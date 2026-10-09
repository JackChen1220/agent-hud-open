import AgentHUDSupport
import Foundation

/// Kiro CLI rewrites these snapshots after completed turns. Read only the metadata, never the transcript JSONL.
/// Some versions fill token counters with zero while reporting credits; neither credits nor context percentages
/// can recover the missing token counts.
enum KiroSessions: LocalSessionLayout {
    static let installPaths = [".kiro/sessions/cli"]

    static func roots(home: URL, environment: [String: String]) -> [URL] {
        [home.appendingPathComponent(".kiro/sessions/cli")]
    }

    static func accepts(_ url: URL) -> Bool { url.pathExtension == "json" }

    static func read(_ url: URL) throws -> ProviderSessions {
        try parse(ProviderFiles.json(url), path: url.path)
    }

    static func parse(_ json: ProviderJSON, path: String) throws -> ProviderSessions {
        guard let rawID = json["session_id"].stringValue, !rawID.isEmpty,
              let turns = json["session_state"]["conversation_metadata"]["user_turn_metadatas"].arrayValue else {
            throw ProviderFailure.format
        }
        let id = "kiro:" + rawID
        var session = ProviderSession(id: id,
            title: json["title"].stringValue.flatMap(SessionTitle.from) ?? "Kiro CLI · \(rawID.prefix(8))",
            workspace: json["cwd"].stringValue, path: path, client: "Kiro CLI",
            startedAt: ProviderDate.iso(json["created_at"].stringValue),
            lastActivity: ProviderDate.iso(json["updated_at"].stringValue))
        var seen = Set<String>(), incomplete = false
        for turn in turns {
            guard let date = ProviderDate.iso(turn["end_timestamp"].stringValue) else { incomplete = true; continue }
            // A completed turn has one end time even if the same record occurs twice in a rewritten snapshot.
            let key = RecordCoding.hash([id, turn["end_timestamp"].stringValue!])
            guard seen.insert(key).inserted else { continue }
            let model = turn["model"].stringValue ?? "Unknown"
            var hasTokens = false
            do {
                let input = try turn["input_token_count"].optionalCounter()
                let output = try turn["output_token_count"].optionalCounter()
                let read = try turn["cache_read_input_token_count"].optionalCounter()
                let write = try turn["cache_write_input_token_count"].optionalCounter()
                let fresh = try TokenCount.sum(input, write)
                hasTokens = try TokenCount.sum(fresh, output, read) > 0
                if hasTokens {
                    session.events.append(ProviderEvent(id: key, model: model, timestamp: date,
                        input: fresh, output: output, cacheRead: read, cacheWrite: write))
                }
            } catch { incomplete = true }
            let meters = turn["metering_usage"].arrayValue ?? []
            let credits = meters.filter { $0["unit"].stringValue?.lowercased() == "credit" || $0["unit"].stringValue?.lowercased() == "credits" }
            let amounts = credits.compactMap { $0["value"].numberValue }.filter { $0.isFinite && $0 >= 0 }
            let total = amounts.reduce(0, +)
            let validCredits = !credits.isEmpty && amounts.count == credits.count && total.isFinite
            if !credits.isEmpty && !validCredits { incomplete = true }
            session.localUsage.append(LocalUsageRecord(id: key, timestamp: date, model: model,
                credits: validCredits ? total : nil, hasTokenCounts: hasTokens))
            session.startedAt = min(session.startedAt ?? date, date)
            session.lastActivity = max(session.lastActivity ?? date, date)
            let success = turn["end_reason"].stringValue == "UserTurnEnd" && turn["result"]["Ok"] != .null
            let duration = turn["turn_duration"]["secs"].numberValue
            let start = duration.flatMap { $0.isFinite && $0 >= 0 ? date.addingTimeInterval(-$0) : nil }
            session.turns.append(SessionTurn(provider: "Kiro", sessionID: id, turnID: key,
                state: success ? .completed : .ended, startedAtMs: start.map(RecordCoding.milliseconds),
                observedAtMs: RecordCoding.milliseconds(date)))
            if success {
                session.completions.append(SessionCompletion(sessionID: id, vendor: "Kiro", turnID: key,
                    task: session.title, model: model, startedAt: start, completedAt: date))
            }
        }
        session.localUsage.sort { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
        return ProviderSessions(sessions: [session], notice: incomplete
            ? L10n.text("部分 Kiro CLI 记录缺少时间或有效计数，用量可能不完整", "Some Kiro CLI records lack a time or valid counts; usage may be incomplete") : nil)
    }
}
