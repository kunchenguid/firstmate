# Architecture

How firstmate works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's full operating manual for the orchestrator agent itself is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals whose crew is not provably working, check-script output such as PR merge polling or an X-mode mention, stale panes whose crew is not provably working whether their status log looks terminal or non-terminal, provably-working stale panes that persist past `FM_STALE_ESCALATE_SECS`, and heartbeat backstop hits.
Repeated provably-working stale escalations on the same unchanged pane add an escalation count to the wake reason and, at `FM_WEDGE_DEMAND_INSPECT_COUNT`, a `demand-deep-inspection` marker.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed process exit can be recovered by draining the queue.
No-verb wakes, such as `working:` notes and bare turn-ended signals, are benign only when `bin/fm-crew-state.sh` reports positive evidence that the crew is still working: an actively running no-mistakes step for that crew's branch or a backend busy signature.
Fresh stale panes use the same current-state read before trusting the status log, so an active run or busy pane outranks an old captain-relevant status-log line left behind before validation.
No-change heartbeats are also benign.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
After each drain, `fm-wake-drain.sh` runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only drains and handles queued wakes.
Routine watcher polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent; an idle crew costs you nothing.
Crew status files are append-only wake-event logs, not current-state fields.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes the matching no-mistakes run, active or terminal, to the crew's own branch and keeps that run-step authoritative even if the pane has closed.
During no-mistakes' `ci` monitor phase, it also reads the ci step log tail because `axi status` reports both "still waiting on checks" and "checks green, waiting on merge" as `ci,running`.
The most recent recognized ci log marker wins, so checks-green monitoring reports done while a later re-arm, failed-check, or issue marker returns the crew to working.
Only when no matching run exists does it fall back to the pane busy-signature and then the status log; a dead pane without a run reports unknown instead of trusting a stale log.
For herdr, that pane fallback trusts a native `busy` verdict outright, but corroborates native `idle` or unknown verdicts against the rendered busy signature before deciding the crew is not working.
For whole-fleet read-only review, `bin/fm-fleet-snapshot.sh --json` emits schema `fm-fleet-snapshot.v1` from the backlog, task metadata, current crew state, endpoint probes, PR/report pointers, scout reports, and secondmate return-channel guidance.
`bin/fm-fleet-view.sh` renders that snapshot as Markdown for humans, so bearings and manual fleet reviews consume one structured contract instead of reparsing raw fleet files.
The script header owns the exact JSON schema.
Optional X mode rides the same check path: the locked session-start bootstrap step drops a local `state/x-watch.check.sh` shim only after the user opts in with `FMX_PAIRING_TOKEN`, and non-X homes keep the default watcher behavior.

At session start, `bin/fm-session-start.sh` emits exactly one primary-harness supervision block rendered by `bin/fm-supervision-instructions.sh` from `docs/supervision-protocols/`.
That block owns the live wait shape for the running primary harness: Claude and Grok use background-notify cycles, Codex uses bounded foreground checkpoints, Pi uses its two tracked primary extensions, and OpenCode uses its TUI plugin.
`bin/fm-watch-arm.sh` remains the verified arm wrapper for protocols that call it; it forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `attached` / restart-only `healthy` / `FAILED`, the last exiting non-zero).
On `attached` it stays live until that existing cycle ends so background-notify harnesses do not get an empty false wake from a healthy no-op exit.
Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if the primary checkout is tangled, or if tasks are in flight and that watcher stops running or queued wakes are waiting to be drained.
The drain script calls that guard after emptying the queue, which avoids repeating the queued-wakes warning for records it just consumed while still warning on stale watcher liveness.
It leads with prominent bordered banners for the tangle and no-watcher cases so they cannot be skimmed past.
On every verified primary harness, tracked hook integration gives the primary session a push-based backstop: when work is in flight and no identity-matched watcher lock with a fresh beacon is live, direct Stop hooks block and passive turn-end hooks force one bounded follow-up.
The guard is scoped out of secondmate homes and crewmate/scout worktrees, is loop-safe per harness, and is documented in [turnend-guard.md](turnend-guard.md).

A presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill starts it through the tracked foreground helper `bin/fm-afk-start.sh`, after which the watcher reverts to daemon-managed one-shot mode and the daemon self-handles routine wakes in bash.
The watcher and daemon share `bin/fm-classify-lib.sh` for captain-relevant status verbs and status-scan primitives.
The always-on watcher also uses that library's provably-working predicate on no-verb signals and first-sighting stale panes before status-log terminality is trusted, while the daemon keeps its away-mode stale recheck unchanged.
The daemon escalates only captain-relevant events as one batched, single-line digest (prefixed with an in-band sentinel marker so firstmate can tell daemon injections apart from real messages).
Its supervisor injection path supports tmux and herdr panes, with `FM_SUPERVISOR_BACKEND` and `FM_SUPERVISOR_TARGET` resolved independently from the task-spawn backend.
Pane existence, busy checks, composer checks, capture, and verified submit route through `bin/fm-backend.sh`: tmux keeps the same submit core used by the tmux send backend, while herdr uses native busy state, native agent-state submit confirmation on idle baselines, and its ANSI-aware structural composer classifier for pending-input guards and submit fallback.
Unsupported supervisor backends refuse at daemon startup.
Stalled escalation delivery raises `state/.subsuper-inject-wedged` after `FM_MAX_DEFER_SECS` instead of silently deferring forever.
`fm-send.sh` selects a pre-Enter popup-settle for slash commands and for codex `$...` skill invocations using metadata-routed target `harness=` values, then adds its own `FM_SEND_SETTLE` pause after successful text sends so immediate peeks catch the receiving turn starting; the sub-supervisor uses only the shared submit core and does not pay that post-submit pause.

## Runtime session backends

