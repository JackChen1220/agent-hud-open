import AppKit
import SwiftUI
import AgentHUDCore
import Observation

@MainActor @Observable
final class RepositoryWindowVisibility { var active = false }

@MainActor
final class RepositoryWindowController: HostedWindowController {
    private let visibility = RepositoryWindowVisibility()
    init(store: RepositoryStore) {
        super.init(size: CGSize(width: 980, height: 650), title: L10n.text("项目分支", "Project branches"), resizable: true)
        window?.minSize = CGSize(width: 800, height: 520)
        window?.isMovableByWindowBackground = false
        setContent(RepositoryManagerView(store: store, visibility: visibility).padding(.top, 28))
    }
    override func show() { visibility.active = true; super.show() }
    override func windowWillClose(_ notification: Notification) { visibility.active = false; super.windowWillClose(notification) }
    func windowDidMiniaturize(_ notification: Notification) { visibility.active = false }
    func windowDidDeminiaturize(_ notification: Notification) { visibility.active = true }
}

struct RepositoryManagerView: View {
    let store: RepositoryStore
    var visibility: RepositoryWindowVisibility
    @State private var search = ""
    @State private var filter = BranchFilter.focused
    @State private var discovering = false
    @State private var candidates: [TrackedRepository] = []
    @State private var choices: Set<String> = []
    @State private var choosing = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RepositoryHeader(store: store, onManage: chooseFolder)
                Button(action: chooseFolder) { Label(L10n.text("添加项目", "Add project"), systemImage: "folder.badge.plus") }
                    .disabled(discovering || !store.loaded)
                if discovering { ProgressView().controlSize(.small) }
                if let repo = store.selected {
                    Menu {
                        Button(L10n.text("打开项目目录", "Open project folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: repo.path)) }
                        Button(L10n.text("从列表移除（保留磁盘文件）", "Remove from list (keep files)")) { store.remove(repo.id) }
                    } label: { Image(systemName: "ellipsis.circle") }.frame(width: 25)
                }
            }.padding(16)
            if let repo = store.selected {
                RepositoryRefreshStatus(store: store, repository: repo).padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let message { Text(message).foregroundStyle(.orange).font(.callout).padding(8) }
            if let error = store.storageError { Text(error).foregroundStyle(.orange).padding(8) }
            Divider()
            HSplitView {
                VStack(spacing: 10) {
                    TextField(L10n.text("搜索分支、简称、提交或备注", "Search branches, titles, commits or notes"), text: $search)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $filter) {
                        ForEach(BranchFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)
                    List(selection: Binding(get: { store.selectedBranch }, set: { store.selectedBranch = $0 })) {
                        ForEach(branches) { branch in
                            BranchRow(store: store, branch: branch).padding(.vertical, 6).tag(branch.id)
                        }
                    }.listStyle(.plain)
                    Text(L10n.text("进度由你标记；代码同步不代表完成或上线。", "Progress is manual; sync does not imply completion or deployment."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(minWidth: 330, idealWidth: 420)
                if let repo = store.selected, let branch = store.snapshot?.branches.first(where: { $0.id == store.selectedBranch }) {
                    BranchDetailView(store: store, repository: repo, branch: branch)
                        .id(repo.id + "\0" + branch.name).frame(minWidth: 330)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(store.selected == nil ? L10n.text("添加项目以查看分支", "Add a project to view branches") : L10n.text("选择一条分支", "Select a branch"))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minWidth: 330)
                }
            }
        }
        .task(id: "\(visibility.active)-\(store.selected?.id ?? "")") {
            if visibility.active { await store.observeSelected() }
        }
        .sheet(isPresented: $choosing) { candidatePicker }
    }

    private var branches: [GitBranch] {
        store.branches(includeRemote: filter == .all).filter { branch in
            let note = store.note(for: branch.name)
            let text = [branch.name, branch.subject, note.title, note.text].joined(separator: " ")
            let matchesFilter = filter != .pending || (!branch.remote && [.ahead, .behind, .diverged, .missingUpstream, .noUpstream].contains(branch.sync))
            return matchesFilter && (search.isEmpty || text.localizedCaseInsensitiveContains(search))
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = L10n.text("选择仓库，或选择父目录扫描候选项目（最多 3 层）。", "Choose a repository or scan a parent folder (up to 3 levels).")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            discovering = true; message = nil
            Task {
                if let repository = try? await GitRepositoryReader.identify(path: url.path) {
                    store.add([repository])
                } else {
                    candidates = await GitRepositoryReader.candidates(under: url)
                    choices = []
                    if candidates.isEmpty { message = L10n.text("未发现仓库，可直接选择更深层的项目目录。", "No repositories found. Try selecting a project folder directly.") }
                    else { choosing = true }
                }
                discovering = false
            }
        }
    }

    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("选择要跟踪的项目", "Choose projects to track")).font(.headline)
            Text(L10n.text("仅保存选中的仓库；备份和独立克隆不会自动加入。", "Only selected repositories are added, including backups and independent clones."))
                .font(.caption).foregroundStyle(.secondary)
            List(candidates) { candidate in
                Toggle(isOn: Binding(get: { choices.contains(candidate.id) }, set: { selected in
                    if selected { choices.insert(candidate.id) } else { choices.remove(candidate.id) }
                })) {
                    VStack(alignment: .leading) {
                        Text(candidate.name)
                        Text(candidate.path).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(height: 300)
            HStack {
                Spacer()
                Button(L10n.text("取消", "Cancel")) { choosing = false }
                Button(L10n.text("添加所选", "Add selected")) {
                    store.add(candidates.filter { choices.contains($0.id) }); choosing = false
                }.disabled(choices.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 580)
    }
}

private struct BranchDetailView: View {
    let store: RepositoryStore
    let repository: TrackedRepository
    let branch: GitBranch
    @State private var action: BranchAction?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    Text(branch.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Spacer()
                    Button {
                        store.updateNote(branch.name, repositoryID: repository.id) { $0.pinned.toggle() }
                    } label: { Image(systemName: store.note(for: branch.name).pinned ? "star.fill" : "star") }
                        .help(L10n.text("置顶", "Pin"))
                }
                Button(L10n.text("复制分支名", "Copy branch name")) {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(branch.name, forType: .string)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button(L10n.text("切换到此分支…", "Switch to branch…")) { action = .switchBranch }
                            .disabled(!branch.remote && occupied)
                        if !branch.remote {
                            Button(L10n.text("提交…", "Commit…")) { action = .commit }.disabled(!occupied)
                            Button(L10n.text("推送…", "Push…")) { action = .push }
                                .disabled(store.snapshot?.remotes.isEmpty != false)
                        }
                    }
                    if !branch.remote {
                        Button(L10n.text("删除本地分支…", "Delete local branch…"), role: .destructive) { action = .delete }
                            .disabled(occupied)
                    }
                    if occupied {
                        Text(L10n.text("该分支已在工作目录中检出，可在下方打开目录。", "This branch is checked out; open its worktree below."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !branch.remote {
                    TextField(L10n.text("需求简称", "Task title"), text: noteBinding(\.title)).textFieldStyle(.roundedBorder)
                    Picker(L10n.text("手动进度", "Manual progress"), selection: noteBinding(\.progress)) {
                        ForEach(BranchProgress.allCases, id: \.self) { Label($0.label, systemImage: "circle.fill").foregroundStyle($0.color).tag($0) }
                    }
                    BranchProgressBadge(progress: store.note(for: branch.name).progress)
                    IntegrationTargetsView(store: store, branch: branch)
                    Text(L10n.text("备注 / 下一步", "Notes / next step")).font(.headline)
                    TextEditor(text: noteBinding(\.text)).font(.body).frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.2)))
                }
                Divider()
                Text(L10n.text("代码状态", "Code status")).font(.headline)
                Text(branch.remote ? L10n.text("远端分支的本地缓存", "Local cache of a remote branch") : branch.sync.label)
                if !branch.upstream.isEmpty {
                    Text("Upstream: " + branch.upstream).textSelection(.enabled)
                    Text(L10n.text("领先 \(branch.ahead) · 落后 \(branch.behind) 个提交", "\(branch.ahead) ahead · \(branch.behind) behind"))
                }
                Text(branch.subject).textSelection(.enabled)
                Text(branch.committedAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                ForEach(store.snapshot?.worktrees.filter { $0.branch == branch.name && !branch.remote } ?? []) { tree in
                    Divider()
                    Text(tree.path).font(.callout).textSelection(.enabled)
                    if let error = tree.error { Text(error).foregroundStyle(.orange) }
                    else if let count = tree.changedEntries {
                        Text(L10n.text("未提交 \(count) 项（含未跟踪目录） · 冲突 \(tree.conflicts ?? 0)", "\(count) changed entries (including untracked folders) · \(tree.conflicts ?? 0) conflicts"))
                    } else { Text(L10n.text("工作目录待检查", "Worktree unchecked")).foregroundStyle(.secondary) }
                    Button(L10n.text("打开工作目录", "Open worktree")) { NSWorkspace.shared.open(URL(fileURLWithPath: tree.path)) }
                        .disabled(tree.prunable)
                }
                Text(L10n.text("进度和备注保存在本机。推送会发送代码到你确认的远端；刷新只拉取信息。", "Progress and notes stay local. Push sends code to the remote you confirm; fetch only retrieves information."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $action) { action in
            BranchActionSheet(store: store, repository: repository, branch: branch, action: action)
        }
    }

    private var occupied: Bool {
        store.snapshot?.worktrees.contains(where: { $0.branch == branch.name && !$0.prunable }) == true
    }

    private func noteBinding<T>(_ path: WritableKeyPath<BranchNote, T>) -> Binding<T> {
        Binding(get: { store.note(for: branch.name, repositoryID: repository.id)[keyPath: path] },
                set: { value in store.updateNote(branch.name, repositoryID: repository.id) { $0[keyPath: path] = value } })
    }
}
