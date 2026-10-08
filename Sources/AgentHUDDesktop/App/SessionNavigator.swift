import AppKit
import AgentHUDCore

/// Dispatches the session identity supplied by its client to that client's native UI.
@MainActor
enum SessionNavigator {
    static func open(_ target: SessionNavigationTarget) async -> Bool {
        guard !Task.isCancelled else { return false }
        if case .antigravityConversation(let id) = target {
            return await AntigravityNavigation.open(conversationID: id)
        }
        guard let url = url(for: target) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static func url(for target: SessionNavigationTarget) -> URL? {
        switch target {
        case .codexThread(let id):
            guard UUID(uuidString: id) != nil else { return nil }
            var components = URLComponents()
            components.scheme = "codex"
            components.host = "threads"
            components.path = "/" + id
            return components.url
        case .claudeDesktopSession(let id), .claudeCoworkSession(let id):
            guard id.hasPrefix("local_"), UUID(uuidString: String(id.dropFirst(6))) != nil else { return nil }
            var components = URLComponents()
            components.scheme = "claude"
            components.host = "claude.ai"
            let path = if case .claudeCoworkSession = target { "/cowork/" } else { "/epitaxy/" }
            components.path = path + id
            return components.url
        case .iTermSession(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var components = URLComponents()
            components.scheme = "iterm2"
            components.path = "reveal"
            components.queryItems = [URLQueryItem(name: "sessionid", value: id)]
            return components.url
        case .antigravityConversation:
            return nil
        case .grokBotAgent(let id):
            guard !id.isEmpty, id.utf8.count <= 128,
                  id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            var components = URLComponents()
            components.scheme = "grokbot"
            components.host = "app"
            components.path = "/v1/agent"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
            return components.url
        }
    }
}
