import Foundation

/// Files parsed whole into sessions, for clients that keep databases or rewrite their logs. A poll lists every listing,
/// parses newest first each file whose modification time or size changed, or a related file's, while its time budget
/// lasts, and keeps each parse until the file changes or leaves the reading window. The client merges the parses into
/// sessions, which reach the ledger through `SessionLedger`.
struct WholeFileStore<Parsed: Sendable> {
    struct Listing {
        /// The notice key of the listing's problems.
        let name: String
        let files: LogFiles
        /// Files whose changes also invalidate a parse, such as a SQLite WAL.
        var related: (URL) -> [URL] = { _ in [] }
        /// The listing's files are parsed and merged before other listings' files, whatever their modification times.
        var leads = false
        /// Parses a file for a report reading from the given date.
        let parse: (URL, Date) throws -> Parsed
    }

    struct Pass {
        /// Parses of the files modified since the cutoff, in reading order.
        var files: [(path: String, parsed: Parsed)] = []
        /// Every file the listings found.
        var listed: Set<String> = []
        var indexing: IndexProgress?
        /// Listings that stopped at their limit, found unreadable entries or could not parse a file.
        var notices: [String: String] = [:]
        /// Changes whenever the parses change.
        var revision = 0

        func listedFiles(_ ids: (Parsed) -> [String]) -> ListedFiles {
            ListedFiles(paths: listed, sessions: Dictionary(uniqueKeysWithValues: files.map { ($0.path, ids($0.parsed)) }))
        }
    }

    static var timeBudget: TimeInterval { 1.5 }

    private let listings: [Listing]
    private var cache: [String: (signature: String, parsed: Parsed)] = [:]
    private var revision = 0

    init(listings: [Listing]) {
        self.listings = listings
    }

    /// Paths from the collector's watch, as `LogFiles.noteChanges` takes them: after the first listing, a poll looks
    /// only at them.
    func noteChanges(_ paths: Set<String>?) {
        for listing in listings { listing.files.noteChanges(paths) }
    }

    mutating func index(since: Date) -> Pass {
        let started = Date()
        var pass = Pass(), seen = Set<String>()
        var candidates: [(path: String, listing: Int, signature: String, modified: Date)] = []
        for (index, listing) in listings.enumerated() {
            let gaps = listing.files.refresh(now: started)
            if gaps.truncated { pass.notices[listing.name] = ProviderFailure.limit.message }
            else if gaps.unreadable > 0 { pass.notices[listing.name] = ProviderFailure.local.message }
            for (path, file) in listing.files.files {
                pass.listed.insert(path)
                var modified = file.modified, signature = "\(file.modified.timeIntervalSince1970):\(file.size)"
                for sibling in listing.related(URL(fileURLWithPath: path)) {
                    if let values = try? sibling.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]), let date = values.contentModificationDate {
                        modified = max(modified, date); signature += ":\(date.timeIntervalSince1970):\(values.fileSize ?? 0)"
                    }
                }
                guard modified >= since, seen.insert(path).inserted else { continue }
                candidates.append((path, index, signature, modified))
            }
        }
        candidates.sort { a, b in
            let (leadsA, leadsB) = (listings[a.listing].leads, listings[b.listing].leads)
            return leadsA != leadsB ? leadsA : a.modified > b.modified
        }
        var pending = 0, loaded = 0
        for candidate in candidates {
            if cache[candidate.path]?.signature == candidate.signature { continue }
            if loaded > 0 && Date().timeIntervalSince(started) >= Self.timeBudget { pending += 1; continue }
            loaded += 1
            let listing = listings[candidate.listing]
            do {
                try Task.checkCancellation()
                cache[candidate.path] = (candidate.signature, try listing.parse(URL(fileURLWithPath: candidate.path), since))
                revision += 1
            } catch { pass.notices[listing.name] = ProviderFailure.local.message }
        }
        if cache.keys.contains(where: { !seen.contains($0) }) {
            cache = cache.filter { seen.contains($0.key) }
            revision += 1
        }
        pass.files = candidates.compactMap { candidate in cache[candidate.path].map { (candidate.path, $0.parsed) } }
        pass.indexing = pending > 0 ? IndexProgress(done: candidates.count - pending, total: candidates.count) : nil
        pass.revision = revision
        return pass
    }
}

