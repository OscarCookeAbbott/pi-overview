import Foundation
import Darwin

struct OverviewItem: Codable {
    let title: String
    let state: String?
    let detail: String?
    var children: [OverviewItem]? = nil
    var kind: String? = nil
    var subtitle: String? = nil
    var body: String? = nil
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
    var sessionId: String?
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
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
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

    func newAgentDirectory() throws -> URL {
        var isDirectory: ObjCBool = false
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OverviewError.message("The configured new-agent directory is unavailable: \(cwd). Update overview.defaultDirectory and reload Pi.")
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
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
    case "running": return "🔄"
    case "complete": return "✓"
    case "failed": return "✕"
    case "waiting": return "…"
    case "cancelled": return "⊘"
    case "pending": return "○"
    case "unknown": return "?"
    default: return "•"
    }
}
func statusSymbolName(_ state: String?) -> String {
    switch state {
    case "running": return "arrow.triangle.2.circlepath"
    case "complete": return "checkmark"
    case "failed": return "xmark"
    case "waiting": return "ellipsis"
    case "cancelled": return "nosign"
    case "unknown": return "questionmark"
    default: return "circle"
    }
}
func agentState(_ info: InstanceInfo) -> String {
    if !info.isLive() && !info.closed { return "unknown" }
    if info.busy { return "running" }
    if info.status.hasPrefix("Error") || info.status == "Launch failed" { return "failed" }
    if info.status == "Completed" { return "complete" }
    if info.status == "Aborted" || info.status == "Closed" || info.status == "Exited" { return "cancelled" }
    return "pending"
}
func agentSymbol(_ info: InstanceInfo, phase: Int = 0) -> String {
    itemSymbol(agentState(info), phase: phase)
}
func sessionIdentity(_ info: InstanceInfo) -> String? {
    if let id = info.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
        return UUID(uuidString: id)?.uuidString.lowercased() ?? id
    }
    guard let path = info.sessionFile, let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 16384),
          let header = (try? JSONSerialization.jsonObject(with: Data(data.prefix { $0 != 10 }))) as? [String: Any],
          header["type"] as? String == "session",
          let id = (header["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
    return UUID(uuidString: id)?.uuidString.lowercased() ?? id
}

func deduplicateSessions(_ instances: [InstanceInfo], now: Double = nowMillis()) -> [InstanceInfo] {
    let ranked = instances.sorted {
        let leftLive = $0.isLive(now: now), rightLive = $1.isLive(now: now)
        if leftLive != rightLive { return leftLive }
        let leftProcess = $0.processAlive, rightProcess = $1.processAlive
        if leftProcess != rightProcess { return leftProcess }
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        if $0.heartbeatAt != $1.heartbeatAt { return $0.heartbeatAt > $1.heartbeatAt }
        return $0.id < $1.id
    }
    var seen = Set<String>()
    return ranked.filter { info in
        let key = sessionIdentity(info).map { "session:\($0)" } ?? "instance:\(info.id)"
        return seen.insert(key).inserted
    }
}

func menubarTitle(_ instances: [InstanceInfo], phase: Int = 0) -> String {
    let live = deduplicateSessions(instances).filter { $0.isLive() }
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
    return "π  " + counts.joined(separator: " ")
}
func menuContributions(_ info: InstanceInfo) -> [OverviewContribution] {
    (info.contributions ?? []).compactMap { contribution in
        guard contribution.id == "jobs" else { return contribution }
        guard info.isLive() else { return nil }
        let sections = contribution.sections.compactMap { section -> OverviewSection? in
            let items = section.items.filter { $0.state == "running" }
            return items.isEmpty ? nil : OverviewSection(title: "Running jobs", items: items)
        }
        return sections.isEmpty ? nil : OverviewContribution(id: "jobs", badge: "", sections: sections)
    }
}
func badgeText(_ info: InstanceInfo) -> String {
    (info.contributions ?? []).filter { $0.id != "jobs" && !$0.badge.isEmpty }.map { "[\(displayText($0.badge, limit: 40))]" }.joined(separator: " ")
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
