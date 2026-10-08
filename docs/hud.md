# The HUD on screen

## Overview

Each display has its own HUD and settings. Notch mode uses the physical notch or a stand-in bar; Dynamic Dock places agent logos along any screen edge. The glow forms a rim around the island or a backdrop behind the logos.

## Model

| Concept | Meaning |
|---|---|
| HUD | One display's presentation: a collapsed entry on a screen edge, the panel it opens into, and its glow |
| Notch mode | The island: the physical notch on a Mac that has one, or a bar standing in for it on a display that does not |
| Dynamic Dock | A queue of marks — the watched vendors and any run in the last day — along a screen edge with no shape behind them |
| Glow | Colour drawn from the enabled windows' levels — a rim around the island, a backdrop falling inward behind the dock |
| Placement | What one display shows and where: mode, edge, position along the edge, logo size, logo spacing, whether the marks are drawn |

## Rules

### Placement

- A display with a notch defaults to notch mode; a display without one defaults to Dynamic Dock, so no screen draws a bar pretending to have a notch.
- Either mode can be chosen for any display; notch mode stays at the physical notch or the screen's top centre.
- A display keeps its own placement under its UUID; display settings can reset its position to top centre, or top left for a dock on a notched display, keeping its mode and logo settings.
- The dock can sit anywhere along the top, right, bottom or left edge, running horizontally on the top and bottom and vertically on the sides; logo size is 12–24 pt and spacing is 0.1–0.6 of the logo.
- Drag a visible HUD directly to any edge; dragging a notch switches it to Dynamic Dock. Its bounds appear while it is grabbed or dragged.
- The marks can be hidden, which leaves the backdrop alone, still where they would have been and as wide.

### What the queue shows

- The enabled, non-API-billed agents first, in the order they are watched in, then any vendor that ran in the last day without a window on that list, most recently used first.
- Watched vendors appear before their first reading; vendors shown only for recent activity leave a day after their last turn and never appear with Live status off.
- Shared artwork appears once: Claude windows share one mark, as do Codex and ChatGPT.
- Marks bob while a session is live, including one blocked on the user, using the same liveness as the panel.
- A dock with nothing to show keeps a minimal entry at its saved position without drawing a logo.
- Marks retain their artwork with a hairline outline; single-colour marks are white, and status colour appears in the glow.

### Hovering and events

- A visible dock accepts dragging; with logos hidden, clicks pass through.
- Hovering opens inward, optionally requiring Option, with the same opening and closing timing on all four edges. During the delay, content height, glow and shadow are prepared without retaining a hidden panel; leaving cancels preparation.
- Events appear once, on the pointer's display.
- A successfully ended turn shows its conversation title and, for Codex, the last paragraph of its final reply when available, with a blue outlined speech bubble. Replies and permission requests share an event panel, separate from the usage panel, with one card open and the rest selectable. A reply offers session return when an exact target is available and a separate token-usage action; a failed return retains it for retry. See [session navigation](session-navigation.md) for coverage.
- The completion's token-usage action opens its Sessions statistics page; quota events reveal and highlight their Tokens card, and other events open Tokens. A panel session's title returns to its native agent when available, its token count opens that session's statistics, and the heading opens the list; chart and menu-bar controls open Tokens and reset Sessions to its list.
- Opening statistics or settings collapses the HUD until the pointer leaves and returns; controls that change only the panel keep it open.
- A dock's backdrop stops when the panel or an event opens; only notch mode draws a rim.
- Expanded docks and reminders flare outward at both ends of their contact with the parked edge, while their text stays upright; the marks keep their saved position over the open usage panel, even when its content is shorter than the queue.

### Usage panel

