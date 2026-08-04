# Herdr runtime backend

Herdr is an experimental agent-native terminal backend with native per-pane agent state and push events.
Firstmate requires Herdr protocol 14 or newer; versions 0.7.1, 0.7.3, 0.7.4, and 0.7.5 are verified, with protocol-16 features enabled only when available.
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

## Optional presentation spaces

Create local gitignored `config/herdr-presentation-spaces` to request a disposable one-task workspace for each new crewmate or scout.
The setting is inherited into secondmate homes through the normal configuration-convergence owner.
A secondmate agent itself always stays in its ordinary parent workspace; only children launched by that home are eligible.
An absent or unconverged setting keeps the flat default.

Presentation is a best-effort visual projection, never task ownership or lifecycle authority.
Only a fresh task with neither metadata nor an existing presentation journal is eligible for projected creation.
Firstmate atomically publishes a three-field version 1 journal containing a random 128-bit base64url token before asking Herdr to create anything.
After the new workspace converges to one exact task endpoint beneath one exact parent workspace id, the journal advances to a version 2 binding that records the physical home, named session, endpoint, parent, and immutable expected labels.
Another parent with the same presentation label does not prevent publication or participate in restart reclaim.
The token is visible in the workspace title because Herdr exposes no verified hidden persistent field, but neither token, title, nor journal authorizes send, capture, task ownership, Treehouse return, or general recovery.

The owning parent is the launcher's own exact workspace, resolved from the same identity the flat path uses, and falls back to a unique home-label lookup only for a Firstmate outside Herdr.
Projected children are never collapsed back into that parent; it is the placement and ordering reference the projection is bound under.
The normal `fm-<id>` task tab is created in the exact new workspace returned by Herdr.
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
Herdr 0.7.5's explicit close moves focus to a neighbor whenever it empties a non-focused workspace, while its pane-death removal preserves the focused workspace whenever the dying workspace sits behind it or the focused workspace is last; both behaviors are fixed on the upstream default branch but in no release, and the exact rules live in the adapter header of `bin/backends/herdr.sh`.
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
```

A Herdr pane id contains a colon, so the adapter splits `window=` on the first colon only.
The recorded pane is the operational fast path.
Workspace and tab ids support verification and cleanup but are not inferred from mutable labels during normal operation.

## Current transport behavior

The adapter starts and polls a named server before workspace, tab, pane, or agent calls.
Every Herdr invocation goes through `fm_backend_herdr_cli`, which sets the environment and passes an explicit trailing `--session <name>`.
An environment variable alone is not reliable when another Herdr server is running.

Literal text and Enter are separate operations for ordinary steers.
Spawn-time fixed commands may use Herdr's atomic run primitive.
Enter, Escape, and Ctrl-C are supported.
Slash and dollar-prefixed input uses the shared harness-aware settle before the first Enter so a completion popup cannot consume it.
Text is typed once; only Enter is retried.

On an idle or done native baseline, submit confirmation waits for `working` or `blocked` across a bounded polling window.
On an already active or unreadable baseline, it falls back to conservative composer clearance.
A fully unreadable target stops retrying and reports unknown.
The poll density bounds the residual possibility of an extremely fast complete turn; a missed transition can cause only a redundant Enter on an empty composer, never duplicate message text.

`pane read --lines N` can return empty output when N is below the viewport height.
The capture owner requests at least 200 lines from Herdr and trims locally to the caller's bound.
This generous floor is required for small composer and peek reads.

Herdr's native agent state can read idle while a harness waits on its own long foreground tool.
The shared crew-state path therefore accepts a native `busy` as evidence of activity but never a native `idle` as evidence that a worker has stopped; the task's own semantic busy state (`bin/fm-busy-lib.sh`) decides that.
A human-blocked permission dialog has no busy banner and still surfaces.

## Composer and injection safety

Herdr has no direct cursor-row primitive.
The adapter locates the bottom-most recognized bordered row, Claude `❯` row, Codex `›` row, or a Pi separator region admitted only when native identity is exactly Pi and state is idle, done, or blocked.
A working Pi, pending middle row, missing identity, incomplete separator pair, or over-tall candidate remains pending or unknown.

ANSI capture preserves de-emphasized placeholder style.
`bin/fm-composer-lib.sh` is the fleet-wide owner that strips dim or faint runs and dark truecolor placeholders while retaining bright typed input.
If a future Herdr version strips ANSI style, ghost suggestions become pending rather than empty, which safely defers injection and eventually raises the wedge alarm.
Unicode blanks are trimmed by the same owner so an idle claude composer is not misread as typed input, and that trim widens no verdict it did not already own - only an unbordered row emptied purely by Unicode-blank trimming defers as `unknown`; see the 2026-07-26 incident below.

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
Mid-session secondmate liveness is not implemented because idle secondmates are deliberately exempt from stale-pane escalation and need a separate periodic identity signal.

## Push events and polling fallback

Protocol 16 can subscribe to `pane.agent_status_changed` over one bounded Unix-socket reader.
`bin/fm-transition-lib.sh` owns the backend-neutral transition vocabulary and policy.
The Herdr adapter subscribes before reconciling current levels, buffers edges during reconciliation, and returns fresh blocked transitions for this home's panes.
The watcher maps the pane back to the task and skips secondmate endpoints and declared `paused:` waits.

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
- Ghost and placeholder recognition depends on ANSI de-emphasis and fails safely to pending when unavailable.
- Mid-session secondmate liveness is not implemented.
- OpenCode 1.18.4 can accept Enter while busy without clearing the composer.
  The tmux backend has a busy-queue fallback, but Herdr still reports this case as submit pending and needs a separate adapter fix.
- Only tmux and Herdr can host the away-mode supervisor terminal.

## Regression entry points

```sh
tests/fm-backend-herdr.test.sh
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

