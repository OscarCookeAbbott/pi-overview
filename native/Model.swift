import Foundation
import Darwin

struct OverviewItem: Codable {
    let title: String
    let state: String?
    let detail: String?
}
struct OverviewSection: Codable {
    let title: String
    let items: [OverviewItem]
}
struct OverviewContribution: Codable {
    let id: String
    let badge: String
    let sections: [OverviewSection]
}

struct InstanceInfo: Codable {
    var version = 1
    var id: String
    var token: String
    var pid: Int32
    var cwd: String
    var projectName: String
    var sessionFile: String?
    var sessionName: String?
    var logFile: String?
    var status: String
    var busy: Bool
    var closed: Bool
    var lastOutput: String
    var updatedAt: Double
    var heartbeatAt: Double
    var contributions: [OverviewContribution]? = nil

    var processAlive: Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func isLive(now: Double = nowMillis()) -> Bool {
        guard !closed, now >= heartbeatAt, now - heartbeatAt < 15000 else { return false }
        return processAlive || (pid == 0 && status == "Starting")
    }

    static func read(_ url: URL) -> InstanceInfo? {
        guard url.pathExtension == "json",
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 262145) <= 262144,
              let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(InstanceInfo.self, from: data),
              info.version == 1, UUID(uuidString: info.id) != nil, UUID(uuidString: info.token) != nil,
              url.deletingPathExtension().lastPathComponent == info.id, info.pid >= 0,
              info.cwd.hasPrefix("/"), info.updatedAt.isFinite, info.heartbeatAt.isFinite else { return nil }
        return info
    }
}

struct Launcher: Decodable {
    let node: String
    let cli: String
    let extensionPath: String
    let cwd: String

    func validate() throws {
        for path in [node, cli, extensionPath] {
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
                throw OverviewError.message("Pi launch configuration is unavailable. Start or reload an installed Pi instance first.")
            }
        }
    }

    func backgroundArguments(session: String) -> [String] {
        // Prompt data goes to stdin, never through a shell, flags, or @file expansion.
        [cli, "--print", "--session", session, "--extension", extensionPath]
    }

    func resumeArguments(session: String) -> [String] { [node, cli, "--session", session] }
}

enum OverviewError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func nowMillis() -> Double { Date().timeIntervalSince1970 * 1000 }
func displayText(_ text: String, limit: Int = 160) -> String {
    String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(limit))
}
func itemSymbol(_ state: String?, phase: Int = 0) -> String {
    switch state {
    case "running": return ["◐", "◓", "◑", "◒"][phase % 4]
    case "complete": return "✓"
    case "failed": return "✕"
    case "waiting": return "…"
    case "cancelled": return "⊘"
    case "pending": return "○"
    default: return "•"
    }
}
func agentSymbol(_ info: InstanceInfo, phase: Int = 0) -> String {
    if !info.isLive() && !info.closed { return "?" }
    if info.busy { return itemSymbol("running", phase: phase) }
    if info.status.hasPrefix("Error") || info.status == "Launch failed" { return "✕" }
    if info.status == "Completed" { return "✓" }
    if info.status == "Aborted" || info.status == "Closed" || info.status == "Exited" { return "⊘" }
    return "○"
}
func menubarTitle(_ instances: [InstanceInfo], phase: Int = 0) -> String {
    let live = instances.filter { $0.isLive() }
    guard !live.isEmpty else { return "π" }
    let running = live.filter { $0.busy }.count
    let completed = live.filter { !$0.busy && $0.status == "Completed" }.count
    let failed = live.filter { !$0.busy && $0.status.hasPrefix("Error") }.count
    let waiting = live.count - running - completed - failed
    var counts: [String] = []
    if running > 0 { counts.append("\(itemSymbol("running", phase: phase)) \(running)") }
    if completed > 0 { counts.append("✓ \(completed)") }
    if failed > 0 { counts.append("✕ \(failed)") }
    if waiting > 0 { counts.append("○ \(waiting)") }
    return "π · " + counts.joined(separator: " ")
}
func badgeText(_ info: InstanceInfo) -> String {
    (info.contributions ?? []).prefix(4).filter { !$0.badge.isEmpty }.map { "[\(displayText($0.badge, limit: 40))]" }.joined(separator: " ")
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func terminalCommand(cwd: String, arguments: [String]) -> String {
    "cd -- " + shellQuote(cwd) + (arguments.isEmpty ? "" : " && exec " + arguments.map(shellQuote).joined(separator: " "))
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func loadInstances(root: URL, now: Double = nowMillis()) -> [InstanceInfo] {
    let records = root.appendingPathComponent("records")
    let files = (try? FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return files.compactMap { file -> InstanceInfo? in
        guard let info = InstanceInfo.read(file) else { return nil }
        if !info.isLive(now: now), (info.closed || !info.processAlive), now - info.updatedAt > 7 * 86400000 {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return info
    }.sorted {
        let left = $0.isLive(now: now), right = $1.isLive(now: now)
        return left == right ? $0.updatedAt > $1.updatedAt : left
    }
}

func canResume(_ info: InstanceInfo, among instances: [InstanceInfo]) -> Bool {
    guard let session = info.sessionFile, FileManager.default.fileExists(atPath: session),
          !info.isLive(), !info.processAlive, !(info.pid == 0 && !info.closed) else { return false }
    return !instances.contains { other in
        other.id != info.id && other.sessionFile == session && !other.closed && (other.isLive() || other.processAlive || other.pid == 0)
    }
}

struct ControlRequest: Encodable {
    let token: String
    let action: String
    let createdAt: Double
}

func requestControl(_ info: InstanceInfo, action: String, root: URL) throws {
    let file = root.appendingPathComponent("records/\(info.id).json")
    guard let current = InstanceInfo.read(file), current.token == info.token, current.pid > 0, current.isLive(),
          action == "abort" || action == "shutdown" else {
        throw OverviewError.message("This Pi instance is no longer responding. No process was signalled.")
    }
    try writeJSON(ControlRequest(token: current.token, action: action, createdAt: nowMillis()), to: root.appendingPathComponent("commands/\(current.id).json"))
}