/// The files a whole-file reader listed, and the sessions of those it holds a parse of.
struct ListedFiles: Sendable {
    var paths: Set<String> = []
    var sessions: [String: [String]] = [:]
}

/// The ledger write of readers that parse whole files or account records: one contribution per session, replaced from
/// the start of the reading window once the index is complete and something changed. The sessions of a stored file
/// that is missing from the listing leave the ledger unless a listed file still holds them. After a rolled-back pass the
/// stored files are read again and every session is written again.
final class SessionLedger {
    let source: String
    private let ledger: UsageLedger
    /// The sessions each stored file held.
    private var stored: [String: [String]] = [:]
    private var loadedGeneration: Int?
    private var recorded: (revision: Int, account: String?, window: Date)?

    init(source: String, ledger: UsageLedger) {
        self.source = source
        self.ledger = ledger
    }

    /// - revision: changes whenever the sessions change; nil when the reader cannot tell, so every call writes.
    func record(files: ListedFiles?, revision: Int?, account: String? = nil, window: Date,
                sessions: () -> [(id: String, events: [UsageEvent])], isolation: isolated (any Actor)? = #isolation) async {
        let generation = await ledger.generation
        if loadedGeneration != generation {
            stored = ((try? await ledger.fileStates(source: source)) ?? [:]).compactMapValues(Self.sessions)
            recorded = nil
            loadedGeneration = generation
        }
        let unchanged = revision != nil && recorded.map { $0.revision == revision && $0.account == account && $0.window == window } == true
        let missing = files.map { files in stored.keys.filter { !files.paths.contains($0) } } ?? []
        if unchanged && missing.isEmpty { return }

        let current = sessions()
        let contributions = unchanged ? [:] : SessionContributions.canonical(current)
        var next = stored, changed: [String: [String]] = [:]
        if !unchanged {
            for (path, ids) in files?.sessions ?? [:] {
                let held = Array(Set(ids)).sorted()
                if held != stored[path] ?? [] { changed[path] = held; next[path] = held.isEmpty ? nil : held }
            }
        }
        for path in missing { next[path] = nil }
        let kept = Set(next.values.joined()).union(current.map(\.id))
        let leaving = Set(missing.flatMap { stored[$0] ?? [] }).subtracting(kept)
        let source = source, changedFiles = changed
        do {
            try await ledger.write { writer in
                for (session, events) in contributions {
                    try writer.replace(source: source, contribution: session, account: account, events: events, since: window)
                }
                for (path, held) in changedFiles {
                    if held.isEmpty { try writer.removeFile(source: source, path: path) }
                    else { try writer.setFile(source: source, path: path, state: Self.state(held)) }
                }
                for path in missing { try writer.removeFile(source: source, path: path) }
                for session in leaving { try writer.remove(source: source, contribution: session) }
            }
            stored = next
            if !unchanged { recorded = revision.map { ($0, account, window) } }
        } catch { /* The next poll writes the same sessions again. */ }
    }

    private struct StoredState: Codable {
        static let version = 1
        let version: Int
        let sessions: [String]
    }

    private static func state(_ sessions: [String]) -> UsageLedger.FileState {
        UsageLedger.FileState(signature: "", state: try? JSONEncoder().encode(StoredState(version: StoredState.version, sessions: sessions)))
    }

    private static func sessions(_ file: UsageLedger.FileState) -> [String]? {
        guard let data = file.state, let state = try? JSONDecoder().decode(StoredState.self, from: data),
              state.version == StoredState.version else { return nil }
        return state.sessions
    }
}
