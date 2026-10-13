# The HUD on screen

## Overview

Each display has its own HUD and settings. Notch mode uses the physical notch or a stand-in bar; Dynamic mode places agent logos along any screen edge; Simple mode parks a small panel of rings and numbers on an edge. The glow forms a rim around the island or a backdrop behind the logos, and Simple mode has none.

## Model

| Concept | Meaning |
|---|---|
| HUD | One display's presentation: a collapsed entry on a screen edge, the panel it opens into, and its glow |
| Notch mode | The island: the physical notch on a Mac that has one, or a bar standing in for it on a display that does not |
| Dynamic mode | A queue of marks — the watched vendors and any run in the last day — along a screen edge with no shape behind them |
| Simple mode | A small floating panel on a screen edge with no glow behind it: each agent's mark, with its most used window as a ring round the mark, a percentage beside it, or both |
| Glow | Colour drawn from the enabled windows' levels — a rim around the island, a backdrop falling inward behind the dock |
| Bot | What a mark turns into while its agent is in flight: a small body in the mark's own outline and colour, with two eyes |
| Placement | What one display shows and where: mode, edge, position along the edge, logo size, logo spacing, whether the marks are drawn, and the Simple panel's size, ring stroke, rings and numbers |

## Rules

### Placement

- A display with a notch defaults to notch mode; a display without one defaults to Dynamic mode, so no screen draws a bar pretending to have a notch.
- Any mode can be chosen for any display; notch mode stays at the physical notch or the screen's top centre. Choosing Simple on a notched display starts at the top left; a centred Dynamic logo queue clears the physical notch below it.
- A display keeps its own placement under its UUID; display settings can reset its position to top centre, or top left for Simple on a notched display, keeping its mode and logo settings.
- The dock can sit anywhere along the top, right, bottom or left edge, running horizontally on the top and bottom and vertically on the sides; logo size is 12–36 pt, spacing is 0.1–0.6 of the logo, and the logos stand 0–20 pt in from the edge.
- Drag a visible HUD directly to any edge; dragging a notch switches it to Dynamic mode, and a Simple panel stays Simple. The drag surface stays transparent during clicks, holds and dragging.
- The marks can be hidden, which leaves the backdrop alone, still where they would have been and as wide.

### What the queue shows

- The enabled, non-API-billed agents first, in the order they are watched in, then any vendor that ran in the last day without a window on that list, most recently used first.
- Watched vendors appear before their first reading; vendors shown only for recent activity leave a day after their last turn and never appear with Live status off.
- Shared artwork appears once: Claude windows share one mark, as do Codex and ChatGPT.
- A mark is its bot for as long as a session is live, including one blocked on the user, using the same liveness as the panel, and settles back into its logo when the session ends. An idle mark becomes its bot for three to five seconds every 20 to 35 seconds. With `botLogos` off, or for a mark that has no bot, a working mark stays its logo and keeps still.
- A dock with nothing to show keeps a minimal entry at its saved position without drawing a logo.
- Marks retain their artwork with a hairline outline, except the fork's borderless Kiro tile; single-colour marks are white, and status colour appears in the glow.

### Bots

