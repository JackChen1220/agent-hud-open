import SwiftUI
import AgentHUDCore

enum BranchFilter: String, CaseIterable {
    case focused, all, pending
    var title: String {
        switch self {
        case .focused: L10n.text("关注", "Focus")
        case .all: L10n.text("全部", "All")
        case .pending: L10n.text("需检查", "Needs review")
        }
    }
}

struct BranchPanelView: View {
    let store: RepositoryStore
    let onManage: () -> Void
    var observesChanges = true
    var listHeight: CGFloat = 285
    @State private var filter = BranchFilter.focused

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RepositoryHeader(store: store, onManage: onManage)
            if let repo = store.selected {
                RepositoryRefreshStatus(store: store, repository: repo)
                HStack {
                    Picker("", selection: $filter) {
                        ForEach(BranchFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 240)
                    Spacer()
                    Button(action: onManage) { Image(systemName: "magnifyingglass") }.help(L10n.text("搜索分支", "Search branches"))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleBranches) { branch in
                            Button {
                                store.selectedBranch = branch.id
                                onManage()
                            } label: {
                                BranchRow(store: store, branch: branch)
                                    .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                        if visibleBranches.isEmpty {
                            Text(L10n.text("暂无符合条件的分支", "No matching branches"))
                                .foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                    }
                }.frame(height: listHeight)
                Text(L10n.text("同步状态来自本地远端引用；使用“刷新”菜单拉取最新信息。", "Sync uses cached remote refs. Fetch using the Refresh menu."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(L10n.text("把正在开发的项目放在这里", "Keep your active projects here"))
                    Text(L10n.text("查看分支、工作目录和同步状态", "Branches, worktrees and sync status at a glance"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button(L10n.text("添加项目", "Add project"), action: onManage).buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).frame(height: 220)
            }
        }
        .font(.system(size: 12))
        .task(id: store.selected?.id) { if observesChanges { await store.observeSelected() } }
    }

    private var visibleBranches: [GitBranch] {
        let branches = store.branches(includeRemote: filter == .all)
        if filter == .pending { return branches.filter { [.ahead, .behind, .diverged, .missingUpstream, .noUpstream].contains($0.sync) } }
        // Focus ranks pinned/current/worktree branches first, but never hides new local work.
        return branches
    }
}

struct RepositoryHeader: View {
    let store: RepositoryStore
    let onManage: () -> Void
    var body: some View {
        HStack {
            if let repo = store.selected {
                Menu {
                    ForEach(store.archive.repositories) { repository in
                        Button(repository.name) { store.select(repository.id) }
                    }
                    Divider()
                    Button(L10n.text("管理项目…", "Manage projects…"), action: onManage)
                } label: {
                    Label(repo.name, systemImage: "folder").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if store.refreshing.contains(repo.id) || store.fetching.contains(repo.id) { ProgressView().controlSize(.mini) }
                Menu {
                    Button(L10n.text("刷新本地状态", "Refresh local status")) { store.refresh() }
                        .disabled(store.refreshing.contains(repo.id))
                    Divider()
                    ForEach(store.snapshot?.remotes ?? [], id: \.self) { remote in
                        Button(L10n.text("拉取远端分支信息 · ", "Fetch remote refs · ") + remote) { store.fetch(remote: remote) }
                            .disabled(store.fetching.contains(repo.id))
                    }
                } label: { Label(L10n.text("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L10n.text("选择刷新本地状态或远端分支信息", "Refresh local state or fetch remote refs"))

            } else {
                Label(L10n.text("项目分支", "Project branches"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
        }.buttonStyle(.plain)
    }
}

struct RepositoryRefreshStatus: View {
    let store: RepositoryStore
    let repository: TrackedRepository
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = store.archive.snapshots[repository.id] {
                HStack {
                    Text(L10n.text("本地 \(snapshot.branches.filter { !$0.remote }.count) · 工作目录 \(snapshot.worktrees.count)",
                                   "\(snapshot.branches.filter { !$0.remote }.count) local · \(snapshot.worktrees.count) worktrees"))
                    Spacer()
                    Text(snapshot.readAt, style: .time)
                }
            }
            ForEach(store.snapshot?.remotes ?? [], id: \.self) { remote in
                HStack(spacing: 4) {
                    Text(remote + " ·")
                    if let date = store.archive.fetchedAt[repository.id]?[remote] {
                        Text(L10n.text("上次远端刷新", "Last fetch")); Text(date, style: .relative)
                    } else { Text(L10n.text("远端未检查，仅本地缓存", "Remote unchecked; cached refs only")) }
                }
            }
            if let error = store.errors[repository.id] { Text(error).foregroundStyle(.orange) }
            if let error = store.remoteErrors[repository.id] { Text(error).foregroundStyle(.orange) }
            if let error = store.storageError { Text(error).foregroundStyle(.orange) }
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

struct BranchRow: View {
    let store: RepositoryStore
    let branch: GitBranch
    var body: some View {
        let note = store.note(for: branch.name)
        let trees = store.snapshot?.worktrees.filter { $0.branch == branch.name && !branch.remote } ?? []
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: branch.current ? "circle.inset.filled" : branch.remote ? "cloud" : "arrow.triangle.branch")
                    .foregroundStyle(branch.current ? Color.green : .secondary)
                Text(note.title.isEmpty ? branch.name : note.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if note.pinned { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                if !branch.remote { BranchProgressBadge(progress: note.progress) }
            }
            if !note.title.isEmpty { Text(branch.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                Text(branch.remote ? L10n.text("远端引用缓存", "Cached remote ref") : branch.sync.label)
                    .foregroundStyle(branch.sync == .diverged ? Color.orange : .secondary)
                if branch.ahead > 0 { Text("↑\(branch.ahead)").foregroundStyle(.orange) }
                if branch.behind > 0 { Text("↓\(branch.behind)").foregroundStyle(.orange) }
                if !trees.isEmpty {
                    Text(trees.count == 1 ? L10n.text("工作目录", "Worktree") : "\(trees.count) worktrees")
                    if let changed = trees.first?.changedEntries, trees.first?.error == nil {
                        Text(L10n.text("修改 \(changed)", "\(changed) changed"))
                    } else { Text(L10n.text("待检查", "Unchecked")) }
                    if trees.contains(where: { ($0.conflicts ?? 0) > 0 }) { Text(L10n.text("冲突", "Conflicts")).foregroundStyle(.red) }
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if !branch.remote {
                HStack(spacing: 6) {
                    ForEach(["test", "uat"], id: \.self) { environment in
                        if let state = store.integration(branch, environment: environment) {
                            IntegrationBadge(environment: environment, state: state)
                        }
                    }
                }
            }
            Text(branch.subject).lineLimit(1).font(.system(size: 10)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
}
