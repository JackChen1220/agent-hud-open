import Foundation

/// Formats durations the way the design shows them.
public enum Countdown {
    /// "2h 14m", "4h 02m", "51m". Never negative.
    public static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    /// Menu-bar variant without the space: "2h14m", "51m".
    public static func compact(_ interval: TimeInterval) -> String {
        format(interval).replacingOccurrences(of: " ", with: "")
    }

    /// Time remaining until `date`, or "—" when unknown.
    public static func until(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        return format(date.timeIntervalSince(now))
    }

    /// Reset label: a countdown inside 24 hours ("3h 10m"), otherwise the weekday and time ("周日 02:00").
    public static func resetLabel(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(now)
        if interval < 24 * 3600 { return format(interval) }
        return ChartData.weekdayTime(date, calendar: calendar)
    }

    /// Menu variant: "3h10m" or "周日 02:00".
    public static func resetLabelCompact(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(now)
        if interval < 24 * 3600 { return compact(interval) }
        return ChartData.weekdayTime(date, calendar: calendar)
    }

    /// Like `format` but drops a zero minute part: "2h" instead of "2h 00m".
    public static func formatRough(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        if total >= 3600, (total % 3600) / 60 == 0 { return "\(total / 3600)h" }
        return format(interval)
    }

    /// Session labels: "27m 进行中" / "27m running" in flight, counted from when the phase started; "结束于 51m 前" /
    /// "ended 51m ago" otherwise, counted from the session's last event.
    public static func sessionLabel(_ phase: SessionPhase, now: Date) -> String {
        if phase.isInFlight {
            let duration = format(now.timeIntervalSince(phase.since))
            return L10n.text("\(duration) 进行中", "\(duration) running")
        }
        let ago = formatRough(now.timeIntervalSince(phase.since))
        return L10n.text("结束于 \(ago) 前", "ended \(ago) ago")
    }

    /// The label of a session counted from its own start while its source has it in flight, else from its end.
    public static func sessionLabel(_ session: LiveSession, now: Date) -> String {
        sessionLabel(SessionPhase(state: session.isLive ? .running : .idle, since: session.isLive ? session.startedAt : session.endedAt ?? now,
                                  validUntil: nil), now: now)
    }
}