- The panel opens on a session summary: up to five sessions with work in flight, those waiting for the user ahead of those still running and newest created first within each group, then up to three recently ended sessions by their last event. Each row shows its agent's mark and its state on the mark's corner; the remaining count and header open the full Sessions page.
- A session waiting on a question shows a badge on its row. It opens the question right there, answered the same way the island's own card answers it, beside a way back to the agent for answering it in its own dialog instead. A row's title returns to its agent, or opens that session's page where the client names no destination; its token count opens that session's usage.
- Quota and balances follow as the smaller account picture, and the token chart becomes a compact strip — its legend, axis and peak mark belong to the statistics window. Height follows content up to the display's height minus 80 pt; overflow scrolls above fixed settings, statistics and host controls, clear of the notch and dock.

### Approvals

Antigravity supplies waiting permissions through its running local service, without an execution hook. All services advertising local credentials are read; agy without them is excluded. Before sending allow-once or deny, the HUD rereads the exact interaction. Answers in Antigravity remove the card. Leaving or expiry keeps the native prompt unanswered and the card hidden until a complete reading confirms it ended. Client hooks off stops observation and cancels answers still in preflight.

DeepSeek Harness's questions come the same way, from the web host its run serves: `dsh --profile web` announces each question its sessions ask on a loopback event stream, and the HUD reads it there — no hook is installed, and nothing is written to Harness's files. Pending questions replay when the connection returns, an answer goes back through the host's respond interface under the question's own id, and a question Harness settles itself arrives as resolved and leaves without one from the HUD. Hosts are found from the process list and confirmed by asking the port itself; a headless or kcode-profile run has no questions provider and never asks. Leaving or expiry leaves Harness's own question open. Client hooks off stops the reading.

