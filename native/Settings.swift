import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class Settings {
    static let flags: [(String, UInt32)] = [("ShowOnHover", 1), ("ShowOnClick", 2), ("ShowOnScroll", 4), ("AutoRehide", 8),
                                          ("EnableAlwaysHiddenSection", 16), ("UseIceBar", 32), ("ShowSectionDividers", 64)]
    static let defaultsMap: [String: Any] = ["ShowIceIcon": true, "ShowOnClick": true, "ShowOnHover": false, "ShowOnScroll": true,
        "AutoRehide": true, "RehideStrategy": 0, "RehideInterval": 15.0, "ShowOnHoverDelay": 0.2, "EnableAlwaysHiddenSection": false,
        "UseIceBar": false, "ShowSectionDividers": false, "HideApplicationMenus": true, "CanToggleAlwaysHiddenSection": true,
        "ShowAllSectionsOnUserDrag": true, "ShowContextMenuOnRightClick": true, "TempShowInterval": 15.0, "IceBarLocation": 0,
        "ItemSpacingOffset": 0]
    let defaults: UserDefaults
    private(set) var config = lb_default_config()

    init(defaults: UserDefaults = .standard, migrate: Bool = true) {
        self.defaults = defaults
        if migrate && !defaults.bool(forKey: "LitebarImportedIce") {
            if let old = defaults.persistentDomain(forName: "com.jordanbaird.Ice") {
                let keys = Array(Self.defaultsMap.keys) + ["Hotkeys", "NSStatusItem Preferred Position SItem", "NSStatusItem Preferred Position HItem", "NSStatusItem Preferred Position AHItem"]
                for key in keys where defaults.object(forKey: key) == nil {
                    if let value = old[key] { defaults.set(value, forKey: key) }
                }
            }
            defaults.set(true, forKey: "LitebarImportedIce")
        }
        defaults.register(defaults: Self.defaultsMap)
        reload()
    }

    func reload() {
        config.flags = Self.flags.reduce(0) { $0 | (defaults.bool(forKey: $1.0) ? $1.1 : 0) }
        config.rehide_strategy = UInt32(max(0, min(2, defaults.integer(forKey: "RehideStrategy"))))
        config.rehide_ms = milliseconds("RehideInterval", fallback: 15, range: 0.1...3600)
        config.hover_ms = milliseconds("ShowOnHoverDelay", fallback: 0.2, range: 0...10)
    }

    func milliseconds(_ key: String, fallback: Double, range: ClosedRange<Double>) -> UInt64 {
        let value = defaults.double(forKey: key)
        return UInt64((min(range.upperBound, max(range.lowerBound, value.isFinite ? value : fallback)) * 1000).rounded())
    }

    func toggle(_ key: String) { defaults.set(!defaults.bool(forKey: key), forKey: key); reload() }
    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    var temporaryInterval: TimeInterval { Double(milliseconds("TempShowInterval", fallback: 15, range: 1...3600)) / 1000 }
}

