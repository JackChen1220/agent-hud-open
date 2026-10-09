import XCTest
@testable import AgentHUDCore

final class ClientHomeTests: XCTestCase {
    /// A variable that moves a client's directory counts as unset when it is empty or only whitespace, for every client.
    func testABlankDirectoryVariableIsUnset() {
        XCTAssertNil(ClientHome.variable("GROK_HOME", in: [:]))
        XCTAssertNil(ClientHome.variable("GROK_HOME", in: ["GROK_HOME": ""]))
        XCTAssertNil(ClientHome.variable("GROK_HOME", in: ["GROK_HOME": " \n"]))
        XCTAssertEqual(ClientHome.variable("GROK_HOME", in: ["GROK_HOME": " /tmp/grok "]), "/tmp/grok")
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(GrokSessions.directory(home: home, environment: ["GROK_HOME": ""]), home.appendingPathComponent(".grok"))
        XCTAssertEqual(OpenAgentPaths(home: home, environment: ["XDG_DATA_HOME": "", "KIMI_CODE_HOME": " "]).openCode,
                       home.appendingPathComponent(".local/share/opencode"))
        XCTAssertEqual(OpenAgentPaths(home: home, environment: ["KIMI_CODE_HOME": " "]).kimi, home.appendingPathComponent(".kimi-code"))
    }
}
