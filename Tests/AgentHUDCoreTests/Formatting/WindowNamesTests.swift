import XCTest
@testable import AgentHUDCore

/// Every quota window's full and short name in both languages, as its provider builds it from the service's answer.
final class WindowNamesTests: XCTestCase {
    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    private func json(_ text: String) throws -> ProviderJSON { try .read(Data(text.utf8)) }

    /// Builds the windows in Chinese and in English and compares their (full, short) names.
    private func assertNames(_ name: String, zh: [(String, String)], en: [(String, String)],
                             file: StaticString = #filePath, line: UInt = #line, _ build: () throws -> [(String, String)]) rethrows {
        for (language, expected) in [(AppLanguage.zhHans, zh), (.en, en)] {
            L10n.setLanguage(language)
            let names = try build()
            XCTAssertEqual(names.map { $0.0 }, expected.map { $0.0 }, "\(name), full, \(language)", file: file, line: line)
            XCTAssertEqual(names.map { $0.1 }, expected.map { $0.1 }, "\(name), short, \(language)", file: file, line: line)
        }
    }

    private func quota(_ windows: [ProviderQuota.Window]) -> [(String, String)] { windows.map { ($0.label, $0.shortLabel ?? $0.label) } }

    private func codex(_ text: String) throws -> [(String, String)] {
        try JSONDecoder().decode(CodexRateLimits.self, from: Data(text.utf8)).rows.map { ($0.label, $0.descriptor.shortName) }
    }

    func testClaudeWindowsAreNamedAsAnthropicNamesThem() {
        let usage = ClaudeUsage(fiveHour: .init(utilizationPct: 1, resetsAt: nil), sevenDay: .init(utilizationPct: 1, resetsAt: nil),
                                modelWeekly: ["fable": .init(utilizationPct: 1, resetsAt: nil)])
        assertNames("Claude", zh: [("当前会话", "5h"), ("每周限制 · 所有模型", "每周"), ("每周限制 · Fable", "Fable")],
                    en: [("Current session", "5h"), ("Weekly limit · All models", "Weekly"), ("Weekly limit · Fable", "Fable")]) {
            usage.rows.map { ($0.descriptor.name, $0.descriptor.shortName) }
        }
        let placeholder = AgentDescriptor(id: "codex", vendor: "Codex", model: "Desktop / CLI", source: "", enabled: true)
        assertNames("a placeholder row of earlier versions", zh: [("账户额度", "额度")], en: [("Account quota", "Quota")]) {
            [(placeholder.name, placeholder.shortName)]
        }
    }

