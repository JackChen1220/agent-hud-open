<h1 align="center">Agent HUD Open</h1>

<p align="center">
  <strong>Your agents, at a glance.</strong><br>
  Activity, quotas, tokens and sessions in your Mac notch or Dynamic Dock.
</p>

<p align="center">
  <a href="https://agenthud.app/mac"><img src="docs/buttons/mac.svg" alt="Download Agent HUD for Mac" width="180" height="36"></a>
  <a href="https://apps.apple.com/app/id6812113619"><img src="docs/buttons/app-store.svg" alt="App Store: iPhone and Apple Watch" width="138" height="36"></a>
  <a href="#build-from-source"><img src="docs/buttons/source.svg" alt="Build Agent HUD Open from source" width="181" height="36"></a>
</p>

<p align="center">
  <a href="https://agenthud.app">Website</a> ·
  <a href="#local-and-remote">Local &amp; Remote</a> ·
  <a href="#supported-clients">Supported clients</a> ·
  <a href="#documentation">Documentation</a><br>
  <sub>Native macOS 14+ &nbsp;·&nbsp; Swift 6 &nbsp;·&nbsp; Apache-2.0</sub>
</p>

<p align="center">
  <img src="docs/videos/agent-hud-loop.gif" alt="Agent HUD notch glow breathing and expanded usage panel" width="800">
</p>

