import Foundation
import XCTest
@testable import AgentHUDCore

final class KiroProviderTests: XCTestCase, @unchecked Sendable {
    private func json(_ text: String) throws -> ProviderJSON { try .read(Data(text.utf8)) }
    private let now = Date(timeIntervalSince1970: 1790553600)

    func testPrecisionAndSeparateCreditPools() throws {
        let response = try json("""
        {"subscriptionInfo":{"subscriptionTitle":"KIRO PRO+"},"nextDateReset":1790812800,
         "userInfo":{"userId":"user-a","email":"user@example.test"},"usageBreakdownList":[{
         "resourceType":"CREDIT","currentUsage":1618,"currentUsageWithPrecision":1618.1,"usageLimit":2000,
         "freeTrialInfo":{"freeTrialStatus":"ACTIVE","currentUsage":10,"usageLimit":50,"freeTrialExpiry":1790812800},
         "bonuses":[{"bonusId":"one","status":"ACTIVE","displayName":"Gift","currentUsage":5,"usageLimit":20,"expiresAt":1790812800},
                    {"status":"ACTIVE","currentUsage":2,"usageLimit":10,"expiresAt":1700000000}],
         "overageCredits":[{"currentUsage":12,"usageLimit":100,"expiresAt":1790812800}]}]}
        """)
        let quota = try KiroClient.parse(response, now: now)
        XCTAssertEqual(quota.plan, "KIRO PRO+")
        XCTAssertEqual(quota.windows.count, 4)
        XCTAssertEqual(quota.windows[0].remaining, 19.095, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(quota.windows[0].amounts).remaining, 381.9, accuracy: 0.00001)
        XCTAssertEqual(quota.windows[0].reset, Date(timeIntervalSince1970: 1790812800))
        XCTAssertNil(quota.windows[0].duration, "Do not invent a 30-day billing cycle")
        XCTAssertEqual(quota.account?.evidence, .account)
        XCTAssertNil(quota.notice)
        XCTAssertEqual(quota.scopedWindows(.kiro)[0].amounts, quota.windows[0].amounts)
    }

    func testMissingUsageIsNotZeroAndOverLimitIsClamped() throws {
        let missing = try KiroClient.parse(json("""
        {"usageBreakdownList":[{"resourceType":"CREDIT","usageLimit":2000}]}
        """))
        XCTAssertTrue(missing.windows.isEmpty)
        XCTAssertNotNil(missing.notice)
        let exceeded = try KiroClient.parse(json("""
        {"usageBreakdownList":[{"resourceType":"CREDIT","usageLimit":100,"currentUsage":120}]}
        """))
        XCTAssertEqual(exceeded.windows.first?.remaining, 0)
        XCTAssertEqual(exceeded.windows.first?.amounts?.used, 120)
        XCTAssertEqual(exceeded.windows.first?.amounts?.remaining, 0)
        XCTAssertThrowsError(try KiroClient.parse(json("{}")))
    }

    func testRequestRejectsExpiredOrUntrustedRegionAndEscapesProfile() throws {
        let auth = try json("""
        {"accessToken":"fixture-token","expiresAt":"2026-10-01T00:00:00Z","region":"us-east-1","authMethod":"IdC","profileArn":"arn:profile/a&x=1"}
        """)
        let request = try KiroClient.request(auth: auth, profile: nil, now: now)
        XCTAssertEqual(request.url.host, "management.us-east-1.kiro.dev")
        XCTAssertEqual(request.url.path, "/getUsageLimits")
        XCTAssertEqual(request.headers["Authorization"], "Bearer fixture-token")
        XCTAssertEqual(request.headers["TokenType"], "SSO_OIDC")
        XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "profileArn" })?.value, "arn:profile/a&x=1")
        XCTAssertThrowsError(try KiroClient.request(auth: auth, profile: nil, now: Date(timeIntervalSince1970: 1900000000)))
        XCTAssertThrowsError(try KiroClient.request(auth: json("""
        {"accessToken":"fixture-token","expiresAt":"2026-10-01T00:00:00Z","region":"evil.example/path"}
        """), profile: nil, now: now))
    }

    func testFetchAndProviderPublishAmountsWithoutFabricatedTokens() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent(".aws/sso/cache/kiro-auth-token.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {"accessToken":"fixture-token","expiresAt":"2026-10-01T00:00:00Z","region":"us-east-1"}
        """.utf8).write(to: path)
        let before = try Data(contentsOf: path)
        let client = KiroClient(home: home, http: ProviderHTTP(send: { request in
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.httpMethod, "GET")
            return Data("""
            {"subscriptionInfo":{"subscriptionTitle":"KIRO PRO+"},"userInfo":{"userId":"user-a"},
             "usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":0,"usageLimit":2000}]}
            """.utf8)
        }), clock: { self.now })
        let provider = AdditionalUsageProvider(source: .kiro, readQuota: { try await client.fetch() },
            readSessions: { _ in ProviderSessions(sessions: []) }, history: QuotaHistoryStore(), clock: { self.now })
        await provider.refreshAccountUsage(historyHours: 24)
        let report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.snapshots.first?.amounts?.limit, 2000)
        XCTAssertEqual(report.snapshots.first?.remainingPct, 100)
        XCTAssertTrue(report.consumers.isEmpty)
        XCTAssertTrue(report.sessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertFalse(provider.seesLocalWork)
    }

    func testLocalSignedInAccountProbe() async throws {
        guard ProcessInfo.processInfo.environment["AGENTHUD_KIRO_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only local Kiro account probe")
        }
        let quota = try await KiroClient().fetch()
        XCTAssertFalse(quota.windows.isEmpty)
        XCTAssertNotNil(quota.plan)
        XCTAssertNotNil(quota.account)
        XCTAssertNotNil(quota.windows.first?.amounts)
    }

    func testSnapshotDecodesBeforeAmountsWereAdded() throws {
        let snapshot = UsageSnapshot(agentId: "old", remainingPct: 50, updatedAt: now)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertNil(try JSONDecoder().decode(UsageSnapshot.self, from: data).amounts)
        let fresh = UsageSnapshot(agentId: "kiro", remainingPct: 50,
            amounts: QuotaAmounts(used: 10, limit: 20, unit: "credits"), updatedAt: now)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(fresh)), fresh)
    }
}
