import SwiftUI
import AgentHUDCore

extension EnvironmentValues {
    /// The scale of the dock a view belongs to (`IslandRootView.dockScale`); 1 anywhere else. What a dock grows
    /// out of itself reads it; cards do not.
    @Entry var stripScale: CGFloat = 1
    /// The widths of a compact reminder's two halves on a dock; nil beside the notch, where they are its wings.
    @Entry var compactWings: CompactWings? = nil
}

/// A compact reminder says who on one side and what on the other. Beside the notch the two are wings of one fixed
/// width with the camera between them. On a dock nothing stands between them, so each is as wide as its words and
/// the pill is as long as what it says: the dock growing an arm, as the Simple panel's hover line is.
struct CompactWings: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
    /// Between the two halves.
    var gap: CGFloat
    /// At each end of the pill.
    var padding: CGFloat
    var width: CGFloat { leading + gap + trailing + 2 * padding }

    /// The halves of `alert`'s reminder on a dock set to `scale`, each measured from its text and no wider than a
    /// wing, so the pill is placed before anything is drawn. The lengths are the ones the reminders' views use.
    @MainActor
    static func dock(for alert: IslandAlert, waiting: Int = 1, scale: CGFloat) -> CompactWings {
        let scale = max(1, scale)
        func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        func width(_ text: String, _ font: NSFont) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        // A symbol is wider than its point size, each by its own amount, so its width is asked of the symbol.
        func symbol(_ name: String, _ size: CGFloat) -> CGFloat {
            let drawn = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))?.size.width
            return ceil(drawn ?? size * 1.4)
        }
        let name = NSFont.systemFont(ofSize: s(13), weight: .semibold)
        let who: String, what: String, mark: CGFloat, status: NSFont
        var count: CGFloat = 0
        switch alert {
        case .completion(let event):
            who = event.agentVendor; what = IslandAlertCompactView.replyStatus; mark = symbol("text.bubble", s(16))
            status = .systemFont(ofSize: s(12), weight: .medium)
        case .permission(let request):
            who = request.project ?? request.vendor; what = PermissionAlertCompactView.status(of: request)
            mark = symbol("hand.raised.fill", s(14))
            status = .systemFont(ofSize: s(12), weight: .medium)
            if waiting > 1 {
                count = s(7) + width("×\(waiting)", .monospacedDigitSystemFont(ofSize: s(10), weight: .semibold)) + 2 * s(5)
            }
        case .quota(let event):
            // These two symbols sit in a frame of their own, two points over their size.
            who = event.agent.vendorName; what = QuotaAlertCompactView.status(of: event); mark = s(12) + 2
            status = .monospacedDigitSystemFont(ofSize: s(12), weight: .medium)
        case .resetCredits(let grant):
            who = grant.account.account.provider; what = ResetCreditAlertCompactView.status(of: grant); mark = s(12) + 2
            status = .monospacedDigitSystemFont(ofSize: s(12), weight: .medium)
        }
        let wing = s(IslandController.alertWingWidth)
        // A point to spare each: a width measured here and one laid out by SwiftUI can differ by a fraction.
        return CompactWings(leading: min(wing, s(17) + s(8) + width(who, name) + 1),
                            trailing: min(wing + count, mark + s(7) + width(what, status) + count + 1),
                            gap: s(14), padding: s(12))
    }
}

