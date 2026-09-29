import Foundation

/// Quota calculations shared by the providers, the store, the alerts and the desktop, as pure functions of readings
/// and time.
public enum QuotaMath {
    /// Where a window's insights start reading its stored readings: a week back, or the start of its current cycle
    /// when that is earlier, so the burn rate of a longer window sees its whole cycle.
    public static func historyStart(for snapshot: UsageSnapshot, now: Date) -> Date {
        let lookback = now.addingTimeInterval(-AlertPolicy.insightsLookback)
        return min(lookback, snapshot.cycle?.start ?? lookback)
    }

    /// A window's burn rate, how long its rest lasts at that rate, and the times it hit its cap, from its stored
    /// readings. The burn rate takes the readings of the current cycle; cap hits are counted over the readings since
    /// `capsSince`. Without a reading there is no burn rate, only cap hits.
    public static func insights(snapshot: UsageSnapshot?, samples: [QuotaSample], capsSince: Date, now: Date) -> UsageInsights {
        let burn = UsageAnalytics.burnRate(samples: samples, cycle: snapshot?.cycle, now: now)
        let caps = UsageAnalytics.capStats(samples: samples.filter { $0.timestamp >= capsSince }, now: now)
        return UsageInsights(burnRatePctPerHour: burn?.pctPerHour,
                             timeToExhaust: snapshot.flatMap { burn?.timeToExhaust(remainingPct: $0.remainingPct) },
                             weeklyCapHits: caps.hits, weeklyWaitTotal: caps.totalWait,
                             weeklyWaitLongest: caps.longestWait, weeklyWaitLongestAt: caps.longestAt)
    }
}