The runtime backend is the session-provider layer below firstmate's scripts.
It owns task endpoint creation, bounded capture, text/key sends, current-path reads for spawn-time worktree discovery when the backend does not create the worktree itself, live-window fallback lookup, agent-process liveness probes where verified, and endpoint teardown.
`bin/fm-backend.sh` centralizes backend selection, `state/<id>.meta` helpers, selector resolution, and operation dispatch; `bin/backends/tmux.sh` is the verified reference adapter ([`docs/tmux-backend.md`](tmux-backend.md)), and `bin/backends/herdr.sh` (P2), `bin/backends/zellij.sh` (P3), `bin/backends/orca.sh` (P4), and `bin/backends/cmux.sh` (P5) are experimental task-spawn adapters.
New spawns select a backend from `--backend`, then `FM_BACKEND`, then local `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
Runtime auto-detection is innermost-first: `$TMUX` wins over `HERDR_ENV=1`, which wins over cmux's primary `CMUX_WORKSPACE_ID` marker and documented fallback signals; auto-detected herdr or cmux prints a one-time opt-out notice, auto-detected tmux stays silent, and zellij and orca are never auto-detected (only explicit selection).
Unknown backend names fail loudly.
For compatibility, default tmux tasks do not write `backend=tmux`; every reader treats a missing `backend=` field as `tmux`.
`fm-watch.sh` polls each window's backend for a busy state: tmux, zellij, orca, and cmux have no native primitive and always report unknown, preserving the original pane-tail-regex detection unchanged; herdr's `agent.get` semantic state (working/idle/done/blocked) is consulted first for stale detection, with unknown native states falling back to the same regex.
That poll loop is the default event source for backends with no native push events, so this stays an extraction of the abstraction rather than a watcher rewrite.
The deeper session-start agent-process liveness probe is separate from that busy-state poll: tmux and herdr have verified classifiers for secondmate recovery, while zellij, Orca, and cmux currently report `unknown` rather than guess.
Herdr is experimental and can be selected explicitly or by runtime auto-detection: treehouse remains the worktree provider for it exactly as it is for tmux (herdr is a session provider only), and its full verification - the container shape decision, created-vs-adopted default-tab prune safety, restored-layout husk respawn idempotency, verified CLI facts, ANSI-preserved Codex ghost suggestions, a verified small-`--lines` capture bug and its workaround, and known gaps - is recorded in `docs/herdr-backend.md`.
Herdr's container shape is workspace-per-home plus tab-per-task: the primary home uses workspace label `firstmate`, secondmate homes use `2ndmate-<secondmate-id>`, and recovery/list-live scopes to the current `FM_HOME`'s workspace.
Zellij is experimental and selected only explicitly: treehouse remains its worktree provider too, and its full verification - the resolved "gaps to verify" list from the original design report, the unconditional-exit-0 CLI quirk and its mitigation, the focus-steal-on-new-tab finding, the home-scoped tab-title collision fix, and known gaps - is recorded in `docs/zellij-backend.md`.
Zellij's container shape is simpler than herdr's: one shared `firstmate` session, one tab per task, with no per-home workspace split; visible tab titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path while task selectors can use exact ids or stable `fm-<id>` labels.
Orca is experimental and selected only explicitly: Orca owns both worktree and terminal lifecycle, records `orca_worktree_id=` and `terminal=`, and removes worktrees through `orca worktree rm` only after the usual firstmate teardown checks pass. Its current behavior and limitations are recorded in `docs/orca-backend.md`.
cmux is experimental, GUI-first, macOS-only, and can be selected explicitly or by runtime auto-detection from its primary `CMUX_WORKSPACE_ID` marker plus documented fallback signals: treehouse remains its worktree provider (cmux is a session provider only, like herdr/zellij), and its full verification - the socket access setup requirement with Automation mode recommended, the read-screen-fails-on-a-fresh-surface finding, the close-surface-refuses-on-the-last-surface finding, the source-verified runtime marker and fallback behavior, and known gaps - is recorded in `docs/cmux-backend.md`.
cmux's container shape is one workspace per task with one surface, no per-home container split; workspace titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path, and `--secondmate` spawns are refused, mirroring Orca.
Codex App support is recorded in `docs/codex-app-backend.md`; it is not selectable as a runtime backend.

## Worktrees, not branches in your checkout

Crewmates never intentionally touch your project clone; [treehouse](https://github.com/kunchenguid/treehouse) pools clean worktrees for tmux, herdr, zellij, and cmux tasks, while Orca creates its own worktrees for `backend=orca`.
For ship and scout work, `fm-spawn.sh` refuses to launch unless the resolved task path is a real git worktree root that is distinct from the project primary checkout.

The firstmate repo has one extra exposure because it can dispatch crewmates to work on itself.
Its operating checkout (`FM_ROOT`) and the disposable crewmate worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
The primary checkout is healthy on its default branch, and linked worktrees or secondmate homes are healthy at detached HEAD.
Only a named non-default branch checked out in `FM_ROOT` is a worktree tangle.

`fm-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`fm-guard.sh` prints the repair command on the next mutable fleet action, while `bin/fm-session-start.sh` reports the same condition through bootstrap as a `TANGLE:` line at session start.
If another live session holds the fleet lock, both surfaces keep the alarm but switch to read-only wording with no repair command.
Ship briefs also tell the crewmate to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.

## Dispatch profiles

Crewmate and scout dispatch can stay on the static crewmate harness resolved by `config/crew-harness`, or it can use local dispatch profiles in `config/crew-dispatch.json`.
The dispatch file is intentionally judgment-based: firstmate reads the natural-language rules at intake, chooses the best matching rule, resolves that rule directly or through a supported selector, and passes only concrete `--harness`, `--model`, and `--effort` axes to `fm-spawn.sh`.
The shell scripts validate the JSON shape and verified harness/effort combinations, and `fm-dispatch-select.sh` owns deterministic selector behavior, but they do not parse task intent or match the natural-language rules.
The session-start bootstrap step surfaces either the active rule block or a concise invalid-config line at startup.
When the file exists, `fm-spawn.sh` refuses crewmate and scout launches without an explicit harness, so `config/crew-harness` is only automatic when no dispatch profile file is active.
Secondmate launches are exempt because they resolve the secondmate harness and any optional secondmate model or effort tokens instead.
Unsupported effort values are still recorded in task meta when passed to `fm-spawn.sh`, but the launch template omits any effort flag that the selected harness does not accept.
That keeps spawn launch compatible across claude, codex, grok, pi, and opencode while preserving the requested profile for later audit.

