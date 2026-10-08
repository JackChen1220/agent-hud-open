import Foundation

/// Follows the questions DeepSeek Harness's web hosts are already asking, over the event stream each one serves on
/// loopback. It installs no hook and answers nothing on its own; the host stays the authority for every question's
/// lifetime — a question answered in Harness arrives as a `question/resolved` frame, and a host that stops talking
/// takes its questions with it.
@MainActor
public final class DeepSeekQuestionObserver {
    private let requests: PermissionRequests
    private var client: DeepSeekQuestions
    /// How long a process keeps its port after it was last confirmed a Harness web host.
    private let endpointLifetime: TimeInterval = 60
    private var endpoints: [Int: Date] = [:]
    /// One connection per confirmed endpoint; its frames carry only this port's questions.
    private var streams: [Int: Task<Void, Never>] = [:]
    /// Questions now waiting, by request id, so a resolution from any channel withdraws exactly that card.
    private var pending: [String: DeepSeekQuestions.Pending] = [:]
    /// Resolutions seen, so a question frame that arrives after its own resolution — the host's pushes are not
    /// ordered — is not turned back into a card.
    private var resolved: [String: Date] = [:]
    /// How long a resolution is remembered, and the frames it can still outrun.
    private let resolutionMemory: TimeInterval = 120
    private var task: Task<Void, Never>?

    /// What discovery runs; the tests replace these instead of starting processes.
    var discover: @Sendable () async -> [Int] = { await DeepSeekQuestionObserver.discoverPorts() }
    var clock: @Sendable () -> Date = { Date() }
    /// Opens the event stream for a port. The closure returns only when the connection ends; it hands each frame's
    /// JSON to `onFrame` and gives up when asked to stop.
    var connect: @Sendable (Int, @escaping @Sendable (ProviderJSON) -> Void, @escaping @Sendable () -> Bool) async -> Void
        = { port, onFrame, shouldStop in await DeepSeekQuestionObserver.stream(port: port, onFrame: onFrame, shouldStop: shouldStop) }

    public init() {
        requests = .shared
        client = DeepSeekQuestions()
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled else { return stop() }
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        for stream in streams.values { stream.cancel() }
        streams.removeAll()
        endpoints.removeAll()
        pending.removeAll()
        resolved.removeAll()
        requests.stopNativeRequests(source: .deepseek)
    }

    /// Rediscovers hosts, forgets the ones gone quiet, and opens streams for the ones newly confirmed. Every
    /// confirmation asks the port itself, so another process that takes a remembered port is not answered.
    private func refresh() async {
        let found = await discover()
        let now = clock()
        var confirmed: Set<Int> = []
        for port in found where endpoints[port] == nil || now.timeIntervalSince(endpoints[port]!) > endpointLifetime {
            guard (try? await client.describe(port: port)) == true else { endpoints[port] = nil; continue }
            endpoints[port] = now
        }
        for port in found {
            guard endpoints[port] != nil else { continue }
            confirmed.insert(port)
            if streams[port] == nil {
                let onFrame: @Sendable (ProviderJSON) -> Void = { [weak self] frame in
                    Task { @MainActor [weak self] in self?.handle(frame, port: port) }
                }
                let shouldStop: @Sendable () -> Bool = { [weak self] in
                    guard let self, !Task.isCancelled else { return true }
                    return MainActor.assumeIsolated { self.endpoints[port] == nil }
                }
                let stream = Task { [connect] in
                    await connect(port, onFrame, shouldStop)
                    await MainActor.run { [weak self] in self?.closed(port) }
                }
                streams[port] = stream
            }
        }
        for (port, stream) in streams where !confirmed.contains(port) {
            stream.cancel()
            streams[port] = nil
        }
        if confirmed.isEmpty { requests.removeNativeRequests(source: .deepseek) }
    }

    /// One frame off a host's stream: a question opens its card, a resolution takes it down.
    func handle(_ frame: ProviderJSON, port: Int) {
        let now = clock()
        resolved = resolved.filter { now.timeIntervalSince($0.value) < resolutionMemory }
        if let rpcID = frame["payload"]["questionRpcId"].stringValue {
            resolved[rpcID] = now
            if let request = pending.values.first(where: { $0.rpcID == rpcID }) {
                withdraw(request.id)
            }
            return
        }
        guard let read = DeepSeekQuestions.Frame.read(frame) else { return }
        // A resolution already seen for this question wins: the frame is late, not new.
        if let seen = resolved[read.rpcID], now.timeIntervalSince(seen) < resolutionMemory { return }
        let waiting = DeepSeekQuestions.pending(read, port: port, now: now)
        pending[waiting.id] = waiting
        publish()
    }

