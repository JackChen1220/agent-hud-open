# Session navigation

## Overview

A completion reminder offers token usage on the left and session return on the right. In the panel's session list, the title returns to the agent and the token count opens usage. The client owns the session identity; the desktop layer opens it after collapsing the HUD. An unavailable destination leaves token usage available, and a rejected return remains available for retry.

## Model

| Client | Target | Capture |
| --- | --- | --- |
| Codex Desktop | Native thread ID | The rollout's Desktop client identity and session ID |
| Codex CLI in iTerm2 | Existing terminal session ID | A direct CLI origin hook, or the shared daemon's thread-specific TUI endpoint matched to its live terminal process |
| Claude Code CLI in iTerm2 | Existing terminal session ID | Session start and prompt hooks verify the native interactive CLI and capture its terminal environment |
| Claude Desktop Code | Native desktop session ID | Desktop metadata maps the CLI session ID to its existing local tab |
| Claude Desktop Cowork | Native desktop session ID | Cowork metadata maps the CLI session ID to its existing local tab |
| Pi in iTerm2 | Existing terminal session ID | The extension's own process environment |
| OpenCode in iTerm2 | Existing terminal session ID | The plugin's own process environment |
| Antigravity standalone | Conversation ID | The client's completion hook |

## Rules

- Codex CLI targets its own iTerm2 session. IDE sessions require their own destination and do not open Codex Desktop.
- Shared Codex daemon navigation reads the thread's `codex_tui` endpoint and matches its loopback listener to a live Codex TUI of the current user; the daemon's inherited terminal environment never supplies a target.
- Direct Codex CLI origin hooks record the latest host at session start and prompt submission. An explicit Desktop or unsupported direct CLI observation replaces an earlier destination, including a still-running TUI endpoint.
- Codex origin hooks require the client's native hook support and trust approval; shared daemon navigation does not require these callbacks.
- Claude origin hooks record the latest host at session start and prompt submission. A direct CLI origin or an unsupported host replaces an earlier Desktop destination; print, background, SDK and IDE observations cannot borrow the Desktop mapping.
- Claude Desktop navigation resolves the exact CLI ID through native local-session metadata, ignoring archived, mismatched or ambiguous records. Code and Cowork retain their distinct native routes.
- A later transcript that identifies a different Claude host clears an older origin; a newer origin callback remains authoritative over an earlier transcript reading.
- Pi and OpenCode record iTerm2 targets only when `TERM_PROGRAM` identifies iTerm2 and `ITERM_SESSION_ID` is present; a process running inside tmux records no target.
- A later observer event replaces the earlier terminal identity, including clearing it when the session moves to an unsupported host.
- Antigravity navigation requires the running standalone app to publish its local debugging endpoint and expose its conversation page; an unavailable endpoint or a rejected page navigation leaves the reminder available for retry or token usage.
- A project directory, window title or running application alone never identifies a conversation.
- Targets stay local: report caches and remote serialization omit them; sources reconstruct them from their own records.
- URL dispatch confirms that the system accepted the request; it cannot confirm that a previously captured iTerm2 pane or Codex thread still exists.
- A terminal destination focuses its existing pane. Switching conversations inside that pane does not give Agent HUD a command to restore the earlier conversation.
- Reload Pi's extensions or start a new Pi session, and restart OpenCode, to load an updated observer.

## Interfaces and configuration

| Interface | Behavior |
| --- | --- |
| `SessionNavigationTarget` | Typed client identity, carried in memory by sessions and completions |
| `codex://threads/<thread-id>` | Opens the existing native Codex thread |
| `claude://claude.ai/epitaxy/<local-session-id>` | Opens the existing Claude Desktop Code tab |
| `claude://claude.ai/cowork/<local-session-id>` | Opens the existing Claude Desktop Cowork tab |
| `iterm2:reveal?sessionid=<session-id>` | Reveals an existing iTerm2 session |
| Antigravity local page | Navigates the running app's page to `/c/<conversation-id>` |

## Code map

| Concept | Code |
| --- | --- |
| Local target model | `Sources/AgentHUDCore/Models/Sessions/SessionNavigationTarget.swift` |
| Client dispatch | `Sources/AgentHUDDesktop/App/SessionNavigator.swift`, `AntigravityNavigation.swift` |
| HUD navigation | `Sources/AgentHUDDesktop/Notch/ScreenHUD.swift`, `Alerts/IslandAlertViews.swift`, `Panel/HoverPanelView.swift` |
| Observer capture | `Sources/AgentHUDCore/Hooks/PiSessionObserver.swift`, `OpenCodeSessionObserver.swift` |
| Codex terminal identity | `Sources/AgentHUDCore/Hooks/CodexSessionOrigins.swift`, `Sources/AgentHUDCore/Providers/Codex/CodexTerminalOrigins.swift`, `CodexDaemonOriginTransport.swift` |
| Claude session identity | `Sources/AgentHUDCore/Hooks/ClaudeSessionOrigins.swift`, `Sources/AgentHUDCore/Providers/Claude/ClaudeCodeProvider.swift`, `ClaudeDesktopSessions.swift` |

## Related documentation

- [Session lifecycle](session-lifecycle.md)
- [The HUD on screen](hud.md)
- [Codex deep links](https://learn.chatgpt.com/docs/reference/commands#deep-links)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [iTerm2 URL scheme](https://iterm2.com/documentation-url-scheme.html#reveal)
