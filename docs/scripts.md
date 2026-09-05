# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), while `docs/sessionstart-nudge.md` covers the silent session-open hook use; `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-sessionstart-nudge.sh` | Print the native session-start hook nudge when the primary has not already run the digest |
| `fm-sessionstart-run.sh` | Route a native session-open hook to the full digest, a context re-emit, or the nudge |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install approved tools |
| `fm-startup-network.sh`  | Run session start's network checks and inactive-outcome scan off its blocking path, retaining reports and durable findings |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print structured fleet snapshot JSON and refresh only its parent-side remote-ledger cache (schema `fm-fleet-snapshot.v1`) |
| `fm-home-summary-refresh.sh` | Atomically publish this home's structured summary ledger                         |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the bounded remote-ledger fleet snapshot to compact TOON; `--include-prs` adds live GitHub enrichment |
| `fm-bearings-board.sh`   | Build and arm the stable interactive `/bearings lavish` fleet board                  |
| `fm-secondmate-reconcile.sh` | Queue Bearings reconcile requests for later supervision delivery and ask each mismatched home through its durable inbox with a per-home cooldown |
| `fm-update.sh`           | Fast-forward-only self-update of firstmate and local or remote secondmate homes, classifying every live mate left on the target commit for restart or fallback nudge |
| `fm-secondmate-restart.sh` | Persist open conversational work, then restart eligible second mates or report the fallback outcome |
| `fm-secondmate-restart-lib.sh` | Shared second-mate restart capability and persistence-request contract |
| `fm-on.sh`               | Execute one tracked Firstmate command in a configured remote secondmate home, using its job worker except for the doctor bootstrap |
| `fm-remote-job-lib.sh`   | Shared bounded remote job queue, worker readiness, LaunchAgent contract, and filesystem-composed PATH |
| `fm-remote-job-worker.sh` | Long-lived remote queue worker for tracked `fm-*.sh` commands in the account runtime |
| `fm-remote-job-reap-orphans.sh` | Stop remote job workers left running by a pruned code root, never one whose checkout still exists |
| `fm-remote-doctor.sh`    | Check, and with `--fix` repair, one remote account's second-mate readiness (remote job worker, Herdr, Aqua launch agents, PATH, and required tools) |
| `fm-backlog-handoff.sh`  | Move queued backlog items into a secondmate home and durably wake its recorded receiver |
| `fm-backlog-receive.sh`  | Idempotently ingest one confined remote handoff outbox through tasks-axi             |
| `fm-captain-hold.sh`     | Hold tasks for the captain, record the captain's answers, gate investigation completion, and report record divergence between the status log and the backlog |
| `fm-decision-hold.sh`    | One-release compatibility shim mapping the retired decision commands onto fm-captain-hold.sh |
| `fm-brief.sh`            | Scaffold ship (explicit `--mode`), scout, secondmate-charter, and Herdr-lab briefs, with Captain's intent and Firstmate spec subsections on ship/scout |
| `fm-dod-lib.sh`          | One owner of ship definitions of done, worker-side remote-delivery proof, and the no-mistakes `--intent` contract |
| `fm-herdr-lab.sh`        | Provision and guardedly operate an isolated, never-default Herdr lab session         |
| `fm-install-herdr.sh`    | Install CI's exact-version Herdr pin with official asset URL, SHA-256, and protocol checks |
| `fm-install-treehouse.sh`| Install CI's exact-version Treehouse pin for real-Herdr E2E that needs spawn worktrees |
| `fm-herdr-ci-cleanup.sh` | Snapshot and tear down only job-owned `fm-lab-*` sessions in the Herdr CI lane       |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, bounded concurrency, budgets, coverage guard, timing/JSON |
| `fm-test-isolation-proof.sh` | Concurrent isolation harness and portable candidate set owner |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` `@AGENTS.md` pointer, and the canonical self-governance section |
| `fm-guard.sh`            | Warn on primary-checkout tangles, main-session pending wakes, and unhealthy supervision |
| `fm-primary-scope-lib.sh` | Shared marker-or-plain-checkout primary-home predicate for tracked hooks             |
| `fm-session-lock-lib.sh` | Shared session-lock harness identity (ancestry walk and holder liveness) for fm-lock.sh and the Claude Stop auto-arm |
| `fm-claude-stop-autoarm.sh` | Claude Stop `asyncRewake` hook owning tokenless watcher continuity with single-flight exit-2 rewake (docs/watcher-continuity.md) |
| `fm-turnend-guard.sh`    | Shared primary turn-end guard predicate so no turn ends blind (docs/turnend-guard.md) |
| `fm-turnend-guard-grok.sh` | Grok Stop-hook adapter for the primary turn-end guard                              |
| `fm-kimi-turnend-hook.sh` | Surgically install or remove Kimi's guarded global crew turn-end hook                |
| `fm-arm-pretool-check.sh` | Stable PreToolUse transport for the watcher-arm command policy (docs/arm-pretool-check.md) |
| `fm-arm-command-policy.mjs` | Semantic owner of the watcher-arm PreToolUse policy (docs/arm-pretool-check.md)   |
| `fm-subagent-pretool-check.sh` | Primary-home delegation-shape PreToolUse guard (docs/subagent-guard.md) |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a local secondmate home and maintain `data/secondmates.md` |
| `fm-remote-home-seed.sh` | Register and provision a whole secondmate home on an SSH-reachable host              |
| `fm-remote-readiness-lib.sh` | Shared remote second-mate readiness gate: check and, when needed, repair then re-check through `fm-remote-doctor.sh` |
| [`fm-project-origin-lib.sh`](../bin/fm-project-origin-lib.sh) | Accepted origin-form owner shared by both remote provisioning boundaries |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-backend-hometag-lib.sh` | Shared per-installation home-tag derivation for zellij tab and cmux workspace titles |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer shapes, capability-aware screen classification, and verdicts |
| `backends/tmux.sh`       | Verified tmux session-provider adapter                                               |
| `backends/herdr.sh`      | Experimental herdr session-provider adapter                                          |
| `backends/zellij.sh`     | Experimental zellij session-provider adapter                                         |
| `backends/orca.sh`       | Experimental Orca backend adapter owning both worktree and terminal                  |
| `backends/cmux.sh`       | Experimental cmux session-provider adapter                                           |
| `fm-config-push.sh`      | Push declared inherited local material to live local or remote secondmates and send the placement-specific config reread when changed |
| `fm-project-mode.sh`     | Resolve a project's registered delivery posture from `data/projects.md` for fleet sync and home seeding |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-task-inbox-lib.sh`   | Single owner of durable steering-inbox records, acknowledgement, doorbells, and the delivery-attempt ladder |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and keyed escalation lifecycle |
| `fm-secondmate-report.sh` | Optional helper that resolves the parent channel itself and appends a correlated status or document-pointer report |
| `fm-extension.mjs`       | Bind, inspect, verify, and strictly invoke trusted external process-event adapter packages |
| `fm-extension-launch-barrier.mjs` | Publish one exact static core-owned invocation group before package code runs |
| `fm-extension.sh`        | Expose extension binding commands through the tracked shell and remote-home command boundary |
| `fm-procevent.sh`        | Register, supervise, capture, classify, acknowledge, and safely retire built-in or explicitly bound process-event sources |
| `fm-procevent-remote-reply.sh` | Relay the remote-secondmate status stream through non-destructive process-event deltas |
| `fm-procevent-quota.sh`  | Wake Firstmate when tracked quota drops below a threshold, is exhausted, or cannot be polled |
| `fm-procevent-when.sh`   | Fire a trust-bound deterministic action at most once when its registered condition holds, then wake with the outcome |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-watch-checkpoint.sh` | Run one bounded foreground watcher checkpoint for Codex-style supervision            |
| `fm-watch.sh`            | Singleton-safe watcher: absorb benign wakes, detect stalled local-secondmate wake queues, and exit on actionable ones |
| `fm-inactive-reconcile.sh` | Reconcile long-inactive direct crewmate terminal outcomes without forge access |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry, exit, rollback, and any backend terminal lifecycle                 |
| `fm-afk-return.sh`       | Own deterministic return shutdown, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Print one deterministic current-state line for a crew                                |
| `fm-nm-run-lib.sh`       | Single owner of shared no-mistakes run-attribution primitives and rules             |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-timeout-lib.sh`      | Single owner of hard-bounded command execution and its fallback watchdog |
| `fm-git-live-remote-lib.sh` | Prove a commit is contained by a branch advertised at a configured push destination |
| `fm-timing-lib.sh`       | Single owner of the deferred network stage's per-step elapsed-time records, inert unless a run asks for them |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for origin pulls and secondmate syncs             |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-backlog-transition-lib.sh` | Pair task-record changes with their backlog transitions and replay interrupted closes |
| `fm-quota-axi-lib.sh`    | Shared `quota-axi` compatibility floor and quota snapshot schema validation           |
| `fm-quota-choose.sh`     | Choose the first candidate with known positive quota from an ordered harness:model list |
| `fm-vendor-auth-probe.sh`| Run one hard-bounded, non-destructive authentication probe of a named vendor CLI and report the fact |
| `fm-wake-drain.sh`       | Present and acknowledge the current actor's claimed wake rows alongside status, outcome-backstop, decision, divergence, recovery, and supervision checks |
| `fm-wake-grant.sh`       | Serialize Pi supervision-branch wake-row claim activation, publication, release, and deactivation |
| `fm-wake-lib.sh`         | Shared durable wake queue, recovery generations, portable locks, and watcher identity/health helpers |
| `fm-classify-lib.sh`     | Shared wake classification, durable keyed-decision folds and scans, unread status selection, and bounded latest-event snapshots |
| `fm-send.sh`             | Steer a task via a durable inbox record plus doorbell, or send a supported key or typed harness invocation through the recorded backend |
| `fm-branch-prompt.sh`    | Emit the Pi supervision branch's byte-stable system prompt ([pi-supervision-branch.md](pi-supervision-branch.md)) |
| `fm-branch-outcome.sh`   | Own the supervision branch's append-only outcome store, cursors, bounded status-coverage indexes, and session-start replay |
| `fm-lease.sh`            | Claim, release, inspect, and sweep per-task supervision leases                       |
| `fm-lease-lib.sh`        | One owner of the supervision lease contract and the main-only role-partition guards  |
| `fm-control.sh`          | Agent lifecycle control plane: allowlisted `interrupt`, `exit`, and transactional `relaunch` verbs for an exact task id ([agent-control.md](agent-control.md)) |
| `fm-control-lib.sh`      | One executable owner of the control-plane verb allowlist, per-harness interrupt/exit mechanics, and per-backend capability |
| `fm-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, and per-harness sources |
| `fm-busy-event.sh`       | The only writer of a task's semantic busy-state record; arms an incarnation and applies lifecycle events |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for composer capture, verified submit, and the submit-time busy check |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-unregister.sh` | Retire a custom watcher check and its trust binding by validated task id            |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-tool-update-check.sh` | Report watched tooling with an update available, and updates installed but left inert by PATH order |
| `fm-pr-lib.sh`           | Own canonical task and PR validation plus private atomic PR-poll publication, merge-notification identity, and retirement |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated PR/MR-poll sidecars           |
| `fm-pr-check.sh`         | Prove PR-task delivery, record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `fm-pr-merge.sh`         | Record PR metadata, merge a task's canonical full GitHub or GitLab URL, then refuse an outcome it cannot prove landed or queued |
| `fm-merge-outcome-lib.sh` | Publish a confirmed merge's durable, role-routed supervision outcome                 |
| `fm-parent-channel-lib.sh` | Resolve a secondmate home's parent channel and append a captain-facing outcome line to it at most once |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task with an explicit delivery mode, and write the ship instructions carrying that mode's definition of done |
| `fm-teardown.sh`         | Fail-closed teardown: return landed ship worktrees, require completed scout deliverables, retire secondmate homes |
| `fm-harness.sh`          | Detect the running harness and resolve crew or secondmate harness, model, and effort |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared Relay config, relay, and reply-threading helpers                              |
| `fm-x-poll.sh`           | One bounded Relay poll: stash newly offered mentions and emit their once-only wake   |
| `fm-x-reply.sh`          | Post or dry-run preview a composed Relay reply or follow-up                          |
| `fm-x-dismiss.sh`        | Dismiss a skipped Relay mention at the relay without replying                        |
| `fm-x-link.sh`           | Link a spawned task to its originating Relay mention in task meta                    |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for a Relay-linked task                  |
| `fm-public-followup-lib.sh` | Shared Relay gate, open-loop registry state, expiry classification, locking, and private transport paths |
| `fm-public-followup.sh`  | Reconcile and deliver typed public commitments, then rechain or explicitly retire their retained loops |
| `fm-public-followup-emit.sh` | Report one typed terminal work result into the home that owes the public reply, or stage it when that home is on another machine |
| `fm-public-followup-collect.sh` | Read and retire the typed terminal results a remote work home staged for the home that owes the public reply |
| `fm-inbox.sh`            | The captain's out-of-band capture surface: queue a note, dictate one, read status, ask a side question |
| `fm-voice-relay.py`      | Hold the spoken conversation on this host, answer from the records, and hand real work to `fm-inbox.sh` ([voice-relay.md](voice-relay.md)) |
| `fm-voice-client.py`     | The laptop end of the spoken interface: capture, playback, and turn timing over SSH; audio devices unverified |
| `fm_voice_frame.py`      | The wire format both machines share, copied to the laptop beside the client          |
| `fm_voice_records.py`    | What a spoken answer may read, and the handover that queues real work                |
