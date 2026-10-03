import XCTest
@testable import AgentHUDCore

final class ModelCatalogTests: XCTestCase {
    /// The id an open agent's provider gives a model it called through `provider`.
    private func consumer(_ client: OpenAgentSource, _ model: String, via provider: String) -> String {
        var session = OpenAgentSession(id: "", client: client, title: "", path: "")
        session.setModel(model, provider: provider)
        return session.currentModel!.id
    }

    func testListPricesFollowTheModelAndThePromptLength() {
        XCTAssertEqual(ModelCatalog.name(of: "claude-model:claude-haiku-4-5-20251001"), "claude-haiku-4-5", "a dated snapshot prices like its alias")
        XCTAssertEqual(ModelCatalog.name(of: "cursor-model:auto"), "auto")
        XCTAssertNil(ModelCatalog.model(for: "cursor-model:auto"), "a client's own routing name has no list price")
        XCTAssertNil(ModelCatalog.model(for: "opencode-model:openai/gpt-5.5#route"), "a gateway sells the model at its own price")
        XCTAssertNil(ModelCatalog.model(for: "opencode-model:anthropic/claude-opus-4.6#route"))
        XCTAssertNil(ModelCatalog.cost(agentId: "codex-model:codex-auto-review", kinds: TokenKinds(input: 1)))
        // Fresh input, cache reads and output at $10, $1 and $50 per million, reasoning billed as output.
        XCTAssertEqual(ModelCatalog.cost(agentId: "codex-model:gpt-6-astra",
                                         kinds: TokenKinds(input: 100_000, reasoning: 400, output: 600, cacheRead: 100_000)),
                       .init(amount: Decimal(string: "1.15")!, currency: "USD"))
        // A prompt over 272K tokens costs twice the input and cache rates and one and a half times the output rate.
        XCTAssertEqual(ModelCatalog.cost(agentId: "codex-model:gpt-6-astra",
                                         kinds: TokenKinds(input: 100_000, output: 1_000, cacheRead: 200_000))?.amount, Decimal(string: "2.475"))
        // Claude Code's one-hour cache writes cost twice the input rate.
        XCTAssertEqual(ModelCatalog.cost(agentId: "claude-model:claude-fable-5-1", kinds: TokenKinds(cacheWrite: 1_000_000, cacheRead: 1_000_000))?.amount,
                       Decimal(string: "20.25"))
    }

    /// GPT-6 and GPT-5.6 bill cache writes at 1.25 times the input rate, twice that in a prompt over 272K tokens; Claude
    /// Sonnet 5.5 is listed at Sonnet 5's rates with a 1M window.
    func testTheNewestModelsCarryTheirListPrices() {
        XCTAssertEqual(ModelCatalog.cost(agentId: "codex-model:gpt-6.1-sol",
                                         kinds: TokenKinds(cacheWrite: 100_000, output: 1_000, cacheRead: 100_000))?.amount, Decimal(string: "0.27"))
        XCTAssertEqual(ModelCatalog.cost(agentId: "codex-model:gpt-6.1-sol",
                                         kinds: TokenKinds(cacheWrite: 100_000, input: 100_000, output: 1_000, cacheRead: 100_000))?.amount,
                       Decimal(string: "0.935"))
        XCTAssertEqual(ModelCatalog.cost(agentId: "codex-model:gpt-5.4-mini", kinds: TokenKinds(input: 300_000))?.amount, Decimal(string: "0.225"),
                       "a model without a long-context list keeps its rates")
        XCTAssertEqual(ModelCatalog.cost(agentId: "claude-model:claude-sonnet-5-5",
                                         kinds: TokenKinds(cacheWrite: 1_000_000, input: 1_000_000, output: 100_000, cacheRead: 1_000_000))?.amount,
                       Decimal(string: "7.2"))
        XCTAssertEqual(ModelCatalog.contextWindow(agentId: "claude-model:claude-sonnet-5-5", reported: nil, largestSeen: nil), 1_000_000)
    }

