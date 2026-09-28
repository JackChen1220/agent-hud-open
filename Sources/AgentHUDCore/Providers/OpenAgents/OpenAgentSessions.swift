import AgentHUDSupport
import Foundation

public enum OpenAgentSource: String, CaseIterable, Sendable {
    case opencode, kimi, glm, pi
    public var name: String {
        switch self { case .opencode: "OpenCode"; case .kimi: "Kimi"; case .glm: "GLM"; case .pi: "Pi" }
    }
    public var detail: String {
        self == .glm ? L10n.text("国内 / 国际 Coding Plan，按计费池去重", "China / Global Coding Plan, grouped by billing pool")
            : L10n.text("本地会话与用量；共享供应商额度只计一次", "Local sessions and usage; shared provider quota counted once")
    }
    public func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if self == .glm { return OpenAgentCredentials.discover(home: home, environment: environment).contains { $0.pool.provider == "GLM" } }
        return OpenAgentPaths(home: home, environment: environment).roots(for: self).contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct OpenAgentPaths: Sendable {
    let home: URL
    let environment: [String: String]
    var openCode: URL { URL(fileURLWithPath: environment["XDG_DATA_HOME"] ?? home.appendingPathComponent(".local/share").path).appendingPathComponent("opencode") }
    var pi: URL { URL(fileURLWithPath: environment["PI_CODING_AGENT_DIR"] ?? home.appendingPathComponent(".pi/agent").path) }
    var piTurns: URL { pi.appendingPathComponent("agent-hud/turns") }
    var kimi: URL { URL(fileURLWithPath: environment["KIMI_CODE_HOME"] ?? home.appendingPathComponent(".kimi-code").path) }
    func roots(for source: OpenAgentSource) -> [URL] {
        switch source {
        case .opencode: [openCode]
        case .pi: [pi.appendingPathComponent("sessions")]
        case .kimi: [kimi.appendingPathComponent("sessions"), home.appendingPathComponent(".kimi/sessions")]
        case .glm: []
        }
    }
}

struct OpenAgentSession: Sendable {
    var id: String
    var client: OpenAgentSource
    var title: String
    var workspace: String?
    var path: String
    var events: [UsageEvent] = []
    var models: [String: String] = [:]
    var currentModel: (id: String, name: String, provider: String)?
    var start: Date?
    var end: Date?
    var turns: [SessionTurn] = []
    var completions: [SessionCompletion] = []

    /// A consumer is the model as the log names it, which the price catalog reads, and after `#` a hash of the provider
    /// the calls went through, which keeps routes to the same model apart.
    mutating func setModel(_ model: String, provider: String) {
        let id = "\(client.rawValue)-model:\(model)#" + RecordCoding.hash([provider])
        models[id] = model
        currentModel = (id, model, provider)
    }

    /// - input, output: including `cacheWrite` and `reasoning`.
    mutating func add(id eventID: String, model: String, provider: String, at: Date, input: Int, output: Int,
                      cacheRead: Int, cacheWrite: Int = 0, reasoning: Int = 0) throws {
        _ = try TokenCount.sum(input, output, cacheRead)
        setModel(model, provider: provider)
        let consumer = currentModel!.id
        events.append(.init(timestamp: at, agentId: consumer, tokensIn: input, tokensOut: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, reasoningTokens: reasoning, eventID: eventID,
            attribution: .init(client: client.name, providerID: provider)))
        start = min(start ?? at, at); end = max(end ?? at, at)
    }
}

/// Provider licenses are listed in THIRD_PARTY_NOTICES.txt.
/// Only metadata and counters leave these parsers; prompts, tool bodies and credentials do not.
enum OpenAgentParser {
    static func jsonLines(_ data: Data, visit: (ProviderJSON, Int) throws -> Void) throws {
        guard data.count <= 64 * 1024 * 1024 else { throw ProviderFailure.limit }
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            try Task.checkCancellation()
            guard let value = try? ProviderJSON.read(Data(line)) else {
                // Writers append the last line concurrently. Interior corruption must be surfaced.
                if index == lines.count - 1 && data.last != 10 { continue }
                throw ProviderFailure.format
            }
            try visit(value, index)
        }
    }

