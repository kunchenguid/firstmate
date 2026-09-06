# Herdr runtime backend

Herdr is an experimental agent-native terminal backend with native per-pane agent state and push events.
Firstmate requires Herdr protocol 14 or newer; broad backend verification covers versions 0.7.1, 0.7.3, 0.7.4, 0.7.5, and 0.8.0, while protocol-16 features remain gated by availability.
Default-on presentation spaces have a higher floor of Herdr 0.8.0 for the reason given under [Presentation spaces](#presentation-spaces).
Herdr provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Pick Herdr when you want native busy, idle, and blocked state and accept the experimental limits below.

Prerequisites:

- Herdr protocol 14 or newer, installed from [herdr.dev](https://herdr.dev).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).
- `python3` only for optional protocol-16 presentation-space ordering and native event subscription.

Herdr is dual-licensed AGPL-3.0-or-later or commercial.
Firstmate invokes its CLI as a separate process.

Select Herdr with local `config/backend` containing `herdr`, `FM_BACKEND=herdr` for one launch, or an explicit request to Firstmate.
A remote second-mate agent is the one case with no choice: it always runs on Herdr, and [`remote-secondmates.md`](remote-secondmates.md) owns that requirement and the readiness its host must meet.
It is also auto-detected when the primary runs natively under `HERDR_ENV=1` and is not inside tmux.
A tmux pane nested inside Herdr resolves to tmux because the innermost multiplexer wins.
An auto-detected Herdr spawn prints an opt-out notice.

Spawn stops before creating a Herdr container or acquiring a task worktree when `herdr`, `jq`, or the protocol floor is unavailable.
No separate first-run provisioning is required.

The required CI lane uses the pinned installers in `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`.
Those script headers own release assets, checksums, download bounds, and post-install gates.
Real harness credential tests remain opt-in rather than part of default CI.

## Watching and task containers

The ordinary topology puts one task tab per endpoint in the exact workspace of the Firstmate or secondmate that launches it.
A new worker's task tab keeps the historical `fm-<id>` label by default; a home that opts in through `config/herdr-task-titles` labels its new workers `<short title> (<id>)`, derived from the backlog row title or, without one, the task brief (a `--secondmate` spawn follows the secondmate home's own config, the same home-authority rule the presentation projection follows).
Historical `fm-<id>` task tabs remain valid and discoverable, and existing task operations never rename them.
When the launcher has no Herdr workspace to inherit, the adapter maintains one durable home-labeled workspace instead.
The primary home label is `firstmate`.
A secondmate home label is `2ndmate-<secondmate-id>`, derived from its validated `.fm-secondmate-home` marker.
A secondmate launched by the primary receives a narrowly scoped home override during container creation.

Attach to the selected named Herdr session and switch to the relevant home workspace to watch its task tabs.
Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without attaching.

Workspace and tab creation use `--no-focus`.
The first workspace in a completely empty Herdr session must become focused because no prior target exists, but later task creation does not intentionally steal focus.

Herdr does not enforce workspace or tab label uniqueness, so a label can never decide where a worker goes.
Herdr 0.7.5 exports `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID`, and `HERDR_WORKSPACE_ID` into every process it manages a pane for, and a Firstmate or secondmate agent's own commands inherit them.
Older injection shapes are unverified, so a claimed launcher pane without the injected socket identity cannot be trusted.
With presentation spaces disabled, a crewmate or scout is created in the exact workspace that identity currently resolves to, read live from Herdr rather than from the injected snapshot, so the worker always appears beside the agent that launched it.
Duplicate labels elsewhere in the session are irrelevant, and the globally focused workspace is never the target.
A `--secondmate` launch is the deliberate exception: it stands up that secondmate home's own workspace instead of joining the launcher's.

A claimed parent identity that cannot be resolved exactly stops the spawn before any worker endpoint exists, rather than falling back to a label search.
That covers a missing or unusable socket identity, a closed or unreadable launcher pane, a pane and tab that disagree about their workspace, a workspace missing from the session, and a pane belonging to another named session or Herdr server.

Firstmate running outside Herdr entirely has no launcher workspace to inherit, so its workers use this home's own labeled workspace, created on first use.
That path needs the home label to identify exactly one workspace: two workspaces sharing it are an unresolvable placement and refuse rather than adopting either.
Avoid naming a personal workspace `firstmate` or `2ndmate-<id>` for that reason, and because the adapter cannot distinguish that label collision from its own container.
An older secondmate workspace using `firstmate-<id>` is not migrated automatically; rename it manually before expecting new tasks or recovery to use it.
Recovery and list-live still scan the first workspace matching the home label, because they address panes they already recorded rather than choosing where new work goes.

Existing task operations use recorded endpoint ids and do not move a live task when labels change.
The per-home workspace is reused while it has task tabs.
Closing its last tab can remove the workspace, and the next spawn recreates it.

## Presentation spaces

Each new crewmate or scout is placed in a disposable one-task workspace by default, on Herdr 0.8.0 and newer.
A home opts out by writing `off` into local gitignored `config/herdr-presentation-spaces`, and forces the projection on by writing `on`.
An absent file leaves the choice to the version floor below, an empty file and the value `on` are both a deliberate opt-in, values are compared with whitespace stripped and case ignored, and an unrecognized value warns and follows the unconfigured default rather than failing a spawn over a purely visual setting.
The empty file is the historical presence-based opt-in form, so every home that had already enabled the projection stays enabled with no migration step, and no previously enabled home can be turned off by the default or by the floor.
A home that never created the file gains the projection at its next Herdr spawn on a supported release; that flip is deliberate, and it reaches only the Herdr backend because no other runtime backend has a projection path.

Projecting each task into its own workspace makes every task cleanup a workspace-emptying removal, which is the only removal shape Herdr's pre-0.8.0 focus defect touches, and the focus-safe removal plan below can only avoid it while the closing pane's shell can be proved lone, childless, and idle.
A persistent child of that shell - a `gitstatusd`, a `zsh-async` worker, or `direnv` - fails that proof permanently and forces the plain explicit close, which on those releases moves the active workspace for roughly a seventh of a second before the restore backstop pulls it back, once per task cleanup.
An unconfigured home is therefore projected only on a release at or above the 0.8.0 floor, where every workspace-removal primitive preserves focus and that proof stops being load-bearing.
Below the floor an unconfigured home uses the ordinary flat per-home layout instead and warns once per home per detected release, naming the running release and the upgrade that restores the projection.
That one-warning-per-release record is a `state/.herdr-presentation-floor-<release>` marker; deleting it only makes the same warning appear again, and an upgrade or downgrade re-announces itself because the release is part of the key.
The floor reads both the installed client's protocol and version and the selected named session's server signals while that server is running, requires both applicable releases to pass, and uses only the client when status positively reports no running server because that client will start it.
The unconfigured default is rechecked after the server is started or adopted and before any presentation journal or workspace is created, while an unreadable server state or release is treated as unsupported rather than guessed at.
An explicit `on` is honored below the floor, so a home that deliberately opted in is never silently downgraded; it accepts that documented focus move, and the exact prior-tab restore stays its backstop.
The floor has a single owner, the spawn-time gate, so cleanup for a projection that already exists always runs and never strands a workspace, whatever release the home is on now.
Upgrading Herdr to 0.8.0 or newer is the fix; writing `off` is the immediate mitigation for a home that cannot upgrade yet.
The setting is inherited into secondmate homes through the normal configuration-convergence owner, and the default needs no special convergence: the primary's absent file and the secondmate's absent file both mean the same unconfigured default, so leaving it converges a secondmate to that same default rather than turning it off, and only an explicit primary `off` propagates the opt-out.
A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An unconverged opt-out keeps the default projection in that home until convergence.

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token before asking Herdr to create anything.
After the new workspace converges to one exact task endpoint beneath one exact parent workspace id, the journal advances to a version 2 binding that records the physical home, named session, endpoint, parent, and immutable expected labels.
Another parent with the same presentation label does not prevent publication or participate in restart reclaim.
The token is visible in the workspace title because Herdr exposes no verified hidden persistent field, but neither token, title, nor journal authorizes send, capture, task ownership, Treehouse return, or general recovery.

The owning parent is the launcher's own exact workspace, resolved from the same identity the flat path uses, and falls back to a unique home-label lookup only for a Firstmate outside Herdr.
Projected children are never collapsed back into that parent; it is the placement and ordering reference the projection is bound under.
The normal task tab is created in the exact new workspace returned by Herdr.
Only the exact seeded default tab returned by the same workspace-create response can be pruned.
Before and after create, prune, order, abort cleanup, and normal cleanup, Firstmate verifies exact workspace, tab, pane, and active-focus ids.
An ambiguous response grants no mutation or cleanup authority.

Protocol 16 exposes `workspace.move` over the named session socket but no CLI subcommand.
`bin/backends/herdr-workspace-move.py` sends only that whitelisted method and verifies the complete returned workspace order.
Projected children are placed in one contiguous block immediately after their owning home when the session layout, protocol, socket, `python3`, and machine-private per-session lock are all verifiable.
Existing legacy child labels may extend an already adjacent block read-only but are never renamed or migrated.
A foreign, ambiguous, detached, or manually interleaved child makes ordering skip with a warning rather than rewriting the layout.

Ordering failure never fails the task spawn.
Firstmate does not retry, adopt, reuse, close, delete, or rename anything in response to an unavailable method, lock contention, ambiguous socket, lost response, failed move, or verification mismatch.
The worker remains on the ordinary flat or Herdr-current-order path.

Normal task metadata remains the sole endpoint authority after creation.
Cleanup closes only the exact recorded task pane and never calls `workspace close`.
Herdr 0.7.5's explicit close moves focus to a neighbor whenever it empties a non-focused workspace, while its pane-death removal preserves the focused workspace whenever the dying workspace sits behind it or the focused workspace is last; both behaviors are fixed in Herdr 0.8.0, and the exact rules live in the adapter header of `bin/backends/herdr.sh`.
Projected cleanup therefore runs under the same session lock, captures the exact active tab, refuses to delete the active tab, and treats a workspace-emptying close as a focus-safe removal: it verifies the close would empty the workspace, repositions the doomed workspace behind the focused one through the verified `workspace.move` transport when needed, proves the pane holds one lone idle shell, and ends that shell so Herdr removes the emptied workspace through its focus-preserving pane-death path.
The repositioning move-to-last preserves every surviving workspace's relative order, and removal is confirmed against the exact moved workspace rather than inferred from pane disappearance before an unconfirmed removal makes one verified attempt under the same session lock to roll the doomed workspace back to its exact original position.
If that rollback cannot restore the verified original order, cleanup warns loudly and leaves the retained records for inspection rather than retrying the shared-layout mutation.
The pane-death signals are pid-exact: the escalation re-reads the pane's process information and refuses unless the same shell pid still passes the strict bare-idle ownership proof, so an exited and reused pid is never signaled.
Any ambiguity, unsupported or failed move, or unproved shell falls back to the plain explicit close, and the exact prior-tab restore remains the backstop behind every close, so degraded behavior is never worse than the pre-mitigation sub-second restore.
Ordinary non-projected task removal serializes through the same session lock, applies the same focus-safe plan when its close would empty a non-focused workspace, keeps the legitimate plain close when the target is the active tab, and refuses an unlocked close if the lock cannot be acquired.
Task cleanup acquires that session lock before the task's isolated copy is returned, so a contended lock refuses up front while the copy, every durable record, and the endpoint are all intact for a plain rerun.
Forced secondmate cleanup recursively preflights every Herdr child endpoint and acquires every affected named-session lock before mutating any child, then retains each child's durable identity unless that exact pane returns structured not-found after its close.
Durable task records are erased only once the exact pane is confirmed gone through its structured presence: after every close path, only a structured not-found response counts as gone, while a present or unknown result retains every record with a visible, retryable error.
Missing or malformed endpoint identity and missing confirmation machinery are ambiguity, never proof of a gone pane, and refuse record removal the same way.
If lock, snapshot, pane identity, or restoration is ambiguous, cleanup warns and preserves the journal for manual inspection.

Recovery is deliberately conservative and presentation-only.
An existing journal suppresses another projected create.
Before any recovery mutation, Firstmate holds both the task spawn lock and the named-session presentation lock.
A same-identity version 2 binding may replace one exact agent-free restart husk in place only when the physical home, session, metadata endpoint, unique token match, workspace shape and labels, parent identity and placement, and non-target focus snapshot all agree.
The replacement tab and pane are created and verified before the old pane is rechecked and closed, then the journal advances atomically to the replacement endpoint before metadata publication.
The reclaim path never moves, closes, deletes, or renames a workspace and never touches a parent, sibling, captain, or foreign pane.
A failed replacement rolls back only the exact response-derived new pane when focus-safe verification permits it.
Version 1 journals, dead or missing panes, duplicate or absent tokens, renamed or detached spaces, cross-home mismatches, inconsistent endpoint bindings, active target tabs, and ambiguous identity or focus fall back flat without mutating the old projection when duplicate-agent risk is positively absent.
A live or unknown recorded or token-matched endpoint refuses duplicate launch.

Locked session start has one narrower cleanup for a restored projected child that is no longer current task state.
It runs only when the current home has at least one ordinary presentation journal and considers only that home; a primary never recursively sweeps a secondmate home.
Discovery starts from the exact current `└ <concise-task> · p:<22-character-token>` grammar, but a title or token alone is never mutation authority.
The title must contain exactly one token occurrence across the named-session snapshot and must equal the title derived from exactly one valid presentation journal in this home's own `state/`; a version 2 journal additionally must bind this exact physical home, named session, workspace, tab, and pane.
The task's ordinary metadata must be absent, and the candidate must have exactly one tab and exactly one pane.
Before cleanup, Firstmate acquires the existing task-id spawn lock and then the shared named-session presentation lock.
Inside both locks it takes one exact snapshot, requires one unambiguous non-target focus and the exact title, token, tab, and pane shape, positively confirms no registered agent, and reads Herdr's process information for the exact named-session pane.
The process proof requires one recognized idle shell as both the shell process and the sole foreground process-group member, an operating-system process-table row for that shell, no child process, and a sleeping or idle shell state.
The proof retries strict single samples for a bounded settle window because an idle interactive shell transiently hosts short-lived prompt helpers; a genuinely busy pane fails every sample.
Any foreground command, child process, active shell job, unknown shell, unreadable process table, missing field, or API error preserves the pane.
Firstmate immediately revalidates the same journal, metadata absence, workspace title and token uniqueness, one-tab and one-pane topology, exact pane relationship, absent agent, process proof, and non-target focus before calling the existing exact-pane focus-preserving close helper.
It closes only that pane, never a workspace.
The matching journal is retired only after the exact pane is positively confirmed gone; an unconfirmed close retains the journal, while a confirmed close may retire it even when focus restoration reported an error after the close.
A second run finds no matching title or journal and is a no-op.
A malformed or missing title or token, duplicate token, zero or multiple journal matches, cross-home version 2 binding, current metadata, registered or unknown agent, extra tab or pane, active target, busy lock, changed revalidation, unreadable check, or any error preserves the candidate and lets session startup continue with at most a concise warning.

Operational compromises:

- Grouping is best-effort; only an exact same-identity version 2 binding survives a Herdr restart in place.
- A failed journal publication or projected workspace create stops that spawn instead of falling back flat, so a Herdr create failure surfaces as a spawn failure in every Herdr home rather than only in homes that opted in; every earlier degradation on the fresh projected-create path (no session server, contended presentation lock, absent or ambiguous parent) still warns and continues flat.
- Recovery of an existing presentation journal deliberately refuses the spawn when the shared presentation lock is contended rather than falling back flat, and default-on makes that refusal reachable in any Herdr home.
- Existing layouts are not force-renamed or rearranged.
- Missing or ambiguous restart bindings fall back to the ordinary home workspace while the old projection remains untouched.
- Crashes, lost responses, failed exact-pane cleanup, or human renames can leave quarantined spaces; session start removes only the exact home-local, uniquely journal-correlated, childless idle-shell shape above.
- Spaces have no cross-home cleanup path, and a secondmate child can clean up only from its exact home.
- Every stale-looking space outside that narrow startup proof still requires manual cleanup in Herdr's UI after human inspection.
- Regaining a dedicated space after degradation requires stopping the flat task, manually checking the stale projection, and clearing its journal before a genuinely fresh launch.
- The visible token is only a restart-stable correlator and never substitutes for the exact binding.

`tests/fm-backend-herdr-presentation-e2e.test.sh` covers multi-home ordering, concurrency, lock contention, legacy coexistence, focus preservation, exact same-identity restart replacement, ambiguous bindings and tokens, and exact-pane cleanup through the guarded lab path.
`tests/fm-herdr-session-cleanup.test.sh` covers every discovery, ownership, topology, process, locking, revalidation, focus, retirement, and continue-on-error boundary.
`tests/fm-herdr-session-cleanup-e2e.test.sh` covers the restored-shell cleanup in a guarded non-default named lab.
`tests/fm-backend-herdr-focus-flash-e2e.test.sh` reproduces the raw explicit-close focus steal on the installed release and proves the focus-safe emptying-close plan removes a doomed workspace with no wrong-focus interval; [`verification/runtime-backends.md`](verification/runtime-backends.md#workspace-removal-focus-safety) owns the active versioned evidence.

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
herdr_task_label=<task-tab label>
```

A Herdr pane id contains a colon, so the adapter splits `window=` on the first colon only.
The recorded pane is the operational fast path.
Workspace and tab ids support verification and cleanup but are not inferred from mutable labels during normal operation.
The recorded `herdr_task_label` is the exact task-tab label, `fm-<id>` by default or `<short title> (<id>)` on an opted-in home, and it survives a relaunch unchanged, because a relaunch adopts the recorded tab without renaming it.

## Current transport behavior

The adapter starts and polls a named server before workspace, tab, pane, or agent calls.
Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.
When the selected named server is not running, the adapter launches it without inherited Firstmate home and directory overrides, harness identity markers, or the supervision-model override.
Herdr passes its server startup environment to every later pane, so retaining those values could misroute panes for another Firstmate home or harness.
An already-running server is reused without restart or environment changes.
Explicit named-session routing and unrelated launch environment remain intact.

Literal text and Enter are separate operations on `fm-send.sh`'s typed plane; ordinary local text steers instead use the durable steering inbox and send only its best-effort constant doorbell through this adapter.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.
Typed-plane slash input, and dollar-prefixed skill input for Codex, uses the shared harness-aware settle before the first Enter so a completion popup cannot consume it.
Typed-plane text is typed once; only Enter is retried.

On an idle or done native baseline, submit confirmation first waits for `working` or `blocked` across a bounded polling window.
If native status stays idle, the shared composer verdict is the next positive signal: a cleared composer is delivery, and proven pending text retries Enter.
After the retry budget, `fm_composer_queued_enter_verdict` treats proven pending text plus a generating busy signal as a queued delivered Enter, and keeps an idle pending composer as a genuine swallow.
On an already active or unreadable baseline, the adapter falls back to conservative composer clearance, with a pre-Enter rendered-footer transition when that baseline is unavailable.
A fully unreadable target stops retrying and reports unknown.
blocked is not treated as a queued-Enter busy signal, so a Cursor pane that reports blocked in every state does not receive that conversion.

Some harnesses never present a legibly idle native baseline at all, so the composer fallback is their only path.
Herdr reports a Cursor pane `blocked` in every state, and Cursor's mid-turn composer renders its placeholder beside a right-aligned busy token, which is composer content and therefore `pending` on a composer that holds no user text.
That fallback alone reported every delivered steer as unconfirmed, so it is paired with a rendered-footer transition: the pane's verified busy footer is read once before the first Enter, and an idle-to-busy transition across that Enter confirms the submit.
It is the same semantic signal the native path uses and the same one the tmux submit core reads.
A pane already mid-turn cannot borrow a rendered-footer transition as proof of this delivery; after retries, only proven pending text plus native `working` can establish that its Enter was accepted and queued.
The composer verdict itself is deliberately unchanged: a right-aligned status token on the composer row stays content for every other caller, including the away-mode pre-injection guard.
The poll density bounds the residual possibility of an extremely fast complete turn; a missed native transition falls through to the composer verdict rather than reporting a false swallow.

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for small composer and peek reads.

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore accepts a native `busy` as evidence of activity but never a native `idle` as evidence that a worker has stopped; the task's own semantic busy state (`bin/fm-busy-lib.sh`) decides that.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter is a thin capture: it hands a bounded ANSI tail plus Herdr's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape - bordered boxes, bare agent-glyph rows (including muse's `⟩`, which the adapter's retired local pattern silently omitted), opencode's left bar, and the Pi separator region this adapter pioneered, admitted only when native `agent get` identity is exactly Pi and state is idle or done.
A blocked Pi is parked on an interactive prompt, so its blank composer region is a menu's and not a free composer's; that state defers instead of proving emptiness.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains unknown or pending.
Identity stays a lazy second read, consulted only when a separator pair could change the verdict.

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.
If the ANSI capture ever fails, the plain fallback declares itself unstyled and the classifier degrades a glyph row carrying trailing text to `unknown` instead of misreading ghost suggestions as typed input, which safely defers injection and eventually raises the wedge alarm.

A bare shell prompt is never an empty agent composer.
Away-mode injection proceeds only on an affirmative `empty` result, never on unknown.
This prevents a dead agent pane from receiving and possibly executing an escalation as shell input.

The current operational envelope starts with U+2063 and `FIRSTMATE_OP: `.
The separate routed-request carrier uses `[fm-from-firstmate]` plus U+2063.
U+2063 survives Herdr terminal input as text, unlike the legacy ASCII control separator that could erase the visible routing label.
`bin/fm-operational-input.sh` owns current operational construction and parsing, and the AFK skill owns legacy away-input compatibility.
No Herdr-specific copy of that protocol exists.

## Restart and liveness behavior

Stopping and restarting a named Herdr server preserves workspace, tab, pane, and label ids, but the underlying harness processes and live agent registrations do not survive.
A restored same-labeled tab with a missing pane or no registered agent is a husk.
Create replaces only a confidently dead or no-agent husk, creates the replacement before closing the old tab, and refuses live or unknown states.
This prevents closing the workspace's last tab before a replacement exists.

The generic Herdr agent-liveness probe reuses the same classifier.
A structurally gone pane becomes `missing`, a restored agent-less shell becomes `dead`, a registered agent becomes `alive`, and an unexpected read becomes `unreadable`.
Unlike tmux process-name inspection, native registration can classify Pi without guessing from a generic interpreter name.

The session-start sweep uses this probe.
Mid-session secondmate agent-process liveness is not implemented because idle secondmates are deliberately exempt from stale-pane escalation and need a separate periodic identity signal.

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.
The watcher maps the pane back to the task and skips secondmate endpoints, declared `paused:` waits, and verified `captain-held` transfers, because a declared wait already names the human the fast escalation would report and is left to the watcher's own bounded pause cadence.

The push path only shortens latency.
Polling runs every cycle and remains the permanent fallback when protocol 16, the event schema, Python, connection, subscription, or repeated reader execution is unavailable.
There is still one watcher process; the event reader is a bounded child of that watcher.

`tests/fm-backend-herdr-eventwait-smoke.test.sh`, `tests/fm-transition-lib.test.sh`, and `tests/fm-supervision-events.test.sh` cover capability, subscribe-then-reconcile ordering, dedupe, exemptions, and polling fallback.

## Away-mode supervisor support

The away daemon supports tmux and Herdr supervisor panes only.
It refuses Zellij, Orca, and cmux as supervisor backends rather than applying the wrong transport.
For Herdr, target existence, native state, capture, composer state, and verified submit all route through the shared backend dispatcher and the explicit named-session CLI owner.
The pane-independent max-defer alert is configured in [`wedge-alarm.md`](wedge-alarm.md).

Harnesses with native tracked background execution can run the daemon in their terminal.
Pi has no such mechanism.
`bin/fm-afk-launch.sh` therefore creates a dedicated unfocused Herdr workspace, runs the daemon there with an explicit supervisor target and backend, records the exact daemon pane, and closes only that pane on stop.
It never splits the captain's active tab and never uses shell `&`.
Recovery reconciles only the recorded exact id.

On stop, the daemon receives termination while `state/.afk` still exists so its final flush can run, the recorded terminal is closed, and the AFK flag is removed last.
A fresh entry clears stale transient escalation caches, while durable queue and task records remain authoritative.

## Destructive lab safety

Never use ambient `herdr server stop` for Firstmate verification.
An environment-only session selection can silently reach a different running server, and the ambient stop command has no explicit target.

`bin/fm-herdr-lab.sh` is the sole supported lifecycle helper for isolated verification.
It provisions only non-default names beginning with `fm-lab-`, appends an explicit `--session` to allowed task commands, refuses caller-supplied session flags and server/session lifecycle subcommands, and performs destructive stop/delete only through its guarded lifecycle actions.
Immediately before every destructive call it re-queries the named session and refuses empty, missing, literal `default`, or `default:true` identities.
Its before/after tripwire requires the live default-session snapshot to remain byte-identical.

The helper's header and `--help` own exact commands.
Tests use thin compatibility wrappers in `tests/herdr-test-safety.sh` and never duplicate the destructive policy.

## Active limits

- Herdr remains experimental.
- Presentation ordering needs protocol 16 and Python and is best-effort only.
- Mutable labels can collide; they are never placement or destructive authority.
- A Firstmate outside Herdr cannot resolve a launcher workspace, so a colliding home label refuses new spawns until the collision is cleared.
- Ghost and placeholder recognition uses ANSI de-emphasis when available; an unstyled glyph row carrying trailing non-idle text fails safely to `unknown`.
- Mid-session secondmate agent-process liveness is not implemented.
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
tests/fm-backend-herdr-eventwait-smoke.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-herdr-session-cleanup-e2e.test.sh
tests/fm-afk-inject-herdr-e2e.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Real Herdr tests use the named lab helper and default-session tripwire.
[`verification/runtime-backends.md`](verification/runtime-backends.md#herdr) records the active version, CLI, projection, event, and lifecycle evidence without task-specific chronology.
