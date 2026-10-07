import XCTest
@testable import AgentHUDCore

final class SessionNavigationTests: XCTestCase {
    func testLocalObserverTargetUsesAnExplicitKindAndIdentity() throws {
        for target in [SessionNavigationTarget.codexThread(id: "thread"), .iTermSession(id: "w0t0p0:session"),
                       .antigravityConversation(id: "conversation"), .claudeDesktopSession(id: "local_desktop"),
                       .claudeCoworkSession(id: "local_cowork")] {
            let data = try JSONEncoder().encode(target)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(Set(fields.keys), ["kind", "id"])
            XCTAssertEqual(try JSONDecoder().decode(SessionNavigationTarget.self, from: data), target)
        }
    }

    func testUsageReportNeverEncodesLocalNavigationDestinations() throws {
        let now = Date(), target = SessionNavigationTarget.iTermSession(id: "w0t0p0:private-terminal")
        let session = LiveSession(id: "session", agentId: "pi-model:model", task: "Task", terminal: "project",
            startedAt: now, pctOfWindow: nil, tokensIn: 1, tokensOut: 2, navigationTarget: target)
        let completion = SessionCompletion(sessionID: session.id, vendor: "Pi", turnID: "turn", task: session.task,
            model: "model", startedAt: now, completedAt: now, navigationTarget: target)
        let report = UsageReport(generatedAt: now, snapshots: [], sessions: [session], completions: [completion])
        let data = try JSONEncoder().encode(report)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("navigationTarget"))
        XCTAssertFalse(encoded.contains("private-terminal"))
        let restored = try JSONDecoder().decode(UsageReport.self, from: data)
        XCTAssertNil(restored.sessions.first?.navigationTarget)
        XCTAssertNil(restored.completions.first?.navigationTarget)
        XCTAssertEqual(restored.sessions.first?.id, session.id)
        XCTAssertEqual(restored.completions.first?.id, completion.id)
    }
}
