import Foundation
import ServiceManagement

/// Launch-at-login through `SMAppService`. Only meaningful when running from a real .app bundle.
enum LoginItem {
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Registers the item only if it was never registered, as on a new install whose setting starts on. One waiting for
    /// approval in System Settings, where the user switched it off, is left alone: registering it at every start would
    /// fight that choice and bring back the notice macOS shows for a new login item.
    static func registerIfNeverRegistered() {
        guard isAvailable, SMAppService.mainApp.status == .notRegistered else { return }
        do { try SMAppService.mainApp.register() }
        catch { NSLog("[AgentHUD] login item update failed: %@", error.localizedDescription) }
    }

    static func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("[AgentHUD] login item update failed: %@", error.localizedDescription)
        }
    }
}
