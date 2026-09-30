import AgentHUDSupport
import Foundation

/// What a session is doing as the Mac shows it: a turn running or blocked on the user, nothing in flight, or in flight by
/// a reading too old for the Mac to vouch for. A provider decides when it reads a session whether its source has it in
/// flight (`LiveSession.endedAt`); the phase adds, at the time it is shown, how long the Mac vouches for that reading,
/// what the newest turn says and whether live status is on. A client's prompt and Stop hooks give a phase of their own.
public struct SessionPhase: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        /// A turn is in flight.
        case running
        /// A turn in flight is blocked on the user.
        case waitingForApproval
        /// Nothing is in flight, or live status is off.
        case idle
        /// The source had the session in flight when it was last read, too long ago for the Mac to vouch for it.
        case unverified
    }

    public let state: State
    /// In flight: when the turn started, or the session while no turn in flight is known. Otherwise: when the newest turn
    /// finished, else the session's last event.
    public let since: Date
    /// In flight: when the Mac stops vouching for the state without a newer reading. Nil otherwise, and for a hook turn,
    /// which nothing bounds.
    public let validUntil: Date?

    public init(state: State, since: Date, validUntil: Date?) {
        self.state = state
        self.since = since
        self.validUntil = validUntil
    }

    /// When the state changes without new evidence.
    public var nextChange: Date? { validUntil }

    /// Running or blocked on the user: both are work in flight.
    public var isInFlight: Bool { state == .running || state == .waitingForApproval }

    /// How long each piece of session evidence counts.
    public enum Limits {
        /// A session whose source never said what its turn is doing, or whose running turn was never seen to start, stays
        /// in flight this long after its log was last written.
        public static let quiet: TimeInterval = 120
        /// A running turn this quiet was abandoned: its client was killed, or its logs stopped reaching this Mac. One tool
        /// call can keep a log quiet for minutes, so silence alone ends a turn only after this long.
        public static let abandoned: TimeInterval = 30 * 60
        /// How long after a reading that had a session in flight the Mac still vouches for it.
        public static let vouched: TimeInterval = 30 * 60
        /// A Pi run whose observer snapshot is this old is over; the observer refreshes it every 15 seconds while the run
        /// is active.
        public static let heartbeat: TimeInterval = 120
        /// A running DeepSeek turn whose log is this quiet is checked against the processes that hold its profile.
        public static let processCheck: TimeInterval = 120
        /// The process table behind that check is read again at most this often.
        public static let processRecheck: TimeInterval = 30
    }

    // MARK: View

    /// The phase the Mac shows at `now` for a session its source reported, given its newest turn, when it last did
    /// something and whether its vendor's live status is on:
    /// - live status off: idle since the last event;
    /// - in flight by a reading less than `Limits.vouched` old: the newest turn's state while it runs or waits for approval,
    ///   since the turn's start, or its observation without one; with no such turn, running since the session's start;
    /// - in flight by an older reading, unverified; ended, idle; both since the newest turn's end when it finished, else the
    ///   last event.
    public init(session: LiveSession, turn: SessionTurn?, lastEventAt: Date, liveStatus: Bool, now: Date) {
        guard liveStatus else {
            self.init(state: .idle, since: lastEventAt, validUntil: nil)
            return
        }
        if session.endedAt == nil, now.timeIntervalSince(session.observedAt) < Limits.vouched {
            let validUntil = session.observedAt.addingTimeInterval(Limits.vouched)
            if let turn, turn.state == .running || turn.state == .waitingForApproval {
                self.init(state: turn.state == .running ? .running : .waitingForApproval,
                          since: RecordCoding.date(turn.startedAtMs ?? turn.observedAtMs), validUntil: validUntil)
            } else {
                self.init(state: .running, since: session.startedAt, validUntil: validUntil)
            }
            return
        }
        let finishedAt = turn.flatMap { $0.state == .completed || $0.state == .ended ? RecordCoding.date($0.observedAtMs) : nil }
        self.init(state: session.endedAt == nil ? .unverified : .idle, since: finishedAt ?? lastEventAt, validUntil: nil)
    }

    // MARK: Hooks

    /// A turn a client's hooks saw: it starts when the prompt is submitted and ends at the Stop hook.
    public struct HookTurn: Hashable, Sendable {
        public var startedAt: Date
        public var endedAt: Date?
        /// Whether it is the turn the reading reports; the caller matches the ids.
        public var isReportedTurn: Bool

        public init(startedAt: Date, endedAt: Date?, isReportedTurn: Bool) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.isReportedTurn = isReportedTurn
        }
    }

    /// The phase a hook turn gives: running since its start while it is open, idle since its end.
    public init(hook: HookTurn) {
        self.init(state: hook.endedAt == nil ? .running : .idle, since: hook.endedAt ?? hook.startedAt, validUntil: nil)
    }

    /// Whether a hook turn takes the place of a reading's phase. The reading keeps it where it saw more than the hooks:
    /// work in flight after the hook's end; while the hook is open, a wait for approval of the same turn, or that turn's
    /// end dated after the hook's start; another turn, or one without an id, dated after the hook's start. Every
    /// comparison of times is strict.
    public static func hookPrevails(_ hook: HookTurn, over reading: SessionPhase, lastEventAt: Date) -> Bool {
        // Work the reading saw after the hook saw the agent stop, such as sub-agents left running, outlasts that stop.
        if reading.isInFlight, let end = hook.endedAt, lastEventAt > end { return false }
        guard hook.isReportedTurn else { return reading.since <= hook.startedAt }
        // The reading can see a wait for approval, or the turn's end, before the hooks do.
        return !(hook.endedAt == nil
            && (reading.state == .waitingForApproval || (!reading.isInFlight && reading.since > hook.startedAt)))
    }
}
