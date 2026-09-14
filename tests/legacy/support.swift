import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
struct MenuBarItem {
    let frame: CGRect
    let windowID: UInt32 = 123
}
enum Constants { static let bundleIdentifier = "com.jordanbaird.Ice" }
final class ControlItem {
    enum Identifier: String {
        case iceIcon = "SItem"
        case hidden = "HItem"
        case alwaysHidden = "AHItem"
    }
    enum HidingState { case hideItems, showItems }
    var state = HidingState.hideItems
    var isAddedToMenuBar = true
}
@MainActor
final class LegacyPanel {
    var currentSection: MenuBarSection.Name?
    func close() { currentSection = nil }
    func show(section: MenuBarSection.Name, on: Int) async { currentSection = section }
}
@MainActor
final class LegacyManager {
    var sections = [MenuBarSection]()
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }
}
@MainActor
final class LegacyState {
    let menuBarManager = LegacyManager()
    var hoverAllowed = false
    func allowShowOnHover() { hoverAllowed = true }
}
@MainActor
final class MenuBarSection {
    enum Name: CaseIterable { case visible, hidden, alwaysHidden }
    let name: Name
    let controlItem = ControlItem()
    var appState: LegacyState?
    var useIceBar = false
    var screenForIceBar: Int? = 0
    var iceBarPanel: LegacyPanel? = LegacyPanel()
    var started = 0
    var stopped = 0
    init(name: Name, state: LegacyState) {
        self.name = name
        self.appState = state
    }
    func startRehideChecks() { started += 1 }
    func stopRehideChecks() { stopped += 1 }
    __var isHidden: Bool__
    __func show()__
    __func hide()__
    __func toggle()__
}
