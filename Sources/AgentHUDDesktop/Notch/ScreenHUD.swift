import AppKit
import AgentHUDCore
import SwiftUI

/// One screen's HUD: its glow window, its island window and its own hover state machine.
///
/// Everything here belongs to a single display, because two displays can be in different modes, be hovered
/// independently and show different things. What is shared — the store, the settings, the system appearance,
/// the pointer — is handed down by `IslandController`, which owns one of these per screen.
@MainActor
final class ScreenHUD {
    /// Height of the open panel; follows the content reported by `IslandRootView`.
    private var panelHeight: CGFloat = IslandController.defaultPanelHeight
    private var alertDetailHeight: CGFloat = 300
    /// The tallest the open card has been while the pointer has stayed on it; zero once it leaves.
    private var alertHoverFloor: CGFloat = 0

    /// The display this HUD lives on, looked up again each time: `NSScreen` instances are replaced when
    /// displays change, while the key outlives them.
    let key: String
    private let store: UsageStore
    private let settings: SettingsStore
    private let mouseLocation: @MainActor () -> CGPoint
    private let additionalHUDControls: @MainActor (@escaping @MainActor () -> Void) -> AnyView
    private(set) var geometry: NotchGeometry
    /// Set by the coordinator, which watches the system appearance once for every screen.
    var systemIsLight = SystemAppearance.isLight
    let glow: GlowWindowController
    let island: IslandWindowController
    private var machine = HoverMachine()
    /// Only the measurements and bitmaps survive the hover's preparation, not a hidden panel.
    private var openingPreparation: OpeningPreparation?
    private var timer: Timer?
    private var targetWindowFrame: CGRect?
    /// The card whose geometry is still interpolating; canvas-only changes share its completion.
    private var geometryTransitionFrame: CGRect?
    /// The island's own shape while an event is showing: wider than the silhouette by the two wings it grew.
    private var alertFrame: CGRect?
    private let alerts = IslandAlertQueue()
    private var activeAlert: IslandAlert? { alerts.current?.alert }
    private var showsAlertDetails: Bool { machine.isOpen && alerts.current?.inUsagePanel == false }
    private var pointerInside = false
    /// Whether the hover currently counts as one that opens the panel; see `reevaluateHover`.
    private var hoverOpens = false
    /// The user is typing into the island. It stays open under their hands, wherever the pointer goes, until they stop.
    private var typing = false
    private var modifierWatch: Timer?
    private let dragSurface = HUDDragWindowController()
    private var moveHintVisible = false
    /// A drag is previewed without writing preferences on every mouse movement; mouse-up commits once.
    private var previewPlacement: ScreenPlacement?
    /// The grip along the strip, kept when the queue turns onto another edge.
    private var dragGrabFraction: CGFloat = 0.5

    /// Inputs that can change the natural layout while a hover is waiting, including token data that
    /// need not change the coordinator's quota rows or glow appearance.
    private struct OpeningInputs: Equatable {
        let report: UsageReport?
        let settings: AgentHUDCore.Settings
        let agents: [AgentDescriptor]
        let hookTurns: [String: SessionPhase.HookTurn]
        let now: Date
        let dataDate: Date
        let error: String?
        let loading: Bool
        let range: StatsRange
        let bucketSize: TokenBucketSize
        let dimensions: TokenDimensions
        let requests: [PermissionRequest]
        let geometry: NotchGeometry
        let light: Bool
        let appearance: GlowAppearance
        let alertID: String?
        let alertDetails: Bool
    }

    private struct OpeningPreparation {
        let inputs: OpeningInputs
        let height: CGFloat
        let images: GlowWindowController.PreparedImages
    }

    private var openingInputs: OpeningInputs {
        OpeningInputs(report: store.report, settings: settings.settings, agents: settings.agents,
                      hookTurns: store.hookTurns, now: store.now, dataDate: store.dataDate,
                      error: store.lastError, loading: store.isLoading, range: store.statsRange,
                      bucketSize: store.tokenBucketSize, dimensions: store.tokenDimensions,
                      requests: PermissionRequests.shared.pending, geometry: geometry, light: systemIsLight,
                      appearance: store.glowAppearance(light: systemIsLight, on: key),
                      alertID: activeAlert?.id, alertDetails: alerts.current?.inUsagePanel == false)
    }

    var onOpenStats: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Asks for a request another screen holds: the waiting list names every request, wherever it arrived.
    var onClaimRequest: ((String) -> Void)?