/// A single silhouette: closed notch, lateral event wings, or a hovered detail surface.
struct IslandRootView: View {
    let store: UsageStore?
    let isOpen: Bool
    let collapsedSize: CGSize
    let collapsedTopRadius: CGFloat
    let collapsedBottomRadius: CGFloat
    let lightBorder: Bool
    let onOpenStats: () -> Void
    var onOpenSettings: () -> Void = {}
    var additionalHUDControls: @MainActor () -> AnyView = { AnyView(EmptyView()) }
    var alert: IslandAlert? = nil
    var onOpenAlert: () -> Void = {}
    var onDismissAlert: () -> Void = {}
    var onOpenAlertSession: () -> Void = {}
    var onOpenAlertUsage: () -> Void = {}
    var sessionNavigationFailed = false
    var onOpenListedSession: (String) -> Void = { _ in }
    var failedListedSessionID: String? = nil
    /// The user's answer to a request waiting on the island; the alert's own id says which request it answers.
    var onDecideAlert: (PermissionDecision) -> Void = { _ in }
    /// Every request waiting for this user, oldest first and across screens: the expanded card stacks the rest under
    /// the one being decided, and the collapsed island only counts them.
    var waitingRequests: [PermissionRequest] = []
    /// The screen owner supplies the same expansion to visible content and natural-height measurement.
    var answeringSessionID: String? = nil
    var onAnswerSession: (String?) -> Void = { _ in }
    /// Replies and requests share the event surface while quota and tokens keep their own panel.
    var sessionEvents: [IslandAlert] = []
    /// Brings one of the stacked requests to the front.
    var onSelectRequest: (String) -> Void = { _ in }
    /// The user started or stopped typing an answer on the island.
    var onTyping: @MainActor (Bool) -> Void = { _ in }
    var showsAlertDetails = false
    var presentationSize: CGSize? = nil
    /// The actual card inside a canvas that can also hold a longer logo strip. Coordinates are local,
    /// top-left based; the card and its upright content share this exact frame with the native shadow.
    var presentationFrame: CGRect? = nil
    var animatesGeometry = true
    var onContentHeight: (CGFloat) -> Void = { _ in }
    var onGeometryCompletion: () -> Void = {}
    /// Set on a screen in logo mode: the marks ride on top of the silhouette, collapsed or open, so hovering
    /// never makes the agents disappear.
    var logoQueue: LogoQueueConfig? = nil
    /// Set on a screen in Simple mode: the panel of rings and numbers, which takes the queue's place. Its
    /// silhouette floats, and is the panel itself while collapsed.
    var simpleMeter: SimpleMeterConfig? = nil
    /// Whether marks on this island turn into bots; carried to the alerts through the environment.
    var botLogos = true
    /// Set on a screen whose HUD is a logo queue. Collapsed, such a HUD has no silhouette: it is the marks
    /// over whatever is behind them. Kept apart from `logoQueue`, which only says whether marks are drawn —
    /// hiding them leaves the backdrop alone and must not bring the black shape back.
    var hidesSilhouette = false
    /// Set on a dock that separates its agents. The marks then stay where they are whatever the card does:
    /// the Simple panel draws its own capsule instead of lending it to the card, and nothing replaces them.
    var separatesAgents = false
    /// The one agent the card is for right now: the hovered mark's, or the sender of the event on show.
    /// Its card is detached: it floats beside the mark instead of growing out of the screen edge.
    var focusVendor: String? = nil
    /// What hovering shows of that agent before a click opens its whole panel.
    var peek: AgentPeek? = nil
    /// A click asked for the agent's whole panel.
    var pinned = false
    var onPin: () -> Void = {}
    /// Where the detached card is on screen, which a change of the window around it leaves alone.
    var cardScreenFrame: CGRect? = nil

    private var detached: Bool { focusVendor != nil }

    /// A card comes out of the dock and goes back into it: scaled from the side that faces the dock. The Simple
    /// line on a side edge only lengthens, as the panel growing an arm would.
    private func cardTransition(_ frame: CGRect, in bounds: CGSize, line: Bool) -> AnyTransition {
        guard !reduceMotion, bounds.width > 0, bounds.height > 0 else { return .opacity }
        let point: CGPoint = switch edge {
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        }
        let anchor = UnitPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        let lengthens = line && !edge.isHorizontal
        return .modifier(active: CardGrowth(x: lengthens ? 0.2 : 0.86, y: lengthens ? 1 : 0.86, opacity: 0, anchor: anchor),
                         identity: CardGrowth(x: 1, y: 1, opacity: 1, anchor: anchor))
    }