- Every bundled mark has a bot. Its body is a plain ball or the mark's own simple shape, in the mark's colours, with any feature drawn on the body: Claude twelve even heads, Pi a square on two legs under a flat hat, Grok a ball with a ring round its waist, Hermes a ball with a fringe, Qoder a ball in a green neck warmer, CodeBuddy and WorkBuddy an upright cat. GitHub Copilot keeps its artwork and only its eyes move. Kiro keeps the fork's purple tile and white ghost, with animated black eyes and no added hairline.
- The logo turns into the bot in half a second: the outline relaxes, the artwork fades into the mark's colours and the eyes open. The eyes are small, stay upright and follow the pointer, sliding across the body as on a ball.
- A bot in the dock stays where its logo was: breathing changes its shape round a fixed centre, at the glow's working period. It does one small thing at random every one to three seconds: a glance, a double blink, a squint, a tilt, a stretch, a wiggle, or a turn of its body.
- A reminder's mark opens as the agent's logo and turns into its bot 0.7 seconds later, once its card has opened; the phase it acts out begins then.
- A permission reminder shows the asking bot: one hop, then raised by 12%, a knock every 2.6 seconds, eyes wide and straight at the user.
- A reply reminder shows the bot smiling for about a second, then looking at the pointer.
- A reminder keeps its bot for as long as it is shown; a dock's mark returns to its logo.
- On a dock that separates its agents, the mark whose own card is up answers to the card instead of its agent. While the card is a peek, the mark is its logo, whatever its agent is doing. A click that opens the whole panel turns it into its bot, which stays up and watches the pointer for as long as the panel is open. Closing the card gives the mark back to its agent — its bot stays if the agent is working, and settles into its logo if not — and an event's card leaves its sender's mark alone.
- One timer steps every bot, as often as the liveliest of them needs: 30 times a second during a morph, an act, a blink or a hop, 15 while eyes follow the pointer, 10 while a bot only breathes, and not at all while every mark waits as its logo for its next visit. A bot's picture is drawn again only when its eyes or outline have visibly changed, in the colours of its display so the layer shows it without converting it; breathing and leaning are layer transforms.
- Reduce Motion, or `botLogos` off, leaves every mark its logo.

### Type sizes

- Two tiers. What a dock answers a glance with is written to the dock's scale; what opens as a card has one fixed scale.
- The dock's scale makes a compact reminder's pill and the Simple panel's hover line as tall as one of the dock's marks: a Simple panel's ring (its Size, 16–40 pt, whether or not the rings are drawn) or a Dynamic dock's logo (12–36 pt). Both are 26 pt high at scale 1, so the scale is the mark's size over 26. It is never below 1: beside a mark of 26 pt or less, which both defaults are (a 22 pt ring, a 20 pt logo), everything is written as at the default. The notch has no size to follow and its scale is always 1.
- Written to the dock's scale: the Simple panel's hover line (12 pt at the default, 14 pt beside a 30 pt ring, 17 pt beside a 36 pt one), the Dynamic dock's hover bubble, and a compact reminder, with their marks, gaps and heights.
- A compact reminder on a dock is a slim pill, as tall as the Simple panel's hover line: 26 pt at the default for a 17 pt mark and 13 pt text, 30 pt beside a 30 pt ring for a 20 pt mark and 15 pt text. It is as long as what it says: who on one side and what on the other, each as wide as its words and no wider than one of the notch's wings (112 pt), 14 pt apart. Beside the notch the two are wings of that fixed width with the camera between them.
- Cards — the usage panel, an agent's own panel, a reminder's card — use one size per role: the agent's name 13 semibold, at most one 15 pt headline, rows 12, a status beside the name 12 medium, secondary text 11. 10 pt is for badges and counts only.

### What the Simple panel shows

- One item per mark, in row order, for the enabled windows that are not API-billed; windows that share artwork share an item.
- An agent billed by use, with a balance and no window, follows them in the balances' order: its mark, an empty ring, and its balance where the percentage would be, in the balance's level colour (a dash before its first reading). The hover line of such an agent reads its balance.
- An item reports its most used window among the readings that show a level, as the menu bar's figure does: a ring round the mark filled to that share, the whole percentage beside it, or both. Each can be switched off, and with both off the panel is the marks alone. A window with no reading shows an empty ring and a dash.
- The ring and the number take that window's level colour. No glow is drawn behind it, collapsed or open.
- Nothing in the panel moves unless its Bot animation is switched on. A working agent's mark is then its bot and an idle one visits as a bot now and then, as in the dock. The switch is the panel's own and off to begin with; `botLogos` does not affect it, and Reduce Motion keeps the logos.
- One length sizes the panel, 16–40 pt: the ring's diameter, with the mark and the number scaled from it. The ring's stroke is 1–4 pt.
- It parks and drags like the dock, 3 pt in from its edge: a row on the top and bottom, a column on the sides with the numbers lined up on the right. Hovering grows the panel itself into the usage panel: the same frame, still 3 pt off its edge and rounded on every corner, enlarges inward round the figures, which keep their place, and shrinks back into the small panel on leaving. An event takes the figures' place in that frame while it shows.

### Hovering and events