    init(key: String, screen: NSScreen?, store: UsageStore, settings: SettingsStore,
         mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
         additionalHUDControls: @escaping @MainActor (@escaping @MainActor () -> Void) -> AnyView = { _ in AnyView(EmptyView()) }) {
        self.key = key
        self.store = store
        self.settings = settings
        self.mouseLocation = mouseLocation
        self.additionalHUDControls = additionalHUDControls
        // The stored placement decides notch or queue before the first frame, so the HUD never flashes
        // the wrong shape on launch.
        let placement = screen.map { ScreenIdentity.placement(for: $0, in: settings.settings) }
            ?? .default(hasNotch: false)
        let geometry = NotchGeometry.detect(screen: screen, placement: placement)
        self.geometry = geometry
        glow = GlowWindowController(geometry: geometry)
        island = IslandWindowController(frame: geometry.islandFrame, rootView: IslandRootView.placeholder)
        island.onPointerChange = { [weak self] _ in self?.samplePointer() }
        alerts.onExpire = { [weak self] in self?.dismissAlert() }
        dragSurface.onPress = { [weak self] in self?.grabHUD() }
        dragSurface.onRelease = { [weak self] in self?.releaseHUD() }
        dragSurface.onBegin = { [weak self] point in self?.beginMoving(at: point) }
        dragSurface.onDrag = { [weak self] point in self?.move(to: point) }
        dragSurface.onEnd = { [weak self] in self?.finishMoving() }

        apply(animated: false)
        island.show()
    }

    // MARK: Hover

