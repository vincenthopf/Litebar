import AppKit
import ApplicationServices

@MainActor
final class EventPort {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let passive: Bool
    var receive: ((CGEventType, CGEvent) -> CGEvent?)?

    init(pid: pid_t?, type: CGEventType, listenOnly: Bool) throws {
        self.passive = listenOnly
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<EventPort>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = owner.port { CGEvent.tapEnable(tap: port, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return (owner.receive?(type, event) ?? (owner.passive ? event : nil)).map(Unmanaged.passUnretained)
            }
        }
        let mask = CGEventMask(1) << type.rawValue
        if let pid {
            port = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap, options: listenOnly ? .listenOnly : .defaultTap,
                                          eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        } else {
            port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: listenOnly ? .listenOnly : .defaultTap,
                                    eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        guard let port, let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            throw AppError.message("Unable to create an event tap. Grant Litebar Accessibility access, then retry.")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        source = nil
        port = nil
        receive = nil
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
    }
}

@MainActor
final class Delivery {
    private var first: EventPort?
    private var second: EventPort?
    private var timer: Timer?
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private static var sequence: Int64 = 0x4c4200000000
    private(set) static var activeTaps = 0

    static func tag() -> Int64 { sequence &+= 1; return sequence }

    static func makeEvent(source: CGEventSource, kind: UInt32, button: UInt32, point: CGPoint, window: UInt32, pid: pid_t) throws -> CGEvent {
        let spec = lb_event_spec(kind, button)
        guard spec.valid == 1, let type = CGEventType(rawValue: spec.event_type), let mouse = CGMouseButton(rawValue: spec.mouse_button),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouse) else {
            throw AppError.message("Unable to construct a menu-bar event.")
        }
        event.flags = CGEventFlags(rawValue: spec.flags)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.eventSourceUserData, value: tag())
        for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, CGEventField(rawValue: 0x33)!] {
            event.setIntegerValueField(field, value: Int64(window))
        }
        if spec.click_count >= 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(spec.click_count)) }
        return event
    }

    func send(_ event: CGEvent, through pid: pid_t? = nil) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let receipt = try EventPort(pid: nil, type: event.type, listenOnly: true)
                    second = receipt
                    Self.activeTaps += 1
                    receipt.receive = { [weak self] _, received in
                        let fields: [CGEventField] = [.eventSourceUserData, .mouseEventWindowUnderMousePointer,
                            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, CGEventField(rawValue: 0x33)!]
                        guard fields.allSatisfy({ received.getIntegerValueField($0) == event.getIntegerValueField($0) }),
                              let self, !self.finished else { return received }
                        self.second?.stop()
                        if let pid { event.postToPid(pid) }
                        self.finish(nil)
                        return received
                    }
                    if let pid {
                        guard let null = CGEvent(source: nil) else { throw AppError.message("Unable to construct the event relay.") }
                        let token = Self.tag()
                        null.setIntegerValueField(.eventSourceUserData, value: token)
                        let relay = try EventPort(pid: pid, type: .null, listenOnly: false)
                        first = relay
                        Self.activeTaps += 1
                        relay.receive = { [weak self] _, received in
                            guard received.getIntegerValueField(.eventSourceUserData) == token else { return received }
                            self?.first?.stop()
                            event.post(tap: .cgSessionEventTap)
                            return nil
                        }
                        armTimeout()
                        null.postToPid(pid)
                    } else {
                        armTimeout()
                        event.post(tap: .cgSessionEventTap)
                    }
                } catch { finish(error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(CancellationError()) }
        }
    }

    private func armTimeout() {
        let value = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(AppError.message("Menu-bar event delivery timed out.")) }
        }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        if first != nil { Self.activeTaps -= 1 }
        if second != nil { Self.activeTaps -= 1 }
        first?.stop()
        second?.stop()
        first = nil
        second = nil
        let result = continuation
        continuation = nil
        if let error { result?.resume(throwing: error) } else { result?.resume() }
    }
}

@MainActor
final class ItemActions {
    let server: WindowServer
    private(set) var busy = false
    var activityChanged: ((Bool) -> Void)?
    init(server: WindowServer) { self.server = server }

