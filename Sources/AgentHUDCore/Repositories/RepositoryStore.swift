import Foundation
import Observation

/// Separate from usage collection: a slow Git command never blocks quotas or panel presentation.
@MainActor @Observable
public final class RepositoryStore {
    public private(set) var archive = RepositoryArchive()
    public private(set) var loaded = false
    public private(set) var refreshing: Set<String> = []
    public private(set) var fetching: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    public private(set) var remoteErrors: [String: String] = [:]
    public private(set) var storageError: String?
    public var selectedBranch: String?
    public private(set) var integrations: [String: BranchIntegrationState] = [:]
    @ObservationIgnored private var integrationTask: Task<Void, Never>?
    @ObservationIgnored private let persistence: RepositoryPersistence
    @ObservationIgnored private var loading: Task<RepositoryArchive, Error>?
    @ObservationIgnored private var reads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetches: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var revision = 0

    public init(storageURL: URL? = AppSupport.directory.appendingPathComponent("repositories-v1.json")) {
        persistence = RepositoryPersistence(url: storageURL)
    }

    public var selected: TrackedRepository? { archive.repositories.first { $0.id == archive.selectedID } ?? archive.repositories.first }
    public var snapshot: RepositorySnapshot? { selected.flatMap { archive.snapshots[$0.id] } }

    public func load() async {
        guard !loaded else { return }
        if loading == nil {
            let persistence = persistence
            loading = Task { try await persistence.load() }
        }
        do {
            let value = try await loading!.value
            guard !loaded else { return }
            archive = value
        } catch {
            storageError = L10n.text("项目记录读取失败，原文件未覆盖。", "Could not read project records; original file was preserved.")
        }
        loaded = true
        loading = nil
    }

    public func select(_ id: String) {
        archive.selectedID = id
        selectedBranch = nil
        save()
        refresh()
    }

    public func add(_ repositories: [TrackedRepository]) {
        guard loaded, storageError == nil else { return }
        for repo in repositories where !archive.repositories.contains(where: { $0.id == repo.id }) { archive.repositories.append(repo) }
        if let first = repositories.first { archive.selectedID = first.id }
        save()
        refresh()
    }

    public func remove(_ id: String) {
        reads.removeValue(forKey: id)?.cancel()
        fetches.removeValue(forKey: id)?.cancel()
        archive.repositories.removeAll { $0.id == id }
        archive.snapshots[id] = nil
        archive.notes[id] = nil
        archive.fetchedAt[id] = nil
        errors[id] = nil
        remoteErrors[id] = nil
        if archive.selectedID == id { archive.selectedID = archive.repositories.first?.id }
        save()
    }

    public func note(for branch: String, repositoryID: String? = nil) -> BranchNote {
        archive.notes[repositoryID ?? selected?.id ?? ""]?[branch] ?? BranchNote()
    }

    public func updateNote(_ branch: String, repositoryID: String, _ change: (inout BranchNote) -> Void) {
        guard archive.repositories.contains(where: { $0.id == repositoryID }) else { return }
        var note = note(for: branch, repositoryID: repositoryID)
        change(&note)
        archive.notes[repositoryID, default: [:]][branch] = note
        save()
    }

    public func branches(includeRemote: Bool = false) -> [GitBranch] {
        guard let snapshot else { return [] }
        let checkedOut = Set(snapshot.worktrees.map(\.branch))
        return snapshot.branches.filter { includeRemote || !$0.remote }.sorted { a, b in
            let aRank = [note(for: a.name).pinned, a.current, checkedOut.contains(a.name)]
            let bRank = [note(for: b.name).pinned, b.current, checkedOut.contains(b.name)]
            for (left, right) in zip(aRank, bRank) where left != right { return left }
            return a.committedAt == b.committedAt ? a.name < b.name : a.committedAt > b.committedAt
        }
    }

