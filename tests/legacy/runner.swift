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
fputs("Legacy characterization: \(checks) assertions passed\n", stderr)
