import AppKit
import ApplicationServices
import Darwin

extension CGRect {
    var rust: LBRect { LBRect(x: origin.x, y: origin.y, width: width, height: height) }
    var finite: Bool { [minX, minY, maxX, maxY, width, height].allSatisfy(\.isFinite) && width >= 0 && height >= 0 }
}

func monotonicMilliseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

func withUTF8<T>(_ value: String, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    var text = value
    return text.withUTF8 { body($0.baseAddress, $0.count) }
}

func identityFlags(_ namespace: String, _ title: String) -> UInt32 {
    withUTF8(namespace) { p, n in withUTF8(title) { q, m in lb_identity_flags(p, n, q, m) } }
}

func searchScore(_ query: String, _ text: String) -> Int32 {
    withUTF8(query) { p, n in withUTF8(text) { q, m in lb_search_score(p, n, q, m) } }
}

@MainActor
final class WindowServer {
    var available: Bool { lb_window_server_available() != 0 }
    var activeSpace: UInt? { let value = lb_active_space(); return value == 0 ? nil : UInt(value) }
    var fullscreen: Bool { lb_fullscreen() != 0 }

    func frame(_ id: UInt32) -> CGRect? {
        var value = LBRect()
        guard lb_window_frame(id, &value) != 0 else { return nil }
        return CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    func descriptions() -> [[String: Any]]? {
        guard let value = lb_copy_window_descriptions() else { return nil }
        return Unmanaged<CFArray>.fromOpaque(value).takeRetainedValue() as? [[String: Any]]
    }

    func matches(_ item: BarItem) -> Bool {
        guard let raw = lb_copy_window_description(item.id),
              let descriptions = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as? [[String: Any]],
              let value = descriptions.first(where: { $0[kCGWindowNumber as String] as? UInt32 == item.id }) else { return false }
        return value[kCGWindowOwnerPID as String] as? pid_t == item.pid
            && (value[kCGWindowName as String] as? String ?? "") == item.title
            && (NSRunningApplication(processIdentifier: item.pid)?.bundleIdentifier ?? "<null>") == item.namespace
    }

    func responsive(_ pid: pid_t) -> Bool { lb_process_responsivity(pid) >= 0 }
    func cursorProperty() -> Bool? { let value = lb_cursor_property(); return value < 0 ? nil : value != 0 }
    @discardableResult
    func setCursorProperty(_ value: Bool) -> Bool { lb_set_cursor_property(value ? 1 : 0) != 0 }
}

struct BarItem: Identifiable {
    let id: UInt32
    let pid: pid_t
    let namespace: String
    let title: String
    let name: String
    let frame: CGRect
    let onScreen: Bool
    let flags: UInt32
    var section: UInt32 = 0
    var identity: String { namespace + ":" + title }
}

@MainActor
final class Inventory {
    let server: WindowServer
    private(set) var items: [BarItem] = []
    private(set) var generation: UInt64 = 0
    private(set) var scans: UInt64 = 0
    private(set) var refreshedAt: UInt64 = 0
    private(set) var dirty = true
    private(set) var reliable = false

    init(server: WindowServer) { self.server = server }
    func invalidate() { dirty = true }
    func clear() { items.removeAll(keepingCapacity: false); dirty = true; reliable = false }

    func refresh(hiddenID: UInt32?, alwaysID: UInt32?, force: Bool = false) {
        let now = monotonicMilliseconds()
        guard force || dirty || now &- refreshedAt >= 500 else { return }
        scans &+= 1
        refreshedAt = now
        dirty = false
        guard let descriptions = server.descriptions() else {
            reliable = false
            items.removeAll(keepingCapacity: true)
            return
        }
        reliable = true
        var processes = [pid_t: NSRunningApplication]()
        let hidden = hiddenID.flatMap(server.frame)
        let always = alwaysID.flatMap(server.frame)
        var result = [BarItem]()
        result.reserveCapacity(descriptions.count)
        for info in descriptions {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == Int(CGWindowLevelForKey(.statusWindow)),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.finite else { continue }
            if processes[pid] == nil { processes[pid] = NSRunningApplication(processIdentifier: pid) }
            let app = processes[pid]
            let namespace = app?.bundleIdentifier ?? "<null>"
            let title = info[kCGWindowName as String] as? String ?? ""
            let owner = app?.localizedName ?? info[kCGWindowOwnerName as String] as? String ?? namespace
            let name = Self.displayName(namespace: namespace, title: title, owner: owner)
            let protectedWithoutTitle = title.isEmpty && ["com.apple.controlcenter", "com.apple.systemuiserver"].contains(namespace)
            var item = BarItem(id: id, pid: pid, namespace: namespace, title: title, name: name, frame: frame,
                               onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                               flags: protectedWithoutTitle ? 0 : identityFlags(namespace, title))
            if let hidden, abs(frame.midY - hidden.midY) < 2 {
                item.section = lb_section_mask(frame.rust, hidden.rust, (always ?? .zero).rust, always == nil ? 0 : 1)
            }
            result.append(item)
        }
        items = result.sorted { $0.frame.minX == $1.frame.minX ? $0.id < $1.id : $0.frame.minX < $1.frame.minX }
        generation &+= 1
    }