    private func closed(_ port: Int) {
        streams[port] = nil
        endpoints[port] = nil
        for waiting in pending.values where waiting.port == port { pending.removeValue(forKey: waiting.id) }
        publish()
    }

    private func withdraw(_ id: String) {
        pending.removeValue(forKey: id)
        publish()
    }

    /// Republishes what is waiting. An answer comes from one place at a time: the queue holds the answer closure,
    /// which tells this host the decision and leaves a question answered elsewhere to its own frame.
    private func publish() {
        let waiting = pending.values.sorted { ($0.request.at, $0.id) < ($1.request.at, $1.id) }
        requests.updateNativeRequests(waiting.map(\.request), source: .deepseek) { [weak self] request, decision in
            guard let self, let waiting = self.pending[request.id] else { return }
            self.withdraw(request.id)
            guard decision != .leave else { return }
            let body = try DeepSeekQuestions.answer(decision, for: waiting)
            let reply = try await self.client.send(body, port: waiting.port)
            // A rejected answer means the question was settled while it was being answered here; the host's own
            // resolution frame withdraws the card either way.
            _ = DeepSeekQuestions.accepted(reply)
        }
    }

    nonisolated static let defaultPort = 3080

    /// The Harness web hosts running right now: processes whose command names the Harness entry and a web profile.
    /// A port named on the command line is what the host serves; without one, the default.
    nonisolated static func discoverPorts(
        inspect: @Sendable (String, [String]) async throws -> String = ProviderCommand.run
    ) async -> [Int] {
        guard let output = try? await inspect("/bin/ps", ["-U", String(getuid()), "-o", "pid=,command="]) else { return [] }
        var ports: Set<Int> = []
        for line in output.split(separator: "\n") {
            let command = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            guard isHarness(command) else { continue }
            if let port = flag("port", command: command).flatMap(Int.init), (1...65535).contains(port) {
                ports.insert(port)
            } else {
                ports.insert(defaultPort)
            }
        }
        return ports.sorted()
    }

    /// The Harness entry — `dsh` or the package's `bin.js` — running its web profile, the only profile whose
    /// host asks questions. Which home a process serves its files under its environment keeps to itself; the
    /// describe call is what confirms the port.
    nonisolated static func isHarness(_ command: String) -> Bool {
        let lower = command.lowercased()
        guard lower.range(of: #"(?:^|/)(?:dsh|bin\.js)(?:\s|$)"#, options: .regularExpression) != nil else { return false }
        return lower.contains("--profile web") || lower.contains("--profile=web")
    }

    nonisolated private static func flag(_ name: String, command: String) -> String? {
        let pattern = #"(?:^|\s)--"# + NSRegularExpression.escapedPattern(for: name) + #"(?:=|\s+)(?:"([^"]+)"|'([^']+)'|([^\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: command) { return String(command[range]) }
        }
        return nil
    }

    /// The event stream: one downlink WebSocket per host, whose server pushes questions and resolutions without
    /// being polled. The connection ends when the socket does; the caller reconnects through `connect` again.
    static func stream(port: Int, onFrame: @escaping @Sendable (ProviderJSON) -> Void, shouldStop: @escaping @Sendable () -> Bool) async {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/api/events.mux") else { return }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket: URLSessionWebSocketTask
        do {
            socket = try await withTimeout(seconds: 5) {
                try await session.webSocketTask(with: URLRequest(url: url)).receiveOnce()
            }
        } catch {
            try? await Task.sleep(for: .seconds(1))
            return
        }
        while !shouldStop() {
            do {
                let message = try await socket.receive()
                if case .data(let data) = message, let frame = try? ProviderJSON.read(data) { onFrame(frame) }
                if case .string(let text) = message, let frame = try? ProviderJSON.read(Data(text.utf8)) { onFrame(frame) }
            } catch {
                return
            }
        }
    }
}

/// Runs an attempt that may hang — a connect to a socket nothing is answering — with a wall clock on it.
private func withTimeout<T: Sendable>(seconds: TimeInterval, _ attempt: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await attempt() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw URLError(.timedOut)
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private extension URLSessionWebSocketTask {
    /// `webSocketTask(with:)` returns a suspended task; the first receive is what starts the handshake.
    func receiveOnce() -> Self {
        resume()
        return self
    }
}