    func testSummedCountsArePricedAtBaseRatesWithTheUnpricedModelsNamed() throws {
        // Two 200K prompts add up past 272K, yet neither was a long one.
        let astra = TokenKinds(input: 400_000, output: 1_000)
        XCTAssertEqual(ModelCatalog.cost(agentId: "codex-model:gpt-6-astra", summed: astra)?.amount, Decimal(string: "4.05"))
        let cost = try XCTUnwrap(ModelCatalog.cost(of: ["codex-model:gpt-6-astra": astra, "cursor-model:auto": TokenKinds(input: 5),
                                                        "claude-model:claude-next": TokenKinds()]))
        XCTAssertEqual(cost.amounts, ["USD": Decimal(string: "4.05")!])
        XCTAssertEqual(cost.unpriced, ["cursor-model:auto"], "a model without tokens is not named")
        XCTAssertNil(ModelCatalog.cost(of: ["cursor-model:auto": TokenKinds(input: 5)]))
        XCTAssertEqual(TokenDimensions.fresh.masking(TokenKinds(input: 1, cacheRead: 9)), TokenKinds(input: 1))
        XCTAssertEqual(TokenKinds(cacheWrite: 10, input: 10, cacheRead: 80).cacheHitRate, 0.8)
        XCTAssertNil(TokenKinds(input: 10, output: 5).cacheHitRate, "a log that counts no cache says nothing about hits")
    }

    func testEachPlatformPricesInItsOwnCurrencyAndTiers() {
        let short = TokenKinds(input: 10_000, output: 1_000), long = TokenKinds(input: 40_000, output: 1_000)
        // BigModel charges more from 32K prompt tokens; Z.ai has one rate.
        XCTAssertEqual(ModelCatalog.cost(agentId: "claude-model:glm-5.1", kinds: short, region: .china),
                       .init(amount: Decimal(string: "0.084")!, currency: "CNY"))
        XCTAssertEqual(ModelCatalog.cost(agentId: "claude-model:glm-5.1", kinds: long, region: .china)?.amount, Decimal(string: "0.348"))
        XCTAssertEqual(ModelCatalog.cost(agentId: consumer(.opencode, "glm-5.1", via: "zai"), kinds: short),
                       .init(amount: Decimal(string: "0.0184")!, currency: "USD"))
        XCTAssertNil(ModelCatalog.cost(agentId: "claude-model:glm-5-turbo", kinds: short), "a model one platform does not sell has no price there")
        XCTAssertNil(ModelCatalog.cost(agentId: "claude-model:glm-4.6", kinds: short, region: .china))
        XCTAssertEqual(ModelCatalog.cost(agentId: "claude-model:claude-haiku-4-5", kinds: TokenKinds(input: 1_000_000), region: .china),
                       .init(amount: 1, currency: "USD"), "a vendor with one list charges it everywhere")
        // Alibaba's tiers follow the prompt; a dated snapshot prices like its model.
        XCTAssertEqual(ModelCatalog.cost(agentId: "qwen-model:qwen3-coder-plus-2025-09-23", kinds: TokenKinds(input: 50_000, output: 1_000))?.amount,
                       Decimal(string: "0.099"))
        // xAI doubles every token of a call from 200K prompt tokens.
        XCTAssertEqual(ModelCatalog.cost(agentId: "grok-model:grok-4.6", kinds: TokenKinds(input: 200_000))?.amount, Decimal(string: "0.8"))
        XCTAssertEqual(ModelCatalog.cost(agentId: "grok-model:grok-code-fast-1", summed: TokenKinds(input: 1_000_000))?.amount, 1,
                       "a retired name prices as the model that serves it")
    }

