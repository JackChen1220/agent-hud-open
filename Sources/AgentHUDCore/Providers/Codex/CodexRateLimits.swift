import AgentHUDSupport
import Foundation

/// The `account/rateLimits/read` fields used by the HUD.
public struct CodexRateLimits: Decodable, Sendable {
    public struct Window: Decodable, Sendable {
        public let usedPercent: Double
        public let windowDurationMins: Int?
        public let resetsAt: TimeInterval?

        public var remainingPct: Double { QuotaMath.remaining(usedPercent: usedPercent) }
        public var resetAt: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
        public var duration: TimeInterval? { windowDurationMins.map { Double($0) * 60 } }
    }

    public struct Bucket: Decodable, Sendable {
        public let limitId: String?
        public let limitName: String?
        public let primary: Window?
        public let secondary: Window?
        public let planType: String?
    }

    public struct Row: Sendable {
        public let id: String
        public let label: String
        public let window: Window
        public let weekly: Window?
        public var account: ProviderAccount? = nil
        /// Only the `codex` bucket limits every model; another bucket limits its own model.
        public var allModels = true

        public var descriptor: AgentDescriptor {
            AgentDescriptor(id: id, vendor: "Codex", model: label, source: L10n.sourceCodexAppServer, enabled: true, account: account,
                            allModels: allModels)
        }

        func scoped(to account: ProviderAccount) -> Row {
            Row(id: account.windowID(id), label: label, window: window, weekly: weekly, account: account, allModels: allModels)
        }
    }

    /// The `account/read` result from the same engine process.
    public struct SignedInAccount: Decodable, Sendable {
        public let type: String?
        public let email: String?
        public let planType: String?
    }

    public let rateLimits: Bucket?
    public let rateLimitsByLimitId: [String: Bucket]?
    public let rateLimitResetCredits: CodexResetCredits?
    /// The ChatGPT workspace of this snapshot. Members of one workspace share it, so the email separates users.
    public let accountId: String?
    public var account: SignedInAccount?
    /// The hash of the workspace this home's account last came with, standing in for an `accountId` the engine left out.
    public var rememberedWorkspace: String?

    /// A present multi-bucket map is authoritative, including an empty map.
    public var buckets: [(id: String, bucket: Bucket)] {
        if let map = rateLimitsByLimitId {
            return map.keys.sorted { a, b in
                if a == "codex" { return b != "codex" }
                if b == "codex" { return false }
                return a < b
            }.map { ($0, map[$0]!) }
        }
        return rateLimits.map { [($0.limitId ?? "codex", $0)] } ?? []
    }

    public var plan: String? { buckets.compactMap { $0.bucket.planType }.first ?? account?.planType }

    /// Hashes of the signed-in email and of the workspace, as `ProviderAccount.identified` makes them; empty for a missing one.
    private var identity: (user: String, workspace: String) {
        let email = account?.email?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workspace = accountId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (email.isEmpty ? "" : RecordCoding.hash([email]),
                workspace.isEmpty ? rememberedWorkspace ?? "" : RecordCoding.hash([workspace]))
    }

    public func providerAccount(home: String) -> ProviderAccount {
        let identity = identity
        guard !identity.user.isEmpty || !identity.workspace.isEmpty else { return .unresolved(provider: "Codex", home: home) }
        return ProviderAccount(provider: "Codex", user: identity.user, workspace: identity.workspace, evidence: .account)
    }

    /// The keys the same account got from readings without its email, as when `account/read` answered too late, or
    /// without its workspace, as from an engine that leaves out `accountId`. Empty unless this reading has both.
    public var partialKeys: [String] {
        let identity = identity
        guard !identity.user.isEmpty, !identity.workspace.isEmpty else { return [] }
        return [ProviderAccount(provider: "Codex", user: "", workspace: identity.workspace, evidence: .account).id,
                ProviderAccount(provider: "Codex", user: identity.user, workspace: "", evidence: .account).id]
    }

    /// Window rows keyed by their own window id (`codex`, `codex:<limit>:<slot>`); providers scope them to the account.
    public func rows(home: String) -> [Row] {
        let account = providerAccount(home: home)
        return rows.map { $0.scoped(to: account) }
    }

    public var rows: [Row] {
        buckets.flatMap { id, bucket in
            let weekly = [bucket.primary, bucket.secondary].compactMap { $0 }.first { $0.windowDurationMins == 10080 }
            return [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { slot, window -> Row? in
                guard let window else { return nil }
                let period: String
                switch window.windowDurationMins {
                case 10080: period = L10n.text("本周", "Weekly")
                case .some(let minutes) where minutes > 0 && minutes % 60 == 0:
                    period = "\(minutes / 60)h"
                case .some(let minutes) where minutes > 0: period = "\(minutes)m"
                default: period = L10n.text(slot == "primary" ? "主额度" : "次额度", slot.capitalized)
                }
                let name = id == "codex" ? nil : VendorCatalog.window(bucket.limitName ?? id, vendor: "Codex")
                // The shared primary window keeps the old placeholder's id as its window key, preserving preferences.
                let rowId = id == "codex" && slot == "primary" ? "codex" : "codex:\(id):\(slot)"
                return Row(id: rowId, label: name.map { "\($0) · \(period)" } ?? period, window: window, weekly: weekly,
                           allModels: id == "codex")
            }
        }
    }
}

/// Account-wide earned resets. The count is authoritative; credit details can be absent or capped.
public struct CodexResetCredits: Codable, Hashable, Sendable {
    public struct Credit: Codable, Hashable, Sendable, Identifiable {
        public let id: String
        public let expiresAt: TimeInterval?

        public init(id: String, expiresAt: TimeInterval?) {
            self.id = id
            self.expiresAt = expiresAt
        }

        public var expirationDate: Date? { expiresAt.map(Date.init(timeIntervalSince1970:)) }
    }

    public let availableCount: Int
    public let credits: [Credit]?

    public init(availableCount: Int, credits: [Credit]?) {
        self.availableCount = availableCount
        self.credits = credits
    }

    public var creditsByExpiry: [Credit] {
        (credits ?? []).sorted { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
    }
}
