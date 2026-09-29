import Foundation

/// Fixed application policy. No threshold values are stored or synchronized.
public enum AlertPolicy {
    public static let warningUsed: Double = 70
    public static let criticalUsed: Double = 90
    /// Remaining % at or below which a window is exhausted.
    public static let exhaustedRemaining: Double = 0
    /// Remaining % at or below which a stored reading counts as the window being at its cap.
    public static let capRemaining: Double = 0.5
    /// Old observations remain visible but must not generate new quota alerts.
    public static let maximumReadingAge: TimeInterval = 30 * 60
    /// Readings wobble by a point or two between queries; only a larger rise is a reset.
    public static let resetRise: Double = 5
    /// How far back a window's insights read its stored readings.
    public static let insightsLookback: TimeInterval = 7 * 86400
    /// The balance at or below which an account warns, by currency. A balance in any other currency warns only when
    /// it runs out.
    public static let balanceWarnings: [String: Decimal] = ["CNY": 10, "USD": 2]

    public static func quotaLevel(remaining: Double) -> StatusLevel {
        StatusLevel.resolve(remainingPct: remaining, warnPct: 100 - warningUsed, critPct: 100 - criticalUsed)
    }

    public static func balanceLevel(remaining: Decimal, currency: String) -> StatusLevel? {
        guard !remaining.isNaN else { return nil }
        guard let warning = balanceWarnings[currency] else { return remaining <= 0 ? .critical : nil }
        return remaining <= 0 ? .critical : remaining <= warning ? .warning : .ok
    }

    /// An API account's level: critical while its service marks it unavailable, even with no balance to show, else
    /// the lowest of its balances' levels.
    public static func balanceLevel(_ balances: [AccountBalance], isAvailable: Bool?) -> StatusLevel? {
        if isAvailable == false { return .critical }
        let levels = balances.compactMap { balanceLevel(remaining: $0.total, currency: $0.currency) }
        return levels.contains(.critical) ? .critical : levels.contains(.warning) ? .warning : levels.first
    }
}

public extension APIBilling {
    func contains(_ model: AgentDescriptor) -> Bool {
        guard model.isAPIBilled else { return false }
        if let billingPool { return model.billingPool?.id == billingPool.id }
        return model.billingPool == nil && model.vendor == vendor
    }
}