- A visible dock accepts dragging; with logos hidden, clicks pass through.
- Hovering opens inward, optionally requiring Option, with the same opening and closing timing on all four edges. During the delay, content height is measured and glow and shadow bitmaps are drawn off the UI thread without retaining a hidden panel; leaving cancels preparation and discards late results. Opening and collapse commit their window geometry immediately, with materials installed when ready. Matching installed materials are reused without another raster.
- Events appear once, on the pointer's display.
- A successfully ended turn shows its conversation title and, for Codex, the last paragraph of its final reply when available, with a blue outlined speech bubble. Replies and permission requests share an event panel, separate from the usage panel, with one card open and the rest selectable. A reply offers session return when an exact target is available and a separate token-usage action; a failed return retains it for retry. See [session navigation](session-navigation.md) for coverage.
- The completion's token-usage action opens its Sessions statistics page; quota events reveal and highlight their Tokens card, and other events open Tokens. A panel session's title returns to its native agent when available, its token count opens that session's statistics, and the heading opens the list; chart and menu-bar controls open Tokens and reset Sessions to its list.
- Opening statistics or settings collapses the HUD until the pointer leaves and returns; controls that change only the panel keep it open.
- A dock's backdrop stops when the panel or an event opens; only notch mode draws a rim.
- Expanded docks and reminders flare outward at both ends of their contact with the parked edge, while their text stays upright; the marks keep their saved position over the open usage panel, even when its content is shorter than the queue.

### Usage panel

- The panel shows quota and balances, then Tokens, then the local session summary with at most five rows in total: sessions with work in flight, those waiting for the user ahead of those still running and newest created first within each group, then sessions last active in the past 24 hours by their last event. Account-wide API receipts and older ended sessions remain in statistics and do not occupy these rows or enter their remaining count. Each row shows its client name, agent mark and state on the mark's corner. The remaining count covers every hidden session in this summary; it and the header open the full Sessions page.
- A session waiting on a question shows a badge on its row. It opens the question right there, answered the same way the island's own card answers it, beside a way back to the agent for answering it in its own dialog instead. A row's title returns to its agent, or opens that session's page where the client names no destination; its token count opens that session's usage.
- The token chart is a compact strip with the latest 24 hours in 96 quarter-hour bars, including the current quarter, and all token kinds. Dashboard range, bucket, model and token-kind controls do not change it; its legend, axis and peak mark belong to the statistics window. Height follows content up to the display's height minus 80 pt; overflow scrolls above fixed settings, statistics and host controls, clear of the notch and dock.

### Approvals

Codex Desktop's Computer Use app-access prompts are read from the original Desktop owner's pending MCP elicitations over local IPC. They offer **Deny**, **Allow this conversation**, and **Always allow** only when Desktop advertises that scope. Before answering, the HUD confirms the same owner and exact request are still waiting. Answering in Desktop withdraws the card; leaving, expiry, and failed readings never answer it. Client hooks off stops observation and cancels answers still in preflight. Engine tool approvals continue through the permission hook and its reviewer check.

Codex Desktop's mid-turn **Question** cards also appear on the HUD, with the supplied choices and a reply field, including questions without choices. Their questions are read from the original owner's active turn messages. Answers go back to the same active turn after the owner and question are checked again. **Skip** hides the HUD card without sending a reply. An accepted answer in Desktop or the end of the turn withdraws the card.

Antigravity supplies waiting permissions through its running local service, without an execution hook. All services advertising local credentials are read; agy without them is excluded. Before sending allow-once or deny, the HUD rereads the exact interaction. Answers in Antigravity remove the card. Leaving or expiry keeps the native prompt unanswered and the card hidden until a complete reading confirms it ended. Client hooks off stops observation and cancels answers still in preflight.

