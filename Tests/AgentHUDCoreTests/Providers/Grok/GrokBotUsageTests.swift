import Foundation
import XCTest
@testable import AgentHUDCore

final class GrokBotUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBillingUsageJoinsNativeMetadataWithoutWritingOrDisplayingItTwice() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        try fixture.writeTranscript([fixture.prompt("prompt", sequence: 1), fixture.reply("reply", sequence: 2)])
        var bot = try GrokBotSessions.read(fixture.roster)
        bot.sessions[0].workspace = "/synthetic/project"
        let billing = try CursorClient.parseEvents([
            row(conversation: fixture.agent, model: "grok-bot-default", at: -55, input: 10, output: 5, cache: 20, write: 2),
            row(conversation: fixture.agent, model: "grok-bot-cua", at: -5, input: 30, output: 7, cache: 40, write: 3),
        ], account: "billing-account")
        let billingID = try XCTUnwrap(billing.sessions.first?.id)
        let ledger = UsageLedger.inMemory()
        let provider = combined(bot: bot, billing: billing, ledger: ledger)

        for _ in 0..<2 {
            let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
            let session = try XCTUnwrap(report.sessions.first)
            XCTAssertEqual(report.sessions.count, 1, "the account import and native cache represent one displayed session")
            XCTAssertEqual(session.id, fixture.sessionID)
            XCTAssertEqual(session.client, "Grok Bot")
            XCTAssertEqual(session.task, "Synthetic conversation")
            XCTAssertEqual(session.transcriptPath, fixture.transcript.path)
            XCTAssertEqual(session.workingDirectory, "/synthetic/project")
            XCTAssertEqual(session.navigationTarget, .grokBotAgent(id: fixture.agent))
            XCTAssertEqual(session.usageKey, billingID)
            XCTAssertEqual(session.agentId, "cursor-model:grok-bot-cua")
            XCTAssertEqual(session.tokensIn, 45)
            XCTAssertEqual(session.tokensOut, 12)
            XCTAssertEqual(session.cacheReadTokens, 60)
            XCTAssertTrue(session.accountWide)
            XCTAssertEqual(session.startedAt, now.addingTimeInterval(-60))
            XCTAssertEqual(session.lastActivityAt, now.addingTimeInterval(-5))
            XCTAssertFalse(session.isLive)

            let usage = try XCTUnwrap(report.sessionUsage?[fixture.sessionID])
            XCTAssertEqual(usage.calls, 2)
            XCTAssertEqual(usage.total, .init(tokensIn: 45, tokensOut: 12, cacheReadTokens: 60, cacheWriteTokens: 5))
            XCTAssertNil(usage.subagents, "billing contributions are the Bot's own calls")
            XCTAssertEqual(Set(usage.models.map(\.agentId)), ["cursor-model:grok-bot-default", "cursor-model:grok-bot-cua"])
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 45)
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensOut }, 12)
            XCTAssertEqual(report.usage.reduce(0) { $0 + $1.cacheReadTokens }, 60)
            let billingAccount = ProviderAccount(provider: "Cursor", user: "billing-owner", workspace: "", evidence: .account)
            XCTAssertEqual(Set(report.usage.compactMap(\.account)), [billingAccount.id], "the join preserves the billing account's canonical scope")

            let request = SessionUsageRequest(session)
            XCTAssertTrue(request.keys.contains(billingID))
            XCTAssertTrue(request.subagentKeys.isEmpty)
            let calls = try await ledger.turnCalls(request, from: now.addingTimeInterval(-60), through: now)
            XCTAssertEqual(calls.count, 2)
            XCTAssertTrue(calls.allSatisfy(\.own))
            XCTAssertEqual(Set(calls.map(\.source)), ["cursor"])
            XCTAssertEqual(Set(calls.map(\.log)), [billingID])

            let turns = GrokBotConversation.turns(at: fixture.transcript, sessionID: session.id,
                                                   since: .distantPast, limit: 10, now: now)
            XCTAssertEqual(turns.first?.prompt, "Synthetic prompt")
            XCTAssertEqual(turns.first?.reply, "Synthetic reply")
            let restored = try JSONDecoder().decode(LiveSession.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.usageKey, billingID, "the own-usage reference survives the restart report")
        }

        let contributions = try await ledger.write { writer in
            ["cursor": try writer.contributions(source: "cursor"), "grok": try writer.contributions(source: "grok")]
        }
        XCTAssertEqual(contributions["cursor"], [billingID])
        XCTAssertEqual(contributions["grok"], [], "joining display metadata must not create another metered contribution")
    }

    func testOnlyAnExactNativeIDCanJoin() async throws {
        let bot = metadata(agent: "native-agent")
        let cases: [(String, String)] = [
            ("native-agent-extra", "grok-bot-default"),
            ("native", "grok-bot-default"),
        ]
        for (conversation, model) in cases {
            let billing = try CursorClient.parseEvents([row(conversation: conversation, model: model)], account: "account-a")
            let report = try await combined(bot: bot, billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
            XCTAssertEqual(report.sessions.count, 2)
            let native = try XCTUnwrap(report.sessions.first { $0.client == "Grok Bot" })
            XCTAssertEqual(native.tokensIn, 0)
            XCTAssertNil(native.usageKey)
        }
    }

    func testNativeSubagentNamespaceIdentifiesBotWithoutARosterAndKeepsOneBillingContribution() async throws {
        let ids = ["sand-subagent-11111111-1111-1111-1111-111111111111",
                   "sand-subagent-22222222-2222-2222-2222-222222222222",
                   "sand-subagent-33333333-3333-3333-3333-333333333333"]
        let models = ["grok-bot-default", "grok-bot-cua", "ordinary-model"]
        let billing = try CursorClient.parseEvents(zip(ids, models).map { row(conversation: $0, model: $1) }, account: "billing-account")
        let ledger = UsageLedger.inMemory()
        let report = try await combined(bot: .init(), billing: billing, ledger: ledger)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, 3)
        XCTAssertEqual(Set(report.consumers.map(\.vendor)), ["Cursor"])
        let account = ProviderAccount(provider: "Cursor", user: "billing-owner", workspace: "", evidence: .account)
        XCTAssertEqual(Set(report.usage.compactMap(\.account)), [account.id])
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensIn }, 36)
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.tokensOut }, 15)
        XCTAssertEqual(report.usage.reduce(0) { $0 + $1.cacheReadTokens }, 60)
        XCTAssertEqual(Set(report.sessions.map(\.task)).count, 3, "the native suffix distinguishes each child")
        for (id, model) in zip(ids, models) {
            let key = "cursor-account:billing-account:" + id
            let session = try XCTUnwrap(report.sessions.first { $0.id == key })
            XCTAssertEqual(session.client, "Grok Bot")
            XCTAssertEqual(session.agentId, "cursor-model:" + model)
            XCTAssertTrue(session.task.hasPrefix("Grok Bot"))
            XCTAssertTrue(session.task.hasSuffix(String(id.dropFirst("sand-subagent-".count).prefix(8))))
            XCTAssertTrue(session.accountWide)
            XCTAssertNil(session.usageKey, "the unchanged session ID already addresses its canonical billing contribution")
            XCTAssertNil(session.transcriptPath)
            XCTAssertNil(session.navigationTarget)
            XCTAssertNil(session.subagentSessions, "the child namespace does not identify a parent")
            let source = SessionSource(vendor: "Cursor", client: session.client)
            XCTAssertEqual(source.vendor, "Grok")
            XCTAssertEqual(source.agentVendor, "Grok Bot")
            let usage = try XCTUnwrap(report.sessionUsage?[key])
            XCTAssertEqual(usage.calls, 1)
            XCTAssertEqual(usage.total, .init(tokensIn: 12, tokensOut: 5, cacheReadTokens: 20, cacheWriteTokens: 2))
            XCTAssertEqual(usage.models.map(\.agentId), [session.agentId])
            let calls = try await ledger.turnCalls(SessionUsageRequest(session), from: now.addingTimeInterval(-60), through: now)
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.source, "cursor")
            XCTAssertEqual(calls.first?.log, key)
        }
        let contributions = try await ledger.write { writer in
            ["cursor": try writer.contributions(source: "cursor"), "grok": try writer.contributions(source: "grok")]
        }
        XCTAssertEqual(Set(contributions["cursor"] ?? []), Set(billing.sessions.map(\.id)))
        XCTAssertEqual(contributions["grok"], [])
    }

    func testModelNamesAndSimilarOrMissingIDsDoNotEstablishBotOrigin() async throws {
        let ids: [String?] = ["ordinary-conversation", "sand-subagent", "sand-subagent-", "other-sand-subagent-child",
                              "sand-subagent-child:other", nil]
        let billing = try CursorClient.parseEvents(ids.map { row(conversation: $0) }, account: "account-a")
        let report = try await combined(bot: .init(), billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, ids.count)
        XCTAssertTrue(report.sessions.allSatisfy { $0.client == "Cursor" && $0.usageKey == nil })
        XCTAssertEqual(Set(report.sessions.map(\.agentId)), ["cursor-model:grok-bot-default"])
    }

    func testAnExactNativeIDJoinsAnOrdinaryModelWithoutChangingItsIdentity() async throws {
        let billing = try CursorClient.parseEvents([row(conversation: "native-agent", model: "cursor-grok-4.6-medium")], account: "account-a")
        let report = try await combined(bot: metadata(agent: "native-agent"), billing: billing)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(report.sessions.count, 1)
        XCTAssertEqual(session.client, "Grok Bot")
        XCTAssertEqual(session.tokensIn, 12)
        XCTAssertEqual(session.agentId, "cursor-model:cursor-grok-4.6-medium")
        XCTAssertEqual(session.usageKey, billing.sessions.first?.id)
        XCTAssertEqual(report.sessionUsage?[session.id]?.models.map(\.agentId), ["cursor-model:cursor-grok-4.6-medium"])
    }

    func testTheNativeNavigationIDMustAgreeWithTheAccountScopedBotIdentity() async throws {
        var bot = metadata(agent: "native-agent")
        bot.sessions[0].navigationTarget = .grokBotAgent(id: "other-agent")
        let billing = try CursorClient.parseEvents([row(conversation: "other-agent")], account: "account-a")
        let report = try await combined(bot: bot, billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, 2)
        XCTAssertNil(report.sessions.first { $0.client == "Grok Bot" }?.usageKey)
    }

    func testAmbiguousBillingAccountsDoNotAttachUsageToOneNativeSession() async throws {
        let first = try CursorClient.parseEvents([row(conversation: "native-agent")], account: "account-a")
        let second = try CursorClient.parseEvents([row(conversation: "native-agent")], account: "account-b")
        let billing = ProviderSessions(sessions: first.sessions + second.sessions)
        let report = try await combined(bot: metadata(agent: "native-agent"), billing: billing)
            .fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, 3)
        XCTAssertEqual(report.sessions.filter { $0.client == "Cursor" }.count, 2)
        let native = try XCTUnwrap(report.sessions.first { $0.client == "Grok Bot" })
        XCTAssertEqual(native.tokensIn, 0)
        XCTAssertNil(native.usageKey)
    }

    func testAmbiguousNativeAccountPartitionsDoNotConsumeBillingUsage() async throws {
        let first = metadata(agent: "native-agent", account: "bot-account-a")
        let second = metadata(agent: "native-agent", account: "bot-account-b")
        let bot = ProviderSessions(sessions: first.sessions + second.sessions)
        let billing = try CursorClient.parseEvents([row(conversation: "native-agent")], account: "account-a")
        let report = try await combined(bot: bot, billing: billing).fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(report.sessions.count, 3)
        XCTAssertEqual(report.sessions.filter { $0.client == "Cursor" }.count, 1)
        XCTAssertTrue(report.sessions.filter { $0.client == "Grok Bot" }.allSatisfy { $0.usageKey == nil && $0.tokensIn == 0 })
    }

    func testSwitchingBotAccountsRemovesTheAttachedNativeSession() async throws {
        let fixture = try GrokBotCacheFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try fixture.writeRoster()
        let billing = try CursorClient.parseEvents([row(conversation: fixture.agent)], account: "account-a")
        let ledger = UsageLedger.inMemory()
        let cursor = provider(.cursor, sessions: billing, ledger: ledger)
        let grok = AdditionalUsageProvider(source: .grok, readQuota: { .init() }, readSessions: { _ in
            (try? GrokBotSessions.read(fixture.roster)) ?? .init()
        }, history: QuotaHistoryStore(), clock: { fixture.now }, ledger: ledger)
        let combined = CombinedUsageProvider([.init("Cursor", cursor), .init("Grok", grok)], ledger: ledger)
        let first = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.sessions.first?.client, "Grok Bot")
        try fixture.writeAccount("other-bot-account")
        let second = try await combined.fetchAccountAndLocalUsage(agents: [], historyHours: 168)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertEqual(second.sessions.first?.client, "Cursor")
        XCTAssertNil(second.sessions.first?.transcriptPath)
        XCTAssertNil(second.sessions.first?.usageKey)
    }

    private func metadata(agent: String, account: String = "bot-account") -> ProviderSessions {
        var session = ProviderSession(id: GrokBotCache.sessionID(account: account, agent: agent), title: "Native title", client: "Grok Bot")
        session.startedAt = now.addingTimeInterval(-60)
        session.lastActivity = now.addingTimeInterval(-10)
        session.navigationTarget = .grokBotAgent(id: agent)
        return ProviderSessions(sessions: [session])
    }

    private func row(conversation: String?, model: String = "grok-bot-default", at: TimeInterval = -5,
                     input: Int64 = 10, output: Int64 = 5, cache: Int64 = 20, write: Int64 = 2) -> ProviderJSON {
        var value: [String: ProviderJSON] = ["timestamp": .integer(Int64(now.addingTimeInterval(at).timeIntervalSince1970 * 1000)),
                 "model": .string(model),
                 "tokenUsage": .object(["inputTokens": .integer(input), "outputTokens": .integer(output),
                                        "cacheReadTokens": .integer(cache), "cacheWriteTokens": .integer(write)])]
        if let conversation { value["conversationId"] = .string(conversation) }
        return .object(value)
    }

    private func provider(_ source: AdditionalSource, sessions: ProviderSessions, ledger: UsageLedger) -> AdditionalUsageProvider {
        let now = now
        return AdditionalUsageProvider(source: source, readQuota: {
            source == .cursor ? .init(account: ProviderAccount(provider: "Cursor", user: "billing-owner", workspace: "", evidence: .account)) : .init()
        }, readSessions: { _ in sessions },
                                       history: QuotaHistoryStore(), clock: { now }, ledger: ledger)
    }

    private func combined(bot: ProviderSessions, billing: ProviderSessions, ledger: UsageLedger = .inMemory()) -> CombinedUsageProvider {
        CombinedUsageProvider([.init("Cursor", provider(.cursor, sessions: billing, ledger: ledger)),
                               .init("Grok", provider(.grok, sessions: bot, ledger: ledger))], ledger: ledger)
    }
}