    func testAnOpenAgentsCallIsPricedOnlyThroughTheVendorsOwnService() {
        let million = TokenKinds(input: 1_000_000)
        XCTAssertEqual(ModelCatalog.cost(agentId: consumer(.pi, "claude-fable-5[1m]", via: "anthropic"), kinds: million)?.amount, 10)
        XCTAssertEqual(ModelCatalog.cost(agentId: consumer(.opencode, "glm-5.1", via: "zhipuai-coding-plan"), kinds: million, region: .china)?.currency, "CNY")
        for route in ["opencode", "opencode-go", "openrouter", "azure", "google-vertex-anthropic", "vibearound-custom-anthropic"] {
            XCTAssertNil(ModelCatalog.cost(agentId: consumer(.opencode, "claude-fable-5", via: route), kinds: million), "\(route) sets its own price")
        }
        XCTAssertEqual(ModelCatalog.contextWindow(agentId: consumer(.opencode, "claude-fable-5", via: "opencode"), reported: nil, largestSeen: nil),
                       1_000_000, "the model's window is the same whoever serves it")
    }

    func testDeepSeekChargesTwiceInBeijingWorkingHours() throws {
        let formatter = ISO8601DateFormatter()
        for (instant, peak) in [("2026-09-07T00:59:59Z", false), ("2026-09-07T01:00:00Z", true), ("2026-09-07T04:00:00Z", false),
                                ("2026-09-07T06:00:00Z", true), ("2026-09-07T10:00:00Z", false), ("2026-09-12T02:00:00Z", false)] {
            XCTAssertEqual(ModelCatalog.isPeak(formatter.date(from: instant)!), peak, instant)
        }
        let friday = formatter.date(from: "2026-09-25T02:00:00Z")!, saturday = formatter.date(from: "2026-09-26T02:00:00Z")!
        let million = TokenKinds(input: 1_000_000)
        XCTAssertEqual(ModelCatalog.cost(agentId: "claude-model:deepseek-v4-pro", kinds: million, region: .china, at: saturday)?.amount, Decimal(string: "4.5"))
        XCTAssertEqual(ModelCatalog.cost(agentId: "claude-model:deepseek-v4-pro", kinds: million, region: .china, at: friday)?.amount, 9)
        XCTAssertEqual(ModelCatalog.cost(agentId: "deepseek-model:deepseek-v4-flash", kinds: million, at: saturday),
                       .init(amount: Decimal(string: "0.15")!, currency: "USD"), "the retired Flash name bills at Flash's rate")
        // Counted usage splits its peak part out; each currency adds up on its own.
        let cost = try XCTUnwrap(ModelCatalog.cost(of: ["claude-model:deepseek-v4-pro": TokenKinds(input: 2_000_000),
                                                        "codex-model:gpt-6-sol": TokenKinds(input: 1_000_000)],
                                                   peak: ["claude-model:deepseek-v4-pro": million, "codex-model:gpt-6-sol": million],
                                                   region: { $0.hasPrefix("claude") ? .china : .international }))
        XCTAssertEqual(cost.amounts, ["CNY": Decimal(string: "13.5")!, "USD": 2])
        XCTAssertTrue(cost.text.hasPrefix("≈$"), cost.text)
    }

    func testCallsArePricedOnThePlatformTheirClientReaches() {
        let deepSeek = APIBilling(vendor: "DeepSeek", balances: [.init(currency: "CNY", total: 8, granted: 0, toppedUp: 8)],
                                  isAvailable: true, updatedAt: nil, costs: [], notice: nil)
        let regions = PriceRegions(services: [
            AgentService(client: "Claude", provider: "GLM", product: .plan, region: .china),
            AgentService(client: "OpenCode", provider: "GLM", product: .api, region: .international),
            AgentService(client: "Pi", provider: "Kimi", product: .plan, region: .china),
            AgentService(client: "Pi", provider: "Moonshot", product: .api, region: .international),
            AgentService(client: "OpenCode", provider: "Anthropic", product: .api),
        ], billing: [deepSeek])
        XCTAssertEqual(regions.region(for: "claude-model:glm-5.1"), .china, "Claude Code signed in to BigModel's plan")
        XCTAssertEqual(regions.region(for: consumer(.opencode, "glm-5.1", via: "zai")), .international)
        XCTAssertEqual(regions.region(for: "glm-model:glm-5.1"), .international, "clients that disagree name no platform for others")
        XCTAssertEqual(regions.region(for: consumer(.pi, "kimi-k3", via: "kimi-coding")), .international, "one client on both platforms is priced abroad")
        XCTAssertEqual(regions.region(for: "claude-model:deepseek-v4-pro"), .china, "a yuan account bills DeepSeek in yuan")
        XCTAssertEqual(regions.region(for: "claude-model:claude-opus-5"), .international)
        XCTAssertEqual(regions.region(for: "cursor-model:auto"), .international)
    }

