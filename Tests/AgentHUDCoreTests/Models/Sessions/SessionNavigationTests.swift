import XCTest
@testable import AgentHUDCore

final class SessionNavigationTests: XCTestCase {
    func testSessionTreesRoundTripAndEarlierReportsWithoutChildrenStillDecode() throws {
        let now = Date()
        let child = LiveSession(id: "child", agentId: "codex-model:gpt-6-astra", task: "Review", terminal: nil,
            startedAt: now, pctOfWindow: nil, tokensIn: 20, tokensOut: 2, agentName: "/root/review",
            navigationTarget: .codexThread(id: "child"))
        let root = LiveSession(id: "root", agentId: child.agentId, task: "Implement", terminal: nil,
            startedAt: now, pctOfWindow: nil, tokensIn: 30, tokensOut: 3, subagentSessions: [child])
        let data = try JSONEncoder().encode(root)
        let restored = try JSONDecoder().decode(LiveSession.self, from: data)
        XCTAssertEqual(restored.descendantSessions.map(\.id), ["child"])
        XCTAssertEqual(restored.subagentSessions?.first?.agentName, "/root/review")
        XCTAssertEqual(restored.subagentSessions?.first?.tokensIn, 20)
        XCTAssertNil(restored.subagentSessions?.first?.navigationTarget)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "subagentSessions")
        old.removeValue(forKey: "agentName")
        let earlier = try JSONDecoder().decode(LiveSession.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(earlier.subagentSessions)
        XCTAssertNil(earlier.agentName)
        XCTAssertEqual(earlier.id, "root")
    }

    func testLocalObserverTargetUsesAnExplicitKindAndIdentity() throws {
        for target in [SessionNavigationTarget.codexThread(id: "thread"), .iTermSession(id: "w0t0p0:session"),
                       .antigravityConversation(id: "conversation"), .grokBotAgent(id: "agent_ID-1"), .claudeDesktopSession(id: "local_desktop"),
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
