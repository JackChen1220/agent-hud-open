import Foundation

public enum DeepSeekLocator {
    public static var dataDirectory: URL { dataDirectory(environment: ProcessInfo.processInfo.environment) }

    public static func dataDirectory(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard let path = environment["DSH_HOME"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return home.appendingPathComponent(".dsh", isDirectory: true)
        }
        let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    public static func isInstalled(directory: URL = dataDirectory) -> Bool {
        ["profiles", "sessions"].contains { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Harness itself requires Node with Zstandard support. GUI launches may have a minimal PATH.
    public static func nodeExecutable(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        let candidates = path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("node") }
            + ["/opt/homebrew/bin/node", "/usr/local/bin/node"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
