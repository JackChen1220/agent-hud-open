# Data access

## Overview

Agent HUD Open reads agent activity and usage metadata on your Mac. It has no Agent HUD account, cloud synchronization or push service. Building it requires no developer account, product credential, provisioning profile or signing certificate; local builds use ad-hoc signing.

## Providers

| Client | Local data | Quota or balance queries |
| --- | --- | --- |
| Claude Code | Session records, account profile, local session-origin hook records and Desktop session identifiers | Installed Claude engine usage interface |
| Codex Desktop / CLI | Session records and sign-in time, including `CODEX_HOME` | Installed Codex app-server account rate limits |
| DeepSeek Harness | Session records and profile-owning Node process metadata, including `DSH_HOME`; its web host's pending questions on loopback | Official DeepSeek balance endpoint with the configured Harness API key, which Harness's own credentials package resolves inside a short-lived Node helper |
| Antigravity | The process list (`ps`) and the listening port of the running language server (`lsof`), whose command line holds its local token; conversation metadata | A local `POST` to that language server on 127.0.0.1 |
| Kiro | Existing sign-in record/profile ARN; CLI session snapshot metadata (title, working directory, model, timestamps, counters and credits); no project files or transcript JSONL | Official Kiro credits endpoint, using its existing bearer token |
| Cursor | Local application database and session metadata | Official Cursor usage endpoints with the installed client's session token |
| Grok CLI | Local session records and credential file | Official Grok CLI billing endpoint |
| OpenCode, Kimi, GLM, Pi | Local JSON/SQLite session records and supported provider configuration, including an `ANTHROPIC_BASE_URL` and its token from the environment or Claude Code's `settings.json` `env` that point at a Kimi or GLM plan; automatically prepared Pi lifecycle observer and OpenCode completion plugin | Official Kimi, GLM, OpenCode Go, and Pi ChatGPT quota endpoints where configured |
| GitHub Copilot CLI | Local session events and OpenTelemetry export files | GitHub Copilot quota endpoint with the GitHub CLI sign-in, only after consent in Settings |
| OpenClaw, Hermes Agent, ZCode, CodeBuddy, WorkBuddy, Qwen Code | Local session databases and transcripts | None |
| Qoder, Qoder CN, QoderWork | Nothing read; the approval hook is added to each build's settings | None |

Per-client fields, endpoints and stored data: [providers](providers.md). Token counts, percentages, alert levels, request intervals and reading retention: [usage semantics](usage-semantics.md).

## Credentials

- A provider that needs a key or token reads it from the client's own configuration, environment variables or local credential files, uses it only for that provider's usage request, and never includes it in reports or stored data.
- Claude and Codex quota queries use the installed clients' existing sign-in. Codex's ID-token sign-in time is read locally to choose the client that reads the account; its access and refresh tokens are not used. Pi ChatGPT OAuth uses the existing access token for the official usage endpoint, without using its refresh token or writing credentials. No request sends a model message or consumes a usage-reset credit.
- Account identity comes only from data a provider already reads or a response it already requests: the Claude profile, Codex `account/read` and Pi’s authenticated ChatGPT usage response, Cursor's local database, the Grok login record, Antigravity's local server and, for GitHub Copilot, GitHub's `/user` response. Provider user and workspace ids are stored as hashes; the account's email or name is kept locally to label its rows.
- GitHub Copilot quota reads no credential until the user confirms Settings → Agents → GitHub Copilot → Read quota; the dialog, shown each time it is switched on, names the environment variables, the keychain item `gh:github.com` and the GitHub CLI `hosts.yml`, and macOS may ask for keychain access. Switching it off forgets the account, its rows and its quota history at once.
- OpenClaw's agent database also stores authentication profiles; only its session tables are queried.
- Custom endpoints are not assumed to share official billing accounts, and executable key resolvers are never run.
- Kimi account identity is confirmed through the official profile endpoint, separately for each deployment; only hashed credential-to-account associations are cached, and accounts are never merged from matching quota values, reset times or unverified token claims.
- DeepSeek session liveness inspection reads executable identity and start time. Question-host discovery reads command names, profile and port arguments; it does not read profile contents or browser credentials.

