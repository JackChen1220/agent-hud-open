import SwiftUI
import AgentHUDCore

struct UsageChartsCard: View {
    let store: UsageStore
    let theme: Theme

    var body: some View {
        TokenConsumptionChart(store: store, theme: theme, context: .stats)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

/// The statistics chart keeps its model controls; the island can show just a compact strip of its bars.
struct TokenConsumptionChart: View {
    enum Context { case stats, island }

    struct ModelTokens: Identifiable {
        let consumer: AgentDescriptor
        let tokens: Int
        let paletteIndex: Int
        var id: String { consumer.id }
    }

    let store: UsageStore
    let theme: Theme
    let context: Context
    let compact: Bool
    var onOpenStats: () -> Void
    private let inspectedColumnID: Date?
    @State private var modelFilter: TokenModelFilter
    @State private var modelsExpanded: Bool

    init(store: UsageStore, theme: Theme, context: Context, modelsExpanded: Bool = false,
         modelFilter: TokenModelFilter = TokenModelFilter(), inspectedColumnID: Date? = nil,
         compact: Bool = false, onOpenStats: @escaping () -> Void = {}) {
        self.store = store
        self.theme = theme
        self.context = context
        self.compact = compact
        self.onOpenStats = onOpenStats
        self.inspectedColumnID = inspectedColumnID
        _modelsExpanded = State(initialValue: modelsExpanded)
        _modelFilter = State(initialValue: modelFilter)
    }

    var body: some View {
        let consumers = context == .stats ? store.consumers.filter { modelFilter.includes($0.id) } : store.consumers
        let ids = context == .stats ? modelFilter.consumerIDs : nil
        let allColumns = store.tokenColumns
        let columns = ids == nil ? allColumns : store.tokenColumns(consumerIDs: ids)
        let models = context == .stats ? Self.modelTotals(consumers: store.consumers, columns: allColumns) : []
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("Token 消耗", "Tokens"))
                    .font(.ui(13, .semibold))
                Spacer()
                if context == .island {
                    Text(store.report == nil ? "\(store.tokenBucketSize.label) · —"
                         : "\(store.tokenBucketSize.label) · \(TokenFormat.short(columns.reduce(0) { $0 + $1.total })) tok")
                        .font(.tabular(12))
                        .foregroundStyle(theme.secondary)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(TokenFormat.short(columns.reduce(0) { $0 + $1.total }))
                            .font(.tabular(20, .semibold))
                            .help(L10n.text("所选模型、时间与种类的 Token 总量", "Total tokens for the selected models, range and kinds"))
                        if let cost = store.statsListCost(consumerIDs: ids) {
                            Text(L10n.text("按 API 价 ", "At API prices ") + cost.text)
                                .font(.tabular(11))
                                .foregroundStyle(theme.secondary)
                                .help(costHelp(unpriced: cost.unpriced))
                        }
                    }
                }
            }
            if !compact, context == .stats, !models.isEmpty || !modelFilter.isAll {
                modelPicker(models)
            } else if !compact, context == .island {
                let legend = Self.islandLegend(consumers: store.consumers, columns: allColumns)
                if !legend.shown.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(legend.shown) { model in
                            legendLabel(model.consumer, tokens: model.tokens)
                        }
                    }
                    .font(.ui(11))
                    .foregroundStyle(theme.secondary)
                }
                if legend.more > 0 {
                    Button {
                        store.statsTab = .tokens
                        onOpenStats()
                    } label: {
                        Text(L10n.text("另 \(legend.more) 个 · 查看统计", "+\(legend.more) more · View stats"))
                    }
                    .buttonStyle(.plain).font(.ui(10)).foregroundStyle(theme.secondary)
                    .accessibilityIdentifier("island-more-token-models")
                }
            }
            TokenBarsChart(columns: columns, interval: store.statsInterval,
                           colors: consumers.map { AgentPalette.swiftUIColor(index: store.consumerPaletteIndex($0.id)) },
                           consumers: consumers, theme: theme, isLoading: store.report == nil,
                           noModelsSelected: context == .stats && modelFilter.consumerIDs?.isEmpty == true,
                           inspectedColumnID: inspectedColumnID, compact: compact)
                .id([store.statsRange.hours, store.tokenBucketSize.rawValue, store.tokenDimensions.rawValue])
                .frame(height: compact ? 40 : (context == .island ? 72 : 100))
                .padding(.horizontal, context == .stats ? 12 : 6)
                .padding(.top, compact ? 8 : 12)
                .zIndex(1)

            if !compact {
                HStack {
                    let labels = ChartData.axisLabels(range: store.statsRange, now: store.dataDate)
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer() }
                        Text(label)
                            .lineLimit(2)
                            .multilineTextAlignment(index == 0 ? .leading : index == labels.count - 1 ? .trailing : .center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.ui(10))
                .foregroundStyle(theme.secondary)
                .padding(.horizontal, context == .stats ? 12 : 6)
            }
        }
    }

    nonisolated static func modelTotals(consumers: [AgentDescriptor], columns: [TokenColumn]) -> [ModelTokens] {
        consumers.enumerated().map { index, consumer in
            ModelTokens(consumer: consumer, tokens: columns.reduce(0) { $0 + $1.tokens[index] }, paletteIndex: index)
        }
    }

    /// The HUD limits labels, never the columns or totals. Ties retain the report's model order and palette identity.
    nonisolated static func islandLegend(consumers: [AgentDescriptor], columns: [TokenColumn]) -> (shown: [ModelTokens], more: Int) {
        let models = modelTotals(consumers: consumers, columns: columns).filter { $0.tokens > 0 }.sorted {
            $0.tokens == $1.tokens ? $0.paletteIndex < $1.paletteIndex : $0.tokens > $1.tokens
        }
        return (Array(models.prefix(10)), max(0, models.count - 10))
    }

    private func modelPicker(_ models: [ModelTokens]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { modelsExpanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: modelsExpanded ? "chevron.down" : "chevron.right").font(.ui(9, .semibold))
                        Text(modelFilter.isAll ? L10n.text("模型 · 全部", "Models · All")
                             : L10n.text("模型 · 已选 \(modelFilter.consumerIDs?.count ?? 0) 个", "Models · \(modelFilter.consumerIDs?.count ?? 0) selected"))
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("token-model-filter")
                .accessibilityValue(modelsExpanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
                Spacer()
                if !modelFilter.isAll {
                    Button(L10n.text("清除筛选", "Clear filter")) { modelFilter.selectAll() }
                        .accessibilityIdentifier("token-model-filter-clear")
                }
            }
            if modelsExpanded {
                Button { modelFilter.selectAll() } label: {
                    Label(L10n.text("全部模型", "All models"), systemImage: modelFilter.isAll ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityIdentifier("token-model-filter-all")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(models) { model in
                        Button { modelFilter.toggle(model.id) } label: {
                            HStack(spacing: 5) {
                                legendLabel(model.consumer, tokens: model.tokens)
                                Image(systemName: modelFilter.isPicked(model.id) ? "checkmark.circle.fill"
                                      : modelFilter.isAll ? "plus.circle" : "circle")
                                    .font(.ui(11))
                            }
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .background(modelFilter.isPicked(model.id) ? theme.text.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("token-model-\(model.id)")
                        .accessibilityValue(modelFilter.isPicked(model.id) ? L10n.text("已选", "Selected")
                                            : modelFilter.isAll ? L10n.text("包含在全部模型中", "Included in all models") : L10n.text("未选", "Not selected"))
                        .help(L10n.text("筛选此模型；点选其他模型可多选", "Filter to this model; click other models to add them"))
                    }
                }
            }
        }
        .buttonStyle(.plain).font(.ui(11)).foregroundStyle(theme.secondary)
    }

    private func costHelp(unpriced: [String]) -> String {
        let note = L10n.text("所选模型与种类按厂商 API 公开价折合；选「全部 Token」即这些调用的总价",
                             "The selected models and kinds at the vendors' API list prices; with all tokens selected, what the calls would cost")
        guard !unpriced.isEmpty else { return note }
        return note + "\n" + L10n.text("没有公开价、未计入：", "Not counted, no list price: ")
            + unpriced.map(store.consumerName).joined(separator: L10n.text("、", ", "))
    }

    private func legendLabel(_ consumer: AgentDescriptor, tokens: Int) -> some View {
        HStack(spacing: 5) {
            Circle().fill(AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(consumer.id))).frame(width: 7, height: 7)
            AgentLogo(vendor: consumer.vendor, size: 12)
            Text(consumer.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(TokenFormat.short(tokens)).font(.tabular(11)).fixedSize()
        }
        .accessibilityLabel("\(consumer.displayName): \(tokens.formatted()) tokens")
        .help("\(consumer.displayName): \(tokens.formatted()) tokens")
    }

}

/// Each column is a single stack whose height is the sum of its model segments.
struct TokenBarsChart: View {
    let columns: [TokenColumn]
    let interval: DateInterval
    let colors: [Color]
    let consumers: [AgentDescriptor]
    let theme: Theme
    var isLoading = false
    var noModelsSelected = false
    let compact: Bool
    @State private var hoveredID: Date?

    init(columns: [TokenColumn], interval: DateInterval, colors: [Color], consumers: [AgentDescriptor], theme: Theme,
         isLoading: Bool = false, noModelsSelected: Bool = false, inspectedColumnID: Date? = nil,
         compact: Bool = false) {
        self.columns = columns
        self.interval = interval
        self.colors = colors
        self.consumers = consumers
        self.theme = theme
        self.isLoading = isLoading
        self.noModelsSelected = noModelsSelected
        self.compact = compact
        _hoveredID = State(initialValue: inspectedColumnID)
    }

    private var inspectedColumn: TokenColumn? {
        hoveredID.flatMap { id in columns.first { $0.id == id } }
    }

    /// Render complete buckets at both ends; their counts still cover only the selected range.
    private var plotInterval: DateInterval {
        guard let first = columns.first, let last = columns.last else { return interval }
        return DateInterval(start: first.interval.start, end: last.interval.end)
    }

    var body: some View {
        let peak = columns.map(\.total).max() ?? 0
        let scale = max(1, peak)
        let inspectedColumn = inspectedColumn
        GeometryReader { proxy in
            let usable = proxy.size.height - 2
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(theme.divider).frame(height: 1)
                if let column = inspectedColumn {
                    let bounds = xBounds(column, width: proxy.size.width)
                    Rectangle().fill(theme.text.opacity(0.08))
                        .frame(width: bounds.upperBound - bounds.lowerBound, height: usable)
                        .offset(x: bounds.lowerBound)
                    Rectangle().fill(theme.secondary.opacity(0.5))
                        .frame(width: 1, height: usable)
                        .offset(x: (bounds.lowerBound + bounds.upperBound) / 2)
                }
                // Draw dense ranges in one surface instead of laying out a view for every segment.
                Canvas { context, size in
                    for column in columns where column.total > 0 {
                        let bounds = xBounds(column, width: size.width)
                        let gap = min(2, (bounds.upperBound - bounds.lowerBound) * 0.2)
                        let x = bounds.lowerBound + gap / 2
                        let width = max(0, bounds.upperBound - bounds.lowerBound - gap)
                        let height = CGFloat(column.total) / CGFloat(scale) * usable
                        let stack = CGRect(x: x, y: size.height - 1 - height, width: width, height: height)
                        var stackContext = context
                        stackContext.clip(to: Path(roundedRect: stack, cornerRadius: 2))
                        stackContext.opacity = inspectedColumn == nil || inspectedColumn?.id == column.id ? 1 : 0.55
                        var bottom = size.height - 1
                        for (index, value) in column.tokens.enumerated() where value > 0 {
                            let segmentHeight = CGFloat(value) / CGFloat(scale) * usable
                            bottom -= segmentHeight
                            let segment = CGRect(x: x, y: bottom, width: width, height: segmentHeight)
                            let color = colors.indices.contains(index) ? colors[index] : theme.secondary
                            stackContext.fill(Path(segment), with: .color(color))
                        }
                    }
                }
                if !compact, peak > 0 || !isLoading {
                    Text(TokenFormat.short(peak))
                        .font(.ui(10))
                        .foregroundStyle(theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(y: -12)
                }
                if peak == 0 && !isLoading {
                    Text(noModelsSelected ? L10n.text("未选择模型", "No models selected")
                         : L10n.text("此时间窗口内没有 Token 消耗", "No token usage in this range"))
                        .font(.ui(11))
                        .foregroundStyle(theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoveredID = isLoading && peak == 0 ? nil : column(at: point.x, width: proxy.size.width)?.id
                case .ended: hoveredID = nil
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let column = inspectedColumn {
                    let width = min(280, proxy.size.width)
                    let bounds = xBounds(column, width: proxy.size.width)
                    let midpoint = (bounds.lowerBound + bounds.upperBound) / 2
                    let preferred = midpoint < proxy.size.width / 2 ? midpoint + 12 : midpoint - width - 12
                    detail(column)
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(x: max(0, min(preferred, proxy.size.width - width)), y: -6)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Token 消耗图表", "Token consumption chart"))
        .accessibilityValue(inspectedColumn.map(description) ?? L10n.text("悬停查看时间段", "Hover to inspect a period"))
    }

    private func xBounds(_ column: TokenColumn, width: CGFloat) -> ClosedRange<CGFloat> {
        let left = column.interval.start.timeIntervalSince(plotInterval.start) / plotInterval.duration * width
        let right = column.interval.end.timeIntervalSince(plotInterval.start) / plotInterval.duration * width
        return left...right
    }

    private func column(at x: CGFloat, width: CGFloat) -> TokenColumn? {
        guard width > 0 else { return nil }
        let date = plotInterval.start.addingTimeInterval(max(0, min(1, x / width)) * plotInterval.duration)
        return ChartData.tokenColumn(at: date, in: columns)
    }

    private func detail(_ column: TokenColumn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(period(column)).font(.ui(10)).foregroundStyle(theme.secondary)
            Text("\(column.total.formatted()) tokens").font(.tabular(14, .semibold))
            ForEach(Array(consumers.enumerated()), id: \.element.id) { index, consumer in
                if column.tokens.indices.contains(index), column.tokens[index] > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(colors[index]).frame(width: 6, height: 6)
                        AgentLogo(vendor: consumer.vendor, size: 12)
                        Text(consumer.name).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(column.tokens[index].formatted()).font(.tabular(11))
                    }
                    .font(.ui(11))
                }
            }
            if column.total == 0 {
                Text(L10n.text("此时段没有 Token 消耗", "No token usage in this period"))
                    .font(.ui(11)).foregroundStyle(theme.secondary)
            }
            if column.interval.start < interval.start || column.interval.end > interval.end {
                Text(L10n.text("仅统计所选范围内的部分时段", "Partial period within the selected range"))
                    .font(.ui(10)).foregroundStyle(theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .foregroundStyle(theme.text)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.cardBorder))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private func period(_ column: TokenColumn) -> String {
        "\(ChartData.dateTime(max(column.interval.start, interval.start))) – \(ChartData.dateTime(min(column.interval.end, interval.end)))"
    }

    private func description(_ column: TokenColumn) -> String {
        let total = L10n.text("合计 \(column.total.formatted()) tokens", "Total \(column.total.formatted()) tokens")
        let details = zip(consumers, column.tokens).filter { $0.1 > 0 }.map { "\($0.0.displayName): \($0.1.formatted())" }
        return ([period(column), total] + details).joined(separator: "\n")
    }
}