    static func displayName(namespace: String, title: String, owner: String) -> String {
        if namespace == "com.apple.controlcenter" {
            let names = ["AccessibilityShortcuts": "Accessibility Shortcuts", "BentoBox": "Control Center", "FocusModes": "Focus",
                         "KeyboardBrightness": "Keyboard Brightness", "MusicRecognition": "Music Recognition", "NowPlaying": "Now Playing",
                         "ScreenMirroring": "Screen Mirroring", "StageManager": "Stage Manager", "UserSwitcher": "Fast User Switching", "WiFi": "Wi-Fi"]
            return names[title] ?? (title.isEmpty ? owner : title)
        }
        if namespace == "com.apple.systemuiserver" {
            return title.contains("TMMenuExtraHost") ? "Time Machine" : (title.isEmpty ? owner : title)
        }
        if namespace == "com.apple.Passwords.MenuBarExtra" { return "Passwords" }
        return owner
    }
}

@MainActor
final class Divider {
    let status: NSStatusItem
    let name: String
    private var widthConstraint: NSLayoutConstraint?
    private let defaults: UserDefaults

    init(name: String, position: Int?, defaults: UserDefaults, persistent: Bool = true) {
        self.defaults = defaults
        self.name = name
        let key = "NSStatusItem Preferred Position " + name
        if defaults.object(forKey: key) == nil, let position { defaults.set(position, forKey: key) }
        status = NSStatusBar.system.statusItem(withLength: 0)
        if persistent { status.autosaveName = name }
        if let button = status.button,
           let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal) {
            widthConstraint = constraints.first { ($0.secondItem as? NSView) === button.superview }
        }
    }

    static func validWindowID(_ number: Int) -> UInt32? {
        guard number > 0 else { return nil }
        return UInt32(exactly: number)
    }

    var windowID: UInt32? {
        let id = lb_status_item_window_id(Unmanaged.passUnretained(status).toOpaque(), Int64(status.button?.window?.windowNumber ?? -1))
        return id == 0 ? nil : id
    }

    func setVisible(_ visible: Bool) {
        guard status.isVisible != visible else { return }
        let key = "NSStatusItem Preferred Position " + name
        let cached = defaults.object(forKey: key)
        status.isVisible = visible
        if let cached { defaults.set(cached, forKey: key) }
    }

    func resize(_ length: Double, text: String) {
        guard let button = status.button else { return }
        let narrow = length <= 1
        widthConstraint?.isActive = !narrow
        let effectiveLength = narrow && widthConstraint == nil ? 8.0 : length
        if status.length != effectiveLength { status.length = effectiveLength }
        button.title = narrow || length >= 10000 ? "" : text
        button.cell?.isEnabled = length < 10000
        button.isHighlighted = false
        if narrow, widthConstraint != nil, let window = button.window {
            window.setContentSize(NSSize(width: 1, height: window.frame.height))
        }
    }

    func remove() {
        let key = "NSStatusItem Preferred Position " + name
        let cached = defaults.object(forKey: key)
        NSStatusBar.system.removeStatusItem(status)
        if let cached { defaults.set(cached, forKey: key) }
    }
}

@MainActor
enum Accessibility {
    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    static func applicationMenuFrame(screen: NSScreen) -> CGRect? {
        guard AXIsProcessTrusted(), let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let bounds = CGDisplayBounds(number.uint32Value)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        let deadline = monotonicMilliseconds() + 150
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, lb_process_responsivity(pid) < 0 { return nil }
        var menu: AXUIElement?
        var attributes: CFArray?
        guard AXUIElementCopyElementAtPosition(system, Float(bounds.minX + 1), Float(bounds.minY + 1), &menu) == .success, let menu else { return nil }
        AXUIElementSetMessagingTimeout(menu, 0.1)
        guard AXUIElementCopyMultipleAttributeValues(menu, [kAXRoleAttribute, kAXChildrenAttribute] as CFArray, .stopOnError, &attributes) == .success,
              let values = attributes as? [Any], values.count == 2, values[0] as? String == kAXMenuBarRole,
              let children = values[1] as? [AXUIElement], children.count <= 64 else { return nil }
        var result = CGRect.null
        let keys = [kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
        for child in children {
            guard monotonicMilliseconds() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(child, 0.05)
            var fields: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(child, keys, .stopOnError, &fields)
            if status == .cannotComplete { return nil }
            guard status == .success, let values = fields as? [Any], values.count == 3, values[0] as? Bool == true else { continue }
            let p = values[1] as CFTypeRef
            let s = values[2] as CFTypeRef
            guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { continue }
            result = result.union(CGRect(origin: point, size: size))
        }
        guard !result.isNull, result.finite, result.width > 0,
              result.minX >= bounds.minX, result.maxX <= bounds.maxX else { return nil }
        if screen != NSScreen.main, let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = notched.auxiliaryTopLeftArea, result.width >= left.maxX { return nil }
        return result
    }
}
