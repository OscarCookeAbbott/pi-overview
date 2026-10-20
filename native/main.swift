import Cocoa
import Darwin

final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let root: URL
    var item: NSStatusItem!
    var timer: Timer?
    var actions: [MenuAction] = []
    var children: [String: (Process, FileHandle)] = [:]
    var phase = 0
    let contributionMenus = ContributionMenus()
    lazy var agentComposer = AgentComposer { [weak self] prompt, directory in
        guard let self = self else { throw OverviewError.message("Overview is no longer available.") }
        let configured = try self.launcher()
        let config = Launcher(node: configured.node, cli: configured.cli, extensionPath: configured.extensionPath, cwd: directory)
        try self.launch(config, prompt: prompt)
        self.item.menu?.cancelTracking()
    }

    init(root: URL) { self.root = root }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        tick()
        let refresh = Timer(timeInterval: 2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(refresh, forMode: .common)
        timer = refresh
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("daemon.json"))
        // Child Pi runs deliberately outlive the menu bar companion.
    }

    @objc func tick() {
        for (id, child) in children where !child.0.isRunning {
            let file = root.appendingPathComponent("records/\(id).json")
            if var info = InstanceInfo.read(file) {
                info.pid = child.0.processIdentifier
                info.closed = true
                info.busy = false
                if info.status != "Aborted" && child.0.terminationStatus != 0 { info.status = "Error (exit \(child.0.terminationStatus))" }
                else if !["Completed", "Aborted", "Error", "Closed", "Exited"].contains(info.status) { info.status = "Exited" }
                info.updatedAt = nowMillis()
                info.heartbeatAt = info.updatedAt
                try? writeJSON(info, to: file)
            }
            try? child.1.close()
            children.removeValue(forKey: id)
        }
        let instances = loadInstances(root: root)
        let live = deduplicateSessions(instances).filter { $0.isLive() }
        phase = (phase + 1) % 4
        if let button = item.button {
            let title = menubarTitle(instances, phase: phase)
            button.title = title
            button.attributedTitle = menubarAttributedTitle(instances, phase: phase)
            button.setAccessibilityLabel(title)
        }
        item.button?.toolTip = "Pi Overview · \(live.filter { $0.busy }.count) busy · \(live.filter { !$0.busy }.count) idle"
        try? writeJSON(["pid": Double(ProcessInfo.processInfo.processIdentifier), "heartbeatAt": nowMillis()], to: root.appendingPathComponent("daemon.json"))
        let command = root.appendingPathComponent("daemon-command.json")
        if let data = try? Data(contentsOf: command) {
            try? FileManager.default.removeItem(at: command)
            if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               value["action"] as? String == "quit", let time = value["createdAt"] as? Double,
               nowMillis() >= time, nowMillis() - time < 10000 { NSApp.terminate(nil) }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.removeAll()
        contributionMenus.reset()
        do { agentComposer.configure(directory: try launcher().cwd) }
        catch { agentComposer.configure(directory: nil, error: error.localizedDescription) }
        let composerItem = NSMenuItem(title: "New agent", action: nil, keyEquivalent: "")
        composerItem.view = agentComposer
        menu.addItem(composerItem)
        menu.addItem(.separator())
        let registrations = loadInstances(root: root)
        let instances = deduplicateSessions(registrations)
        if instances.isEmpty { menu.addItem(entry("No Pi instances", enabled: false)) }
        for info in instances {
            let live = info.isLive()
            let state = agentState(info)
            let badges = badgeText(info)
            let name = displayText(info.sessionName ?? info.projectName, limit: 60)
            let status = displayText(live || info.closed ? info.displayStatus : "Disconnected", limit: 50)
            let heading = entry("\(name) · \(status)" + (badges.isEmpty ? "" : " " + badges))
            applyStatusIcon(heading, state: state)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let statusRow = entry(status, enabled: false)
            applyStatusIcon(statusRow, state: state)
            submenu.addItem(statusRow)
            submenu.addItem(entry(displayText(info.cwd, limit: 180), enabled: false))
            submenu.addItem(entry("PID \(info.pid) · \(info.id.prefix(8))", enabled: false))
            submenu.addItem(entry(info.lastOutput.isEmpty ? "No assistant output yet" : displayText(info.lastOutput, limit: 60), enabled: false))
            if !info.lastOutput.isEmpty {
                submenu.addItem(entry("Copy Output Preview") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.lastOutput, forType: .string)
                })
            }
            addContributions(info, to: submenu)
            submenu.addItem(.separator())
            submenu.addItem(entry("Open Project in Terminal") { [weak self] in self?.openTerminal(info, resume: false) })
            submenu.addItem(entry("Resume This Session in Terminal", enabled: canResume(info, among: registrations)) { [weak self] in self?.openTerminal(info, resume: true) })
            if let log = info.logFile, FileManager.default.fileExists(atPath: log) {
                submenu.addItem(entry("Open Run Log") { NSWorkspace.shared.open(URL(fileURLWithPath: log)) })
            }
            if let session = info.sessionFile, FileManager.default.fileExists(atPath: session) {
                submenu.addItem(entry("Reveal Session File") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session)]) })
            }
            submenu.addItem(.separator())
            submenu.addItem(entry("Abort Run", enabled: live && info.busy && info.pid > 0) { [weak self] in self?.control(info, action: "abort") })
            submenu.addItem(entry("Quit Pi Instance…", enabled: live && info.pid > 0) { [weak self] in self?.control(info, action: "shutdown") })
            heading.submenu = submenu
            menu.addItem(heading)
        }
        menu.addItem(.separator())
        menu.addItem(entry("Clear Finished Entries") { [weak self] in
            guard let self = self else { return }
            for info in loadInstances(root: self.root) where info.closed || (!info.processAlive && !info.isLive()) {
                try? FileManager.default.removeItem(at: self.root.appendingPathComponent("records/\(info.id).json"))
            }
            self.tick()
        })
        menu.addItem(entry("Open Overview Folder") { [weak self] in if let root = self?.root { NSWorkspace.shared.open(root) } })
        menu.addItem(entry("Quit Menu Bar (Keep Pi Running)") { NSApp.terminate(nil) })
    }

    func addContributions(_ info: InstanceInfo, to menu: NSMenu) {
        let sections = menuContributions(info).flatMap { $0.sections }.filter { !$0.items.isEmpty }
        guard !sections.isEmpty else { return }
        menu.addItem(.separator())
        for section in sections {
            let heading = entry(displayText(section.title, limit: 40))
            heading.submenu = contributionMenus.makeItemsMenu(section.items, phase: phase)
            menu.addItem(heading)
        }
    }

    func entry(_ title: String, enabled: Bool = true, action: (() -> Void)? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action == nil ? nil : #selector(MenuAction.invoke), keyEquivalent: "")
        if let action = action {
            let target = MenuAction(action)
            actions.append(target)
            item.target = target
        }
        item.isEnabled = enabled
        return item
    }

    func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pi Overview"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func launcher() throws -> Launcher {
        let value = try JSONDecoder().decode(Launcher.self, from: Data(contentsOf: root.appendingPathComponent("launcher.json")))
        try value.validate()
        return value
    }

    func control(_ info: InstanceInfo, action: String) {
        if action == "shutdown" {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit Pi in \(displayText(info.projectName))?"
            alert.informativeText = "This requests an orderly shutdown of PID \(info.pid), including its background jobs."
            alert.addButton(withTitle: "Quit Instance")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try requestControl(info, action: action, root: root) } catch { showError(error) }
    }

    func launch(_ config: Launcher, prompt: String) throws {
        let cwd = try config.newAgentDirectory().path
        let id = UUID().uuidString.lowercased()
        let session = root.appendingPathComponent("sessions/\(id).jsonl").path
        let log = root.appendingPathComponent("logs/\(id).log")
        let record = root.appendingPathComponent("records/\(id).json")
        var info = InstanceInfo(id: id, token: UUID().uuidString.lowercased(), pid: 0, cwd: cwd,
                                projectName: URL(fileURLWithPath: cwd).lastPathComponent, sessionFile: session,
                                logFile: log.path, status: "Starting", busy: true, closed: false,
                                lastOutput: "", updatedAt: nowMillis(), heartbeatAt: nowMillis())
        try writeJSON(info, to: record)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.node)
        process.arguments = config.backgroundArguments(session: session)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["PI_OVERVIEW_DIR"] = root.path
        environment["PI_OVERVIEW_LAUNCH_ID"] = id
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            children[id] = (process, handle)
            DispatchQueue.global(qos: .utility).async {
                try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
            }
        } catch {
            try? handle.close()
            info.closed = true
            info.busy = false
            info.status = "Launch failed"
            info.lastOutput = error.localizedDescription
            try? writeJSON(info, to: record)
            throw error
        }
        tick()
    }

    func openTerminal(_ info: InstanceInfo, resume: Bool) {
        do {
            let config = try launcher()
            if resume && !canResume(info, among: loadInstances(root: root)) {
                throw OverviewError.message("This session is still active or no longer available. Open the project instead; concurrent session writers are not started.")
            }
            let args = resume ? config.resumeArguments(session: info.sessionFile!) : []
            let process = Process()
            let ghostty = "/Applications/Ghostty.app"
            if FileManager.default.fileExists(atPath: ghostty) {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-na", ghostty, "--args", "--working-directory=\(info.cwd)"] + (args.isEmpty ? [] : ["-e"] + args)
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "on run argv\ntell application \"Terminal\"\nactivate\ndo script (item 1 of argv)\nend tell\nend run", "--", terminalCommand(cwd: info.cwd, arguments: args)]
            }
            try process.run()
        } catch { showError(error) }
    }
}

umask(0o077)
guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
    fputs("Usage: pi-overview <absolute-state-directory>\n", stderr)
    exit(64)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
} catch { fputs("Cannot create overview directory: \(error)\n", stderr); exit(1) }
let lock = open(root.appendingPathComponent("daemon.lock").path, O_CREAT | O_RDWR, 0o600)
guard lock >= 0 else { fputs("Cannot open overview lock\n", stderr); exit(1) }
guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(root: root)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
close(lock)
