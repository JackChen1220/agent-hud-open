import Foundation

/// Local metadata reads and explicit remote fetches. No shell, source bodies or telemetry.
public enum GitRepositoryReader {
    public enum Failure: Error, LocalizedError {
        case command, timeout, truncated, invalidRepository, unmerged, authentication, network, rejected, locked, certificate, wouldOverwrite
        case commandFailed(Int32)
        public var errorDescription: String? {
            switch self {
            case .command: L10n.text("Git 操作无法执行，请检查所选仓库和分支。", "Git cannot perform this operation. Check the selected repository and branch.")
            case .unmerged: L10n.text("Git 拒绝删除：该本地分支尚未合并。请保留分支或在终端检查，不会强制删除。", "Git refused deletion: this local branch is not fully merged. It will not be force-deleted.")
            case .wouldOverwrite: L10n.text("切换会覆盖本地改动或文件，Git 已停止切换。请先提交受影响的改动，或在终端临时保存（git stash）后再切换。", "Git stopped the switch because it would overwrite local changes or files. Commit the affected changes or stash them in Terminal, then switch.")
            case .authentication: L10n.text("远端认证失败。请先在终端完成该仓库的 SSH 或 Git 凭据登录，再重试。", "Remote authentication failed. Sign in using this repository’s SSH or Git credentials in Terminal, then retry.")
            case .network: L10n.text("无法连接远端。请检查网络、公司 VPN 和代理设置后重试。", "Cannot reach the remote. Check your network, company VPN and proxy, then retry.")
            case .certificate: L10n.text("远端证书验证失败，请检查公司证书或代理配置。", "Remote certificate verification failed. Check your company certificate or proxy configuration.")
            case .rejected: L10n.text("远端拒绝推送，可能有更新的提交、受保护分支或服务端规则。请刷新远端后检查。", "Push rejected: newer commits, branch protection or server rules may apply. Fetch and inspect the remote.")
            case .locked: L10n.text("仓库正被其他 Git 操作锁定，请等待该操作结束后重试。", "Another Git operation holds a repository lock. Wait for it to finish, then retry.")
            case .commandFailed(let code): L10n.text("Git 操作失败（退出码 \(code)）。可能是仓库钩子、签名或配置问题；请在终端检查。", "Git failed (exit \(code)). Check repository hooks, signing and configuration in Terminal.")
            case .timeout: L10n.text("Git 检查超时，已保留旧数据。", "Git timed out; previous data was retained.")
            case .truncated: L10n.text("Git 结果过大，未展示不完整的数据。", "Git output exceeded the limit; incomplete data was not shown.")
            case .invalidRepository: L10n.text("请选择一个非裸 Git 仓库。", "Choose a non-bare Git repository.")
            }
        }
    }

