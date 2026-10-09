import AppKit
import AgentHUDCore

/// Keeps a second Agent HUD from starting while one runs.
@MainActor
public enum SingleInstance {
    /// Kept for the life of the process; the system lets go of the lock when it ends.
    private static var lock: InstanceLock?

    /// Claims the lock every Agent HUD shares (`InstanceLock`). When another copy holds it, an alert says where that
    /// copy runs and this returns false: the caller quits before it reads or writes anything the running copy uses. A
    /// lock that cannot be taken at all lets this copy run. The alert is in the system's language, since the stored
    /// preferences are not read before the claim.
    public static func claim(at url: URL = InstanceLock.sharedURL) -> Bool {
        switch InstanceLock.claim(at: url) {
        case .acquired(let lock):
            self.lock = lock
            return true
        case .unavailable:
            return true
        case .held(let holder):
            let alert = NSAlert()
            alert.messageText = L10n.text("Agent HUD 已在运行", "Agent HUD is already running")
            if let holder {
                let place = (holder.path as NSString).abbreviatingWithTildeInPath
                alert.informativeText = L10n.text("正在运行的是 \(place)。请先退出它，再打开这一个。",
                                                  "\(place) is running. Quit it first, then open this one.")
            } else {
                alert.informativeText = L10n.text("请先退出正在运行的 Agent HUD，再打开这一个。",
                                                  "Quit the Agent HUD that is running first, then open this one.")
            }
            alert.addButton(withTitle: L10n.text("好", "OK"))
            NSApp.activate()
            alert.runModal()
            return false
        }
    }
}
