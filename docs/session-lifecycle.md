# Session lifecycle

## Overview

Which clients expose running and terminal turns, which of them say they are waiting for the user and what the agent last said, what evidence each provider accepts, and how the hooks work. Usage records and running turns are separate observations: a token counter or a recent file modification never establishes that a whole agent turn is running or complete, and a quota response or a single model response never ends a turn.

## Model

`UsageReport.turns` carries `SessionTurn` observations: provider, session id, turn id, state (`running`, `waitingForApproval`, `completed` or `ended`), the source start time when known, the time of the latest source event — reading a cached transcript does not advance it — and the agent's last visible message where the client's records carry one. `waitingForApproval` is a running turn the client says is blocked on the user. `UsageReport.completions` carries `SessionCompletion` records (id = hash of vendor, session and turn; task, model, completion time) parsed from logs or received from hooks. `LiveSession.observedAt` records when the collector last checked desktop activity, including process evidence, and `LiveSession.lastActivityAt` when the session's log last recorded anything, which reading it again does not move.

| Client | Running turns | Terminal turns | Evidence |
| --- | --- | --- | --- |
| Claude Code | Yes | Yes | A prompt line starts the turn, but a slash command Claude Code runs itself, such as `/exit`, `/clear` or `/model`, and its output do not; an assistant `stop_reason` of `end_turn` or `stop_sequence` completes it; a `[Request interrupted` user line ends it; `tool_use` keeps it running, and a working assistant line after the turn stopped, with no prompt before it (a sub-agent's report, a queued notification, a Stop hook's feedback), resumes it. Attachment and queue records never date a turn. `isSidechain` lines and `<synthetic>` messages (API errors) never start or finish a turn, and the session's sub-agents keep it running ([Sub-agents](#sub-agents)). The turn's message is the latest assistant text block, and its notification hook reports waiting for approval. |
| Codex Desktop / CLI | Yes | Yes | `task_started` (`turn_id`) starts the turn and later events refresh it; `task_complete` completes it; `turn_aborted` ends it; an `agent_message` is the running turn's message. Guardian and sub-agent rollouts report none. |
| DeepSeek Harness | Yes | Yes | `turn/start`, later step, message and tool events (format 0 also logs streaming chunks), `turn/end`; only `reason.kind == completed` is a completion, and sub-agent sessions and inherited fork history record none. A quiet turn stays active while a Node process that predates it holds the Harness profile. |
| Grok CLI | Yes | Yes | Session updates keyed by `promptId`; `turn_completed` with `stop_reason` `end_turn` completes, other outcomes end without a completion. Older unified logs carry usage only. |
| Kimi | Yes | Yes | On the `main` agent the first `step.begin` starts the turn and loop events refresh it; `turn.ended` with `reason == completed` and no `error` completes it; child agents never finish the parent. Older status logs carry usage only. |
| Pi | Yes, with the observer | Yes, with the observer | `agent_start`, `agent_settled` and `session_shutdown` from the Agent HUD extension; an assistant stop alone does not finish a run. |
| OpenClaw | Yes | Yes | Gateway lifecycle status on a session's current window: `running` (turn `lifecycleRunId`) is running, `done` (turn `lastRunId`) completes, `failed`, `timeout` and `killed` end without a completion; a parent waiting on sub-agents stays running, and sub-agent sessions and legacy transcripts report none. |
| GitHub Copilot CLI | Yes | Through the `agentStop` hook | A main-agent `user.message` or `assistant.turn_start` starts the turn and loop events, including sub-agent ones, refresh it; `abort` and `session.shutdown` end it. |
| Antigravity | No | Through the `Stop` hook | Local records supply usage only. |
| Cursor | No | Through the `stop` hook | Local records supply usage only. |
| CodeBuddy | No | Through the `Stop` hook | Local records supply usage only. |
| Qwen Code | No | Through the `Stop` hook | Transcripts record no turn end; a text-only answer is not one, because a hook or a follow-up can continue the turn. |
| Hermes Agent, ZCode, WorkBuddy | No | No | Local records hold usage counters only. |
| OpenCode | No | No | A persisted message end is not an agent end. |
| GLM | n/a | n/a | Billing service; execution state belongs to the client using it. |

## Rules

### Live status