    private func ready() async throws {
        guard AXIsProcessTrusted(), server.available else { throw AppError.message("Accessibility access and supported WindowServer APIs are required.") }
        let deadline = monotonicMilliseconds() + 2000
        var previous = NSEvent.mouseLocation
        var quietSince = monotonicMilliseconds()
        while monotonicMilliseconds() < deadline {
            try Task.checkCancellation()
            let position = NSEvent.mouseLocation
            if previous != position { previous = position; quietSince = monotonicMilliseconds() }
            let modifiers = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            if NSEvent.pressedMouseButtons == 0 && modifiers.isEmpty && monotonicMilliseconds() - quietSince >= 100 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.message("Release the mouse and modifier keys, stop moving the pointer, then retry.")
    }

    private func changed(_ id: UInt32, from initial: CGRect) async throws {
        let deadline = monotonicMilliseconds() + 100
        while monotonicMilliseconds() < deadline {
            try Task.checkCancellation()
            guard let current = server.frame(id) else { throw AppError.message("The menu-bar item disappeared.") }
            if current != initial { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.message("The menu-bar item did not move before the deadline.")
    }

    private func source() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw AppError.message("Unable to create an event source.") }
        source.localEventsSuppressionInterval = 0
        for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
            source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents], state: state)
        }
        return source
    }

    private func wake(_ item: BarItem, source: CGEventSource) async throws {
        guard let frame = server.frame(item.id) else { throw AppError.message("The menu-bar item disappeared.") }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let up = try Delivery.makeEvent(source: source, kind: 0, button: 1, point: point, window: item.id, pid: item.pid)
        do {
            let down = try Delivery.makeEvent(source: source, kind: 0, button: 0, point: point, window: item.id, pid: item.pid)
            try await Delivery().send(down, through: item.pid)
            try await Delivery().send(up, through: item.pid)
        } catch {
            up.post(tap: .cgSessionEventTap)
            throw error
        }
    }

    func move(_ item: BarItem, beside target: BarItem, right: Bool, section: UInt32) async throws {
        guard !busy else { throw AppError.message("Another item operation is still running.") }
        guard item.id != target.id, item.flags & 1 != 0, section == 1 || item.flags & 2 != 0 else {
            throw AppError.message("macOS protects this item from that move.")
        }
        guard abs(item.frame.midY - target.frame.midY) < 2 else { throw AppError.message("Move items within the active display only.") }
        busy = true
        activityChanged?(true)
        defer { busy = false; activityChanged?(false) }
        try await ready()
        guard server.matches(item) else { throw AppError.message("The item changed owners or identity. Refresh the list and retry.") }
        guard let cursor = CGEvent(source: nil)?.location else { throw AppError.message("Unable to read the pointer position.") }
        let previousCursorProperty = server.cursorProperty()
        if previousCursorProperty != nil { server.setCursorProperty(true) }
        let hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer {
            CGWarpMouseCursorPosition(cursor)
            if hidden { CGDisplayShowCursor(CGMainDisplayID()) }
            if let previousCursorProperty { server.setCursorProperty(previousCursorProperty) }
        }
        let source = try source()
        let deadline = monotonicMilliseconds() + 2000
        var last: Error = AppError.message("The item could not be moved.")
        for attempt in 0..<5 {
            try Task.checkCancellation()
            guard monotonicMilliseconds() < deadline else { break }
            guard server.matches(item), server.matches(target) else { throw AppError.message("An item changed identity during movement.") }
            guard let initial = server.frame(item.id), let destination = server.frame(target.id) else { throw AppError.message("A menu-bar item disappeared.") }
            let adjacent = right ? abs(initial.minX - destination.maxX) < 1 : abs(initial.maxX - destination.minX) < 1
            if adjacent { return }
            let fallback = try Delivery.makeEvent(source: source, kind: 0, button: 1, point: CGPoint(x: initial.midX, y: initial.midY), window: item.id, pid: item.pid)
            do {
                let down = try Delivery.makeEvent(source: source, kind: 0, button: 0, point: CGPoint(x: 20000, y: 20000), window: item.id, pid: item.pid)
                try await Delivery().send(down, through: item.pid)
                try await changed(item.id, from: initial)
                guard let lifted = server.frame(item.id), let updatedTarget = server.frame(target.id) else { throw AppError.message("A menu-bar item disappeared during movement.") }
                let point = CGPoint(x: right ? updatedTarget.maxX : updatedTarget.minX, y: updatedTarget.midY)
                let up = try Delivery.makeEvent(source: source, kind: 0, button: 1, point: point, window: target.id, pid: item.pid)
                try await Delivery().send(up, through: item.pid)
                try await changed(item.id, from: lifted)
                if let current = server.frame(item.id), let dest = server.frame(target.id),
                   right ? abs(current.minX - dest.maxX) < 1 : abs(current.maxX - dest.minX) < 1 { return }
                throw AppError.message("macOS moved the item but not to the requested position.")
            } catch {
                fallback.post(tap: .cgSessionEventTap)
                last = error
                if error is CancellationError { throw error }
                if attempt < 4 { try await wake(item, source: source) }
            }
        }
        throw last
    }

    func click(_ item: BarItem, right: Bool) async throws {
        guard !busy else { throw AppError.message("Another item operation is still running.") }
        busy = true
        activityChanged?(true)
        defer { busy = false; activityChanged?(false) }
        try await ready()
        guard server.matches(item) else { throw AppError.message("The item changed owners or identity. Refresh the list and retry.") }
        guard let frame = server.frame(item.id), let cursor = CGEvent(source: nil)?.location,
              NSScreen.screens.contains(where: { screen in
                  guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                  return CGDisplayBounds(id.uint32Value).contains(CGPoint(x: frame.midX, y: frame.midY))
              }) else { throw AppError.message("Show the item on screen before clicking it.") }
        let source = try source()
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let down = try Delivery.makeEvent(source: source, kind: 1, button: right ? 2 : 0, point: point, window: item.id, pid: item.pid)
        let up = try Delivery.makeEvent(source: source, kind: 1, button: right ? 3 : 1, point: point, window: item.id, pid: item.pid)
        let hidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        defer { CGWarpMouseCursorPosition(cursor); if hidden { CGDisplayShowCursor(CGMainDisplayID()) } }
        do {
            try await Delivery().send(down)
            try await Delivery().send(up)
        } catch { up.post(tap: .cgSessionEventTap); throw error }
    }
}
