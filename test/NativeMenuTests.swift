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
        try testStatusSymbols()
        testMenubarSymbols()
        testMenuWidthContract()
        testAgentCards()
        testAgentHoverRefresh()
        testComposerLayout()
        try testComposer()
        print("Native menu tests passed: structured cards, owned notes, scrolling lists and inline composer controls.")
    }

    static func testStatusSymbols() throws {
        let renderer = ContributionMenus()
        for kind in ["task", "job"] {
            for (state, symbol) in [("running", "play.fill"), ("complete", "checkmark"), ("pending", "pause")] {
                let value = OverviewItem(title: "Status", state: state, detail: nil, kind: kind)
                let menu = renderer.makeItemsMenu([value])
                renderer.menuWillOpen(menu)
                let reference = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
                reference.size = NSSize(width: 14, height: 14)
                expect(reference.tiffRepresentation != nil, "reference symbols can be rendered")
                expect(menu.items[0].image != nil, "status rows have a native symbol")
                expect(menu.items[0].image?.tiffRepresentation == reference.tiffRepresentation, "\(kind) \(state) must use the shared \(symbol) icon")
            }
        }
    }

    static func testMenubarSymbols() {
        let now = nowMillis()
        let running = InstanceInfo(id: UUID().uuidString, token: UUID().uuidString, pid: getpid(), cwd: "/tmp",
                                   projectName: "Running", status: "Working", busy: true, closed: false,
                                   lastOutput: "", updatedAt: now, heartbeatAt: now)
        var complete = running
        complete.id = UUID().uuidString
        complete.projectName = "Complete"
        complete.status = "Completed"
        complete.busy = false
        var idle = complete
        idle.id = UUID().uuidString
        idle.status = "Idle"
        let title = menubarAttributedTitle([running, complete, idle])
        expect(title.string == "π  \u{fffc} 1 \u{fffc} 1 \u{fffc} 1", "native count icons retain the exact Pi separator and counts")
        var images: [NSImage] = []
        title.enumerateAttribute(.attachment, in: NSRange(location: 0, length: title.length)) { value, _, _ in
            if let image = (value as? NSTextAttachment)?.image { images.append(image) }
        }
        expect(images.count == 3, "running, completed and idle counts have native icons")
        for (index, pair) in [("running", "play.fill"), ("complete", "checkmark"), ("pending", "pause")].enumerated() {
            let (state, symbol) = pair
            let reference = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            reference.size = NSSize(width: NSFont.menuBarFont(ofSize: 0).pointSize, height: NSFont.menuBarFont(ofSize: 0).pointSize)
            expect(images[index].isTemplate && images[index].tiffRepresentation == reference.tiffRepresentation, "menubar uses the shared template \(symbol)")
            let row = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
            applyStatusIcon(row, state: state)
            reference.size = NSSize(width: 14, height: 14)
            expect(row.image?.tiffRepresentation == reference.tiffRepresentation, "agent row uses the shared \(symbol)")
        }
    }

    static func testMenuWidthContract() {
        let composer = AgentComposer { _, _ in }
        expect(composer.autoresizingMask.contains(.width), "custom menu view must opt into NSMenu's full-width resizing before attachment")
        let menu = NSMenu()
        let input = NSMenuItem(title: "New agent", action: nil, keyEquivalent: "")
        input.view = composer
        menu.addItem(input)
        menu.addItem(NSMenuItem(title: String(repeating: "Long project name ", count: 6), action: nil, keyEquivalent: ""))
        menu.update()
        fitMenuViews(menu)
        expect(menu.size.width > 600 && composer.frame.width == menu.size.width, "composer must fill a real wider menu, not just a manually resized test view")
        expect(composer.editor.enclosingScrollView!.frame.maxX == composer.frame.width - 12, "input and footer track the complete menu width")
        fitMenuViews(menu)
        expect(composer.frame.width == menu.size.width, "fitting must not grow the menu repeatedly")
    }

    static func testAgentCards() {
        let active = OverviewItem(title: "[ab] Build compact cards", state: "running", detail: "Scope", kind: "task")
        let notes = OverviewItem(title: "Notes", state: "unknown", detail: nil, children: [
            OverviewItem(title: "<cd> Decision", state: "unknown", detail: "Full note", kind: "note")
        ], kind: "group")
        let parent = OverviewItem(title: "[pa] Overhaul", state: "waiting", detail: "Parent details", children: [
            OverviewItem(title: "Subtasks", state: "unknown", detail: nil, children: [active], kind: "group"), notes
        ], kind: "task")
        var info = InstanceInfo(id: UUID().uuidString, token: UUID().uuidString, pid: getpid(), cwd: "/tmp/project",
                                projectName: "Project", sessionName: "UI overhaul", status: "Running: read", busy: true, closed: false,
                                lastOutput: "Legacy message preview", updatedAt: nowMillis(), heartbeatAt: nowMillis())
        info.contributions = [
            OverviewContribution(id: "tasks", badge: "0/2 tasks", sections: [OverviewSection(title: "Tasks", items: [parent])]),
            OverviewContribution(id: "jobs", badge: "", sections: [OverviewSection(title: "Running jobs", items:
                (0..<50).map { OverviewItem(title: "[jb] Job \($0)", state: "running", detail: "Command", kind: "job") }
            )])
        ]
        let renderer = ContributionMenus()
        let actions = NSMenu()
        actions.addItem(NSMenuItem(title: "Open Project in Terminal", action: nil, keyEquivalent: ""))
        let rows = renderer.makeAgentItems(info, actions: actions)
        guard let card = rows.first?.view as? AgentCard else { expect(false, "agent summary is a visible root card"); return }
        expect(rows.first?.submenu == nil, "agent information must not require a first-level agent hover")
        expect(card.titleLabel.stringValue == "UI overhaul" && card.metadataLabel.stringValue.contains("Running: read"), "name/status are visible on the main card")
        expect(card.metadataLabel.stringValue.contains("/tmp/project") && card.metadataLabel.toolTip?.contains("PID") == true, "path stays visible while diagnostics move out of the main text")
        expect(!card.subviews.contains { $0 is NSBox }, "agent sections use native menu spacing, not boxed web-style panels")
        expect([card.metadataLabel, card.taskLabel, card.activityLabel].allSatisfy { $0.frame.minX == card.titleLabel.frame.minX }, "agent text shares one native list column")
        expect(card.taskLabel.stringValue == "▶ [ab] Build compact cards", "active nested task is visible without hovering")
        expect(card.activityLabel.stringValue == "Legacy message preview", "old snapshots retain their message preview")
        expect(rows.count == 4 && rows[1].title == "Tasks · 0/2" && rows[2].title == "Running jobs", "contributions sit directly beneath the card")
        expect(rows[3].submenu === actions, "existing controls remain reachable under Actions")
        let tasks = rows[1].submenu!, jobs = rows[2].submenu!
        renderer.menuWillOpen(tasks)
        renderer.menuWillOpen(jobs)
        expect(tasks.items.map { $0.title } == ["[pa] Overhaul", "[ab] Build compact cards"], "one task hover exposes all descendants")
        expect(tasks.items[1].indentationLevel == 1, "flattened tasks retain their hierarchy visually")
        expect(jobs.items.count == 50 && jobs.items.last?.title == "[jb] Job 49", "one job hover exposes every job without caps")
        let details = tasks.items[0].submenu!
        renderer.menuWillOpen(details)
        expect(details.items.contains { $0.title == "Notes (1)" }, "owned notes/details remain reachable")
        expect(!details.items.contains { $0.title.hasPrefix("Subtasks") }, "task navigation does not reintroduce redundant nesting")
        let activeHeight = card.frame.height
        info.lastActivity = "Tool finished · read"
        card.configure(info)
        card.setFrameSize(NSSize(width: 640, height: card.frame.height))
        expect(card.activityLabel.stringValue == "Tool finished · read" && card.frame.height == activeHeight, "activity changes preserve the current section height")
        expect(card.activityLabel.frame.height <= 18, "short activity does not reserve a blank second line")
        expect(card.activityLabel.maximumNumberOfLines == 2 && card.activityLabel.frame.maxX == card.frame.width - 16, "compact multiline activity stretches with the card")
        info.contributions = []
        card.configure(info)
        expect(card.taskLabel.isHidden && card.frame.height < activeHeight, "agents without active tasks do not reserve an empty task row")
        expect([card.titleLabel, card.metadataLabel, card.activityLabel].allSatisfy { card.bounds.contains($0.frame) }, "compact section content stays inside its resized bounds")
        info.lastActivity = ""
        info.lastOutput = ""
        card.configure(info)
        expect(card.activityLabel.isHidden && card.frame.height <= 54, "empty activity does not reserve a placeholder row")
    }

    static func testAgentHoverRefresh() {
        var info = InstanceInfo(id: UUID().uuidString, token: UUID().uuidString, pid: getpid(), cwd: "/tmp",
                                projectName: "Refresh", status: "Working", busy: true, closed: false,
                                lastOutput: "", updatedAt: nowMillis(), heartbeatAt: nowMillis())
        info.contributions = [OverviewContribution(id: "jobs", badge: "", sections: [OverviewSection(title: "Running jobs", items: [
            OverviewItem(title: "Old snapshot", state: "running", detail: "Old command", kind: "job")
        ])])]
        var latest = info
        let renderer = ContributionMenus()
        let rows = renderer.makeAgentItems(info, actions: NSMenu(), refresh: { latest })
        latest.contributions = [OverviewContribution(id: "jobs", badge: "", sections: [OverviewSection(title: "Running jobs", items: [
            OverviewItem(title: "Latest job", state: "running", detail: "New command", kind: "job")
        ])])]
        let jobs = rows[1].submenu!
        renderer.menuWillOpen(jobs)
        expect(jobs.items.first?.title == "Latest job", "hover lists read current agent data rather than the menu-open snapshot")
        let staleRows = renderer.makeAgentItems(info, actions: NSMenu(), refresh: { nil })
        renderer.menuWillOpen(staleRows[1].submenu!)
        expect(staleRows[1].submenu!.items.first?.title == "No items", "deleted agent records never fall back to stale running jobs")
        info.contributions = [OverviewContribution(id: "other", badge: "", sections: [
            OverviewSection(title: "Same name", items: [OverviewItem(title: "First", state: "pending", detail: nil)]),
            OverviewSection(title: "Same name", items: [OverviewItem(title: "Second", state: "pending", detail: nil)])
        ])]
        let duplicateSections = renderer.makeAgentItems(info, actions: NSMenu())
        for index in 1...2 { renderer.menuWillOpen(duplicateSections[index].submenu!) }
        expect(duplicateSections[1].submenu!.items.first?.title == "First" && duplicateSections[2].submenu!.items.first?.title == "Second",
               "duplicate section titles retain all distinct contributed items")
    }

    static func testComposerLayout() {
        let composer = AgentComposer { _, _ in }
        composer.configure(directory: FileManager.default.temporaryDirectory.path)
        guard let scroll = composer.editor.enclosingScrollView else { expect(false, "composer has a scrollable editor"); return }
        let labels = composer.subviews.compactMap { $0 as? NSTextField }
        expect(!labels.contains { $0.stringValue == "New agent" || $0.stringValue.hasPrefix("⌘") }, "no redundant heading or standalone shortcut legend")
        expect(composer.startButton.keyEquivalent == "\r" && composer.startButton.keyEquivalentModifierMask.contains(.command), "Start exposes its command-return shortcut natively")
        expect(composer.startButton.image != nil && composer.startButton.toolTip?.contains("⌘") == true, "symbolic Start remains discoverable")
        for width: CGFloat in [560, 360, 720] {
            composer.setFrameSize(NSSize(width: width, height: composer.frame.height))
            composer.layoutSubtreeIfNeeded()
            scroll.tile()
            expect(abs(scroll.frame.maxX - (width - scroll.frame.minX)) < 1, "input retains equal insets at every menu width")
            expect(abs(composer.editor.frame.width - scroll.contentSize.width) < 1, "editor fills the scroll viewport")
            expect(composer.startButton.frame.maxX == scroll.frame.maxX, "Start stays right-aligned")
            expect(composer.directoryButton.frame.minY >= scroll.frame.maxY && composer.directoryLabel.frame.minY >= scroll.frame.maxY, "directory controls sit below the input")
            expect(composer.directoryButton.frame.minX == scroll.frame.minX, "folder button stays left-aligned")
            expect(composer.directoryLabel.frame.maxX < composer.startButton.frame.minX, "path does not overlap Start")
            expect((48...64).contains(scroll.frame.height) && composer.frame.height <= 110, "headerless composer is compact but remains multiline")
            expect(composer.bounds.height - composer.startButton.frame.maxY <= 12, "footer has no empty legend/error row")
            expect(composer.errorLabel.isHidden && !composer.directoryLabel.isHidden, "valid drafts show the path without empty error space")
        }
        composer.prompt = String(repeating: "A longer multiline draft\n", count: 20)
        composer.editor.sizeToFit()
        expect(composer.editor.frame.height > scroll.contentSize.height && scroll.hasVerticalScroller, "long drafts still scroll")
        let height = composer.frame.height
        composer.configure(directory: nil, error: "Configuration missing")
        expect(!composer.errorLabel.isHidden && composer.directoryLabel.isHidden && composer.directoryButton.isEnabled, "inline errors replace the path but keep folder selection available")
        expect(composer.frame.height == height && composer.errorLabel.frame.maxX < composer.startButton.frame.minX, "errors fit without resizing the composer")
        expect(composer.subviews.filter { !$0.isHidden }.allSatisfy { composer.bounds.contains($0.frame) }, "visible controls fit inside the compact composer")
        composer.configure(directory: FileManager.default.temporaryDirectory.path)
        expect(composer.errorLabel.isHidden && !composer.directoryLabel.isHidden, "clearing errors restores the path")
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
