import Observation
import AgentHUDCore

enum HubTab: CaseIterable {
    case agents, branches
    var title: String { self == .agents ? "Agent" : L10n.text("分支", "Branches") }
    var symbol: String { self == .agents ? "sparkles" : "arrow.triangle.branch" }
}

/// Lives with the HUD coordinator, so collapsing does not reset the user's tab.
@MainActor @Observable
final class HubNavigation {
    @ObservationIgnored var onChange: (() -> Void)?
    var tab = HubTab.agents {
        didSet { if tab != oldValue { onChange?() } }
    }
}
