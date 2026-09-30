import Foundation

/// Finds the Claude Code engine binary. GUI apps get a minimal PATH, so well-known install locations are checked
/// directly; the desktop app's Code tab installs the same engine under `~/.local/share/claude/versions`.
public enum ClaudeEngineLocator {
    public static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var list = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        let versions = home.appendingPathComponent(".local/share/claude/versions", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path) {
            let sorted = names.filter { !$0.hasPrefix(".") }.sorted { lhs, rhs in
                lhs.compare(rhs, options: .numeric) == .orderedDescending
            }
            list += sorted.map { versions.appendingPathComponent($0) }
        }
        return list
    }

    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) -> URL? {
        candidates(home: home).first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