## Optional secondmates

`data/secondmates.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
`fm-home-seed.sh` provisions the isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `fm-spawn.sh --secondmate` launches it through the same session-provider and status-file path as any direct report.
On the herdr backend, a secondmate launch lands in that secondmate home's labeled workspace, and crewmates spawned from that home land in the same workspace.
When seeded with `-`, the home is a durable treehouse lease under the secondmate id, so it survives with no live process and is not recycled by later `treehouse get` or pruning.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
If returning the lease fails during teardown, firstmate leaves the route and home intact instead of hiding a still-held lease.
Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`local-only` projects stay with the main first mate because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple secondmate homes when their scopes differ, such as issue triage versus feature development.
Secondmates are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
When called with `FM_HOME=<this-firstmate-home>` or when `FM_HOME` is already set to the active firstmate home, metadata-routed `fm-send.sh` requests to a live `kind=secondmate` are prefixed with the from-firstmate marker from `bin/fm-marker-lib.sh`, so the secondmate returns terse answers through status lines and detailed answers through docs plus status pointers instead of replying only in its own chat.
Explicit backend-target sends and direct human typing stay unmarked, so captain intervention in a secondmate pane remains conversational.
After seeding a secondmate, `fm-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that secondmate home so the domain queue starts in the right place.
Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.

Secondmate homes stay on the same firstmate version as the primary checkout.
On locked session start, `fm-bootstrap.sh` fast-forwards each live secondmate home recorded in `state/*.meta` to the primary default-branch commit with no origin fetch.
The live signal is a `state/<id>.meta` record with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
A tracked-files fast-forward leaves the home's gitignored `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` directories untouched.
The same locked session start probes each live secondmate endpoint for a real agent process and respawns only a confidently dead endpoint; inconclusive probes are reported and never acted on.
The locked session-start bootstrap step separately propagates the primary's declared inheritable local config, currently `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend`, into each validated live secondmate home so that secondmate's own crewmates, dispatch profiles, and backlog backend use the primary settings.
That propagation is primary-authoritative, re-runs even when tracked files were already current, mirrors absence when the primary clears the value, and deliberately never copies `config/secondmate-harness`.
Dirty, diverged, unsafe, or in-flight homes are reported and left unchanged by the tracked-file sync.
Only a running secondmate home that actually advanced and changed `AGENTS.md`, `bin/`, or `.agents/skills/` is listed for a re-read nudge.
Changes under public `skills/` fast-forward like other tracked files, but they are not part of the running firstmate instruction surface.
`fm-config-push.sh` is the focused mid-session version of that same inheritance path: it discovers the same live secondmate homes, calls the same propagation helper, and reports per-home/per-item results without running the tracked-file fast-forward or sending reread nudges.
`fm-spawn.sh --secondmate` performs the same guarded local fast-forward before launch or recovery respawn; skipped syncs warn and the secondmate launches unchanged.
Secondmate spawn also propagates the same inheritable config before launch.

Secondmate agents can run on a different verified harness than crewmates.
`config/secondmate-harness` controls the primary's secondmate launch harness and may also carry optional model and effort tokens as `<harness> [<model>] [<effort>]` on the first non-empty, non-comment line.
A bare harness line remains harness-only, so existing `config/secondmate-harness` files keep their previous behavior.
When the harness token is unset or `default`, launch falls back to `config/crew-harness`, then to the primary's own harness, and the model and effort tokens are ignored.
Those optional tokens are re-read on every secondmate spawn or respawn and are overridden by explicit per-spawn `--model` or `--effort` flags.
An explicit per-spawn harness or raw launch command does not inherit model or effort tokens from `config/secondmate-harness`.
`config/crew-harness` remains the crewmate harness and is inherited into secondmate homes.
`config/crew-dispatch.json` is inherited too; secondmates use the same natural-language dispatch profiles when spawning their own crewmates.
`config/backlog-backend` is inherited too; absent or `tasks-axi` selects the default tasks-axi backlog backend, while `manual` forces hand-editing across the fleet.

