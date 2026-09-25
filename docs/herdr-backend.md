# Herdr runtime backend

This page covers running Firstmate workers on the Herdr runtime backend: setup, where tasks appear, how they are cleaned up, how input reaches them, and how their liveness is read.
Operators who choose Herdr, or who verify Firstmate against it, need it.

Herdr is an agent-native terminal backend with native per-pane agent state and push events.
Firstmate requires Herdr protocol 14 or newer.
Broad backend verification covers versions 0.7.1, 0.7.3, 0.7.4, 0.7.5, and 0.8.0.
Protocol-16 features remain gated by availability.
Default-on presentation spaces have a higher floor of Herdr 0.8.0 for the reason given under [Presentation spaces](#presentation-spaces).
Herdr provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Find a topic

| What you want to know | Start here |
| --- | --- |
| Install Herdr and select it | [Setup](#setup) |
| Why a command ran on a different `herdr` client | [Client selection](#client-selection) |
| Where task tabs appear and how to watch them | [Watching and task containers](#watching-and-task-containers) |
| The one-task workspaces, their setting, and their cleanup | [Presentation spaces](#presentation-spaces) |
| Why a seeded default tab is or is not closed | [Default-tab prune safety](#default-tab-prune-safety) |
| What task metadata records for a Herdr endpoint | [Endpoint metadata](#endpoint-metadata) |
| How text and keys reach a worker and how delivery is confirmed | [Current transport behavior](#current-transport-behavior) and [Composer and injection safety](#composer-and-injection-safety) |
| What happens after a Herdr server restart and how liveness is judged | [Restart and liveness behavior](#restart-and-liveness-behavior) |
| How blocked transitions arrive and what happens without protocol 16 | [Push events and polling fallback](#push-events-and-polling-fallback) |
| Where the away daemon runs and how it stops | [Away-mode supervisor support](#away-mode-supervisor-support) |
| Stopping or deleting Herdr sessions during verification | [Destructive lab safety](#destructive-lab-safety) |
| Known limits and the test suite | [Active limits](#active-limits) and [Regression entry points](#regression-entry-points) |

## Setup

Pick Herdr when you want native busy, idle, and blocked state and accept the [active limits](#active-limits) below.

Prerequisites:

- Herdr protocol 14 or newer, installed from [herdr.dev](https://herdr.dev).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- `python3` only for optional protocol-16 presentation-space ordering and native event subscription.

Herdr is dual-licensed AGPL-3.0-or-later or commercial.
Firstmate invokes its CLI as a separate process.

### Selecting Herdr

Select Herdr in any of these ways:

- Local `config/backend` containing `herdr`.
- `FM_BACKEND=herdr` for one launch.
- An explicit request to Firstmate.

A remote second-mate agent is the one case with no choice: it always runs on Herdr, and [`remote-secondmates.md`](remote-secondmates.md) owns that requirement and the readiness its host must meet.

Herdr is also auto-detected when the primary runs natively under `HERDR_ENV=1` and is not inside tmux.
A tmux pane nested inside Herdr resolves to tmux because the innermost multiplexer wins.
An auto-detected Herdr spawn stays silent, matching the verified tmux default path.

### Spawn preflight and CI

Spawn stops before creating a Herdr container or acquiring a task worktree when `herdr`, `jq`, or the protocol floor is unavailable.
No separate first-run provisioning is required.

The required CI lane uses the pinned installers in `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`.
Those script headers own release assets, checksums, download bounds, and post-install gates.
Real harness credential tests remain opt-in rather than part of default CI.

## Client selection

Each operation routed through the adapter's session-scoped CLI helper starts with the first `herdr` on `PATH`, unless that session has already selected another client.

A host can carry more than one client, such as a self-updated copy in `~/.local/bin` beside a package-managed one.
A client older than the running server can receive error code `protocol_mismatch` on operational commands.

### Recovering from a protocol mismatch

On a `protocol_mismatch` refusal, the adapter:

1. Reads `status --json --session <name>` from each distinct `herdr` on `PATH`, in order.
2. Adopts the first one the running server reports compatible.
3. Retries the command on it once.

The choice is reused only for later calls to the same session in that process.
Another session starts with the `PATH` default.
A later mismatch forces selection again, so a changed server can return to that default.

Selection also follows these rules:

- Ordinary adapter operations make no selection read on the happy path.
- Status that supplies neither `.server.compatible` nor both client and server protocols leaves compatibility unknown.
- No other failure triggers a reselection.

`fm-remote-doctor.sh` reports the client selected for the remote session.
Removing or upgrading the shadowing client is the durable fix.
`bin/backends/herdr.sh` "client selection" owns the mechanics.

## Watching and task containers

The ordinary topology puts one task tab per endpoint in the exact workspace of the Firstmate or secondmate that launches it.
When the launcher has no Herdr workspace to inherit, the adapter maintains one durable home-labeled workspace instead.

| Home | Workspace label |
| --- | --- |
| Primary | `firstmate` |
| Secondmate | `2ndmate-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker |

A secondmate launched by the primary receives a narrowly scoped home override during container creation.

### Watching tasks

Attach to the selected named Herdr session and switch to the relevant home workspace to watch its task tabs.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without attaching.

### Focus

Workspace and tab creation use `--no-focus`.
The first workspace in a completely empty Herdr session must become focused, because no prior target exists.
Later task creation does not intentionally steal focus.

### Placement beside the launcher

Herdr does not enforce workspace or tab label uniqueness, so a label can never decide where a worker goes.

Herdr 0.7.5 exports `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` into every process it manages a pane for.
A Firstmate or secondmate agent's own commands inherit them.
Older injection shapes are unverified, so a claimed launcher pane without the injected socket identity cannot be trusted.

With presentation spaces disabled, a crewmate or scout is created in the exact workspace that identity currently resolves to.
That workspace is read live from Herdr rather than from the injected snapshot, so the worker always appears beside the agent that launched it.
Duplicate labels elsewhere in the session are irrelevant, and the globally focused workspace is never the target.
A `--secondmate` launch is the deliberate exception: it stands up that secondmate home's own workspace instead of joining the launcher's.

### Unresolvable launcher identity

A claimed parent identity that cannot be resolved exactly stops the spawn before any worker endpoint exists, rather than falling back to a label search.
That covers:

- A missing or unusable socket identity.
- A closed or unreadable launcher pane.
- A pane and tab that disagree about their workspace.
- A workspace missing from the session.
- A pane belonging to another named session or Herdr server.

### Firstmate running outside Herdr

Firstmate running outside Herdr entirely has no launcher workspace to inherit, so its workers use this home's own labeled workspace, created on first use.
That path needs the home label to identify exactly one workspace.
Two workspaces sharing it are an unresolvable placement and refuse rather than adopting either.

Avoid naming a personal workspace `firstmate` or `2ndmate-<id>` for that reason.
Also avoid it because the adapter cannot distinguish that label collision from its own container.

An older secondmate workspace using `firstmate-<id>` is not migrated automatically.
Rename it manually before expecting new tasks or recovery to use it.

### Recovery and existing tasks

Recovery and list-live still scan the first workspace matching the home label, because they address panes they already recorded rather than choosing where new work goes.
The one recovery that does place new work is the control plane's reclaim of a destroyed endpoint.
It mints a replacement tab through this section's ordinary placement rules while pinning the herdr session the task's record names ([`agent-control.md`](agent-control.md) "Reclaiming a task whose endpoint is gone").

Existing task operations use recorded endpoint ids and do not move a live task when labels change.
The per-home workspace is reused while it has task tabs.
Closing its last tab can remove the workspace, and the next spawn recreates it.

## Presentation spaces

Each new crewmate or scout is placed in a disposable one-task workspace by default, on Herdr 0.8.0 and newer.
This section calls that one-task workspace the projection.
Without the projection, tasks use the ordinary flat layout described under [Watching and task containers](#watching-and-task-containers).

### Setting values

The local gitignored `config/herdr-presentation-spaces` file controls the projection.

| File state | Result |
| --- | --- |
| Absent | Leaves the choice to the version floor below (the unconfigured default). |
| `off` | Opts the home out. |
| `on` | Forces the projection on, as a deliberate opt-in. |
| Empty | A deliberate opt-in, the same as `on`. |
| Any other value | Warns and follows the unconfigured default rather than failing a spawn over a purely visual setting. |

Values are compared with whitespace stripped and case ignored.

The empty file is the historical presence-based opt-in form.
So every home that had already enabled the projection stays enabled with no migration step.
No previously enabled home can be turned off by the default or by the floor.

A home that never created the file gains the projection at its next Herdr spawn on a supported release.
That flip is deliberate.
It reaches only the Herdr backend, because no other runtime backend has a projection path.

### Why the default needs Herdr 0.8.0

Projecting each task into its own workspace makes every task cleanup a workspace-emptying removal.
That is the only removal shape Herdr's pre-0.8.0 focus defect touches.
The focus-safe removal plan below can only avoid the defect while the closing pane's shell can be proved lone, childless, and idle.

A persistent child of that shell - a `gitstatusd`, a `zsh-async` worker, or `direnv` - fails that proof permanently and forces the plain explicit close.
On those releases, that close moves the active workspace for roughly a seventh of a second before the restore backstop pulls it back, once per task cleanup.

An unconfigured home is therefore projected only on a release at or above the 0.8.0 floor.
On those releases every workspace-removal primitive preserves focus, and that proof stops being load-bearing.

Below the floor, an unconfigured home uses the ordinary flat per-home layout instead.
It warns once per home per detected release, naming the running release and the upgrade that restores the projection.
That one-warning-per-release record is a `state/.herdr-presentation-floor-<release>` marker.
Deleting it only makes the same warning appear again.
An upgrade or downgrade re-announces itself because the release is part of the key.

### How the floor is checked

The floor reads two sources:

- The installed client's protocol and version.
- The selected named session's server signals, while that server is running.

Both applicable releases must pass.
When status positively reports no running server, the floor uses only the client, because that client will start it.

The unconfigured default is rechecked after the server is started or adopted, and before any presentation journal or workspace is created.
An unreadable server state or release is treated as unsupported rather than guessed at.

An explicit `on` is honored below the floor, so a home that deliberately opted in is never silently downgraded.
That home accepts the documented focus move, and the exact prior-tab restore stays its backstop.

The floor has a single owner, the spawn-time gate.
So cleanup for a projection that already exists always runs and never strands a workspace, whatever release the home is on now.

Upgrading Herdr to 0.8.0 or newer is the fix.
Writing `off` is the immediate mitigation for a home that cannot upgrade yet.

### Secondmate homes

The setting is inherited into secondmate homes through the normal configuration-convergence owner.
The default needs no special convergence.
The primary's absent file and the secondmate's absent file both mean the same unconfigured default.
So leaving the file absent converges a secondmate to that same default rather than turning it off.
Only an explicit primary `off` propagates the opt-out.

A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An unconverged opt-out keeps the default projection in that home until convergence.

### Presentation journal

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
A presentation journal is the per-task record in this home's `state/` that binds a task to its projected workspace.

Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Creation proceeds in this order:

1. Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token, before asking Herdr to create anything.
2. After the new workspace converges to one exact task endpoint beneath one exact parent workspace id, the journal advances to a version 2 binding.
   That binding records the physical home, named session, endpoint, parent, and immutable expected labels.

Another parent with the same presentation label does not prevent publication or participate in restart reclaim.

The token is visible in the workspace title, because Herdr exposes no verified hidden persistent field.
Neither token, title, nor journal authorizes send, capture, task ownership, Treehouse return, or general recovery.

### Owning parent and tabs

The owning parent is the launcher's own exact workspace, resolved from the same identity the flat path uses.
It falls back to a unique home-label lookup only for a Firstmate outside Herdr.
Projected children are never collapsed back into that parent.
The parent is the placement and ordering reference the projection is bound under.

The normal `fm-<id>` task tab is created in the exact new workspace returned by Herdr.
Only the exact seeded default tab returned by the same workspace-create response can be pruned.
Before and after create, prune, order, abort cleanup, and normal cleanup, Firstmate verifies exact workspace, tab, pane, and active-focus ids.
An ambiguous response grants no mutation or cleanup authority.

### Ordering

Protocol 16 exposes `workspace.move` over the named session socket but no CLI subcommand.
`bin/backends/herdr-workspace-move.py` sends only that whitelisted method and verifies the complete returned workspace order.

Projected children are placed in one contiguous block immediately after their owning home when all of these are verifiable:

- The session layout.
- The protocol.
- The socket.
- `python3`.
- The machine-private per-session lock.

Existing legacy child labels may extend an already adjacent block read-only but are never renamed or migrated.
A foreign, ambiguous, detached, or manually interleaved child makes ordering skip with a warning rather than rewriting the layout.

Ordering failure never fails the task spawn.
Firstmate does not retry, adopt, reuse, close, delete, or rename anything in response to an unavailable method, lock contention, ambiguous socket, lost response, failed move, or verification mismatch.
The worker remains on the ordinary flat or Herdr-current-order path.

### Cleanup and focus safety

Normal task metadata remains the sole endpoint authority after creation.
Cleanup closes only the exact recorded task pane and never calls `workspace close`.

Herdr 0.7.5's explicit close moves focus to a neighbor whenever it empties a non-focused workspace.
Its pane-death removal preserves the focused workspace whenever the dying workspace sits behind it or the focused workspace is last.
Both behaviors are fixed in Herdr 0.8.0, and the exact rules live in the adapter header of `bin/backends/herdr.sh`.

Projected cleanup therefore:

- Runs under the same session lock.
- Refuses to delete the tab a live foreground client is viewing.
- Treats a workspace-emptying close as a focus-safe removal.

A focus-safe removal takes these steps:

1. Verify the close would empty the workspace.
2. When needed, reposition the doomed workspace behind the focused one through the verified `workspace.move` transport.
3. Prove the pane holds one lone idle shell.
4. End that shell, so Herdr removes the emptied workspace through its focus-preserving pane-death path.

The persisted `.focused` pointer is not a live viewer.
When `herdr terminal title clear` reports `no_foreground_client`, cleanup proceeds on that tab because no human is attached, and skips restoration of the tab it destroys.

Herdr currently has no atomic client-aware mutation.
So a fresh target-focus and foreground-client checkpoint runs immediately before each move, signal, or explicit close.
When a live viewer has switched to another tab, that fresh tab becomes the restore target.
A client can still attach or switch focus in the residual checkpoint-to-mutation window.
A durable atomic close is deferred until Herdr exposes that primitive.

The repositioning move-to-last preserves every surviving workspace's relative order.
Removal is confirmed against the exact moved workspace rather than inferred from pane disappearance.
An unconfirmed removal then makes one verified attempt, under the same session lock, to roll the doomed workspace back to its exact original position.
If that rollback cannot restore the verified original order, cleanup warns loudly and leaves the retained records for inspection rather than retrying the shared-layout mutation.

The pane-death signals are pid-exact.
The escalation re-reads the pane's process information and refuses unless the same shell pid still passes the strict bare-idle ownership proof, so an exited and reused pid is never signaled.

A move-plan ambiguity, unsupported or failed move, or unproved shell falls back to the plain explicit close.
Exact tab restoration remains the backstop whenever a surviving tab must be preserved.
So degraded behavior is never worse than the pre-mitigation sub-second restore.

### Ordinary removal and cleanup locking

Ordinary non-projected task removal:

- Serializes through the same session lock.
- Applies the same focus-safe plan when its close would empty a non-focused workspace.
- Keeps the legitimate plain close when the target is the active tab.
- Refuses an unlocked close if the lock cannot be acquired.

Task cleanup acquires that session lock before the task's isolated copy is returned.
So a contended lock refuses up front while the copy, every durable record, and the endpoint are all intact for a plain rerun.

Forced secondmate cleanup recursively preflights every Herdr child endpoint and acquires every affected named-session lock before mutating any child.
It then retains each child's durable identity unless that exact pane returns structured not-found after its close.

### When task records are erased

Durable task records are erased only once the exact pane is confirmed gone through its structured presence.
After every close path, only a structured not-found response counts as gone.
A present or unknown result retains every record with a visible, retryable error.
Missing or malformed endpoint identity and missing confirmation machinery are ambiguity, never proof of a gone pane, and refuse record removal the same way.
If lock, snapshot, pane identity, or restoration is ambiguous, cleanup warns and preserves the journal for manual inspection.

### Restart recovery

Recovery is deliberately conservative and presentation-only.
An existing journal suppresses another projected create.
Before any recovery mutation, Firstmate holds both the task spawn lock and the named-session presentation lock.

A same-identity version 2 binding may replace one exact agent-free restart husk in place.
A husk is a restored same-labeled tab with a missing pane or no registered agent, as [Restart and liveness behavior](#restart-and-liveness-behavior) describes.
The replacement is allowed only when all of these agree:

- The physical home.
- The session.
- The metadata endpoint.
- The unique token match.
- The workspace shape and labels.
- The parent identity and placement.
- The non-target focus snapshot.

The replacement tab and pane are created and verified before the old pane is rechecked and closed.
Then the journal advances atomically to the replacement endpoint before metadata publication.
The reclaim path never moves, closes, deletes, or renames a workspace and never touches a parent, sibling, captain, or foreign pane.
A failed replacement rolls back only the exact response-derived new pane when focus-safe verification permits it.

These cases fall back flat without mutating the old projection when duplicate-agent risk is positively absent:

- Version 1 journals.
- Dead or missing panes.
- Duplicate or absent tokens.
- Renamed or detached spaces.
- Cross-home mismatches.
- Inconsistent endpoint bindings.
- Active target tabs.
- Ambiguous identity or focus.

A live or unknown recorded or token-matched endpoint refuses duplicate launch.

### Startup cleanup of restored projections

Locked session start has one narrower cleanup for a restored projected child that is no longer current task state.
It runs only when the current home has at least one ordinary presentation journal, and it considers only that home.
A primary never recursively sweeps a secondmate home.

Discovery starts from the exact current `└ <concise-task> · p:<22-character-token>` grammar, but a title or token alone is never mutation authority.
A candidate must meet all of these conditions:

- The title must contain exactly one token occurrence across the named-session snapshot.
- The title must equal the title derived from exactly one valid presentation journal in this home's own `state/`.
- A version 2 journal additionally must bind this exact physical home, named session, workspace, tab, and pane.
- The task's ordinary metadata must be absent.
- The candidate must have exactly one tab and exactly one pane.

Firstmate then cleans up the candidate in this order:

1. Acquire the existing task-id spawn lock, and then the shared named-session presentation lock.
2. Inside both locks, take one exact snapshot.
3. Require one unambiguous non-target focus and the exact title, token, tab, and pane shape.
4. Positively confirm no registered agent.
5. Read Herdr's process information for the exact named-session pane and apply the process proof below.
6. Immediately revalidate the same journal, metadata absence, workspace title and token uniqueness, one-tab and one-pane topology, exact pane relationship, absent agent, process proof, and non-target focus.
7. Call the existing exact-pane focus-preserving close helper.
   It closes only that pane, never a workspace.
8. Retire the matching journal only after the exact pane is positively confirmed gone.

The process proof requires all of these:

- One recognized idle shell as both the shell process and the sole foreground process-group member.
- An operating-system process-table row for that shell.
- No child process.
- A sleeping or idle shell state.

The proof retries strict single samples for a bounded settle window, because an idle interactive shell transiently hosts short-lived prompt helpers.
A genuinely busy pane fails every sample.
Any foreground command, child process, active shell job, unknown shell, unreadable process table, missing field, or API error preserves the pane.

An unconfirmed close retains the journal.
A confirmed close may retire it even when focus restoration reported an error after the close.
A second run finds no matching title or journal and is a no-op.

Any of these preserves the candidate and lets session startup continue with at most a concise warning:

- A malformed or missing title or token.
- A duplicate token.
- Zero or multiple journal matches.
- A cross-home version 2 binding.
- Current metadata.
- A registered or unknown agent.
- An extra tab or pane.
- An active target.
- A busy lock.
- A changed revalidation.
- An unreadable check.
- Any error.

### Operational compromises

- Grouping is best-effort; only an exact same-identity version 2 binding survives a Herdr restart in place.
- A failed journal publication or projected workspace create stops that spawn instead of falling back flat.
  So a Herdr create failure surfaces as a spawn failure in every Herdr home, rather than only in homes that opted in.
  Every earlier degradation on the fresh projected-create path (no session server, contended presentation lock, absent or ambiguous parent) still warns and continues flat.
- Recovery of an existing presentation journal deliberately refuses the spawn when the shared presentation lock is contended, rather than falling back flat.
  Default-on makes that refusal reachable in any Herdr home.
- Existing layouts are not force-renamed or rearranged.
- Missing or ambiguous restart bindings fall back to the ordinary home workspace while the old projection remains untouched.
- Crashes, lost responses, failed exact-pane cleanup, or human renames can leave quarantined spaces.
  Session start removes only the exact home-local, uniquely journal-correlated, childless idle-shell shape above.
- Spaces have no cross-home cleanup path, and a secondmate child can clean up only from its exact home.
- Every stale-looking space outside that narrow startup proof still requires manual cleanup in Herdr's UI after human inspection.
- Regaining a dedicated space after degradation requires stopping the flat task, manually checking the stale projection, and clearing its journal before a genuinely fresh launch.
- The visible token is only a restart-stable correlator and never substitutes for the exact binding.

### Presentation tests

| Test | What it covers |
| --- | --- |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | Multi-home ordering, concurrency, lock contention, legacy coexistence, focus preservation, exact same-identity restart replacement, ambiguous bindings and tokens, and exact-pane cleanup through the guarded lab path. |
| `tests/fm-herdr-session-cleanup.test.sh` | Every discovery, ownership, topology, process, locking, revalidation, focus, retirement, and continue-on-error boundary. |
| `tests/fm-herdr-session-cleanup-e2e.test.sh` | The restored-shell cleanup in a guarded non-default named lab. |
| `tests/fm-backend-herdr-focus-flash-e2e.test.sh` | Reproduces the raw explicit-close focus steal on the installed release, and proves the focus-safe emptying-close plan removes a doomed workspace with no wrong-focus interval. |
| `tests/fm-backend-herdr-stale-active-tab-e2e.test.sh` | Proves a persisted-focused tab still closes when no foreground client is attached. |
| `tests/fm-herdr-attached-viewer-live-e2e.test.sh` | Proves the other half against a real attached viewer, which `bin/fm-herdr-lab.sh viewer start` supplies over a pty sized before the fork. |

[`verification/runtime-backends.md`](verification/runtime-backends.md#workspace-removal-focus-safety) owns the active versioned evidence for the focus-flash test.
[`verification/runtime-backends.md`](verification/runtime-backends.md#attached-foreground-viewer) owns the active versioned evidence and the re-run trigger for the attached-viewer test.

## Default-tab prune safety

`herdr workspace create` seeds one default tab.
Firstmate prunes it only after a real task tab exists and only when the same create response supplied the seeded tab id.
An adopted workspace never supplies that id and can never enter the prune path, regardless of labels or tab count.
Immediately before close, Firstmate rechecks the exact tab, expected seed label, and native agent state.
A working seed pane is never closed.

This created-versus-adopted gate is a destructive safety boundary.
A prior label heuristic could adopt a captain-owned workspace named `firstmate` and close its live seed-shaped tab.
The current structural gate removes label inference from cleanup authority.
`tests/fm-backend-herdr-prune-safety-e2e.test.sh` reproduces the collision in an isolated named session and proves the adopted pane remains untouched.

## Endpoint metadata

```text
backend=herdr
window=<session>:<pane-id>
herdr_session=<session>
herdr_workspace_id=<workspace-id>
herdr_tab_id=<tab-id>
herdr_pane_id=<pane-id>
```

A Herdr pane id contains a colon, so the adapter splits `window=` on the first colon only.
The recorded pane is the operational fast path.
Workspace and tab ids support verification and cleanup but are not inferred from mutable labels during normal operation.

## Current transport behavior

### Named server and session routing

The adapter starts and polls a named server before workspace, tab, pane, or agent calls.
Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.

When the selected named server is not running, the adapter launches it without these inherited values:

- Firstmate home and directory overrides.
- Harness identity markers.
- The supervision-model override.

Herdr passes its server startup environment to every later pane, so retaining those values could misroute panes for another Firstmate home or harness.
An already-running server is reused without restart or environment changes.
Explicit named-session routing and unrelated launch environment remain intact.

### Sending text and keys

Literal text and Enter are separate operations on `fm-send.sh`'s typed plane.
Ordinary local text steers instead use the durable steering inbox and send only its best-effort constant doorbell through this adapter.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.

Typed-plane slash input, and dollar-prefixed skill input for Codex, uses the shared harness-aware settle before the first Enter, so a completion popup cannot consume it.
Typed-plane text is typed once; only Enter is retried.

### Claude composer proof

When native `agent get` identity is Claude, the adapter types only into an empty composer.
A Claude composer that already holds text, or cannot be read, before the send is refused with nothing typed.
Before that Enter, the adapter continues only when the selected composer shows the typed payload, or only Claude paste placeholders with no literal remainder.

That comparison ignores whitespace and U+2063, the invisible mark that starts operational inputs and ends the from-firstmate label.
It ignores U+2063 because Claude's Herdr read-back never shows it.

A composer that holds a shorter suffix, or a placeholder plus a literal remainder, does not receive Enter.
Instead:

1. The adapter presses Ctrl+U until the shared classifier reads the composer as empty.
2. It then reports `send-failed`, so a resend starts from a clean composer.

Ctrl+C is not used for this, because Claude documents it as interrupting a running operation.
If the composer cannot be verified empty again, the submit reports `unknown` instead, because text may still be in the composer.

Other harnesses, and panes with no native identity, skip this proof and keep the type-then-Enter path.
They skip it because their paste placeholders and composer shapes are not live-verified.

### Submit confirmation

On an idle or done native baseline, submit confirmation proceeds in this order:

1. Wait for `working` or `blocked` across a bounded polling window.
2. If native status stays idle, use the shared composer verdict as the next positive signal.
   A cleared composer is delivery, and proven pending text retries Enter.
3. After the retry budget, `fm_composer_queued_enter_verdict` treats proven pending text plus a generating busy signal as a queued delivered Enter.
   It keeps an idle pending composer as a genuine swallow.

On an already active or unreadable baseline, the adapter falls back to conservative composer clearance.
That fallback adds a pre-Enter rendered-footer transition when the baseline is unavailable.
A fully unreadable target stops retrying and reports unknown.

`blocked` is not treated as a queued-Enter busy signal, so a Cursor pane that reports blocked in every state does not receive that conversion.

### Harnesses with no idle baseline

Some harnesses never present a legibly idle native baseline at all, so the composer fallback is their only path.

Cursor is one such harness:

- Herdr reports a Cursor pane `blocked` in every state.
- Cursor's mid-turn composer renders its placeholder beside a right-aligned busy token.
  That token is composer content, and therefore `pending` on a composer that holds no user text.

That fallback alone reported every delivered steer as unconfirmed.
So it is paired with a rendered-footer transition.
The pane's verified busy footer is read once before the first Enter, and an idle-to-busy transition across that Enter confirms the submit.
It is the same semantic signal the native path uses and the same one the tmux submit core reads.

A pane already mid-turn cannot borrow a rendered-footer transition as proof of this delivery.
After retries, only proven pending text plus native `working` can establish that its Enter was accepted and queued.

The composer verdict itself is deliberately unchanged.
A right-aligned status token on the composer row stays content for every other caller, including the away-mode pre-injection guard.

The poll density bounds the residual possibility of an extremely fast complete turn.
A missed native transition falls through to the composer verdict rather than reporting a false swallow.

### Capture size

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for small composer and peek reads.

### Native idle state

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore accepts a native `busy` as evidence of activity.
It never accepts a native `idle` as evidence that a worker has stopped; the task's own semantic busy state (`bin/fm-busy-lib.sh`) decides that.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter is a thin capture.
It hands a bounded ANSI tail plus Herdr's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape:

- Bordered boxes.
- Bare agent-glyph rows, including muse's `⟩`, which the adapter's retired local pattern silently omitted.
- opencode's left bar.
- The Pi separator region this adapter pioneered, admitted only when native `agent get` identity is exactly Pi and state is idle or done.

### Pi composer states

A blocked Pi is parked on an interactive prompt, so its blank composer region is a menu's and not a free composer's.
That state defers instead of proving emptiness.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains unknown or pending.
Identity stays a lazy second read, consulted only when a separator pair could change the verdict.

### Placeholder and ghost text

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.

If the ANSI capture ever fails, the plain fallback declares itself unstyled.
The classifier then degrades a glyph row carrying trailing text to `unknown` instead of misreading ghost suggestions as typed input.
That safely defers injection and eventually raises the wedge alarm.

### Away-mode injection

A bare shell prompt is never an empty agent composer.
Away-mode injection proceeds only on an affirmative `empty` result, never on unknown.
This prevents a dead agent pane from receiving and possibly executing an escalation as shell input.

### Operational input markers

The current operational envelope starts with U+2063 and `FIRSTMATE_OP: `.
The separate routed-request carrier uses `[fm-from-firstmate]` plus U+2063.
U+2063 survives Herdr terminal input as text, unlike the legacy ASCII control separator that could erase the visible routing label.
`bin/fm-operational-input.sh` owns current operational construction and parsing, and the AFK skill owns legacy away-input compatibility.
No Herdr-specific copy of that protocol exists.

## Restart and liveness behavior

### Husks after a server restart

Stopping and restarting a named Herdr server preserves workspace, tab, pane, and label ids.
The underlying harness processes and live agent registrations do not survive.
A restored same-labeled tab with a missing pane or no registered agent is a husk.

Create replaces only a confidently dead or no-agent husk, creates the replacement before closing the old tab, and refuses live or unknown states.
This prevents closing the workspace's last tab before a replacement exists.

### Stale agent registrations

A registration alone never proves an agent.
Herdr keeps a Pi registration after the Pi process has exited to a plain shell, whenever a nested interactive shell sits under the pane's top shell.
In that case `agent get` still reports `agent=pi` with its last status.
That nested shell is the crew shape `treehouse get` leaves behind (measured on Herdr 0.9.0 - [verification](verification/runtime-backends.md) "Stale agent registration"; upstream issue #4115).

So before a registered agent counts as live, the pane classifier reads `pane process-info` and the real process table.
It uses the shared harness-process classifier in `bin/fm-agent-process-lib.sh`, the same rule the tmux adapter proves liveness with:

| What the process view shows | Verdict |
| --- | --- |
| A harness in the foreground process group, or still a descendant of the pane shell | The registration stays live. |
| A foreground that is nothing but shells, with no harness descendant | A `stale-agent` pane: agent-free, with that explicit reason. |
| A foreground holding anything else | The registration stays live, but only after the same bounded settle window the idle-shell proof uses. |
| An unreadable process view | The pane is `unknown`, trusting neither the registration nor its absence. |

The settle window exists because an idle shell transiently hosts prompt helpers such as starship in its foreground group.
The first agent or shell sample in that window decides.

No registered status outranks the process view, because an agent killed mid-turn leaves `working` behind just as a quit one leaves `idle`.
The native busy verdict is verified the same way, so a shell-only pane never reads busy.

### Process-view version support

The `pane process-info` subcommand that this process-level proof depends on is present in every supported release client from the 0.7.1 floor upward (measured 2026-09-10 on the pinned 0.7.1, 0.7.3, 0.7.4, and 0.7.5 release clients - [verification](verification/runtime-backends.md) "Stale agent registration").
The response shape the adapter parses (`result.type` of `pane_process_info`, `process_info.shell_pid`, and `foreground_processes` entries carrying `name`, `argv0`, `argv`, and `cmdline`) is verified live only on Herdr 0.9.0.
The idle-shell proof's narrower parse was previously verified on 0.7.5.
A server response below 0.9.0 has not been measured for this parse.
An unreadable or unparseable process view reads `unknown`, which refuses lifecycle verbs and recovery rather than trusting the registration.

### Agent-liveness probe

The generic Herdr agent-liveness probe reuses that pane classifier, then applies one recovery-only exception.

| Pane read | Probe verdict |
| --- | --- |
| A structurally gone pane, or a pane read from a session positively reported as having no running server | `missing` |
| A restored agent-less shell, or a stale registration over a shell-only pane | `dead` |
| A registered agent with a live process | `alive` |
| Every other unexpected read | `unreadable` |

Neither the stopped-server exception nor the stale-registration verdict widens husk detection or any close authority.
Those paths still refuse an unreadable pane.
A `stale-agent` pane is reused by recovery, never closed as a husk, because the shell it holds may be a nested worktree shell.

Native registration still identifies Pi by name where tmux would see a generic interpreter.
The process-level proof only decides whether that registration is backed by a running process.
`tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh` pins the live-Pi versus leftover-shell distinction.
[`verification/runtime-backends.md`](verification/runtime-backends.md#agent-lifecycle-control) owns the versioned evidence.

The session-start sweep and the watcher's dedicated secondmate liveness tick use this probe.
Idle secondmates remain exempt from stale-pane escalation.
[Secondmate endpoint recovery](architecture.md) owns the shared supervision mechanism.

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.

The watcher maps the pane back to the task and skips these:

- Secondmate endpoints.
- Declared `paused:` waits, because a declared wait already names the human the fast escalation would report.
  It is left to the watcher's own bounded pause cadence.
- Verified `captain-held` transfers.
  A captain-held transfer remains silent without rechecks while the away-posture record exists.

### Polling fallback

The push path only shortens latency.
Polling runs every cycle and remains the permanent fallback when any of these is unavailable:

- Protocol 16.
- The event schema.
- Python.
- The connection.
- The subscription.
- Repeated reader execution.

There is still one watcher process; the event reader is a bounded child of that watcher.

`tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh` cover capability, subscribe-then-reconcile ordering, dedupe, exemptions, and polling fallback.

## Away-mode supervisor support

The away daemon supports tmux and Herdr supervisor panes only.
It refuses Zellij, Orca, and cmux as supervisor backends rather than applying the wrong transport.
For Herdr, target existence, native state, capture, composer state, and verified submit all route through the shared backend dispatcher and the explicit named-session CLI owner.
The pane-independent max-defer alert is configured in [`wedge-alarm.md`](wedge-alarm.md).

### Where the daemon runs

- Harnesses with native tracked background execution can run the daemon in their terminal.
- Pi and pi-signed no longer launch the away daemon; their ordinary supervision session continues under the posture record.
- An opted-in non-Pi home also skips the daemon for `/afk`; see [supervision-host.md](supervision-host.md).
- For another harness without native tracked background execution, `bin/fm-afk-launch.sh` runs the daemon in a Herdr workspace, as described next.

In that last case, `bin/fm-afk-launch.sh`:

1. Creates a dedicated unfocused Herdr workspace.
2. Runs the daemon there with an explicit supervisor target and backend.
3. Records the exact daemon pane.
4. Closes only that pane on stop.

It never splits the captain's active tab and never uses shell `&`.
Recovery reconciles only the recorded exact id.

### Stopping the daemon

On stop:

1. The daemon receives termination while `state/.afk` still exists, so its final flush can run.
2. The recorded terminal is closed.
3. The AFK flag is removed last.

A fresh entry clears stale transient escalation caches, while durable queue and task records remain authoritative.

## Destructive lab safety

Never use ambient `herdr server stop` for Firstmate verification.
An environment-only session selection can silently reach a different running server.
The ambient stop command has no explicit target.

`bin/fm-herdr-lab.sh` is the sole supported lifecycle helper for isolated verification.
The helper:

- Provisions only non-default names beginning with `fm-lab-`.
- Supplies an explicit `--session` Herdr option before any `--` delimiter in allowed task commands.
- Refuses caller-supplied session flags and server/session lifecycle subcommands.
- Performs destructive stop/delete only through its guarded lifecycle actions.

Immediately before every destructive call it re-queries the named session and refuses empty, missing, literal `default`, or `default:true` identities.
Its before/after tripwire requires the live default-session snapshot to remain byte-identical.

The helper's header and `--help` own exact commands.
Tests use thin compatibility wrappers in `tests/herdr-test-safety.sh` and never duplicate the destructive policy.

## Active limits

- Presentation ordering needs protocol 16 and Python and is best-effort only.
- Mutable labels can collide; they are never placement or destructive authority.
- A Firstmate outside Herdr cannot resolve a launcher workspace, so a colliding home label refuses new spawns until the collision is cleared.
- Ghost and placeholder recognition uses ANSI de-emphasis when available; an unstyled glyph row carrying trailing non-idle text fails safely to `unknown`.
- Only tmux and Herdr can host the away-mode supervisor terminal.

## Regression entry points

```sh
tests/fm-backend-herdr.test.sh
tests/fm-composer-lib.test.sh
tests/fm-herdr-submit-confirm-live-e2e.test.sh
tests/fm-backend-herdr-smoke.test.sh
tests/fm-backend-herdr-prune-safety-e2e.test.sh
tests/fm-backend-herdr-respawn-idem-e2e.test.sh
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
tests/fm-backend-herdr-presentation-e2e.test.sh
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh
tests/fm-backend-herdr-eventwait-smoke.test.sh
tests/fm-control-herdr-smoke.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
tests/fm-herdr-attached-viewer-live-e2e.test.sh
tests/fm-afk-inject-herdr-e2e.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Real Herdr tests use the named lab helper and default-session tripwire.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) records the active version, CLI, projection, event, and lifecycle evidence without task-specific chronology.
