import Foundation

/// Agent HUD's handler for one hook of one client: the settings file it lives in, and the arguments that follow the
/// executable in its command. Reading that file, telling Agent HUD's handlers from the client's own and writing the
/// result back are the same for every hook; only the edit is the hook's own.
struct HookInstaller {
    /// The largest client settings file read or rewritten.
    static let configurationLimit = 16 * 1024 * 1024

    /// The client's settings file.
    let configuration: URL
    /// What follows the executable in the handler's command, such as `--completion-hook cursor`.
    let arguments: String

    /// The settings, empty when the file is missing or empty. A file over `configurationLimit`, or one whose content is
    /// not a JSON object, throws.
    func read() throws -> [String: ProviderJSON] {
        guard FileManager.default.fileExists(atPath: configuration.path) else { return [:] }
        let data = try Data(contentsOf: configuration)
        guard data.count <= Self.configurationLimit else { throw ProviderFailure.limit }
        guard !data.isEmpty else { return [:] }
        guard let object = try ProviderJSON.read(data).objectValue else { throw ProviderFailure.format }
        return object
    }

    /// Points every Agent HUD handler of the hook at `executable`, whichever copy wrote it (`HookCommand`), or with
    /// `enabled` false takes them all out. `updating` gives the settings with the handlers set to a command, or taken out
    /// for nil, leaves every other entry alone and throws for a layout it does not recognize. A file that already says
    /// the same is not rewritten, and taking the handlers out never leaves behind a file the client did not have.
    /// `willWrite` runs just before a changed file is written.
    func configure(enabled: Bool, executable: URL,
                   updating: ([String: ProviderJSON], String?) throws -> [String: ProviderJSON],
                   willWrite: () -> Void = {}) throws {
        guard enabled || FileManager.default.fileExists(atPath: configuration.path) else { return }
        if enabled { try HookCommand.checkInstall(executable: executable) }
        let object = try read()
        let updated = try updating(object, enabled ? HookCommand.make(executable: executable, arguments: arguments) : nil)
        guard updated != object else { return }
        willWrite()
        try HookSettings.write(updated, to: configuration)
    }
}