The `data/secondmates.md` line schema and the secondmate environment variables are documented in [configuration.md](configuration.md).

## Project modes are explicit

`data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
`no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.
Review diffs go through `bin/fm-review-diff.sh`, which refreshes the authoritative base and, when task meta records `pr=`, compares against the reachable recorded `pr_head=` or a freshly fetched `refs/pull/<n>/head` before falling back to the local branch with a warning.
For target project repos shipped through their own no-mistakes pipeline, commits under `.no-mistakes/evidence/` are the pipeline's PR-viewable validation evidence and are expected to stay in the crew branch until the evidence-hosting design changes.
The firstmate repo itself is the exception: its `.no-mistakes/` directory is local state, stays gitignored, and is rejected by CI if tracked.
PR-based task merges go through `bin/fm-pr-merge.sh`, which records `pr=` and any available `pr_head=` through `bin/fm-pr-check.sh` before calling `gh-axi pr merge`.
The helper requires a full `https://github.com/<owner>/<repo>/pull/<n>` URL, invokes `gh-axi pr merge <n> --repo <owner>/<repo>`, defaults to `--squash`, preserves explicit merge-method flags, and rejects malformed URLs or repo override flags before recording merge state.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
If a git `index.lock` blocks safety inspection or `treehouse return`, teardown waits, retries, and only removes the lock when `bin/fm-teardown.sh` can prove it stale; otherwise it leaves the lock and state intact and fails closed.
Landed work is accepted when `HEAD` is reachable from any remote-tracking branch, when a merged PR's GitHub head contains the current local work, or when the worktree content is already present in the freshly fetched default branch.
PR-head containment covers an exact PR head match, a local `HEAD` that is an ancestor of the PR head, or unpushed local patches whose patch IDs appear in the PR head after no-mistakes replayed the branch.
GitHub lookup errors fall back to the content check and still refuse if that check is inconclusive.
If no `pr=` was ever recorded, teardown can still discover a merged PR by matching the worktree branch name and fetching `refs/pull/<n>/head` when the head branch was deleted.
Those PR-head and content checks let a squash-merged PR whose head branch was deleted tear down cleanly without using `--force`; `local-only` work instead tears down after the approved local default-branch merge or after the branch is pushed to any remote.

## Optional X mode

