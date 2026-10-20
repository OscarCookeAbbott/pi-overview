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
        let payload: [String: Any] = ["title": "Task", "kind": "task", "state": "running", "subtitle": "Active · 1 note", "body": detail, "detail": detail, "children": [
            ["title": "Notes", "kind": "group", "children": [
                ["title": "<ab> Decision", "kind": "note", "state": "unknown", "body": "FULL NOTE\nSecond note line", "detail": "FULL NOTE\nSecond note line"]
            ]]
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
        guard let card = submenu.items.compactMap({ $0.view as? ContributionCard }).first else {
            expect(false, "task details need a custom native card"); return
        }
        expect(card.titleLabel.stringValue == "Task" && card.subtitleLabel.stringValue == "Active · 1 note", "card has distinct title/status typography")
        expect(card.textView.string == detail && !card.textView.isEditable && card.textView.isSelectable, "complete details are selectable and read-only")
        expect(card.frame.height <= 268 && card.scrollView.hasVerticalScroller, "long details scroll within a bounded-height card")
        guard let notesMenu = submenu.items.first(where: { $0.title.contains("Notes (1)") })?.submenu else {
            expect(false, "notes need their own ownership group"); return
        }
        renderer.menuWillOpen(notesMenu)
        expect(submenu.items.contains { $0.title == "Copy details" && $0.isEnabled }, "details can be copied")
        guard let note = notesMenu.items.first(where: { $0.title.contains("<ab> Decision") }), let noteMenu = note.submenu else {
            expect(false, "notes must be nested under their task"); return
        }
        expect(note.isEnabled, "notes are independently hoverable")
        renderer.menuWillOpen(noteMenu)
        let noteCard = noteMenu.items.compactMap { $0.view as? ContributionCard }.first
        expect(noteCard?.textView.string == "FULL NOTE\nSecond note line", "note has its own complete detail card")
        expect(note.image != nil, "typed notes have a native icon")
        try testComposer()
        print("Native menu tests passed: structured cards, owned notes, scrolling lists and inline composer controls.")
    }

    static func testComposer() throws {
        let base = FileManager.default.temporaryDirectory
        let chosen = base.appendingPathComponent("pi-composer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chosen) }
        var launches: [(String, String)] = []
        let composer = AgentComposer { prompt, directory in launches.append((prompt, directory)) }
        composer.configure(directory: base.path)
        expect(!composer.startButton.isEnabled, "empty prompts cannot launch")
        composer.prompt = "  A multi-line\nprompt  "
        composer.directoryPicker = { current in
            expect(current == base.path, "picker starts in the current directory")
            return chosen.path
        }
        composer.directoryButton.performClick(nil)
        expect(composer.directory == chosen.path && composer.directoryLabel.stringValue.contains(chosen.path), "folder selection updates inline readout")
        composer.configure(directory: base.path)
        expect(composer.directory == chosen.path && composer.prompt.contains("A multi-line"), "menu reopening retains the draft and its directory")
        composer.directoryPicker = { _ in nil }
        composer.directoryButton.performClick(nil)
        expect(composer.directory == chosen.path && composer.prompt.contains("A multi-line"), "cancelling directory selection does not discard the draft")
        let window = NSWindow(contentRect: composer.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = composer
        defer { window.close() }
        expect(window.makeFirstResponder(composer.editor), "inline editor can receive keyboard focus")
        var cancelled = false
        composer.editor.onCancel = { cancelled = true }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        composer.editor.keyDown(with: escape)
        expect(cancelled && composer.prompt.contains("A multi-line"), "escape dismisses without clearing draft")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        composer.editor.keyDown(with: enter)
        expect(launches.count == 1 && launches[0].0 == "A multi-line\nprompt" && launches[0].1 == chosen.path, "command-return launches exactly the chosen draft")
        expect(composer.prompt.isEmpty && composer.directory == base.path, "successful launch resets draft and per-agent directory")
        composer.prompt = String(repeating: "🥧", count: 16385)
        expect(!composer.startButton.isEnabled && composer.errorLabel.stringValue.contains("64 KiB"), "prompt bound counts UTF-8 bytes")
        composer.prompt = String(repeating: "🥧", count: 16384)
        expect(composer.startButton.isEnabled, "the exact 64 KiB prompt limit remains usable")
        let failed = AgentComposer { _, _ in throw OverviewError.message("Launch denied") }
        failed.configure(directory: base.path)
        failed.prompt = "Keep this draft"
        failed.startButton.performClick(nil)
        expect(failed.prompt == "Keep this draft" && failed.errorLabel.stringValue == "Launch denied", "launch errors stay inline and preserve input")
        failed.configure(directory: nil, error: "Configuration missing")
        expect(!failed.startButton.isEnabled && failed.errorLabel.stringValue == "Configuration missing", "configuration errors disable launch without a popup")
    }
}
