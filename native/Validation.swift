import AppKit
import ApplicationServices

@MainActor
func validateNative(_ controller: Controller) {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        assertions += 1
    }
    check(lb_abi_version() == 1, "ABI version")
    check(MemoryLayout<LBConfig>.size == 24, "config ABI")
    check(MemoryLayout<LBState>.size == 56, "state ABI")
    check(MemoryLayout<LBRect>.size == 32, "rectangle ABI")
    check(MemoryLayout<LBEventSpec>.size == 24, "event ABI")
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
    let panel = ItemPanel(controller: controller)
    let item = BarItem(id: 100, pid: 123, namespace: "com.apple.controlcenter", title: "WiFi", name: "Wi-Fi", frame: CGRect(x: 100, y: 0, width: 20, height: 24), onScreen: true, flags: 3, section: 2)
    panel.setItems([item])
    panel.search.stringValue = "wf"
    panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    check(panel.numberOfRows(in: panel.table) == 1, "native search results")
    check(panel.selected?.id == 100, "native search selection")
    panel.makeKeyAndOrderFront(nil)
    check(panel.isVisible, "native panel visible")
    panel.orderOut(nil)
    check(Delivery.activeTaps == 0, "no synthetic event taps left installed")
    print("Native validation: \(assertions) assertions passed")
    controller.stop()
    NSApp.terminate(nil)
}