    /// A bucket of the Tokens page, priced one kind at a time for a host that publishes the amounts.
    func testABucketIsPricedKindByKindOnItsClientsPlatform() throws {
        let formatter = ISO8601DateFormatter()
        let friday = formatter.date(from: "2026-09-25T02:00:00Z")!, saturday = formatter.date(from: "2026-09-26T02:00:00Z")!
        let deepSeek = APIBilling(vendor: "DeepSeek", balances: [.init(currency: "CNY", total: 8, granted: 0, toppedUp: 8)],
                                  isAvailable: true, updatedAt: nil, costs: [], notice: nil)
        let regions = PriceRegions(services: [
            AgentService(client: "Claude", provider: "GLM", product: .plan, region: .china),
            AgentService(client: "OpenCode", provider: "GLM", product: .api, region: .international),
        ], billing: [deepSeek])
        // In 3M with 1M cache writes, out 1.5M with 0.5M reasoning, 1M cache reads: every kind but input once.
        func bucket(_ agentId: String, at start: Date = saturday, cacheRead: Int = 1_000_000) -> UsageBucket {
            UsageBucket(start: start, agentId: agentId, tokensIn: 3_000_000, tokensOut: 1_500_000, cacheReadTokens: cacheRead,
                        cacheWriteTokens: 1_000_000, reasoningTokens: 500_000)
        }
        let amounts: (String...) -> [TokenKind: Decimal] = { values in
            Dictionary(uniqueKeysWithValues: zip([TokenKind.input, .cacheWrite, .reasoning, .output, .cacheRead], values.map { Decimal(string: $0)! }))
        }
        let cases: [(String, UsageBucket, ModelCatalog.KindCosts?)] = [
            // BigModel's list in yuan, at its base rates though the sum passes its 32K tier; reasoning at the output rate.
            ("a client on the China platform", bucket("claude-model:glm-5.1"),
             .init(currency: "CNY", amounts: amounts("12", "6", "12", "24", "1.3"))),
            ("a client abroad", bucket(consumer(.opencode, "glm-5.1", via: "zai")),
             .init(currency: "USD", amounts: amounts("2.8", "1.4", "2.2", "4.4", "0.26"))),
            ("DeepSeek off-peak, in its account's yuan", bucket("claude-model:deepseek-v4-pro"),
             .init(currency: "CNY", amounts: amounts("9", "4.5", "6.75", "13.5", "0.15"))),
            ("DeepSeek in Beijing working hours", bucket("claude-model:deepseek-v4-pro", at: friday),
             .init(currency: "CNY", amounts: amounts("18", "9", "13.5", "27", "0.3"))),
            ("a kind without tokens is left out", bucket("claude-model:glm-5.1", cacheRead: 0),
             .init(currency: "CNY", amounts: amounts("12", "6", "12", "24"))),
            ("a model without a list price", bucket("cursor-model:auto"), nil),
            ("a model its platform does not sell", bucket(consumer(.opencode, "glm-5-turbo", via: "zai")), nil),
        ]
        for (name, bucket, expected) in cases {
            let cost = ModelCatalog.cost(of: bucket, regions: regions)
            XCTAssertEqual(cost, expected, name)
            // The kinds add up to the bucket's price as the Tokens page counts it.
            XCTAssertEqual(cost?.total, ModelCatalog.cost(agentId: bucket.agentId, summed: bucket.kinds, region: regions.region(for: bucket.agentId),
                                                          at: bucket.start)?.amount, name)
        }
    }