X mode is opt-in presence for the shared `@myfirstmate` bot.
A user enables it by putting `FMX_PAIRING_TOKEN` in the firstmate home's gitignored `.env`; `FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while parent-thread context may still include other public accounts.
On the locked session-start bootstrap step, that token creates two local artifacts: `state/x-watch.check.sh`, which performs one bounded relay poll through `bin/fm-x-poll.sh`, and `config/x-mode.env`, which sets `FM_CHECK_INTERVAL=30` for watcher processes in that home.
Without the token, the locked session-start bootstrap step removes those artifacts on opt-out and otherwise stays silent, so non-X users see no behavior change.
Pending mentions are stored as `state/x-inbox/<request_id>.json`; the `fmx-respond` agent-only skill drains that inbox, uses `in_reply_to` parent-post context for conversational continuity, classifies each mention as an actionable request, question, or pure acknowledgment, and submits public-safe replies through `bin/fm-x-reply.sh`.
When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
Actionable reversible requests run through firstmate's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.
Work that spawns a longer-running task gets an acknowledgement reply first; `bin/fm-x-link.sh` records `x_request=`, `x_request_ts=`, `x_followups=0`, and optional reply-platform context in that task's `state/<id>.meta`, and later milestone and completion wakes use `bin/fm-x-followup.sh` to post up to three public-safe follow-ups through the relay's `connector/followup` endpoint, ending with a `--final` one that always clears the link.
If recovery relinks the same relay request onto a successor task, `fm-x-link.sh --carry-count <n> --carry-ts <epoch> --carry-platform <x|discord> --carry-max <n>` preserves the consumed follow-up count, original 7-day window, and reply split budget instead of granting a fresh local budget or falling back to the wrong platform.
The follow-up helper forwards `--image <path>` to the same reply client when a follow-up needs an image.
Each follow-up is bounded by a local 7-day window and a 3-post cap; a successful non-final post increments the counter and keeps the link, while `--final`, reaching the cap, the window lapsing, or the relay itself rejecting an exhausted binding all clear it, and the helper is skipped for tasks that did not originate from an X-mode mention.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh`, which calls the relay's `connector/dismiss` endpoint and posts no text, then the local inbox file is cleared.
Concise replies stay single unnumbered messages; genuinely long replies are split by the client into bounded, numbered threads using the target platform's reply budget, with `texts` carrying the ordered chunks for the relay.
Splitting preserves fenced-code, paragraph, line, and word boundaries when possible.
If an image is attached to a split reply, the relay puts it on the first/opener message only and leaves later chunks text-only.
For preview testing, `FMX_DRY_RUN` makes `fm-x-reply.sh` and `fm-x-dismiss.sh` skip the public post or dismiss call and record the would-be payload under `state/x-outbox/`, including `texts` when the reply would be a thread and an `endpoint` marker when the preview is a completion follow-up or dismiss, while the rest of the poll -> compose -> would-post loop still succeeds.
Attached images are recorded as compact `{media_type, bytes, source_path}` metadata in dry-run instead of base64 bytes.
The watcher, wake queue, arm wrapper, and afk daemon are unchanged; X mode is layered on top through the existing check mechanism.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
Each project `AGENTS.md` carries a short `## Maintaining this file` self-governance section; `bin/fm-ensure-agents-md.sh` owns the canonical wording and appends it when creating the skeleton or promoting an existing `CLAUDE.md`.
The full ownership rule - what is project-intrinsic versus fleet-private, and how firstmate keeps the two apart without writing into project clones - is owned by firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (project memory ownership).

## Operational memory routing

`/stow` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
Captain preferences go to `data/captain.md`, fleet-local operational facts and gotchas go to `data/learnings.md`, project-intrinsic knowledge goes through normal crewmate delivery into that project's committed `AGENTS.md`, and task-scoped notes or undone next steps go to the backlog.
Memory writes use inspect-then-update: read the current destination first, then rewrite or prune matching bullets or notes in place instead of appending by default.
Task-scoped notes use `tasks-axi show <id> --full` followed by `tasks-axi update <id> --body-file <path>`, adding `--archive-body` when the prior body should remain recoverable.
Generalizable firstmate knowledge goes to shared tracked docs through the normal PR pipeline; the firstmate-internal `/stow` deliberately never stores findings in either skill directory.

## Local clones stay fresh

The locked session-start bootstrap step, PR-based teardown, and merged-PR wake handling refresh remote-backed project clones when the clone is safe to move.
Wake-time refreshes can target a single clone by project name, so the primary home also catches up when a secondmate reports a merge from its own home.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin`, then re-reads updated instructions and nudges updated secondmates without touching project clones.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
The origin-based updater and the local secondmate sync share the same guarded fast-forward helper; only the origin mode fetches.
The mechanics are owned by the `/updatefirstmate` skill and firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

Fleet state lives in each task's session-provider backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected), no-mistakes run records, status event logs, local markdown under `data/` including `data/captain.md` and `data/learnings.md`, and persistent secondmate homes.
For herdr, respawning after a server-restored layout closes and replaces confirmed no-agent or dead task-tab husks instead of requiring manual tab cleanup.
At session start, confirmed-dead secondmate agent endpoints are closed and relaunched through the same secondmate spawn path, while ambiguous liveness reads are left untouched to avoid duplicate supervisors.
Use `/stow` before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk; after that, the next firstmate session can reconcile and carry on.

## Development notes

The current watcher reliability work combines always-on bash triage with a durable queue for actionable wakes, a race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on watcher.
