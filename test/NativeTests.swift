import Foundation
import Darwin

@main
struct NativeTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
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
        let args = launcher.backgroundArguments(session: session.path)
        expect(args == [launcher.cli, "--print", "--session", session.path, "--extension", launcher.extensionPath], "structured launch arguments")
        expect(!args.contains(where: { $0.contains("--approve") || $0 == "-c" }), "no automatic trust or shell evaluation")
        expect(shellQuote("a'b $HOME") == "'a'\\''b $HOME'", "POSIX quotes protect apostrophes and expansion")
        let terminal = terminalCommand(cwd: "/tmp/$(touch NEVER) 'quoted'", arguments: launcher.resumeArguments(session: session.path))
        expect(terminal.contains(shellQuote(session.path)) && terminal.contains(shellQuote(launcher.node)), "Terminal resume paths are quoted data")
        expect(displayText("a\nb\u{1b}c") == "a b c", "menu control characters removed")
        info.updatedAt = nowMillis() - 8 * 86400000
        info.heartbeatAt = info.updatedAt
        try writeJSON(info, to: file)
        expect(loadInstances(root: root).isEmpty, "expired closed snapshots are pruned")
        expect(FileManager.default.fileExists(atPath: session.path), "pruning never deletes session history")
        print("Native model tests passed: snapshots, liveness, token controls, resume exclusion, launch arguments and quoting.")
    }
}