    /// Every consumer is named from its id alone, by the one function the providers and a host's missing ids share.
    func testConsumersAreNamedFromTheirIdsAlone() {
        let cases: [(id: String, name: String)] = [
            // Kimi Code logs its plan model under its route; the plan model is Kimi's product.
            ("kimi-model:kimi-code/kimi-for-coding#kimi-code", "Kimi For Coding"),
            ("kimi-model:kimi-for-coding#kimi-code", "Kimi For Coding"),
            ("kimi-model:kimi-code/real-model#kimi-code", "real-model"),
            ("kimi-model:kimi-code/kimi-for-coding-highspeed#kimi-code", "kimi-for-coding-highspeed"),
            ("kimi-model:#kimi-code", "Unknown · kimi-code"),
            (consumer(.opencode, "kimi-for-coding", via: "kimi-for-coding"), "Kimi For Coding"),
            (consumer(.pi, "kimi-for-coding", via: "kimi-coding"), "Kimi For Coding"),
            // A route that is not the product's own service, or does not show in the name, stays beside it.
            (consumer(.opencode, "kimi-for-coding", via: "openrouter"), "Kimi For Coding · openrouter"),
            (consumer(.opencode, "k3", via: "kimi-for-coding"), "k3 · kimi-for-coding"),
            (consumer(.pi, "kimi-k3", via: "kimi-coding"), "kimi-k3 · kimi-coding"),
            (consumer(.opencode, "kimi-k2", via: "moonshotai"), "kimi-k2 · moonshotai"),
            (consumer(.opencode, "glm-5.1", via: "zhipuai-coding-plan"), "glm-5.1 · zhipuai-coding-plan"),
            (consumer(.pi, "claude-fable-5[1m]", via: "anthropic"), "claude-fable-5[1m] · anthropic"),
            ("opencode-model:openai/gpt-5.5#route", "openai/gpt-5.5 · route"),
            ("opencode-model:anthropic/claude-opus-4.6#anthropic", "claude-opus-4.6"),
            ("pi-model:gpt-5.6-luna#", "gpt-5.6-luna"),
            ("pi-model:new-a", "new-a"),
            // Other clients' consumers read as their providers name them.
            ("claude-model:claude-opus-4-5-20251101", "Opus 4.5"),
            ("claude-model:claude-fable-5-1[1m]", "Fable 5.1"),
            ("claude-model:kimi-for-coding", "Kimi For Coding"),
            ("claude-model:glm-5.1", "glm-5.1"),
            ("codex-model:gpt-6.1-sol", "gpt-6.1-sol"),
            ("deepseek-model:deepseek-v4-pro", "deepseek-v4-pro"),
            ("cursor-model:auto", "auto"),
            ("claude-session", "claude-session"),
        ]
        for (id, name) in cases { XCTAssertEqual(ModelCatalog.consumerName(of: id), name, id) }
        XCTAssertEqual(DiscoveredModel(modelId: "claude-opus-4-5-20251101", lastSeen: .distantPast).descriptor.name, "Opus 4.5")
    }

    func testContextWindowsComeFromTheLogThenTheCatalogThenWhatTheModelHeld() {
        XCTAssertEqual(ModelCatalog.contextWindow(agentId: "codex-model:gpt-6-astra", reported: 258_400, largestSeen: nil), 258_400)
        XCTAssertEqual(ModelCatalog.contextWindow(agentId: "claude-model:claude-haiku-4-5", reported: nil, largestSeen: 150_000), 200_000)
        XCTAssertEqual(ModelCatalog.contextWindow(agentId: "claude-model:claude-next-1", reported: nil, largestSeen: 150_000), 200_000)
        XCTAssertEqual(ModelCatalog.contextWindow(agentId: "claude-model:claude-next-1", reported: nil, largestSeen: 420_000), 1_000_000)
        XCTAssertNil(ModelCatalog.contextWindow(agentId: "codex-model:gpt-6-astra", reported: nil, largestSeen: 420_000))
        XCTAssertNil(ModelCatalog.contextWindow(agentId: "cursor-model:auto", reported: nil, largestSeen: 420_000))
    }
}
