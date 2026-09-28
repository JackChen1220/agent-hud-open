import Foundation

public struct GitActionContext: Equatable, Sendable {
    public let repositoryID: String
    public let path: String
    public let branch: String
    public let head: String
}

public struct GitChangedFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let status: String
    public var paths: [String] { [path] + (originalPath.map { [$0] } ?? []) }
}

public struct GitCommitPreview: Sendable {
    public let context: GitActionContext
    public let files: [GitChangedFile]
    public let status: String
}

public struct GitPushPreview: Sendable {
    public let branch: String
    public let head: String
    public let remote: String
    public let destination: String
    public let displayURL: String
    /// Never displayed or persisted; detects a destination change between review and execution.
    let actualURL: String
}

/// Mutations are explicit, serialized per common Git directory, and revalidated after the user reviews them.
/// Git hooks/signing remain enabled; there is no force, reset, stash, merge or remote deletion API.
public actor GitRepositoryActions {
    public static let shared = GitRepositoryActions()
    private var busy: Set<String> = []

    public enum Failure: Error, LocalizedError {
        case busy, changed, dirty, occupied, inProgress, conflict, emptySelection, multipleDestinations, invalidName
        case stagedButNotCommitted(String)
        public var errorDescription: String? {
            switch self {
            case .busy: L10n.text("这个项目已有操作在执行，请稍后重试。", "An operation is already running for this project.")
            case .changed: L10n.text("分支、提交或目录状态已变化，请重新打开操作并检查。", "The branch, commit or directory changed. Reopen the operation and review again.")
            case .dirty: L10n.text("工作目录有未提交改动，请先提交或在终端处理后再切分支。", "The worktree has uncommitted changes. Commit or handle them in Terminal before switching.")
            case .occupied: L10n.text("该分支正在某个工作目录中使用，请打开该目录；不能在这里切换或删除。", "This branch is checked out in a worktree. Open that directory instead of switching or deleting it here.")
            case .inProgress: L10n.text("目录中有未结束的合并、变基或拣选操作，请先在终端处理。", "A merge, rebase or cherry-pick is in progress. Finish it in Terminal first.")
            case .conflict: L10n.text("目录中仍有冲突，请解决后再提交。", "Resolve worktree conflicts before committing.")
            case .emptySelection: L10n.text("请选择文件并填写提交说明。", "Select files and enter a commit message.")
            case .multipleDestinations: L10n.text("该远端配置了多个推送地址，请在终端确认目标后推送。", "This remote has multiple push URLs. Verify the destinations and push in Terminal.")
            case .invalidName: L10n.text("分支名无效，或所选远端已不存在。", "Invalid branch name or the selected remote no longer exists.")
            case .stagedButNotCommitted(let reason): L10n.text("所选文件已暂存，但提交未完成：", "Selected files were staged, but commit did not complete: ") + reason
            }
        }
    }

    public static func context(path: String) async throws -> GitActionContext {
        let repo = try await GitRepositoryReader.identify(path: path)
        let branch = try await GitRepositoryReader.git(path, ["symbolic-ref", "--quiet", "--short", "HEAD"]).trimmingCharacters(in: .newlines)
        let head = try await GitRepositoryReader.git(path, ["rev-parse", "--verify", "HEAD"]).trimmingCharacters(in: .newlines)
        return GitActionContext(repositoryID: repo.id, path: repo.path, branch: branch, head: head)
    }

    public static func branchHead(_ repository: TrackedRepository, branch: String, remote: Bool = false) async throws -> String {
        try await GitRepositoryReader.git(repository.path, ["rev-parse", "--verify", (remote ? "refs/remotes/" : "refs/heads/") + branch])
            .trimmingCharacters(in: .newlines)
    }

    public static func commitPreview(path: String) async throws -> GitCommitPreview {
        let context = try await context(path: path)
        try await checkInProgress(path)
        let status = try await status(path)
        let files = parseFiles(status)
        guard !files.contains(where: { ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains($0.status) }) else { throw Failure.conflict }
        return GitCommitPreview(context: context, files: files, status: status)
    }

    static func parseFiles(_ text: String) -> [GitChangedFile] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var result: [GitChangedFile] = [], index = 0
        while index < fields.count {
            let field = fields[index]
            guard field.count >= 4 else { index += 1; continue }
            let code = String(field.prefix(2))
            let paired = code.contains("R") || code.contains("C")
            let original = paired && index + 1 < fields.count ? fields[index + 1] : nil
            result.append(GitChangedFile(path: String(field.dropFirst(3)), originalPath: original, status: code))
            index += paired ? 2 : 1
        }
        return result
    }

    public func switchBranch(_ repository: TrackedRepository, expected: GitActionContext, branch: String,
                             expectedTarget: String, remote: Bool = false, localName: String = "") async throws {
        try acquire(repository.id); defer { busy.remove(repository.id) }
        try await verify(expected)
        try await Self.checkInProgress(expected.path)
        guard try await Self.status(expected.path).isEmpty else { throw Failure.dirty }
        guard try await Self.branchHead(repository, branch: branch, remote: remote) == expectedTarget else { throw Failure.changed }
        if remote {
            try await Self.validateBranch(localName, path: repository.path)
            _ = try await GitRepositoryReader.git(expected.path, ["switch", "--create", localName, "--track", "refs/remotes/" + branch], timeout: 120, writesRepository: true)
        } else {
            try await ensureUnoccupied(repository, branch: branch)
            _ = try await GitRepositoryReader.git(expected.path, ["switch", "--no-guess", "--", branch], timeout: 120, writesRepository: true)
        }
    }

    public func commit(_ preview: GitCommitPreview, selectedPaths: Set<String>, message: String) async throws {
        let context = preview.context
        try acquire(context.repositoryID); defer { busy.remove(context.repositoryID) }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !selectedPaths.isEmpty else { throw Failure.emptySelection }
        try await verify(context)
        let fresh = try await Self.commitPreview(path: context.path)
        guard fresh.status == preview.status, selectedPaths.isSubset(of: Set(fresh.files.map(\.path))) else { throw Failure.changed }
        let paths = Array(Set(fresh.files.filter { selectedPaths.contains($0.path) }.flatMap(\.paths))).sorted()
        // --only commits each selected file's complete current state, preserving unrelated staged changes.
        // A staged rename/deletion may already have removed its old path from the index. Do not
        // feed that vanished path to `add`; it still belongs in commit's explicit path selection.
        let indexed = Set(try await GitRepositoryReader.git(context.path, ["ls-files", "-z", "--"] + paths)
            .split(separator: "\0").map(String.init))
        let addPaths = paths.filter { indexed.contains($0) || (try? FileManager.default.attributesOfItem(atPath: context.path + "/" + $0)) != nil }
        if !addPaths.isEmpty {
            _ = try await GitRepositoryReader.git(context.path, ["add", "-A", "--"] + addPaths, timeout: 60, writesRepository: true)
        }
        do {
            try await verify(context)
            _ = try await GitRepositoryReader.git(context.path, ["commit", "--only", "-m", message, "--"] + paths, timeout: 120, writesRepository: true)
        } catch {
            throw Failure.stagedButNotCommitted(error.localizedDescription)
        }
    }

    public static func pushPreview(_ repository: TrackedRepository, branch: String, remote: String, destination: String) async throws -> GitPushPreview {
        try await validateBranch(destination, path: repository.path)
        let remotes = try await GitRepositoryReader.git(repository.path, ["remote"]).split(separator: "\n").map(String.init)
        guard remotes.contains(remote), !remote.hasPrefix("-") else { throw Failure.invalidName }
        let urls = try await GitRepositoryReader.git(repository.path, ["remote", "get-url", "--push", "--all", remote]).split(separator: "\n").map(String.init)
        guard urls.count == 1, let url = urls.first else { throw Failure.multipleDestinations }
        return GitPushPreview(branch: branch, head: try await branchHead(repository, branch: branch), remote: remote,
                              destination: destination, displayURL: sanitizedRemote(url), actualURL: url)
    }

    public func push(_ repository: TrackedRepository, preview: GitPushPreview, setUpstream: Bool) async throws {
        try acquire(repository.id); defer { busy.remove(repository.id) }
        let fresh = try await Self.pushPreview(repository, branch: preview.branch, remote: preview.remote, destination: preview.destination)
        guard fresh.head == preview.head, fresh.actualURL == preview.actualURL else { throw Failure.changed }
        var args = ["-c", "remote.\(preview.remote).mirror=false", "push", "--porcelain", "--no-force", "--no-follow-tags", "--recurse-submodules=no"]
        if setUpstream { args.append("--set-upstream") }
        args += ["--", preview.remote, "refs/heads/\(preview.branch):refs/heads/\(preview.destination)"]
        _ = try await GitRepositoryReader.git(repository.path, args, timeout: 120, writesRepository: true)
    }

    public func deleteLocal(_ repository: TrackedRepository, branch: String, expectedHead: String) async throws {
        try acquire(repository.id); defer { busy.remove(repository.id) }
        guard try await Self.branchHead(repository, branch: branch) == expectedHead else { throw Failure.changed }
        try await ensureUnoccupied(repository, branch: branch)
        _ = try await GitRepositoryReader.git(repository.path, ["branch", "-d", "--", branch], timeout: 30, writesRepository: true)
    }

    static func sanitizedRemote(_ value: String) -> String {
        if var url = URLComponents(string: value), url.scheme != nil, url.host != nil {
            url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
            return url.string ?? L10n.text("配置的远端", "Configured remote")
        }
        // SCP-style SSH URL: discard the login portion. Local remotes remain local paths.
        if let at = value.firstIndex(of: "@"), value[at...].contains(":") { return String(value[value.index(after: at)...]) }
        return value
    }

    private func acquire(_ id: String) throws {
        guard !busy.contains(id) else { throw Failure.busy }
        busy.insert(id)
    }
    private func verify(_ expected: GitActionContext) async throws {
        guard try await Self.context(path: expected.path) == expected else { throw Failure.changed }
    }
    private func ensureUnoccupied(_ repository: TrackedRepository, branch: String) async throws {
        let output = try await GitRepositoryReader.git(repository.path, ["worktree", "list", "--porcelain", "-z"])
        guard !GitRepositoryReader.parseWorktrees(output).contains(where: { $0.branch == branch }) else { throw Failure.occupied }
    }
    private static func validateBranch(_ name: String, path: String) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("@{") else { throw Failure.invalidName }
        do { _ = try await GitRepositoryReader.git(path, ["check-ref-format", "refs/heads/" + name]) }
        catch { throw Failure.invalidName }
    }
    private static func status(_ path: String) async throws -> String {
        try await GitRepositoryReader.git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    }
    private static func checkInProgress(_ path: String) async throws {
        for marker in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer"] {
            let file = try await GitRepositoryReader.git(path, ["rev-parse", "--path-format=absolute", "--git-path", marker]).trimmingCharacters(in: .newlines)
            if FileManager.default.fileExists(atPath: file) { throw Failure.inProgress }
        }
    }
}
