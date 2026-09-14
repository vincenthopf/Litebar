import AppKit
import ApplicationServices

@MainActor
private final class RuntimeTarget: NSObject {
    var clicks: [NSEvent.EventType] = []
    @objc func clicked(_ sender: NSStatusBarButton) {
        if let type = NSApp.currentEvent?.type { clicks.append(type) }
    }
}

@MainActor
func validateRuntime(_ controller: Controller) async -> Int {
    var assertions = 0
    var fixtures: [NSStatusItem] = []
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        let passed = value()
        fputs("\(passed ? "PASS" : "FAIL"): \(message)\n", stderr)
        guard passed else { exit(1) }
        assertions += 1
    }
    func window(_ status: NSStatusItem) -> UInt32 {
        lb_status_item_window_id(Unmanaged.passUnretained(status).toOpaque(), Int64(status.button?.window?.windowNumber ?? -1))
    }
    func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    func settle() async {
        var previous: [CGRect] = []
        var stable = 0
        for _ in 0..<60 {
            let frames = fixtures.compactMap { controller.server.frame(window($0)) }
            if frames.count == fixtures.count && frames.allSatisfy({ $0.width > 0 }) && frames == previous { stable += 1 }
            else { stable = 0 }
            if stable >= 3 { return }
            previous = frames
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        runtimeFailure("Native fixture layout did not settle")
    }
    check(controller.state.revealed == 1, "validation begins with native sections shown")
    let target = RuntimeTarget()
    let right = NSStatusBar.system.statusItem(withLength: 24)
    let left = NSStatusBar.system.statusItem(withLength: 24)
    for (item, title) in [(right, "R"), (left, "L")] {
        item.button?.title = title
        item.button?.target = target
        item.button?.action = #selector(RuntimeTarget.clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Litebar runtime " + title)
    }
    fixtures = [left, right]
    defer {
        NSStatusBar.system.removeStatusItem(left)
        NSStatusBar.system.removeStatusItem(right)
    }
    await waitFor { window(left) != 0 && window(right) != 0 }
    check(window(left) != 0 && window(right) != 0, "native runtime fixture windows exist")
    await settle()
    for status in [left, right] {
        let id = window(status)
        let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
        let bounds = entries?.first(where: { $0[kCGWindowNumber as String] as? UInt32 == id })?[kCGWindowBounds as String] as? [String: Any]
        let expected = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        fputs("Window \(id): public=\(String(describing: expected)) Rust=\(String(describing: controller.server.frame(id)))\n", stderr)
        check(expected != nil && controller.server.frame(id) == expected, "frame queries and inventory use identical full-window bounds")
    }
    controller.icon?.status.button?.performClick(nil)
    check(controller.state.revealed == 0, "clicking the application icon hides the hidden section")
    await waitFor { controller.server.frame(window(left)).map { $0.maxX <= 0 } == true }
    check(controller.server.frame(window(left)).map { $0.maxX <= 0 } == true, "application control hides real fixture windows")
    controller.icon?.status.button?.performClick(nil)
    check(controller.state.revealed == 1, "clicking the application icon reveals the hidden section")
    await waitFor { controller.server.frame(window(left)).map { $0.minX >= 0 } == true }
    check(controller.server.frame(window(left)).map { $0.minX >= 0 } == true, "application control restores real fixture windows")
    await settle()
    controller.refreshItems(force: true)
    let owned = [controller.icon?.windowID, controller.hidden?.windowID, controller.always?.windowID].compactMap { $0 }
    check(!controller.displayItems.contains { owned.contains($0.id) }, "own hosted controls are excluded from the item list")
    if #available(macOS 26, *), AXIsProcessTrusted() {
        let hosts = [getpid()] + NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").map(\.processIdentifier)
        for pid in hosts {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            var bar: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &bar) == .success, let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() {
                var visited = 0
                inspectAccessibility(unsafeBitCast(bar, to: AXUIElement.self), depth: 0, visited: &visited)
            }
        }
    }
    fflush(stdout)
    if AXIsProcessTrusted() {
        guard let source = controller.inventory.items.first(where: { $0.id == window(left) }),
              let destination = controller.inventory.items.first(where: { $0.id == window(right) }) else {
            runtimeFailure("Native movement fixtures are absent from the WindowServer inventory")
        }
        check(controller.server.matches(source), "live source identity matches")
        check(controller.server.responsive(source.pid), "live source process responds")
        fputs("Cursor property: \(String(describing: controller.server.cursorProperty()))\n", stderr)
        do {
            try await controller.actions.move(source, beside: destination, right: true, section: 1)
            check(controller.server.frame(source.id)?.minX == controller.server.frame(destination.id)?.maxX, "native event delivery actually reorders status items")
            try await controller.actions.move(source, beside: destination, right: false, section: 1)
            check(controller.server.frame(source.id)?.maxX == controller.server.frame(destination.id)?.minX, "native event delivery restores fixture order")
            target.clicks.removeAll()
            try await controller.actions.click(source, right: false)
            await waitFor { target.clicks.contains(.leftMouseUp) }
            check(target.clicks.contains(.leftMouseUp), "synthetic left click reaches the status button")
            try await controller.actions.click(source, right: true)
            await waitFor { target.clicks.contains(.rightMouseUp) }
            check(target.clicks.contains(.rightMouseUp), "synthetic right click reaches the status button")
            check(Delivery.activeTaps == 0 && !controller.actions.busy, "live operations release taps and movement lease")
        } catch { runtimeFailure("Live native operation failed: " + error.localizedDescription) }
    } else { print("Live input validation skipped: this runner did not grant Accessibility access.") }
    controller.openSettings()
    weak var settings = NSApp.windows.first { $0.title == "Litebar settings" }
    check(settings?.isVisible == true, "controller opens a native settings window")
    settings?.close()
    await waitFor { settings == nil }
    check(settings == nil, "closed settings window is released")
    controller.openSearch()
    weak var panel = NSApp.windows.first { $0.title == "Litebar items" }
    check(panel?.isVisible == true, "controller opens a native item panel")
    controller.closeItems()
    await waitFor { panel == nil }
    check(panel == nil, "closed item panel is released")
    print("Native runtime: \(assertions) assertions passed. Accessibility: \(AXIsProcessTrusted())")
    return assertions
}

@MainActor
private func inspectAccessibility(_ element: AXUIElement, depth: Int, visited: inout Int) {
    guard depth < 4, visited < 32 else { return }
    visited += 1
    AXUIElementSetMessagingTimeout(element, 0.05)
    var pid: pid_t = 0
    _ = AXUIElementGetPid(element, &pid)
    let keys = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXHelpAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
    var fields: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, keys, [], &fields) == .success, let fields = fields as? [Any], fields.count == 8 else { return }
    print("AX fixture depth=\(depth) pid=\(pid) identity=\(Array(fields.prefix(7)))")
    for child in (fields[7] as? [AXUIElement] ?? []).prefix(32) { inspectAccessibility(child, depth: depth + 1, visited: &visited) }
}

private func runtimeFailure(_ message: String) -> Never {
    fputs("FAIL: " + message + "\n", stderr)
    exit(1)
}
