import XCTest
@testable import AgentHUDCore

final class AntigravityServiceTests: XCTestCase, @unchecked Sendable {
    private func processes(_ count: Int) -> String {
        (1...count).map { "\($0) /Applications/Antigravity.app/Contents/Resources/language_server --csrf_token fixture-\($0)" }.joined(separator: "\n")
    }

    func testNativeDiscoveryIncludesEveryCredentialBearingService() async throws {
        let processes = processes(7)
        let endpoints = try await AntigravityService.permissionEndpoints { executable, arguments in
            if executable == "/bin/ps" { return processes }
            let index = try XCTUnwrap(arguments.firstIndex(of: "-p"))
            let pid = try XCTUnwrap(Int(arguments[index + 1]))
            return "n127.0.0.1:\(50000 + pid)"
        }
        XCTAssertEqual(Set(endpoints.map(\.pid)), Set(1...7), "a later service must not silently disappear from the snapshot")
    }

    func testLaterInspectionFailureDoesNotReturnAnEarlierPartialDiscovery() async {
        enum Failure: Error { case inspection }
        let processes = processes(7)
        do {
            _ = try await AntigravityService.permissionEndpoints { executable, arguments in
                if executable == "/bin/ps" { return processes }
                if arguments.contains("7") { throw Failure.inspection }
                return "n127.0.0.1:50001"
            }
            XCTFail("an unread service is not an empty service")
        } catch { XCTAssertTrue(error is Failure) }
    }

    func testUnauthenticatedCLIListenersDoNotBlockSupportedNativeServices() async throws {
        let processes = processes(1) + "\n2 /usr/local/bin/agy --prompt-interactive fixture"
        let endpoints = try await AntigravityService.permissionEndpoints { executable, arguments in
            if executable == "/bin/ps" { return processes }
            XCTAssertFalse(arguments.contains("2"), "a CLI without discoverable credentials cannot authenticate this native API")
            return "n127.0.0.1:50001"
        }
        XCTAssertEqual(endpoints.map(\.pid), [1])
    }

    func testAnAuthenticatedServiceWithoutDiscoverableListenersIsUnknown() async {
        let processes = processes(1)
        do {
            _ = try await AntigravityService.permissionEndpoints { executable, _ in
                executable == "/bin/ps" ? processes : ""
            }
            XCTFail("a failed listener discovery must not settle an existing prompt")
        } catch { XCTAssertEqual(error.localizedDescription, ProviderFailure.format.localizedDescription) }
    }
}
