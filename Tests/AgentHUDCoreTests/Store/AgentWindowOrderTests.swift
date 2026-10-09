import XCTest
@testable import AgentHUDCore

final class AgentWindowOrderTests: XCTestCase {
    func testAccountReorderKeepsOtherAccountsInTheirExistingHUDSlots() {
        let work = account("work"), personal = account("personal")
        let rows = [window("a", account: work), window("b", account: personal, enabled: false),
                    window("c", account: work), window("d", account: personal), window("e", account: work)]
        let reordered = rows.movingAccountWindow(id: "e", to: "a")
        XCTAssertEqual(reordered.map(\.id), ["e", "b", "a", "d", "c"])
        XCTAssertEqual(reordered[1], rows[1])
        XCTAssertEqual(reordered[3], rows[3])
        XCTAssertEqual(reordered.movingAccountWindow(id: "e", to: "c"), rows)
        XCTAssertEqual(rows.movingAccountWindow(id: "a", to: "d"), rows)
        XCTAssertEqual(rows.movingAccountWindow(id: "missing", to: "a"), rows)
    }

    func testSharedAPIPoolCanReorderAcrossItsClientsWithoutMovingAnotherPool() {
        let shared = pool("shared"), other = pool("other")
        let rows = [window("open", vendor: "OpenCode", pool: shared),
                    window("other", vendor: "Pi", pool: other), window("pi", vendor: "Pi", pool: shared)]
        XCTAssertEqual(rows.movingAccountWindow(id: "pi", to: "open").map(\.id), ["pi", "other", "open"])
        XCTAssertEqual(rows.movingAccountWindow(id: "pi", to: "other"), rows)
    }

    func testUnscopedRowsStayWithinTheirProvider() {
        let rows = [window("a"), window("other", vendor: "Claude"), window("c")]
        XCTAssertEqual(rows.movingAccountWindow(id: "c", to: "a").map(\.id), ["c", "other", "a"])
        XCTAssertEqual(rows.movingAccountWindow(id: "c", to: "other"), rows)
    }

    func testSectionsGroupInterleavedAccountsWithoutChangingStoredOrderOrVisibility() throws {
        let work = account("work"), personal = account("personal")
        let rows = [window("a", account: work), window("b", account: personal, enabled: false),
                    window("c", account: work)]
        let report = UsageReport(generatedAt: Date(), snapshots: [], sessions: [], accounts: ["Antigravity": [
            .init(account: work, label: "work@example.com", observedAt: Date()),
            .init(account: personal, label: "personal@example.com", observedAt: Date(), isCurrent: false),
        ]])
        let group = try XCTUnwrap(AgentSettingsGroup.make(sources: [], agents: rows, report: report).first)
        XCTAssertEqual(group.windowSections.map(\.id), [work.id, personal.id])
        XCTAssertEqual(group.windowSections.map(\.title), ["work@example.com", "personal@example.com"])
        XCTAssertEqual(group.windowSections.map { $0.agents.map(\.id) }, [["a", "c"], ["b"]])
        XCTAssertEqual(group.agents, rows)
        XCTAssertFalse(group.windowSections[1].agents[0].enabled)
    }

    func testUnscopedWindowsHaveOneSectionWithoutAnInventedAccount() throws {
        let work = account("work")
        let rows = [window("unscoped-a"), window("account", account: work), window("unscoped-b")]
        let group = try XCTUnwrap(AgentSettingsGroup.make(sources: [], agents: rows).first)
        XCTAssertEqual(group.windowSections.map(\.id), [nil, work.id])
        XCTAssertNil(group.windowSections[0].title)
        XCTAssertEqual(group.windowSections[0].agents.map(\.id), ["unscoped-a", "unscoped-b"])
        XCTAssertEqual(group.agents, rows)
    }

    func testSectionHeaderUsesAPIBalanceNameOrExistingFallbackIdentity() throws {
        let shared = pool("shared"), missing = pool("missing")
        let rows = [window("open", vendor: "OpenCode", pool: shared),
                    window("pi", vendor: "Pi", pool: missing)]
        let billing = APIBilling(vendor: "Anthropic", balances: [], isAvailable: true, updatedAt: Date(),
                                 notice: nil, billingPool: shared)
        let report = UsageReport(generatedAt: Date(), snapshots: [], sessions: [], billing: [billing])
        let group = try XCTUnwrap(AgentSettingsGroup.make(sources: [], agents: rows, report: report).first)
        XCTAssertEqual(group.windowSections.map(\.id), [shared.id, missing.id])
        XCTAssertEqual(group.windowSections.map(\.title), [billing.displayName, group.unobservedAccounts.first?.displayName])
        XCTAssertEqual(group.agents, rows)
    }

    private func account(_ user: String) -> ProviderAccount {
        .identified(provider: "Antigravity", user: user, workspace: nil)!
    }

    private func pool(_ scope: String) -> BillingPool {
        .init(provider: "Anthropic", realm: "Global", product: .api, scope: scope, evidence: .account, entitlement: "api")
    }

    private func window(_ id: String, vendor: String = "Antigravity", account: ProviderAccount? = nil,
                        enabled: Bool = true, pool: BillingPool? = nil) -> AgentDescriptor {
        .init(id: id, vendor: vendor, model: "Quota", source: "", enabled: enabled, billingPool: pool, account: account)
    }
}