    func testCodexWindowsAreNamedAsCodexsOwnClientNamesThem() throws {
        try assertNames("5 hours and a week", zh: [("5 小时额度", "5h"), ("每周额度", "每周")], en: [("5h limit", "5h"), ("Weekly limit", "Weekly")]) {
            try codex(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":1,"windowDurationMins":300},"secondary":{"usedPercent":1,"windowDurationMins":10080}}}}"#)
        }
        try assertNames("a weekly-only plan", zh: [("每周额度", "每周")], en: [("Weekly limit", "Weekly")]) {
            try codex(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":1,"windowDurationMins":10080}}}}"#)
        }
        try assertNames("a named bucket with two windows, and one with one",
                        zh: [("Luna Reserve · 每周额度", "Reserve"), ("GPT-5.3-Codex-Spark · 5 小时额度", "Spark 5h"), ("GPT-5.3-Codex-Spark · 每周额度", "Spark 每周")],
                        en: [("Luna Reserve · Weekly limit", "Reserve"), ("GPT-5.3-Codex-Spark · 5h limit", "Spark 5h"), ("GPT-5.3-Codex-Spark · Weekly limit", "Spark 7d")]) {
            try codex(#"{"rateLimitsByLimitId":{"spark":{"limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":1,"windowDurationMins":300},"secondary":{"usedPercent":1,"windowDurationMins":10080}},"base_model_inference":{"limitName":"gpt-reserve","primary":{"usedPercent":1,"windowDurationMins":10080}}}}"#)
        }
        try assertNames("windows without a length", zh: [("用量额度", "额度"), ("次要用量额度", "次要额度")],
                        en: [("Usage limit", "Usage"), ("Secondary usage limit", "Secondary")]) {
            try codex(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":1},"secondary":{"usedPercent":1}}}}"#)
        }
        try assertNames("a day and a month", zh: [("每日额度", "每日"), ("每月额度", "每月")], en: [("Daily limit", "Daily"), ("Monthly limit", "Monthly")]) {
            try codex(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":1,"windowDurationMins":1440},"secondary":{"usedPercent":1,"windowDurationMins":43200}}}}"#)
        }
        try assertNames("a year, and lengths within 5 %", zh: [("每年额度", "每年"), ("5 小时额度", "5h")], en: [("Annual limit", "Annual"), ("5h limit", "5h")]) {
            try codex(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":1,"windowDurationMins":525600},"secondary":{"usedPercent":1,"windowDurationMins":290}}}}"#)
        }
        try assertNames("any other length", zh: [("3 小时额度", "3h"), ("90 分钟额度", "90m")], en: [("3h limit", "3h"), ("90m limit", "90m")]) {
            try codex(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":1,"windowDurationMins":180},"secondary":{"usedPercent":1,"windowDurationMins":90}}}}"#)
        }
        try assertNames("two buckets whose words read alike keep their full names",
                        zh: [("Spark · 5 小时额度", "Spark · 5 小时额度"), ("GPT-5.4-Codex-Spark · 5 小时额度", "GPT-5.4-Codex-Spark · 5 小时额度")],
                        en: [("Spark · 5h limit", "Spark · 5h limit"), ("GPT-5.4-Codex-Spark · 5h limit", "GPT-5.4-Codex-Spark · 5h limit")]) {
            try codex(#"{"rateLimitsByLimitId":{"a":{"limitName":"Spark","primary":{"usedPercent":1,"windowDurationMins":300}},"b":{"limitName":"GPT-5.4-Codex-Spark","primary":{"usedPercent":1,"windowDurationMins":300}}}}"#)
        }
    }

    func testCursorWindowsAreNamedAsCursorNamesThem() throws {
        let answer = try json(#"{"membershipType":"pro","individualUsage":{"plan":{"enabled":true,"totalPercentUsed":10,"autoPercentUsed":20,"apiPercentUsed":30},"overall":{"enabled":true,"used":10,"limit":100},"onDemand":{"enabled":true,"used":5,"limit":50}},"teamUsage":{"pooled":{"enabled":true,"used":1,"limit":10}}}"#)
        try assertNames("Cursor",
                        zh: [("包含用量", "包含用量"), ("Cursor 模型", "第一方模型"), ("其他模型", "第三方模型"), ("个人支出限额", "支出限额"),
                             ("共享用量", "共享用量"), ("按需用量", "按需用量")],
                        en: [("Included usage", "Included"), ("Cursor Models", "First-party"), ("Other Models", "Third-party"),
                             ("Individual spending limit", "Spend limit"), ("Pooled usage", "Pooled"), ("On-demand usage", "On-demand")]) {
            quota(try CursorClient.parseQuota(answer).windows)
        }
    }

    func testGrokWindowsAreNamedByTheirPeriod() throws {
        func answer(_ period: String) throws -> ProviderJSON {
            try json(#"{"config":{"creditUsagePercent":10,"currentPeriod":{"type":"\#(period)"},"onDemandCap":{"val":100},"onDemandUsed":{"val":10}}}"#)
        }
        try assertNames("Grok", zh: [("每周用量额度", "每周"), ("额外用量", "额外用量"), ("每月用量额度", "每月"), ("用量额度", "用量")],
                        en: [("Weekly usage limit", "Weekly"), ("Extra usage", "Extra"), ("Monthly usage limit", "Monthly"), ("Usage limit", "Usage")]) {
            quota(try GrokClient.parse(answer("USAGE_PERIOD_TYPE_WEEKLY")).windows)
                + quota(Array(try GrokClient.parse(answer("USAGE_PERIOD_TYPE_MONTHLY")).windows.prefix(1)))
                + quota(Array(try GrokClient.parse(answer("")).windows.prefix(1)))
        }
    }

    func testCopilotWindowsAreNamedAsGitHubNamesThem() throws {
        let requests = try json(#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":150,"unlimited":false},"chat":{"entitlement":50,"remaining":40,"unlimited":false},"completions":{"entitlement":2000,"remaining":1000,"unlimited":false},"agent":{"entitlement":10,"remaining":5,"unlimited":false},"code_review":{"entitlement":10,"remaining":5,"unlimited":false}}}"#)
        try assertNames("request-based billing",
                        zh: [("高级请求", "高级请求"), ("聊天消息", "聊天消息"), ("代码补全", "代码补全"), ("Agent", "Agent"), ("Code Review", "Code")],
                        en: [("Premium requests", "Premium"), ("Chat messages", "Chat"), ("Code completions", "Completions"), ("Agent", "Agent"),
                             ("Code Review", "Code")]) {
            quota(try CopilotClient.parse(requests).windows)
        }
        let credits = try json(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":1500,"remaining":1200,"unlimited":false}}}"#)
        try assertNames("usage-based billing", zh: [("AI credits", "额度")], en: [("AI credits", "Credits")]) {
            quota(try CopilotClient.parse(credits).windows)
        }
    }

    func testAntigravityWindowsAreNamedByGroupAndPeriod() throws {
        let gemini = #"{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","displayName":"Five Hour Limit","remainingFraction":0.5},{"bucketId":"gemini-7d","displayName":"Weekly Limit","remainingFraction":0.75}]}"#
        let others = #"{"displayName":"Claude and GPT models","buckets":[{"bucketId":"third-party-5h","displayName":"Five Hour Limit","remainingFraction":1},{"bucketId":"third-party-7d","displayName":"Weekly Limit","remainingFraction":1}]}"#
        let one = try json(#"{"groups":[\#(gemini)]}"#), several = try json(#"{"groups":[\#(gemini),\#(others)]}"#)
        try assertNames("one group", zh: [("Gemini Models · Five Hour Limit", "5h"), ("Gemini Models · Weekly Limit", "每周")],
                        en: [("Gemini Models · Five Hour Limit", "5h"), ("Gemini Models · Weekly Limit", "Weekly")]) {
            quota(try AntigravityClient.summary(one).windows)
        }
        try assertNames("several groups",
                        zh: [("Gemini Models · Five Hour Limit", "Gemini 5h"), ("Gemini Models · Weekly Limit", "Gemini 每周"),
                             ("Claude and GPT models · Five Hour Limit", "第三方 5h"), ("Claude and GPT models · Weekly Limit", "第三方 每周")],
                        en: [("Gemini Models · Five Hour Limit", "Gemini 5h"), ("Gemini Models · Weekly Limit", "Gemini 7d"),
                             ("Claude and GPT models · Five Hour Limit", "3rd-party 5h"), ("Claude and GPT models · Weekly Limit", "3rd-party 7d")]) {
            quota(try AntigravityClient.summary(several).windows)
        }
        let status = try json(#"{"userStatus":{"cascadeModelConfigData":{"clientModelConfigs":[{"label":"Gemini 3 Pro","modelOrAlias":{"model":"M1"},"quotaInfo":{"remainingFraction":0.5}},{"label":"Claude Sonnet 5","modelOrAlias":{"model":"M2"},"quotaInfo":{"remainingFraction":0.5}},{"label":"Kimi K3","modelOrAlias":{"model":"M3"},"quotaInfo":{"remainingFraction":0.5}}]}}}"#)
        try assertNames("the earlier per-model quota", zh: [("Kimi K3", "K3"), ("Claude and GPT models", "第三方"), ("Gemini Models", "Gemini")],
                        en: [("Kimi K3", "K3"), ("Claude and GPT models", "3rd-party"), ("Gemini Models", "Gemini")]) {
            quota(try AntigravityClient.userStatus(status).windows)
        }
    }

    func testPoolWindowsAreNamedByPeriodAndPlan() throws {
        let kimi = OpenAgentCredentials.credential(.kimi, token: "fixture-key", client: "Kimi")
        let now = Date(timeIntervalSince1970: 1_788_800_000)
        let current = try json(#"{"usages":{"limit_5h":{"used_ratio":0.25},"limit_7d":{"used_ratio":0.2},"limit_month_total":{"used_ratio":0.4}},"membership":{"level":"Allegretto"}}"#)
        try assertNames("Kimi",
                        zh: [("5 小时额度 · Allegretto", "5h"), ("周额度 · Allegretto", "每周"), ("月总额度 · Allegretto", "每月")],
                        en: [("5-hour quota · Allegretto", "5h"), ("Weekly quota · Allegretto", "Weekly"), ("Monthly total quota · Allegretto", "Monthly")]) {
            quota(try OpenAgentQuotaClient.parse(current, credential: kimi, now: now).windows)
        }
        let limits = try json(#"{"limits":[{"window":{"duration":3,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"100","used":"10"}}]}"#)
        try assertNames("Kimi, another length", zh: [("3 小时额度", "3h")], en: [("3-hour quota", "3h")]) {
            quota(try OpenAgentQuotaClient.parse(limits, credential: kimi, now: now).windows)
        }
        let glm = OpenAgentCredentials.credential(.glmChina, token: "fixture-key", client: "Claude")
        func limitsJSON(_ limits: String) throws -> ProviderJSON {
            try json(#"{"success":true,"code":200,"data":{"planName":"Pro","limits":[\#(limits)]}}"#)
        }
        let credit = #"{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":25},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":25}"#
        let tokens = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":25},{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":5},{"type":"TOKENS_LIMIT","unit":9,"number":1,"percentage":5}"#
        try assertNames("GLM credit plans", zh: [("5 小时积分 · Pro", "5h"), ("每周积分 · Pro", "每周")],
                        en: [("5-hour credits · Pro", "5h"), ("Weekly credits · Pro", "Weekly")]) {
            quota(try OpenAgentQuotaClient.parse(limitsJSON(credit), credential: glm, now: now).windows)
        }
        try assertNames("GLM's older plans",
                        zh: [("每 5 小时限额 · Pro", "5h"), ("每周限额 · Pro", "每周"), ("MCP 每月用量 · Pro", "MCP"), ("TOKENS_LIMIT · Pro", "Tokens")],
                        en: [("5-hour limit · Pro", "5h"), ("Weekly limit · Pro", "Weekly"), ("MCP usage (1 month) · Pro", "MCP"), ("TOKENS_LIMIT · Pro", "Tokens")]) {
            quota(try OpenAgentQuotaClient.parse(limitsJSON(tokens), credential: glm, now: now).windows)
        }
        let both = #"{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25},{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":25},{"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":25}"#
        try assertNames("GLM tokens and credits of one length", zh: [("每 5 小时限额 · Pro", "Tokens 5h"), ("5 小时积分 · Pro", "Credits 5h"), ("每周积分 · Pro", "每周")],
                        en: [("5-hour limit · Pro", "Tokens 5h"), ("5-hour credits · Pro", "Credits 5h"), ("Weekly credits · Pro", "Weekly")]) {
            quota(try OpenAgentQuotaClient.parse(limitsJSON(both), credential: glm, now: now).windows)
        }
        let go = OpenAgentCredentials.credential(.go, token: "fixture-key", client: "OpenCode")
        let usage = try json(#"{"usage":{"rolling":{"percent":1},"weekly":{"percent":1},"monthly":{"percent":1}}}"#)
        try assertNames("OpenCode Go", zh: [("5 小时限制", "5h"), ("每周限制", "每周"), ("每月限制", "每月")],
                        en: [("5-hour limit", "5h"), ("Weekly limit", "Weekly"), ("Monthly limit", "Monthly")]) {
            quota(try OpenAgentQuotaClient.parse(usage, credential: go, now: now).windows)
        }
    }

    func testPeriodsWordsAndClashes() {
        let periods: [(Double?, WindowNames.Period?)] = [
            (18000, .fiveHours), (285 * 60, .fiveHours), (284 * 60, .minutes(284)), (86400, .day), (604800, .week), (30 * 86400, .month),
            (365 * 86400, .year), (2 * 86400, .days(2)), (3 * 3600, .hours(3)), (90 * 60, .minutes(90)), (30, nil), (nil, nil),
        ]
        for (seconds, period) in periods { XCTAssertEqual(WindowNames.Period(seconds: seconds), period, "\(String(describing: seconds))") }
        XCTAssertEqual(["GPT-5.3-Codex-Spark", "Luna Reserve", "gpt_reserve", "GPT-5", "Claude 4"].map(WindowNames.word),
                       ["Spark", "Reserve", "reserve", "GPT-5", "Claude 4"], "a name with nothing left keeps itself")
        XCTAssertEqual(["Fable", "Code Review", "Mythos preview"].map(WindowNames.leading), ["Fable", "Code", "Mythos"])
        XCTAssertEqual(WindowNames.distinct(["5h", "5h", "Weekly", nil]), [nil, nil, "Weekly", nil])
    }
}
