import Foundation
import AgentHUDCore

/// Cheap, prompt-free detection of local agent installs for the first-launch screen.
enum SourceDetector {
    static func resolve(_ sources: [SourceStatus], report: UsageReport?) -> [SourceStatus] {
        guard let report else { return sources }
        return sources.map { source in
            // Shared account quota does not establish that either execution client supplied sessions.
            if source.provider == "Grok", source.name == "Grok CLI" || source.name == "Grok Bot" {
                guard source.supportsLiveStatus,
                      report.sessions.contains(where: { SessionSource(vendor: "Grok", client: $0.client).name == source.name
                          && SessionSource.vendor(impliedBy: $0.agentId) == "Grok" }) else { return source }
                return SourceStatus(id: source.id, name: source.name, detail: source.detail, state: .ready(plan: nil),
                                    provider: source.provider, supportsLiveStatus: source.supportsLiveStatus)
            }
            let vendor: String
            switch source.id {
            case "claude-code": vendor = "Claude"
            case "codex-cli": vendor = "Codex"
            case "deepseek": vendor = "DeepSeek"
            default:
                if let additional = AdditionalSource(rawValue: source.id) { vendor = additional.vendor }
                else if let additional = OpenAgentSource(rawValue: source.id) { vendor = additional.name }
                else { return source }
            }
            if vendor == "DeepSeek", report.discoveredAgents.contains(where: { $0.id == "deepseek" && $0.connected }) {
                return SourceStatus(id: source.id, name: source.name, detail: source.detail, state: .ready(plan: nil),
                                    provider: source.provider, supportsLiveStatus: source.supportsLiveStatus)
            }
            let hasQuota = report.discoveredAgents.contains { agent in
                (agent.vendor == vendor || vendor == "OpenCode" && agent.vendor == "OpenCode Go") && report.snapshots.contains { $0.agentId == agent.id }
            }
            let hasSessions = report.consumers.contains { $0.vendor == vendor }
            let plan = report.subscriptions[vendor]
            if let notice = report.sourceNotices[vendor] ?? (vendor == "OpenCode" ? report.sourceNotices["OpenCode Go"] : nil) {
                return SourceStatus(id: source.id, name: source.name, detail: notice,
                    state: hasQuota || hasSessions || plan != nil ? .ready(plan: plan) : .unavailable,
                    provider: source.provider, supportsLiveStatus: source.supportsLiveStatus)
            }
            guard hasQuota || hasSessions || plan != nil else { return source }
            return SourceStatus(id: source.id, name: source.name, detail: source.detail, state: .ready(plan: plan),
                                provider: source.provider, supportsLiveStatus: source.supportsLiveStatus)
        }
    }

    static func detect(fileManager: FileManager = .default) -> [SourceStatus] {
        let home = fileManager.homeDirectoryForCurrentUser
        let engine = ClaudeEngineLocator.find(home: home, fileManager: fileManager)
        let claudeReady = engine != nil || fileManager.fileExists(atPath: home.appendingPathComponent(".claude/projects").path)
        let codexReady = CodexLocator.find() != nil
        let deepseekReady = DeepSeekLocator.isInstalled()
        let claudeDetail: String
        if engine != nil {
            claudeDetail = L10n.text("额度、会话与用量统计", "Quota, sessions and usage")
        } else if claudeReady {
            claudeDetail = L10n.text("已发现会话，安装并登录后读取额度", "Sessions found; install and sign in to read quota")
        } else {
            claudeDetail = L10n.text("安装并登录后读取用量", "Reads usage once installed and signed in")
        }
        return [
            SourceStatus(
                id: "claude-code", name: "Claude",
                detail: claudeDetail,
                state: claudeReady ? .installed : .notDetected
            ),
            SourceStatus(
                id: "codex-cli", name: "Codex",
                detail: codexReady
                    ? L10n.text("额度、会话与用量统计", "Quota, sessions and usage")
                    : L10n.text("安装并登录后读取用量", "Reads usage once installed and signed in"),
                state: codexReady ? .installed : .notDetected
            ),
            SourceStatus(id: "deepseek", name: "DeepSeek",
                         detail: deepseekReady
                             ? L10n.text("Harness 会话、API 余额与费用", "Harness sessions, API balance and costs")
                             : L10n.text("启动 Harness 后读取用量", "Reads usage after starting Harness"),
                         state: deepseekReady ? .installed : .notDetected),
        ] + AdditionalSource.allCases.flatMap { source -> [SourceStatus] in
            let status = SourceStatus(id: source.rawValue, name: source == .grok ? "Grok CLI" : source.vendor,
                                     detail: source == .grok ? L10n.text("本地会话与用量", "Local sessions and usage") : source.detail,
                                     state: source.isInstalled(home: home) ? .installed : .notDetected,
                                     provider: source.vendor)
            guard source == .grok else { return [status] }
            return [status, SourceStatus(id: "grok-bot", name: "Grok Bot",
                detail: L10n.text("会话、用量与实时状态读取暂未支持", "Session, usage and live status reading is not supported yet"),
                state: GrokBotLocator.isInstalled(home: home) ? .installed : .notDetected,
                provider: "Grok", supportsLiveStatus: false)]
        } + OpenAgentSource.allCases.map {
            SourceStatus(id: $0.rawValue, name: $0.name, detail: $0.detail, state: $0.isInstalled(home: home) ? .installed : .notDetected)
        }
    }
}
