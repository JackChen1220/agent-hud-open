import AgentHUDSupport
import Foundation

/// The hook a client runs when it is about to ask its user whether a tool may run.
///
/// The notification hook only says a session needs its user; this one is answered. The client waits on the hook's own
/// output and acts on what it says, so a request can be approved from the HUD instead of the terminal. Saying nothing
/// is always available and always safe: the client then behaves exactly as it would with no hook installed.
public enum PermissionHooks {
    /// Clients with the PermissionRequest hook contract: it runs only when the client is about to ask, and the client
    /// reads Claude Code's allow/deny answer. Codex CLI and Desktop share one hooks file, WorkBuddy runs CodeBuddy
    /// Code's engine, ZCode's desktop app and terminal share one engine and one configuration file, and Qwen Code
    /// reads the answer unchanged; only Claude Code and the Qoder builds apply a permission-rule update sent back.
    public enum Source: String, CaseIterable, Sendable {
        case claude
        case codex
        case qoder
        case qoderCN
        case qoderWork
        case codebuddy
        case workbuddy
        case zcode
        case qwen

        public var vendor: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .qoder: return "Qoder"
            case .qoderCN: return "Qoder CN"
            case .qoderWork: return "QoderWork"
            case .codebuddy: return "CodeBuddy"
            case .workbuddy: return "WorkBuddy"
            case .zcode: return "ZCode"
            case .qwen: return "Qwen"
            }
        }

        var event: String { "PermissionRequest" }
        /// The id this client's sessions carry in reports, so a request stands beside its session everywhere. The providers
        /// that read CodeBuddy, WorkBuddy, ZCode and Qwen Code prefix their ids with the client; Claude Code and Codex keep
        /// the client's own, and the Qoder builds report no sessions.
        func sessionID(_ raw: String) -> String {
            switch self {
            case .codebuddy, .workbuddy, .zcode, .qwen: return "\(rawValue):\(raw)"
            case .claude, .codex, .qoder, .qoderCN, .qoderWork: return raw
            }
        }
        /// A rule is echoed back only where the client both offers one and applies it. CodeBuddy Code offers
        /// suggestions but never applies one sent back, ZCode applies a rule but never offers one, and Codex and
        /// Qwen Code do neither.
        var supportsPermissionUpdates: Bool {
            switch self {
            case .claude, .qoder, .qoderCN, .qoderWork: return true
            case .codex, .codebuddy, .workbuddy, .zcode, .qwen: return false
            }
        }
        /// Matched against the tool name; empty is every tool. ZCode rejects an empty matcher and runs a group without
        /// one for every tool.
        var matcher: String? { self == .zcode ? nil : "" }
        /// Claude Code's layout keeps the event lists at `hooks.<Event>`; ZCode nests them at `hooks.events.<Event>`.
        var nestsEvents: Bool { self == .zcode }
        /// Calls that ask the user something other than permission. ZCode routes its question and its plan approval
        /// through this event, and an answer without the user's reply fails the question or approves an unread plan;
        /// Qwen Code ignores an allow for both. Claude Code takes a question's answers back through this event and
        /// shows its own plan dialog while the hook waits; its forks are not known to do either. The HUD leaves these to
        /// the client's own dialog.
        var unanswerableTools: Set<String> {
            switch self {
            case .zcode: return ["AskUserQuestion", "ExitPlanMode"]
            case .qwen: return ["ask_user_question", "exit_plan_mode"]
            case .qoder, .qoderCN, .qoderWork, .codebuddy, .workbuddy: return ["AskUserQuestion", "ExitPlanMode"]
            case .claude, .codex: return []
            }
        }
        /// Whether the client writes Claude Code's session record, where a call answered in the client's own dialog
        /// shows as that call's result.
        var recordsCalls: Bool { self == .claude }
        /// How long the client waits for an answer: only the ceiling behind the HUD's own wait
        /// (`PermissionRequests.holdTime`), for a HUD that stopped answering. A client that cancels the hook first
        /// closes the connection, which takes the request off the HUD.
        /// Qwen Code reads a value of 1000 or more as milliseconds on every version, so its day is written that way.
        var timeout: Int { self == .qwen ? 86_400_000 : 86_400 }

        var directory: String {
            switch self {
            case .claude: return ".claude"
            case .codex: return ".codex"
            case .qoder: return ".qoder"
            case .qoderCN: return ".qoder-cn"
            case .qoderWork: return ".qoderwork"
            case .codebuddy: return ".codebuddy"
            case .workbuddy: return ".workbuddy"
            case .zcode: return ".zcode/cli"
            case .qwen: return ".qwen"
            }
        }

        func home(_ base: URL) -> URL {
            if case .codex = self { return CodexLocator.dataDirectory(home: base) }
            if case .codebuddy = self { return CodeBuddySessions.home(base) }
            if case .qwen = self { return QwenSessions.home(base) }
            // Claude Code's configuration directory moves with CLAUDE_CONFIG_DIR; the forks have no such variable.
            if case .claude = self { return ClaudeSubscription.directory(home: base) }
            return base.appendingPathComponent(directory, isDirectory: true)
        }

        func configuration(home base: URL) -> URL {
            let name: String
            switch self {
            case .codex: name = "hooks.json"
            case .zcode: name = "config.json"
            default: name = "settings.json"
            }
            return home(base).appendingPathComponent(name)
        }

        /// Whether the client is here at all. A machine without it keeps its home untouched.
        public func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                fileManager: FileManager = .default) -> Bool {
            switch self {
            case .claude:
                return ClaudeEngineLocator.find(home: home, fileManager: fileManager) != nil
                    || fileManager.fileExists(atPath: self.home(home).appendingPathComponent("projects").path)
            case .codex, .qoder, .qoderCN, .qoderWork, .zcode, .qwen:
                return fileManager.fileExists(atPath: self.home(home).path)
            // The session folder is what the usage provider reads; a settings folder alone can be the IDE extension's.
            case .codebuddy, .workbuddy:
                return fileManager.fileExists(atPath: self.home(home).appendingPathComponent("projects").path)
            }
        }
    }

    // MARK: Installation

    /// What follows the executable in Agent HUD's handler of the permission hook.
    static func arguments(_ source: Source) -> String { "--permission-hook " + source.rawValue }

    static func installer(_ source: Source, home: URL) -> HookInstaller {
        HookInstaller(configuration: source.configuration(home: home), arguments: arguments(source))
    }

    static func configuration(_ source: Source, home: URL) throws -> [String: ProviderJSON] {
        try installer(source, home: home).read()
    }

    static func ownsCommand(_ command: String?, source: Source) -> Bool { HookCommand.runs(command, arguments: arguments(source)) }

    public static func isActive(_ source: Source, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let object = try? configuration(source, home: home) else { return false }
        return !commands(in: object, source: source).isEmpty
    }

    static func commands(in configuration: [String: ProviderJSON], source: Source) -> [String] {
        let hooks = ProviderJSON.object(configuration)["hooks"]
        let events = source.nestsEvents ? hooks["events"] : hooks
        return (events[source.event].arrayValue ?? []).flatMap { $0["hooks"].arrayValue ?? [] }
            .compactMap { $0["command"].stringValue }.filter { ownsCommand($0, source: source) }
    }

    /// Points every Agent HUD handler of the permission hook at `executable`, whichever copy wrote it
    /// (`HookCommand`), or with `enabled` false takes them all out, leaving every other hook in the file alone. An
    /// unrecognized layout throws rather than being rewritten.
    public static func configure(_ source: Source, enabled: Bool, executable: URL,
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try installer(source, home: home).configure(enabled: enabled, executable: executable) {
            try updating($0, source: source, command: $1)
        }
    }

    /// The configuration with Agent HUD's handlers taken out, or with `command` when it is given: in the first handler
    /// already there, or in a group of its own.
    static func updating(_ configuration: [String: ProviderJSON], source: Source, command: String?) throws -> [String: ProviderJSON] {
        var object = configuration
        guard object["hooks"] == nil || object["hooks"]?.objectValue != nil else { throw ProviderFailure.format }
        var hooks = object["hooks"]?.objectValue ?? [:]
        if source.nestsEvents {
            // ZCode drops its whole configuration over a malformed hooks section, so only its known shapes are edited.
            guard hooks["events"] == nil || hooks["events"]?.objectValue != nil,
                  hooks["enabled"] == nil || hooks["enabled"]?.boolValue != nil else { throw ProviderFailure.format }
        }
        var events = source.nestsEvents ? hooks["events"]?.objectValue ?? [:] : hooks
        guard events[source.event] == nil || events[source.event]?.arrayValue != nil else { throw ProviderFailure.format }
        // A handler already there takes the new command and keeps the matcher, timeout and anything else the user set.
        let groups = ClaudeStyleHooks.setting(command, in: events[source.event]?.arrayValue ?? [],
                                              owns: { ownsCommand($0, source: source) }) { command in
            var group: [String: ProviderJSON] = ["hooks": .array([.object(["type": .string("command"), "command": .string(command),
                                                                           "timeout": .integer(Int64(source.timeout))])])]
            if let matcher = source.matcher { group["matcher"] = .string(matcher) }
            return .object(group)
        }
        events[source.event] = groups.isEmpty ? nil : .array(groups)
        if source.nestsEvents {
            hooks["events"] = events.isEmpty ? nil : .object(events)
            // ZCode runs no hook at all until this is set. A user who switched hooks off keeps them off.
            if command != nil, hooks["enabled"] == nil { hooks["enabled"] = .bool(true) }
        } else {
            hooks = events
        }
        object["hooks"] = hooks.isEmpty && configuration["hooks"] == nil ? nil : .object(hooks)
        return object
    }
}