- A hook client that stops to ask whether a tool may run reaches the HUD through a socket of its own, and the request lives only as long as that client waits for it. One copy of the application runs at a time ([command line](command-line.md#launch-and-display)) and serves the socket; should another start beside it with the same data directory, it leaves the socket to the first, and quitting removes only a socket that copy made. Answering resumes the client; the client giving up — timed out, killed — takes the request off the HUD by itself, and nothing is answered on anyone's behalf.
- While a request waits, its session needs approval wherever it is shown — its dot among the island's sessions, its card on the Sessions page and its page — and counts as running, whatever the client's log says; the mark leaves with the request. A session whose Live status is off shows no state.
- Claude Code keeps its hook waiting after the user answers in Claude Code's own dialog, in the terminal or the desktop app. The hook follows the session record instead: once the call it asked about has its result there — answered, refused or interrupted — it leaves without an answer, which takes the request off the HUD. The record names the call by its tool and exact input; an approved command's result is written when the command finishes, so its card stays until then or until the wait runs out.
- A request holds the island until it is settled, where other events expire a few seconds after being shown. Unanswered, it waits Settings → General → Wait for an answer — 10 minutes unless 1, 3, 5, 30 or 60 is chosen — and then goes back to the client's own prompt, answered by nobody. The hook timeout written into the client, a day, is only the ceiling behind that wait, so a new value applies at once, to requests already waiting too, without rewriting any client's settings. Quitting the application hands every waiting request back the same way, and a client that asks while it is not running goes straight to its own prompt. Replies that arrive while a request waits remain selectable in the event panel; quota events and added usage resets are dropped, and a second request waits its turn.
- Hovering opens the queue: the oldest request open, the rest a line each. Any line can be opened, which closes the one before it, and the answers always act on the open one. Answering hands over to whichever has waited longest.
- A request is on one display at a time, the one the pointer was on when it arrived, and the queue lists every request waiting on any of them: opening a line that arrived on another display moves that request to this one. A request whose display goes away moves to the display the pointer is on, still waiting.
- A question Claude Code, ZCode or DeepSeek Harness asks its user is answered rather than approved: each question with its offered answers, several where it allows them, and a field for the user's own words, one question at a time and sent together after the last. Any question can be skipped; the client hears which were left open — nothing on a question card refuses the call. A session waiting on one carries a badge on its row in the usage panel, where the same answers open inline.
- A plan Claude Code asks to have approved is not answered on the HUD: the card names it, shows its opening lines and points to Claude Code, whose own dialog carries the choices about how to go on. Putting the card away answers nothing. The field is the only thing on the HUD that takes the keyboard, and only when clicked — a card that arrives never catches keys typed elsewhere; the keyboard goes back to the app in front when the answer is sent, Escape is pressed or another window is clicked, and the island stays open while it is being typed into.
- Deny and allow-once are always offered for every other request, and always beside what an allow lets run: the command, the file and the lines it would change, the URL or the tool's own input, even when the one-line summary already says the same. A request that arrives while the usage panel is open switches to the event panel.
- A third answer appears only when the client supports rule updates and itself suggested a rule — the HUD echoes that suggestion back untouched rather than composing one, and writes out the rule it adds, such as `Bash(npm test:*)`, before it can be given. Antigravity, Codex, CodeBuddy, WorkBuddy, ZCode and Qwen Code offer only deny and allow-once; their shell commands, file edits and MCP tools use the same queue as Claude Code.
- A request reaches the HUD only when the client itself was about to ask. A client whose hook runs before every tool call, or whose hook cannot approve, is not connected, because answering it would mean asking about calls the client would have allowed on its own. A plan approval, and a question from any client but Claude Code, ZCode and DeepSeek Harness, stays in the client's own dialog: those clients either ignore an answer sent back, act on one without the user's reply, or are not known to read one.
- Settings → General → Client hooks switches every handler Agent HUD keeps in the clients' own settings: approvals, Claude Code's notification hook, the stop hooks, Pi's extension and OpenCode's plugin. Switching it off asks first, naming what stops working — answering requests on the HUD, completion reminders from the clients that report them only through a stop hook or a plugin, Claude Code's waiting state and Pi's running status; usage, quota and sessions are unaffected. Off, every Agent HUD handler is removed at once, whichever copy of the application added it, and none is added back; ZCode's hooks switch stays as it was.
- Saying nothing is an answer the HUD can always give, and it is what a closed, paused or busy HUD gives: the client's own permission flow carries on as though no hook were installed. A hidden or paused glow silences events but never a request, which would otherwise leave a session waiting with nothing on screen to say why.

### The glow

- Every display has its own glow: style, effect, speed, reach and density are set per screen, and a display with none of its own follows the default.
- The falloff is two settings, both counted in rows: how many keep full strength, and how many the glow fades away over. The fade is Gaussian, so it leaves the solid rows level instead of dropping at once.
- The effect plays at the working period while any agent runs and at the idle period otherwise; the glow never stops, it only slows down, so a resting HUD still reads as alive.
- Every effect takes the period, not only breathing. Grid styles are dithered by each cell's place in the Bayer matrix, which keeps the average density and breaks up the stripes a distance-only level would produce.
- The whole HUD shares one drawing budget across displays, so a second screen costs frames rather than processor. A blurred glow never enters the frame loop; an idle one is sampled at 8 frames a second.
- Reduce Motion holds the resting frame and turns the island's geometry changes into a cross-fade.

## Interfaces and configuration

| Setting | Values | Default |
|---|---|---|
| `screens[<display UUID>].mode` | `notch`, `logos` (Dynamic Dock) | By hardware: `notch` with a notch, `logos` without |
| `screens[…].edge` / `offset` | `top`, `right`, `bottom`, `left` / 0–1 along the edge | `top` / 0.5 |
| `screens[…].logoSize` / `gapScale` | 12–24 pt / 0.1–0.6 of the logo | 20 pt / 0.4 |
| `screens[…].showsLogos` | Draw the marks, or the backdrop alone | `true` |
| `screenGlow[<display UUID>].style` | `blur`, `dots`, `ascii`, `blocks`, `braille`, `binary` | `blur` |
| `screenGlow[…].effect` | `breathe`, `flow`, `scan`, `ripple`, `shimmer`, `boot` | `breathe` |
| `screenGlow[…].breathSeconds` / `idleBreathSeconds` | 1–24 s, the period every effect plays at | 3 s / 7 s |
| `screenGlow[…].gridCore` / `gridFade` | 0–8 rows at full strength / 0–8 rows to fade over | 0 / 5 |
| `screenGlow[…].gridPitch` / `gridDensity` | 4–12 pt between cells / 50–150% of a cell filled | 10 pt / 100% |
| `screenGlow[…].range` / `blur` | 0–36 pt reach / 0–36 pt feather, for the blurred style | 14 pt / 8 pt |
| `screenGlow[…].brightness` / `breathAmplitude` | 20–100% / how deep the breath dips | 90% / 60% |
| `requiresOptionToOpen` | Hovering alone leaves the panel closed | `false` |
| `clientHooks` | Keep client handlers and native approval observation enabled | `true` |
| `approvalWaitMinutes` | 1, 3, 5, 10, 30 or 60 minutes a permission request waits for an answer | 10 |

Supported approval hooks are installed for detected clients at startup, alongside the notification and completion hooks, unless `clientHooks` is off; `--permission-hook <source>` is the handler they point back at. Antigravity uses its running service instead, and DeepSeek Harness's questions its web host. See [command line](command-line.md) and [data access](data-access.md).

`Settings.placement(on:hasNotch:)` and `glow(on:)` answer what one display uses, falling back to the default when it has none of its own. Both are keyed by the string `ScreenIdentity.key(for:)` returns for a display.

## Code map

| Concept | Where |
|---|---|
| Per-display placement and glow | `Sources/AgentHUDCore/Models/Settings/ScreenPlacement.swift`, `GlowSettings.swift`, `Settings.swift` |
| One HUD per screen, and what they share | `Sources/AgentHUDDesktop/Notch/ScreenHUD.swift`, `ScreenIdentity.swift`, `Notch/Island/IslandController.swift` |
| Where a HUD sits on its screen | `Sources/AgentHUDDesktop/Notch/NotchGeometry.swift` |
| The marks and their motion | `Sources/AgentHUDDesktop/Notch/Island/LogoQueueView.swift`, `LogoImages.swift` |
| Glow geometry, falloff, colours and frames | `Sources/AgentHUDDesktop/Notch/Glow/GlowGeometry.swift`, `GlowMatrix.swift`, `GlowMotion.swift`, `GlowGradient.swift`, `GlowWindowController.swift`, `GlowFrameRenderer.swift`, `GlowAnimator.swift` |
| Collapsed shape, panel and events | `Sources/AgentHUDDesktop/Notch/Island/IslandRootView.swift`, `IslandWindowController.swift` |
| Requests waiting, and the channel they wait on | `Sources/AgentHUDCore/Hooks/Permission/PermissionRequests.swift`, `PermissionRequest.swift`, `PermissionHooks.swift`, `PermissionHookClient.swift`; `Sources/AgentHUDCore/System/UnixSocketListener.swift`, `UnixSocket.swift` |
| Native Antigravity approvals | `Sources/AgentHUDCore/Hooks/Permission/AntigravityPermissions.swift`, `AntigravityPermissionObserver.swift`; `Sources/AgentHUDCore/Providers/Antigravity/AntigravityService.swift` |
| DeepSeek Harness's questions | `Sources/AgentHUDCore/Hooks/Permission/DeepSeekQuestions.swift`, `DeepSeekQuestionObserver.swift` |
| A call answered in Claude Code's own dialog | `Sources/AgentHUDCore/Hooks/Permission/PermissionTranscript.swift` |
| The card, the queue and the answers | `Sources/AgentHUDDesktop/Notch/Alerts/PermissionAlertViews.swift`, `PermissionQuestionViews.swift`, `IslandAlert.swift`, `Notch/OverlayPanel.swift` |
| Settings for both | `Sources/AgentHUDDesktop/Settings/ScreensPane.swift`, `GlowPane.swift`, `DisplayPane.swift` |

## Related

[architecture.md](architecture.md) package layout and host integration · [usage-semantics.md](usage-semantics.md) what the levels behind the colour mean · [session-lifecycle.md](session-lifecycle.md) when a session counts as live · [command-line.md](command-line.md) launch options
