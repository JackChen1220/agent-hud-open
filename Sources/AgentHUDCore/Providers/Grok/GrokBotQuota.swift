import AgentHUDSupport
import Foundation

/// The Bot's schema-2 personal quota cache. Team selection needs a live client response and is not inferred here.
enum GrokBotQuota {
    /// Match the account's known cache paths even after a file was deleted, without opening transcript blobs.
    static func isQuotaChange(_ paths: Set<String>, in directory: URL) -> Bool {
        guard !paths.isEmpty else { return false }
        let resolved: [String]
        if let path = realpath(directory.path, nil) {
            let actual = String(cString: path)
            // FSEvents uses the real path; Foundation callers can use its /var or /tmp alias.
            resolved = [actual, URL(fileURLWithPath: actual).standardizedFileURL.path]
            free(path)
        } else { resolved = [] }
        func contains(_ key: String) -> Bool {
            let url = GrokBotCache.url(for: key, in: directory)
            return paths.contains(url.standardizedFileURL.path)
                || resolved.contains { paths.contains($0 + "/" + url.lastPathComponent) }
        }
        if contains(GrokBotCache.accountKey) { return true }
        guard let slot = GrokBotCache.currentAccount(in: directory) else { return false }
        return contains(GrokBotCache.quotaKey(account: slot))
    }

    static func fetch(in directory: URL, now: Date) throws -> ProviderQuota? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let marker = try GrokBotCache.value(at: GrokBotCache.url(for: GrokBotCache.accountKey, in: directory),
                                           key: GrokBotCache.accountKey, schema: 1)
        if marker == .null { return ProviderQuota(client: "Grok Bot", signedOut: true) }
        guard let quota = read(in: directory, now: now) else {
            throw UsageProviderError(L10n.text("Grok Bot 缓存额度不可用，请在 Bot 中刷新", "Grok Bot cached quota is unavailable; refresh in Bot"))
        }
        return quota
    }

    static func read(in directory: URL, now: Date) -> ProviderQuota? {
        guard let slot = GrokBotCache.currentAccount(in: directory) else { return nil }
        let key = GrokBotCache.quotaKey(account: slot)
        guard let value = try? GrokBotCache.value(at: GrokBotCache.url(for: key, in: directory), key: key, schema: 2),
              let quota = parse(value, accountSlot: slot, now: now),
              GrokBotCache.currentAccount(in: directory) == slot else { return nil }
        return quota
    }

    static func parse(_ value: ProviderJSON, accountSlot: String, now: Date) -> ProviderQuota? {
        guard value["kind"].stringValue == "present", value.objectValue?["selectedTeamId"] == .null,
              let expires = ProviderDate.milliseconds(value["expiresAtMs"]), expires > now,
              let readAt = ProviderDate.milliseconds(value["reading"]["readAtMs"]), readAt <= now, expires > readAt,
              now.timeIntervalSince(readAt) < 86400 else { return nil }
        let usage = value["reading"]["usage"]
        guard let used = usage["percentUsed"].numberValue, used >= 0,
              usage["hasNonZeroIncludedLimit"].boolValue == true,
              let trial = usage["isSandTrial"].boolValue,
              usage["isTeamSeat"].boolValue != true else { return nil }
        let reset = ProviderDate.milliseconds(usage["nextResetMs"])
        guard usage.objectValue?["nextResetMs"] == .null || reset != nil else { return nil }
        // A Bot slot may be an auth id or an email fallback. It cannot establish equality with a CLI user id.
        var quota = ProviderQuota(windows: [.init(id: "grok", label: trial ? L10n.text("试用额度", "Trial usage limit")
            : L10n.text("每周用量额度", "Weekly usage limit"), remaining: QuotaMath.remaining(usedPercent: used), reset: reset,
            duration: trial ? nil : TimeInterval(7 * 86400), shortLabel: trial ? L10n.text("试用", "Trial") : WindowNames.Period.week.shortName)],
            plan: usage["grokPlanLabel"].stringValue,
            displayNotice: L10n.text("额度来自 Grok Bot 缓存；在 Bot 中刷新可更新读数", "Quota from Grok Bot cache; refresh in Bot to update"),
            account: .unresolved(provider: "Grok", home: "grok-bot:" + RecordCoding.hash([accountSlot])),
            label: "Grok Bot", observedAt: readAt, client: "Grok Bot")
        if let cap = usage["onDemand"]["limitCents"].numberValue, cap > 0,
           let extra = usage["onDemand"]["usedCents"].numberValue, extra >= 0 {
            quota.windows.append(.init(id: "grok:extra", label: L10n.text("额外用量", "Extra usage"),
                remaining: QuotaMath.remaining(usedPercent: extra / cap * 100), reset: reset,
                shortLabel: L10n.text("额外用量", "Extra")))
        }
        return quota
    }
}
