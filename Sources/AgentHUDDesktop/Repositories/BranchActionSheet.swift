import SwiftUI
import AgentHUDCore

enum BranchAction: String, Identifiable {
    case switchBranch, commit, push, delete
    var id: String { rawValue }
    var title: String {
        switch self {
        case .switchBranch: L10n.text("切换分支", "Switch branch")
        case .commit: L10n.text("提交所选文件", "Commit selected files")
        case .push: L10n.text("推送分支", "Push branch")
        case .delete: L10n.text("删除本地分支", "Delete local branch")
        }
    }
}

struct BranchActionSheet: View {
    let store: RepositoryStore
    let repository: TrackedRepository
    let branch: GitBranch
    let action: BranchAction
    @Environment(\.dismiss) private var dismiss
    @State private var context: GitActionContext?
    @State private var commitPreview: GitCommitPreview?
    @State private var pushPreview: GitPushPreview?
    @State private var targetHead: String?
    @State private var worktreePath = ""
    @State private var selectedFiles: Set<String> = []
    @State private var message = ""
    @State private var localName = ""
    @State private var remote = ""
    @State private var destination = ""
    @State private var setUpstream = false
    @State private var loading = true
    @State private var running = false
    @State private var error: String?

    private var worktrees: [GitWorktree] {
        store.snapshot?.worktrees.filter { $0.branch == branch.name && !$0.prunable } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.title2.weight(.semibold))
            Text(branch.name).font(.headline).textSelection(.enabled)
            if action == .commit {
                Picker(L10n.text("工作目录", "Worktree"), selection: $worktreePath) {
                    ForEach(worktrees) { Text($0.path).tag($0.path) }
                }.disabled(running)
                commitForm
            } else if action == .push {
                pushForm
            } else {
                Text(repository.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if action == .switchBranch {
                    Text(L10n.text("当前分支：", "Current branch: ") + (context?.branch ?? "…"))
                    if branch.remote {
                        TextField(L10n.text("创建并切换到本地分支", "Create and switch to local branch"), text: $localName).textFieldStyle(.roundedBorder)
                    }
                    Text(L10n.text("仅切换上方目录。未提交改动需要先处理；不会自动 stash 或覆盖文件。", "Only switches the directory above. Resolve uncommitted changes first; no automatic stash or overwrite."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(L10n.text("仅删除这个本地分支引用。保留远端分支和项目目录；被工作目录占用或 Git 判定尚未合并时会拒绝删除。", "Deletes only this local branch reference. Keeps the remote branch and project folder; checked-out or unmerged branches are refused."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text("重新检查", "Check again")) { Task { await load() } }.disabled(loading || running)
            }
            HStack {
                if loading || running {
                    ProgressView().controlSize(.small)
                    Text(running ? L10n.text("正在执行…", "Running…") : L10n.text("读取最新状态…", "Reading current state…")).font(.caption)
                }
                Spacer()
                Button(L10n.text("取消", "Cancel")) { dismiss() }.disabled(running).keyboardShortcut(.cancelAction)
                Button(action.title, role: action == .delete ? .destructive : nil) { perform() }
                    .disabled(!canPerform).buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 600)
        .interactiveDismissDisabled(running)
        .task { await load() }
        .onChange(of: worktreePath) { old, new in
            if old != new, !old.isEmpty { Task { await loadCommit() } }
        }
        .onChange(of: remote) { pushPreview = nil }
        .onChange(of: destination) { pushPreview = nil }
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("提交所选文件的全部当前改动，其他文件的暂存状态保持不变。", "Commits all current changes in selected files. Other staged files are preserved."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("全选", "Select all")) { selectedFiles = Set(commitPreview?.files.map(\.path) ?? []) }
                Button(L10n.text("清空选择", "Clear selection")) { selectedFiles = [] }
                Spacer()
                Text(L10n.text("已选 \(selectedFiles.count) 项", "\(selectedFiles.count) selected")).font(.caption)
            }.disabled(running || loading)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(commitPreview?.files ?? []) { file in
                        Toggle(isOn: Binding(get: { selectedFiles.contains(file.path) }, set: { selected in
                            if selected { selectedFiles.insert(file.path) } else { selectedFiles.remove(file.path) }
                        })) {
                            HStack(alignment: .top) {
                                Text(file.status).monospaced().foregroundStyle(.secondary)
                                Text(file.originalPath.map { $0 + " → " + file.path } ?? file.path).lineLimit(3)
                            }.font(.callout)
                        }.disabled(running)
                    }
                    if commitPreview?.files.isEmpty == true { Text(L10n.text("没有可提交的改动", "No changes to commit")).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 200)
            Text(L10n.text("提交说明", "Commit message")).font(.headline)
            TextEditor(text: $message).font(.body).frame(height: 90).disabled(running)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.25)))
        }
    }

    private var pushForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.text("远端", "Remote"), selection: $remote) {
                ForEach(store.snapshot?.remotes ?? [], id: \.self) { Text($0).tag($0) }
            }
            TextField(L10n.text("目标远端分支", "Destination branch"), text: $destination).textFieldStyle(.roundedBorder)
            Toggle(L10n.text("设为该本地分支的上游", "Set as this local branch's upstream"), isOn: $setUpstream)
            Button(L10n.text("检查推送目标", "Review push destination")) { Task { await reviewPush() } }
                .disabled(remote.isEmpty || destination.isEmpty || loading)
            if let preview = pushPreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preview.displayURL).textSelection(.enabled)
                    Text("\(preview.branch) → \(preview.remote)/\(preview.destination)")
                    Text("Commit: " + String(preview.head.prefix(12))).monospaced().font(.caption)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(L10n.text("推送会把该分支的提交及其所需代码对象发送到以上远端。不会自动提交，也不会强制覆盖远端历史。", "Push sends this branch’s commits and required code objects to the remote above. It does not auto-commit or force overwrite remote history."))
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(running)
    }

    private var canPerform: Bool {
        guard !loading, !running, error == nil else { return false }
        switch action {
        case .commit: return commitPreview != nil && !selectedFiles.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .push: return pushPreview != nil && pushPreview?.remote == remote && pushPreview?.destination == destination
        case .delete: return targetHead != nil
        case .switchBranch: return context != nil && targetHead != nil && (!branch.remote || !localName.isEmpty)
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            switch action {
            case .commit:
                worktreePath = worktrees.first?.path ?? repository.path
                await loadCommit()
            case .push:
                remote = (store.snapshot?.remotes.contains(branch.upstreamRemote) == true ? branch.upstreamRemote : store.snapshot?.remotes.first) ?? ""
                destination = branch.upstream.hasPrefix(remote + "/") ? String(branch.upstream.dropFirst(remote.count + 1)) : branch.name
                setUpstream = branch.upstream.isEmpty
            case .switchBranch:
                context = try await GitRepositoryActions.context(path: repository.path)
                targetHead = try await GitRepositoryActions.branchHead(repository, branch: branch.name, remote: branch.remote)
                if branch.remote {
                    let remoteName = (store.snapshot?.remotes ?? []).sorted { $0.count > $1.count }.first { branch.name.hasPrefix($0 + "/") }
                    localName = remoteName.map { String(branch.name.dropFirst($0.count + 1)) } ?? ""
                }
            case .delete:
                targetHead = try await GitRepositoryActions.branchHead(repository, branch: branch.name)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func loadCommit() async {
        let path = worktreePath
        loading = true; error = nil; commitPreview = nil; selectedFiles = []
        do {
            let preview = try await GitRepositoryActions.commitPreview(path: path)
            guard path == worktreePath else { return }
            guard preview.context.branch == branch.name else { throw GitRepositoryActions.Failure.changed }
            commitPreview = preview
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func reviewPush() async {
        loading = true; error = nil; pushPreview = nil
        do { pushPreview = try await GitRepositoryActions.pushPreview(repository, branch: branch.name, remote: remote, destination: destination) }
        catch { self.error = error.localizedDescription }
        loading = false
    }

    private func perform() {
        running = true
        Task {
            do {
                switch action {
                case .switchBranch:
                    if let context, let targetHead {
                        try await GitRepositoryActions.shared.switchBranch(repository, expected: context, branch: branch.name,
                            expectedTarget: targetHead, remote: branch.remote, localName: localName)
                    }
                case .commit:
                    if let commitPreview { try await GitRepositoryActions.shared.commit(commitPreview, selectedPaths: selectedFiles, message: message) }
                case .push:
                    if let pushPreview { try await GitRepositoryActions.shared.push(repository, preview: pushPreview, setUpstream: setUpstream) }
                case .delete:
                    if let targetHead { try await GitRepositoryActions.shared.deleteLocal(repository, branch: branch.name, expectedHead: targetHead) }
                }
                running = false
                store.refreshAfterOperation()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                running = false
                store.refreshAfterOperation()
            }
        }
    }
}
