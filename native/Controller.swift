import AppKit
import ApplicationServices
import ServiceManagement

private enum Input: UInt32 {
    case toggleHidden = 1, toggleAlways, hideAll, pointerEmpty, pointerBar, pointerOutside, clickEmpty, scrollShow, scrollHide, deadline,
         focusChanged, menuBegin, menuEnd, buttonDown, buttonUp, suspend, resume, showHidden, showAlways, smartRehide, preventHover, userDragBegin
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
    private var lastError: String?
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
    private var layoutTimer: Timer?
    private var repairTimer: Timer?
    private var hoverClickTimer: Timer?
    private var temporary: [TemporaryItem] = []
    private var recoveryAvailable = true
    private var recoveryFile: URL {
        if let ephemeralSuite {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(ephemeralSuite).appendingPathComponent("recovery.plist")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("com.vincenthopf.Litebar").appendingPathComponent("recovery.plist")
    }
    private var operation: Task<Void, Never>?
    private var ownerRefresh: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private var closing = false
    private var observingMenus = 0
    private var showingForDrag = false
    private var cachedFullscreen = false
    private var cachedMenuFrame: CGRect?
    private var cachedMenuScreen: NSScreen?
    private var menuFrameAt: UInt64 = 0
    private let validation: Bool
    private let benchmark: Bool
    private var ephemeralSuite: String?
    var onValidation: ((Controller) -> Void)?
    var onBenchmark: ((Controller) -> Void)?
    var activeTimerCount: Int { [timer, temporaryTimer, delayedClick, layoutTimer, repairTimer, hoverClickTimer].compactMap { $0 }.filter(\.isValid).count }
    var monitorsMovement: Bool { monitoringMovement && eventMonitor != nil }

    init(validation: Bool = false, benchmark: Bool = false) {
        self.validation = validation
        self.benchmark = benchmark
        if validation || benchmark {
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
        if !validation && !benchmark, NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.jordanbaird.Ice" || ($0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid()) }) {
            let alert = NSAlert()
            alert.messageText = "Another menu-bar manager is already running."
            alert.informativeText = "Running two menu-bar managers at once can change divider positions. Litebar will not quit another app for you."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        icon = Divider(name: "SItem", position: 0, defaults: settings.defaults, persistent: !validation && !benchmark)
        hidden = Divider(name: "HItem", position: 1, defaults: settings.defaults, persistent: !validation && !benchmark)
        always = Divider(name: "AHItem", position: nil, defaults: settings.defaults, persistent: !validation && !benchmark)
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
        do { try loadTemporary() }
        catch { recoveryAvailable = false; report(error) }
        cachedFullscreen = server.fullscreen
        if validation { state = lb_step(state, settings.config, 18, monotonicMilliseconds()) }
        render()
        if validation { onValidation?(self); return }
        observe()
        installMonitors()
        let errors = hotkeys.install()
        if !errors.isEmpty { report(AppError.message(errors.joined(separator: "\n"))) }
        if !benchmark && (!settings.defaults.bool(forKey: "LitebarHasLaunched") || !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess()) {
            settings.defaults.set(true, forKey: "LitebarHasLaunched")
            openSettings()
        }
        if !temporary.isEmpty { openSettings(); report(AppError.message("Some temporarily moved items need restoring. Open Items and choose Restore temporary items.")) }
        scheduleDividerRepair()
        if benchmark { onBenchmark?(self) }
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
        icon?.resize(28, text: "LB")
        hidden?.resize(showingForDrag ? 150 : lb_hidden_length(state, settings.config), text: showingForDrag ? "Hidden | Visible" : "|")
        always?.setVisible(settings.bool("EnableAlwaysHiddenSection"))
        always?.resize(showingForDrag ? 150 : lb_always_length(state, settings.config), text: showingForDrag ? "Always-hidden | Hidden" : "|")
        inventory.invalidate()
        if state.panel != 0 { presentItems(section: state.panel == 2 ? 4 : 2, activate: false) }
        else if itemPanel?.isVisible == true { releaseItems() }
        if state.revealed == 0 && state.panel == 0 { restoreApplicationMenus() }
        else if state.revealed != 0 { scheduleLayoutCheck() }
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
        if !settings.bool("HideApplicationMenus") { restoreApplicationMenus() }
        state = lb_reconfigure(state, settings.config, monotonicMilliseconds())
        render()
        schedule()
        if !validation { installMonitors(force: true) }
        settingsWindow?.refresh()
        scheduleDividerRepair()
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
        send(.preventHover)
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

    func menuWillOpen(_ menu: NSMenu) { observingMenus += 1; send(.menuBegin); hotkeys.suspend(true, reason: 1) }
    func menuDidClose(_ menu: NSMenu) {
        observingMenus = max(0, observingMenus - 1)
        if NSEvent.pressedMouseButtons == 0 {
            while state.buttons != 0 { send(.buttonUp) }
        }
        send(.menuEnd)
        if observingMenus == 0 { hotkeys.suspend(false, reason: 1) }
    }
    @objc private func toggleHidden() { updatePointer(); send(.toggleHidden); send(.preventHover) }
    @objc private func toggleAlways() { updatePointer(); send(.toggleAlways); send(.preventHover) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openReleases() {
        if let url = URL(string: "https://github.com/vincenthopf/Litebar/releases") { NSWorkspace.shared.open(url) }
    }
    @objc func openSearch() { presentItems(section: 0, activate: true) }
    private func releaseItems() {
        guard let panel = itemPanel else { return }
        itemPanel = nil
        panel.controller = nil
        panel.close()
    }
    func closeItems() { releaseItems(); send(.hideAll) }
    func panelClosed() { itemPanel = nil; if state.panel != 0 { send(.hideAll) } }
    func settingsClosed() { settingsWindow = nil }

    private var screen: NSScreen? {
        if let frame = icon?.windowID.flatMap(server.frame),
           let hosted = NSScreen.screens.first(where: { candidate in
               guard let number = candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
               return CGDisplayBounds(number.uint32Value).contains(CGPoint(x: frame.midX, y: frame.midY))
           }) { return hosted }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
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
        let ownWindows = [icon?.windowID, hidden?.windowID, always?.windowID].compactMap { $0 }
        return inventory.items.filter { $0.pid != getpid() && !ownWindows.contains($0.id) }.map { item in
            var value = item
            if let pending = temporary.first(where: { $0.window == item.id && $0.identity == item.identity }) { value.section = pending.section }
            return value
        }
    }

    func refreshItems(force: Bool) {
        inventory.refresh(hiddenID: hidden?.windowID, alwaysID: settings.bool("EnableAlwaysHiddenSection") ? always?.windowID : nil, force: force)
        let message = inventory.reliable ? "Double-click to open. Drag rows or choose a section to move. \(temporary.count) temporary item(s)." : "The item inventory is unavailable. Refresh after granting access or switching back to the original desktop. Basic hiding still works."
        itemPanel?.setItems(displayItems, message: lastError ?? message)
        if ownerRefresh == nil {
            ownerRefresh = Task { [weak self] in
                guard let self else { return }
                await self.inventory.resolveOwners(force: force)
                self.ownerRefresh = nil
                guard !Task.isCancelled, !self.closing else { return }
                self.itemPanel?.setItems(self.displayItems, message: self.lastError ?? message)
            }
        }
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            watch(workspace, name) { [weak self] in
                guard let self else { return }
                if name == NSWorkspace.activeSpaceDidChangeNotification { self.operation?.cancel() }
                self.cachedFullscreen = self.server.fullscreen
                self.menuFrameAt = 0
                self.inventory.invalidate()
                self.updatePointer()
                self.armTemporaryTimer(3)
                self.scheduleDividerRepair()
            }
        }
        watch(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            guard let self else { return }
            self.cachedFullscreen = self.server.fullscreen
            self.inventory.invalidate()
            self.menuFrameAt = 0
            self.updatePointer()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() { self.send(.focusChanged) }
            else { self.scheduleDividerRepair() }
            if self.settingsWindow?.isVisible == true { self.settingsWindow?.refresh() }
            self.armTemporaryTimer(3)
        }
        watch(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            guard let self else { return }
            self.operation?.cancel()
            self.send(.suspend)
            self.stopMonitors()
            self.cancelAuxiliaryTimers()
            self.inventory.clear()
        }
        watch(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            self.cachedFullscreen = self.server.fullscreen
            self.menuFrameAt = 0
            self.send(.resume)
            self.inventory.invalidate()
            self.installMonitors(force: true)
            self.armTemporaryTimer(3)
            self.scheduleDividerRepair()
        }
        watch(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }
            self.operation?.cancel()
            self.cancelAuxiliaryTimers()
            self.cachedFullscreen = self.server.fullscreen
            self.cachedMenuScreen = nil
            self.menuFrameAt = 0
            self.send(.hideAll)
            self.inventory.invalidate()
            self.armTemporaryTimer(3)
            self.scheduleDividerRepair()
        }
        if let window = hidden?.status.button?.window {
            observations.append(window.observe(\.frame, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inventory.invalidate()
                    self.menuFrameAt = 0
                    if self.cachedFullscreen && self.settings.bool("ShowOnHover") && !self.closing {
                        self.updatePointer()
                    }
                }
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
        let movement = settings.bool("ShowOnHover") || state.revealed != 0 || state.panel != 0 || NSEvent.modifierFlags.contains(.command)
        guard force || eventMonitor == nil || movement != monitoringMovement else { return }
        stopMonitors()
        monitoringMovement = movement
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .flagsChanged]
        if movement { mask.insert(.mouseMoved) }
        if settings.bool("ShowOnScroll") { mask.insert(.scrollWheel) }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in MainActor.assumeIsolated { self?.input(event) } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in MainActor.assumeIsolated { self?.input(event) }; return event }
    }

    private func menuFrame(on screen: NSScreen, force: Bool = false) -> CGRect? {
        let now = monotonicMilliseconds()
        if force || menuFrameAt == 0 || screen != cachedMenuScreen || now &- menuFrameAt >= 2000 {
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
        let hostedFrame = icon?.windowID.flatMap(server.frame) ?? hidden?.windowID.flatMap(server.frame)
        let inside = hostedFrame.map { point.y >= $0.minY && point.y < $0.maxY && appkit.x >= screen.frame.minX && appkit.x < screen.frame.maxX } ?? false
        guard inside else { send(.pointerOutside); return }
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, appkit.x >= left.maxX && appkit.x < right.minX { send(.pointerBar); return }
        guard settings.bool("ShowOnHover") || settings.bool("ShowOnClick") || settings.bool("ShowContextMenuOnRightClick") else { send(.pointerBar); return }
        inventory.refresh(hiddenID: hidden?.windowID, alwaysID: settings.bool("EnableAlwaysHiddenSection") ? always?.windowID : nil)
        let overControl = [icon, hidden, always].compactMap { $0 }.contains { $0.status.isVisible && $0.status.length < 10000 && $0.status.button?.window?.frame.contains(appkit) == true }
        if !inventory.reliable || overControl || inventory.items.contains(where: { $0.onScreen && $0.pid != getpid() && $0.frame.contains(point) }) {
            send(.pointerBar); return
        }
        guard let menu = menuFrame(on: screen), point.x > menu.maxX else { send(.pointerBar); return }
        send(.pointerEmpty)
    }

    private func input(_ event: NSEvent) {
        guard !actions.busy, !closing else { return }
        updatePointer()
        if settings.bool("ShowAllSectionsOnUserDrag"), event.modifierFlags.contains(.command), state.pointer != 0, !showingForDrag,
           [.flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseDragged].contains(event.type) {
            showingForDrag = true
            send(.userDragBegin)
            render()
        }
        switch event.type {
        case .flagsChanged:
            if showingForDrag && !event.modifierFlags.contains(.command) { showingForDrag = false; render() }
            installMonitors()
        case .mouseMoved, .leftMouseDragged: break
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if state.pointer != 0 { send(.preventHover) }
            send(.buttonDown)
            if event.type == .rightMouseDown && state.pointer == 2 && settings.bool("ShowContextMenuOnRightClick") { showMenu(at: NSEvent.mouseLocation) }
            if event.type == .leftMouseDown && state.pointer == 2 {
                let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
                if flags == .control { showMenu(at: NSEvent.mouseLocation) }
                else if flags == .option && settings.bool("CanToggleAlwaysHiddenSection") { scheduleEmptyClick(always: true) }
                else if settings.bool("ShowOnClick") { scheduleEmptyClick(always: false) }
            }
            if event.type == .leftMouseDown && state.pointer == 0 && settings.bool("AutoRehide") && settings.config.rehide_strategy == 0 && (state.revealed != 0 || state.panel != 0) {
                scheduleSmartRehide(point: event.cgEvent?.location, initialSpace: server.activeSpace)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            send(.buttonUp)
            if showingForDrag { showingForDrag = false; render(); inventory.invalidate(); scheduleDividerRepair() }
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
                          let title = value[kCGWindowName as String] as? String, !title.isEmpty else { return false }
                    return frame.contains(point)
                }
                guard let pid = window?[kCGWindowOwnerPID as String] as? pid_t, let app = NSRunningApplication(processIdentifier: pid) else { return }
                if app.bundleIdentifier == "com.apple.dock" || (app.isActive && app.activationPolicy == .regular && pid != getpid()) { self.send(.smartRehide) }
            }
        }
        delayedClick = value
        RunLoop.main.add(value, forMode: .common)
    }

    private func scheduleEmptyClick(always: Bool) {
        hoverClickTimer?.invalidate()
        let value = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.suspended == 0, !self.closing else { return }
                self.hoverClickTimer = nil
                self.send(always ? .toggleAlways : .toggleHidden)
                self.send(.preventHover)
            }
        }
        hoverClickTimer = value
        RunLoop.main.add(value, forMode: .common)
    }