    public func refresh() {
        guard loaded, let repo = selected, reads[repo.id] == nil else { return }
        refreshing.insert(repo.id)
        reads[repo.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.refreshing.remove(repo.id); self.reads[repo.id] = nil }
            do {
                var value = try await GitRepositoryReader.read(repo)
                try Task.checkCancellation()
                guard self.archive.repositories.contains(where: { $0.id == repo.id }) else { return }
                // Publish cheap refs first. Worktree scans arrive one by one and have individual deadlines.
                self.archive.snapshots[repo.id] = value
                self.errors[repo.id] = nil
                self.save()
                self.refreshIntegrations()
                for index in value.worktrees.indices {
                    try Task.checkCancellation()
                    value.worktrees[index] = await GitRepositoryReader.status(value.worktrees[index])
                    try Task.checkCancellation()
                    self.archive.snapshots[repo.id] = value
                }
                self.save()
            } catch is CancellationError { } catch {
                self.errors[repo.id] = (error as? GitRepositoryReader.Failure)?.errorDescription
                    ?? L10n.text("仓库读取失败，已保留旧数据。", "Repository read failed; previous data was retained.")
            }
        }
    }

    public func fetch(remote: String) {
        guard let repo = selected, fetches[repo.id] == nil else { return }
        fetching.insert(repo.id)
        fetches[repo.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.fetching.remove(repo.id); self.fetches[repo.id] = nil }
            do {
                try await GitRepositoryReader.fetch(repo, remote: remote)
                try Task.checkCancellation()
                guard self.archive.repositories.contains(where: { $0.id == repo.id }) else { return }
                self.archive.fetchedAt[repo.id, default: [:]][remote] = Date()
                self.remoteErrors[repo.id] = nil
                self.save()
                // Finish any earlier read, then refresh against the newly fetched refs.
                if let read = self.reads[repo.id] { await read.value }
                if self.selected?.id == repo.id { self.refresh() }
            } catch is CancellationError { } catch {
                self.remoteErrors[repo.id] = (error as? GitRepositoryReader.Failure)?.errorDescription
                    ?? L10n.text("远端刷新失败，已保留旧数据。", "Remote refresh failed; previous data was retained.")
            }
        }
    }

    public func integrationTarget(_ environment: String) -> String? {
        guard let repo = selected else { return nil }
        if let saved = archive.integrationTargets?[repo.id]?[environment] { return saved.isEmpty ? nil : saved }
        let refs = snapshot?.branches ?? []
        return ["refs/remotes/origin/" + environment, "refs/heads/" + environment]
            .first { candidate in refs.contains { $0.id.lowercased() == candidate } }
            .flatMap { candidate in refs.first { $0.id.lowercased() == candidate }?.id }
    }

    public func setIntegrationTarget(_ environment: String, ref: String) {
        guard let repo = selected else { return }
        var targets = archive.integrationTargets ?? [:]
        targets[repo.id, default: [:]][environment] = ref
        archive.integrationTargets = targets
        save()
        refreshIntegrations()
    }

    private func integrationKey(_ branch: GitBranch, environment: String) -> String? {
        guard let repo = selected, let source = branch.objectID, let targetRef = integrationTarget(environment),
              let target = snapshot?.branches.first(where: { $0.id == targetRef })?.objectID else { return nil }
        return [repo.id, source, target].joined(separator: "\0")
    }

    public func integration(_ branch: GitBranch, environment: String) -> BranchIntegrationState? {
        guard integrationTarget(environment) != nil else { return nil }
        guard let key = integrationKey(branch, environment: environment) else { return .unknown }
        return integrations[key] ?? .unknown
    }

    private func refreshIntegrations() {
        integrationTask?.cancel()
        guard let repo = selected, let snapshot else { return }
        let checks = snapshot.branches.filter { !$0.remote }.flatMap { branch in
            ["test", "uat"].compactMap { environment -> (String, String, String)? in
                guard let key = integrationKey(branch, environment: environment), (integrations[key] == nil || integrations[key] == .unknown),
                      let source = branch.objectID, let ref = integrationTarget(environment),
                      let target = snapshot.branches.first(where: { $0.id == ref })?.objectID else { return nil }
                return (key, source, target)
            }
        }
        // Bound the memory cache across long sessions and rebases.
        if integrations.count > 2000 { integrations = [:] }
        integrationTask = Task {
            for (key, source, target) in checks {
                guard !Task.isCancelled else { return }
                let value = await GitRepositoryReader.integrationState(repo, sourceID: source, targetID: target)
                guard !Task.isCancelled else { return }
                integrations[key] = value
            }
        }
    }

    public func refreshAfterOperation() {
        guard let repo = selected else { return }
        Task {
            if let read = reads[repo.id] { await read.value }
            if selected?.id == repo.id { refresh() }
        }
    }

    public func stop() {
        integrationTask?.cancel()
        reads.values.forEach { $0.cancel() }
        fetches.values.forEach { $0.cancel() }
    }

    /// Only visible branch surfaces subscribe. Git metadata events are debounced; working-tree
    /// contents are checked at most every 30 seconds while visible, never continuously crawled.
    public func observeSelected() async {
        await load()
        guard let repo = selected else { return }
        let monitor = FileChangeMonitor(directories: [URL(fileURLWithPath: repo.id)])
        var lastCheck = Date.distantPast
        while !Task.isCancelled, selected?.id == repo.id {
            if monitor.consumeChanges() || Date().timeIntervalSince(lastCheck) >= 30 {
                refresh()
                lastCheck = Date()
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { break }
        }
    }

    private func save() {
        guard loaded, storageError == nil else { return }
        revision += 1
        let revision = revision, value = archive, persistence = persistence
        Task { [weak self] in
            do { try await persistence.save(value, revision: revision) }
            catch { self?.storageError = L10n.text("项目记录保存失败。", "Could not save project records.") }
        }
    }
}

/// Serialized disk IO off the main actor. Explicit permissions also protect paths, subjects and notes.
private actor RepositoryPersistence {
    let url: URL?
    var revision = 0
    init(url: URL?) { self.url = url }
    func load() throws -> RepositoryArchive {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return RepositoryArchive() }
        return try JSONDecoder().decode(RepositoryArchive.self, from: Data(contentsOf: url))
    }
    func save(_ value: RepositoryArchive, revision: Int) throws {
        guard let url, revision > self.revision else { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        self.revision = revision
    }
}