    /// Where a detached card is and how round, as numbers SwiftUI interpolates itself: a card that moves to another
    /// agent, or widens into the whole panel, passes through every size in between instead of jumping to the last.
    private struct CardPlacement: ViewModifier, @preconcurrency Animatable {
        var frame: CGRect
        var radius: CGFloat
        var outline: Double

        var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>,
                                           AnimatablePair<CGFloat, Double>> {
            get { .init(.init(.init(frame.minX, frame.minY), .init(frame.width, frame.height)), .init(radius, outline)) }
            set {
                frame = CGRect(x: newValue.first.first.first, y: newValue.first.first.second,
                               width: newValue.first.second.first, height: newValue.first.second.second)
                radius = newValue.second.first
                outline = newValue.second.second
            }
        }

        func body(content: Content) -> some View {
            let card = RoundedRectangle(cornerRadius: min(radius, min(frame.width, frame.height) / 2), style: .continuous)
            content
                .frame(width: max(0, frame.width), height: max(0, frame.height))
                .clipShape(card)
                .overlay { card.strokeBorder(.white.opacity(outline), lineWidth: 1) }
                .position(x: frame.midX, y: frame.midY)
        }
    }

    private struct CardGrowth: ViewModifier {
        let x: CGFloat, y: CGFloat, opacity: Double, anchor: UnitPoint
        func body(content: Content) -> some View {
            content.scaleEffect(x: x, y: y, anchor: anchor).opacity(opacity)
        }
    }

    /// The card on show is the Simple panel's one-line peek.
    private var growsFromPanel: Bool {
        isOpen && !pinned && alert == nil && peek?.style == .line && simpleMeter != nil && !showsAlertDetails
    }