- Every execution client has Settings → Agents → [Agent] → Live status; billing-only services have none. `Settings.liveStatusEnabled(for:)` controls running indicators and completion reminders only: turning it off changes nothing in collection, session history, token statistics or quota windows, and installs or removes no adapter. With it off a session shows no state, and not what the agent last said either.
- The switch permits available observations; it never manufactures lifecycle support for a source whose logs only provide usage.
- A running turn keeps the running indicator however quiet its log goes: one tool call can take minutes without writing a line. Only an end recorded by the client, evidence that the client is gone, or, for a client with neither a process check nor a heartbeat, 30 minutes of silence (`SessionPhase.Limits.abandoned`, which counts the turn as abandoned) leaves the indicator, and none of them invents an end time in history; a failed read never creates a completion or an artificial end. A source that never says what its turn is doing keeps the older rule: 120 s (`SessionPhase.Limits.quiet`) of silence leaves the indicator. A turn waiting for approval is a running turn: every client's rule keeps it in flight as it keeps a running one, it keeps its start time, and the panel marks it in the warning colour.
- Silence counts from the newest event the client recorded: a Claude Code log's last line, a Codex rollout's newest event, a turn's latest observation. A file's modification date never counts, since writes that record nothing move it too. DeepSeek Harness has no silence limit: its turn runs while a Harness process that predates it holds the profile, checked once the log has recorded no event for 120 s. A Pi run ends with its heartbeat ([Pi observer](#pi-observer)). Sub-agents keep their session running only where the client ties them to it: Claude Code's ([Sub-agents](#sub-agents)) and GitHub Copilot CLI's, whose loop events refresh the turn.
- A session whose client waits for an answer to a permission request ([approvals](hud.md#approvals)) is waiting for approval for as long as the client waits, whatever its log says, since its turn in flight started, or since the session started when no turn is known to be in flight; the request is the session's latest event. The client holding the request open is the evidence, so no reading's age ends the wait, and the request leaving the HUD returns the session to what its log says.
- A session its source had in flight at a reading 30 minutes old or older (`SessionPhase.Limits.vouched`) is out of date: the Mac no longer vouches for that reading, so its card and its page say its status is out of date rather than show a state, and it does not count as running.
- Session lists are ordered by each session's last event — a prompt, a reply, a tool result or an approval request — newest first, so a running session that has been quiet longer than another session has been finished ranks below it. A source that reports no turns leaves the session's own end, or, while it runs, when its log last recorded anything, else the reading that last saw it running.
- A session in flight counts its time from its turn's start, or from its own start when no turn in flight has a start; any other session counts from its last event, which is also when it ended. Its card and its page count alike.
- A session shows the message of its newest turn that carries one, and none while its Live status is off. A turn's message is the agent's visible answer, never reasoning, a tool argument or a tool result. It is read up to 2 KB, kept only while the application runs, and never written to the usage ledger.
- Process evidence is separate from the last recorded observation: a quiet process does not manufacture a transcript event, and a disappeared process does not prove completion.
- The island announces each completed turn once, for clients whose Live status is on (`IslandEventTracker`). Completions that happened before the application started are history, not events, and turns that finished while Live status was off are not replayed when it is turned back on.
- Hosts that relay completions use the island's update rather than deciding again, and apply the same preference in any other relay or synchronization service.

### Hook turns

- A host that receives its clients' prompt and Stop hooks hands the turns they saw to the store (`UsageStore.hookTurns`), by session id, saying whether each is the turn the session's log reports. A hook turn takes the place of what the log says wherever the hooks saw more (`SessionPhase.hookPrevails`), so the panel changes at the Stop hook rather than at the next read of the log.
- The log keeps its word where it saw more than the hooks: work in flight after the Stop hook, such as sub-agents left running; while the hook turn is open, a wait for approval of the same turn, or that turn's end dated after the prompt; another turn, or one without an id, dated after the prompt.
- An open hook turn runs for 30 minutes from its prompt (`SessionPhase.Limits.vouched`), as a reading is vouched for, and is out of date after that, when it no longer takes the place of a log that still has the session in flight; a stopped one is finished since its Stop hook, which is then the session's last event, and what the agent said at the Stop hook, where the hook carries it, is then the session's message. With Live status off, hook turns change nothing.
- Agent HUD Open receives no prompt hooks and hands in no hook turns: the Stop hooks it installs complete their clients' turns through the providers (`SessionPhase.stopped`), which read a record as soon as a hook writes it ([Completion hooks](#completion-hooks)).

### Sub-agents

- A Claude Code session also runs while the sub-agents and workflow agents it started work, after its own agent ended its turn or went quiet waiting for them. Their logs sit in a directory named after the session's log (`<session>/subagents/`, workflow agents under `workflows/<run>/`), and their latest activity is the session's latest event.
- Each of those logs follows its own turn: its prompt starts it; `end_turn`, a `StructuredOutput` call (a workflow agent handing back its result) or a `[Request interrupted` line ends it; 30 quiet minutes abandon it, as for any running turn. An agent stopped without any of these, such as one closed with its session, keeps the session running until then.
- The session's turn keeps its id and start while its agents work. Sub-agent logs report no completions and mark no prompts, so the agent's own answer is still announced when it ends its turn.
- A session waiting for approval keeps waiting while its agents work: a request is answered by a line of the session's own log after it, never by a sub-agent's.

### Pi observer

- The standalone host installs or updates its extension under the Pi directory (`PI_CODING_AGENT_DIR`, default `~/.pi/agent`) whenever that directory exists; existing Pi processes need one `/reload`, new ones load it automatically. A same-named file that is not Agent HUD's is left alone.
- The observer writes metadata-only turn snapshots, keeps retries, compaction and queued continuations inside one run until `agent_settled`, and reports a completion only for a successful final response; errors, cancellation and shutdown end activity without claiming success. While a run is active the observer refreshes its snapshot every 15 seconds; a run whose last snapshot is 120 seconds old stops being live and ends without claiming success. Snapshots are kept 7 days.
- Token totals still come only from Pi's message transcripts; installing the observer replays no reminders and creates no usage events.

### Notification hook

A transcript shows that a tool call is pending but not whether the client is running it or asking the user to allow it, so waiting for approval comes from the client itself: a permission request waiting on the HUD marks its session, and Claude Code's notification callback marks a Claude Code turn, also once a request went back to Claude Code's own dialog and while Claude Code waits for input (`agent_needs_input`). `AttentionHooks` owns the notification hook's configuration, the callback and the local record.

| Source | Configuration | Reported |
| --- | --- | --- |
| Claude Code | Group appended to `hooks.Notification` of `settings.json` in `$CLAUDE_CONFIG_DIR` (default `~/.claude`); only commands ending in ` --attention-hook claude` are Agent HUD's | `session_id` and the client's `message`, at the callback time |

- The callback only says that the client needs the user; which kind of attention it is comes from the transcript, never from the wording of the message. A turn that is still running is waiting for approval and shows the message; a turn that already finished is waiting for the next prompt, which the transcript already said.
- A request is answered as soon as the transcript carries a line newer than it. One unanswered request is kept per session, in `attention/<source>/<hashed session id>.json` in the data directory: session id, the client's message up to 2 KB, and the time. Requests are forgotten a day after they were made; a file's own timestamps are never used for that.
- The handler command is `'<executable path>' --attention-hook <source>` with a 5-second timeout, installed and taken over by the same rules as a completion hook below.

### Completion hooks

Antigravity, Cursor, GitHub Copilot CLI, CodeBuddy and Qwen Code do not record finished turns locally, so their completions come from the clients' own stop hooks. `CompletionHooks` owns the configuration, the callback and the local record.

| Source | Configuration | Accepted as a completion when |
| --- | --- | --- |
| Antigravity | `agent-hud` entry (`Stop` array) of `~/.gemini/config/hooks.json`; `GEMINI_CLI_HOME` overrides `~/.gemini` | `terminationReason` is `NO_TOOL_CALL` (the model answered without calling a tool), `fullyIdle` is true, `error` is absent or empty, and `conversationId` is present; `executionNum` is 0 on every turn, so the turn is the callback time |
| Cursor | Handler appended to `hooks.stop` of a version-1 `~/.cursor/hooks.json`; only commands ending in ` --completion-hook cursor` are Agent HUD's | `hook_event_name` is `stop`, `status` is `completed`, and `conversation_id` and `generation_id` are present |
| GitHub Copilot CLI | `bash` handler in `hooks.agentStop` of the version-1 user hook file `~/.copilot/hooks/agent-hud.json`, `timeoutSec` 5 | `stopReason` is `end_turn` and `sessionId` is present; the turn is the callback time |
| CodeBuddy | Group appended to `hooks.Stop` of `~/.codebuddy/settings.json`; only commands ending in ` --completion-hook codebuddy` are Agent HUD's | `hook_event_name` is `Stop` and `session_id` is present; the turn is the transcript's last completed assistant `messageId` after the last user message, else the callback time |
| Qwen Code | Group appended to `hooks.Stop` of `settings.json` in `$QWEN_HOME` (default `~/.qwen`), timeout 5000 ms; only commands ending in ` --completion-hook qwen` are Agent HUD's | `hook_event_name` is `Stop` and `session_id` is present; the turn is `prompt_id` (0.23.4 and later), else the callback time. A cancelled or failed turn runs no `Stop` |

- The handler command is `'<executable path>' --completion-hook <source>` with a 5-second timeout, written in the client's own unit. Other hooks in the file are preserved. The first Agent HUD handler already in the file keeps its place and whatever a user changed in it — its group's matcher, its timeout, Antigravity's `enabled` — and only its command is set; any other Agent HUD handler goes, and a file that needs no new command is not rewritten. A settings file kept as a symbolic link, as a dotfiles checkout keeps it, is written where the link leads and stays a link, and every rewritten file keeps its permissions; approval hooks are written the same way.
- Only one copy of the application runs at a time ([command line](command-line.md#launch-and-display)), and at each start it points every Agent HUD handler at itself, whichever copy wrote it: another build, one since moved or deleted, or one that ran from a disk image. Moving the application, or starting another build, therefore moves the hooks at the next start.
- An application running from under App Translocation or `/Volumes` installs no hook and logs why. Installing a hook never starts, restarts or interrupts the client and consumes no quota.
- With Settings → General → Client hooks off, start-up installs none and removes every Agent HUD handler, whichever copy wrote it.
- The handler reads the payload from standard input and writes one JSON record per completion to `turn-completions/<source>/<id>.json` in the data directory: id, `sessionID` (`<source>:<conversation id>`), vendor, task (vendor plus workspace folder name), model when the payload names one, and receipt time. No prompt, tool argument, credential or e-mail address is stored.
- An existing record for the same id is left untouched, so repeated callbacks create no duplicates; records older than 30 days are deleted on the next write.
- The handler prints `{"decision":"stop"}` for Antigravity and `{}` for the other clients and exits 0 even when recording fails, so status tracking can never block the agent.
- Providers read the inbox for the report's history window and merge those records with completions parsed from logs; a hook completion received at or after a running turn's latest observation completes that turn.

## Code map

| Concept | Code |
| --- | --- |
| Turn, completion and session models | `Sources/AgentHUDCore/Models/SessionTurn.swift`, `SessionCompletion.swift`, `LiveSession.swift` |
| Live status preference | `Sources/AgentHUDCore/Models/Settings.swift` |
| Whether a client's records have a session in flight when its provider reads it, and the turn it reports; a session's phase at a given time, a hook turn's phase and when it takes a reading's place; the session limits | `Sources/AgentHUDCore/Logic/SessionPhase.swift` |
| A report's rows, balances, levels and sessions as the Mac shows them: each session's source, newest turn, last event, message and phase, the sessions waiting on a permission request, the hook turns in the log's place, their order, and the live sessions, working vendors and logo queue; the store's view of its report, the requests waiting and the hook turns a host hands in | `Sources/AgentHUDCore/Logic/ReportView.swift`, `Sources/AgentHUDCore/Store/UsageStore.swift`, `Sources/AgentHUDCore/Providers/Shared/PermissionRequests.swift` |
| Completion reminders | `Sources/AgentHUDCore/Logic/IslandEvents.swift`, `Sources/AgentHUDDesktop/App/DesktopApplication.swift` |
| Adapter setup, the handler command and the settings writer | `Sources/AgentHUDCore/Providers/SessionObservers.swift`, `Shared/HookCommand.swift`, `Shared/HookSettings.swift` |
| Completion hooks and handler entry | `Sources/AgentHUDCore/Providers/Additional/CompletionHooks.swift`, `Sources/AgentHUDOpenApp/main.swift` |
| Pi observer and its extension script | `Sources/AgentHUDCore/Providers/OpenAgents/PiSessionObserver.swift` |
| Per-client turn parsing | `Sources/AgentHUDCore/Providers/Claude/ClaudeTranscripts.swift`, `Codex/CodexTranscripts.swift`, `DeepSeek/DeepSeekTranscript.swift`, `Grok/GrokSessions.swift`, `OpenAgents/OpenAgentSessions.swift` |
| Claude sub-agents keeping their session running | `Sources/AgentHUDCore/Providers/Claude/ClaudeCodeProvider.swift` |

## Related

[providers.md](providers.md) per-client reads and counting · [command-line.md](command-line.md) adapter commands · [architecture.md](architecture.md) host integration and hook ownership
