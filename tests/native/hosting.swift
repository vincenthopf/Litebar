import AppKit
import ObjectiveC.runtime

private final class HostUInt: NSObject { @objc func hostWindowID() -> UInt32 { 123 } }
private final class HostUInt64: NSObject { @objc func hostWindowID() -> UInt64 { 124 } }
private final class HostInt: NSObject { @objc func hostWindowID() -> Int32 { 125 } }
private final class HostInt64: NSObject { @objc func hostWindowID() -> Int64 { 126 } }
private final class HostNegative: NSObject { @objc func hostWindowID() -> Int64 { -1 } }
private final class HostOverflow: NSObject { @objc func hostWindowID() -> UInt64 { UInt64.max } }
private final class HostWrong: NSObject { @objc func hostWindowID() -> String { "123" } }

@MainActor
private final class HostingValidator: NSObject, NSApplicationDelegate {
    var controls: [NSStatusItem] = []
    var assertions = 0

    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        assertions += 1
    }

    func number(_ object: NSObject, fallback: Int64 = -1) -> UInt32 {
        lb_status_item_window_id(Unmanaged.passUnretained(object).toOpaque(), fallback)
    }

    func rectangle(_ item: NSStatusItem) -> CGRect? {
        let id = number(item, fallback: Int64(item.button?.window?.windowNumber ?? -1))
        var frame = LBRect()
        guard id != 0, lb_window_frame(id, &frame) != 0 else { return nil }
        return CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for title in ["R", "|", "L"] {
            let item = NSStatusBar.system.statusItem(withLength: 24)
            item.button?.title = title
            controls.append(item)
        }
        Task { @MainActor in await validate() }
    }

    func validate() async {
        for item in controls {
            let selector = NSSelectorFromString("hostWindowID")
            if let method = class_getInstanceMethod(type(of: item), selector), let encoding = method_getTypeEncoding(method) {
                print("Host accessor: \(NSStringFromClass(type(of: item))) \(String(cString: encoding))")
            } else { print("Legacy status item: \(NSStringFromClass(type(of: item)))") }
        }
        fflush(stdout)
        check(number(HostUInt()) == 123, "unsigned 32-bit host ID")
        check(number(HostUInt64()) == 124, "unsigned 64-bit host ID")
        check(number(HostInt()) == 125, "signed 32-bit host ID")
        check(number(HostInt64()) == 126, "signed 64-bit host ID")
        check(number(HostNegative()) == 0, "negative host ID is invalid")
        check(number(HostOverflow()) == 0, "oversized host ID is invalid")
        check(number(HostWrong(), fallback: 123) == 0, "unsupported host ABI fails closed")
        check(number(NSObject(), fallback: 127) == 127, "older OS uses local window ID")
        check(number(NSObject(), fallback: -1) == 0, "unassigned local window ID")
        for _ in 0..<60 {
            if controls.allSatisfy({ rectangle($0) != nil }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        for (index, item) in controls.enumerated() {
            print("Assigned status \(index): host=\(number(item)), local=\(item.button?.window?.windowNumber ?? -1), frame=\(String(describing: rectangle(item)))")
        }
        fflush(stdout)
        check(controls.allSatisfy { rectangle($0) != nil }, "every native status item has an assigned server window")
        controls[1].length = 10000
        for _ in 0..<60 {
            if let frame = rectangle(controls[2]), frame.maxX <= 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        print("Hidden fixture: \(String(describing: rectangle(controls[2]))), divider: \(String(describing: rectangle(controls[1])))")
        fflush(stdout)
        check(rectangle(controls[2]).map { $0.maxX <= 0 } == true, "expanded divider actually hides a native status item")
        controls[1].length = 24
        for _ in 0..<60 {
            if let frame = rectangle(controls[2]), frame.minX >= 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        check(rectangle(controls[2]).map { $0.minX >= 0 && $0.width > 0 } == true, "contracted divider restores a native status item")
        for item in controls { NSStatusBar.system.removeStatusItem(item) }
        controls.removeAll()
        print("Native status hosting: \(assertions) assertions passed")
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let validator = HostingValidator()
    application.delegate = validator
    withExtendedLifetime(validator) { application.run() }
}
