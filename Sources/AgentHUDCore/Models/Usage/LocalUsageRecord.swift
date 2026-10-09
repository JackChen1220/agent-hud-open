import Foundation

/// A completed local turn's reported billing units, independent of token counts and account quota.
public struct LocalUsageRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let model: String
    /// Nil means the CLI did not report credits; it is not zero usage.
    public let credits: Double?
    public let hasTokenCounts: Bool

    public init(id: String, timestamp: Date, model: String, credits: Double?, hasTokenCounts: Bool) {
        self.id = id; self.timestamp = timestamp; self.model = model
        self.credits = credits; self.hasTokenCounts = hasTokenCounts
    }

    /// Half-open periods keep a boundary turn in just one bucket. Stable turn ids prevent duplicate imports.
    public static func records(in sessions: [LiveSession], during interval: DateInterval) -> [Self] {
        var seen = Set<String>()
        return sessions.flatMap { $0.localUsage ?? [] }.filter {
            $0.timestamp >= interval.start && $0.timestamp < interval.end && seen.insert($0.id).inserted
        }.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }
    }
}