    static func pi(_ data: Data, path: String) throws -> [OpenAgentSession] {
        var session: OpenAgentSession?
        try jsonLines(data) { line, index in
            let type = line["type"].stringValue
            if type == "session", let id = line["id"].stringValue {
                session = .init(id: "pi:\(id)", client: .pi, title: "Pi", workspace: line["cwd"].stringValue, path: path,
                                start: ProviderDate.iso(line["timestamp"].stringValue))
                return
            }
            guard session != nil else { return }
            if type == "session_info", let name = line["name"].stringValue { session?.title = name; return }
            if type == "model_change", let model = line["modelId"].stringValue, let provider = line["provider"].stringValue {
                session?.setModel(model, provider: provider)
                return
            }
            let message = line["message"]
            guard type == "message", message["role"].stringValue == "assistant", message["usage"].objectValue != nil else { return }
            guard let at = ProviderDate.iso(line["timestamp"].stringValue) ?? ProviderDate.milliseconds(message["timestamp"]) else { throw ProviderFailure.format }
            let usage = message["usage"]
            let input = try usage["input"].optionalCounter(), output = try usage["output"].optionalCounter()
            let read = try usage["cacheRead"].optionalCounter(), write = try usage["cacheWrite"].optionalCounter()
            let model = message["model"].stringValue ?? "Unknown", provider = message["provider"].stringValue ?? "Unknown"
            // Pi entry IDs are short. Retain timestamp/provider/model to distinguish unrelated collisions,
            // while forks retaining the original entries collapse to the original request.
            let identity: String
            if let response = message["responseId"].stringValue, !response.isEmpty {
                identity = "pi:response:" + RecordCoding.hash([provider, response])
            } else if let entry = line["id"].stringValue {
                identity = "pi:entry:" + RecordCoding.hash([entry, String(RecordCoding.milliseconds(at)), provider, model])
            } else { identity = "\(session!.id):line:\(index)" }
            try session?.add(id: identity, model: model, provider: provider, at: at, input: try TokenCount.sum(input, write),
                         output: output, cacheRead: read, cacheWrite: write)
            // An assistant stop is not agent_settled; retries, tools and queued followups can still run.
        }
        return session.map { [$0] } ?? []
    }

    static func kimi(_ data: Data, path: String) throws -> [OpenAgentSession] {
        let file = URL(fileURLWithPath: path), directory = file.deletingLastPathComponent()
        let modern = directory.deletingLastPathComponent().lastPathComponent == "agents"
        let sessionID = modern ? directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent : directory.lastPathComponent
        let agent = modern ? directory.lastPathComponent : "main"
        var session = OpenAgentSession(id: "kimi:\(sessionID):\(agent)", client: .kimi, title: "Kimi", path: path)
        var requestModel: String?, keyed: [String: Int] = [:]
        func concrete(_ name: String?) -> String? {
            guard let name, !name.isEmpty, !name.hasPrefix("__") else { return nil }; return name
        }
        try jsonLines(data) { line, index in
            let type = line["type"].stringValue
            if modern {
                if agent == "main", type == "context.append_loop_event",
                   let turnID = line["event"]["turnId"].stringValue, let at = ProviderDate.milliseconds(line["time"]) {
                    if let position = session.turns.firstIndex(where: { $0.turnID == turnID }) {
                        let previous = session.turns[position]
                        if previous.state == .running, RecordCoding.milliseconds(at) > previous.observedAtMs {
                            session.turns[position] = .init(provider: "Kimi", sessionID: session.id, turnID: turnID,
                                state: .running, startedAtMs: previous.startedAtMs, observedAtMs: RecordCoding.milliseconds(at))
                        }
                    } else if line["event"]["type"].stringValue == "step.begin" {
                        session.turns.append(.init(provider: "Kimi", sessionID: session.id, turnID: turnID,
                            state: .running, startedAtMs: RecordCoding.milliseconds(at), observedAtMs: RecordCoding.milliseconds(at)))
                    }
                    session.start = min(session.start ?? at, at); session.end = max(session.end ?? at, at)
                    return
                }
                if type == "llm.request" { requestModel = concrete(line["model"].stringValue); return }
                if type == "turn.ended", let turn = line["turnId"].countValue, let at = ProviderDate.milliseconds(line["time"]) {
                    let success = line["reason"].stringValue == "completed" && line["error"] == .null
                    let position = session.turns.firstIndex { $0.turnID == String(turn) }
                    let start = position.flatMap { session.turns[$0].startedAtMs }
                    if agent == "main" {
                        let finished = SessionTurn(provider: "Kimi", sessionID: session.id, turnID: String(turn),
                            state: success ? .completed : .ended, startedAtMs: start, observedAtMs: RecordCoding.milliseconds(at))
                        if let position { session.turns[position] = finished } else { session.turns.append(finished) }
                    }
                    session.end = max(session.end ?? at, at)
                    // Subagent ends cannot complete the parent conversation.
                    if success && agent == "main" {
                        session.completions.append(.init(sessionID: session.id, vendor: "Kimi", turnID: String(turn),
                            task: session.title, model: requestModel ?? "Unknown", startedAt: start.map(RecordCoding.date), completedAt: at))
                    }
                    return
                }
                guard type == "usage.record", line["usageScope"].stringValue == "turn" else { return }
                guard let at = ProviderDate.milliseconds(line["time"]) else { throw ProviderFailure.format }
                let usage = line["usage"]
                let input = try usage["inputOther"].optionalCounter(), read = try usage["inputCacheRead"].optionalCounter()
                let write = try usage["inputCacheCreation"].optionalCounter(), output = try usage["output"].optionalCounter()
                try session.add(id: "\(session.id):usage:\(index)", model: concrete(line["model"].stringValue) ?? requestModel ?? "Unknown",
                    provider: "kimi-code", at: at, input: try TokenCount.sum(input, write), output: output, cacheRead: read, cacheWrite: write)
            } else {
                let message = line["message"], payload = message["payload"]
                guard message["type"].stringValue == "StatusUpdate", payload["token_usage"].objectValue != nil else { return }
                guard let seconds = line["timestamp"].numberValue, seconds > 0, seconds <= 253402300799 else { throw ProviderFailure.format }
                let at = Date(timeIntervalSince1970: seconds), usage = payload["token_usage"]
                let input = try usage["input_other"].optionalCounter(), read = try usage["input_cache_read"].optionalCounter()
                let write = try usage["input_cache_creation"].optionalCounter(), output = try usage["output"].optionalCounter()
                let id = "\(session.id):" + (payload["message_id"].stringValue ?? "line:\(index)")
                let old = keyed[id].map { session.events[$0] }
                try session.add(id: id, model: "Unknown", provider: "Unknown", at: old?.timestamp ?? at,
                    input: try TokenCount.sum(input, write), output: output, cacheRead: read, cacheWrite: write)
                if let position = keyed[id] {
                    let latest = session.events.removeLast()
                    if latest.total >= session.events[position].total { session.events[position] = latest }
                } else { keyed[id] = session.events.count - 1 }
            }
        }
        return [session]
    }