## Local storage

- Preferences use the application's UserDefaults domain; the usage ledger, the restart copy of the report and completion records live in `~/Library/Application Support/Agent HUD Open`. Local metadata can include workspace paths and session titles, and a title can be the first line of a prompt, cut to 60 characters; raw conversation bodies and authentication secrets are never stored.
- `~/Library/Caches/app.agenthud/instance.lock` keeps a second copy of the application from starting while one runs; it holds the path of the running copy's executable and nothing else.
- Quota, balance and account-wide usage requests run between local polls, one provider at a time and at most once a minute each: more often while that client works, every 5 minutes for a client nobody is using ([cadence](usage-semantics.md#collection-cadence)); a missing or signed-out client does not prevent other sources from reporting.
- Saved readings appear immediately after a restart with their original observation times; a failed refresh keeps them and reports the failure. Unavailable quotas are never inferred from token counts.
- Readings of an account a client is no longer signed in to stay until the account has not been seen for 30 days.
- A completed credential scan retires expired, removed or rejected OpenCode Go, Kimi and GLM quota rows, including cached rows and saved display settings.
- The approval hook adds one handler to a client's own settings or hooks file, leaving every other hook in it alone, and refuses to rewrite a layout it does not recognize. Codex CLI and Desktop share that handler; their hook trust and feature settings stay under Codex's control. ZCode runs no hook until its hooks switch is on, so an absent switch is set and one the user turned off is left off; a rewritten file keeps its permissions. Settings → General → Client hooks off removes Agent HUD's handlers from every client and adds none back; removing never creates a file the client did not have. What it carries — the tool, its input, the folder and the client's own rule suggestions — is read in memory to draw the card and is never stored; the answer goes straight back to the client that asked ([approvals](hud.md#approvals)).
- Optional completion hooks write one small local record per finished turn (session and turn identity, model, workspace folder name and time) and nothing else; they send no notifications and upload nothing ([completion hooks](session-lifecycle.md#completion-hooks)).
- Claude and Codex origin hooks keep the latest session ID, host type, time and optional destination locally. They inspect the native callback process and never store its arguments or the hook's prompt. Claude Desktop navigation decodes only session identifiers and archive status from its Code and Cowork metadata; unrelated prompt, configuration and account fields are ignored. Shared Codex daemon navigation reads loaded thread IDs and the thread's local TUI endpoint through the running daemon, then matches its listener to a live Codex process of the current user. Only terminal identity variables are decoded; no model request or MCP tool is invoked, and navigation destinations are omitted from report caches and synchronization ([session navigation](session-navigation.md)).
- Pi's extension and OpenCode's plugin run inside those clients and write only metadata records of their turns — session and turn identity, workspace, the session's title, model, provider and times — beside the client's own data; they make no request and upload nothing ([observers](session-lifecycle.md#observers)).

- Antigravity approvals are read from its already-running local service, without changing its permission settings or installing a tool-execution hook. Only the user's explicit allow-once or deny sends an interaction answer to that same service; credentials and waiting tool inputs stay in memory. Client hooks off stops the observer.
- DeepSeek Harness's questions are read from its web host's loopback event stream and answered back on 127.0.0.1; only the answers the user gives on the HUD are sent, and nothing is written to Harness's files. Client hooks off stops the reading.

## Related

[providers.md](providers.md) per-client details · [usage-semantics.md](usage-semantics.md) counting and retention · [session-lifecycle.md](session-lifecycle.md) turn evidence · [../THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt) provider protocol references and licenses

- Kiro quota reads use its existing `~/.aws/sso/cache/kiro-auth-token.json` bearer token with the official, region-allowlisted management endpoint. The request is read-only; it does not refresh or rewrite credentials and never sends project data. An expired sign-in asks the user to open Kiro.
