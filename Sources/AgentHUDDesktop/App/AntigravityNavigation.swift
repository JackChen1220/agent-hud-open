import AppKit
import Foundation

/// Uses Antigravity's bundled desktop contract: DevToolsActivePort and `/c/<conversationId>`.
@MainActor
enum AntigravityNavigation {
    static func open(conversationID: String) async -> Bool {
        guard UUID(uuidString: conversationID) != nil,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.antigravity").first,
              let port = activePort() else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let opened = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await navigate(conversationID: conversationID, port: port, session: session) }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                session.invalidateAndCancel()
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            session.invalidateAndCancel()
            return result
        }
        return opened && !Task.isCancelled && app.activate()
    }

    private static func activePort() -> Int? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let first = text.split(whereSeparator: \.isNewline).first,
              let port = Int(first), (1...65535).contains(port) else { return nil }
        return port
    }

    struct Page: Decodable, Sendable {
        let id: String
        let type: String
        let url: String
        let webSocketDebuggerUrl: URL?
    }

    nonisolated static func destination(conversationID: String, page: Page, port: Int) -> (id: String, url: URL, socket: URL)? {
        guard UUID(uuidString: conversationID) != nil, page.type == "page",
              let pageURL = URL(string: page.url), pageURL.scheme == "https", pageURL.host == "127.0.0.1",
              let socket = page.webSocketDebuggerUrl,
              socket.scheme == "ws", socket.host == "127.0.0.1", socket.port == port,
              socket.path == "/devtools/page/" + page.id,
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/c/" + conversationID
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        return (page.id, url, socket)
    }

    nonisolated static func destination(conversationID: String, pages: [Page], port: Int) -> (id: String, url: URL, socket: URL)? {
        let destinations = pages.compactMap { page -> (id: String, url: URL, socket: URL)? in
            destination(conversationID: conversationID, page: page, port: port)
        }
        let existing = destinations.filter { destination in
            pages.first(where: { $0.id == destination.id }).flatMap { URL(string: $0.url) }?.path == destination.url.path
        }
        if existing.count == 1 { return existing[0] }
        return existing.isEmpty && destinations.count == 1 ? destinations[0] : nil
    }

    nonisolated private static func navigate(conversationID: String, port: Int, session: URLSession) async -> Bool {
        do {
            let list = URL(string: "http://127.0.0.1:\(port)/json/list")!
            let (data, response) = try await session.data(from: list)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let pages = try JSONDecoder().decode([Page].self, from: data)
            guard let target = destination(conversationID: conversationID, pages: pages, port: port) else {
                return false
            }
            if pages.first(where: { $0.id == target.id }).flatMap({ URL(string: $0.url) })?.path == target.url.path {
                return true
            }
            let socket = session.webSocketTask(with: target.socket)
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }
            let result = try await command(id: 1, method: "Page.navigate", params: ["url": target.url.absoluteString], socket: socket)
            guard result["frameId"] is String, result["errorText"] == nil else { return false }
            // A reload detaches the original CDP execution context; the host's page inventory survives it.
            while true {
                try Task.checkCancellation()
                let (data, response) = try await session.data(from: list)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
                let current = try JSONDecoder().decode([Page].self, from: data)
                if let page = current.first(where: { $0.id == target.id }), let url = URL(string: page.url),
                   url.scheme == target.url.scheme && url.host == target.url.host && url.port == target.url.port
                    && url.path == target.url.path { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            return false
        }
    }

    nonisolated private static func command(id: Int, method: String, params: [String: Any],
                                           socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .data(let value): data = value
            case .string(let value): data = Data(value.utf8)
            @unknown default: return [:]
            }
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  response["id"] as? Int == id else { continue }
            return response["result"] as? [String: Any] ?? [:]
        }
    }
}
