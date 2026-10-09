import AgentHUDSupport
import Foundation

/// Reads Kiro's existing sign-in without refreshing or rewriting its credentials. The request matches the
/// installed Kiro control-plane client; only fixed official hosts receive the bearer token.
struct KiroClient: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var http = ProviderHTTP()
    var clock: @Sendable () -> Date = { Date() }

    func fetch() async throws -> ProviderQuota {
        let path = home.appendingPathComponent(".aws/sso/cache/kiro-auth-token.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            if AdditionalSource.kiro.isInstalled(home: home) { throw ProviderFailure.login("Kiro") }
            return ProviderQuota()
        }
        guard let auth = try? ProviderFiles.json(path) else { throw ProviderFailure.login("Kiro") }
        let profile = try? ProviderFiles.json(home.appendingPathComponent("Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/profile.json"))
        let request = try Self.request(auth: auth, profile: profile, now: clock())
        do {
            let response = try await http.json(request.url, headers: request.headers)
            var quota = try Self.parse(response, now: clock())
            if quota.account == nil { quota.account = .unresolved(provider: "Kiro", home: home.path) }
            return quota
        } catch let error as ProviderHTTPError {
            if error.isAuthentication { throw ProviderFailure.login("Kiro") }
            throw error
        } catch let error as UsageProviderError { throw error }
        catch { throw UsageProviderError(L10n.text("Kiro 额度读取失败，请检查网络后重试", "Kiro quota could not be read; check the connection and retry")) }
    }

    static func request(auth: ProviderJSON, profile: ProviderJSON?, now: Date) throws -> (url: URL, headers: [String: String]) {
        guard let token = auth["accessToken"].stringValue, !token.isEmpty,
              let expires = DateParsing.internet(auth["expiresAt"].stringValue), expires > now else {
            throw UsageProviderError(L10n.text("请打开 Kiro 更新登录状态，再刷新额度", "Open Kiro to renew its sign-in, then refresh quota"))
        }
        let region = auth["region"].stringValue ?? "us-east-1"
        guard ["us-east-1", "eu-central-1", "us-gov-east-1", "us-gov-west-1"].contains(region) else {
            throw UsageProviderError(L10n.text("暂不支持此 Kiro 账户区域", "This Kiro account region is not supported yet"))
        }
        var url = URLComponents(string: "https://management.\(region).kiro.dev/getUsageLimits")!
        url.queryItems = [URLQueryItem(name: "origin", value: "AI_EDITOR")]
        // Prefer the profile bound to this login. Older IDEs keep it in their local profile record.
        if let arn = auth["profileArn"].stringValue ?? profile?["arn"].stringValue, !arn.isEmpty {
            url.queryItems?.append(URLQueryItem(name: "profileArn", value: arn))
        }
        var headers = ["Authorization": "Bearer \(token)"]
        if auth["authMethod"].stringValue == "IdC" { headers["TokenType"] = "SSO_OIDC" }
        if auth["authMethod"].stringValue == "external_idp" { headers["TokenType"] = "EXTERNAL_IDP" }
        return (url.url!, headers)
    }

    static func parse(_ response: ProviderJSON, now: Date = Date()) throws -> ProviderQuota {
        guard let breakdowns = response["usageBreakdownList"].arrayValue else { throw ProviderFailure.format }
        var quota = ProviderQuota(plan: response["subscriptionInfo"]["subscriptionTitle"].stringValue)
        quota.account = ProviderAccount.identified(provider: "Kiro", user: response["userInfo"]["userId"].stringValue
            ?? response["userInfo"]["email"].stringValue, workspace: nil)
        quota.label = response["userInfo"]["email"].stringValue
        var incomplete = false
        var ids = Set<String>()
        func add(_ value: ProviderJSON, id: String, label: String, reset: Date?) {
            guard let used = (value["currentUsageWithPrecision"].numberValue ?? value["currentUsage"].numberValue),
                  let limit = (value["usageLimitWithPrecision"].numberValue ?? value["usageLimit"].numberValue),
                  used.isFinite, limit.isFinite, used >= 0, limit > 0, limit < 999999, ids.insert(id).inserted else {
                incomplete = true; return
            }
            quota.windows.append(.init(id: id, label: label, remaining: max(0, 100 - used / limit * 100), reset: reset,
                amounts: QuotaAmounts(used: used, limit: limit, unit: "credits")))
        }
        for item in breakdowns where item["resourceType"].stringValue == "CREDIT" {
            let reset = date(item["nextDateReset"]) ?? date(response["nextDateReset"])
            add(item, id: "kiro:credits", label: L10n.text("套餐额度", "Plan credits"), reset: reset)
            let trial = item["freeTrialInfo"]
            if trial["freeTrialStatus"].stringValue == "ACTIVE", let expiry = date(trial["freeTrialExpiry"]), expiry > now {
                add(trial, id: "kiro:trial", label: L10n.text("试用赠送", "Trial credits"), reset: expiry)
            }
            for (index, bonus) in (item["bonuses"].arrayValue ?? []).enumerated() {
                guard ["ACTIVE", "EXHAUSTED"].contains(bonus["status"].stringValue ?? "") else { continue }
                let expiry = date(bonus["expiresAt"])
                guard expiry.map({ $0 > now }) ?? true else { continue }
                let key = bonus["bonusId"].stringValue ?? "\(bonus["displayName"].stringValue ?? "bonus"):\(expiry?.timeIntervalSince1970 ?? 0):\(index)"
                add(bonus, id: "kiro:bonus:" + RecordCoding.hash([key]), label: bonus["displayName"].stringValue ?? L10n.text("赠送额度", "Bonus credits"), reset: expiry)
            }
            for (index, extra) in (item["overageCredits"].arrayValue ?? []).enumerated() {
                let expiry = date(extra["expiresAt"])
                guard expiry.map({ $0 > now }) ?? true else { continue }
                add(extra, id: "kiro:add-on:\(expiry?.timeIntervalSince1970 ?? 0):\(index)",
                    label: L10n.text("加购额度", "Add-on credits"), reset: expiry)
            }
        }
        quota.quotaWindowIDs = Set(quota.windows.map(\.id))
        if quota.windows.isEmpty || incomplete {
            quota.notice = L10n.text("部分 Kiro credits 未返回有效限额或已用量，未计入统计", "Some Kiro credits lack a valid limit or usage and are not included")
        }
        return quota
    }

    private static func date(_ value: ProviderJSON) -> Date? {
        if let seconds = value.numberValue, seconds.isFinite, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        return DateParsing.internet(value.stringValue)
    }
}
