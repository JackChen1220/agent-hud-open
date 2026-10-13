import Foundation

public struct TrackedRepository: Codable, Hashable, Identifiable, Sendable {
    /// Real common Git directory: linked worktrees are one project, independent clones are not.
    public var id: String
    public var path: String
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(id: String, path: String) { self.id = id; self.path = path }
}

public enum BranchProgress: String, Codable, CaseIterable, Sendable {
    // Keep `testing` as the persisted value for the existing "待测试" state.
    case unmarked, developing, integration, testing, inTesting, awaitingMerge, awaitingRelease, complete, paused
    public var label: String {
        switch self {
        case .unmarked: L10n.text("未标记", "Unmarked")
        case .developing: L10n.text("开发中", "Developing")
        case .integration: L10n.text("待联调", "Integration")
        case .testing: L10n.text("待测试", "Awaiting tests")
        case .inTesting: L10n.text("测试中", "Testing")
        case .awaitingMerge: L10n.text("待合并", "Awaiting merge")
        case .awaitingRelease: L10n.text("待发布", "Awaiting release")
        case .complete: L10n.text("已完成", "Complete")
        case .paused: L10n.text("暂停", "Paused")
        }
    }
}

public struct BranchNote: Codable, Hashable, Sendable {
    public var title = ""
    public var progress: BranchProgress = .unmarked
    public var text = ""
    public var pinned = false
    public init() {}
}

public enum BranchSync: String, Codable, Sendable {
    case noUpstream, missingUpstream, synced, ahead, behind, diverged, unknown
    public var label: String {
        switch self {
        case .noUpstream: L10n.text("未配置上游", "No upstream")
        case .missingUpstream: L10n.text("上游引用缺失", "Upstream missing")
        case .synced: L10n.text("与缓存上游一致", "Matches cached upstream")
        case .ahead: L10n.text("领先上游", "Ahead of upstream")
        case .behind: L10n.text("落后上游", "Behind upstream")
        case .diverged: L10n.text("已分叉", "Diverged")
        case .unknown: L10n.text("同步状态待确认", "Sync unknown")
        }
    }
}

public struct GitBranch: Codable, Hashable, Identifiable, Sendable {
    public var id: String { (remote ? "refs/remotes/" : "refs/heads/") + name }
    public var name: String
    public var current: Bool
    public var remote: Bool
    public var upstream: String
    public var upstreamRemote: String
    public var ahead: Int
    public var behind: Int
    public var sync: BranchSync
    public var subject: String
    public var committedAt: Date
    public var objectID: String? = nil
}

public struct GitWorktree: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var branch: String
    public var detached: Bool
    public var prunable: Bool
    public var changedEntries: Int?
    public var conflicts: Int?
    public var checkedAt: Date?
    public var error: String?
}

public struct RepositorySnapshot: Codable, Sendable {
    public var branches: [GitBranch]
    public var worktrees: [GitWorktree]
    public var remotes: [String]
    public var readAt: Date
}

public struct RepositoryArchive: Codable, Sendable {
    public var repositories: [TrackedRepository] = []
    public var selectedID: String?
    public var snapshots: [String: RepositorySnapshot] = [:]
    public var notes: [String: [String: BranchNote]] = [:]
    /// Only this application's successful explicit fetches, never inferred from a local read.
    public var fetchedAt: [String: [String: Date]] = [:]
    /// Optional for archives created before integration targets were introduced.
    public var integrationTargets: [String: [String: String]]? = nil
    public init() {}
}

public enum BranchIntegrationState: String, Sendable {
    case included, notIncluded, unknown
    public var label: String {
        switch self {
        case .included: L10n.text("已包含", "Included")
        case .notIncluded: L10n.text("未完整包含", "Not fully included")
        case .unknown: L10n.text("待确认", "Unknown")
        }
    }
}
