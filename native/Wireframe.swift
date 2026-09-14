import AppKit
import ServiceManagement
import ScreenCaptureKit

@MainActor
final class ItemPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    weak var controller: Controller?
    let search = NSSearchField()
    let table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "")
    let groups = NSSegmentedControl(labels: ["All", "Visible", "Hidden", "Always-hidden"], trackingMode: .selectOne, target: nil, action: nil)
    let destination = NSPopUpButton()
    private var all: [BarItem] = []
    private(set) var rows: [BarItem] = []
    private let dragType = NSPasteboard.PasteboardType("com.vincenthopf.Litebar.item")
    override var canBecomeKey: Bool { true }

    init(controller: Controller) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 380), styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Litebar items"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        minSize = NSSize(width: 640, height: 260)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        contentView = root
        search.placeholderString = "Search menu-bar items"
        search.delegate = self
        groups.target = self
        groups.action = #selector(filterChanged)
        groups.selectedSegment = 0
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshItems))
        let settings = NSButton(title: "Settings", target: controller, action: #selector(Controller.openSettings))
        let top = NSStackView(views: [search, refresh, settings])
        top.spacing = 8
        top.orientation = .horizontal
        root.addArrangedSubview(top)
        root.addArrangedSubview(groups)
        groups.setAccessibilityLabel("Filter menu-bar section")
        for (id, title, width) in [("name", "Item", 360.0), ("section", "Section", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.allowsMultipleSelection = false
        table.registerForDraggedTypes([dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Menu-bar items. Drag rows to reorder or use Move.")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        destination.addItems(withTitles: ["Visible", "Hidden", "Always-hidden"])
        destination.setAccessibilityLabel("Move destination section")
        let open = NSButton(title: "Open", target: self, action: #selector(openSelected))
        open.keyEquivalent = "\r"
        let right = NSButton(title: "Right-click", target: self, action: #selector(rightClickSelected))
        let move = NSButton(title: "Move", target: self, action: #selector(moveSelected))
        let restore = NSButton(title: "Restore temporary items", target: controller, action: #selector(Controller.restoreRequested))
        let bottom = NSStackView(views: [open, right, destination, move, restore])
        bottom.spacing = 8
        root.addArrangedSubview(bottom)
        root.addArrangedSubview(status)
        for view in [top, scroll, bottom, status] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    }

    func setItems(_ items: [BarItem], section: UInt32? = nil, message: String? = nil) {
        all = items
        if let section { groups.selectedSegment = section == 1 ? 1 : section == 2 ? 2 : section == 4 ? 3 : 0 }
        if let message { status.stringValue = message }
        filterChanged()
    }

    @objc private func filterChanged() {
        let selectedID = selected?.id
        let index = groups.selectedSegment
        let section: UInt32 = (1...3).contains(index) ? 1 << UInt32(index - 1) : 0
        let query = search.stringValue
        rows = all.compactMap { item -> (BarItem, Int32)? in
            guard section == 0 || item.section & section != 0 else { return nil }
            let score = searchScore(query, item.name + " " + item.title + " " + item.namespace)
            return score >= 0 ? (item, score) : nil
        }.sorted { $0.1 == $1.1 ? ($0.0.frame.minX == $1.0.frame.minX ? $0.0.id < $1.0.id : $0.0.frame.minX < $1.0.frame.minX) : $0.1 < $1.1 }.map(\.0)
        table.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { filterChanged() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn else { return nil }
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        cell.identifier = column.identifier
        let item = rows[row]
        cell.stringValue = column.identifier.rawValue == "name" ? item.name : Self.sectionName(item.section)
        cell.toolTip = item.identity
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }
    static func sectionName(_ section: UInt32) -> String {
        section & 1 != 0 ? "Visible" : section & 2 != 0 ? "Hidden" : section & 4 != 0 ? "Always-hidden" : "Unclassified"
    }
    var selected: BarItem? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    @objc private func openSelected() { if let selected { controller?.openItem(selected.id, right: false) } }
    @objc private func rightClickSelected() { if let selected { controller?.openItem(selected.id, right: true) } }
    @objc private func moveSelected() {
        guard (0...2).contains(destination.indexOfSelectedItem), let selected else { return }
        controller?.moveToSection(selected.id, section: 1 << UInt32(destination.indexOfSelectedItem))
    }
    @objc private func refreshItems() { controller?.refreshItems(force: true) }
    override func cancelOperation(_ sender: Any?) { controller?.closeItems() }
    override func close() { super.close(); controller?.panelClosed() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard search.stringValue.isEmpty, rows.indices.contains(row), rows[row].flags & 1 != 0 else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(rows[row].id), forType: dragType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, !rows.isEmpty, search.stringValue.isEmpty else { return [] }
        table.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table, let value = info.draggingPasteboard.string(forType: dragType),
              let id = UInt32(value), rows.contains(where: { $0.id == id }), !rows.isEmpty, row >= 0, row <= rows.count else { return false }
        let target = rows[min(row, rows.count - 1)]
        guard id != target.id else { return false }
        controller?.rearrange(id, target: target.id, right: row == rows.count, section: target.section)
        return true
    }
}

@MainActor
private final class SettingsStack: NSStackView { override var isFlipped: Bool { true } }

@MainActor
final class SettingsWindow: NSWindow {
    weak var controller: Controller?
    private var inputs: [String: NSControl] = [:]
    private let permission = NSTextField(wrappingLabelWithString: "")
    private var recorder: Any?
    private var recordButton: NSButton?

    init(controller: Controller) {
        self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 590, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Litebar settings"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 560, height: 440)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let stack = SettingsStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.documentView = stack
        contentView = scroll
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        stack.addArrangedSubview(permission)
        stack.addArrangedSubview(NSStackView(views: [NSButton(title: "Accessibility permission", target: self, action: #selector(requestAccessibility)),
            NSButton(title: "Window names permission", target: self, action: #selector(requestWindowNames))]))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "No screenshots are captured. macOS may require Screen Recording permission to disclose other apps' menu-item names. Basic hiding works without it."))
        for (key, title) in [("ShowIceIcon", "Show Litebar menu-bar icon"), ("UseIceBar", "Show hidden items in a separate text bar"),
            ("ShowOnClick", "Reveal when empty menu-bar space is clicked"), ("ShowOnHover", "Reveal on hover"), ("ShowOnScroll", "Reveal or hide on scroll"),
            ("AutoRehide", "Automatically rehide"), ("EnableAlwaysHiddenSection", "Enable always-hidden section"), ("CanToggleAlwaysHiddenSection", "Option-click toggles always-hidden"),
            ("ShowSectionDividers", "Show section dividers"), ("HideApplicationMenus", "Make room by temporarily hiding application menus"),
            ("ShowAllSectionsOnUserDrag", "Show all sections while Command-dragging"), ("ShowContextMenuOnRightClick", "Right-click empty menu-bar space for controls")] {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(change))
            button.identifier = NSUserInterfaceItemIdentifier(key)
            inputs[key] = button
            stack.addArrangedSubview(button)
        }
        for (key, label, values) in [("RehideStrategy", "Rehide strategy", ["Smart", "Timed", "Focused app"]), ("IceBarLocation", "Separate bar location", ["Dynamic", "Mouse pointer", "Litebar icon"])] {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: values)
            popup.identifier = NSUserInterfaceItemIdentifier(key)
            popup.target = self
            popup.action = #selector(change)
            inputs[key] = popup
            stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: label), popup]))
        }
        for (key, title) in [("RehideInterval", "Rehide after seconds"), ("ShowOnHoverDelay", "Hover delay seconds"), ("TempShowInterval", "Temporary item duration seconds")] {
            let field = NSTextField()
            field.identifier = NSUserInterfaceItemIdentifier(key)
            field.target = self
            field.action = #selector(change)
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.setAccessibilityLabel(title)
            inputs[key] = field
            stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: title), field]))
        }
        let login = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(changeLogin))
        inputs["Login"] = login
        stack.addArrangedSubview(login)
        for index in Hotkeys.actions.indices {
            let button = NSButton(title: "Record", target: self, action: #selector(record))
            button.tag = index
            inputs["Shortcut\(index)"] = button
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut))
            clear.tag = index
            stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: Hotkeys.labels[index]), button, clear]))
        }
        let spacing = NSSlider(value: 0, minValue: -15, maxValue: 16, target: nil, action: nil)
        spacing.numberOfTickMarks = 32
        spacing.allowsTickMarkValuesOnly = true
        spacing.widthAnchor.constraint(equalToConstant: 180).isActive = true
        inputs["Spacing"] = spacing
        let apply = NSButton(title: "Apply spacing", target: self, action: #selector(applySpacing))
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Spacing offset"), spacing, apply]))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Spacing is system-wide. Changes take effect when apps next launch or at your next login. Litebar never force-quits other apps."))
        stack.addArrangedSubview(NSButton(title: "Back up and forget recovery records…", target: controller, action: #selector(Controller.forgetRecovery)))
        refresh()
        center()
    }

    func refresh() {
        guard let controller else { return }
        for (key, input) in inputs {
            if key == "Login", let button = input as? NSButton { button.state = SMAppService.mainApp.status == .enabled ? .on : .off }
            else if key.hasPrefix("Shortcut"), let index = UInt32(key.dropFirst(8)), let button = input as? NSButton {
                button.title = controller.hotkeys.shortcuts[index]?.label ?? "Record"
            } else if key == "Spacing", let slider = input as? NSSlider { slider.doubleValue = controller.settings.defaults.double(forKey: "ItemSpacingOffset") }
            else if let popup = input as? NSPopUpButton { popup.selectItem(at: max(0, min(popup.numberOfItems - 1, controller.settings.defaults.integer(forKey: key)))) }
            else if let button = input as? NSButton { button.state = controller.settings.bool(key) ? .on : .off }
            else if let field = input as? NSTextField {
                switch key {
                case "RehideInterval": field.doubleValue = Double(controller.settings.config.rehide_ms) / 1000
                case "ShowOnHoverDelay": field.doubleValue = Double(controller.settings.config.hover_ms) / 1000
                default: field.doubleValue = controller.settings.temporaryInterval
                }
            }
        }
        permission.stringValue = "Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted"). Window names: \(CGPreflightScreenCaptureAccess() ? "granted" : "limited"). Private APIs: \(controller.server.available ? "available" : "unavailable")."
    }

    @objc private func change(_ sender: NSControl) {
        guard let controller, let key = sender.identifier?.rawValue else { return }
        if let popup = sender as? NSPopUpButton { controller.settings.defaults.set(popup.indexOfSelectedItem, forKey: key) }
        else if let button = sender as? NSButton { controller.settings.defaults.set(button.state == .on, forKey: key) }
        else if let field = sender as? NSTextField {
            guard let number = Double(field.stringValue), number.isFinite, number >= 0, number <= 3600 else { refresh(); return }
            controller.settings.defaults.set(number, forKey: key)
        }
        controller.settingsChanged()
    }
    @objc private func changeLogin(_ sender: NSButton) {
        do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { controller?.report(error) }
        refresh()
    }
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }
    @objc private func requestWindowNames() {
        if #available(macOS 15, *) { SCShareableContent.getWithCompletionHandler { _, _ in } }
        else { _ = CGRequestScreenCaptureAccess() }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
        controller?.inventory.invalidate()
        refresh()
    }
    @objc private func applySpacing() {
        guard let slider = inputs["Spacing"] as? NSSlider else { return }
        controller?.applySpacing(Int(slider.intValue))
    }
    @objc private func record(_ sender: NSButton) {
        stopRecording()
        recordButton = sender
        sender.title = "Press shortcut. Escape cancels."
        controller?.hotkeys.suspend(true)
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                self.stopRecording()
                if event.keyCode != 53 {
                    do { try self.controller?.hotkeys.set(Shortcut(event: event), for: UInt32(sender.tag)) }
                    catch { self.controller?.report(error) }
                }
                self.refresh()
                return true
            }
            return consumed ? nil : event
        }
    }
    @objc private func clearShortcut(_ sender: NSButton) {
        do { try controller?.hotkeys.set(nil, for: UInt32(sender.tag)) } catch { controller?.report(error) }
        refresh()
    }
    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recordButton = nil
        controller?.hotkeys.suspend(false)
    }
    override func resignKey() { stopRecording(); refresh(); super.resignKey() }
    override func close() { stopRecording(); super.close(); controller?.settingsClosed() }
}
