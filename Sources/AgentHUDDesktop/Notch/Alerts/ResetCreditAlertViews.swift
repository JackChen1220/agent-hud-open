import SwiftUI
import AgentHUDCore

/// The camera stays empty; the account's client sits in one wing and how many resets it gained in the other.
struct ResetCreditAlertCompactView: View {
    let grant: ResetCreditGrant
    let cameraWidth: CGFloat
    let height: CGFloat
    let onOpen: () -> Void

    var body: some View {
        let copy = ResetCreditAlertCopy(grant: grant)
        Button(action: onOpen) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    AgentLogo(vendor: grant.account.account.provider, size: 17)
                    Text(grant.account.account.provider)
                        .font(.ui(13, .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .frame(width: IslandController.alertWingWidth, alignment: .leading)
                Color.clear.frame(width: cameraWidth)
                HStack(spacing: 7) {
                    ResetCreditSymbol(grant: grant, size: 12)
                    Text(copy.compactTitle)
                        .font(.tabular(12, .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                }
                .frame(width: IslandController.alertWingWidth, alignment: .trailing)
            }
            .padding(.horizontal, IslandController.alertSidePadding)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("island-alert-resetCredits")
        .accessibilityLabel(copy.accessibilityLabel)
        .help(L10n.text("悬停查看详情，点击打开统计", "Hover for details; click for statistics"))
    }
}

/// Hovering the event shows what the account holds now and its earliest deadline.
struct ResetCreditAlertDetailView: View {
    let grant: ResetCreditGrant
    let onOpen: () -> Void

    var body: some View {
        let copy = ResetCreditAlertCopy(grant: grant)
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                AgentLogo(vendor: grant.account.account.provider, size: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(grant.account.account.provider).font(.ui(13, .semibold)).foregroundStyle(.white)
                    Text(grant.account.displayName).font(.ui(10)).foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle().fill(copy.accent).frame(width: 5, height: 5)
                    Text(L10n.text("新增重置", "new reset")).font(.ui(10, .medium)).foregroundStyle(copy.accent)
                }
            }
            Text(copy.title).font(.ui(12)).foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                metric("+\(grant.added)", label: L10n.text("新增", "added"))
                metric("\(grant.credits.availableCount)", label: L10n.text("可用次数", "available"))
                metric(copy.expiry, label: L10n.text("最早到期", "first expires"))
            }
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Text(L10n.text("查看用量统计", "View usage statistics"))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.ui(12, .semibold)).foregroundStyle(.black.opacity(0.9))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(copy.accent, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("island-alert-details-open")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(copy.accessibilityLabel)
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.tabular(23, .medium)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(label).font(.ui(10)).foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An event in the normal panel adds a quiet line, not a nested notification card.
struct ResetCreditAlertInlineView: View {
    let grant: ResetCreditGrant
    let onOpen: () -> Void

    var body: some View {
        let copy = ResetCreditAlertCopy(grant: grant)
        Button(action: onOpen) {
            HStack(spacing: 10) {
                ResetCreditSymbol(grant: grant, size: 13)
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.title).font(.ui(12, .medium)).foregroundStyle(.white.opacity(0.95))
                    Text("\(grant.account.account.provider) · \(grant.account.displayName)")
                        .font(.ui(10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.ui(10)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("island-alert-resetCredits")
        .accessibilityLabel(copy.accessibilityLabel)
    }
}

/// The panel's own mark for usage resets, turned once as the new one arrives.
private struct ResetCreditSymbol: View {
    let grant: ResetCreditGrant
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Image(systemName: "arrow.counterclockwise")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(IslandAlert.calmAccent))
            .rotationEffect(.degrees(animate ? -360 : 0))
            .frame(width: size + 2, height: size + 2)
            .task(id: grant.id) {
                animate = false
                guard !reduceMotion else { return }
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                withAnimation(.easeInOut(duration: 0.8)) { animate = true }
            }
    }
}

private struct ResetCreditAlertCopy {
    let grant: ResetCreditGrant
    var accent: Color { Color(IslandAlert.calmAccent) }
    var compactTitle: String {
        L10n.text("+\(grant.added) 次重置", grant.added == 1 ? "+1 reset" : "+\(grant.added) resets")
    }
    var title: String {
        L10n.text("此账户新增了 \(grant.added) 次额度重置。",
                  grant.added == 1 ? "A usage reset was added to this account." : "\(grant.added) usage resets were added to this account.")
    }
    /// The account's earliest deadline, as the usage panel names it.
    var expiry: String {
        guard let deadline = grant.credits.creditsByExpiry.compactMap(\.expirationDate).first else { return "—" }
        return deadline.formatted(Date.FormatStyle().month(.abbreviated).day()
            .locale(L10n.dateLocale))
    }
    var accessibilityLabel: String {
        grant.account.account.provider + " · " + title + (grant.isPreview ? L10n.text(" · 动画测试", " · Animation test") : "")
    }
}
