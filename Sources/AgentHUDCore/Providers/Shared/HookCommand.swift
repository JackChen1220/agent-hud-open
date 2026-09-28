import Foundation

/// The command a client runs to reach Agent HUD, and the installation behind it.
///
/// Every handler Agent HUD writes is its executable's path in single quotes followed by the hook's switch, so the path
/// can be read back. That is what tells a handler nothing answers any more from one another installation still
/// answers: an app first opened from its disk image, or from Downloads, runs from a place macOS takes away again, and a
/// deleted app leaves a path to nothing. Adding and removing a handler both clear the ones nothing answers and leave
/// another installation's with it.
enum HookCommand {
    /// `'<executable path>' <arguments>`, quoted for the shell the client runs it through.
    static func make(executable: URL, arguments: String) -> String {
        "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + arguments
    }

    /// The executable a command written by `make` runs; nil for a command written any other way.
    static func executable(of command: String) -> String? {
        guard command.first == "'" else { return nil }
        var path = "", rest = command.dropFirst()
        while let quote = rest.firstIndex(of: "'") {
            path += rest[..<quote]
            rest = rest[rest.index(after: quote)...]
            // A quote inside the path is written as `'\''`: close, an escaped quote, open again.
            guard rest.hasPrefix("\\''") else { return path }
            path += "'"
            rest = rest.dropFirst(3)
        }
        return nil
    }

    /// A place an app runs from only until it is moved: the randomized copy App Translocation makes of an app opened
    /// where it was downloaded, or a mounted volume such as the disk image it came on. A handler pointing there stops
    /// working once the app is moved or the image is ejected.
    static func isTransient(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// Whether nothing will answer the handler again: its executable is gone, or only ever ran from a transient place.
    /// A command written some other way is never taken for abandoned.
    static func isAbandoned(_ command: String) -> Bool {
        guard let path = executable(of: command) else { return false }
        return isTransient(path) || !FileManager.default.fileExists(atPath: path)
    }

    /// The Agent HUD handlers in `existing` that another installation still answers: not `command`, and not abandoned.
    /// They stay with that installation whether this one adds its handler or takes it out.
    static func otherInstallations(_ existing: [String], besides command: String) -> Set<String> {
        Set(existing.filter { $0 != command && !isAbandoned($0) })
    }

    /// Throws unless this installation may add its handler: an app running from a transient place writes nothing,
    /// since its handler would stop working once it is moved, and a handler another installation still answers
    /// (`others`) is left to it, which `conflict` says. A handler whose installation is gone is simply replaced.
    static func checkInstall(executable: URL, others: Set<String>, conflict: String) throws {
        if isTransient(executable.path) {
            throw UsageProviderError(L10n.text("应用正从磁盘映像或临时位置运行，移到应用程序文件夹后才会写入回调",
                                               "The app is running from a disk image or a temporary copy; move it to Applications to add hooks"))
        }
        if !others.isEmpty { throw UsageProviderError(conflict) }
    }
}
