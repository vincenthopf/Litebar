import AppKit
import ApplicationServices
import ServiceManagement

private enum Input: UInt32 {
    case toggleHidden = 1, toggleAlways, hideAll, pointerEmpty, pointerBar, pointerOutside, clickEmpty, scrollShow, scrollHide, deadline,
         focusChanged, menuBegin, menuEnd, buttonDown, buttonUp, suspend, resume, showHidden, showAlways, smartRehide
}

private struct TemporaryItem: Codable {
    var identity: String
    var window: UInt32
    var anchorIdentity: String
    var anchor: UInt32
    var right: Bool
    var section: UInt32
    var space: UInt
    var interfaceWindow: UInt32?
    var attempts: Int = 0
}

@MainActor
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings: Settings
    let server = WindowServer()
    lazy var inventory = Inventory(server: server)
    lazy var actions = ItemActions(server: server)
    let hotkeys: Hotkeys
    private(set) var state = lb_initial_state()
    private(set) var icon: Divider?
    private(set) var hidden: Divider?
    private(set) var always: Divider?
    private var itemPanel: ItemPanel?
    private var settingsWindow: SettingsWindow?
    private var eventMonitor: Any?
    private var localMonitor: Any?
    private var monitoringMovement = false
    private var observations: [NSKeyValueObservation] = []
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var scheduledDeadline: UInt64 = 0
    private var temporaryTimer: Timer?
    private var delayedClick: Timer?
    private var temporary: [TemporaryItem] = []
    private var operation: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private var closing = false
    private var observingMenus = 0
    private var showingForDrag = false
    private var cachedFullscreen = false
    private var cachedMenuFrame: CGRect?
    private var cachedMenuScreen: NSScreen?
    private var menuFrameAt: UInt64 = 0
    private let validation: Bool
    private var ephemeralSuite: String?
    var onValidation: ((Controller) -> Void)?

    init(validation: Bool = false) {
        self.validation = validation
        if validation {
            let suite = "Litebar.Validation." + UUID().uuidString
            ephemeralSuite = suite
            settings = Settings(defaults: UserDefaults(suiteName: suite)!, migrate: false)
        } else { settings = Settings() }
        hotkeys = Hotkeys(defaults: settings.defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard lb_abi_version() == 1 else { fatalError("Incompatible Litebar core ABI") }
        NSApp.setActivationPolicy(.accessory)
        if !validation, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.jordanbaird.Ice" }) {
            let alert = NSAlert()
            alert.messageText = "Quit Ice before running Litebar."
            alert.informativeText = "Running two menu-bar managers at once can change divider positions. Litebar will not quit another app for you."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        icon = Divider(name: "SItem", position: 0, defaults: settings.defaults)
        hidden = Divider(name: "HItem", position: 1, defaults: settings.defaults)
        always = Divider(name: "AHItem", position: nil, defaults: settings.defaults)
        for control in [icon, hidden, always].compactMap({ $0 }) {
            control.status.button?.target = self
            control.status.button?.action = #selector(statusClicked)
            control.status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        icon?.status.button?.toolTip = "Litebar. Click to reveal, Option-click for always-hidden, right-click for settings."
        actions.activityChanged = { [weak self] active in
            guard let self else { return }
            if active { self.send(.menuBegin) }
            else { self.send(.menuEnd); self.inventory.invalidate() }
        }
        hotkeys.action = { [weak self] id in self?.shortcut(id) }
        if let data = settings.defaults.data(forKey: "LitebarTemporaryItems"), let restored = try? PropertyListDecoder().decode([TemporaryItem].self, from: data) {
            temporary = Array(restored.prefix(16))
        }
        cachedFullscreen = server.fullscreen
        if validation { state = lb_step(state, settings.config, 18, monotonicMilliseconds()) }
        render()
        if validation { onValidation?(self); return }
        observe()
        installMonitors()
        let errors = hotkeys.install()
        if !errors.isEmpty { report(AppError.message(errors.joined(separator: "\n"))) }
        if !settings.defaults.bool(forKey: "LitebarHasLaunched") {
            settings.defaults.set(true, forKey: "LitebarHasLaunched")
            openSettings()
        }
        if !temporary.isEmpty { openSettings(); report(AppError.message("Some temporarily moved items need restoring. Open Items and choose Restore temporary items.")) }
    }

    private func send(_ input: Input) {
        let before = state
        state = lb_step(state, settings.config, input.rawValue, monotonicMilliseconds())
        if before.revealed != state.revealed || before.panel != state.panel { render() }
        schedule()
        if !validation { installMonitors() }
    }

    private func render() {
        icon?.setVisible(settings.bool("ShowIceIcon"))
        icon?.resize(28, text: state.revealed == 0 ? "LB" : "‹")
        hidden?.resize(showingForDrag ? 20 : lb_hidden_length(state, settings.config), text: "|")
        always?.setVisible(settings.bool("EnableAlwaysHiddenSection"))
        always?.resize(showingForDrag ? 20 : lb_always_length(state, settings.config), text: "|")
        inventory.invalidate()
        if state.panel != 0 { presentItems(section: state.panel == 2 ? 4 : 2, activate: false) }
        else if state.revealed == 0 { itemPanel?.orderOut(nil) }
        if state.revealed == 0 && state.panel == 0 { restoreApplicationMenus() }
        else if state.revealed != 0 { makeRoomIfNeeded() }
    }

    private func schedule() {
        let next = lb_next_deadline(state)
        guard next != scheduledDeadline else { return }
        timer?.invalidate()
        timer = nil
        scheduledDeadline = next
        guard next != 0 else { return }
        let now = monotonicMilliseconds()
        let delay = Double(next > now ? next - now : 1) / 1000
        let value = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.scheduledDeadline = 0
                self.updatePointer()
                if NSEvent.pressedMouseButtons != 0 && self.state.buttons == 0 { self.send(.buttonDown) }
                self.send(.deadline)
            }
        }
        value.tolerance = min(0.02, delay / 10)
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }

    func settingsChanged() {
        settings.reload()
        state = lb_reconfigure(state, settings.config, monotonicMilliseconds())
        render()
        schedule()
        if !validation { installMonitors(force: true) }
        settingsWindow?.refresh()
    }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow(controller: self) }
        settingsWindow?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags.intersection([.command, .option, .control, .shift]) ?? []
        if event?.type == .rightMouseUp || flags == .control { showMenu(at: nil); return }
        updatePointer()
        if flags == .option && settings.bool("CanToggleAlwaysHiddenSection") { send(.toggleAlways) }
        else if sender === always?.status.button { send(.toggleAlways) }
        else { send(.toggleHidden) }
    }

    private func showMenu(at point: NSPoint?) {
        let menu = NSMenu(title: "Litebar")
        menu.delegate = self
        for (title, action) in [("Items and search…", #selector(openSearch)), ("Settings…", #selector(openSettings)),
            ("Toggle hidden section", #selector(toggleHidden)), ("Toggle always-hidden section", #selector(toggleAlways)),
            ("Restore temporary items", #selector(restoreRequested)), ("Releases…", #selector(openReleases)), ("Quit Litebar", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(toggleAlways) { item.isEnabled = settings.bool("EnableAlwaysHiddenSection") }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        if let point { menu.popUp(positioning: nil, at: point, in: nil) }
        else if let button = icon?.status.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
    }

    func menuWillOpen(_ menu: NSMenu) { observingMenus += 1; send(.menuBegin); hotkeys.suspend(true) }
    func menuDidClose(_ menu: NSMenu) {
        observingMenus = max(0, observingMenus - 1)
        if NSEvent.pressedMouseButtons == 0 {
            while state.buttons != 0 { send(.buttonUp) }
        }
        send(.menuEnd)
        if observingMenus == 0 { hotkeys.suspend(false) }
    }
    @objc private func toggleHidden() { updatePointer(); send(.toggleHidden) }
    @objc private func toggleAlways() { updatePointer(); send(.toggleAlways) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openReleases() {
        if let url = URL(string: "https://github.com/vincenthopf/Litebar/releases") { NSWorkspace.shared.open(url) }
    }
    @objc func openSearch() { presentItems(section: 0, activate: true) }
    func closeItems() { itemPanel?.orderOut(nil); send(.hideAll) }
    func panelClosed() { if state.panel != 0 { send(.hideAll) } }

    private var screen: NSScreen? {
        if cachedFullscreen { return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func presentItems(section: UInt32, activate: Bool) {
        if itemPanel == nil { itemPanel = ItemPanel(controller: self) }
        refreshItems(force: true)
        guard let panel = itemPanel, let screen else { return }
        panel.setItems(displayItems, section: section)
        let location = settings.defaults.integer(forKey: "IceBarLocation")
        let iconX = icon?.status.button?.window?.frame.midX ?? screen.frame.midX
        let center = location == 2 ? iconX : location == 1 ? NSEvent.mouseLocation.x : activate ? screen.frame.midX : iconX
        let x = max(screen.visibleFrame.minX, min(center - panel.frame.width / 2, screen.visibleFrame.maxX - panel.frame.width))
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: screen.visibleFrame.maxY - 6))
        panel.orderFrontRegardless()
        if activate { panel.makeKey(); panel.makeFirstResponder(panel.search) }
    }

    var displayItems: [BarItem] {
        inventory.items.filter { $0.pid != getpid() }.map { item in
            var value = item
            if let pending = temporary.first(where: { $0.window == item.id && $0.identity == item.identity }) { value.section = pending.section }
            return value
        }
    }

    func refreshItems(force: Bool) {
        inventory.refresh(hiddenID: hidden?.windowID, alwaysID: settings.bool("EnableAlwaysHiddenSection") ? always?.windowID : nil, force: force)
        let message = server.available ? "Double-click to open. Drag rows or choose a section to move. \(temporary.count) temporary item(s)." : "Private WindowServer APIs are unavailable. Basic hiding still works."
        itemPanel?.setItems(displayItems, message: message)
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            watch(workspace, name) { [weak self] in
                guard let self else { return }
                self.cachedFullscreen = self.server.fullscreen
                self.menuFrameAt = 0
                self.inventory.invalidate()
                self.updatePointer()
            }
        }
        watch(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            guard let self else { return }
            self.inventory.invalidate()
            self.menuFrameAt = 0
            self.updatePointer()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() { self.send(.focusChanged) }
            self.settingsWindow?.refresh()
        }
        watch(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.operation?.cancel(); self?.send(.suspend); self?.stopMonitors(); self?.temporaryTimer?.invalidate(); self?.inventory.clear()
        }
        watch(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.send(.resume); self?.inventory.invalidate(); self?.installMonitors(force: true)
        }
        watch(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.operation?.cancel(); self?.send(.hideAll); self?.inventory.invalidate()
        }
        if let window = hidden?.status.button?.window {
            observations.append(window.observe(\.frame, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.inventory.invalidate(); self?.updatePointer() }
            })
        }
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        tokens.append((center, token))
    }

    private func stopMonitors() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        eventMonitor = nil
        localMonitor = nil
    }

    private func installMonitors(force: Bool = false) {
        guard !closing, state.suspended == 0 else { return }
        let movement = settings.bool("ShowOnHover") || state.revealed != 0 || state.panel != 0
        guard force || eventMonitor == nil || movement != monitoringMovement else { return }
        stopMonitors()
        monitoringMovement = movement
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged]
        if movement { mask.insert(.mouseMoved) }
        if settings.bool("ShowOnScroll") { mask.insert(.scrollWheel) }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in MainActor.assumeIsolated { self?.input(event) } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in MainActor.assumeIsolated { self?.input(event) }; return event }
    }

    private func menuFrame(on screen: NSScreen, force: Bool = false) -> CGRect? {
        let now = monotonicMilliseconds()
        if force || screen != cachedMenuScreen || now &- menuFrameAt >= 500 {
            cachedMenuFrame = Accessibility.applicationMenuFrame(screen: screen)
            cachedMenuScreen = screen
            menuFrameAt = now
        }
        return cachedMenuFrame
    }

    private func updatePointer() {
        guard let screen else { return }
        let appkit = NSEvent.mouseLocation
        if let panel = itemPanel, panel.isVisible, panel.frame.insetBy(dx: -10, dy: -10).contains(appkit) { send(.pointerBar); return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: appkit.x, y: top - appkit.y)
        var inside = appkit.y > screen.visibleFrame.maxY && appkit.y <= screen.frame.maxY && appkit.x >= screen.frame.minX && appkit.x < screen.frame.maxX
        if cachedFullscreen || NSApp.currentSystemPresentationOptions.contains(.autoHideMenuBar) || NSApp.currentSystemPresentationOptions.contains(.hideMenuBar) {
            if let frame = hidden?.status.button?.window?.frame { inside = appkit.y >= frame.minY && appkit.y < frame.maxY && appkit.x >= screen.frame.minX && appkit.x < screen.frame.maxX }
            else { inside = false }
        }
        guard inside else { send(.pointerOutside); return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, appkit.x >= left.maxX && appkit.x < right.minX { send(.pointerBar); return }
        guard settings.bool("ShowOnHover") || settings.bool("ShowOnClick") || settings.bool("ShowContextMenuOnRightClick") else { send(.pointerBar); return }
        inventory.refresh(hiddenID: hidden?.windowID, alwaysID: settings.bool("EnableAlwaysHiddenSection") ? always?.windowID : nil)
        let overControl = [icon, hidden, always].compactMap { $0 }.contains { $0.status.isVisible && $0.status.length < 10000 && $0.status.button?.window?.frame.contains(appkit) == true }
        if overControl || inventory.items.contains(where: { $0.onScreen && $0.pid != getpid() && $0.frame.contains(point) }) {
            send(.pointerBar); return
        }
        guard let menu = menuFrame(on: screen), point.x > menu.maxX else { send(.pointerBar); return }
        send(.pointerEmpty)
    }

    private func input(_ event: NSEvent) {
        guard !actions.busy, !closing else { return }
        updatePointer()
        switch event.type {
        case .mouseMoved: break
        case .leftMouseDragged:
            if event.modifierFlags.contains(.command), state.pointer != 0, settings.bool("ShowAllSectionsOnUserDrag") {
                showingForDrag = true
                send(settings.bool("EnableAlwaysHiddenSection") ? .showAlways : .showHidden)
                render()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            send(.buttonDown)
            if event.type == .rightMouseDown && state.pointer == 2 && settings.bool("ShowContextMenuOnRightClick") { showMenu(at: NSEvent.mouseLocation) }
            if event.type == .leftMouseDown && state.pointer == 2 {
                let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
                if flags == .control { showMenu(at: NSEvent.mouseLocation) }
                else if flags == .option && settings.bool("CanToggleAlwaysHiddenSection") { send(.toggleAlways) }
                else { send(.clickEmpty) }
            }
            if event.type == .leftMouseDown && state.pointer == 0 && (state.revealed != 0 || state.panel != 0) {
                scheduleSmartRehide(point: event.cgEvent?.location, initialSpace: server.activeSpace)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            send(.buttonUp)
            if showingForDrag { showingForDrag = false; render(); inventory.invalidate() }
        case .scrollWheel:
            let delta = (event.scrollingDeltaX + event.scrollingDeltaY) / 2
            if delta > 5 { send(.scrollShow) } else if delta < -5 { send(.scrollHide) }
        default: break
        }
    }

    private func scheduleSmartRehide(point: CGPoint?, initialSpace: UInt?) {
        delayedClick?.invalidate()
        let value = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delayedClick = nil
                if self.server.activeSpace != initialSpace { self.send(.smartRehide); return }
                guard let point, let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0) as? [[String: Any]] else { return }
                let window = windows.first { value in
                    guard let layer = value[kCGWindowLayer as String] as? Int, layer < Int(CGWindowLevelForKey(.cursorWindow)),
                          let bounds = value[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                          value[kCGWindowName as String] as? String != "" else { return false }
                    return frame.contains(point)
                }
                guard let pid = window?[kCGWindowOwnerPID as String] as? pid_t, let app = NSRunningApplication(processIdentifier: pid) else { return }
                if app.bundleIdentifier == "com.apple.dock" || (app.isActive && app.activationPolicy == .regular && pid != getpid()) { self.send(.smartRehide) }
            }
        }
        delayedClick = value
        RunLoop.main.add(value, forMode: .common)
    }

    private func makeRoomIfNeeded() {
        guard !validation, settings.bool("HideApplicationMenus"), !server.fullscreen, settingsWindow?.isVisible != true,
              !NSApp.currentSystemPresentationOptions.contains(.autoHideMenuBar), let screen,
              let menu = Accessibility.applicationMenuFrame(screen: screen) else { return }
        refreshItems(force: true)
        let visible = inventory.items.filter { $0.pid != getpid() && ($0.section & 1 != 0 || state.revealed & 2 != 0 || $0.section & 2 != 0) }
        if let first = visible.min(by: { $0.frame.minX < $1.frame.minX }), first.frame.minX <= menu.maxX { hideApplicationMenus() }
    }

    private func hideApplicationMenus() {
        guard previousApplication == nil else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = NSMenu(title: "Litebar")
        NSApp.activate(ignoringOtherApps: true)
    }
    private func restoreApplicationMenus() {
        guard let app = previousApplication else { return }
        previousApplication = nil
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), !app.isTerminated { app.activate(options: []) }
        NSApp.setActivationPolicy(.accessory)
    }
    private func shortcut(_ id: UInt32) {
        switch id {
        case 0: toggleHidden()
        case 1: toggleAlways()
        case 2: if itemPanel?.isVisible == true { closeItems() } else { openSearch() }
        case 3: settings.toggle("UseIceBar"); settingsChanged()
        case 4: settings.toggle("ShowSectionDividers"); settingsChanged()
        case 5: if previousApplication == nil { hideApplicationMenus() } else { restoreApplicationMenus() }
        default: break
        }
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        guard operation == nil, !closing else { report(AppError.message("Another operation is still running.")); return }
        operation = Task { [weak self] in
            defer { self?.operation = nil; self?.refreshItems(force: true) }
            do { try await body() } catch is CancellationError { } catch { self?.report(error) }
        }
    }

    func rearrange(_ id: UInt32, target: UInt32, right: Bool, section: UInt32) {
        perform { [self] in
            guard !server.fullscreen, !NSApp.currentSystemPresentationOptions.contains(.autoHideMenuBar) else {
                throw AppError.message("Turn off automatic menu-bar hiding and leave full screen before arranging items.")
            }
            refreshItems(force: true)
            guard let item = inventory.items.first(where: { $0.id == id }), let destination = inventory.items.first(where: { $0.id == target }), section != 0 else {
                throw AppError.message("Refresh the item list before moving this item.")
            }
            try await actions.move(item, beside: destination, right: right, section: section & 1 != 0 ? 1 : section & 2 != 0 ? 2 : 4)
            temporary.removeAll { $0.window == id }
            persistTemporary()
        }
    }

    func moveToSection(_ id: UInt32, section: UInt32) {
        refreshItems(force: true)
        let divider = section == 4 ? always?.windowID : hidden?.windowID
        guard section != 4 || settings.bool("EnableAlwaysHiddenSection"), let divider else { report(AppError.message("Enable the target section first.")); return }
        rearrange(id, target: divider, right: section == 1, section: section)
    }

    func openItem(_ id: UInt32, right: Bool) {
        perform { [self] in
            refreshItems(force: true)
            guard let item = inventory.items.first(where: { $0.id == id }) else { throw AppError.message("The item no longer exists.") }
            itemPanel?.orderOut(nil)
            defer { armTemporaryTimer() }
            let physicalFrame = server.frame(item.id)
            let displayBounds = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayBounds($0.uint32Value) } }
            let visible = item.onScreen && physicalFrame.map { frame in displayBounds.contains { $0.contains(frame) } } == true
            if !visible {
                guard temporary.count < 16, let screen, let space = server.activeSpace,
                      let menu = Accessibility.applicationMenuFrame(screen: screen), let index = inventory.items.firstIndex(where: { $0.id == id }) else {
                    throw AppError.message("Unable to safely determine a temporary position for the item.")
                }
                let others = inventory.items
                let anchor: BarItem
                let returnRight: Bool
                if others.indices.contains(index + 1) { anchor = others[index + 1]; returnRight = false }
                else if index > 0 { anchor = others[index - 1]; returnRight = true }
                else { throw AppError.message("No stable anchor exists for returning the item.") }
                let safeX = max(menu.maxX, screen.auxiliaryTopRightArea.map { $0.minX + 20 } ?? menu.maxX)
                guard let target = others.first(where: { $0.id != id && $0.onScreen && $0.section & 1 != 0 && $0.frame.minX - item.frame.width > safeX }) else {
                    throw AppError.message("There is not enough room beside the visible items to open this item.")
                }
                let context = TemporaryItem(identity: item.identity, window: item.id, anchorIdentity: anchor.identity, anchor: anchor.id,
                                             right: returnRight, section: item.section, space: space)
                temporary.append(context)
                persistTemporary()
                do { try await actions.move(item, beside: target, right: false, section: 1) }
                catch { armTemporaryTimer(); throw error }
            }
            let before = Set(onScreenWindows().compactMap { $0[kCGWindowNumber as String] as? UInt32 })
            try await actions.click(item, right: right)
            try await Task.sleep(nanoseconds: 100_000_000)
            let opened = onScreenWindows().first { $0[kCGWindowOwnerPID as String] as? pid_t == item.pid && !before.contains($0[kCGWindowNumber as String] as? UInt32 ?? 0) }
            if let index = temporary.firstIndex(where: { $0.window == id }) {
                temporary[index].interfaceWindow = opened?[kCGWindowNumber as String] as? UInt32
                persistTemporary()
            }
        }
    }

    private func onScreenWindows() -> [[String: Any]] { CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0) as? [[String: Any]] ?? [] }
    private func persistTemporary() { settings.defaults.set(try? PropertyListEncoder().encode(temporary), forKey: "LitebarTemporaryItems") }
    private func armTemporaryTimer(_ interval: TimeInterval? = nil) {
        temporaryTimer?.invalidate()
        temporaryTimer = nil
        guard !temporary.isEmpty, temporary.contains(where: { $0.attempts < 3 }), !closing else { return }
        let value = Timer(timeInterval: interval ?? settings.temporaryInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.temporaryTimer = nil; self?.restoreRequested() }
        }
        value.tolerance = 0.25
        temporaryTimer = value
        RunLoop.main.add(value, forMode: .common)
    }

    @objc func restoreRequested() {
        if actions.busy || operation != nil { armTemporaryTimer(3); return }
        perform { [self] in try await restoreTemporary() }
    }
    private func restoreTemporary() async throws {
        guard !temporary.isEmpty else { return }
        if NSEvent.pressedMouseButtons != 0 { armTemporaryTimer(3); return }
        let windows = onScreenWindows()
        if temporary.contains(where: { pending in pending.interfaceWindow.map { id in windows.contains { $0[kCGWindowNumber as String] as? UInt32 == id } } ?? false }) {
            armTemporaryTimer(3); return
        }
        refreshItems(force: true)
        var remaining: [TemporaryItem] = []
        var failed = false
        for var context in temporary.reversed() {
            guard server.activeSpace == context.space else { remaining.append(context); continue }
            let matches = inventory.items.filter { $0.identity == context.identity }
            let anchors = inventory.items.filter { $0.identity == context.anchorIdentity }
            let item = matches.first(where: { $0.id == context.window }) ?? (matches.count == 1 ? matches.first : nil)
            let anchor = anchors.first(where: { $0.id == context.anchor }) ?? (anchors.count == 1 ? anchors.first : nil)
            guard let item else { continue }
            guard let anchor else { context.attempts = 3; remaining.append(context); failed = true; continue }
            do { try await actions.move(item, beside: anchor, right: context.right, section: context.section & 4 != 0 ? 4 : 2) }
            catch { context.attempts += 1; remaining.append(context); failed = true }
        }
        temporary = Array(remaining.reversed())
        persistTemporary()
        if temporary.contains(where: { $0.attempts >= 3 }) { throw AppError.message("A temporary item could not be restored. Refresh the list and use Move to return it. Automatic retries have stopped.") }
        if failed { armTemporaryTimer(3) }
    }

    func applySpacing(_ offset: Int) {
        let alert = NSAlert()
        alert.messageText = "Apply system-wide menu-bar spacing?"
        alert.informativeText = "Other apps will use the new spacing after they next launch or you next log in. No other apps will be quit."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let offset = max(-15, min(16, offset))
        for key in ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"] {
            CFPreferencesSetValue(key as CFString, offset == 0 ? nil : NSNumber(value: 16 + offset), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) else {
            report(AppError.message("macOS could not save the spacing preferences.")); return
        }
        settings.defaults.set(offset, forKey: "ItemSpacingOffset")
    }

    func report(_ error: Error) {
        itemPanel?.status.stringValue = error.localizedDescription
        if validation { fputs(error.localizedDescription + "\n", stderr); return }
        let alert = NSAlert(error: error)
        if let window = settingsWindow, window.isVisible { alert.beginSheetModal(for: window) }
        else if let panel = itemPanel, panel.isVisible { alert.beginSheetModal(for: panel) }
        else { alert.runModal() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openSettings(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !closing else { return .terminateNow }
        guard operation != nil || !temporary.isEmpty else { return .terminateNow }
        closing = true
        let task = operation
        task?.cancel()
        Task {
            await task?.value
            do { try await restoreTemporary() } catch { report(error) }
            if !temporary.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Some temporary items are still out of place."
                alert.informativeText = "Cancel to restore them using the item list, or quit and keep the recovery record for next launch."
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit")
                if alert.runModal() == .alertFirstButtonReturn { closing = false; sender.reply(toApplicationShouldTerminate: false); return }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { stop() }
    func stop() {
        closing = true
        timer?.invalidate()
        temporaryTimer?.invalidate()
        delayedClick?.invalidate()
        stopMonitors()
        hotkeys.stop()
        observations.removeAll()
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        restoreApplicationMenus()
        for control in [icon, hidden, always].compactMap({ $0 }) { control.remove() }
        icon = nil; hidden = nil; always = nil
        inventory.clear()
        if let ephemeralSuite { settings.defaults.removePersistentDomain(forName: ephemeralSuite) }
    }
}
