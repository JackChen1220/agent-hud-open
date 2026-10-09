# Project branches

The island footer switches between Agent usage and project branches. Agent is the startup default; the selected tab survives collapsing the panel during the same run. Command–Shift–H toggles the panel on the pointer's screen and holds it open until dismissed. A second press closes the keyboard-opened panel even if the pointer moved to another screen. Outside clicks close it; Escape closes it when the panel has keyboard focus. Existing Command–Option–H still controls HUD visibility. General settings can record another Command/Control plus letter/number combination, disable it, or restore the default; registration conflicts are shown there.

## Add and inspect projects

Choose Branches → Add project. Select a repository directly, or a parent directory to choose from discovered repositories. Discovery stops after three levels, 2,000 directories or 100 candidates, skips hidden/dependency/build folders and symbolic-link directories, and never automatically registers all results. Deeper repositories can be added directly. Linked worktrees share one project by canonical common Git directory; independent clones remain distinct.

The panel ranks pinned, currently checked-out and worktree branches ahead of recent local branches. All includes cached remote refs; Needs review includes ahead/behind/diverged, missing upstream and unconfigured upstream states; it is a filter, not an automatic sync action. Search and branch details live in the resizable project window. Task titles, notes, pinning and manual progress are stored locally. Manual progress uses colored labels (developing blue, integration purple, testing orange, complete green, paused/unmarked gray). Removing a project from the list never removes its files or branches.

Ahead and behind compare against the configured upstream, even when its name differs from the local branch. No upstream does **not** mean unpushed. Matching cached refs does **not** establish the current server state. Every remote has its own last successful explicit fetch time; a failed fetch remains visible even after a successful local refresh. Manual completion is independent of Git sync, merge, test or deployment state. GitLab/GitHub MR/PR/CI integrations are not part of this version.

TEST/UAT targets can be selected per project in branch details. Existing `origin/test` / `origin/uat` refs (case-insensitive), or local equivalents, are initial defaults; other naming conventions require selection. The app asynchronously checks `merge-base --is-ancestor` against snapshot commit IDs and shows Included / Not fully included / Unknown. This identifies commit ancestry, not deployment or test completion. Cherry-picked and squash-merged changes may be equivalent without sharing ancestry, so Not fully included does not claim the code was never transferred. Cached remote refs remain explicitly labelled as cached.

## Explicit branch actions

The branch detail window offers switching, committing, pushing and local branch deletion. Each opens a review sheet identifying the directory, branch, selected files or remote destination. Operations are serialized per common Git directory and revalidate the reviewed HEAD/ref/destination before executing. These controls do not operate automatically and there is no merge or force action.

- Switch affects the tracked project directory. Compatible staged, unstaged and untracked changes carry over to the target branch without committing or stashing. Git refuses changes that would overwrite local files; ignored files are protected too. Unresolved conflicts and in-progress merge/rebase/cherry-pick operations remain blocked, and submodules are not recursively switched. A local branch already checked out elsewhere must be opened in that worktree instead. Remote refs can be checked out as a newly named tracking branch.
- Commit lists paths with NUL-safe rename handling. Files start unselected; the user chooses files and supplies the message. It commits each selected file’s entire current state using `commit --only`, preserving unrelated staged changes. Hooks and signing are respected. If commit fails after staging, the UI says so; it does not reset or discard the user’s index.
- Push requires reviewing the configured push URL (credentials stripped from display), source commit and destination branch. Only an explicit click sends commits and required code objects to that remote. An explicit non-force refspec disables mirror/follow-tags/submodule side effects. Multiple configured push URLs must be handled in Terminal. Upstream registration is an explicit checkbox.
- Delete removes only the local ref via `branch -d`, never remote branches or folders. Current/worktree-occupied branches and branches Git considers unmerged are refused. No `-D` option is exposed.

The Refresh menu distinguishes local reads from fetching remote refs. Connection closure, authentication, TLS, lock, rejection and timeout failures are classified without exposing raw stderr or credentials.

Worktree status is separate from branch history. Counts include changed tracked files and untracked entries (an untracked directory counts as one entry), with submodules excluded. A worktree checked out on a different branch during collection is left unchecked rather than attributing its changes to the old branch. Prunable and detached worktrees are retained in repository metadata.

## Performance and data boundary

- `RepositoryStore` is independent of `UsageStore`. Cached data is loaded asynchronously at startup; opening a panel never waits for Git or a network request.
- Ref metadata is published before worktree checks. Only visible branch surfaces watch the selected common Git directory, coalescing signals at three-second intervals and checking working-tree status every 30 seconds. Hidden windows, Agent pages and offscreen size measurements do not subscribe. In-flight reads finish or time out; quitting cancels them.
- Commands run asynchronously through the bounded `ChildProcess` runner: 10-second local deadlines, 30-second fetch deadline, 4 MiB stdout cap. A timed-out or oversized result never replaces the cache with partial refs.
- Reads and actions use `/usr/bin/git` with literal pathspecs and argument arrays, never a shell. The feature collects paths, refs, commit subjects/times and status counts; it does not collect source bodies, diffs, conversations or credentials. Git itself may inspect working files to compute status.
- Only an explicit remote-refresh action invokes `git fetch`; an explicitly confirmed push is the other network operation. It uses the configured remote, disables hooks/automatic maintenance/submodule recursion/tags, supplies its own remote-only destination and clears configured ref mappings with `--refmap=`. These fetch restrictions are separate from the explicit branch actions above.
- Existing Git credential helpers/SSH configuration provide authentication. Interactive terminal prompts are disabled. Raw stderr, which can contain credential-bearing URLs, is never displayed, logged or cached.
- Project configuration, cached metadata, notes and fetch times are stored in `repositories-v1.json` in the application's data directory, with mode `0600`. Nothing in this feature sends repository metadata to an AI service or telemetry endpoint. This does not alter the pre-existing usage providers' network behavior.

## Verification

`RepositoryTests` creates temporary local repositories and bare remotes to cover different-name upstreams, ahead state, worktree identity, custom fetch mappings, NUL-delimited rename/conflict status, local persistence permissions and old settings compatibility. `RepositoryActionTests` covers selected-file commits, hooks, renamed/deleted paths, compatible dirty-worktree switching, overwrite refusal, reviewed push destinations, non-force deletion and ancestry checks. `HubPanelTests` covers immediate tab/window height synchronization and keyboard hold/dismissal and renders `build/branch-panel-preview.png` from synthetic data.

An optional read-only real-repository probe is available:

```sh
AGENTHUD_TEST_REPOSITORY=/path/to/repository swift test --filter RepositoryTests.testInstalledRepositoryReadPerformance
```

It never fetches or prints source/paths/subjects. On the development machine, the CRM example's 107 refs and 13 worktrees took approximately 78 ms for metadata and 596 ms including all worktree checks. This is an observed local result, not a latency guarantee.

Manual progress includes Unmarked, Developing, Awaiting integration, Awaiting tests, Testing, Awaiting merge, Awaiting release, Complete and Paused. The persisted `testing` value keeps its original Awaiting tests meaning; the three new states have separate values and colors.