    static func openCodeMessage(_ value: ProviderJSON, id: String, sessionID: String, path: String,
                                title: String? = nil, workspace: String? = nil, assistant: Bool = false) throws -> OpenAgentSession? {
        guard value["role"].stringValue == "assistant" || (assistant && value["role"] == .null) else { return nil }
        guard value["tokens"].objectValue != nil else { return nil }
        guard let at = ProviderDate.milliseconds(value["time"]["created"]) else { throw ProviderFailure.format }
        let tokens = value["tokens"]
        let input = try tokens["input"].optionalCounter(), output = try tokens["output"].optionalCounter()
        let read = try tokens["cache"]["read"].optionalCounter(), write = try tokens["cache"]["write"].optionalCounter()
        let model = value["modelID"].stringValue ?? value["model"]["id"].stringValue ?? "Unknown"
        let provider = value["providerID"].stringValue ?? value["model"]["providerID"].stringValue ?? "Unknown"
        var session = OpenAgentSession(id: "opencode:\(sessionID)", client: .opencode, title: title ?? "OpenCode",
            workspace: workspace ?? value["path"]["root"].stringValue, path: path)
        try session.add(id: "opencode:\(id)", model: model, provider: provider, at: at,
                    input: try TokenCount.sum(input, write), output: try TokenCount.sum(output, tokens["reasoning"].optionalCounter()), cacheRead: read,
                    cacheWrite: write, reasoning: try tokens["reasoning"].optionalCounter())
        session.end = ProviderDate.milliseconds(value["time"]["completed"]) ?? at
        return session
    }

    /// Replies are in `message`, and in `session_message` for sessions of OpenCode's newer kind, whose table also holds
    /// agent and model switches before it holds any reply. The two name one reply by different ids, so a session is read
    /// from `session_message` once that table has its replies, and from `message` until then.
    static func openCodeSQLite(_ url: URL, since: Date = .distantPast) throws -> [OpenAgentSession] {
        let db = try ReadOnlySQLite(url)
        var tables = Set<String>()
        try db.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('session_message', 'message', 'session_v2', 'session')") { row in
            if let name = ReadOnlySQLite.text(row, 0) { tables.insert(name) }
        }
        for table in tables { try db.requireTable(table) }
        let newer = tables.contains("session_message")
        guard newer || tables.contains("message") else { throw ProviderFailure.format }
        var sessions: [OpenAgentSession] = []
        // Prefer SQLite records. Stable message IDs deduplicate JSON records.
        func read(_ messages: String, titles table: String?, where filter: String) throws {
            let metadata = table == nil ? "NULL, NULL" : "s.title, s.directory"
            let join = table.map { "LEFT JOIN \($0) s ON s.id = m.session_id" } ?? ""
            try db.rows("SELECT m.id, m.session_id, m.data, \(metadata) FROM \(messages) m \(join) WHERE \(filter) AND json_extract(m.data, '$.time.created') >= CAST(? AS REAL) ORDER BY m.id DESC", strings: [String(since.timeIntervalSince1970 * 1000)]) { row in
                guard let id = ReadOnlySQLite.text(row, 0), let sid = ReadOnlySQLite.text(row, 1), let raw = ReadOnlySQLite.text(row, 2) else { throw ProviderFailure.format }
                if let item = try openCodeMessage(ProviderJSON.read(Data(raw.utf8)), id: id, sessionID: sid, path: url.path,
                    title: ReadOnlySQLite.text(row, 3), workspace: ReadOnlySQLite.text(row, 4), assistant: messages == "session_message") {
                    sessions.append(item)
                }
            }
        }
        if newer {
            try read("session_message", titles: ["session_v2", "session"].first(where: tables.contains), where: "m.type = 'assistant'")
        }
        if tables.contains("message") {
            try read("message", titles: ["session", "session_v2"].first(where: tables.contains), where: "json_extract(m.data, '$.role') = 'assistant'"
                + (newer ? " AND m.session_id NOT IN (SELECT session_id FROM session_message WHERE type = 'assistant' AND session_id IS NOT NULL)" : ""))
        }
        return sessions
    }
}