## Incident (2026-07-26): away-mode never delivered because claude's idle composer ends in a no-break space

Away mode buffered every escalation instead of delivering it: one supervisor window logged 2113 deferrals across 42062 seconds with zero live deliveries.
Nothing was lost (the buffer flushed on the captain's return), but the captain got no live updates for roughly twelve hours, which is the entire point of away mode.

**Root cause.** Claude's current CLI draws its idle input box as an UNBORDERED `❯` followed by U+00A0 (no-break space), not the older bordered `│ ❯ │` shape.
The shared classifier trimmed ASCII whitespace only, and U+00A0 is not ASCII whitespace - glibc does not classify it as `[[:space:]]` either - so the residual no-break space survived the trim and read as genuine typed text.
`fm_composer_classify_content` therefore returned `pending` for a completely idle pane, and the away-mode injector, which proceeds only on an affirmative `empty`, deferred forever.
Captured read-only from a live pane on 2026-07-26 against Claude Code 2.1.220:

```
$ claude --version
2.1.220 (Claude Code)
$ tmux capture-pane -p -e -t "$pane" | grep -a "$(printf '%b' '\xe2\x9d\xaf')" | tail -1 | od -c | head -2
0000000 033   [   3   9   m 342 235 257 302 240  \n
```

The row's entire content is `❯` (U+276F, `342 235 257`) followed by U+00A0 (`302 240`).
An `FM_COMPOSER_IDLE_RE` override matching that shape was verified to flip the pane from `pending` to `empty`, which confirmed the diagnosis before the permanent fix.

**Fix (task fm-afk-wedge-bgjob-pane): trim Unicode blanks in the one shared owner.**
`bin/fm-composer-lib.sh` gains `fm_composer_trim`, the single fleet-wide blank trim, applied inside `fm_composer_classify_content`.
It strips leading and trailing ASCII whitespace plus every Unicode space separator and the two zero-width characters (U+200B, U+FEFF), so a row carrying only a known agent prompt glyph and any combination of blanks reads `empty`.
Because the fix lives in the shared owner, every delegating adapter is corrected at once rather than per harness, for each row its own structural detection actually hands to that classifier.
Interior blanks are untouched, so real typed text is never rewritten.
The blanks are matched as literal UTF-8 byte strings rather than a byte class, because U+202F (`E2 80 AF`) shares its lead byte with `❯` (`E2 9D AF`); a byte class would eat the glyph under `LC_ALL=C`.
`FM_COMPOSER_IDLE_RE` is unchanged and remains available as a per-harness idle-placeholder override for future harnesses.

The safety direction is unchanged: real unsubmitted text still reads `pending`, so the daemon never merges its digest into a half-typed line, and a bare shell prompt still reads `unknown`, so an escalation is never typed into a dead shell.
The same idle capture now classifies `empty` with no override set:

```
$ . bin/fm-tmux-lib.sh
$ fm_tmux_composer_state "$pane"
empty
```

**What the fix covers, and what it does not.** Covered is composer CONTENT, on every backend whose structural row detection reaches the shared classifier, because the trim lives in that one shared classifier.
The measured exception is orca and cmux, which discard an unbordered row before the classifier is reached, so claude's real idle row measures `unknown` on both - detailed below.
`fm_composer_trim` removes blanks from the LEADING and TRAILING positions only, so a row holding just a known agent prompt glyph plus any combination of blanks classifies `empty` whenever the adapter hands that row to the classifier at all.
Blanks INTERIOR to real text are never removed, so such a row stays `pending` - measured, `classify 0 "❯<U+00A0>fix findings"` = `pending` and `classify 0 "❯ a<U+00A0>b"` = `pending`, both pinned in `tests/fm-composer-lib.test.sh`.
A no-break space inside a half-typed human line therefore does NOT make the pane a safe injection target.
Not covered is a Unicode blank in the STRUCTURAL border position, which each adapter still detects after an ASCII-only trim of its own.
A harness rendering `│ > │` followed by U+00A0 reads `pending` on the tmux path, because `bin/fm-tmux-lib.sh` fails its bordered-shape match, leaves `bordered=0`, and keeps the border glyphs in the content.
The same row reads `unknown` on the other three: `bin/backends/herdr.sh` matches neither the bordered shape nor its bare-prompt regex, and `bin/backends/orca.sh` and `bin/backends/cmux.sh` discard any row that does not end in a border glyph.
Those four verdicts were verified empirically, each through its real `composer_state` function with a real U+00A0 byte and a passing control row in the same run.
Both `pending` and `unknown` are non-`empty`, so away-mode injection is refused in every case and nothing is ever typed into a dead shell - the gap costs delivery, never safety.
It would still reproduce a never-delivers wedge.
Only claude was measured here, and its U+00A0 sits inside the composer content, which this trim covers.
The other verified harnesses were never captured or measured for a blank in the structural border position, so that shape is unobserved rather than proven absent.
Hoisting the trim into the adapters' structural row detection was deliberately declined here, per captain ruling, because it widens the blast radius on the exact code that distinguishes a real composer from a dead shell; it is filed as separate scoped work.

**A separate structural gap on orca and cmux, independent of blank trimming.** Claude renders its idle composer UNBORDERED - a bare `❯` plus U+00A0, with no border glyphs on the row.
`bin/backends/orca.sh` and `bin/backends/cmux.sh` are deliberately border-row based: they keep only rows whose trimmed content both starts and ends with a border glyph, so claude's real idle row is discarded before the shared classifier is ever reached.
Measured through `fm_backend_orca_composer_state` and `fm_backend_cmux_composer_state` with a real U+00A0 byte, that row reads `unknown` on both, with or without the blank trim, and both verdicts are now pinned by `tests/fm-backend-orca.test.sh` and `tests/fm-backend-cmux.test.sh`.
`tmux` and `herdr` do read that same unbordered row as `empty`, so the gap is confined to the two experimental backends.
This is NOT a live injection hole today, and the bound is explicit rather than left to the reader: the away-mode daemon accepts only `tmux` and `herdr` as supervisor backends and refuses any other loudly at startup.
Measured, not inferred - `FM_SUPERVISOR_SUPPORTED_BACKENDS` is `tmux herdr` in `bin/fm-supervise-daemon.sh`, and running the daemon with `FM_SUPERVISOR_BACKEND=orca`, `=cmux`, and `=zellij` each exits with `error: away-mode daemon does not support supervisor backend ... (supported: tmux herdr)`.
`unknown` is non-`empty` in any case, so injection is refused rather than typed into a row the adapter could not classify.

The empirical basis for keeping the trim content-only: the fix was verified end to end with no `FM_COMPOSER_IDLE_RE` override against four live claude panes through `fm_tmux_composer_state`, each reading `pending` before the fix and `empty` after, and against the exact captured bytes through `fm_backend_herdr_composer_state`.
Content-only trimming is therefore sufficient for the shape claude actually renders.

**An empty row: the trim widens no verdict it did not already own.** Trimming Unicode blanks made one more row flip: an UNBORDERED, glyph-less row holding nothing but Unicode blanks trims to empty content, and the classifier's empty-content fallthrough answered `empty` - the injection-permitting direction, on a row carrying no evidence that it is an agent composer at all.
That flip is declined: `fm_composer_classify_content` records what an ASCII-ONLY trim would have left of `<content>`, captured before the Unicode-aware trim runs, and then answers an empty row three ways - `empty` when `<bordered>` is 1, `unknown` when that ASCII-only remainder was non-empty because only Unicode-blank trimming emptied the row, and `empty` otherwise.
`[plain_content]` is deliberately NOT trimmed, because the ghost-only branch above that decision asks whether the RAW row carried anything at all.
Trimming it was tried and reverted: it let a blanks-only plain row skip that branch and reach the empty-row decision as `empty`, which measured as an injection-permitting flip - `fm_composer_classify_content 0 '' '' sensitive '   '` reads `unknown` before this branch and read `empty` with the trim in place.
The ASCII class is spelled out as literal ASCII whitespace rather than `[[:space:]]`, because glibc widens `[[:space:]]` to U+2003, U+3000 and other Unicode spaces in a UTF-8 locale while `LC_ALL=C` does not, and a locale-dependent answer on the decision that gates injection is not acceptable.
That spelling scopes the ASCII-only remainder alone - `fm_composer_trim`'s own ASCII step still uses `[[:space:]]`, which leaves the pre-existing locale gap recorded below.

**Exactly which verdicts this branch changes.** Measured under `LC_ALL=C.UTF-8` against `fork/main`, through a harness that first asserts the known-good controls (agent glyph reads `empty`, bare shell prompt reads `unknown`, real text reads `pending`) on both libraries before any row is trusted:

- An unbordered row of an agent prompt glyph plus Unicode blanks goes `pending` to `empty` - the reported claude wedge, and the point of this branch.
- An unbordered row of only Unicode blanks goes `pending` to `unknown` - the one new permission, declined.
- An unbordered row of only a glibc-wide blank such as U+3000 or U+2003 goes `empty` to `unknown`, because the ASCII-only remainder is spelled with the literal class while `[[:space:]]` covered those characters before - a deliberate deferral in the safe direction, not an unchanged verdict.
- An unbordered row whose `<content>` and untrimmed `[plain_content]` are both only ASCII spaces goes `empty` to `unknown`, also deferring; no adapter produces it, because tmux, herdr, orca, and cmux each ASCII-trim their candidate row before calling this owner.

Every other verdict measured identical to `fork/main`, including a truly empty row, a ghost-stripped glyph plain row, a blanks-only plain row, a bare dead-shell prompt glyph, and real typed text.
A wider rule requiring `<bordered>=1` for EVERY empty row was tried first and reverted, because it took away away-mode delivery for a container-less composer on the tmux path - Pi's exact shape, since `bin/fm-tmux-lib.sh` recognises only `│…│`, `┃…┃`, and `|…|` as a container and has no equivalent of the separator-pair detection `bin/backends/herdr.sh` does for Pi.

Measured against a real tmux server on an isolated socket, each row rendered by a real pane and read through the real `fm_tmux_composer_state`, with a passing control in the same run:

```
row of only U+00A0 (302 240)                 -> unknown   (the new permission, declined)
Pi-shaped container-less blank composer      -> empty     (delivery preserved)
real dead shell, PS1 empty, blank row        -> empty     (pre-existing, see below)
ASCII-blank-only row                         -> empty     (pre-existing)
claude idle composer: 342 235 257 302 240    -> empty
real typed text after the glyph              -> pending
```

Directly through the shared classifier, a bordered blanks-only row stays `empty`, a bare codex `›` stays `empty`, and a bare dead-shell prompt glyph stays `unknown`.
Every one of the verdicts measured above is identical under `LC_ALL=C` and `LC_ALL=C.UTF-8`, which is what the blank set's literal byte-string matching buys; it is not a claim that the trim is locale-independent for every possible character, and the residual locale gap below records where it is not.
The standing rule this follows: on an injection-permitting path, uncertainty defers, because being wrong toward `empty` executes text in a dead shell while being wrong toward `unknown` only delays a message.

The post-Enter submit acknowledgement is unchanged by this branch, and that was confirmed rather than assumed.
A composer that clears to a blank, glyph-less row is a truly empty row, so it reads `empty` exactly as it did before, and `fm_tmux_submit_enter_core` plus `inject_msg` still take that as the positive confirmation that a digest landed.

**Not covered, and unchanged by this branch: a glyph-less blank cursor row on tmux still reads `empty`.**
That is measured to include a real dead shell with an empty prompt, which returned `empty` on a real tmux pane both before and after this branch.
It is pre-existing behaviour rather than something introduced here, and it is the same reading that keeps a container-less composer such as Pi deliverable on tmux.
The two shapes are indistinguishable on that path: the tmux reader takes the raw cursor row with no structural composer identification on the unbordered branch, so telling a dead shell apart from a border-less composer needs new structural detection.
That detection was deliberately NOT added here - it would change the exact code that distinguishes a real composer from a dead shell - and is filed as separate scoped work.
Herdr, orca, and cmux are not exposed to it: a blanks-only row matches neither herdr's bordered shape nor its bare-prompt regex, and orca and cmux discard any row not bounded by border glyphs, so all three answer `unknown` for that shape.
The same pre-existing gap covers a dead shell whose prompt character IS an agent glyph, such as Starship's default `❯` - measured, `fm_composer_classify_content 0 '❯'` reads `empty` on `fork/main` and on this branch alike, under both `LC_ALL=C` and `LC_ALL=C.UTF-8`, because the unconditional agent-glyph rule needs no container.

**Not covered, and unchanged by this branch: the trim's ASCII step is locale-dependent for U+2028 and U+2029.**
Only the blank set is matched locale-independently: `FM_COMPOSER_BLANKS` are whole literal UTF-8 byte strings, which is why U+202F (`E2 80 AF`) can never be confused with the lead byte of `❯` (`E2 9D AF`).
`fm_composer_trim`'s ASCII whitespace step still uses `[[:space:]]`, and glibc widens that class in a UTF-8 locale to include U+2028 and U+2029, neither of which is in `FM_COMPOSER_BLANKS`.
A row whose only trailing character is one of those two therefore classifies differently between the two locales - measured, `classify 0 "❯<U+2028>"` reads `empty` under `LC_ALL=C.UTF-8` and `pending` under `LC_ALL=C`.
That divergence is pre-existing rather than introduced or widened here, measured identically on `fork/main` and on this branch.
Both readings are non-`empty` for a row carrying no agent glyph, so no dead-shell injection follows from it, and closing it would change behaviour for those two characters in the fleet's own UTF-8 locale - deliberately out of scope here and filed as separate scoped work.
The end-to-end gate is locale-dependent for glibc-wide blanks for the same reason, even though the ASCII-only remainder inside the classifier is not: every adapter ASCII-trims its candidate row with `[[:space:]]` before calling this owner (`bin/fm-tmux-lib.sh`, `bin/backends/herdr.sh`), so a U+3000-only tmux row arrives already emptied under `LC_ALL=C.UTF-8` and reads `empty`, while under `LC_ALL=C` it arrives intact and reads `unknown`.

**Also not covered, and unchanged by this branch:** on the tmux path only, if a harness ever renders its prompt glyph ITSELF de-emphasised, the ghost-stripped content is empty while the untrimmed plain row is the glyph plus blanks, which does not equal the bare glyph and therefore reads `unknown` - deferring, never a false `empty` - measured identically on `fork/main` and on this branch (`classify 0 '' '' sensitive "❯<U+00A0>"` -> `unknown`), unreachable with claude 2.1.220 whose glyph survives ghost stripping intact, and filed as separate scoped work.

**Regression coverage (from the exact captured bytes).** `tests/fm-composer-lib.test.sh` pins the shared owner: an agent glyph plus any Unicode blank reads `empty`, the same blanks around or inside real text stay `pending`, a bare shell glyph padded with blanks stays `unknown`, and both the trim of the blank set and the leading multibyte agent-glyph strip give the same verdict under `LC_ALL=C` and `LC_ALL=C.UTF-8` and are `set -euo pipefail` safe.
`test_plain_content_path_is_not_blank_trimmed` pins the opposite for `[plain_content]`: it is deliberately left untrimmed, because the ghost-only branch that consumes it asks whether the RAW row carried anything at all, so a blanks-only plain row that skipped that branch would reach the empty-row decision as `empty`.
`tests/fm-composer-ghost.test.sh` drives the exact captured row through the real tmux reader, asserting the idle row's exact `fm_tmux_composer_state` verdict of `empty` and the typed-text row's `pending`.
The idle assertion is the verdict itself rather than `fm_pane_input_pending` being false, because that predicate is also false for `unknown` - the state in which away mode defers forever - so a regression back to the wedge would otherwise still pass; the ghost-only idle rows in that file assert `empty` for the same reason.
`tests/fm-backend-herdr.test.sh` pins claude's real idle row per backend, bare and bordered, verified to fail before the fix.
`tests/fm-backend-orca.test.sh` and `tests/fm-backend-cmux.test.sh` pin a blank inside a BORDERED composer's content, which is what proves the shared trim reaches those adapters; they do not pin claude's real idle composer, which those two backends never see, and each file additionally pins the measured `unknown` verdict for that unbordered row.
For the scoped empty-row rule, `tests/fm-composer-lib.test.sh` pins all three answers: a genuinely empty or ASCII-blank row reads `empty` bordered or not, a container-less blank composer row reads `empty` so Pi's tmux delivery cannot be taken away again, and an unbordered row of nothing but Unicode blanks reads `unknown` for every blank in the set, so the one new permission cannot silently reopen.
`tests/fm-composer-ghost.test.sh` pins the same two rows end to end through the real `fm_tmux_composer_state` rather than the classifier alone - a Pi-shaped container-less blank row -> `empty`, an unbordered U+00A0-only row -> `unknown` - and both were verified to fail against the wider bordered-only rule before it was scoped.
`tests/fm-daemon.test.sh`'s and `tests/fm-wake-daemon-lifecycle-e2e.test.sh`'s injectable-supervisor fixtures render claude's real unbordered `❯` plus U+00A0 rather than a blank capture, which is the shape a live claude supervisor pane actually presents; either shape passes under the scoped rule, and the realistic one is kept.
`bin/fm-lint.sh` passes clean.