struct Shortcut: Equatable {
    var key: UInt32
    var modifiers: UInt32
    var carbon: UInt32 {
        (modifiers & 1 != 0 ? UInt32(controlKey) : 0) | (modifiers & 2 != 0 ? UInt32(optionKey) : 0) |
        (modifiers & 4 != 0 ? UInt32(shiftKey) : 0) | (modifiers & 8 != 0 ? UInt32(cmdKey) : 0)
    }
    var label: String {
        let prefix = [(1, "⌃"), (2, "⌥"), (4, "⇧"), (8, "⌘")].reduce("") { $0 + (modifiers & UInt32($1.0) != 0 ? $1.1 : "") }
        return prefix + Self.keyLabel(key)
    }
    private static func keyLabel(_ key: UInt32) -> String {
        let special: [UInt32: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 76: "Enter", 115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let label = special[key] { return label }
        let functionKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if let index = functionKeys.firstIndex(of: key) { return "F\(index + 1)" }
        guard key <= 127, let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(key)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size else { return "Key \(key)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadState, characters.count, &length, &characters)
        guard status == noErr, length > 0, length <= characters.count else { return "Key \(key)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    init(key: UInt32, modifiers: UInt32) { self.key = key; self.modifiers = modifiers & 15 }
    init(event: NSEvent) {
        key = UInt32(event.keyCode)
        let f = event.modifierFlags
        modifiers = (f.contains(.control) ? 1 : 0) | (f.contains(.option) ? 2 : 0) | (f.contains(.shift) ? 4 : 0) | (f.contains(.command) ? 8 : 0)
    }
    static func decode(_ data: Data) -> Shortcut? {
        guard let values = try? JSONDecoder().decode([UInt32].self, from: data), values.count == 2,
              values[0] <= 127, values[1] <= 15 else { return nil }
        return Shortcut(key: values[0], modifiers: values[1])
    }
    func encoded() -> Data? { try? JSONEncoder().encode([key, modifiers]) }
}

@MainActor
final class Hotkeys {
    static let actions = ["ToggleHiddenSection", "ToggleAlwaysHiddenSection", "SearchMenuBarItems", "EnableIceBar", "ShowSectionDividers", "ToggleApplicationMenus"]
    static let labels = ["Toggle hidden", "Toggle always-hidden", "Search items", "Toggle separate bar", "Toggle dividers", "Toggle application menus"]
    let defaults: UserDefaults
    private var handler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private(set) var shortcuts: [UInt32: Shortcut] = [:]
    private var suspensionReasons: Set<UInt32> = []
    var action: ((UInt32) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: "Hotkeys") as? [String: Data] ?? [:]
        for (index, name) in Self.actions.enumerated() {
            if let data = stored[name], let shortcut = Shortcut.decode(data) { shortcuts[UInt32(index)] = shortcut }
        }
    }

    func install() -> [String] {
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let object = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
                    var id = EventHotKeyID()
                    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
                    guard status == noErr, id.signature == 0x4c425231, object.registrations[id.id] != nil else { return OSStatus(eventNotHandledErr) }
                    object.action?(id.id)
                    return noErr
                }
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            if status != noErr { return ["Unable to install hotkeys (\(status))."] }
        }
        guard suspensionReasons.isEmpty else { return [] }
        var errors: [String] = []
        for (id, shortcut) in shortcuts where registrations[id] == nil {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(shortcut.key, shortcut.carbon, EventHotKeyID(signature: 0x4c425231, id: id), GetEventDispatcherTarget(), 0, &reference)
            if result == noErr, let reference { registrations[id] = reference }
            else { errors.append("\(Self.labels[Int(id)]) conflicts with another shortcut (\(result)).") }
        }
        return errors
    }

    func set(_ shortcut: Shortcut?, for id: UInt32) throws {
        guard Int(id) < Self.actions.count else { throw AppError.message("Unknown shortcut.") }
        if let shortcut {
            guard shortcut.modifiers & 11 != 0 else { throw AppError.message("Include Command, Option, or Control in the shortcut.") }
            if shortcuts.contains(where: { $0.key != id && $0.value == shortcut }) { throw AppError.message("That shortcut is already assigned.") }
            var symbolic: Unmanaged<CFArray>?
            if CopySymbolicHotKeys(&symbolic) == noErr, let values = symbolic?.takeRetainedValue() as? [[String: Any]],
               values.contains(where: { ($0[kHISymbolicHotKeyEnabled] as? Bool == true) && ($0[kHISymbolicHotKeyCode] as? UInt32 == shortcut.key) && ($0[kHISymbolicHotKeyModifiers] as? UInt32 == shortcut.carbon) }) {
                throw AppError.message("macOS reserves that shortcut.")
            }
        }
        let old = shortcuts[id]
        if let existing = registrations.removeValue(forKey: id) { UnregisterEventHotKey(existing) }
        shortcuts[id] = shortcut
        let errors = install()
        if !errors.isEmpty {
            if let existing = registrations.removeValue(forKey: id) { UnregisterEventHotKey(existing) }
            shortcuts[id] = old
            _ = install()
            throw AppError.message(errors.joined(separator: "\n"))
        }
        var stored = [String: Data]()
        for (id, value) in shortcuts { stored[Self.actions[Int(id)]] = value.encoded() }
        defaults.set(stored, forKey: "Hotkeys")
    }

    func suspend(_ value: Bool, reason: UInt32 = 2) {
        if value { suspensionReasons.insert(reason) } else { suspensionReasons.remove(reason) }
        if suspensionReasons.isEmpty { _ = install() } else { clearRegistrations() }
    }
    private func clearRegistrations() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
    }
    func stop() {
        clearRegistrations()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}