Agent HUD Open is the macOS core and standalone source edition of [Agent HUD](https://agenthud.app). Local monitoring is free. The official Agent HUD app also offers connections to your iPhone and Apple Watch.

## On your Mac

| Stay in the flow | Know your usage | Follow your sessions |
| --- | --- | --- |
| Hover over the notch for a quick overview. On any display, drag Dynamic Dock to one of its four edges. | Check plan quotas, reset times, burn rates and API balances. Explore tokens by model, token kind and time. | Browse and search sessions by client and project. Git repositories and their worktrees share one project group. |
| Get turn-completion reminders, quota warnings and reset alerts. Answer supported approvals and questions directly in the HUD. | The HUD always shows the past 24 hours of tokens in 15-minute bars, followed by up to five recent or active sessions. | Open per-turn usage, context and cache details, including identified Codex subagents. Return to a supported client's conversation or existing terminal pane. |

Choose visible agents and accounts, per-display placement, and a soft glow or halftone, ASCII, block, Braille or binary effects. Press **⌘⌥H** to toggle the glow.

### Approve without switching windows

Inspect the command, file, tool input or edit diff before answering. Claude Code, Codex, Antigravity and other supported clients keep ownership of their permission flow; available choices depend on the client. Questions from Claude Code, ZCode and compatible DeepSeek Harness hosts can also be answered in the HUD.

<p align="center">
  <img src="docs/screenshots/approvals.webp" alt="Agent HUD notch with a queue of tool requests and an expanded edit diff" width="800">
</p>

### See where your tokens go

Compare models, inspect session turns, follow cache usage and view activity heatmaps. Costs at published API prices are estimates, shown separately from subscription quotas and actual account balances.

<p align="center">
  <a href="docs/screenshots/usage-statistics.webp"><img src="docs/screenshots/usage-statistics.webp" alt="Mac usage dashboard with token charts, model breakdowns, balances and an activity heatmap" width="380"></a> <a href="docs/screenshots/mac-session.webp"><img src="docs/screenshots/mac-session.webp" alt="Mac session details with tokens per turn, context usage, cache hits and costs" width="380"></a><br>
  <sub>Mac usage dashboard and session details · Sample data</sub>
</p>

## Local and Remote

| Connection | What you can do | Availability |
| --- | --- | --- |
| **On your Mac** | Monitor local activity, quotas, tokens and sessions; use the HUD, statistics, approvals and reminders. | Free, with no Agent HUD account or subscription. Available in Agent HUD Open and the official Mac app. |
| **Local network · Beta** | Pair a compatible phone with your Mac by QR code for read-only viewing on the same network. | Official Mac app with compatible Beta clients. Local pairing does not require an Agent HUD Remote subscription. |
| **Agent HUD Remote** | View your Macs together on iPhone, read shared recent conversations, and follow quotas and sessions through widgets, Live Activities and the paired Apple Watch. | Paid Remote access on the official Mac app. The iPhone and Apple Watch apps are free to download. |

> [!WARNING]
> **Critical LAN Beta issue:** LAN-enabled Mac Beta releases conflict with the communication mechanism in existing Agent HUD iOS versions and may disrupt Mac–iPhone communication or synchronization. Use the stable channel for cross-device viewing and wait for a verified compatibility fix before trying LAN. See the [release notes](https://github.com/jazzenchen/agent-hud-open/releases).

[Get Agent HUD on the App Store](https://apps.apple.com/app/id6812113619) for **iPhone and Apple Watch**. Requires iOS 17+ and watchOS 10+; automatic Live Activities require iOS 18+, with watchOS 11+ for the Watch Smart Stack. Remote viewing uses the same Apple Account in your Mac and iPhone system settings; Apple Watch uses its paired iPhone.

<p align="center"><a href="docs/screenshots/iphone-home.webp"><img src="docs/screenshots/iphone-home.webp" alt="Agent HUD Remote on iPhone showing quotas and balances from demo Macs" width="220"></a> <a href="docs/screenshots/iphone-sessions.webp"><img src="docs/screenshots/iphone-sessions.webp" alt="Agent HUD Remote on iPhone showing session activity, token totals and per-turn charts" width="220"></a><br>
  <sub>Agent HUD Remote on iPhone · Home and Sessions · Sample data</sub>
</p>

The source edition in this repository provides the local Mac features. Device connections and push services belong to the official Agent HUD app. See [Agent HUD Remote](https://agenthud.app/#pricing) for plans.

## Supported clients

**Claude Code** · **Codex Desktop / CLI** · **DeepSeek Harness** · **Antigravity** · **Cursor** · **Grok CLI** · **Grok Bot** · **GitHub Copilot CLI** · **OpenCode** · **Kimi** · **GLM** · **Pi** · **OpenClaw** · **Hermes Agent** · **ZCode** · **CodeBuddy** · **WorkBuddy** · **Qwen Code**

Install and sign into the clients you want to monitor. Activity, quota, balance and navigation coverage varies by client and account. Grok CLI and Grok Bot have separate client entries and icons under Grok accounts; Bot reads available local conversation caches, which can have gaps and do not establish live status.

See [provider support](docs/providers.md), [session lifecycle](docs/session-lifecycle.md) and [session navigation](docs/session-navigation.md). The **Qoder** builds also support approval hooks; supported choices and questions are described in [HUD approvals](docs/hud.md#approvals).

### Your data

Local monitoring reads the clients' records on your Mac. Supported quota and balance queries use the installed clients' existing sign-in or configured credentials; those credentials stay out of reports and stored usage data. The source edition keeps its usage history locally. See [data access](docs/data-access.md) and the official app's [privacy policy](https://agenthud.app/privacy).

## Build from source

**Requirements:** macOS 14+ and Xcode or the Xcode Command Line Tools with a Swift 6 toolchain.

```sh
git clone https://github.com/jazzenchen/agent-hud-open.git
cd agent-hud-open
make check
make test
make run
```

This builds and opens `build/Agent HUD Open.app`, signed ad-hoc for local use. No developer account, signing identity or provisioning profile is required.

<details>
<summary><strong>Development and embedding</strong></summary>

| Command | Purpose |
| --- | --- |
| `make check` / `make test` | Check source boundaries / run unit tests |
| `make build` / `make run` | Build the locally signed app / build and open it |
| `make demo` / `make snapshot` | Open sample data / render the UI to `build/snapshots` |

The Swift package exposes `AgentHUDSupport` (records and identities), `AgentHUDCore` (providers, models and storage), and `AgentHUDDesktop` (native HUD and statistics). `AgentHUDOpen` is the standalone executable. Hosts can provide settings pages and services through `DesktopApplication`; see [host integration](docs/architecture.md#host-integration).

CI checks source boundaries, runs unit tests, builds the app and verifies its signature and resources.

</details>

## Documentation

[HUD and approvals](docs/hud.md) · [Providers](docs/providers.md) · [Usage semantics](docs/usage-semantics.md) · [Session lifecycle](docs/session-lifecycle.md) · [Session navigation](docs/session-navigation.md) · [Data access](docs/data-access.md) · [Architecture](docs/architecture.md) · [Performance](docs/performance.md) · [Command line](docs/command-line.md) · [Updates](docs/updates.md) · [Brand assets](docs/brand-assets.md) · [Changelog](CHANGELOG.md)

## License

[Apache-2.0](LICENSE). Provider references and icon assets retain their [third-party notices](THIRD_PARTY_NOTICES.txt) and [icon license](Sources/AgentHUDDesktop/Resources/LobeIcons-LICENSE.txt).