    func pointer(inside: Bool) {
        guard previewPlacement == nil else { return }
        if pointerInside != inside {
            pointerInside = inside
            alerts.hold(inside)
            // Whether Option is down can change without the pointer moving, so while it is over the HUD the
            // modifier is watched. A global keyboard monitor would ask for accessibility; this does not.
            modifierWatch?.invalidate()
            modifierWatch = nil
            if inside, settings.settings.requiresOptionToOpen {
                modifierWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.reevaluateHover() }
                }
            }
        }
        // Moving within the HUD can reach the top while an ordinary hover is still waiting to open.
        reevaluateHover()
    }

    /// The bare island canvas passes clicks through. A visible strip has its own small grab surface;
    /// hidden logos expose that surface only with Command. Hover is followed by the coordinator, while
    /// an open island takes events for its controls.
    private func updateClickThrough(_ passes: Bool) {
        guard island.panel.ignoresMouseEvents != passes else { return }
        island.panel.ignoresMouseEvents = passes
    }

    /// The region that counts as hovering: the marks while collapsed, the wings an event grew, the panel once it is
    /// open. The target frame rather than the window's, which is briefly grown into a canvas for the opening
    /// animation. An event is the only thing on screen at that moment, so everything it draws is part of it — a
    /// reminder you cannot point at is a reminder you cannot answer.
    func samplePointer() {
        pointer(inside: Self.containsPointer(mouseLocation(), in: hoverRegion))
    }

    /// CGRect.contains excludes its top and right edges. A pointer pinned to a display edge is still
    /// over the HUD, including at the physical notch, so hover includes the target's boundary.
    static func containsPointer(_ point: CGPoint, in region: CGRect) -> Bool {
        !region.isEmpty && point.x >= region.minX && point.x <= region.maxX
            && point.y >= region.minY && point.y <= region.maxY
    }

    /// AppKit's pointer may stop one point short of maxY at a physical display boundary.
    /// Only the HUD's own top edge qualifies; side and bottom queues keep their ordinary hover delay.
    static func pointerTouchesTop(_ point: CGPoint, geometry: NotchGeometry) -> Bool {
        geometry.edge == .top && point.y >= geometry.screenFrame.maxY - 1
            && point.y <= geometry.screenFrame.maxY && containsPointer(point, in: geometry.rect)
    }

    private var hoverRegion: CGRect {
        ScreenHUD.hoverRegion(open: machine.isOpen, panel: targetWindowFrame ?? island.panel.frame,
                              alert: alertFrame, marks: geometry.rect)
    }

    /// Which shape the pointer has to be inside to count as hovering this HUD.
    static func hoverRegion(open: Bool, panel: CGRect, alert: CGRect?, marks: CGRect) -> CGRect {
        if open { return panel }
        return alert ?? marks
    }

    /// Hovering opens the panel, unless the user asked for Option as well. Typing keeps it open either way.
    private func reevaluateHover() {
        guard !moveHintVisible, !dragSurface.isPressed, previewPlacement == nil else { return }
        let opens = ScreenHUD.opensOnHover(counted: hoverOpens, open: machine.isOpen, pointerInside: pointerInside,
                                           typing: typing, requiresOption: settings.settings.requiresOptionToOpen,
                                           optionDown: NSEvent.modifierFlags.contains(.option))
        let canFinishOpening = switch machine.state {
        case .opening: true
        // A handoff to Settings or Stats deliberately stays collapsed until the pointer leaves.
        case .collapsed: !hoverOpens
        default: false
        }
        if opens, canFinishOpening, settings.settings.openImmediatelyAtTop,
           Self.pointerTouchesTop(mouseLocation(), geometry: geometry) {
            hoverOpens = true
            transition(machine.reduce(.forceOpen, config: config))
            return
        }
        guard opens != hoverOpens else { return }
        hoverOpens = opens
        let now = Date()
        transition(machine.reduce(opens ? .pointerEntered(at: now) : .pointerExited(at: now), config: config))
    }

    /// Whether the hover counts as one that opens the panel; `counted` is whether it already does. Option is asked for
    /// only to start it: a tap is enough, and from then on the hover counts until the pointer leaves. An open panel
    /// needs no Option either — it is being read and pointed at, including by a pointer that slipped off the edge and
    /// came back before it closed.
    static func opensOnHover(counted: Bool, open: Bool, pointerInside: Bool, typing: Bool,
                             requiresOption: Bool, optionDown: Bool) -> Bool {
        typing || pointerInside && (counted || open || !requiresOption || optionDown)
    }

    func forceOpen() {
        transition(machine.reduce(.forceOpen, config: config))
    }

    func forceCollapse() {
        transition(machine.reduce(.forceCollapse, config: config))
    }

    // MARK: Quota events

    func present(_ alert: QuotaAlert) { present(.quota(alert)) }

    /// `inUsagePanel` is passed on when one request hands over to the next: the surface the user is looking at is
    /// theirs, and answering a card must not move the queue into the usage panel underneath it.
    func present(_ alert: IslandAlert, inUsagePanel: Bool? = nil) {
        // A hidden or paused glow silences news. A client waiting for an answer is not news: it is a question that
        // was asked of this user, and hiding it would leave the session stuck with nobody knowing why.
        let silenced = (store.glowHidden || store.isPaused) && !alert.isPersistent
        guard !silenced, alerts.show(alert, inUsagePanel: inUsagePanel ?? machine.isOpen) else { return }
        // An event owns the brief expansion; a pending hover must not open the full panel underneath it.
        timer?.invalidate()
        timer = nil
        openingPreparation = nil
        if !machine.isOpen { machine = HoverMachine() }
        if hoverOpens {
            transition(machine.reduce(.pointerEntered(at: Date()), config: config))
        }
        apply(animated: true)
        island.show()
    }

    /// The client withdrew its request: it timed out, it was answered in the terminal, or it was killed. Nothing is
    /// answered on the user's behalf — the card simply stops being a question.
    func withdraw(requestID: String) {
        let surface = alerts.current?.inUsagePanel
        let wasShowing = activeAlert?.id == requestID
        let outcome = alerts.remove(id: requestID)
        guard outcome.removed else { return }
        if wasShowing { stopTyping() }
        if let next = outcome.next {
            present(next, inUsagePanel: surface)
        } else if alerts.current == nil {
            closeAfterLastAlert(wasInUsagePanel: surface ?? false)
        }
    }

    /// Brings a stacked request to the front, so the buttons act on the card the user is looking at. One that arrived
    /// on another screen moves to this one first.
    func selectRequest(_ id: String) {
        if !alerts.contains(id: id) { onClaimRequest?(id) }
        guard alerts.promote(id: id) else { return }
        openingPreparation = nil
        apply(animated: true)
    }

    /// The requests this screen holds, which outlive it when its display goes away.
    var questions: [IslandAlert] { alerts.questions }

    func holds(_ id: String) -> Bool { alerts.contains(id: id) }

    /// Hands a request over to another screen: it leaves this one as a withdrawn one does, still unanswered.
    func take(requestID: String) -> IslandAlert? {
        guard let alert = alerts.questions.first(where: { $0.id == requestID }) else { return nil }
        withdraw(requestID: requestID)
        return alert
    }

    /// Hands the user's answer to the client that is waiting for it, and takes the card off the island.
    private func decideAlert(_ decision: PermissionDecision) {
        guard case .permission(let request)? = activeAlert else { return }
        stopTyping()
        PermissionRequests.shared.resolve(request.id, decision)
    }

    private func setTyping(_ typing: Bool) {
        guard self.typing != typing else { return }
        self.typing = typing
        updateDragSurface()
        reevaluateHover()
    }

    /// The card being typed into is gone: the keyboard goes back to the app it came from.
    private func stopTyping() {
        island.panel.releaseKeyboard()
        setTyping(false)
    }

    private func dismissAlert() {
        let surface = alerts.current?.inUsagePanel
        if let next = alerts.dismiss() {
            present(next, inUsagePanel: surface)
        } else {
            closeAfterLastAlert(wasInUsagePanel: surface ?? false)
        }
    }

    /// What the island does once the last card is gone. A card the user was reading in place of the panel takes the
    /// island back to where it was before it arrived: the pointer is on a button that said Deny, not on one asking
    /// for the usage panel, and sliding the panel under it would answer a question nobody put. A card that was a row
    /// inside the panel leaves the panel exactly where it was.
    private func closeAfterLastAlert(wasInUsagePanel: Bool) {
        if ScreenHUD.closesAfterLastAlert(wasInUsagePanel: wasInUsagePanel, pointerInside: pointerInside) {
            machine = HoverMachine()
            openingPreparation = nil
            timer?.invalidate()
            timer = nil
        }
        apply(animated: true)
    }

    /// Whether the island collapses once the last card is answered.
    static func closesAfterLastAlert(wasInUsagePanel: Bool, pointerInside: Bool) -> Bool {
        !wasInUsagePanel || !pointerInside
    }

    /// Opens the statistics window on what the card was about: a finished turn's session, or a quota event's window.
    private func openAlert() {
        guard let alert = activeAlert else { return }
        store.focusedSessionID = nil
        switch alert {
        case .quota(let event) where store.rows.contains(where: { $0.id == event.agent.id }):
            store.selectedQuotaId = event.agent.id
        case .completion(let event) where store.sessions.contains(where: { $0.id == event.sessionID }):
            store.focusedSessionID = event.sessionID
        default: store.statsTab = .tokens
        }
        dismissAlert()
        handOff { onOpenStats?() }
    }

    /// A click that opens another window takes the HUD down first: the panel floats above every window and stays open
    /// while the pointer rests on it, so the window it opened would appear underneath it. The pointer has to leave and
    /// come back to open it again.
    private func handOff(_ open: () -> Void) {
        forceCollapse()
        open()
    }

    private var config: HoverMachine.Config {
        HoverMachine.Config(hoverDelay: settings.settings.hoverDelay, collapseDelay: settings.settings.collapseDelay)
    }

    private func transition(_ transition: HoverMachine.Transition) {
        let wasOpen = machine.isOpen
        machine = transition.machine
        timer?.invalidate()
        timer = nil
        if let deadline = transition.deadline {
            let interval = max(0.001, deadline.timeIntervalSinceNow)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.timerFired() }
            }
        }
        if case .opening = machine.state {
            prepareOpening()
        } else if !machine.isOpen {
            openingPreparation = nil
        }
        if wasOpen != machine.isOpen {
            // The panel opening is someone looking at the numbers, which is reason enough to read the accounts again.
            if machine.isOpen { Task { await store.refreshAccounts() } }
            apply(animated: true)
        }
    }

    private func timerFired() {
        transition(machine.reduce(.timerFired(at: Date()), config: config))
    }

    // MARK: Layout

    private var maximumContentHeight: CGFloat {
        geometry.screenFrame.height - 80
    }

    /// Resizes the open panel to its content (rows come and go as windows are discovered).
    private func updatePanelHeight(_ height: CGFloat) {
        let clamped = max(80, min(height.rounded(), maximumContentHeight))
        if showsAlertDetails {
            guard abs(clamped - alertDetailHeight) >= 1 else { return }
            alertDetailHeight = clamped
            apply(animated: true)
            return
        }
        guard clamped > 0, abs(clamped - panelHeight) >= 1 else { return }
        panelHeight = clamped
        if machine.isOpen { apply(animated: true) }
    }

    /// A card grows to its content freely and shrinks only as far as the pointer allows.
    ///
    /// Opening a shorter request, or answering one and losing its row, makes the card shorter than the pointer that
    /// asked for it: the pointer ends up below the card it is still using, which reads as having left the HUD, and
    /// the island closes under the user's hand. The card keeps its height until the pointer is no longer standing
    /// in the part that would be taken away.
    /// The window's height while a card is open: the card's own, or the tallest the card has been for as long as
    /// the pointer has stayed on it. The difference is transparent — the black shape is drawn at the card's size —
    /// so a shorter request opening under the pointer leaves a surface beneath it rather than a black band, and
    /// the window returns to the card's height the moment the pointer leaves.
    static func heldWindowHeight(card: CGFloat, floor: CGFloat, pointerInside: Bool) -> CGFloat {
        pointerInside ? max(card, floor) : card
    }

    /// This HUD's own display, or nothing once it has been unplugged.
    var screen: NSScreen? {
        NSScreen.screens.first { ScreenIdentity.key(for: $0) == key }
    }

    private var placement: ScreenPlacement {
        previewPlacement ?? screen.map { ScreenIdentity.placement(for: $0, in: settings.settings) } ?? .default(hasNotch: false)
    }

    // MARK: Repositioning

    func updateMoveHint(commandDown: Bool) {
        guard !dragSurface.isDragging else { return }
        let shows = commandDown && !typing
        guard shows != moveHintVisible else { return }
        moveHintVisible = shows
        if shows {
            openingPreparation = nil
            timer?.invalidate()
            timer = nil
            if !machine.isOpen { machine = HoverMachine(); hoverOpens = false }
        }
        updateDragSurface()
    }

    private func updateDragSurface() {
        let visibleHUD = geometry.mode == .notch || logoQueue != nil
        guard !typing, visibleHUD || moveHintVisible || previewPlacement != nil || dragSurface.isPressed else {
            dragSurface.hide()
            return
        }
        dragSurface.show(frame: Self.dragSurfaceFrame(for: geometry),
                         outlined: moveHintVisible || previewPlacement != nil || dragSurface.isPressed)
    }

    /// The dashed bounds leave room at both ends of the queue without moving its marks or backdrop.
    static func dragSurfaceFrame(for geometry: NotchGeometry) -> CGRect {
        var frame = geometry.rect.insetBy(dx: geometry.edge.isHorizontal ? -8 : 0,
                                         dy: geometry.edge.isHorizontal ? 0 : -8)
        // The physical notch cannot be clicked. A little space beneath it makes its move surface reachable.
        if geometry.mode == .notch { frame.origin.y -= 14; frame.size.height += 14 }
        return frame.intersection(geometry.screenFrame)
    }

    private func grabHUD() {
        openingPreparation = nil
        timer?.invalidate()
        timer = nil
        if !machine.isOpen { machine = HoverMachine(); hoverOpens = false }
        updateDragSurface()
    }

    private func releaseHUD() {
        updateDragSurface()
        if previewPlacement == nil { samplePointer() }
    }

    func beginMoving(at point: CGPoint? = nil) {
        openingPreparation = nil
        if let point {
            let run = geometry.edge.isHorizontal ? geometry.rect.width : geometry.rect.height
            let grip = geometry.edge.isHorizontal ? point.x - geometry.rect.minX : geometry.rect.maxY - point.y
            dragGrabFraction = min(1, max(0, grip / run))
        } else {
            dragGrabFraction = 0.5
        }
        previewPlacement = placement
        previewPlacement?.mode = .logos
        timer?.invalidate()
        timer = nil
        targetWindowFrame = nil
        geometryTransitionFrame = nil
        machine = HoverMachine()
        hoverOpens = false
        alerts.hold(true)
        apply(animated: false)
    }

    func move(to point: CGPoint) {
        guard let current = previewPlacement else { return }
        let config = LogoQueueConfig(items: queueItems, placement: current, settings: settings.settings)
        previewPlacement = NotchGeometry.dragPlacement(at: point, screenFrame: geometry.screenFrame,
                                                       queue: queueSize(config), placement: current,
                                                       grabFraction: dragGrabFraction)
        apply(animated: false)
    }

    func finishMoving() {
        guard let next = previewPlacement else { return }
        settings.update { $0.screens[key] = next }
        previewPlacement = nil
        moveHintVisible = NSEvent.modifierFlags.contains(.command) && !typing
        // Dropping the HUD is an explicit repositioning, not a request to open its panel under the pointer.
        hoverOpens = true
        apply(animated: false)
        pointerInside = Self.containsPointer(mouseLocation(), in: hoverRegion)
        alerts.hold(pointerInside)
    }

    private func queueSize(_ config: LogoQueueConfig) -> CGSize {
        guard config.items.isEmpty else { return config.size }
        let run = max(32, config.logo)
        return config.edge.isHorizontal ? CGSize(width: run, height: config.logo) : CGSize(width: config.logo, height: run)
    }

    /// The marks this screen shows: the watched agents and anything else run in the last day.
    private var queueItems: [LogoQueueItem] {
        LogoQueueItem.queue(rows: store.queueVendors)
    }

    /// Logo mode sizes the strip from the queue it has to hold.
    private func resolveGeometry() -> NotchGeometry {
        let screen = screen
        let placement = placement
        guard placement.mode == .logos else { return NotchGeometry.detect(screen: screen, placement: placement) }
        let config = LogoQueueConfig(items: queueItems, placement: placement, settings: settings.settings)
        return NotchGeometry.detect(screen: screen, placement: placement, queue: queueSize(config))
    }

    private var logoQueue: LogoQueueConfig? {
        // The geometry still measures the queue when the marks are hidden, so the backdrop keeps the place
        // and the width it had; only the drawing stops.
        guard geometry.mode == .logos, placement.showsLogos else { return nil }
        let config = LogoQueueConfig(items: queueItems, placement: placement, settings: settings.settings)
        return config.items.isEmpty ? nil : config
    }

    /// Takes this HUD's windows off screen; the display it belonged to is gone.
    func close() {
        openingPreparation = nil
        modifierWatch?.invalidate()
        timer?.invalidate()
        targetWindowFrame = nil
        geometryTransitionFrame = nil
        island.panel.orderOut(nil)
        glow.close()
        dragSurface.hide()
    }

    private func makeRoot(open: Bool, animated: Bool) -> IslandRootView {
        var root = IslandRootView(
            store: store,
            isOpen: open,
            collapsedSize: geometry.mode == .logos ? geometry.rect.size : geometry.islandFrame.size,
            collapsedTopRadius: geometry.mode == .logos ? NotchGeometry.expandedTopRadius : NotchGeometry.collapsedTopRadius,
            collapsedBottomRadius: geometry.cornerRadius,
            lightBorder: systemIsLight,
            onOpenStats: { [weak self] in self?.handOff { self?.onOpenStats?() } },
            onOpenSettings: { [weak self] in self?.handOff { self?.onOpenSettings?() } },
            additionalHUDControls: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return self.additionalHUDControls { [weak self] in self?.forceCollapse() }
            },
            alert: previewPlacement == nil ? activeAlert : nil,
            onOpenAlert: { [weak self] in self?.openAlert() },
            onDecideAlert: { [weak self] decision in self?.decideAlert(decision) },
            waitingRequests: PermissionRequests.shared.pending,
            onSelectRequest: { [weak self] id in self?.selectRequest(id) },
            onTyping: { [weak self] typing in self?.setTyping(typing) },
            showsAlertDetails: open && alerts.current?.inUsagePanel == false,
            animatesGeometry: animated
        )
        root.logoQueue = logoQueue
        root.edge = geometry.edge
        // The mode decides the silhouette, not whether there are marks to draw.
        root.hidesSilhouette = geometry.mode == .logos
        return root
    }

    /// Run during the existing hover delay without touching the visible windows or their current glow.
    private func prepareOpening() {
        guard case .opening = machine.state else { return }
        geometry = resolveGeometry()
        let inputs = openingInputs
        guard openingPreparation?.inputs != inputs else { return }
        let root = makeRoot(open: true, animated: false)
        let height = max(80, min(island.contentHeight(for: root).rounded(), maximumContentHeight))
        let surface = surface(open: true, height: height)
        let images = glow.prepare(geometry: geometry, island: surface.glowIsland,
                                  islandRadius: surface.glowRadius, glow: surface.glowGeometry,
                                  outwardOnly: surface.glowSettings.outwardOnly, appearance: inputs.appearance,
                                  pattern: surface.glowSettings.pattern(), drawsGlow: surface.drawsGlow)
        openingPreparation = OpeningPreparation(inputs: inputs, height: height, images: images)
    }

    func apply(animated: Bool) {
        let open = machine.isOpen
        let previousGeometry = geometry
        geometry = resolveGeometry()
        // A changed edge replaces the coordinate system; it is a repositioning, not an expansion.
        let animated = animated && geometry.edge == previousGeometry.edge
            && geometry.mode == previousGeometry.mode && geometry.screenFrame == previousGeometry.screenFrame
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var root = makeRoot(open: open, animated: animated)
        // A report can change the token legend without changing the coordinator's observed quota rows.
        // Validate at consumption as well as when the coordinator applies an update during the delay.
        let prepared = open && openingPreparation?.inputs == openingInputs ? openingPreparation : nil
        if open { openingPreparation = nil }
        if open {
            let height = prepared?.height
                ?? max(80, min(island.contentHeight(for: root).rounded(), maximumContentHeight))
            if showsAlertDetails { alertDetailHeight = height }
            else { panelHeight = height }
        }
        let surface = surface(open: open, height: showsAlertDetails ? alertDetailHeight : panelHeight)
        var windowFrame = surface.windowFrame
        let expanded = surface.expanded
        alertFrame = (activeAlert != nil && !open && expanded) ? windowFrame : nil
        // What the black shape fills, before the window is stretched to keep a surface under the pointer.
        let presentation = surface.cardFrame.size
        if showsAlertDetails {
            alertHoverFloor = pointerInside ? max(alertHoverFloor, windowFrame.height) : 0
            let held = ScreenHUD.heldWindowHeight(card: windowFrame.height, floor: alertHoverFloor,
                                                  pointerInside: pointerInside)
            if geometry.mode == .logos {
                windowFrame = geometry.expandedFrame(size: CGSize(width: windowFrame.width, height: held))
            } else {
                windowFrame.origin.y -= held - windowFrame.height
                windowFrame.size.height = held
            }
        } else {
            alertHoverFloor = 0
        }
        let appearance = store.glowAppearance(light: systemIsLight, on: key)
        let previousCanvas = island.panel.frame
        let previousCard = island.rootView.presentationFrame.map {
            CGRect(x: previousCanvas.minX + $0.minX, y: previousCanvas.maxY - $0.maxY,
                   width: $0.width, height: $0.height)
        }
        let cardFrame = surface.cardFrame
        if animated && previousCard != cardFrame {
            geometryTransitionFrame = cardFrame
        } else if !animated {
            geometryTransitionFrame = nil
        }

        if !animated || targetWindowFrame != windowFrame {
            targetWindowFrame = windowFrame
            if animated {
                // Every edge uses the same transition canvas. Card geometry supplies the parked anchor;
                // the union also covers a clamped card and any longer, stationary logo queue.
                island.setFrame(island.panel.frame.union(windowFrame))
                island.setVisibleSize(windowFrame.size)
            } else {
                island.setFrame(windowFrame)
                island.setVisibleSize(windowFrame.size)
            }
        }
        glow.update(
            geometry: geometry,
            island: surface.glowIsland,
            islandRadius: surface.glowRadius,
            glow: surface.glowGeometry,
            outwardOnly: surface.glowSettings.outwardOnly,
            appearance: appearance,
            animated: animated,
            alert: activeAlert,
            quotaVendors: store.alertPulseVendors,
            pattern: surface.glowSettings.pattern(),
            backdrop: surface.backdrop ? geometry.rect : nil,
            drawsGlow: surface.drawsGlow,
            prepared: prepared?.images
        )
        // The strip's place on screen is fixed; the window around it is not, so the offset between them is
        // measured rather than assumed to be the window's own top edge — which moves when the panel opens.
        let canvas = island.panel.frame
        root.logoQueueInset = max(0, canvas.maxY - geometry.rect.maxY)
        root.logoQueueHeight = geometry.rect.height
        root.logoQueueFrame = CGRect(x: geometry.rect.minX - canvas.minX,
                                     y: canvas.maxY - geometry.rect.maxY,
                                     width: geometry.rect.width, height: geometry.rect.height)
        updateClickThrough(geometry.mode == .logos && !expanded)
        // A tracking area can report an exit when the window or its hosting view resizes, even though the
        // pointer has not left the visible HUD. Both native events and the coordinator use screen geometry.
        // Collapsed logo queues pass clicks through, so their coordinator alone supplies the events.
        island.onPointerChange = geometry.mode == .logos
            ? nil
            : { [weak self] _ in self?.samplePointer() }
        root.presentationSize = presentation
        root.presentationFrame = CGRect(x: surface.cardFrame.minX - canvas.minX,
                                        y: canvas.maxY - surface.cardFrame.maxY,
                                        width: surface.cardFrame.width, height: surface.cardFrame.height)
        root.onContentHeight = { [weak self] height in self?.updatePanelHeight(height) }
        root.onGeometryCompletion = { [weak self] in
            // Reversing or repositioning can finish an older animation together with the new one.
            // A changing logo queue can also change the canvas without changing the card's target.
            guard let self, self.geometryTransitionFrame == cardFrame,
                  let target = self.targetWindowFrame else { return }
            self.geometryTransitionFrame = nil
            self.island.setFrame(target)
        }
        island.setRootView(root)
        if geometryTransitionFrame == nil { island.setFrame(windowFrame) }
        updateDragSurface()
        prepareOpening()
    }

    /// Both preparation and presentation use the same parked edge, clamping and glow dimensions.
    private struct Surface {
        let windowFrame: CGRect
        let cardFrame: CGRect
        let expanded: Bool
        let glowIsland: CGRect
        let glowRadius: CGFloat
        let glowGeometry: GlowGeometry
        let glowSettings: GlowSettings
        let backdrop: Bool
        let drawsGlow: Bool
    }

    private func surface(open: Bool, height: CGFloat) -> Surface {
        let expanded = (open || activeAlert != nil) && previewPlacement == nil
        let compactSize = geometry.mode == .logos
            ? IslandRootView.dockCompactSize(edge: geometry.edge, collapsedSize: geometry.rect.size)
            : CGSize(width: geometry.rect.width + 2 * (IslandController.alertWingWidth + IslandController.alertSidePadding),
                     height: max(38, geometry.rect.height))
        let size = open
            ? (alerts.current?.inUsagePanel == false
                ? CGSize(width: activeAlert?.detailWidth ?? IslandController.alertDetailWidth,
                         height: height)
                : CGSize(width: IslandController.expandedWidth, height: height))
            : compactSize
        // The shoulder curves widen the contact with the parked edge. Clamp their whole canvas, then
        // derive the card's core from it, so even a dock near a corner retains both curved shoulders.
        let flare = open || geometry.mode == .logos ? NotchGeometry.expandedTopRadius : NotchGeometry.collapsedTopRadius
        let horizontal = geometry.edge.isHorizontal
        let dockWindowSize = CGSize(width: size.width + (horizontal ? flare * 2 : 0),
                                    height: size.height + (horizontal ? 0 : flare * 2))
        let cardFrame = expanded
            ? (geometry.mode == .logos
                ? geometry.expandedFrame(size: dockWindowSize)
                : geometry.expandedFrame(size: size).insetBy(dx: -flare, dy: 0))
            : geometry.islandFrame
        // A short card must not clip a longer queue. The extra canvas stays transparent and the card
        // retains its own screen position, including while a reminder's hover floor holds a taller window.
        let windowFrame = open && geometry.mode == .logos && activeAlert == nil
            ? cardFrame.union(geometry.islandFrame).intersection(geometry.screenFrame)
            : cardFrame
        let islandFrame = expanded
            ? (geometry.mode == .logos
                ? cardFrame.insetBy(dx: horizontal ? flare : 0, dy: horizontal ? 0 : flare)
                : geometry.expandedFrame(size: size))
            : geometry.rect
        let radius = open ? IslandController.expandedRadius : max(geometry.cornerRadius, activeAlert == nil ? 0 : 14)
        let current = settings.settings
        // This screen's own glow, or the default when it has not been given one.
        let glowSettings = current.glow(on: key)
        // The glow style is the HUD's backdrop in both modes, but the shape it radiates from differs. The
        // notch is a small silhouette, so the field reads as a rim around it. A logo queue wants a curtain
        // exactly as wide as the marks: the shape is a flat lip at the screen's top edge, run wider than the
        // queue so every cell's nearest point is straight above it and the field falls vertically. The glow
        // panel then clips that field back to the queue's own column, cutting off the ends that would dip.
        let backdrop = geometry.mode == .logos && !expanded
        // Only a silhouette is worth rimming. A logo queue has none — its glow is the backdrop behind the
        // marks — so once the panel or an event has grown over the place that field belonged, it stops
        // rather than following the new shape around.
        let drawsGlow = geometry.mode != .logos || backdrop
        let overhang = GlowWindowController.backdropOverhang(glowSettings)
        // The lip is a flat line on the screen's top edge, run wider than the queue: every cell's nearest
        // point is then straight above it, so the field falls vertically instead of curling in at the ends,
        // and the marks sit inside the field rather than below where it starts.
        let glowIsland: CGRect = {
            guard backdrop else { return islandFrame }
            switch geometry.edge {
            case .top:
                return CGRect(x: geometry.rect.minX - overhang, y: geometry.screenFrame.maxY,
                              width: geometry.rect.width + overhang * 2, height: 2)
            case .bottom:
                return CGRect(x: geometry.rect.minX - overhang, y: geometry.screenFrame.minY - 2,
                              width: geometry.rect.width + overhang * 2, height: 2)
            case .left:
                return CGRect(x: geometry.screenFrame.minX - 2, y: geometry.rect.minY - overhang,
                              width: 2, height: geometry.rect.height + overhang * 2)
            case .right:
                return CGRect(x: geometry.screenFrame.maxX, y: geometry.rect.minY - overhang,
                              width: 2, height: geometry.rect.height + overhang * 2)
            }
        }()
        let glowRadius = backdrop ? 0 : radius
        let glowGeometry = glowSettings
            .geometry(islandWidth: geometry.edge.isHorizontal ? glowIsland.width : glowIsland.height,
                      islandHeight: geometry.edge.isHorizontal ? glowIsland.height : glowIsland.width,
                      islandRadius: glowRadius)
            .fitted(within: geometry.edge.isHorizontal ? geometry.screenFrame.height : geometry.screenFrame.width)
        return Surface(windowFrame: windowFrame, cardFrame: cardFrame, expanded: expanded, glowIsland: glowIsland,
                       glowRadius: glowRadius, glowGeometry: glowGeometry, glowSettings: glowSettings,
                       backdrop: backdrop, drawsGlow: drawsGlow)
    }
}
