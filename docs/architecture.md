# Architecture

How firstmate works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's always-loaded operating contract and routing index for conditional procedures is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals whose crew is not provably working, authenticated check output such as PR merge polling or an X-mode mention, stale panes whose crew is not provably working whether their status log looks terminal or non-terminal, provably-working stale panes that persist past `FM_STALE_ESCALATE_SECS`, declared external waits that remain paused past `FM_PAUSE_RESURFACE_SECS`, and heartbeat backstop hits.
Repeated provably-working stale escalations on the same unchanged pane add an escalation count to the wake reason and, at `FM_WEDGE_DEMAND_INSPECT_COUNT`, a `demand-deep-inspection` marker.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed process exit can be recovered by draining the queue.
No-verb wakes, such as `working:` notes and bare turn-ended signals, are benign only when `bin/fm-crew-state.sh` reports positive evidence that the crew is still working: an actively running no-mistakes step attributed to that crew's current code or a backend busy signature.
A crew that declares `paused:` for a known external wait is separately absorbed while idle and re-surfaced only on the longer pause cadence, rather than being treated as a possible wedge.
For an ordinary crew that has stopped, the normal-mode watcher first surfaces one stale wake, then applies that same cadence to an unchanged `paused:` or durable `captain-held` endpoint only when the backend confidently reports its agent dead.
Live or inconclusive liveness remains fail-open at that initial surface, and the secondmate idle-endpoint exemption is unchanged.
Its initial normal-mode status signal still surfaces through the no-verb path, while away mode self-handles that routine signal and owns the later recheck.
Fresh stale panes use the same current-state read before trusting the status log, so an active run or busy pane outranks an old captain-relevant status-log line left behind before validation.
No-change heartbeats are also benign.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
After each drain, `fm-wake-drain.sh` runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only drains and handles queued wakes.
Routine watcher polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent.
A declared external wait trades that silence for one bounded recheck per pause window, so a forgotten pause cannot remain invisible indefinitely.
Crew status files are append-only wake-event logs, not current-state fields.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes a no-mistakes run, active or terminal, only when it matches the crew's branch and current code identity, then keeps that run-step authoritative even if the pane has closed.
The script header owns the exact run-head ancestry rules.
During no-mistakes' `ci` monitor phase, it also reads the ci step log tail because `axi status` reports both "still waiting on checks" and "checks green, waiting on merge" as `ci,running`.
The most recent recognized ci log marker wins, so checks-green monitoring reports done while a later re-arm, failed-check, or issue marker returns the crew to working.
Only when no matching run exists does it fall back to the pane busy-signature and then a status-log event whose verb maps to a recognized run-state; a dead pane without a run reports unknown instead of trusting a stale log.
Decision-only events such as `resolved` never become current state or leak their prose into the current-state detail.
In that status-log fallback, a declared external wait reports the distinct `paused` state with its reason.
For herdr, that pane fallback trusts a native `busy` verdict outright, but corroborates native `idle` or unknown verdicts against the rendered busy signature before deciding the crew is not working.
For whole-fleet read-only review, `bin/fm-fleet-snapshot.sh --json` emits schema `fm-fleet-snapshot.v1` from the backlog, task metadata, current crew state, endpoint probes, PR/report pointers, scout reports, bounded current summaries from registered secondmate homes, and secondmate return-channel guidance.
`bin/fm-fleet-view.sh` renders that snapshot as Markdown for humans, while `bin/fm-bearings-snapshot.sh` provides the bounded bearings projection, so both views consume one structured contract instead of reparsing raw fleet files.
The script header owns the exact JSON schema.

### Registered secondmate current state

