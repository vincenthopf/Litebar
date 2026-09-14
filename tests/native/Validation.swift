import AppKit
import ApplicationServices

@MainActor
func validateNative(_ controller: Controller, liveInput: Bool = true) async {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        assertions += 1
    }
    for _ in 0..<40 {
        if controller.hidden?.windowID != nil { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if controller.hidden?.windowID == nil {
        print("Missing hosted divider after the startup deadline.")
        fflush(stdout)
    }
    check(Divider.validWindowID(-1) == nil, "unassigned window number")
    check(Divider.validWindowID(0) == nil, "null window number")
    check(Divider.validWindowID(Int.max) == nil, "overflowing window number")
    check(Divider.validWindowID(123) == 123, "assigned window number")
    check(lb_copy_window_description(0) == nil, "null window description")
    check(lb_copy_window_description(UInt32.max) == nil, "missing window description")
    check(lb_status_item_window_id(nil, -1) == 0, "nil hosted status item")
    check(lb_status_item_window_id(nil, 123) == 123, "legacy status window ID")
    check(identityFlags("com.apple.controlcenter", "BentoBox-0") == 2, "hosted Control Center restriction")
    check(identityFlags("com.apple.controlcenter", "AudioVideoModule-0") == 1, "hosted privacy indicator restriction")
    check(lb_abi_version() == 1, "ABI version")
    check(MemoryLayout<LBConfig>.size == 24, "config ABI")
    check(MemoryLayout<LBState>.size == 56, "state ABI")
    check(MemoryLayout<LBRect>.size == 32, "rectangle ABI")
    check(MemoryLayout<LBEventSpec>.size == 24, "event ABI")
    check(MemoryLayout<LBMoveCandidate>.size == 48, "movement candidate ABI")
    check(MemoryLayout<LBMovePlan>.size == 40, "movement result ABI")
    check(MemoryLayout<LBFrameWait>.size == 24, "frame wait ABI")
    check(MemoryLayout<LBMoveLease>.size == 16, "movement lease ABI")
    let config = lb_default_config()
    check(config.flags == 14, "default flags")
    var state = lb_initial_state()
    check(lb_next_deadline(state) == 0, "idle timer")
    state = lb_step(state, config, 1, 100)
    check(state.revealed == 1, "FFI reveal")
    state = lb_step(state, config, 1, 101)
    check(state.revealed == 0, "FFI hide")
    check(lb_classic_transition(3, 2, 1) == 1, "always-hidden transition")
    check(identityFlags("com.apple.controlcenter", "Clock") == 2, "clock restriction")
    check(identityFlags("com.apple.controlcenter", "AudioVideoModule") == 1, "privacy indicator restriction")
    check(searchScore("wf", "Wi-Fi") >= 0, "search FFI")
    check(searchScore("missing", "Wi-Fi") == -1, "search miss")
    check(Shortcut.decode(Data("[49,9]".utf8)) == Shortcut(key: 49, modifiers: 9), "legacy hotkey format")
    check(Shortcut.decode(Data("[49]".utf8)) == nil, "invalid hotkey format")
    check(Shortcut(key: 49, modifiers: 9).label == "⌃⌘Space", "shortcut modifier labels")
    check(Shortcut(key: 122, modifiers: 0).label == "F1", "function key labels")
    check(Shortcut(key: 49, modifiers: 9).carbon == UInt32(4096 + 256), "Carbon modifier conversion")
    controller.settings.defaults.set(Double.nan, forKey: "RehideInterval")
    controller.settings.defaults.set(-1, forKey: "RehideStrategy")
    controller.settings.reload()
    check(controller.settings.config.rehide_ms == 15000, "nonfinite settings")
    check(controller.settings.config.rehide_strategy == 0, "negative enum setting")
    check(controller.icon?.status.button != nil, "native status button")
    check(controller.hidden?.status.isVisible == true, "native hidden divider")
    check(controller.always?.status.isVisible == false, "disabled always-hidden divider")
    check(controller.server.available, "required private symbols are present")
    if let id = controller.hidden?.windowID { check(controller.server.frame(id) != nil, "Rust WindowServer frame FFI") }
    else { preconditionFailure("Hidden divider has no window") }
    check(controller.server.activeSpace != nil, "Rust active Space FFI")
    check(controller.server.descriptions() != nil, "Rust batch window descriptions FFI")
    var candidate = LBMoveCandidate(window_id: 1, process_id: 100, display_id: 1, flags: 3, frame: LBRect(x: 20, y: 0, width: 20, height: 24))
    let target = LBMoveCandidate(window_id: 2, process_id: 200, display_id: 1, flags: 3, frame: LBRect(x: 100, y: 0, width: 20, height: 24))
    let planned = lb_plan_move(candidate, target, 0, 2)
    check(planned.status == 0 && planned.target_x == 100 && planned.fallback_x == 30, "Rust movement plan FFI")
    candidate.flags = 2
    check(lb_plan_move(candidate, target, 0, 2).status != 0, "Rust movement policy protects fixed items")
    var wait = lb_frame_wait_start(100, 50)
    check(lb_frame_wait_poll(&wait, 100) == 0, "Rust first frame observation")
    check(lb_frame_wait_poll(&wait, 101) == 9, "Rust bounded frame wait")
    var lease = LBMoveLease()
    check(lb_move_begin(&lease, 100) == 1, "Rust movement lease begins")
    for n: UInt32 in 1...5 { check(lb_move_attempt(&lease, 101) == n, "Rust movement lease counts attempts") }
    check(lb_move_attempt(&lease, 102) == 0, "Rust movement retry cap")
    if let source = CGEventSource(stateID: .hidSystemState) {
        for kind: UInt32 in 0...1 {
            for button: UInt32 in 0..<6 {
                do {
                    let spec = lb_event_spec(kind, button)
                    let event = try Delivery.makeEvent(source: source, kind: kind, button: button, point: .zero, window: 123, pid: 456)
                    check(event.type.rawValue == spec.event_type, "native event type")
                    check(event.flags.rawValue == spec.flags, "native event flags")
                    check(event.getIntegerValueField(.eventTargetUnixProcessID) == 456, "target pid")
                    check(event.getIntegerValueField(CGEventField(rawValue: 0x33)!) == 123, "private window field")
                    check(event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 123, "window pointer field")
                    check(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 123, "handled window field")
                    if kind == 1 { check(event.getIntegerValueField(.mouseEventClickState) == 1, "click state") }
                } catch { preconditionFailure(error.localizedDescription) }
            }
        }
    } else { preconditionFailure("CGEventSource unavailable") }
    assertions += await validateDelivery()
    assertions += await validateRuntime(controller, liveInput: liveInput)
    let panel = ItemPanel(controller: controller)
    let item = BarItem(id: 100, pid: 123, namespace: "com.apple.controlcenter", title: "WiFi", name: "Wi-Fi", frame: CGRect(x: 100, y: 0, width: 20, height: 24), onScreen: true, flags: 3, section: 2)
    panel.setItems([item])
    panel.search.stringValue = "wf"
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    check(panel.numberOfRows(in: panel.table) == 1, "native search results")
    check(panel.selected?.id == 100, "native search selection")
    panel.makeKeyAndOrderFront(nil)
    check(panel.isVisible, "native panel visible")
    if let destination = ProcessInfo.processInfo.environment["LITEBAR_VALIDATION_DIR"] {
        do {
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            try saveWireframe(panel, to: URL(fileURLWithPath: destination).appendingPathComponent("items.png"))
            let settings = SettingsWindow(controller: controller)
            settings.makeKeyAndOrderFront(nil)
            try saveWireframe(settings, to: URL(fileURLWithPath: destination).appendingPathComponent("settings.png"))
            settings.close()
        } catch { preconditionFailure(error.localizedDescription) }
    }
    panel.orderOut(nil)
    check(Delivery.activeTaps == 0, "no synthetic event taps left installed")
    print("Native validation: \(assertions) assertions passed")
    controller.stop()
    NSApp.terminate(nil)
}

@MainActor
private func saveWireframe(_ window: NSWindow, to url: URL) throws {
    guard let view = window.contentView else { throw AppError.message("Missing native content view.") }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Unable to render the native wireframe.") }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw AppError.message("Unable to create the wireframe graphics context.") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.windowBackgroundColor.setFill()
    view.bounds.fill()
    view.displayIgnoringOpacity(view.bounds, in: context)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Unable to encode the native wireframe.") }
    try data.write(to: url, options: .atomic)
}

@MainActor
private final class TestEndpoint: EventEndpoint {
    var receive: ((CGEventType, CGEvent) -> CGEvent?)?
    var stopped = false
    func stop() { stopped = true; receive = nil }
}

@MainActor
private final class TestTransport {
    enum Behavior { case echo, silent, failFirst, failSecond }
    let behavior: Behavior
    var endpoints: [TestEndpoint] = []
    var posts: [pid_t?] = []
    init(_ behavior: Behavior) { self.behavior = behavior }
    func make(_ pid: pid_t?, _ type: CGEventType, _ passive: Bool) throws -> any EventEndpoint {
        if behavior == .failFirst || (behavior == .failSecond && endpoints.count == 1) {
            throw AppError.message("Expected test endpoint failure")
        }
        let endpoint = TestEndpoint()
        endpoints.append(endpoint)
        return endpoint
    }
    func post(_ event: CGEvent, _ pid: pid_t?) {
        posts.append(pid)
        guard behavior == .echo else { return }
        if event.type == .null { _ = endpoints.last?.receive?(event.type, event) }
        else if pid == nil { _ = endpoints.first?.receive?(event.type, event) }
    }
}

@MainActor
private func validateDelivery() async -> Int {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        assertions += 1
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = try? Delivery.makeEvent(source: source, kind: 1, button: 0, point: .zero, window: 123, pid: 456) else {
        preconditionFailure("Native test event could not be created")
    }
    for behavior in [TestTransport.Behavior.echo, .silent, .failFirst, .failSecond] {
        let transport = TestTransport(behavior)
        let delivery = Delivery(timeout: 0.005, makePort: transport.make, post: transport.post)
        do {
            try await delivery.send(event, through: 456)
            check(behavior == .echo, "Only acknowledged delivery succeeds")
            check(transport.posts.count == 3, "PID-session-PID relay")
            check(transport.posts[0] == 456 && transport.posts[1] == nil && transport.posts[2] == 456, "Relay destinations")
        } catch { check(behavior != .echo, "Acknowledged delivery must not time out") }
        check(transport.endpoints.allSatisfy(\.stopped), "Every created endpoint is closed")
        check(Delivery.activeTaps == 0, "Failure paths leave no event taps")
    }
    let direct = TestTransport(.echo)
    do { try await Delivery(makePort: direct.make, post: direct.post).send(event) }
    catch { preconditionFailure(error.localizedDescription) }
    check(direct.posts.count == 1 && direct.posts[0] == nil, "Direct click uses the session stream")
    check(direct.endpoints.allSatisfy(\.stopped), "Direct delivery closes its endpoint")
    let cancelled = TestTransport(.silent)
    let delivery = Delivery(timeout: 1, makePort: cancelled.make, post: cancelled.post)
    let task = Task { try await delivery.send(event, through: 456) }
    try? await Task.sleep(nanoseconds: 5_000_000)
    task.cancel()
    do { try await task.value; preconditionFailure("Cancelled delivery succeeded") }
    catch { check(error is CancellationError, "Cancellation preserves the cancellation error") }
    check(cancelled.endpoints.allSatisfy(\.stopped), "Cancellation closes endpoints")
    check(Delivery.activeTaps == 0, "Cancellation releases all taps")
    return assertions
}