    static func git(_ path: String, _ arguments: [String], timeout: TimeInterval = 10, writesRepository: Bool = false) async throws -> String {
        // Do not inherit a host's repository override, tracing, or interactive askpass configuration.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") && $0.key != "SSH_ASKPASS" }
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "Never"
        environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10"
        let readOnlyOptions = writesRepository ? [] : ["-c", "core.hooksPath=/dev/null"]
        let output = try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/git"),
            ["--no-pager", "--literal-pathspecs"] + readOnlyOptions + ["-c", "core.fsmonitor=false",
             "-c", "maintenance.auto=false", "-c", "gc.auto=0", "-C", path] + arguments,
            environment: environment, timeout: timeout, stdoutLimit: 4 * 1024 * 1024)
        guard output.status != nil else { throw Failure.timeout }
        guard output.status == 0 else { throw failure(stderr: String(decoding: output.stderr, as: UTF8.self), status: output.status ?? -1) }
        guard !output.truncated else { throw Failure.truncated }
        // stderr may contain credential-bearing URLs. It never enters UI, cache or logs.
        return String(decoding: output.stdout, as: UTF8.self)
    }

    static func failure(stderr: String, status: Int32) -> Failure {
        let text = stderr.lowercased()
        if text.contains("would be overwritten") || text.contains("would be removed") { return .wouldOverwrite }
        if text.contains("not fully merged") { return .unmerged }
        if text.contains("certificate") || text.contains("ssl peer") { return .certificate }
        if ["permission denied (publickey", "authentication failed", "could not read username", "could not read password", "http 401", "returned error: 401", "returned error: 403", "access denied"].contains(where: text.contains) { return .authentication }
        if ["could not resolve", "couldn't resolve", "connection timed out", "connection refused", "network is unreachable", "failed to connect", "could not connect", "connection reset", "connection closed"].contains(where: text.contains) { return .network }
        if text.contains("[rejected]") || text.contains("[remote rejected]") || text.contains("non-fast-forward") || text.contains("failed to push some refs") { return .rejected }
        if text.contains("index.lock") || text.contains("cannot lock ref") { return .locked }
        return .commandFailed(status)
    }

    public static func identify(path: String) async throws -> TrackedRepository {
        guard try await git(path, ["rev-parse", "--is-bare-repository"]).trimmingCharacters(in: .whitespacesAndNewlines) == "false" else {
            throw Failure.invalidRepository
        }
        let root = try await git(path, ["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .newlines)
        let common = try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .newlines)
        return TrackedRepository(id: URL(fileURLWithPath: common).resolvingSymlinksInPath().path,
                                 path: URL(fileURLWithPath: root).resolvingSymlinksInPath().path)
    }

    public static func read(_ repository: TrackedRepository) async throws -> RepositorySnapshot {
        let format = "%(refname)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(subject)%00%(symref)%00%(upstream:remotename)%00%(objectname)"
        let refs = try await git(repository.path, ["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"])
        let worktrees = try await git(repository.path, ["worktree", "list", "--porcelain", "-z"])
        let remotes = try await git(repository.path, ["remote"])
        return RepositorySnapshot(branches: parseBranches(refs), worktrees: parseWorktrees(worktrees),
                                  remotes: remotes.split(separator: "\n").map(String.init), readAt: Date())
    }

    static func parseBranches(_ text: String) -> [GitBranch] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8, fields[6].isEmpty else { return nil } // skip remote HEAD aliases
            let remote = fields[0].hasPrefix("refs/remotes/")
            let prefix = remote ? "refs/remotes/" : "refs/heads/"
            let track = fields[3]
            var ahead = 0, behind = 0
            for part in track.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",") {
                let words = part.split(separator: " ")
                if words.count == 2, let count = Int(words[1]) {
                    if words[0] == "ahead" { ahead = count }
                    if words[0] == "behind" { behind = count }
                }
            }
            let sync: BranchSync = fields[2].isEmpty ? .noUpstream : track == "[gone]" ? .missingUpstream
                : ahead > 0 && behind > 0 ? .diverged : ahead > 0 ? .ahead : behind > 0 ? .behind
                : track.isEmpty ? .synced : .unknown
            return GitBranch(name: String(fields[0].dropFirst(prefix.count)), current: fields[1] == "*", remote: remote,
                             upstream: fields[2], upstreamRemote: fields[7], ahead: ahead, behind: behind, sync: sync,
                             subject: fields[5], committedAt: Date(timeIntervalSince1970: Double(fields[4]) ?? 0), objectID: fields.count > 8 ? fields[8] : nil)
        }
    }

    static func parseWorktrees(_ text: String) -> [GitWorktree] {
        var results: [GitWorktree] = [], current: GitWorktree?
        for token in text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if token.hasPrefix("worktree ") {
                if let current { results.append(current) }
                current = GitWorktree(path: String(token.dropFirst(9)), branch: "", detached: false, prunable: false)
            } else if token.hasPrefix("branch refs/heads/") {
                current?.branch = String(token.dropFirst(18))
            } else if token == "detached" { current?.detached = true
            } else if token.hasPrefix("prunable") { current?.prunable = true }
        }
        if let current { results.append(current) }
        return results
    }

    public static func status(_ worktree: GitWorktree) async -> GitWorktree {
        var updated = worktree
        guard !worktree.prunable else { return updated }
        do {
            // porcelain v1 -z paths are opaque; a rename consumes a second NUL field.
            let output = try await git(worktree.path, ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=normal", "--ignore-submodules=all"])
            let records = output.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            let header = String(records.first ?? "")
            let expected = "## " + worktree.branch
            // A user/agent may have switched this worktree after refs were read. Never attribute
            // that directory's uncommitted changes to the previous branch.
            guard worktree.detached ? header == "## HEAD (no branch)"
                : (header == expected || header.hasPrefix(expected + "...")) else { throw Failure.command }
            let counts = parseStatus(records.count == 2 ? String(records[1]) : "")
            updated.changedEntries = counts.changed
            updated.conflicts = counts.conflicts
            updated.checkedAt = Date()
            updated.error = nil
        } catch {
            updated.error = (error as? Failure)?.errorDescription ?? L10n.text("工作目录检查失败", "Worktree check failed")
        }
        return updated
    }

    static func parseStatus(_ text: String) -> (changed: Int, conflicts: Int) {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0, changed = 0, conflicts = 0
        while index < fields.count {
            let code = String(fields[index].prefix(2))
            changed += 1
            if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(code) { conflicts += 1 }
            index += code.contains("R") || code.contains("C") ? 2 : 1
        }
        return (changed, conflicts)
    }

    /// The only network operation in this feature, called from an explicit user action.
    public static func fetch(_ repository: TrackedRepository, remote: String) async throws {
        let remotes = try await git(repository.path, ["remote"]).split(separator: "\n").map(String.init)
        guard remotes.contains(remote), !remote.hasPrefix("-"), !remote.contains(":") else { throw Failure.command }
        // Explicit destination prevents custom fetch mappings from updating local branches.
        _ = try await git(repository.path, ["fetch", "--refmap=", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "--prune",
                                           "--", remote, "+refs/heads/*:refs/remotes/\(remote)/*"], timeout: 30)
    }

    public static func integrationState(_ repository: TrackedRepository, sourceID: String, targetID: String) async -> BranchIntegrationState {
        // Object IDs bind the answer to the metadata snapshot even if another process moves refs.
        guard [sourceID, targetID].allSatisfy({ $0.count >= 40 && $0.allSatisfy(\.isHexDigit) }) else { return .unknown }
        do {
            _ = try await git(repository.path, ["merge-base", "--is-ancestor", sourceID, targetID])
            return .included
        } catch Failure.commandFailed(1) { return .notIncluded }
        catch { return .unknown }
    }

    public static func candidates(under directory: URL) async -> [TrackedRepository] {
        let paths = await Task.detached(priority: .utility) {
            var found: [String] = [], queue: [(URL, Int)] = [(directory, 0)]
            let excluded: Set<String> = ["node_modules", "vendor", "build", "dist", "Library", "Pods"]
            var visited = 0
            while !queue.isEmpty, visited < 2000, found.count < 100 {
                let (url, depth) = queue.removeFirst(); visited += 1
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    found.append(url.path); continue
                }
                guard depth < 3 else { continue }
                let children = (try? FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
                for child in children where !excluded.contains(child.lastPathComponent) {
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true, values?.isSymbolicLink != true { queue.append((child, depth + 1)) }
                }
            }
            return found.sorted()
        }.value
        var result: [TrackedRepository] = []
        for path in paths {
            guard !Task.isCancelled else { break }
            if let repo = try? await identify(path: path), !result.contains(where: { $0.id == repo.id }) { result.append(repo) }
        }
        return result
    }
}
