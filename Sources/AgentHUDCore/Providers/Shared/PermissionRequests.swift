import AgentHUDSupport
import Foundation
import Network

/// The requests a user is being asked about right now, and the channel their clients are waiting on.
///
/// A request exists only while its client waits for it: the hook that carried it holds the connection open, so the
/// connection is the request. Answering resumes the client; the client giving up — because the user answered in the
/// terminal, because it timed out, or because it was killed — closes the connection, and the request leaves the HUD
/// on its own. Nothing is stored and nothing outlives the client.
@MainActor
@Observable
public final class PermissionRequests {
    public static let shared = PermissionRequests()

    /// In arrival order. Two sessions can be waiting at once, and parallel tool calls in one session can be too.
    public private(set) var pending: [PermissionRequest] = []

    @ObservationIgnored private var waiting: [String: NWConnection] = [:]
    /// How long a request waits for an answer before it goes back to the client's own prompt. The client's hook
    /// timeout stays far longer, as the ceiling for a HUD that stopped answering altogether; letting go here instead
    /// means a new value applies at once, to requests already waiting too, without rewriting any client's settings.
    @ObservationIgnored public var holdTime: TimeInterval = 600 {
        didSet { for request in pending { scheduleExpiry(request) } }
    }
    @ObservationIgnored private var channel: UnixSocketListener?
    @ObservationIgnored private var counter: UInt64 = 0

    private init() {}

    // MARK: Channel

    /// Where the hook and the app meet. The name is short on purpose: a unix socket path has about a hundred bytes.
    public nonisolated static var socketPath: String { AppSupport.directory.appendingPathComponent("permission.sock").path }

    /// Opens the channel, unless another copy of the app opened beside this one already serves it.
    public func start(path: String = PermissionRequests.socketPath) {
        guard channel == nil else { return }
        let channel = UnixSocketListener(path: path, requestLimit: 1024 * 1024, category: "permission") { data, connection in
            PermissionRequests.shared.register(data, connection: connection)
        }
        if channel.start() { self.channel = channel }
    }

    /// Lets every waiting client go back to asking in its own terminal, then closes the channel. Only the socket this
    /// process made is removed.
    public func stop() {
        for id in pending.map(\.id) { withdraw(id) }
        channel?.stop()
        channel = nil
    }

    // MARK: Receiving

    private func register(_ data: Data, connection: NWConnection) {
        // The hook names its own client; a payload that arrives on this socket without one cannot be placed.
        guard let source = source(of: data) else { return connection.cancel() }
        counter &+= 1
        let id = "\(source.rawValue)-\(counter)"
        guard let request = try? PermissionRequest.parse(data, source: source, id: id, now: Date()) else {
            return connection.cancel()
        }
        waiting[id] = connection
        pending.append(request)
        scheduleExpiry(request)
        // A client that gives up closes the socket. That is the only signal that a request stopped being a question,
        // and it arrives whether the user answered in the terminal, the hook timed out or the client was killed.
        connection.stateUpdateHandler = { state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed:
                    // An answered request is already gone from the table, so its own teardown withdraws nothing.
                    PermissionRequests.shared.withdraw(id)
                default:
                    break
                }
            }
        }
    }

    /// The hook adds its own name to the payload it forwards; the client's own fields are left untouched.
    private func source(of data: Data) -> PermissionHooks.Source? {
        guard let payload = try? ProviderJSON.read(data),
              let name = payload[PermissionHookClient.sourceKey].stringValue else { return nil }
        return PermissionHooks.Source(rawValue: name)
    }

    // MARK: Answering

    /// Hands the client the user's decision and lets it go.
    public func resolve(_ id: String, _ decision: PermissionDecision) {
        guard decision != .leave else { return withdraw(id) }
        guard let request = request(id) else { return }
        pending.removeAll { $0.id == id }
        // The demo's requests have no client waiting behind them: taking the card away is the whole answer.
        guard let connection = waiting.removeValue(forKey: id) else { return }
        connection.send(content: decision.response(for: request), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func scheduleExpiry(_ request: PermissionRequest) {
        let delay = max(0, request.at.addingTimeInterval(holdTime).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [id = request.id] in
            MainActor.assumeIsolated { PermissionRequests.shared.expire(id) }
        }
    }

    /// A request nobody answered in time goes back unanswered, so the client asks in its own prompt. A timer set
    /// under an earlier, longer wait finds the request still inside the current one and leaves it.
    private func expire(_ id: String) {
        guard let request = request(id), waiting[id] != nil, Date() >= request.at.addingTimeInterval(holdTime) else { return }
        withdraw(id)
    }

    /// Takes a request off the HUD without answering it: the client goes on as if the HUD had never been there.
    public func withdraw(_ id: String) {
        pending.removeAll { $0.id == id }
        waiting.removeValue(forKey: id)?.cancel()
    }

    public func request(_ id: String) -> PermissionRequest? { pending.first { $0.id == id } }

    /// Fills the queue for the demo. Nothing is listening on the channel in that mode, and nothing is answered
    /// on any client's behalf.
    public func seedDemo(now: Date = Date()) {
        pending = PermissionRequest.demo(now: now)
    }
}
