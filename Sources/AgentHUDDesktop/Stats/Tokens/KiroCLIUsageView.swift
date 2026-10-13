import SwiftUI
import AgentHUDCore

/// Local CLI metering stays in its reported unit, outside the token chart's total and percentage shares.
struct KiroCLIUsageView: View {
    let records: [LocalUsageRecord]
    let theme: Theme
    var compact = false

    var body: some View {
        let reported = records.compactMap(\.credits)
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            HStack(spacing: 6) {
                AgentLogo(vendor: "Kiro", size: 12)
                Text(L10n.text("Kiro CLI 本机用量", "Kiro CLI local usage"))
                Spacer(minLength: 4)
                Text(reported.isEmpty ? L10n.text("credits 未提供", "Credits unavailable")
                     : amount(reported.reduce(0, +)) + " credits")
                    .font(.tabular(compact ? 11 : 18, .semibold))
            }
            if !compact {
                ForEach(Array(Set(records.map(\.model))).sorted(), id: \.self) { model in
                    let values = records.filter { $0.model == model }.compactMap(\.credits)
                    HStack {
                        Text(model).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(values.isEmpty ? "—" : amount(values.reduce(0, +)) + " credits").font(.tabular(11))
                    }
                    .foregroundStyle(theme.secondary)
                }
            }
            Text(note(reported: reported.count))
                .foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.ui(11))
        .help(L10n.text("所选时段内，CLI 保存的已完成轮次。随本地记录更新；进行中的轮次可能尚未落盘。credits 不计入 Token 合计。",
                       "Completed turns saved by the CLI in the selected range. Updates as local records change; running turns may not be saved yet. Credits are excluded from token totals."))
    }

    private func amount(_ value: Double) -> String {
        value > 0 && value < 0.01 ? "<0.01" : value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func note(reported: Int) -> String {
        let count = records.count
        let turns = L10n.text("已完成 \(count) 轮", "\(count) completed turns")
        let coverage = reported < count ? L10n.text(" · \(count - reported) 轮未提供 credits", " · \(count - reported) turns without credits") : ""
        let tokens = records.contains { !$0.hasTokenCounts }
            ? L10n.text(" · CLI 未提供完整 Token 计数", " · CLI token counts incomplete") : ""
        return turns + coverage + tokens
    }
}
