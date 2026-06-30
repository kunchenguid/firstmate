# Architecture

How firstmate works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's full operating manual for the orchestrator agent itself is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals whose crew is not provably working, check-script output such as PR merge polling or an X mention, terminal stale panes, non-terminal stale panes whose crew is not provably working, provably-working non-terminal stale panes that persist past `FM_STALE_ESCALATE_SECS`, and heartbeat backstop hits.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed process exit can be recovered by draining the queue.
No-verb wakes, such as `working:` notes, bare turn-ended signals, and fresh non-terminal stale panes, are benign only when `bin/fm-crew-state.sh` reports positive evidence that the crew is still working: an actively running no-mistakes step for that crew's branch or a pane busy signature.
No-change heartbeats are also benign.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
After each drain, `fm-wake-drain.sh` runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only drains and handles queued wakes.
Routine watcher polling, re-arm no-ops, elapsed waiting time, and absorbed benign wakes stay silent; an idle crew costs you nothing.
Crew status files are append-only wake-event logs, not current-state fields.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes the matching no-mistakes run, active or terminal, to the crew's own branch and keeps that run-step authoritative even if the pane has closed.
Only when no matching run exists does it fall back to the pane busy-signature and then the status log; a dead pane without a run reports unknown instead of trusting a stale log.
Optional X mode rides the same check path: bootstrap drops a local `state/x-watch.check.sh` shim only after the user opts in with `FMX_PAIRING_TOKEN`, and non-X homes keep the default watcher behavior.

Routine re-arms go through `bin/fm-watch-arm.sh`, which forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `healthy` / `FAILED`, the last exiting non-zero) - never a false `already running` off a dying process.
Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if the primary checkout is tangled, or if tasks are in flight and that watcher stops running or queued wakes are waiting to be drained.
The drain script calls that guard after emptying the queue, which avoids repeating the queued-wakes warning for records it just consumed while still warning on stale watcher liveness.
It leads with prominent bordered banners for the tangle and no-watcher cases so they cannot be skimmed past.

A presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill activates it, after which the watcher reverts to daemon-managed one-shot mode and the daemon self-handles routine wakes in bash.
The watcher and daemon share `bin/fm-classify-lib.sh` for captain-relevant status verbs and status-scan primitives.
The always-on watcher also uses that library's provably-working predicate on no-verb signal and non-terminal-stale paths, while the daemon keeps its away-mode stale recheck unchanged.
The daemon escalates only captain-relevant events as one batched, single-line digest (prefixed with an in-band sentinel marker so firstmate can tell daemon injections apart from real messages).
Its injection path shares `bin/fm-tmux-lib.sh` with `fm-send.sh`, so dim-ghost-aware and border-aware composer detection plus verified submit retry stay consistent; stalled escalation delivery raises `state/.subsuper-inject-wedged` after `FM_MAX_DEFER_SECS` instead of silently deferring forever.
`fm-send.sh` selects a pre-Enter popup-settle for slash commands and for codex `$...` skill invocations using the target's recorded `harness=` meta, then adds its own `FM_SEND_SETTLE` pause after successful text sends so immediate peeks catch the receiving turn starting; the sub-supervisor uses only the shared submit core and does not pay that post-submit pause.

## Worktrees, not branches in your checkout