DeepSeek Harness questions can be answered on the HUD when its web host exposes the compatible question interface. The HUD confirms the host before reading its loopback event stream; hosts using a different interface keep questions in Harness. No hook is installed and nothing is written to Harness's files. Pending questions replay when the connection returns, answers keep each question's original id, and a question settled in Harness leaves the HUD. Plan reviews and questions with supporting detail stay in Harness so their full content can be read. Leaving or expiry keeps the question open there and hidden on the HUD, including across a temporary connection loss. Client hooks off stops the reading. See [the supported interface](providers.md#deepseek-harness).

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
- A request reaches the HUD only for a user's decision; automatic review and requests whose reviewer cannot be confirmed continue in the client's own permission flow without a HUD answer. A client whose hook runs before every tool call, or whose hook cannot approve, is not connected, because answering it would mean asking about calls the client would have allowed on its own. A plan approval, and a question from any client but Claude Code, ZCode, DeepSeek Harness and Codex Desktop's mid-turn Question interface, stays in the client's own dialog: those clients either ignore an answer sent back, act on one without the user's reply, or are not known to read one.
- Settings → General → Client hooks switches every handler Agent HUD keeps in the clients' own settings: approvals, Claude Code's notification hook, the stop hooks, Pi's extension and OpenCode's plugin. Switching it off asks first, naming what stops working — answering requests on the HUD, completion reminders from the clients that report them only through a stop hook or a plugin, Claude Code's waiting state and Pi's running status; usage, quota and sessions are unaffected. Off, every Agent HUD handler is removed at once, whichever copy of the application added it, and none is added back; ZCode's hooks switch stays as it was.
- Saying nothing is an answer the HUD can always give, and it is what a closed, paused or busy HUD gives: the client's own permission flow carries on as though no hook were installed. A hidden or paused glow silences events but never a request, which would otherwise leave a session waiting with nothing on screen to say why.

### The glow

- A display in Simple mode draws no glow, and its settings show no glow section. Every other display has its own glow: style, effect, speed, reach and density are set per screen, and a display with none of its own follows the default.
- The falloff is two settings, both counted in rows: how many keep full strength, and how many the glow fades away over. The fade is Gaussian, so it leaves the solid rows level instead of dropping at once.
- The effect plays at the working period while any agent runs and at the idle period otherwise; the glow never stops, it only slows down, so a resting HUD still reads as alive.
- Every effect takes the period, not only breathing. Grid styles are dithered by each cell's place in the Bayer matrix, which keeps the average density and breaks up the stripes a distance-only level would produce.
- The whole HUD shares one drawing budget across displays, so a second screen costs frames rather than processor. A blurred glow never enters the frame loop; an idle one is sampled at 8 frames a second.
- Reduce Motion holds the resting frame and turns the island's geometry changes into a cross-fade.

## Interfaces and configuration

| Setting | Values | Default |
|---|---|---|
| `screens[<display UUID>].mode` | `notch`, `logos` (Dynamic), `simple` | By hardware: `notch` with a notch, `logos` without |
| `screens[…].edge` / `offset` | `top`, `right`, `bottom`, `left` / 0–1 along the edge | `top` / 0.5 |
| `screens[…].logoSize` / `gapScale` | 12–36 pt / 0.1–0.6 of the logo | 20 pt / 0.4 |
| `screens[…].logoEdgeDistance` | 0–20 pt from the visible logo, outline included, to its edge | 2 pt |
| `screens[…].showsLogos` | Draw the marks, or the backdrop alone | `true` |
| `screens[…].simpleSize` / `ringWidth` | 16–40 pt ring diameter / 1–4 pt ring stroke, in Simple mode | 22 pt / 1.5 pt |
| `screens[…].showsRings` / `showsNumbers` | Draw the ring round each mark / write the percentage beside it | `true` / `true` |
| `screens[…].simpleBots` | The Simple panel's marks turn into bots while their agents work, and visit as bots while idle | `false` |
| `screenGlow[<display UUID>].style` | `blur`, `dots`, `ascii`, `blocks`, `braille`, `binary` | `blur` |
| `screenGlow[…].effect` | `breathe`, `flow`, `scan`, `ripple`, `shimmer`, `boot` | `breathe` |
| `screenGlow[…].breathSeconds` / `idleBreathSeconds` | 1–24 s, the period every effect plays at | 3 s / 7 s |
| `screenGlow[…].gridCore` / `gridFade` | 0–8 rows at full strength / 0–8 rows to fade over | 0 / 5 |
| `screenGlow[…].gridPitch` / `gridDensity` | 4–12 pt between cells / 50–150% of a cell filled | 10 pt / 100% |
| `screenGlow[…].range` / `blur` | 0–36 pt reach / 0–36 pt feather, for the blurred style | 14 pt / 8 pt |
| `screenGlow[…].brightness` / `breathAmplitude` | 20–100% / how deep the breath dips | 90% / 60% |
| `botLogos` | Dock marks and reminders' marks turn into bots while their agents work, ask or have just replied | `true` |
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
| The Simple panel: its items, its sizes and its drawing | `Sources/AgentHUDDesktop/Notch/Simple/SimpleMeter.swift`, `SimpleMeterView.swift` |
| What each mark becomes, how a bot moves and how it is drawn | `Sources/AgentHUDDesktop/Bots/BotSpec.swift`, `BotForm.swift`, `BotMotion.swift`, `BotRenderer.swift`, `BotActor.swift` |
| Glow geometry, falloff, colours and frames | `Sources/AgentHUDDesktop/Notch/Glow/GlowGeometry.swift`, `GlowMatrix.swift`, `GlowMotion.swift`, `GlowGradient.swift`, `GlowWindowController.swift`, `GlowFrameRenderer.swift`, `GlowAnimator.swift` |
| Collapsed shape, panel and events | `Sources/AgentHUDDesktop/Notch/Island/IslandRootView.swift`, `IslandWindowController.swift` |
| Requests waiting, and the channel they wait on | `Sources/AgentHUDCore/Hooks/Permission/PermissionRequests.swift`, `PermissionRequest.swift`, `PermissionHooks.swift`, `PermissionHookClient.swift`; `Sources/AgentHUDCore/System/UnixSocketListener.swift`, `UnixSocket.swift` |
| Native Antigravity approvals | `Sources/AgentHUDCore/Hooks/Permission/AntigravityPermissions.swift`, `AntigravityPermissionObserver.swift`; `Sources/AgentHUDCore/Providers/Antigravity/AntigravityService.swift` |
| Native Codex Desktop app approvals and mid-turn questions | `Sources/AgentHUDCore/Providers/Codex/CodexDesktopPermissions.swift`, `CodexDesktopQuestions.swift`, `CodexDesktopIPC.swift`; `Sources/AgentHUDCore/Hooks/Permission/CodexDesktopPermissionObserver.swift` |
| DeepSeek Harness's questions | `Sources/AgentHUDCore/Hooks/Permission/DeepSeekQuestions.swift`, `DeepSeekQuestionObserver.swift` |
| A call answered in Claude Code's own dialog | `Sources/AgentHUDCore/Hooks/Permission/PermissionTranscript.swift` |
| The card, the queue and the answers | `Sources/AgentHUDDesktop/Notch/Alerts/PermissionAlertViews.swift`, `PermissionQuestionViews.swift`, `IslandAlert.swift`, `Notch/OverlayPanel.swift` |
| Settings for both | `Sources/AgentHUDDesktop/Settings/ScreensPane.swift`, `GlowPane.swift`, `DisplayPane.swift` |

## Related

[architecture.md](architecture.md) package layout and host integration · [usage-semantics.md](usage-semantics.md) what the levels behind the colour mean · [session-lifecycle.md](session-lifecycle.md) when a session counts as live · [command-line.md](command-line.md) launch options

## Local fork Hub controls

- Agent / Branches tabs keep the last selection and resize the native panel immediately. Branches opens the local repository/worktree view; its progress labels are manual. See [project branches](repositories.md).
- ⌘⇧H opens or closes the Hub on the display under the pointer. Settings → General can change or disable it; ⌘⌥H still toggles the glow.
- Pin beside Settings keeps the panel open after the pointer leaves or another window is clicked. Unpin restores hovering; an explicit dismissal clears the pin.
- The expanded Hub and its popovers stay dark; independent settings and detail windows follow the appearance preference.
- A top-edge logo queue that overlaps the physical notch stays horizontally centered and is placed directly below the notch; other edges retain upstream dragging and placement.
- Kiro CLI completed-turn credits appear separately from reported tokens; neither credits nor context percentages are converted to token counts.
