import Foundation

/// Bot owns its account-scoped session metadata; Cursor owns the dashboard's billing events. Join their exact native
/// conversation identities for display without copying events to another source or inferring Cloud Agent children.
enum GrokBotUsage {
    static func merge(_ sessions: [LiveSession]) -> [LiveSession] {
        let billed = Dictionary(grouping: sessions.filter {
            $0.client == "Cursor" && conversationID($0.id) != nil
        }, by: { conversationID($0.id)! })
        let bots = Dictionary(grouping: sessions.filter {
            $0.client == "Grok Bot" && nativeID($0) != nil
        }, by: { nativeID($0)! })
        var joined: [String: LiveSession] = [:], consumed = Set<String>()
        for (id, candidates) in bots {
            guard candidates.count == 1, let bot = candidates.first,
                  let usage = billed[id], usage.count == 1, let bill = usage.first else { continue }
            joined[bot.id] = LiveSession(id: bot.id, agentId: bill.agentId, task: bot.task, terminal: bot.terminal,
                startedAt: min(bot.startedAt, bill.startedAt), endedAt: bot.endedAt.map { max($0, bill.endedAt ?? $0) },
                pctOfWindow: bill.pctOfWindow, tokensIn: bill.tokensIn, tokensOut: bill.tokensOut, client: bot.client,
                transcriptPath: bot.transcriptPath, cacheReadTokens: bill.cacheReadTokens, accountWide: bill.accountWide,
                observedAt: bot.observedAt, workingDirectory: bot.workingDirectory,
                subagentTranscripts: bot.subagentTranscripts, agentName: bot.agentName, subagentSessions: bot.subagentSessions,
                lastActivityAt: max(bot.lastActivityAt ?? bot.startedAt, bill.lastActivityAt ?? bill.startedAt),
                navigationTarget: bot.navigationTarget, usageKey: bill.id)
            consumed.insert(bill.id)
        }
        return sessions.compactMap { consumed.contains($0.id) ? nil : joined[$0.id] ?? $0 }
    }

    private static func conversationID(_ id: String) -> String? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "cursor-account", !parts[1].isEmpty,
              GrokBotCache.isAgentID(String(parts[2])) else { return nil }
        return String(parts[2])
    }

    private static func nativeID(_ session: LiveSession) -> String? {
        guard case .grokBotAgent(let id) = session.navigationTarget else { return nil }
        let parts = session.id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "grok-bot", !parts[1].isEmpty, parts[2] == id else { return nil }
        return id
    }
}
