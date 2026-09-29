import Foundation

actor AdditionalLocalStore {
    let source: AdditionalSource
    let roots: [URL]
    private var files: WholeFileStore<ProviderSessions>

    init(source: AdditionalSource, roots: [URL]? = nil) {
        self.source = source
        let layout = source.layout
        let roots = roots ?? layout?.roots(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment) ?? []
        self.roots = roots
        files = WholeFileStore(listings: layout.map { layout in
            [.init(name: source.vendor, files: LogFiles(roots: roots, watchesChanges: false, limit: 20000, skips: { layout.skips($0) }, accepts: { layout.accepts($0) }),
                   related: { layout.related($0) }, parse: { url, _ in try layout.read(url) })]
        } ?? [])
    }

    func fileChanges(_ paths: Set<String>?) { files.noteChanges(paths) }

    func index(since: Date) -> ProviderSessions {
        let pass = files.index(since: since)
        var failed = !pass.notices.isEmpty
        var sessions = pass.files.flatMap(\.parsed.sessions)
        let mergeNotice = source.layout?.notice(merging: sessions)
        if let layout = source.layout { sessions = layout.merge(sessions) }
        // Identically named Antigravity SQLite copies in the recognized roots represent the same conversation.
        var byID: [String: ProviderSession] = [:]
        for item in sessions {
            if var previous = byID[item.id] {
                var events = Dictionary(previous.events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                for event in item.events {
                    if let old = events[event.id], old != event { failed = true }
                    else { events[event.id] = event }
                }
                previous.events = events.values.sorted { $0.timestamp < $1.timestamp }; byID[item.id] = previous
            } else { byID[item.id] = item }
        }
        let notices = ([failed ? ProviderFailure.local.message : nil, mergeNotice] + pass.files.map(\.parsed.notice)).compactMap { $0 }
        return ProviderSessions(sessions: byID.keys.sorted().compactMap { byID[$0] }, notice: notices.isEmpty ? nil : Array(Set(notices)).sorted().joined(separator: " · "),
            indexing: pass.indexing, revision: pass.revision, files: pass.listedFiles { $0.sessions.map(\.id) })
    }
}

enum ProviderFiles {
    static func json(_ url: URL) throws -> ProviderJSON {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw ProviderFailure.limit }
        return try ProviderJSON.read(Data(contentsOf: url))
    }
    /// Decodes a JSON Lines file line by line, numbering lines from 1. Given `markers`, a line holding none of them is
    /// numbered but not decoded, so a reader passes them only when every line it uses holds one.
    static func lines(_ url: URL, markers: [Data] = [], consume: (ProviderJSON, Int) throws -> Void) throws {
        func wanted(_ line: Data) -> Bool { markers.isEmpty || markers.contains { line.range(of: $0) != nil } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var carry = Data(), read = 0, ordinal = 0
        let deadline = Date().addingTimeInterval(3)
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            read += chunk.count
            guard read <= 128 * 1024 * 1024, Date() <= deadline else { throw ProviderFailure.limit }
            carry.append(chunk)
            // Lines are cut from a moving start, and what they took is dropped once per chunk.
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 10) {
                let line = carry[start..<newline]
                ordinal += 1
                if !line.isEmpty, wanted(line) { try consume(ProviderJSON.read(Data(line)), ordinal) }
                start = newline + 1
            }
            carry.removeSubrange(carry.startIndex..<start)
            guard carry.count <= 16 * 1024 * 1024 else { throw ProviderFailure.limit }
        }
        // Accept a complete last JSON value without a newline; retry a torn tail on the next changed-file scan.
        if !carry.isEmpty, wanted(carry), let value = try? ProviderJSON.read(carry) { try consume(value, ordinal + 1) }
    }
}
