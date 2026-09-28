import XCTest
@testable import AgentHUDCore

final class RepositoryTests: XCTestCase {
    /// Opt-in local probe. Never fetches, modifies a checkout, or emits paths/subjects.
    func testInstalledRepositoryReadPerformance() async throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTHUD_TEST_REPOSITORY"] else {
            throw XCTSkip("Set AGENTHUD_TEST_REPOSITORY for the local read-only performance probe")
        }
        let start = ContinuousClock.now
        let repo = try await GitRepositoryReader.identify(path: path)
        let snapshot = try await GitRepositoryReader.read(repo)
        let refsTime = start.duration(to: .now)
        var checked = 0
        for worktree in snapshot.worktrees {
            let result = await GitRepositoryReader.status(worktree)
            if result.checkedAt != nil { checked += 1 }
        }
        print("Repository probe: refs=\(snapshot.branches.count), worktrees=\(snapshot.worktrees.count), checked=\(checked), metadata=\(refsTime), total=\(start.duration(to: .now))")
        XCTAssertFalse(snapshot.branches.isEmpty)
    }

    func testNoUpstreamIsNotUnpushedAndDifferentNameUpstreamIsRespected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repoPath = root.appendingPathComponent("repo with spaces")
        let remotePath = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remotePath, withIntermediateDirectories: true)
        _ = try await GitRepositoryReader.git(remotePath.path, ["init", "--bare"])
        _ = try await GitRepositoryReader.git(repoPath.path, ["init", "-b", "feature"])
        _ = try await GitRepositoryReader.git(repoPath.path, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
        _ = try await GitRepositoryReader.git(repoPath.path, ["remote", "add", "origin", remotePath.path])
        _ = try await GitRepositoryReader.git(repoPath.path, ["push", "-u", "origin", "HEAD:refs/heads/published-name"])
        _ = try await GitRepositoryReader.git(repoPath.path, ["branch", "untracked"])
        let repo = try await GitRepositoryReader.identify(path: repoPath.path)
        let snapshot = try await GitRepositoryReader.read(repo)
        let feature = try XCTUnwrap(snapshot.branches.first { $0.name == "feature" })
        XCTAssertEqual(feature.upstream, "origin/published-name")
        XCTAssertEqual(feature.upstreamRemote, "origin")
        XCTAssertEqual(feature.sync, .synced)
        XCTAssertEqual(snapshot.branches.first { $0.name == "untracked" }?.sync, .noUpstream)

        _ = try await GitRepositoryReader.git(repoPath.path, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Local work"])
        let changed = try await GitRepositoryReader.read(repo)
        XCTAssertEqual(changed.branches.first { $0.name == "feature" }?.ahead, 1)
        XCTAssertEqual(changed.branches.first { $0.name == "feature" }?.sync, .ahead)

        let treePath = root.appendingPathComponent("linked tree")
        _ = try await GitRepositoryReader.git(repoPath.path, ["worktree", "add", treePath.path, "untracked"])
        let linked = try await GitRepositoryReader.identify(path: treePath.path)
        XCTAssertEqual(repo.id, linked.id)
        let withTree = try await GitRepositoryReader.read(repo)
        XCTAssertEqual(withTree.worktrees.count, 2)
        try "private source".write(to: treePath.appendingPathComponent("untracked\nfile.txt"), atomically: true, encoding: .utf8)
        let tree = try XCTUnwrap(withTree.worktrees.first { $0.branch == "untracked" })
        let status = await GitRepositoryReader.status(tree)
        XCTAssertEqual(status.changedEntries, 1)
        XCTAssertEqual(status.conflicts, 0)

        // A repository's custom refspec must not let an explicit refresh overwrite local branches.
        _ = try await GitRepositoryReader.git(repoPath.path, ["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])
        try await GitRepositoryReader.fetch(repo, remote: "origin")
        let afterFetch = try await GitRepositoryReader.read(repo)
        XCTAssertFalse(afterFetch.branches.contains { !$0.remote && $0.name == "published-name" })
    }

    func testParseDivergedMissingAndRemoteHead() {
        let input = "refs/heads/topic\0*\0origin/elsewhere\0[ahead 2, behind 3]\01700000000\0Work\0\0origin\n"
            + "refs/heads/gone\0 \0origin/gone\0[gone]\01700000000\0Old\0\0origin\n"
            + "refs/remotes/origin/HEAD\0 \0\0\01700000000\0Base\0refs/remotes/origin/main\0\n"
        let rows = GitRepositoryReader.parseBranches(input)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].sync, .diverged)
        XCTAssertEqual(rows[0].ahead, 2)
        XCTAssertEqual(rows[0].behind, 3)
        XCTAssertEqual(rows[1].sync, .missingUpstream)
    }

    func testNulStatusCountsRenamesAndConflictsWithoutReadingNames() {
        let result = GitRepositoryReader.parseStatus("R  new name\0old\nname\0?? other\0UU conflicted\0 M source\0")
        XCTAssertEqual(result.changed, 4)
        XCTAssertEqual(result.conflicts, 1)
    }

    @MainActor
    func testCachedStateLoadsOfflineAndPreservesNotes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("repositories.json")
        var archive = RepositoryArchive()
        let repo = TrackedRepository(id: "/missing/.git", path: "/missing")
        archive.repositories = [repo]; archive.selectedID = repo.id
        var note = BranchNote(); note.title = "A task"; note.progress = .testing
        archive.notes[repo.id] = ["topic": note]
        try JSONEncoder().encode(archive).write(to: file)
        let store = RepositoryStore(storageURL: file)
        await store.load()
        XCTAssertEqual(store.selected?.id, repo.id)
        XCTAssertEqual(store.note(for: "topic").progress, .testing)
        XCTAssertTrue(store.refreshing.isEmpty, "Loading the cache must not invoke Git")
        store.updateNote("topic", repositoryID: repo.id) { $0.text = "Next step" }
        for _ in 0..<100 {
            let saved = try JSONDecoder().decode(RepositoryArchive.self, from: Data(contentsOf: file))
            if saved.notes[repo.id]?["topic"]?.text == "Next step" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try JSONDecoder().decode(RepositoryArchive.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.notes[repo.id]?["topic"]?.text, "Next step")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testOldSettingsGainDefaultPanelShortcut() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.panelShortcut, PanelShortcut())
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).panelShortcut.label, "⇧⌘H")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-hud-repository-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