A registered secondmate's validated home is the authority for bearings current state because it owns the child metadata inventory, each child's current-state result, endpoint observations, backlog holds and dependencies, keyed unresolved decisions, and recent Done baseline.
The original cross-home projection instead treated the secondmate agent as an ordinary parent task, so an idle secondmate's `fm-crew-state` fallback selected the latest append-only parent status event even when structured state in the registered home contradicted it.
The parent-status contract also required explicit keyed resolution for decisions and blockers but not for a material `working` phase, so a start event could remain unsuperseded after the corresponding home backlog had moved the work to Done.
Generated secondmate charters now key material routed-work phases and close them with a same-key later state or `resolved` event, while the structured home remains authoritative even if that closure is missing.
Cross-home reads validate the seeded identity and operational-directory boundaries, use per-home time and output bounds, and classify unavailable, invalid, malformed, or inconsistent structured state as unknown rather than reviving a parent event as current work.
A bounded direct-report terminal tail can help diagnose a mismatch by showing that historical parent wording is still visible, but it is untrusted supplemental evidence because scrollback, prompts, copied output, idle shells, and agent prose are not durable state.
The snapshot strips control sequences, retains only capture metadata and literal event-corroboration flags, and never lets terminal evidence override a valid structured classification.
The default path remains local-only; live GitHub enrichment exists only behind the bearings `--include-prs` opt-in.
Optional X mode integrates with the watcher only after explicit opt-in; [configuration.md](configuration.md#x-mode-env) owns its generated-artifact and dispatch mechanics.

At session start, `bin/fm-session-start.sh` emits exactly one primary-harness supervision block rendered by `bin/fm-supervision-instructions.sh` from `docs/supervision-protocols/`.
That block owns the live wait shape for the running primary harness: Claude and Grok use background-notify cycles, Codex uses bounded foreground checkpoints, Pi uses its two tracked primary extensions, and OpenCode uses its TUI plugin.
`bin/fm-watch-arm.sh` remains the verified arm wrapper for protocols that call it; it forks the watcher as a tracked child, verifies it is genuinely alive with a fresh liveness beacon, and prints an honest `started`, `attached`, or nonzero `FAILED` status.
On `attached` it stays live across identity-matched successors, and an unexplained clean child close either attaches to a verified healthy successor or becomes the typed nonzero `watcher: FAILED - cycle ended without an actionable reason` result.
The arm layer records one bounded lifecycle row per observed cycle in `state/.watch-cycle-exits.log`; `state/.watch-triage.log` remains exclusively the absorbed-wake debug log.
Pi and OpenCode verify session-lock ownership and launch one singleton successor from their child-close handlers before delivering an actionable wake prompt, with bounded exponential retry for failed restoration.
Claude keeps its tracked background-task protocol and adds a narrow PreToolUse continuity gate that allows drain, arm recovery, and fail-closed teardown while refusing only other fleet commands when tasks are in flight and no identity-matched live watcher holds the home lock.
The existing turn-end guard is unchanged and remains the final backstop for all five harness protocols.
Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if the primary checkout is tangled, or if tasks are in flight and that watcher stops running or queued wakes are waiting to be drained.
The drain script calls that guard after emptying the queue, which avoids repeating the queued-wakes warning for records it just consumed while still warning on stale watcher liveness.
It leads with a prominent bordered tangle banner, while `bin/fm-guard.sh` owns the stale-watcher banner/reminder policy so repeated guarded commands stay noisy without reprinting the full watcher-down banner in the same episode.
On every verified primary harness, tracked hook integration gives the primary session a push-based backstop: when work is in flight and no identity-matched watcher lock with a fresh beacon is live, direct Stop hooks block and passive turn-end hooks force one bounded follow-up.
The guard covers the main primary and genuinely marked secondmate homes, exempts child crewmate/scout worktrees, is loop-safe per harness, and is documented in [turnend-guard.md](turnend-guard.md).

A presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) extends this for walk-away supervision: the `/afk` skill starts it through the tracked foreground helper `bin/fm-afk-start.sh`, after which the watcher reverts to daemon-managed one-shot mode and the daemon self-handles routine wakes in bash.
The watcher and daemon share `bin/fm-classify-lib.sh` for captain-relevant status verbs, declared-external-wait vocabulary, and status-scan primitives.
Terminal verbs remain captain-relevant, while a nonterminal progress verb cannot become terminal merely because its prose contains a legacy free-text token such as `merged`; bare legacy free-text lines remain compatible.
The always-on watcher also uses that library's absorb classification on no-verb signals and first-sighting stale panes before status-log terminality is trusted, while the daemon maintains distinct wedge and declared-pause recheck cadences.
In away mode, seen-status dedupe does not clear possible-wedge aging for nonterminal progress, so housekeeping still re-escalates an unchanged idle pane at the configured bound.
The daemon escalates captain-relevant events, plus a bounded recheck for a declared pause that remains idle, as one batched, single-line digest prefixed with a terminal-safe U+2063 sentinel marker so firstmate can tell daemon injections apart from real messages.
Its supervisor injection path supports tmux and herdr panes, with `FM_SUPERVISOR_BACKEND` and `FM_SUPERVISOR_TARGET` resolved independently from the task-spawn backend.
Pane existence, busy checks, composer checks, capture, and verified submit route through `bin/fm-backend.sh`: tmux keeps the same submit core used by the tmux send backend, while herdr uses native busy state, native agent-state submit confirmation on idle baselines, and its ANSI-aware structural composer classifier for pending-input guards and submit fallback.
The tmux submit core (shared `fm_tmux_submit_enter_core`) treats a busy pane + retries-exhausted + composer-still-pending as a queued Enter (opencode 1.18.4 accepts Enter mid-turn and queues it for after the turn), reported as `empty` so the daemon and `fm-send` do not re-send; an idle pane keeps the `pending` verdict as a genuine swallow. The same opencode busy-queue case is a known gap on the herdr adapter and is recorded in `docs/herdr-backend.md` rather than patched here.
Composer-content classification has one shared owner, `bin/fm-composer-lib.sh`, used by tmux, herdr, Orca, and cmux after each adapter performs its own capture and composer-row recognition.
The daemon injects only into an affirmatively `empty` composer, so both `pending` and `unknown` defer and a bare dead-shell prompt cannot receive an escalation; the complete policy is in [Composer-emptiness safety](herdr-backend.md#composer-emptiness-safety-2026-07-10-fleet-wide-across-all-four-backends).
Unsupported supervisor backends refuse at daemon startup.
Stalled escalation delivery writes `state/.subsuper-inject-wedged` and attempts a configured backend-independent active alert after `FM_MAX_DEFER_SECS` instead of silently deferring forever.
On an unmarked return, `bin/fm-afk-return.sh` owns ordered shutdown, durable catch-up evidence, and the fail-closed gate that keeps ordinary work behind every live firstmate-actionable blocker.
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
For capable herdr sessions, the same watcher replaces its terminal sleep with a bounded native event wait that immediately surfaces `blocked`; [herdr-backend.md](herdr-backend.md#native-paneagent_status_changed-push-escalation-immediate-blocked-wake) owns the mechanism, capability gates, and verification evidence.
The deeper session-start agent-process liveness probe is separate from that busy-state poll: tmux and herdr have verified classifiers for secondmate recovery, while zellij, Orca, and cmux currently report `unknown` rather than guess.
Herdr is experimental and can be selected explicitly or by runtime auto-detection: treehouse remains the worktree provider for it exactly as it is for tmux (herdr is a session provider only), and its full verification - the container shape decision, created-vs-adopted default-tab prune safety, restored-layout husk respawn idempotency, verified CLI facts, ANSI-preserved ghost/placeholder classification through the shared extractor, a verified small-`--lines` capture bug and its workaround, and known gaps - is recorded in `docs/herdr-backend.md`.
Herdr's durable default container shape is workspace-per-home plus tab-per-task: the primary home uses workspace label `firstmate`, secondmate homes use `2ndmate-<secondmate-id>`, and recovery/list-live scopes to the current `FM_HOME`'s workspace.
Its optional default-off presentation projection may place one clean new task in a disposable workspace without changing endpoint authority or lifecycle ownership; [`docs/herdr-backend.md`](herdr-backend.md#optional-disposable-single-task-presentation-spaces) owns that conditional design.
Zellij is experimental and selected only explicitly: treehouse remains its worktree provider too, and its full verification - the resolved "gaps to verify" list from the original design report, the unconditional-exit-0 CLI quirk and its mitigation, the focus-steal-on-new-tab finding, the home-scoped tab-title collision fix, and known gaps - is recorded in `docs/zellij-backend.md`.
Zellij's container shape is simpler than herdr's: one shared `firstmate` session, one tab per task, with no per-home workspace split; visible tab titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path.
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

## No-mistakes gate authority boundary

Firstmate's own no-mistakes gate runs agents inside a checkout that also contains the fleet-captain identity in `AGENTS.md`, so gate execution needs an authority boundary separate from ordinary crewmate worktree isolation.
The tracked `.no-mistakes.yaml` sets `disable_project_settings: true`; no-mistakes honors that setting only from the trusted default-branch copy, so a pushed branch cannot enable its own project instructions during validation.
Independently, `fm-spawn.sh`, `fm-send.sh`, and `fm-teardown.sh` source `bin/fm-gate-refuse-lib.sh` and exit with status 3 before fleet mutation when the gate environment marker is present or the current checkout matches the default no-mistakes gate-repository topology.
A normal primary checkout or crewmate worktree has neither signal and remains unaffected.
The helper's header owns the exact signal detection, relocated-home limitation, test-harness bypass, and relationship to no-mistakes' HEAD-continuity guard.

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

`data/secondmates.md` records persistent secondmates with natural-language scopes, project clone lists, and home paths.
`fm-home-seed.sh` provisions the isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `fm-spawn.sh --secondmate` launches it through the same session-provider and status-file path as any direct report.
For a domain whose subject is the firstmate repo itself, a deliberate `--no-projects` seed creates a project-less home whose crews take pooled worktrees of that repo instead of separate clones.
The signal cannot be mixed with project names or omitted accidentally, and a populated home cannot be converted in place; the full seed contract is in [configuration.md](configuration.md#secondmate-routes-datasecondmatesmd).
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
After seeding a secondmate, `fm-backlog-handoff.sh` validates the fleet-specific handoff, then atomically delegates already-judged in-scope queued item moves to `tasks-axi mv` so the domain queue starts in the right place.
Idle secondmate panes are healthy; teardown is explicit and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.

Secondmate homes converge conservatively to the primary's version and declared inherited local material at launch and during locked session start.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the full guarded sync, propagation, nudge, and mid-session local-material push contract.

Secondmate agents can run on a different verified harness than crewmates.
`config/secondmate-harness` controls the primary's secondmate launch harness and may also carry optional model and effort tokens as `<harness> [<model>] [<effort>]` on the first non-empty, non-comment line.
A bare harness line remains harness-only, so existing `config/secondmate-harness` files keep their previous behavior.
When the harness token is unset or `default`, launch falls back to `config/crew-harness`, then to the primary's own harness, and the model and effort tokens are ignored.
Those optional tokens are re-read on every secondmate spawn or respawn and are overridden by explicit per-spawn `--model` or `--effort` flags.
An explicit per-spawn harness or raw launch command does not inherit model or effort tokens from `config/secondmate-harness`.
`config/crew-harness` remains the crewmate harness and is inherited into secondmate homes.
`config/crew-dispatch.json` is inherited too; secondmates use the same natural-language dispatch profiles when spawning their own crewmates.
`config/backlog-backend` is inherited too; absent or `tasks-axi` selects the default tasks-axi backlog backend, while `manual` forces routine backlog updates to hand-editing across the fleet without disabling validated handoff delegation.

The `data/secondmates.md` line contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), and the secondmate environment variables are documented in [configuration.md](configuration.md).

## Project modes are explicit

`data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
`no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.
When a selected delivery path calls for a diff, `bin/fm-review-diff.sh` refreshes the authoritative base and, when task meta records `pr=`, always fetches and compares against `refs/pull/<n>/head` by default (recorded `pr_head=` is only an offline fallback) before falling back to the local branch with a warning.
For target project repos shipped through their own no-mistakes pipeline, commits under `.no-mistakes/evidence/` are the pipeline's PR-viewable validation evidence and are expected to stay in the crew branch until the evidence-hosting design changes.
The firstmate repo itself is the exception: its `.no-mistakes/` directory is local state, stays gitignored, and is rejected by CI if tracked.
PR-based task merges go through `bin/fm-pr-merge.sh`, which records `pr=` and any available `pr_head=` through `bin/fm-pr-check.sh` before calling `gh-axi pr merge`.
The helper requires a full `https://github.com/<owner>/<repo>/pull/<n>` URL, invokes `gh-axi pr merge <n> --repo <owner>/<repo>`, defaults to `--squash`, preserves explicit merge-method flags, and rejects malformed URLs or repo override flags before recording merge state.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
[`bin/fm-teardown.sh`](../bin/fm-teardown.sh)'s header owns the landed-work proofs, PR-discovery fallback, and stale-lock recovery procedure.

## Optional X mode

X mode is opt-in presence for the shared `@myfirstmate` bot.
A user enables it by putting `FMX_PAIRING_TOKEN` in the firstmate home's gitignored `.env`; `FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while parent-thread context may still include other public accounts.
On the locked session-start bootstrap step, that token creates the local polling and watcher-cadence artifacts described in the [X mode configuration reference](configuration.md#x-mode-env).
Without the token, the locked session-start bootstrap step removes those artifacts on opt-out and otherwise stays silent, so non-X users see no behavior change.
Newly offered mentions are stored as `state/x-inbox/<request_id>.json` and wake firstmate once per retained request ID; the [X mode configuration reference](configuration.md#x-mode-env) owns the durable offer-marker and re-offer contract.
The `fmx-respond` agent-only skill drains that inbox, uses `in_reply_to` parent-post context for conversational continuity, classifies each mention as an actionable request, question, or pure acknowledgment, and submits public-safe replies through `bin/fm-x-reply.sh`.
When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
Actionable reversible requests run through firstmate's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.
Work that spawns a longer-running task gets an acknowledgement reply first; `bin/fm-x-link.sh` records `x_request=`, `x_request_ts=`, `x_followups=0`, and optional reply-platform context in that task's `state/<id>.meta`, while durable per-request context preserves the original platform and budget independently of task links and inbox cleanup.
Later milestone and completion wakes use `bin/fm-x-followup.sh` to post up to three public-safe follow-ups through the relay's `connector/followup` endpoint, ending with a `--final` one that always clears the link.
The [X mode configuration reference](configuration.md#x-mode-env) owns the exact context retention, platform-resolution, and fail-safe posting contract.
If recovery relinks the same relay request onto a successor task, `fm-x-link.sh --carry-count <n> --carry-ts <epoch> --carry-platform <x|discord> --carry-max <n>` preserves the consumed follow-up count, original 7-day window, and reply split budget instead of granting a fresh local budget or falling back to the wrong platform.
The follow-up helper forwards `--image <path>` to the same reply client when a follow-up needs an image.
Each follow-up is bounded by a local 7-day window and a 3-post cap; a successful non-final post increments the counter and keeps the link, while `--final`, reaching the cap, the window lapsing, or the relay itself rejecting an exhausted binding all clear it, and the helper is skipped for tasks that did not originate from an X-mode mention.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh`, which calls the relay's `connector/dismiss` endpoint and posts no text, then the local inbox file is cleared.
Concise replies stay single unnumbered messages; genuinely long replies are split by the client into bounded, numbered threads using the target platform's reply budget, with `texts` carrying the ordered chunks for the relay.
Splitting preserves fenced-code, paragraph, line, and word boundaries when possible.
If an image is attached to a split reply, the relay puts it on the first/opener message only and leaves later chunks text-only.
For preview testing, `FMX_DRY_RUN` makes `fm-x-reply.sh` and `fm-x-dismiss.sh` skip the public post or dismiss call and record the would-be payload under `state/x-outbox/`, including `texts` when the reply would be a thread and an `endpoint` marker when the preview is a completion follow-up or dismiss, while the rest of the poll -> compose -> would-post loop still succeeds.
Attached images are recorded as compact `{media_type, bytes, source_path}` metadata in dry-run instead of base64 bytes.
X mode remains layered on top of the existing check mechanism without changing its request-handling behavior.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
Each project `AGENTS.md` carries a short `## Maintaining this file` self-governance section; `bin/fm-ensure-agents-md.sh` owns the canonical wording and injects it idempotently when creating the skeleton, promoting an existing `CLAUDE.md`, or reconciling an existing `AGENTS.md` that still lacks it.
It refuses a case-variant real memory file such as a lowercase `agents.md`, whose `CLAUDE.md` symlink would carry an uppercase literal target that dangles on a case-sensitive filesystem, and surfaces the mismatch for manual reconciliation.
The full ownership rule - what is project-intrinsic versus fleet-private, and how firstmate keeps the two apart without writing into project clones - is owned by [`AGENTS.md`](../AGENTS.md) (project and knowledge management).

## Operational memory routing

`/stow` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
Home-domain captain preferences go to `data/captain.md`, cross-domain shared captain preferences go to the primary home's `data/captain-shared.md`, fleet-local operational facts and gotchas go to home-local `data/learnings.md`, project-intrinsic knowledge goes through normal crewmate delivery into that project's committed `AGENTS.md`, and task-scoped notes or undone next steps go to the backlog.
Memory writes use inspect-then-update: read the current destination first, then rewrite or prune matching bullets or notes in place instead of appending by default.
Task-scoped notes use `tasks-axi show <id> --full` followed by `tasks-axi update <id> --body-file <path>`, adding `--archive-body` when the prior body should remain recoverable.
Generalizable firstmate knowledge goes to shared tracked docs through the normal PR pipeline; the firstmate-internal `/stow` deliberately never stores findings in either skill directory.

## Local clones stay fresh

The locked session-start bootstrap step, PR-based teardown, and merged-PR wake handling refresh remote-backed project clones when the clone is safe to move.
Wake-time refreshes can target a single clone by project name, so the primary home also catches up when a secondmate reports a merge from its own home.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Fetches blocked by an orphaned `.git/packed-refs.lock` use bounded retries and remove the lock only when the shared staleness proof can prove it abandoned; [configuration.md](configuration.md#toolchain) owns the recovery details and tuning knobs.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin`, then re-reads updated instructions and nudges updated secondmates without touching project clones.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
The origin-based updater and the local secondmate sync share the same guarded fast-forward helper; only the origin mode fetches.
The mechanics are owned by the `/updatefirstmate` skill and firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

Fleet state lives in each task's session-provider backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected), no-mistakes run records, status event logs, local markdown under `data/` including `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, and persistent secondmate homes.
For herdr, respawning after a server-restored layout closes and replaces confirmed no-agent or dead task-tab husks instead of requiring manual tab cleanup.
At session start, confirmed-dead secondmate agent endpoints are closed and relaunched through the same secondmate spawn path, while ambiguous liveness reads are left untouched to avoid duplicate supervisors.
Use `/stow` before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk; after that, the next firstmate session can reconcile and carry on.

## Development notes

The current watcher reliability work combines always-on bash triage with a durable queue for actionable wakes, a race-proof singleton lock, duplicate self-eviction, drain-time liveness assertion, and a self-verifying tracked-child arm wrapper.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on watcher.
