import Foundation
@testable import AgentHUDCore

/// Entirely synthetic desktop persistence; no installed client's messages or account identifiers enter fixtures.
struct GrokBotCacheFixture {
    let directory: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let account = "fixture.account|one"
    let agent = "fixture-agent"

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GrokBotCache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeAccount(account)
    }

    var roster: URL { GrokBotCache.url(for: GrokBotCache.rosterKey(account: account), in: directory) }
    var transcript: URL { GrokBotCache.url(for: GrokBotCache.transcriptKey(account: account, agent: agent), in: directory) }
    var sessionID: String { GrokBotCache.sessionID(account: account, agent: agent) }

    @discardableResult func write(_ value: Any, key: String, schema: Int) throws -> URL {
        let url = GrokBotCache.url(for: key, in: directory)
        var data = Data()
        if url.pathExtension == "kblob" {
            data = try JSONSerialization.data(withJSONObject: key, options: .fragmentsAllowed)
            data.append(10)
        }
        data.append(try JSONSerialization.data(withJSONObject: ["schemaVersion": schema, "value": value], options: .sortedKeys))
        try data.write(to: url)
        return url
    }

    func writeAccount(_ value: String?) throws {
        try write(value.map { $0 as Any } ?? NSNull(), key: GrokBotCache.accountKey, schema: 1)
    }

    func writeRoster(account: String? = nil, rows: [[String: Any]]? = nil) throws -> URL {
        try write(["rows": rows ?? [["id": agent, "title": "Synthetic conversation", "createdAt": milliseconds(-60),
            "updatedAt": milliseconds(-5), "lastActivityAt": milliseconds(-10), "lastEntry": ["content": "Excluded roster preview"],
            "isRunningTurn": true, "currentActivity": "Excluded live field"]]],
            key: GrokBotCache.rosterKey(account: account ?? self.account), schema: 4)
    }

    @discardableResult func writeTranscript(_ entries: [[String: Any]], account: String? = nil, agent: String? = nil,
                                          persistedAt: Date? = nil, schema: Int = 1) throws -> URL {
        try write(["entries": entries, "persistedAt": (persistedAt ?? now).timeIntervalSince1970 * 1000,
            "acceptedSequenceHint": 9000, "epochHint": "fixture-epoch"],
            key: GrokBotCache.transcriptKey(account: account ?? self.account, agent: agent ?? self.agent), schema: schema)
    }

    func prompt(_ id: String, sequence: Int?, text: String = "Synthetic prompt", request: String? = "fixture-request", at: TimeInterval = -30) -> [String: Any] {
        var row: [String: Any] = ["kind": "message", "id": id, "role": "user", "content": text, "timestampMs": milliseconds(at)]
        row["seq"] = sequence; row["requestId"] = request
        return row
    }

    func reply(_ id: String, sequence: Int?, text: String = "Synthetic reply", request: String? = "fixture-request", at: TimeInterval = -20) -> [String: Any] {
        var row: [String: Any] = ["kind": "send-message", "id": id, "message": ["type": "text", "content": text], "timestampMs": milliseconds(at)]
        row["seq"] = sequence; row["requestId"] = request
        return row
    }

    func milliseconds(_ offset: TimeInterval) -> Double { now.addingTimeInterval(offset).timeIntervalSince1970 * 1000 }
}
