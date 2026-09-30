import Foundation

/// Hover copy for a time-limited quota, using that window's existing burn-rate estimate.
public enum QuotaForecast {
    /// `AlertPolicy.maximumReadingAge`.
    public static var maximumReadingAge: TimeInterval { AlertPolicy.maximumReadingAge }

    /// The text of the window's outlook. A window that runs out only after its reset says what it will have used by
    /// then, as its island row does.
    public static func hint(snapshot: UsageSnapshot, insights: UsageInsights?, now: Date) -> String? {
        switch QuotaMath.outlook(snapshot: snapshot, insights: insights, now: now) {
        case .untimed: return nil
        case .exhausted: return L10n.text("已耗尽", "Exhausted")
        case .noEstimate: return L10n.text("暂无预测", "No estimate")
        case .noUsage: return L10n.text("暂无消耗", "No usage")
        case .insufficientData: return L10n.text("记录不足", "Insufficient data")
        case .exhausts(let interval, let beforeReset):
            guard beforeReset else {
                let used = max(0, min(100, 100 - snapshot.remainingPct))
                return QuotaMath.projectedUsedAtReset(usedPct: used, insights: insights, resetAt: snapshot.resetAt, now: now).map(byReset)
                    ?? L10n.text("记录不足", "Insufficient data")
            }
            // Keep the duration tied to the provider's latest estimate; don't simulate unobserved consumption.
            let exhaustion = duration(interval)
            return L10n.text("耗尽 ~\(exhaustion)", "Exhausts ~\(exhaustion)")
        }
    }

    /// The share of the window used by its reset, in words.
    public static func byReset(_ projectedUsedPct: Double) -> String {
        L10n.text("重置时 \(Int(projectedUsedPct.rounded()))%", "\(Int(projectedUsedPct.rounded()))% by reset")
    }

    private static func duration(_ interval: TimeInterval) -> String {
        // A pace a hair above zero can put the end further off than a whole number of minutes holds.
        let minutes = Int(min(ceil(interval / 60), Double(Int32.max)))
        let hours = minutes / 60
        if hours > 0 {
            if minutes % 60 == 0 { return L10n.text("\(hours)小时", "\(hours)h") }
            return L10n.text("\(hours)小时\(minutes % 60)分", "\(hours)h \(minutes % 60)m")
        }
        return L10n.text("\(minutes)分", "\(minutes)m")
    }
}
