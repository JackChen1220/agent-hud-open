import Foundation
import SwiftUI
import AgentHUDCore

/// One presentation queue for quota events, added usage resets, completed turns and tool calls waiting to be approved.
enum IslandAlert: Identifiable {
    case quota(QuotaAlert)
    case resetCredits(ResetCreditGrant)
    case completion(SessionCompletion)
    case permission(PermissionRequest)

    var id: String {
        switch self {
        case .quota(let event): return event.id.uuidString
        case .resetCredits(let event): return event.id.uuidString
        case .completion(let event): return event.id
        case .permission(let request): return request.id
        }
    }
    var vendor: String {
        switch self {
        case .quota(let event): return event.agent.vendor
        case .resetCredits(let event): return event.account.account.provider
        case .completion(let event): return event.agentVendor
        case .permission(let request): return request.vendor
        }
    }
    var isWarning: Bool {
        switch self {
        case .quota(let event): return event.kind == .exhaustion
        case .permission: return true
        case .resetCredits, .completion: return false
        }
    }
    /// A request is a question, not news: it stays until its client has its answer, and nothing else takes its place
    /// while it waits. Everything else is over the moment it has been read.
    var isPersistent: Bool {
        if case .permission = self { return true }
        return false
    }
    /// Agent replies and requests share an event panel, independently of their different lifetimes.
    var isSessionEvent: Bool {
        switch self {
        case .completion, .permission: return true
        case .quota, .resetCredits: return false
        }
    }
    /// When the client started waiting. News has no such moment: it is over as soon as it has been read.
    var waitingSince: Date? {
        if case .permission(let request) = self { return request.at }
        return nil
    }

    /// How wide the expanded card is. A queue of requests reads across — a project, what kind of call, on what and
    /// how long it has waited — and one request is the same card with one row in it, so the width does not move
    /// under the user as requests arrive and are answered. Replies use that same event panel.
    @MainActor var detailWidth: CGFloat { isSessionEvent ? 470 : IslandController.alertDetailWidth }

    /// How far the expanded card starts below the island's own silhouette. News is one line under a headline and can
    /// afford the room.
    var detailTopInset: CGFloat { 16 }

    /// The frame a request card wears: the usage panel's own, because the two open in the same place, one after the
    /// other, and a queue of requests is a panel of rows like any other. Its top is a floor, not a measurement —
    /// the island's own silhouette wins when it is taller, since the card is narrower than the panel and sits under
    /// the notch rather than beside it. Quota news keeps the silhouette-relative inset above.
    var detailInsets: EdgeInsets? {
        isSessionEvent ? EdgeInsets(top: 32, leading: 18, bottom: 14, trailing: 18) : nil
    }

    /// A turn ending is news in blue; restored quota stays green and a warning stays warm.
    var accent: RGBA {
        if case .completion = self { return Self.turnAccent }
        return isWarning ? Self.warningAccent : Self.calmAccent
    }
    static let turnAccent = RGBA(hex: 0x82aaff)
    static let calmAccent = RGBA(hex: 0x6cd8ac)
    static let warningAccent = RGBA(hex: 0xe9a16d)
}

/// Keeps one alert on the island at a time; later alerts wait in arrival order. An alert expires `visibleDuration`
/// after it appears or the pointer last leaves the island, and never while the pointer is over it. A request waiting
/// to be approved never expires at all: it holds the island until it is answered or its client takes it back, and
/// completed turns that arrive meanwhile stay in the same event list; quota news is dropped.
@MainActor
final class IslandAlertQueue {
    struct Presentation {
        let alert: IslandAlert
        /// Whether this card belongs inside usage; session events always use their own panel.
        let inUsagePanel: Bool

        init(alert: IslandAlert, inUsagePanel: Bool) {
            self.alert = alert
            self.inUsagePanel = !alert.isSessionEvent && inUsagePanel
        }
    }

    static let visibleDuration: Duration = .seconds(4)

    private(set) var current: Presentation?
    /// Called when the current alert's time is up; the owner dismisses it.
    var onExpire: () -> Void = {}
    private var pending: [IslandAlert] = []
    private var held = false
    private var expiry: Task<Void, Never>?

    /// Shows `alert` now and returns true, or queues it behind the current alert and returns false.
    func show(_ alert: IslandAlert, inUsagePanel: Bool) -> Bool {
        guard current == nil else {
            // Replies remain available beside a waiting request; quota news cannot interrupt that request.
            if current?.alert.isPersistent == true && !alert.isSessionEvent { return false }
            pending.append(alert)
            return false
        }
        current = Presentation(alert: alert, inUsagePanel: inUsagePanel)
        scheduleExpiry()
        return true
    }

    /// The pointer over the island holds the current alert until it leaves.
    func hold(_ inside: Bool) {
        held = inside
        guard current != nil else { return }
        if inside { expiry?.cancel() } else { scheduleExpiry() }
    }

    /// Takes one alert off the island or out of the queue, wherever it is. The client withdrew its request, so the
    /// question is no longer being asked; nothing is answered on the user's behalf.
    /// Returns the alert that should be shown next when the removed one was the one on screen.
    func remove(id: String) -> (removed: Bool, next: IslandAlert?) {
        if current?.alert.id == id { return (true, dismiss()) }
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return (false, nil) }
        pending.remove(at: index)
        return (true, nil)
    }

    /// Whether the alert is on screen or waiting here.
    func contains(id: String) -> Bool {
        current?.alert.id == id || pending.contains { $0.id == id }
    }

    /// The requests held here, the one on screen first: questions stay until their clients have an answer.
    var questions: [IslandAlert] {
        ((current.map { [$0.alert] } ?? []) + pending).filter(\.isPersistent)
    }

    /// The event panel's current row and the other replies and requests waiting here.
    var sessionEvents: [IslandAlert] {
        ((current.map { [$0.alert] } ?? []) + pending).filter(\.isSessionEvent)
    }

    var pendingIDs: [String] { pending.map(\.id) }

    /// Brings a waiting alert to the front and puts the one on screen back in its place. Which request is being
    /// answered has to be the user's choice, so the card they picked becomes the card the island is showing.
    @discardableResult
    func promote(id: String) -> Bool {
        guard let showing = current, showing.alert.id != id,
              let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        let promoted = pending[index]
        pending[index] = showing.alert
        current = Presentation(alert: promoted, inUsagePanel: showing.inUsagePanel)
        scheduleExpiry()
        return true
    }

    /// Removes the current alert and hands back the next one waiting, if any.
    ///
    /// The one that has been waiting longest comes forward, whatever order the user shuffled the stack into — it is
    /// the one at the top of the pile they were just looking at. News carries no such moment and keeps arrival order.
    func dismiss() -> IslandAlert? {
        expiry?.cancel()
        current = nil
        guard !pending.isEmpty else { return nil }
        let next = pending.indices.min {
            (pending[$0].waitingSince ?? .distantFuture, $0) < (pending[$1].waitingSince ?? .distantFuture, $1)
        } ?? pending.startIndex
        return pending.remove(at: next)
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard !held, current?.alert.isPersistent != true else { return }
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: Self.visibleDuration) } catch { return }
            self?.onExpire()
        }
    }
}
