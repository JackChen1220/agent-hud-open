import SwiftUI
import AgentHUDCore

extension BranchProgress {
    var color: Color {
        switch self {
        case .unmarked, .paused: .gray
        case .developing: .blue
        case .integration: .purple
        case .testing: .orange
        case .inTesting: .cyan
        case .awaitingMerge: .indigo
        case .awaitingRelease: .pink
        case .complete: .green
        }
    }
}

struct BranchProgressBadge: View {
    let progress: BranchProgress
    var body: some View {
        Label(progress.label, systemImage: progress == .complete ? "checkmark.circle.fill" : progress == .paused ? "pause.circle.fill" : "circle.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(progress.color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(progress.color.opacity(0.12), in: Capsule())
    }
}

struct IntegrationBadge: View {
    let environment: String
    let state: BranchIntegrationState
    var body: some View {
        let color: Color = state == .included ? .green : state == .notIncluded ? .orange : .gray
        Text(environment.uppercased() + " · " + state.label)
            .font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct IntegrationTargetsView: View {
    let store: RepositoryStore
    let branch: GitBranch
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("TEST / UAT 包含关系（自动）", "TEST / UAT inclusion (automatic)")).font(.headline)
            ForEach(["test", "uat"], id: \.self) { environment in
                HStack {
                    Picker(environment.uppercased(), selection: Binding(get: { store.integrationTarget(environment) ?? "" }, set: {
                        store.setIntegrationTarget(environment, ref: $0)
                    })) {
                        Text(L10n.text("选择目标分支", "Choose target branch")).tag("")
                        ForEach(store.snapshot?.branches ?? []) { target in
                            Text((target.remote ? "" : L10n.text("本地 · ", "Local · ")) + target.name).tag(target.id)
                        }
                    }
                    if let state = store.integration(branch, environment: environment) {
                        IntegrationBadge(environment: environment, state: state)
                    }
                }
            }
            Text(L10n.text("按本地引用检查当前分支的全部提交。目标设置对整个项目生效；远端引用需手动刷新。Cherry-pick / squash 可能显示“未完整包含”，不代表代码未迁移。", "Checks all branch commits using cached refs. Targets apply to this project; fetch remote refs manually. Cherry-pick / squash may appear as not fully included even when code was transferred."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
