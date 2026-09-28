import XCTest
@testable import AgentHUDCore

final class RepositoryActionTests: XCTestCase {
    func testStagedRenameAndDeletionCommitOnlySelectedPaths() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "rename".write(to: root.appendingPathComponent("before"), atomically: true, encoding: .utf8)
        try "delete".write(to: root.appendingPathComponent("deleted"), atomically: true, encoding: .utf8)
        _ = try await git(root, ["add", "."])
        _ = try await git(root, ["commit", "-m", "Files"])
        _ = try await git(root, ["mv", "before", "after"])
        _ = try await git(root, ["rm", "deleted"])
        let preview = try await GitRepositoryActions.commitPreview(path: root.path)
        let service = GitRepositoryActions()
        try await service.commit(preview, selectedPaths: ["after", "deleted"], message: "Rename and delete")
        let files = try await git(root, ["ls-tree", "--name-only", "HEAD"])
        XCTAssertEqual(files.trimmingCharacters(in: .newlines), "after")
    }

    func testIntegrationUsesCommitAncestryAndDoesNotInventCompletion() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepositoryReader.identify(path: root.path)
        let base = try await GitRepositoryActions.branchHead(repo, branch: "main")
        _ = try await git(root, ["commit", "--allow-empty", "-m", "New work"])
        let newer = try await GitRepositoryActions.branchHead(repo, branch: "main")
        let included = await GitRepositoryReader.integrationState(repo, sourceID: base, targetID: newer)
        let incomplete = await GitRepositoryReader.integrationState(repo, sourceID: newer, targetID: base)
        let unknown = await GitRepositoryReader.integrationState(repo, sourceID: "missing", targetID: base)
        XCTAssertEqual(included, .included)
        XCTAssertEqual(incomplete, .notIncluded)
        XCTAssertEqual(unknown, .unknown)
    }

    func testSelectedCommitPreservesUnrelatedStagingAndHonorsHookFailure() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected file.txt")
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try "selected".write(to: selected, atomically: true, encoding: .utf8)
        try "other".write(to: unrelated, atomically: true, encoding: .utf8)
        _ = try await git(root, ["add", "--", "unrelated.txt"])
        let preview = try await GitRepositoryActions.commitPreview(path: root.path)
        let service = GitRepositoryActions()
        try await service.commit(preview, selectedPaths: ["selected file.txt"], message: "Commit only selected")
        let files = try await git(root, ["show", "--format=", "--name-only", "HEAD"])
        XCTAssertEqual(files.trimmingCharacters(in: .newlines), "selected file.txt")
        let staged = try await git(root, ["diff", "--cached", "--name-only"])
        XCTAssertEqual(staged.trimmingCharacters(in: .newlines), "unrelated.txt")

        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "updated".write(to: selected, atomically: true, encoding: .utf8)
        let blocked = try await GitRepositoryActions.commitPreview(path: root.path)
        do {
            try await service.commit(blocked, selectedPaths: ["selected file.txt"], message: "Must not bypass hook")
            XCTFail("Pre-commit hook must be respected")
        } catch GitRepositoryActions.Failure.stagedButNotCommitted { }
        let head = try await git(root, ["log", "-1", "--format=%s"])
        XCTAssertEqual(head.trimmingCharacters(in: .newlines), "Commit only selected")
    }

    func testSwitchAndDeleteRefuseDirtyOccupiedAndUnmergedBranches() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepositoryReader.identify(path: root.path)
        let service = GitRepositoryActions()
        _ = try await git(root, ["branch", "topic"])
        let head = try await GitRepositoryActions.branchHead(repo, branch: "topic")
        let context = try await GitRepositoryActions.context(path: root.path)
        try "pending".write(to: root.appendingPathComponent("pending"), atomically: true, encoding: .utf8)
        do {
            try await service.switchBranch(repo, expected: context, branch: "topic", expectedTarget: head)
            XCTFail("Dirty worktree must not switch")
        } catch GitRepositoryActions.Failure.dirty { }
        try FileManager.default.removeItem(at: root.appendingPathComponent("pending"))
        try await service.switchBranch(repo, expected: context, branch: "topic", expectedTarget: head)
        do {
            try await service.deleteLocal(repo, branch: "topic", expectedHead: head)
            XCTFail("Checked-out branch must not be deleted")
        } catch GitRepositoryActions.Failure.occupied { }
        _ = try await git(root, ["commit", "--allow-empty", "-m", "Unmerged work"])
        let newHead = try await GitRepositoryActions.branchHead(repo, branch: "topic")
        _ = try await git(root, ["switch", "main"])
        do {
            try await service.deleteLocal(repo, branch: "topic", expectedHead: newHead)
            XCTFail("Unmerged branch must not be force-deleted")
        } catch GitRepositoryReader.Failure.unmerged { }
        _ = try await git(root, ["branch", "merged"])
        let mergedHead = try await GitRepositoryActions.branchHead(repo, branch: "merged")
        try await service.deleteLocal(repo, branch: "merged", expectedHead: mergedHead)
        let remaining = try await git(root, ["branch", "--list", "merged"])
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPushUsesReviewedBranchAndDestinationAndRejectsChangedRemote() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await git(remote, ["init", "--bare"])
        _ = try await git(root, ["remote", "add", "origin", remote.path])
        let repo = try await GitRepositoryReader.identify(path: root.path)
        let preview = try await GitRepositoryActions.pushPreview(repo, branch: "main", remote: "origin", destination: "published")
        let service = GitRepositoryActions()
        try await service.push(repo, preview: preview, setUpstream: true)
        let remoteHead = try await git(remote, ["rev-parse", "refs/heads/published"])
        XCTAssertEqual(remoteHead.trimmingCharacters(in: .newlines), preview.head)
        let upstream = try await git(root, ["rev-parse", "--abbrev-ref", "@{upstream}"])
        XCTAssertEqual(upstream.trimmingCharacters(in: .newlines), "origin/published")
        _ = try await git(root, ["remote", "set-url", "--push", "origin", root.appendingPathComponent("other.git").path])
        do {
            try await service.push(repo, preview: preview, setUpstream: false)
            XCTFail("A changed destination must require another review")
        } catch GitRepositoryActions.Failure.changed { }
    }

    func testErrorsDoNotExposeCredentialsAndStatusKeepsRenamePaths() {
        XCTAssertEqual(GitRepositoryActions.sanitizedRemote("https://user:secret@git.example.com/team/repo.git?token=secret"), "https://git.example.com/team/repo.git")
        XCTAssertEqual(GitRepositoryActions.sanitizedRemote("git@git.example.com:team/repo.git"), "git.example.com:team/repo.git")
        let error = GitRepositoryReader.failure(stderr: "Connection closed by 127.0.0.1 port 5153", status: 128)
        if case .network = error { } else { XCTFail("Closed SSH connections need a network diagnosis") }
        let files = GitRepositoryActions.parseFiles("R  new\nname\0old name\0?? :(glob)*\0")
        XCTAssertEqual(files[0].paths, ["new\nname", "old name"])
        XCTAssertEqual(files[1].path, ":(glob)*")
    }

    private func fixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hud-action-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await git(root, ["init", "-b", "main"])
        _ = try await git(root, ["config", "user.name", "Test"])
        _ = try await git(root, ["config", "user.email", "test@example.invalid"])
        _ = try await git(root, ["config", "commit.gpgsign", "false"])
        _ = try await git(root, ["commit", "--allow-empty", "-m", "Initial"])
        return root
    }
    private func git(_ root: URL, _ arguments: [String]) async throws -> String {
        try await GitRepositoryReader.git(root.path, arguments)
    }
}
