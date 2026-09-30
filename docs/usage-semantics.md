# Usage semantics

## Overview

How Agent HUD Open counts tokens, names quota windows, colors readings, spaces account requests and keeps readings. The rules apply to every provider and to the desktop, and hosts use the same numbers. Where each client's fields come from is in [providers](providers.md); running and terminal turns are in [session lifecycle](session-lifecycle.md).

## Model

| Kind | Contains |
| --- | --- |
| Cache write | Prompt tokens written to the prompt cache |
| Input | The other new prompt tokens |
| Reasoning | Output spent reasoning or thinking |
| Output | The other output |
| Cache read | Prompt tokens read back from the cache |

The five kinds (`TokenKind`, selected as `TokenDimensions`) are additive and never overlap. Logs count cache writes inside input and reasoning inside output; a log that does not tell them apart puts everything in input and output, and so do events recorded before the ledger split them, until their logs are read again. Charts, the heat map, model shares and the agent cards' token counts follow the selected kinds; the default is every kind but cache reads (`fresh`, shown as excluding cache reads), and `all` adds cache reads. The panel's per-session token figure leaves cache reads out too. The statistics window's Sessions page counts every kind in its rows, sub-agents included, and lists the sessions whose last event is at most seven days old under the day each started on, whatever range its Tokens page shows; those that started before the seven days share one Earlier group, and its Active only switch lists just the sessions active in the last 24 hours. A quota window is one row per window the service reports, with that window's own reset time and period; a reading is the last value of a window, balance or reset-credit count together with its observation time. An account is whose quota a window describes, identified by the provider's own user and workspace ids; a window's row id is the account id followed by the provider's window name (`account:<hash>/codex`).

## Rules

### Percentages, windows and presentation

