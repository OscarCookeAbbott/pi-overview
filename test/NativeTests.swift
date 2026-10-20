import Foundation
import Darwin

@main
struct NativeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func testSessionDeduplication(root: URL, template: InstanceInfo) throws {
        let sessionId = UUID().uuidString.lowercased()
        let sharedSession = root.appendingPathComponent("finished-session.jsonl")
        try Data("{\"type\":\"session\",\"id\":\"\(sessionId)\"}\n".utf8).write(to: sharedSession)
        var finished = template
        finished.sessionFile = sharedSession.path
        finished.busy = false
        finished.status = "Completed"
        finished.updatedAt = nowMillis()
        finished.heartbeatAt = finished.updatedAt
        var oldRegistration = finished
        oldRegistration.id = UUID().uuidString.lowercased()
        oldRegistration.updatedAt -= 1000
        try writeJSON(finished, to: root.appendingPathComponent("records/\(finished.id).json"))
        try writeJSON(oldRegistration, to: root.appendingPathComponent("records/\(oldRegistration.id).json"))
        let registrations = loadInstances(root: root)
        expect(menubarTitle(registrations) == "π  ✓ 1", "reload registrations of the same finished session count once")
        expect(deduplicateSessions(registrations).map { $0.id } == [finished.id], "the newest finished registration supplies the menu row")
        expect(registrations.count == 2, "deduplication preserves raw records for cleanup and control safety")
        finished.closed = true
        finished.pid = 0
        finished.sessionId = sessionId
        oldRegistration.closed = true
        oldRegistration.pid = 0
        let copiedSession = root.appendingPathComponent("copied-session.jsonl")
        try FileManager.default.copyItem(at: sharedSession, to: copiedSession)
        oldRegistration.sessionFile = copiedSession.path
        expect(deduplicateSessions([oldRegistration, finished]).map { $0.id } == [finished.id], "closed reload registrations dedupe by header ID even across different paths")
        var live = finished
        live.id = UUID().uuidString.lowercased()
        live.pid = getpid()
        live.closed = false
        live.updatedAt -= 2000
        expect(deduplicateSessions([finished, live]).map { $0.id } == [live.id], "a live registration wins over a newer closed snapshot")
        live.heartbeatAt -= 20000
        expect(deduplicateSessions([finished, live]).map { $0.id } == [live.id], "an existing writer is not hidden behind a finished record")
        var other = finished
        other.id = UUID().uuidString.lowercased()
        other.sessionId = UUID().uuidString.lowercased()
        expect(deduplicateSessions([finished, other]).count == 2, "different session IDs are not merged by name, directory or path")
        var unknown = finished
        unknown.sessionId = nil
        unknown.sessionFile = root.appendingPathComponent("missing-session").path
        unknown.id = UUID().uuidString.lowercased()
        var anotherUnknown = unknown
        anotherUnknown.id = UUID().uuidString.lowercased()
        expect(deduplicateSessions([unknown, anotherUnknown]).count == 2, "unknown session identities remain separate")
        var staleStarting = finished
        staleStarting.id = UUID().uuidString.lowercased()
        staleStarting.closed = false
        staleStarting.heartbeatAt -= 20000
        staleStarting.updatedAt -= 1000
        expect(deduplicateSessions([staleStarting, finished]).map { $0.id } == [finished.id], "stale launch placeholders do not hide newer finished sessions")
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-overview-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("records"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("commands"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let session = root.appendingPathComponent("session 'quoted'.jsonl")
        try Data("session".utf8).write(to: session)
        var info = InstanceInfo(id: id, token: UUID().uuidString.lowercased(), pid: getpid(), cwd: root.path,
                                projectName: "Example", sessionFile: session.path, status: "Thinking", busy: true,
                                closed: false, lastOutput: "Preview", updatedAt: nowMillis(), heartbeatAt: nowMillis())
        let file = root.appendingPathComponent("records/\(id).json")
        try writeJSON(info, to: file)
        expect(InstanceInfo.read(file)?.id == id, "snapshot round-trip")
        expect(info.isLive(), "fresh live process")
        var complete = info
        complete.id = UUID().uuidString.lowercased()
        complete.busy = false
        complete.status = "Completed"
        expect(menubarTitle([]) == "π", "no separator without counts")
        expect(menubarTitle([info, complete]) == "π  ▶ 1 ✓ 1", "Pi and state counts are separated by exactly two spaces")
        expect(agentSymbol(complete) == "✓" && itemSymbol("failed") == "✕", "popup state symbols")
        expect(itemSymbol("running", phase: 1) == "▶", "running uses an unenclosed play triangle")
        var idle = complete
        idle.id = UUID().uuidString
        idle.status = "Idle"
        expect(agentState(idle) == "pending" && agentSymbol(idle) == "‖", "idle sessions use plain pause bars, not a completion checkmark")
        expect(menubarTitle([info, complete, idle]) == "π  ▶ 1 ✓ 1 ‖ 1", "idle count uses the shared pause fallback")
        idle.status = "Ready"
        expect(idle.displayStatus == "Idle" && agentSymbol(idle) == "‖", "legacy Ready records are presented as Idle")
        expect(complete.displayStatus == "Completed", "completion labels remain distinct from idle")
        info.contributions = [
            OverviewContribution(id: "tasks", badge: "3/6 tasks", sections: [OverviewSection(title: "Tasks", items: [
                OverviewItem(title: "[ab] Build", state: "running", detail: "Run tests")
            ])]),
            OverviewContribution(id: "jobs", badge: "2 jobs", sections: [])
        ]
        expect(badgeText(info) == "[3/6 tasks]", "job counts are not shown inline")
        var jobsInfo = info
        jobsInfo.contributions = [OverviewContribution(id: "jobs", badge: "2 jobs", sections: [OverviewSection(title: "Jobs", items: [
            OverviewItem(title: "Running", state: "running", detail: nil), OverviewItem(title: "Old", state: "complete", detail: nil)
        ])])]
        expect(menuContributions(jobsInfo)[0].sections[0].items.count == 1, "legacy menu payloads hide finished jobs")
        jobsInfo.closed = true
        expect(menuContributions(jobsInfo).isEmpty, "closed agents cannot show stale running jobs")
        try writeJSON(info, to: file)
        expect(InstanceInfo.read(file)?.contributions?.count == 2, "contribution snapshot round-trip")
        var large = info
        large.contributions = [OverviewContribution(id: "large", badge: "3000 tasks", sections: [OverviewSection(title: "Tasks", items:
            (0..<3000).map { OverviewItem(title: "Task \($0)", state: "pending", detail: String(repeating: "x", count: 120)) }
        )])]
        try writeJSON(large, to: file)
        expect(InstanceInfo.read(file)?.contributions?[0].sections[0].items.count == 3000, "large lists are not discarded by a snapshot-size cap")
        try writeJSON(info, to: file)
        expect(!info.isLive(now: info.heartbeatAt + 20000), "stale heartbeat is not live")
        expect(!canResume(info, among: [info]), "never resume a live writer")
        try requestControl(info, action: "abort", root: root)
        let command = root.appendingPathComponent("commands/\(id).json")
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: command)) as? [String: Any] else {
            throw OverviewError.message("Invalid control JSON")
        }
        expect(value["token"] as? String == info.token && value["action"] as? String == "abort", "mailbox control is addressed to current token")
        try FileManager.default.removeItem(at: command)
        var replacement = info
        replacement.token = UUID().uuidString.lowercased()
        try writeJSON(replacement, to: file)
        do { try requestControl(info, action: "shutdown", root: root); expect(false, "stale token accepted") } catch {}
        expect(!FileManager.default.fileExists(atPath: command.path), "no command for a replaced instance")
        info.closed = true
        info.busy = false
        expect(!canResume(info, among: [info]), "reload snapshots cannot resume while the original process remains alive")
        info.pid = 0
        expect(canResume(info, among: [info]), "inactive exact session can be resumed")
        var other = replacement
        other.id = UUID().uuidString.lowercased()
        expect(!canResume(info, among: [info, other]), "another live writer blocks resume")
        let launcher = Launcher(node: "/node with spaces", cli: "/pi '$HOME'.js", extensionPath: "/extension.ts", cwd: root.path)
        let newAgentDirectory = try launcher.newAgentDirectory()
        expect(newAgentDirectory.path == root.path, "new agents use the configured directory directly")
        for invalid in ["relative", root.appendingPathComponent("missing").path, session.path] {
            let invalidLauncher = Launcher(node: launcher.node, cli: launcher.cli, extensionPath: launcher.extensionPath, cwd: invalid)
            do {
                _ = try invalidLauncher.newAgentDirectory()
                expect(false, "missing, non-directory or relative launch directory accepted")
            } catch {}
        }
        let args = launcher.backgroundArguments(session: session.path)
        expect(args == [launcher.cli, "--print", "--session", session.path, "--extension", launcher.extensionPath], "structured launch arguments")
        expect(!args.contains(where: { $0.contains("--approve") || $0 == "-c" }), "no automatic trust or shell evaluation")
        expect(shellQuote("a'b $HOME") == "'a'\\''b $HOME'", "POSIX quotes protect apostrophes and expansion")
        let terminal = terminalCommand(cwd: "/tmp/$(touch NEVER) 'quoted'", arguments: launcher.resumeArguments(session: session.path))
        expect(terminal.contains(shellQuote(session.path)) && terminal.contains(shellQuote(launcher.node)), "Terminal resume paths are quoted data")
        expect(displayText("a\nb\u{1b}c") == "a b c", "menu control characters removed")
        expect(displayText(String(repeating: "x", count: 100), limit: 60).count == 60, "recent output is limited to 60 characters")
        info.updatedAt = nowMillis() - 8 * 86400000
        info.heartbeatAt = info.updatedAt
        try writeJSON(info, to: file)
        expect(loadInstances(root: root).isEmpty, "expired closed snapshots are pruned")
        expect(FileManager.default.fileExists(atPath: session.path), "pruning never deletes session history")
        try testSessionDeduplication(root: root, template: replacement)
        print("Native model tests passed: snapshots, liveness, token controls, resume exclusion, launch arguments and quoting.")
    }
}