    /// The Simple panel's own shape inside the window: its strip without the margin on the parked side.
    private var simplePanelPath: Path? {
        guard let simpleMeter, var panel = logoQueueFrame else { return nil }
        let margin = SimpleMeterConfig.edgeMargin
        switch edge {
        case .top: panel.origin.y += margin; panel.size.height -= margin
        case .bottom: panel.size.height -= margin
        case .left: panel.origin.x += margin; panel.size.width -= margin
        case .right: panel.size.width -= margin
        }
        return Path(roundedRect: panel, cornerRadius: simpleMeter.cornerRadius, style: .continuous)
    }
    static let detachedInsets = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)

    /// A full card keeps a card's corner; a peek or a compact reminder is as round as its height allows.
    private func detachedRadius(height: CGFloat) -> CGFloat {
        let wanted: CGFloat = isOpen && (pinned || showsAlertDetails) ? 22 : peek?.style == .bubble && alert == nil ? 14 : height
        return min(wanted, height / 2)
    }
    /// Where the queue's strip sits inside the window, in points down from its top edge, and how tall it is.
    /// The window's own top edge moves between the collapsed and the expanded frame; the marks must not.
    var logoQueueInset: CGFloat = 0
    var logoQueueHeight: CGFloat = 0
    var edge: HUDEdge = .top
    /// The queue's exact rect in the window, using SwiftUI's top-left coordinates. It stays anchored while
    /// the panel grows inward, including when clamping the panel near a screen corner moves its centre.
    var logoQueueFrame: CGRect? = nil
    var repositories: RepositoryStore? = nil
    var navigation: HubNavigation? = nil
    var isPinned = false
    var onTogglePin: () -> Void = {}
    var observesRepositories = true
    var maximumPanelHeight: CGFloat = 700
    var onOpenRepositories: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let expandedTopRadius: CGFloat = NotchGeometry.expandedTopRadius
    static let expandedBottomRadius: CGFloat = IslandController.expandedRadius
    /// A compact reminder on a dock is a slim pill, as tall as the Simple panel's hover line: 26 pt for a 17 pt mark
    /// and 13 pt text, where the notch's own height made it 48.
    nonisolated static let dockCompactHeight: CGFloat = 26
    /// Above and below the pill's row. The row already keeps its own padding at each end, so the card adds none.
    static let dockCompactInsets = EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0)
    /// This screen's `dockScale`. A compact reminder is the dock growing an arm, as the Simple panel's line is,
    /// so it is written to this scale; cards keep their own sizes.
    var stripScale: CGFloat = 1

    /// How much larger than at its default a dock writes what it grows out of itself: enough for a compact
    /// reminder's pill and the hover line to be as tall as one of the dock's marks, a Simple panel's ring or a
    /// Dynamic dock's logo. Never below 1, so beside a mark shorter than the default pill nothing is written
    /// smaller than it was. The notch has no size to follow and keeps 1.
    nonisolated static func dockScale(mode: HUDMode, placement: ScreenPlacement) -> CGFloat {
        switch mode {
        case .simple: max(1, CGFloat(placement.simpleSize) / dockCompactHeight)
        case .logos: max(1, CGFloat(placement.logoSize) / dockCompactHeight)
        case .notch: 1
        }
    }

    /// A compact reminder's row and the room above and below it, on a dock set to `scale`. The row is what the
    /// two insets leave of the pill, so a pill written to a mark's size is that size to the point.
    static func dockCompactRow(scale: CGFloat) -> (height: CGFloat, inset: CGFloat) {
        let scale = max(1, scale), inset = (dockCompactInsets.top * scale).rounded()
        return ((dockCompactHeight * scale).rounded() - 2 * inset, inset)
    }

    static var placeholder: IslandRootView {
        IslandRootView(store: nil, isOpen: false, collapsedSize: CGSize(width: 216, height: 32),
                       collapsedTopRadius: NotchGeometry.collapsedTopRadius, collapsedBottomRadius: 12,
                       lightBorder: false, onOpenStats: {})
    }

    var body: some View {
        surfaces.environment(\.botLogos, botLogos)
    }

    private var surfaces: some View {
        GeometryReader { proxy in
            let bounds = proxy.size
            let visible = isOpen || alert != nil
            let size = visible ? (presentationFrame?.size ?? presentationSize ?? bounds) : collapsedSize
            // Simple mode has one floating frame. Collapsed it is the capsule the figures sit in; opening
            // enlarges that same frame into the panel, so nothing fades in over it and nothing is swapped.
            let shape = simpleMeter.map { meter in
                IslandShape(
                    topRadius: visible ? Self.expandedTopRadius : 0,
                    bottomRadius: isOpen ? Self.expandedBottomRadius : (alert == nil ? meter.cornerRadius : 16),
                    edge: edge, lift: SimpleMeterConfig.edgeMargin
                )
            } ?? IslandShape(
                topRadius: isOpen ? Self.expandedTopRadius : collapsedTopRadius,
                bottomRadius: isOpen ? Self.expandedBottomRadius : max(collapsedBottomRadius, alert == nil ? 0 : 14),
                edge: edge
            )
            // A collapsed logo queue is the marks alone: no silhouette behind them, so they read as agents
            // sitting on the desktop rather than as a bar. The silhouette comes back the moment the panel
            // opens or an event needs somewhere to be shown — but never because the marks were hidden.
            let bare = hidesSilhouette && !visible && (!floats || separatesAgents)
            let surface = ZStack(alignment: surfaceAlignment) {
                // Keep one shape alive through collapse so it can shrink before becoming transparent.
                shape.fill(.black.opacity(floats && !visible ? 0.82 : 1))
                    .overlay {
                        if floats { shape.stroke(.white.opacity(0.14), lineWidth: 1) }
                        else if lightBorder && alert == nil { shape.stroke(.white.opacity(0.18), lineWidth: 1) }
                    }
                    .frame(width: size.width, height: size.height)
                    .opacity(bare ? 0 : 1)
                content
                    .environment(\.islandTyping, onTyping)
                    .mask(alignment: surfaceAlignment) { shape.frame(width: size.width, height: size.height) }
                }
            ZStack(alignment: .topLeading) {
                // The card's place in the view outlives the card: one that arrives with its own container has
                // nothing to grow out of.
                if separatesAgents, detached || !visible {
                    // The card belongs to a mark: it grows out of the dock beside it, slides along the dock from
                    // one agent to the next, and widens into the whole panel on a click.
                    ZStack(alignment: .topLeading) {
                    if visible, detached, let presentationFrame {
                        // The Simple line is the panel growing: the panel's own fill, no outline of its own, and
                        // nothing drawn where the panel already is, so the two never darken each other.
                        let grows = growsFromPanel
                        let motion: Animation? = reduceMotion ? nil : IslandAnimation.curve
                        ZStack {
                            Color.black.opacity(grows ? SimpleMeterView.fillOpacity : 1)
                            content.environment(\.islandTyping, onTyping)
                        }
                        .modifier(CardPlacement(frame: presentationFrame,
                                                radius: detachedRadius(height: presentationFrame.height),
                                                outline: grows ? 0 : 0.14))
                        // Keyed to the card's place on screen. Its place in the window also changes whenever the
                        // window around it is resized, and that must never move the card.
                        .animation(motion, value: cardScreenFrame)
                        .transition(cardTransition(presentationFrame, in: bounds, line: grows).animation(motion ?? .easeOut(duration: 0.12)))
                    }
                    }
                    .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                    .mask {
                        // A full card never reaches the panel, so the cut can stay while a line is on its way out.
                        if separatesAgents, let panel = simplePanelPath {
                            Path { path in
                                path.addRect(CGRect(origin: .zero, size: bounds))
                                path.addPath(panel)
                            }.fill(style: FillStyle(eoFill: true))
                        } else {
                            Rectangle()
                        }
                    }
                } else if let presentationFrame {
                    // The native canvas changes immediately. Only the card's size and its position
                    // along the parked edge interpolate; the contact edge stays on that canvas.
                    let offset = (hidesSilhouette ? edge : .top).isHorizontal
                        ? CGSize(width: presentationFrame.midX - bounds.width / 2, height: 0)
                        : CGSize(width: 0, height: presentationFrame.midY - bounds.height / 2)
                    surface
                        .frame(width: presentationFrame.width, height: presentationFrame.height,
                               alignment: surfaceAlignment)
                        .offset(offset)
                        .animation(geometryAnimation, value: presentationFrame)
                        .transaction(value: presentationFrame) { transaction in
                            if animatesGeometry {
                                transaction.addAnimationCompletion(criteria: .removed, onGeometryCompletion)
                            }
                        }
                        .frame(width: bounds.width, height: bounds.height, alignment: surfaceAlignment)
                } else {
                    surface
                        .animation(geometryAnimation, value: size)
                        .frame(width: bounds.width, height: bounds.height, alignment: surfaceAlignment)
                }
                if let logoQueue, alert == nil || focusVendor != nil {
                    if let logoQueueFrame {
                        LogoQueueView(config: logoQueue, light: lightBorder)
                            .frame(width: logoQueueFrame.width, height: logoQueueFrame.height)
                            .position(x: logoQueueFrame.midX, y: logoQueueFrame.midY)
                            .frame(width: bounds.width, height: bounds.height)
                            .transaction { $0.animation = nil }
                    } else {
                        LogoQueueView(config: logoQueue, light: lightBorder)
                            .frame(width: size.width, height: logoQueueHeight)
                            .padding(.top, logoQueueInset)
                            .frame(width: bounds.width, height: bounds.height, alignment: surfaceAlignment)
                            .transaction { $0.animation = nil }
                    }
                }
                if let simpleMeter, alert == nil || focusVendor != nil {
                    let strip = logoQueueFrame ?? CGRect(x: 0, y: logoQueueInset, width: size.width, height: logoQueueHeight)
                    SimpleMeterView(config: simpleMeter, onIsland: !separatesAgents)
                        .frame(width: strip.width, height: strip.height)
                        .position(x: strip.midX, y: strip.midY)
                        .frame(width: bounds.width, height: bounds.height)
                        .transaction { $0.animation = nil }
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .id(store?.settings.settings.language ?? .system)
    }

    @ViewBuilder
    var content: some View {
        if isOpen, showsAlertDetails, let alert {
            Group {
                if alert.isSessionEvent {
                    IslandEventPanelView(alert: alert, onOpen: onOpenAlert, onDecide: onDecideAlert,
                                         onDismiss: onDismissAlert,
                                         onOpenSession: onOpenAlertSession, onOpenUsage: onOpenAlertUsage,
                                         sessionNavigationFailed: sessionNavigationFailed,
                                         events: sessionEvents, waitingRequests: waitingRequests,
                                         onSelectRequest: onSelectRequest)
                } else {
                    IslandAlertDetailView(alert: alert, onOpen: onOpenAlert, onDecide: onDecideAlert,
                                          onDismiss: onDismissAlert,
                                          onOpenSession: onOpenAlertSession, onOpenUsage: onOpenAlertUsage,
                                          sessionNavigationFailed: sessionNavigationFailed,
                                          waitingRequests: waitingRequests, onSelectRequest: onSelectRequest)
                }
            }
                .padding(hidesSilhouette ? dockInsets : alert.detailInsets.map {
                    // Never under the silhouette: a notch is 38 pt of hardware on some Macs, and a card narrower
                    // than the usage panel sits squarely in its shadow rather than beside it. A screenshot cannot
                    // show that, which is why the number has to come from the screen and not from the panel.
                    EdgeInsets(top: max($0.top, collapsedSize.height), leading: $0.leading,
                               bottom: $0.bottom, trailing: $0.trailing)
                } ?? EdgeInsets(top: collapsedSize.height + alert.detailTopInset, leading: 24, bottom: 22, trailing: 24))
                .frame(width: alert.detailWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height) })
                .onPreferenceChange(PanelHeightKey.self, perform: onContentHeight)
                .transition(detailTransition)
        } else if isOpen, detached, !pinned, let peek {
            AgentPeekView(peek: peek)
                .contentShape(Rectangle())
                .onTapGesture(perform: onPin)
                .id(peek.vendor)
        } else if isOpen, let store {
            HoverPanelView(store: store, onOpenStats: onOpenStats, onOpenSettings: onOpenSettings,
                           additionalHUDControls: additionalHUDControls,
                           height: panelPresentationHeight,
                           alert: alert, onOpenAlert: onOpenAlert, onOpenAlertSession: onOpenAlertSession,
                           onOpenAlertUsage: onOpenAlertUsage, sessionNavigationFailed: sessionNavigationFailed,
                           onOpenListedSession: onOpenListedSession, failedListedSessionID: failedListedSessionID,
                           onDecideAlert: onDecideAlert,
                           waitingRequests: waitingRequests,
                           insets: hidesSilhouette ? dockInsets : HoverPanelView.notchInsets,
                           answeringSessionID: answeringSessionID, onAnswerSession: onAnswerSession,
                           focusVendor: focusVendor,
                           repositories: repositories, navigation: navigation, isPinned: isPinned, onTogglePin: onTogglePin,
                           observesRepositories: observesRepositories, maximumPanelHeight: maximumPanelHeight,
                           onOpenRepositories: onOpenRepositories)
                .frame(width: detached ? IslandController.agentPanelWidth : IslandController.expandedWidth, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .onPreferenceChange(PanelHeightKey.self, perform: onContentHeight)
                .transition(detailTransition)
        } else if let alert {
            if hidesSilhouette {
                let row = Self.dockCompactRow(scale: stripScale)
                let wings = CompactWings.dock(for: alert, waiting: max(1, waitingRequests.count), scale: stripScale)
                IslandAlertCompactView(alert: alert, cameraWidth: 0, height: row.height, onOpen: onOpenAlert,
                                       waitingRequests: waitingRequests)
                    .environment(\.stripScale, max(1, stripScale))
                    .environment(\.compactWings, wings)
                    .padding(.vertical, row.inset)
                    .frame(width: wings.width)
                    .offset(floats && !detached ? liftCentring : .zero)
                    .id(alert.id)
                    .transition(detailTransition)
            } else {
                IslandAlertCompactView(alert: alert,
                                      cameraWidth: collapsedSize.width - collapsedTopRadius * 2,
                                      height: max(38, collapsedSize.height), onOpen: onOpenAlert,
                                      waitingRequests: waitingRequests)
                    .id(alert.id)
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.08)))
            }
        }
    }

    /// Only the strip's thickness is clearance. A long vertical queue must not turn into top padding.
    static func dockInsets(edge: HUDEdge, collapsedSize: CGSize) -> EdgeInsets {
        let strip = edge.isHorizontal ? collapsedSize.height : collapsedSize.width
        var insets = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        switch edge {
        case .top: insets.top = strip + 12
        case .bottom: insets.bottom = strip + 12
        case .left: insets.leading = strip + 12
        case .right: insets.trailing = strip + 12
        }
        return insets
    }

    /// - wings: the reminder's own halves, which make the pill as long as what it says; without them it is two full
    ///   wings long, the most a reminder can be.
    static func dockCompactSize(edge: HUDEdge, collapsedSize: CGSize, scale: CGFloat = 1, wings: CompactWings? = nil) -> CGSize {
        // Events replace the marks, so their row needs no queue clearance. The window adds the
        // contact shoulders along its parked edge once, outside this compact content core.
        let scale = max(1, scale), row = dockCompactRow(scale: scale)
        // Each length is rounded as the row's own views round it, so the two agree to the point.
        let textWidth = wings?.width
            ?? 2 * (IslandController.alertWingWidth * scale).rounded() + 2 * (IslandController.alertSidePadding * scale).rounded()
        return CGSize(width: textWidth, height: row.height + 2 * row.inset)
    }

    /// A detached card covers no strip, so it needs none of a docked panel's clearance.
    private var dockInsets: EdgeInsets {
        detached ? Self.detachedInsets : Self.dockInsets(edge: edge, collapsedSize: collapsedSize)
    }

    /// Simple mode's silhouette floats off its edge instead of flaring into it.
    private var floats: Bool { simpleMeter != nil }

    /// A floating silhouette gives up `edgeMargin` on its edge side; a row centred in the card moves half of
    /// that inward to sit centred in what is left.
    private var liftCentring: CGSize {
        let half = SimpleMeterConfig.edgeMargin / 2
        switch edge {
        case .top: return CGSize(width: 0, height: half)
        case .bottom: return CGSize(width: 0, height: -half)
        case .left: return CGSize(width: half, height: 0)
        case .right: return CGSize(width: -half, height: 0)
        }
    }

    /// Side flares live above and below the content core. The fixed-height usage panel stays upright,
    /// centred between those shoulders, and the reported natural height still describes only the core.
    private var panelPresentationHeight: CGFloat? {
        guard let height = presentationFrame?.height ?? presentationSize?.height else { return nil }
        return hidesSilhouette && !edge.isHorizontal && !detached ? max(0, height - 2 * Self.expandedTopRadius) : height
    }

    private var surfaceAlignment: Alignment {
        IslandAnimation.attachmentAlignment(for: hidesSilhouette ? edge : .top)
    }

    private var geometryAnimation: Animation? {
        animatesGeometry && !reduceMotion ? IslandAnimation.curve : nil
    }

    private var detailTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let offset = IslandAnimation.entryOffset(for: hidesSilhouette ? edge : .top)
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(offset)).animation(.easeOut(duration: 0.22).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }
}
