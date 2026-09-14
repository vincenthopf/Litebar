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
    typealias Connection = @convention(c) () -> Int32
    typealias Count = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>) -> Int32
    typealias List = @convention(c) (Int32, Int32, Int32, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<Int32>) -> Int32
    typealias Frame = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    typealias ActiveSpace = @convention(c) (Int32) -> UInt
    typealias SpaceType = @convention(c) (Int32, UInt) -> UInt32
    typealias Spaces = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    typealias CopyProperty = @convention(c) (Int32, Int32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32

    private let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    private lazy var connection: Connection? = symbol("CGSMainConnectionID", "SLSMainConnectionID")
    private lazy var count: Count? = symbol("CGSGetWindowCount", "SLSGetWindowCount")
    private lazy var list: List? = symbol("CGSGetProcessMenuBarWindowList", "SLSGetProcessMenuBarWindowList")
    private lazy var getFrame: Frame? = symbol("CGSGetScreenRectForWindow", "SLSGetScreenRectForWindow")
    private lazy var space: ActiveSpace? = symbol("CGSGetActiveSpace", "SLSGetActiveSpace")
    private lazy var spaceType: SpaceType? = symbol("CGSSpaceGetType", "SLSSpaceGetType")
    private lazy var spaces: Spaces? = symbol("CGSCopySpacesForWindows", "SLSCopySpacesForWindows")
    private lazy var setProperty: SetProperty? = symbol("CGSSetConnectionProperty", "SLSSetConnectionProperty")
    private lazy var copyProperty: CopyProperty? = symbol("CGSCopyConnectionProperty", "SLSCopyConnectionProperty")

    private func symbol<T>(_ names: String...) -> T? {
        guard let handle else { return nil }
        for name in names {
            if let raw = dlsym(handle, name) { return unsafeBitCast(raw, to: T.self) }
        }
        return nil
    }

    var available: Bool { connection != nil && count != nil && list != nil && getFrame != nil && spaces != nil && space != nil }
    var activeSpace: UInt? { connection.flatMap { id in space.map { $0(id()) } } }
    var fullscreen: Bool {
        guard let connection, let activeSpace, let spaceType else { return false }
        return spaceType(connection(), activeSpace) == 4
    }

    func frame(_ id: UInt32) -> CGRect? {
        guard let connection, let getFrame, id != 0 else { return nil }
        var result = CGRect.zero
        return getFrame(connection(), id, &result) == 0 && result.finite ? result : nil
    }

    func active(_ id: UInt32, space: UInt) -> Bool {
        guard let connection, let spaces,
              let copied = spaces(connection(), 7, [NSNumber(value: id)] as CFArray),
              let values = copied.takeRetainedValue() as? [NSNumber] else { return false }
        return values.contains { $0.uintValue == space }
    }

    func descriptions() -> [[String: Any]] {
        guard let connection, let count, let list, let activeSpace else { return [] }
        var capacity: Int32 = 0
        guard count(connection(), 0, &capacity) == 0, capacity > 0, capacity <= 65536 else { return [] }
        capacity = min(capacity + 64, 65536)
        var ids = [UInt32](repeating: 0, count: Int(capacity))
        var actual: Int32 = 0
        guard list(connection(), 0, capacity, &ids, &actual) == 0, actual >= 0, actual <= capacity else { return [] }
        let windows = ids.prefix(Int(actual)).filter { $0 != 0 && active($0, space: activeSpace) }
        guard !windows.isEmpty else { return [] }
        var pointers = windows.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
              let result = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [] }
        return result
    }

    func matches(_ item: BarItem) -> Bool {
        guard let descriptions = CGWindowListCopyWindowInfo(.optionIncludingWindow, item.id) as? [[String: Any]],
              let value = descriptions.first(where: { $0[kCGWindowNumber as String] as? UInt32 == item.id }) else { return false }
        return value[kCGWindowOwnerPID as String] as? pid_t == item.pid
            && (value[kCGWindowName as String] as? String ?? "") == item.title
    }

    func cursorProperty() -> Bool? {
        guard let connection, let copyProperty else { return nil }
        var value: Unmanaged<CFTypeRef>?
        guard copyProperty(connection(), connection(), "SetsCursorInBackground" as CFString, &value) == 0 else { return nil }
        return value?.takeRetainedValue() as? Bool
    }

    @discardableResult
    func setCursorProperty(_ value: Bool) -> Bool {
        guard let connection, let setProperty else { return false }
        return setProperty(connection(), connection(), "SetsCursorInBackground" as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == 0
    }
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

    init(server: WindowServer) { self.server = server }
    func invalidate() { dirty = true }
    func clear() { items.removeAll(keepingCapacity: false); dirty = true }

    func refresh(hiddenID: UInt32?, alwaysID: UInt32?, force: Bool = false) {
        let now = monotonicMilliseconds()
        guard force || dirty || now &- refreshedAt >= 500 else { return }
        scans &+= 1
        refreshedAt = now
        dirty = false
        let descriptions = server.descriptions()
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

    init(name: String, position: Int?, defaults: UserDefaults) {
        self.defaults = defaults
        self.name = name
        let key = "NSStatusItem Preferred Position " + name
        if defaults.object(forKey: key) == nil, let position { defaults.set(position, forKey: key) }
        status = NSStatusBar.system.statusItem(withLength: 0)
        status.autosaveName = name
        if let button = status.button,
           let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal) {
            widthConstraint = constraints.first { ($0.secondItem as? NSView) === button.superview }
        }
    }

    var windowID: UInt32? { status.button?.window.map { UInt32($0.windowNumber) } }

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
        var menu: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(bounds.minX + 1), Float(bounds.minY + 1), &menu) == .success,
              let menu, attribute(menu, kAXRoleAttribute) as? String == kAXMenuBarRole,
              let children = attribute(menu, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        var result = CGRect.null
        for child in children.prefix(100) {
            guard attribute(child, kAXEnabledAttribute) as? Bool == true,
                  let p = attribute(child, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
                  let s = attribute(child, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { continue }
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
