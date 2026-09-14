let fixtureRoot = CommandLine.arguments[1]
var checks = 0
func require(_ condition: Bool, _ message: String) {
    precondition(condition, message)
    checks += 1
}
func rows(_ name: String) throws -> [[String]] {
    try String(contentsOfFile: fixtureRoot + "/" + name, encoding: .utf8)
        .components(separatedBy: "\n")
        .dropFirst()
        .filter { !$0.isEmpty }
        .map { $0.components(separatedBy: "\t") }
}
for row in try rows("sections.tsv") {
    require(row.count == 8, "section fixture shape")
    let hidden = MenuBarItem(frame: CGRect(x: Double(row[1])!, y: 0, width: Double(row[2])!, height: 24))
    let always = row[3] == "-" ? nil : MenuBarItem(frame: CGRect(x: Double(row[3])!, y: 0, width: Double(row[4])!, height: 24))
    let item = MenuBarItem(frame: CGRect(x: Double(row[5])!, y: 0, width: Double(row[6])!, height: 24))
    let predicates = Predicates<MenuBarItem>.sectionPredicates(hiddenControlItem: hidden, alwaysHiddenControlItem: always)
    let mask = (predicates.isInVisibleSection(item) ? 1 : 0) | (predicates.isInHiddenSection(item) ? 2 : 0) | (predicates.isInAlwaysHiddenSection(item) ? 4 : 0)
    require(mask == Int(row[7]), row[0])
    print("section\t\(row[0])\t\(mask)")
}
for row in try rows("identities.tsv") {
    require(row.count == 5, "identity fixture shape")
    let data = try JSONEncoder().encode(row[0])
    let value = try JSONDecoder().decode(MenuBarItemInfo.self, from: data)
    require(value.namespace.rawValue == row[1], "namespace: " + row[0])
    require(value.title == row[2], "title: " + row[0])
    let movable = !MenuBarItemInfo.immovableItems.contains(value)
    let hideable = !MenuBarItemInfo.nonHideableItems.contains(value)
    require(movable == (row[3] == "1"), "movable: " + row[0])
    require(hideable == (row[4] == "1"), "hideable: " + row[0])
    let encoded = try JSONEncoder().encode(value)
    let roundtrip = try JSONDecoder().decode(MenuBarItemInfo.self, from: encoded)
    require(value == roundtrip, "identity roundtrip")
    print("identity\t\(row[1])\t\(row[2])\t\(movable ? 1 : 0)\t\(hideable ? 1 : 0)")
}
require(MenuBarItemInfo.Namespace.null.optional == nil, "null namespace")
require(MenuBarItemInfo.Namespace("<null>").optional != nil, "literal null namespace is not absent")

@MainActor
func checkTransitions() throws {
    for row in try rows("transitions.tsv") {
        let state = LegacyState()
        state.menuBarManager.sections = MenuBarSection.Name.allCases.map { MenuBarSection(name: $0, state: state) }
        let values = state.menuBarManager.sections
        let mask = Int(row[1])!
        values[0].controlItem.state = mask & 1 != 0 ? .showItems : .hideItems
        values[1].controlItem.state = mask & 1 != 0 ? .showItems : .hideItems
        values[2].controlItem.state = mask & 2 != 0 ? .showItems : .hideItems
        let target = values[Int(row[2])!]
        switch row[3] {
        case "show": target.show()
        case "hide": target.hide()
        case "toggle": target.toggle()
        default: preconditionFailure("Invalid action")
        }
        let actual = (values[1].controlItem.state == .showItems ? 1 : 0) | (values[2].controlItem.state == .showItems ? 2 : 0)
        require(actual == Int(row[4]), row[0])
        print("transition\t\(row[0])\t\(actual)")
        for value in values { value.appState = nil }
    }
}
try await checkTransitions()
#if canImport(CoreGraphics)
private let buttonStates: [MenuBarItemEventButtonState] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
let source = CGEventSource(stateID: .hidSystemState)!
let eventItem = MenuBarItem(frame: CGRect(x: 20, y: 0, width: 20, height: 24))
for row in try rows("events.tsv") {
    let button = buttonStates[Int(row[2])!]
    let type: MenuBarItemEventType = row[1] == "0" ? .move(button) : .click(button)
    let location = CGPoint(x: 30, y: 12)
    let event = CGEvent.menuBarItemEvent(type: type, location: location, item: eventItem, pid: 456, source: source)!
    require(event.type.rawValue == UInt32(row[3]), row[0] + " type")
    require(event.flags.rawValue == UInt64(row[4]), row[0] + " flags")
    let nativeDefault = CGEvent(mouseEventSource: source, mouseType: type.cgEventType, mouseCursorPosition: location, mouseButton: type.mouseButton)!
    let clickState = row[1] == "0" ? nativeDefault.getIntegerValueField(.mouseEventClickState) : Int64(row[5])!
    require(event.getIntegerValueField(.mouseEventClickState) == clickState, row[0] + " click")
    require(event.getIntegerValueField(.eventTargetUnixProcessID) == 456, row[0] + " pid")
    for field in [CGEventField.mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, .windowID] {
        require(event.getIntegerValueField(field) == 123, row[0] + " window")
    }
    print("event\t\(row[0])\t\(row[3])\t\(row[4])\t\(row[5])")
}
#endif
fputs("Legacy characterization: \(checks) assertions passed\n", stderr)
