import Foundation

/// Latest quota reading for one agent.
public struct UsageSnapshot: Hashable, Codable, Sendable {
    public let agentId: String
    /// Remaining % of this quota window.
    public let remainingPct: Double
    /// Remaining % of the weekly (7d) window, when the source reports one.
    public let weeklyRemainingPct: Double?
    public let resetAt: Date?
    /// Full reset period reported by the source, in seconds.
    public let windowDuration: TimeInterval?
    public let weeklyResetAt: Date?
    public let amounts: QuotaAmounts?
    public let updatedAt: Date

    public init(
        agentId: String,
        remainingPct: Double,
        weeklyRemainingPct: Double? = nil,
        resetAt: Date? = nil,
        windowDuration: TimeInterval? = nil,
        weeklyResetAt: Date? = nil,
        amounts: QuotaAmounts? = nil,
        updatedAt: Date
    ) {
        self.agentId = agentId
        self.remainingPct = remainingPct
        self.weeklyRemainingPct = weeklyRemainingPct
        self.resetAt = resetAt
        self.windowDuration = windowDuration
        self.weeklyResetAt = weeklyResetAt
        self.amounts = amounts
        self.updatedAt = updatedAt
    }

    public var cycle: QuotaCycle? { QuotaCycle(resetAt: resetAt, duration: windowDuration) }
}

/// Exact units reported by a quota service, separate from token counts and percentages.
public struct QuotaAmounts: Hashable, Codable, Sendable {
    public let used: Double
    public let limit: Double
    public let unit: String
    public init(used: Double, limit: Double, unit: String) {
        self.used = used; self.limit = limit; self.unit = unit
    }
    public var remaining: Double { max(0, limit - used) }
    public var summary: String {
        func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        return L10n.text("已用 \(number(used)) / \(number(limit)) · 剩余 \(number(remaining)) \(unit)",
                         "Used \(number(used)) / \(number(limit)) · \(number(remaining)) \(unit) left")
    }
}