Crewmates never intentionally touch your project clone; [treehouse](https://github.com/kunchenguid/treehouse) pools clean worktrees so parallel tasks on one repo cannot collide.
For ship and scout work, `fm-spawn.sh` waits for `treehouse get` and then refuses to launch unless the pane resolves to a real git worktree root that is distinct from the project primary checkout.

The firstmate repo has one extra exposure because it can dispatch crewmates to work on itself.
Its operating checkout (`FM_ROOT`) and the disposable crewmate worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
The primary checkout is healthy on its default branch, and linked worktrees or secondmate homes are healthy at detached HEAD.
Only a named non-default branch checked out in `FM_ROOT` is a worktree tangle.

`fm-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`fm-guard.sh` prints the repair command on the next fleet action, while `fm-bootstrap.sh` reports the same condition as a `TANGLE:` line at session start.
Ship briefs also tell the crewmate to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.

## Dispatch profiles

Crewmate and scout dispatch can stay on the static crewmate harness resolved by `config/crew-harness`, or it can use local dispatch profiles in `config/crew-dispatch.json`.
The dispatch file is intentionally judgment-based: firstmate reads the natural-language rules at intake, chooses the best matching profile, and passes only concrete `--harness`, `--model`, and `--effort` axes to `fm-spawn.sh`.
The shell scripts validate the JSON shape and verified harness/effort combinations, but they do not parse task intent or match the natural-language rules.
Bootstrap surfaces either the active rule block or a concise invalid-config line at startup.
When the file exists, `fm-spawn.sh` refuses crewmate and scout launches without an explicit harness, so `config/crew-harness` is only automatic when no dispatch profile file is active.
Secondmate launches are exempt because they resolve the secondmate harness instead.
Unsupported effort values are still recorded in task meta when passed to `fm-spawn.sh`, but the launch template omits any effort flag that the selected harness does not accept.
That keeps spawn launch compatible across claude, codex, grok, pi, and opencode while preserving the requested profile for later audit.

## Optional secondmates

`data/secondmates.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
`fm-home-seed.sh` provisions the isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `fm-spawn.sh --secondmate` launches it through the same tmux and status-file path as any direct report.
When seeded with `-`, the home is a durable treehouse lease under the secondmate id, so it survives with no live process and is not recycled by later `treehouse get` or pruning.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
If returning the lease fails during teardown, firstmate leaves the route and home intact instead of hiding a still-held lease.
Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`local-only` projects stay with the main first mate because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple secondmate homes when their scopes differ, such as issue triage versus feature development.
Secondmates are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
Bare `fm-send.sh fm-<id>` requests to a live `kind=secondmate` are prefixed with the from-firstmate marker from `bin/fm-marker-lib.sh`, so the secondmate returns terse answers through status lines and detailed answers through docs plus status pointers instead of replying only in its own chat.
Explicit `session:window` sends and direct human typing stay unmarked, so captain intervention in a secondmate pane remains conversational.
After seeding a secondmate, `fm-backlog-handoff.sh` moves already-judged in-scope queued items from the main backlog into that secondmate home so the domain queue starts in the right place.
Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.

Secondmate homes stay on the same firstmate version as the primary checkout.
On main firstmate bootstrap, `fm-bootstrap.sh` fast-forwards each live secondmate home recorded in `state/*.meta` to the primary default-branch commit with no origin fetch.
The live signal is a `state/<id>.meta` record with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
A tracked-files fast-forward leaves the home's gitignored `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` directories untouched.
Bootstrap separately propagates the primary's declared inheritable local config, currently `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend`, into each validated live secondmate home so that secondmate's own crewmates, dispatch profiles, and backlog backend use the primary settings.
That propagation is primary-authoritative, re-runs even when tracked files were already current, mirrors absence when the primary clears the value, and deliberately never copies `config/secondmate-harness`.
Dirty, diverged, unsafe, or in-flight homes are reported and left unchanged by the tracked-file sync.
Only a running secondmate home that actually advanced and changed `AGENTS.md`, `bin/`, or `.agents/skills/` is listed for a re-read nudge.
`fm-config-push.sh` is the focused mid-session version of that same inheritance path: it discovers the same live secondmate homes, calls the same propagation helper, and reports per-home/per-item results without running the tracked-file fast-forward or sending reread nudges.
`fm-spawn.sh --secondmate` performs the same guarded local fast-forward before launch or recovery respawn; skipped syncs warn and the secondmate launches unchanged.
Secondmate spawn also propagates the same inheritable config before launch.

Secondmate agents can run on a different verified harness than crewmates.
`config/secondmate-harness` controls the primary's secondmate launch harness and falls back to `config/crew-harness`, then to the primary's own harness, when unset or `default`.
`config/crew-harness` remains the crewmate harness and is inherited into secondmate homes.
`config/crew-dispatch.json` is inherited too; secondmates use the same natural-language dispatch profiles when spawning their own crewmates.
`config/backlog-backend` is inherited too; absent or `tasks-axi` selects the default tasks-axi backlog backend, while `manual` forces hand-editing across the fleet.

The `data/secondmates.md` line schema and the secondmate environment variables are documented in [configuration.md](configuration.md).

## Project modes are explicit

`data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
`no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
Landed work is accepted when `HEAD` is reachable from any remote-tracking branch, when a merged PR's GitHub head contains the current local work, or when the worktree content is already present in the freshly fetched default branch.
PR-head containment covers an exact PR head match, a local `HEAD` that is an ancestor of the PR head, or unpushed local patches whose patch IDs appear in the PR head after no-mistakes replayed the branch.
GitHub lookup errors fall back to the content check and still refuse if that check is inconclusive.
Those PR-head and content checks let a squash-merged PR whose head branch was deleted tear down cleanly without using `--force`; `local-only` work instead tears down after the approved local default-branch merge or after the branch is pushed to any remote.

## Optional X mode

X mode is opt-in presence for the shared `@myfirstmate` bot.
A user enables it by putting `FMX_PAIRING_TOKEN` in the firstmate home's gitignored `.env`; `FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while parent-thread context may still include other public accounts.
On bootstrap, that token creates two local artifacts: `state/x-watch.check.sh`, which performs one bounded relay poll through `bin/fm-x-poll.sh`, and `config/x-mode.env`, which sets `FM_CHECK_INTERVAL=30` for watcher arms in that home.
Without the token, bootstrap removes those artifacts on opt-out and otherwise stays silent, so non-X users see no behavior change.
Pending mentions are stored as `state/x-inbox/<request_id>.json`; the `fmx-respond` agent-only skill drains that inbox, uses `in_reply_to` parent-tweet context for conversational continuity, classifies each mention as an actionable request, question, or pure acknowledgment, and submits public-safe replies through `bin/fm-x-reply.sh`.
When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
Actionable reversible requests run through firstmate's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.
Work that spawns a longer-running task gets an acknowledgement reply first; `bin/fm-x-link.sh` records `x_request=` and `x_request_ts=` in that task's `state/<id>.meta`, and the terminal completion wake later uses `bin/fm-x-followup.sh` to post one public-safe follow-up through the relay's `connector/followup` endpoint.
The follow-up helper forwards `--image <path>` to the same reply client when the completion outcome needs an image.
The follow-up is bounded by a local 24h window, clears the link after success or expiry, and is skipped for tasks that did not originate from an X mention.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh`, which calls the relay's `connector/dismiss` endpoint and posts no text, then the local inbox file is cleared.
Concise replies stay single unnumbered tweets; genuinely long replies are split by the client into bounded, numbered threads on word boundaries, with `texts` carrying the ordered chunks for the relay.
If an image is attached to a split reply, the relay puts it on the first/opener tweet only and leaves later chunks text-only.
For preview testing, `FMX_DRY_RUN` makes `fm-x-reply.sh` and `fm-x-dismiss.sh` skip the public post or dismiss call and record the would-be payload under `state/x-outbox/`, including `texts` when the reply would be a thread and an `endpoint` marker when the preview is a completion follow-up or dismiss, while the rest of the poll -> compose -> would-post loop still succeeds.
Attached images are recorded as compact `{media_type, bytes, source_path}` metadata in dry-run instead of base64 bytes.
The watcher, wake queue, arm wrapper, and afk daemon are unchanged; X mode is layered on top through the existing check mechanism.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
The full ownership rule - what is project-intrinsic versus fleet-private, and how firstmate keeps the two apart without writing into project clones - is owned by firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (project memory ownership).

## Local clones stay fresh

Bootstrap and PR-based teardown refresh remote-backed project clones when the clone is safe to move.
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

All state lives in tmux, no-mistakes run records, status event logs, local markdown under `data/`, `data/secondmates.md`, and persistent secondmate homes.
Kill the first mate session anytime; the next one reconciles and carries on.

## Development notes

The current watcher reliability work combines always-on bash triage with a durable queue for actionable wakes, a race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on watcher.