- Every percentage shown is used, the convention of Claude Code's `/usage`; providers store the remaining share and the desktop converts.
- Rows come from the response, never from a template: `primary` is not assumed to mean 5 hours, and a window the service names by period (minutes, "7d", weekly, monthly, "MCP") keeps that label.
- One account's windows are shown once even when two programs share the account (Codex Desktop and CLI); usage recorded by one client is never duplicated into another client's account, and model token spend is shown separately from quota windows.
- Money keeps its currency and is never converted or turned into a percentage; API-billed clients (DeepSeek) show balance and estimated cost instead of windows, and estimates are labelled as estimates.
- Codex reset credits show the service's `availableCount`; the per-credit expiry list is supplementary and never derives the count.
- A missing reading is "—", not 0; zero is shown only when the service reported zero.
- Tokens are never converted into quota, and an unavailable quota is never inferred from token counts. Claude Code's session share is its share of the tokens in the current 5 h window times the window's utilization, given only to sessions that spent tokens in that window; every other session shows "—".
- One API response is counted once whatever the log layout; copies of one event from two files or two Macs merge, and distinct requests with identical counts are kept. Bar buckets are 15 min, 30 min, 1 h or 1 d on local quarter-hour, hour or calendar-day boundaries inside the exact half-open range; empty buckets keep their position and counts stay integers.
- A session's breakdown (`SessionUsage`) is read from the ledger: its own log, or its id for sources read whole, plus its sub-agents' logs: every log under the directory named like its log (Claude Code), and every rollout that names it, directly or through another sub-agent, as the thread that started it (Codex spawned agents and guardians); by kind, model, 15-minute period and turn, with the number of calls. Its totals therefore exceed the session row, which leaves sub-agents out. A session is read again when its counts move or when the ledger has changed any log it is made of, its own or a sub-agent's, since its breakdown was read.
- A turn is a prompt in the session's own log and every call, sub-agents' included, until the next prompt; calls before the first prompt form a turn of their own, a prompt no call followed forms none, and a turn notes whether the client compacted the conversation during it. Claude Code, Codex and DeepSeek Harness logs mark their prompts; sessions of other clients have no turns. A breakdown keeps the newest 200 turns and counts all of them.
- The context is a call's input with cache writes and cache reads: the session's is its latest call's, a turn's its last call's, given only for logs that record every call. The context window is the one the log reports with the call (Codex), else the model's published window; a Claude model runs with 200K or 1M, so one missing from the catalog counts as 200K until this Mac has seen it hold more.
- A list price (`ModelCatalog`) is what calls would cost at the vendor's published API prices, keyed by the model a call named whatever client made it: Anthropic, OpenAI, DeepSeek, xAI, Google, Zhipu, Moonshot, Alibaba, MiniMax and Xiaomi. A promotional price that lasts only a while is left out for the vendor's regular one. A gateway's name for a model (`openai/gpt-5.5`, `anthropic/claude-opus-4.6`) has no list price, since the gateway sets its own, and an OpenCode, Pi or Kimi call is priced only when the provider it names is the vendor's own API or plan, not a gateway such as OpenCode Zen, OpenCode Go or OpenRouter, a cloud such as Azure, Bedrock or Vertex, or a proxy. Input, cache writes (Claude Code's at the one-hour rate it writes with), cache reads and output with reasoning are priced at the tier the call's prompt reaches, and DeepSeek's calls in its peak hours, weekdays 9–12 and 14–18 Beijing time, at twice its off-peak rates. It is an estimate, not a charge. A session's list price is on the international list at off-peak rates, and a call whose model has no list price leaves the session without one.
- Vendors with separate China and international lists (DeepSeek, Zhipu, Moonshot, Alibaba, Xiaomi) are priced on the platform a client reaches (`PriceRegions`): its configured endpoint or plan, or for DeepSeek, which bills one platform in either currency, its account's currency. A client nothing names, or one on both platforms, is priced on the international list. Amounts keep their currency, yuan on a China list and US dollars otherwise, and add up per currency.
- The Tokens page prices the charted range and each period from 15-minute buckets, each model on its client's platform and DeepSeek's peak-hour buckets at its peak rates. A bucket sums calls and says nothing of any one prompt's length, so buckets are priced at the base rates, and a range can come out below its sessions where prompts ran past a tier. Only the selected kinds are priced, and models without a list price are named, not counted. The agent cards follow the order of Settings, rank their models and sessions by tokens of the selected kinds with the international list price breaking ties, and price every kind whatever the selection.
- The periods (`UsagePeriods`) are today from local midnight and the last seven and thirty days, read from the ledger, which keeps 31 days of buckets. The report carries those 31 days for the charts' month, while providers read one week of their own logs.
- The cache hit rate is cache reads against every prompt token: fresh input, cache writes and cache reads. A log that counts no cache at all has none.

### Alert levels

| Reading | OK | Warning | Critical |
| --- | --- | --- | --- |
| Quota window | used < 70% | used ≥ 70% | used ≥ 90% |
| DeepSeek balance in CNY | > 10 | ≤ 10 | ≤ 0 |
| DeepSeek balance in USD | > 2 | ≤ 2 | ≤ 0 |
| Balance in another currency | > 0 | — | ≤ 0 |
| Account reported unavailable | — | — | always |

- The policy is fixed (`AlertPolicy`): nothing is stored, synchronized or configurable. A color describes the resource state of one reading; readings of different windows are never combined into one health score, and a color never indicates task progress.
- The glow shows one segment per enabled window, and one per enabled API account, whose reading shows a level; the others stay out of it, and a paused or hidden glow is grey. An alert's pulse lights the segments of its vendor in that same list.
- A balance follows the rules of a quota window: after a failed read it keeps its last amount on screen without a level and outside the glow, and its card and menu row say why; a balance read in the future has no level either. Every currency climbs one ladder, low at its warning line where it has one and depleted at or below zero, and an account its service marks unavailable is critical whatever its balance. The menu shows a critical balance, like a critical window, in the critical colour.
- A window is exhausted with half a point or less left, for its alerts, its outlook, its row and its cap statistics alike.
- Alerts (`QuotaAlertTracker`): the first reading of a window is a silent baseline; crossing 90% used, running out, a forecast of exhaustion before the reset, and a confirmed reset each notify once. A forecast notifies once per cycle, however often the estimate dips below the reset and back. Readings older than 30 minutes stay visible but generate no alerts.
- A window whose quota reading failed or could not be verified keeps its last reading on screen but has no level, stays out of the glow and raises no alert until a reading succeeds; a notice about the client's local logs or completion hooks, or about something a successful answer left out, is shown as well and holds back none of these.
- A sound reading of the current account keeps its level and its place in the glow however old it grows, since a client nobody is using is read again only when a reset or its work calls for it; only alerts and added usage resets need a reading under 30 minutes old. A reading dated after the Mac's clock has no level and confirms nothing.
- When every source fails to read, the last report stays on screen and every reading in it counts as failed: no window has a level, and each account's header says when it was last read, until a pass reads a source again.
- Only a reading that shows a level enters a calculation: the menu bar's figure, the hover hint on the island and in the menu, the island row's burn rate, projection and token rate, and the windows a reset alert names as still exhausted. Any other reading is shown greyed, with its share used and its reset but without a forecast.
- Added usage resets (`ResetCreditTracker`): a rise in a signed-in account's Codex reset-credit count notifies once, with how many were added; the first reading of an account is a silent baseline, and using a credit or letting one expire is not an event. A reading whose account's or client's read failed or could not be verified, or one older than 30 minutes, confirms nothing; a notice about the client's logs or hooks holds nothing back.
- Every provider reads a window's stored readings from a week back, or from the start of its current cycle when that is earlier, whatever range the statistics show, and counts the window's cap hits over the last week (`QuotaMath.insights`).
- The hover hint (`QuotaForecast.hint`) puts a window's outlook into words: how long it lasts at its pace when it runs out before its reset, and the share it will have used by the reset when it runs out only after, as its island row says.
- The burn rate (`UsageAnalytics.burnRate`) is the recent pace with idle time included: consumption over the last hour of a 5h window, the last day of a weekly one and the last week of a monthly one, or over the whole observed series while that is shorter. A rise under 5 points is reading noise; a larger one is a reset and restarts the series. A series shorter than 15 minutes, or one hour for windows of a day or more, gives no estimate.
- The island shows these alerts (`IslandEventTracker`). Baselines start again at every launch, so readings present at start-up never alert; nothing is checked while collection is paused or the last refresh failed, and alerts that arrive while the glow is hidden are dropped.

### Accounts

- Readings, quota history, alert baselines and display settings are keyed by the account's window rows, so two accounts of one client never share a history or a burn rate.
- The account of a provider's latest successful reading is current; only current accounts join the glow, the menu-bar figure, hints and alerts. A failed refresh keeps the current account, and a login without plan limits makes no account current.
- An account's header says it is the current account only while its readings are sound. When its own read or its client's failed or could not be verified, it says when the account was last read, and the island above the account and the menu's tooltip give the reason, then the client's other notices; a billing pool's header speaks for its pool alone.
- Other accounts keep their last reading and its observation time, greyed under the account's name, until they have not been seen for 30 days; their readings, rows and display settings then retire.
- Changing accounts is neither a reset nor an exhaustion: an account that becomes current again starts a new alert baseline.
- The first identified account takes over an unidentified row's position and display switch; a window that appears on a further account inherits the switch of the same window on another account. Quota history recorded before accounts were identified belongs to no account and feeds no burn rate.
- A login the provider does not identify is one account per client home directory, never merged with another home. A provider that must forget its accounts, for example after reading consent is withdrawn, retires their readings, rows and display settings at once.
- Codex reset credits belong to the account that reported them; native and Pi logins can make several accounts current at once. Billing-pool rows (Kimi, GLM, OpenCode Go) keep their pool ids as account ids, and a pool whose reading failed or whose account could not be confirmed holds back its own rows only, never another pool of the same vendor.

### Collection cadence

Reads never run in parallel: the usage store runs one pass of source reads or one account step at a time, and a pass starts only after the previous one finished. Every account request is a metadata read: no model message is sent and no reset credit is consumed.

| Work | Cadence |
| --- | --- |
| One client's local logs | When a file under its data directories changes, when one of its live sessions reaches 120 s or a running turn 120 s, 5 minutes or 30 minutes without an observation, and after its account step; passes start at most every 2 s |
| Local logs of a source that cannot name its directories | Every 5 s |
| Every client's local logs while the first index is being built | Every 2 s |
| Account readings: Claude Code engine `get_usage`, Codex `account/rateLimits/read`, DeepSeek balance, Antigravity, Cursor, Grok and GitHub Copilot quota, Cursor account usage events, and Kimi, GLM and OpenCode Go quota per billing pool | Per client: every minute while one of its turns runs, every 3 minutes while a session of its is live between turns, once more for work that finished since its last reading, and when one of its windows resets. Also when the panel, the menu bar menu or the statistics window opens, and at once when GitHub Copilot quota reading is switched on or off |

- A client nobody is using is not asked: its windows move only while its own work runs. A window whose reset has passed, a reading that names no window, and a client whose usage is the account's from every device it signs in on (Cursor and Codex, including Pi logins) keep the 5-minute interval.
- A known reset takes priority over the normal cadence and stays due until an account request has run at or after it, subject to the 60-second request spacing. An old window returned after that attempt retries on the normal cadence.
- Account steps run one provider after another, back to back for at most one second before local logs get their turn, so a slow request delays a poll by that request alone.
- A pass reads only the clients that signalled; the others keep their last result. Every local source is read again every 5 minutes, which catches a change a directory watch missed. Every client's listing of its logs and databases examines only the files the watch reported changed, and lists every file again every 5 minutes or after dropped events; a listing that stops at its limit keeps the files it did not reach that are still there.
- A provider never repeats an account request within 60 s, whoever asks, and a failure waits as long as a success; it is reported as a source notice while the other sources keep working.

### Reading retention

- The last successful reading is kept with its observation time; a failed refresh keeps it and exposes the failure, and a restart restores it before the first poll.
- A client whose read, or whose quota or balance reading, failed keeps the sessions it last reported beside those it still reports; a notice about its local logs or hooks keeps none, and neither does a billing pool's failed reading, which is no one client's.
- When a window's reset time has passed, the row keeps the last reading and its time. A reset is confirmed only by a new reading whose reset time moved forward or that shows the window full again after rising at least 5 points; until then alert evaluation treats the deadline as pending and the row displays “Pending update”. Historical accounts show no live countdown. A successful Codex response replaces that account's complete window inventory, removing omitted windows from the kept report and the settings alike; the account's or Codex's failed read retains the old inventory, and a notice about Codex's logs or hooks does not.
- Kimi, GLM and OpenCode Go rows are retired — readings, cached rows and display settings — once a completed credential scan finds their credentials expired, removed or rejected; a temporary network failure retires nothing.
- A row no provider has reported for 30 days retires with its reading, whatever stopped it: a client uninstalled, a window the service dropped, a vendor no longer read. Until a provider reports a row it is not shown anywhere, and its stored display switch and position wait for it.
- One rule (`ReportView.isPresent`) decides whether a row is present in the panel, the menu, Settings and the report kept across passes: a provider reported it within 30 days, its account is in its provider's inventory, and its plan pool is active. What no report says counts as present, so before the first read every row shows, plan pools included, and a row without an account leaves once its provider identifies accounts.
- Quota histories keep 30 days.
- A session whose source never says what its turn is doing leaves the running indicator 120 s after its last observation; one whose source reports a running turn keeps it until the turn ends, or until 30 minutes without an observation say its client is gone. Either way it stays in history without an invented end time.

## Code map

| Concept | Code |
| --- | --- |
| Token kinds and dimensions, bar buckets | `Sources/AgentHUDCore/Models/TokenKinds.swift`, `Sources/AgentHUDCore/Logic/ChartData.swift` |
| List prices, platforms, context windows | `Sources/AgentHUDCore/Models/ModelCatalog.swift`, `ModelPriceList.swift`, `PriceRegions.swift` |
| Today, seven and thirty days | `Sources/AgentHUDCore/Models/UsagePeriods.swift`, `Store/UsageLedger.swift` |
| Alert levels, thresholds and reading age, status colors | `Sources/AgentHUDCore/Models/AgentThresholds.swift`, `Sources/AgentHUDCore/Logic/StatusLevel.swift` |
| Reading status and assessment | `Sources/AgentHUDCore/Models/ReadingStatus.swift` |
| Which rows are present, levels, glow segments, menu figure and hints | `Sources/AgentHUDCore/Logic/ReportView.swift` |
| Alert tracker, added usage resets, island events, forecast | `Sources/AgentHUDCore/Logic/QuotaAlerts.swift`, `ResetCreditGrants.swift`, `IslandEvents.swift`, `QuotaForecast.swift` |
| Event union, analytics, history retention | `Sources/AgentHUDCore/Store/UsageAggregation.swift`, `QuotaHistoryStore.swift`, `Sources/AgentHUDCore/Logic/UsageAnalytics.swift` |
| A window's remaining share, insights, outlook, projection and token rate | `Sources/AgentHUDCore/Logic/QuotaMath.swift` |
| Session liveness and its limits, retained readings | `Sources/AgentHUDCore/Logic/SessionPhase.swift`, `Sources/AgentHUDCore/Models/LiveSession.swift`, `Sources/AgentHUDCore/Providers/RetainedUsageProvider.swift` |
| Session breakdown | `Sources/AgentHUDCore/Models/SessionUsage.swift`, `Store/UsageLedger.swift`, `Providers/CombinedUsageProvider.swift` |
| Accounts, current and previous readings, settings migration | `Sources/AgentHUDCore/Models/ProviderAccount.swift`, `Sources/AgentHUDCore/Providers/RetainedUsageProvider.swift`, `Sources/AgentHUDCore/Store/SettingsStore.swift` |

## Related

[providers.md](providers.md) per-client fields and request intervals · [session-lifecycle.md](session-lifecycle.md) running and terminal turns · [architecture.md](architecture.md) design invariants
