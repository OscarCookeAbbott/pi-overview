import Cocoa

@main
struct NativeMenuTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let renderer = ContributionMenus()
        let items = (0..<50).map { OverviewItem(title: "Task \($0)", state: "pending", detail: "Description \($0)") }
        let list = renderer.makeItemsMenu(items)
        renderer.menuWillOpen(list)
        expect(list.items.count == 50, "native menus must retain every item, not stop at twenty")
        expect(list.items.last?.title.contains("Task 49") == true, "last item is reachable")

        let detail = "Description:\n" + String(repeating: "long detail ", count: 30) + "\nEND DETAIL"
        let payload: [String: Any] = ["title": "Task", "state": "running", "detail": detail, "children": [
            ["title": "<ab> Decision", "state": "unknown", "detail": "FULL NOTE\nSecond note line"]
        ]]
        let task = try JSONDecoder().decode(OverviewItem.self, from: JSONSerialization.data(withJSONObject: payload))
        let tasks = renderer.makeItemsMenu([task])
        renderer.menuWillOpen(tasks)
        let row = tasks.items[0]
        expect(row.isEnabled && row.submenu != nil, "hoverable task row is enabled and owns a submenu")
        expect(row.toolTip == detail, "complete detail is available as a tooltip")
        let submenu = row.submenu!
        renderer.menuNeedsUpdate(submenu)
        renderer.menuWillOpen(submenu)
        expect(submenu.items.contains { $0.title == "END DETAIL" }, "multiline detail is not clipped to 120 characters")
        expect(submenu.items.contains { $0.title == "Copy details" && $0.isEnabled }, "details can be copied")
        guard let note = submenu.items.first(where: { $0.title.contains("<ab> Decision") }), let noteMenu = note.submenu else {
            expect(false, "notes must be nested under their task"); return
        }
        expect(note.isEnabled, "notes are independently hoverable")
        renderer.menuWillOpen(noteMenu)
        expect(noteMenu.items.contains { $0.title == "FULL NOTE" }, "full note detail is reachable")
        print("Native menu tests passed: untruncated lists, enabled hover submenus, multiline details, nested notes and copy actions.")
    }
}