    private func scheduleLayoutCheck() {
        guard !validation, state.suspended == 0, !closing else { return }
        layoutTimer?.invalidate()
        let value = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutTimer = nil
                self.cachedFullscreen = self.server.fullscreen
                if self.state.revealed != 0 { self.makeRoomIfNeeded() }
            }
        }
        layoutTimer = value
        RunLoop.main.add(value, forMode: .common)
    }

    private func scheduleDividerRepair() {
        guard !validation, !closing, state.suspended == 0, AXIsProcessTrusted(), settings.bool("EnableAlwaysHiddenSection") else { return }
        repairTimer?.invalidate()
        let value = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repairTimer = nil
                guard self.operation == nil, !self.actions.busy, NSEvent.pressedMouseButtons == 0,
                      let hiddenID = self.hidden?.windowID, let alwaysID = self.always?.windowID else { return }
                self.refreshItems(force: true)
                guard let hidden = self.inventory.items.first(where: { $0.id == hiddenID }),
                      let always = self.inventory.items.first(where: { $0.id == alwaysID }),
                      hidden.frame.maxX <= always.frame.minX else { return }
                self.perform { try await self.actions.move(always, beside: hidden, right: false, section: 2) }
            }
        }
        repairTimer = value
        RunLoop.main.add(value, forMode: .common)
    }

    private func cancelAuxiliaryTimers() {
        temporaryTimer?.invalidate(); temporaryTimer = nil
        delayedClick?.invalidate(); delayedClick = nil
        layoutTimer?.invalidate(); layoutTimer = nil
        repairTimer?.invalidate(); repairTimer = nil
        hoverClickTimer?.invalidate(); hoverClickTimer = nil
    }

    private func makeRoomIfNeeded() {
        guard !validation, settings.bool("HideApplicationMenus"), !server.fullscreen, settingsWindow?.isVisible != true,
              !NSApp.currentSystemPresentationOptions.contains(.autoHideMenuBar), let screen,
              let menu = Accessibility.applicationMenuFrame(screen: screen) else { return }
        refreshItems(force: true)
        let owned = [icon?.windowID, hidden?.windowID, always?.windowID].compactMap { $0 }
        let visible = inventory.items.filter { $0.pid != getpid() && !owned.contains($0.id) && $0.section != 0 && ($0.section & 1 != 0 || state.revealed & 2 != 0 || $0.section & 2 != 0) }
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

    private func perform(interactive: Bool = true, _ body: @escaping @MainActor () async throws -> Void) {
        guard operation == nil, !closing else { report(AppError.message("Another operation is still running.")); return }
        lastError = nil
        operation = Task { [weak self] in
            defer { self?.operation = nil; self?.refreshItems(force: true) }
            do { try await body() }
            catch is CancellationError { }
            catch { self?.report(error, interactive: interactive) }
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
            let sameIdentityCount = inventory.items.filter { $0.identity == item.identity }.count
            temporary.removeAll { $0.window == id || ($0.identity == item.identity && sameIdentityCount == 1) }
            try persistTemporary()
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
            releaseItems()
            defer { armTemporaryTimer() }
            let physicalFrame = server.frame(item.id)
            let visible = physicalFrame.map { visibleForClick($0) } == true
            if !visible {
                guard recoveryAvailable, temporary.count < 16, let screen, let space = server.activeSpace,
                      let menu = Accessibility.applicationMenuFrame(screen: screen), item.section != 0,
                      !temporary.contains(where: { $0.identity == item.identity && $0.window == item.id }) else {
                    throw AppError.message("Unable to safely determine a temporary position for the item.")
                }
                let others = inventory.items.filter { $0.section != 0 }
                guard let index = others.firstIndex(where: { $0.id == id }) else { throw AppError.message("The item is not on the active display.") }
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
                try persistTemporary()
                do { try await actions.move(item, beside: target, right: false, section: 1) }
                catch { armTemporaryTimer(); throw error }
            }
            let before = Set(onScreenWindows().compactMap { $0[kCGWindowNumber as String] as? UInt32 })
            guard let currentFrame = server.frame(item.id), visibleForClick(currentFrame) else { throw AppError.message("The item is obscured by the notch or application menus. Reveal it or make more room first.") }
            try await actions.click(item, right: right)
            try await Task.sleep(nanoseconds: 100_000_000)
            let opened = onScreenWindows().first { $0[kCGWindowOwnerPID as String] as? pid_t == item.pid && !before.contains($0[kCGWindowNumber as String] as? UInt32 ?? 0) }
            if let index = temporary.firstIndex(where: { $0.window == id }) {
                temporary[index].interfaceWindow = opened?[kCGWindowNumber as String] as? UInt32
                try persistTemporary()
            }
        }
    }

    private func visibleForClick(_ frame: CGRect) -> Bool {
        guard let screen, let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let menu = menuFrame(on: screen, force: true), let delimiter = hidden?.windowID.flatMap(server.frame),
              abs(frame.midY - delimiter.midY) < 2, CGDisplayBounds(number.uint32Value).contains(frame),
              frame.minX >= menu.maxX else { return false }
        if let right = screen.auxiliaryTopRightArea { return frame.minX >= right.minX }
        return true
    }

    private func onScreenWindows() -> [[String: Any]] { CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0) as? [[String: Any]] ?? [] }
    private func loadTemporary() throws {
        let data: Data?
        if FileManager.default.fileExists(atPath: recoveryFile.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: recoveryFile.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 1024 * 1024 else { throw AppError.message("The recovery journal is too large. It was not modified.") }
            data = try Data(contentsOf: recoveryFile)
        } else if !settings.defaults.bool(forKey: "LitebarJournalMigrated") {
            data = settings.defaults.data(forKey: "LitebarTemporaryItems")
        } else { data = nil }
        guard let data else { return }
        guard data.count <= 1024 * 1024 else { throw AppError.message("The recovery journal is too large. It was not modified.") }
        let records = try PropertyListDecoder().decode([TemporaryItem].self, from: data)
        guard records.count <= 16, records.allSatisfy({ $0.window != 0 && $0.anchor != 0 && $0.space != 0 && $0.identity.utf8.count <= 32768 && $0.anchorIdentity.utf8.count <= 32768 && $0.attempts >= 0 }) else {
            throw AppError.message("The recovery journal is invalid. It was not modified.")
        }
        temporary = records.map { var record = $0; record.attempts = min(3, record.attempts); return record }
        if !settings.defaults.bool(forKey: "LitebarJournalMigrated") { try persistTemporary() }
    }

    private func persistTemporary() throws {
        guard recoveryAvailable else { throw AppError.message("Resolve the invalid recovery journal before moving temporary items.") }
        let data = try PropertyListEncoder().encode(temporary)
        let saved = withUTF8(recoveryFile.path) { path, length in
            data.withUnsafeBytes { bytes in lb_store_journal(path, length, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
        }
        guard saved != 0 else { throw AppError.message("Unable to safely save the recovery journal at " + recoveryFile.path) }
        settings.defaults.set(true, forKey: "LitebarJournalMigrated")
    }

    @objc func forgetRecovery() {
        guard operation == nil, !actions.busy else { report(AppError.message("Finish the current item operation first.")); return }
        let alert = NSAlert()
        alert.messageText = "Forget recovery records?"
        alert.informativeText = "This does not move any items. First return them using the item list or Command-drag. The existing journal will be backed up before a new empty journal is saved."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Back up and forget")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let previous = temporary
        let wasAvailable = recoveryAvailable
        do {
            if FileManager.default.fileExists(atPath: recoveryFile.path) {
                let backup = recoveryFile.deletingPathExtension().appendingPathExtension("backup-" + UUID().uuidString + ".plist")
                try FileManager.default.copyItem(at: recoveryFile, to: backup)
            }
            temporary = []
            recoveryAvailable = true
            try persistTemporary()
            temporaryTimer?.invalidate()
            temporaryTimer = nil
        } catch {
            temporary = previous
            recoveryAvailable = wasAvailable
            report(error)
        }
    }

    private func canRestore(_ item: TemporaryItem, manual: Bool) -> Bool {
        lb_restoration_allowed(UInt64(item.space), UInt64(server.activeSpace ?? 0), UInt32(clamping: item.attempts), manual ? 1 : 0) != 0
    }

    private func resolve(_ preferred: UInt32, in matches: [BarItem]) -> BarItem? {
        let ids = matches.map(\.id)
        let id = ids.withUnsafeBufferPointer { lb_resolve_window(preferred, $0.baseAddress, $0.count) }
        return id == 0 ? nil : matches.first { $0.id == id }
    }

    private func armTemporaryTimer(_ interval: TimeInterval? = nil) {
        temporaryTimer?.invalidate()
        temporaryTimer = nil
        guard !temporary.isEmpty, temporary.contains(where: { canRestore($0, manual: false) }), !closing, state.suspended == 0 else { return }
        let value = Timer(timeInterval: interval ?? settings.temporaryInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.temporaryTimer = nil; self?.requestRestoration(manual: false) }
        }
        value.tolerance = 0.25
        temporaryTimer = value
        RunLoop.main.add(value, forMode: .common)
    }

    @objc func restoreRequested() { requestRestoration(manual: true) }
    private func requestRestoration(manual: Bool) {
        if actions.busy || operation != nil { armTemporaryTimer(3); return }
        perform(interactive: manual) { [self] in try await restoreTemporary(manual: manual) }
    }
    private func restoreTemporary(manual: Bool = true) async throws {
        guard !temporary.isEmpty else { return }
        if NSEvent.pressedMouseButtons != 0 { armTemporaryTimer(3); return }
        let windows = onScreenWindows()
        if temporary.contains(where: { pending in
            guard let id = pending.interfaceWindow,
                  let window = windows.first(where: { $0[kCGWindowNumber as String] as? UInt32 == id }) else { return false }
            let layer = window[kCGWindowLayer as String] as? Int
            let app = (window[kCGWindowOwnerPID as String] as? pid_t).flatMap(NSRunningApplication.init(processIdentifier:))
            return lb_interface_showing(1, layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) ? 1 : 0, app.map { $0.isActive ? 1 : 0 } ?? -1) != 0
        }) {
            armTemporaryTimer(3); return
        }
        refreshItems(force: true)
        guard inventory.reliable else { throw AppError.message("The item inventory is unavailable. Recovery records were retained. Refresh after restoring access.") }
        var remaining: [TemporaryItem] = []
        var failed = false
        for var context in temporary.reversed() {
            guard canRestore(context, manual: manual) else { remaining.append(context); continue }
            let matches = inventory.items.filter { $0.identity == context.identity }
            let anchors = inventory.items.filter { $0.identity == context.anchorIdentity }
            let item = resolve(context.window, in: matches)
            let anchor = resolve(context.anchor, in: anchors)
            guard let item else {
                context.attempts = matches.isEmpty ? min(3, context.attempts + 1) : 3
                remaining.append(context)
                failed = true
                continue
            }
            guard let anchor else { context.attempts = 3; remaining.append(context); failed = true; continue }
            do { try await actions.move(item, beside: anchor, right: context.right, section: context.section & 1 != 0 ? 1 : context.section & 2 != 0 ? 2 : 4) }
            catch { context.attempts = min(3, context.attempts + 1); remaining.append(context); failed = true }
        }
        temporary = Array(remaining.reversed())
        try persistTemporary()
        if failed { armTemporaryTimer(3) }
        if temporary.contains(where: { $0.attempts >= 3 }) { throw AppError.message("A temporary item could not be restored. Refresh the list and use Move to return it. Automatic retries have stopped.") }
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

    func report(_ error: Error, interactive: Bool = true) {
        lastError = error.localizedDescription
        itemPanel?.status.stringValue = error.localizedDescription
        icon?.status.button?.toolTip = "Litebar: " + error.localizedDescription
        if validation || benchmark { fputs(error.localizedDescription + "\n", stderr); return }
        guard interactive else { return }
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
        ownerRefresh?.cancel()
        ownerRefresh = nil
        closing = true
        timer?.invalidate()
        cancelAuxiliaryTimers()
        stopMonitors()
        releaseItems()
        settingsWindow?.close()
        settingsWindow = nil
        hotkeys.stop()
        observations.removeAll()
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
        restoreApplicationMenus()
        for control in [icon, hidden, always].compactMap({ $0 }) { control.remove() }
        icon = nil; hidden = nil; always = nil
        inventory.clear()
        if let ephemeralSuite {
            settings.defaults.removePersistentDomain(forName: ephemeralSuite)
            try? FileManager.default.removeItem(at: recoveryFile.deletingLastPathComponent())
        }
    }
}
