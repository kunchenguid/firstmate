---
name: operational-home-layout
description: Load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths.
user-invocable: false
metadata:
  internal: true
---

# Operational home layout

```
AGENTS.md            this file (CLAUDE.md is a real @AGENTS.md pointer to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (section 10)
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
.claude/mods/        Claude Code mods (function-hooks plugins), committed; Calm's module may load through CLAUDE_CODE_ENABLE_FUNCTION_HOOKS or tengu_plugin_hooks_modules, but activates only when CLAUDE_CODE_ENABLE_FUNCTION_HOOKS is exactly "1" and is otherwise a complete no-op (docs/calm.md)
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
.env                 optional Relay pairing token (presence-gates section 14), mail-plane credentials (schema: docs/configuration.md "Mail plane"), and typed dispatch resolution key TYPESAFE_API_KEY (presence-gates bin/fm-dispatch-resolve.sh; docs/configuration.md "Typed dispatch resolution"); LOCAL, gitignored
config/crew-harness  crewmate harness override; LOCAL, gitignored; absent or "default" = same as firstmate. Inherited as the literal file: a concrete primary adapter value also controls a secondmate home's own crewmates (section 4)
config/claude-permission-mode  optional one-token permission posture for every Claude worker launch: absent or "bypass" keeps --dangerously-skip-permissions, "auto" launches with --permission-mode auto; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Claude permission mode"
config/claude-account config/pi-account  optional per-home worker account pin for Claude and Pi launches; LOCAL, gitignored, not inherited; absent keeps today's ambient account; present refuses a launch unless the pinned account resolves and is signed in (section 4 owns the refusal rule); see docs/configuration.md "Worker account pin"
config/crew-dispatch.json  optional crewmate dispatch profiles; LOCAL, gitignored; firstmate-maintained but human-editable natural-language rules that choose a per-task harness/model/effort profile (section 4). Inherited by secondmate homes
config/project-capacity  optional per-machine count of workers each named project admits at once, read from the root home by every local home; LOCAL, gitignored; see docs/configuration.md "Project capacity"
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by a model and effort token on the same line ("<harness> [<model>] [<effort>]"; section 4); LOCAL, gitignored; absent or "default" harness falls back to config/crew-harness then firstmate's own. The primary's own setting; NOT inherited into secondmate homes (secondmates do not spawn secondmates)
config/backlog-backend  backlog backend override; LOCAL, gitignored; absent or "tasks-axi" = the configured tasks-axi backend, "manual" = force routine backlog updates to hand-editing; inherited by secondmate homes (section 10)
config/backend  runtime session-provider backend override for new tasks; LOCAL, gitignored; absent = falls through to runtime auto-detection (the runtime firstmate itself is executing inside), then tmux; tmux is the verified reference backend (docs/tmux-backend.md), herdr has its own required CI lane (docs/herdr-backend.md), while zellij, orca, and cmux remain experimental with no dedicated real-backend CI lane (docs/zellij-backend.md, docs/orca-backend.md, docs/cmux-backend.md) - herdr and cmux can also be selected by runtime auto-detection, zellij and orca never are (always explicit), and codex-app is not accepted; see docs/codex-app-backend.md; inherited by secondmate homes under the primary-authoritative contract in secondmate-provisioning
config/calm     Calm presentation preference shared by the Pi extension and the Claude Code mod; LOCAL, gitignored, and not inherited; see docs/configuration.md "Calm preference"
config/keep-ai-trailers  optional presence flag to keep AI co-author trailers in this home's fleet commits; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Commit attribution"
config/supervision-branch-model config/supervision-branch-effort  Pi supervision-branch model and reasoning-effort pins written by /supervision-model; LOCAL, gitignored, independently settable, and not inherited; see docs/configuration.md "Pi supervision branch model and effort"
config/supervision-host  optional supervision-host engine setting: the host runs the supervision branch's contract on a headless engine beside a non-Pi primary, away and, on a Claude or Cursor primary, attended; absent runs it on a Claude primary and nowhere else; LOCAL, gitignored, not inherited; see docs/configuration.md "Supervision host"
config/supervision-host-off  optional presence flag opting this home out of the supervision host on every primary; LOCAL, gitignored; inherited by secondmate homes under the primary-authoritative contract; see docs/configuration.md "Supervision host"
config/startup-memory-budget     primary-authoritative per-home startup-memory budget; LOCAL, gitignored, materialized as 7,500 estimated tokens by locked primary bootstrap and inherited into secondmate homes; see docs/configuration.md "Startup memory budget"
config/stow-pass-horizon  optional presence flag opting this home in to /stow's default-off pass-count decay horizon; LOCAL, gitignored, and not inherited; see docs/configuration.md "Stow pass horizon"
config/herdr-presentation-spaces  optional "off" opt-out from, or "on" opt-in to, Herdr's default-on disposable single-task visual projection, which is unconfigured-default-on only at or above a Herdr version floor; LOCAL, gitignored; inherited by secondmate homes; see docs/herdr-backend.md "Presentation spaces"
config/trace-context  optional presence flag enabling default-off native W3C trace-context propagation to spawned agents; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Trace context propagation" and docs/trace-context.md
config/lavish-axi-host  optional one-line per-machine Lavish server address; LOCAL, gitignored, inherited by secondmate homes, and exported into every worker launch; see docs/configuration.md "Lavish server address" for opening versus polling
config/brief-include.md  optional standing worker instructions appended verbatim as the last section of every ship and scout scaffold; LOCAL, gitignored, and not inherited; keep its text out of `## Firstmate spec`; see docs/configuration.md "Home brief include"
config/fleet-ledger  optional presence flag opting this home in to the default-off fleet activity ledger state/fleet-ledger.jsonl that outside tools can follow; LOCAL, gitignored, and not inherited; see docs/fleet-ledger.md
config/wait-no-turns  optional presence flag opting this home into default-off waiting-worker behavior (brief waiting section, foreground pipeline drive, pending-reply hold, one fire-and-forget retry ring); LOCAL, gitignored, and not inherited; see docs/configuration.md "Waiting worker spends no turns"
config/pipeline-spend  optional presence flag opting this home in to default-off per-task no-mistakes spend recording in data/pipeline-spend.jsonl; LOCAL, gitignored, and not inherited; see docs/configuration.md "No-mistakes pipeline spend"
config/turnend-churn-absorb  optional presence flag opting this home into the default-off absorb of bare turn-end wakes on pane churn; LOCAL, gitignored, and not inherited; see docs/configuration.md "Turn-end pane-churn absorb"
config/wedge-defer-parked-gate  optional presence flag opting this home into the default-off deferral of a wedge escalation for a lane parked at a validation gate awaiting the supervisor's own still-open decision; LOCAL, gitignored, and not inherited; see docs/configuration.md "Parked-gate wait deferral"
config/cmux-socket-password  optional cmux control-socket password; LOCAL, gitignored; read fresh on every cmux CLI call and passed through without ever overriding an operator's own ambient CMUX_SOCKET_PASSWORD when absent (docs/cmux-backend.md "Setup")
config/wedge-alarm  optional away-mode wedge-alarm active-alert directives; LOCAL, gitignored; absent means auto (macOS Notification Center when available); see docs/wedge-alarm.md
config/watched-tools.json  optional list of the tools this home depends on, read by the update check armed with bin/fm-tool-update-check.sh; LOCAL, gitignored, firstmate-maintained but human-editable, and NOT inherited by secondmate homes; see docs/configuration.md "Watched tool updates"
config/x-mode.env    generated Relay watcher cadence; LOCAL, gitignored; source before arming watcher when present
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture and optional ship-branch prefix; firstmate-private, parsed by fm-project-mode.sh (section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (section 6)
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
  pipeline-spend.jsonl  optional per-task no-mistakes pipeline spend, written only when config/pipeline-spend is present; bin/fm-pipeline-spend.sh owns the schema
projects/            cloned repos; gitignored; read-only except under hard rule 1's concrete captain-approved project operation exception
state/               runtime records and signals; gitignored
  <id>.status        append-only wake events, not current-state truth; bin/fm-classify-lib.sh owns their syntax
  <id>.turn-ended    touched by turn-end hooks
  <id>.progress      touched for observed native-harness activity inside one Pi turn; bin/fm-busy-event.sh owns its generation binding and bin/fm-watch.sh reads it beside turn-ended for the busy-age bound only, never as a completed turn
  <id>.busy-state <id>.busy-gen   semantic busy-state record (one line, atomically replaced) and its per-incarnation gen sidecar; bin/fm-busy-event.sh is the only writer and bin/fm-busy-lib.sh owns the record format and classification; arming again replaces the previous incarnation so late events carrying its gen are rejected as stale; removed by retire and teardown
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.kimi-turnend-token   firstmate-owned Kimi hook registry token for the task; removed by teardown
  <id>.gemini-settings.json  firstmate-owned per-task Gemini settings carrying the busy-state and turn-end hooks, reached through GEMINI_CLI_SYSTEM_SETTINGS_PATH so nothing is written into the project's own .gemini/; removed by teardown
  <id>.claude-settings.json  firstmate-owned per-task Claude settings for a secondmate (busy-state hooks plus the session keys), passed through --settings so the mate home's own .claude/settings.local.json is never edited; written by fm-spawn; removed by relaunch retirement and teardown
  <id>.devin-config.json  firstmate-owned per-task Devin config (mode 600 snapshot of the user config plus the busy-state and turn-end hooks) passed through --config so no user or project config is edited; bin/fm-devin-config.sh owns it; removed by teardown
  <id>.muse-session  muse busy-source binding (sessions root plus task worktree) written by fm-spawn; removed by teardown
  <id>.cursor-session  cursor busy-source binding (projects root, task worktree, prior conversations) written by fm-spawn; removed by teardown
  <id>.git-hooks/    per-task git hooksPath that strips AI commit trailers at the commit object unless config/keep-ai-trailers is present; written by fm-spawn, removed by teardown (bin/fm-git-strip-ai-trailers.sh)
  <id>.reconcile-nudged  epoch second of the last inventory-reconcile nudge sent to this secondmate; bin/fm-secondmate-reconcile.sh owns its per-home cooldown window
  <id>.backlog-close  the exact backlog transition a teardown recorded before removing the task's record, so an interrupted cleanup can still be finished at the next session start; bin/fm-backlog-transition-lib.sh owns its format and replay, and a landed transition removes it
  <id>.inbox/          durable steering inbox: sequenced firstmate instruction records the worker acknowledges by moving them into its handled/ subdirectory; written by fm-send, with ordinary records re-rung and escalated by the watcher while explicit fire-and-forget records are excluded from that ladder, and removed by teardown (bin/fm-task-inbox-lib.sh)
  <id>.meta          task metadata; each producer script's header owns its exact fields and mutation contract, with docs/configuration.md routing operator-facing backend and trace-context details
  <id>.herdr-presentation  quarantinable attempt and restart-binding journal for Herdr's optional visual projection; never task or endpoint authority; see docs/herdr-backend.md "Presentation spaces"
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified Relay shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  <id>.check-trust   private content binding created by fm-check-register.sh for an intentional custom check
  <id>.pr-poll       private validated data sidecar for the byte-static PR merge poll
  <id>.pr-poll-registration  private transactional provenance record binding the task, canonical metadata identity, sidecar, and static poll publication
  <id>.pr-poll-retirement  private identity-bound crash-recovery receipt for one exact validated merged result; removed after its poll artifacts retire
  <id>.merge-authority  private canonical-PR-bound authority persisted after firstmate's forge merge request is accepted and consumed by a later merged poll; bin/fm-merge-authority-lib.sh owns its format and lifecycle
  <id>.pr-poll-merge-notified  canonical PR identity of the last merge outcome delivered for this task; bin/fm-pr-lib.sh owns the marker format and identity mechanics, while bin/fm-merge-outcome-lib.sh owns locked publication, duplicate suppression, and replacement
  branch-outcomes.jsonl .branch-outcomes-cursor .branch-outcomes-processed .<task>.branch-outcome-index .branch-outcome-index-ready .branch-outcomes-tail.jsonl  Pi supervision-branch durable outcome store, its read cursor, main's processed marker, bounded latest per-task status-coverage caches, their recovery marker, and a bounded display copy of the newest rows; bin/fm-branch-outcome.sh owns the formats
  branch-session/ .branch-session .branch-mirror-cursor  the branch's per-main-session conversations, the pointer to the current one, and the dialog-mirror cursor; extension-owned (docs/pi-supervision-branch.md)
  .branch-eligible-rows .branch-eligible-owner .main-eligible-rows  per-actor wake-row claims and branch-owner evidence; docs/watcher-continuity.md owns the acknowledgement contract
  .supervision-host*  supervision host process record, engine conversation, current turn scope and report receipts, and bounded ledger of every close and engine turn; bin/fm-supervision-host.sh owns them; never touch
  .lease-<task>        per-task supervision lease naming which actor (main or branch) may change that task; bin/fm-lease-lib.sh owns the contract the guarded scripts enforce
  x-watch.check.sh   generated Relay poll shim; present only when opted in (section 14)
  tool-updates.check.sh  generated watched-tool update poll shim and its .check-trust binding; present only after bin/fm-tool-update-check.sh arm; its report record .tool-updates is what keeps one pending update from being reported on every poll
  mail.check.sh      generated received-mail poll shim and its .check-trust binding; present only after bin/fm-mail-check.sh arm; report record .mail-check (mail schema: docs/configuration.md "Mail plane")
  .mail-seen .mail-woken .mail-retry .mail-retry-pos .mail-turn .mail-seen.lock  mail-plane poll cursor, emission journal, transient-fetch retry set, retry-scan position, contended-slot turn flag, and overlapping-poll lock; written only by bin/fm-mail.sh (mail schema: docs/configuration.md "Mail plane")
  startup-growth.check.sh  generated daily startup-growth poll shim and its .check-trust binding; present only after bin/fm-startup-growth-check.sh arm; its record .startup-growth-check holds the daily gate, the per-file growth baselines, and the last reported finding set, so removing it re-baselines growth silently and repeats a standing finding such as a budget overrun once (docs/configuration.md "Daily startup growth check")
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  procevent/         registered process-to-event sources, one private record per canonical source id; written only by bin/fm-procevent.sh, and their presence alone keeps supervision required (`process-event-sources` skill)
  procevent-inbox/   private captured results and their durable handled-acknowledgement markers; source output lives here and never in an event line
  decision-bindings/ private records marking a captured-answer source as feeding the keyed-answer intake, with a legacy origin on pre-collapse records; written only by bin/fm-captain-hold.sh bind, dropped by unbind and by source retirement (`process-event-sources` and `captain-hold-lifecycle` skills; docs/captain-hold-lifecycle.md)
  reconcile-requests/ private open obligations to re-check a captain call whose board selection was `reconcile`; written only by bin/fm-captain-hold.sh, retired by its verify-then-decide outcomes or a normal answer that settles the call (`process-event-sources` and `captain-hold-lifecycle` skills; docs/captain-hold-lifecycle.md)
  when/              private condition->action watch specs, their trust bindings, and single-fire markers; written only by bin/fm-procevent-when.sh (`process-event-sources` skill)
  inbox/             captain notes captured out of band by bin/fm-inbox.sh, including the voice handover's queued requests; each note appends one `check` wake and stays pending until acknowledged with `bin/fm-inbox.sh drain --ack <id>`, which moves it to inbox/handled/; request-id reservations, announcement markers, and primary replies live beside the notes (bin/fm-inbox.sh; docs/voice-relay.md)
  x-inbox/           generated Relay pending mention payloads; fmx-respond drains it (section 14)
  x-context/         generated Relay durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (section 14; bin/fm-x-lib.sh)
  x-outbox/          generated Relay dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (section 14)
  public-followup/   generated private transport for promised public replies: retained open-loop registrations, typed terminal-result inbox, results staged for an owning home on another machine, accepted/rejected ledgers, and retirement receipts (section 14; bin/fm-public-followup.sh)
  x-poll.error x-poll.claim-error  generated Relay and offer-claim diagnostic dedupe markers
  .startup-network.*  status, report, per-step elapsed timings, inline-print claim, and lock for the deferred startup stage that runs network checks and the inactive-outcome scan off the digest's blocking path; bin/fm-startup-network.sh
  .wake-queue        durable queued wakes retained until post-handling acknowledgement: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .watcher-down      private generation-bound recovery state coupling watcher downtime, durable wake presentation, and post-handling acknowledgement; never touch
  .<id>.open-decisions-cursor  per-task byte cursor and folded open-decision set bounding the OPEN DECISIONS scan's cost to new status-log appends; written only by fm-classify-lib.sh's status_open_decisions_incremental, removed by teardown, safe to delete (forces one full re-fold)
  .<id>.home-appends  per-task ledger of byte ranges this home itself appended as bookkeeping closes, so a wake scan can tell its own growth from a foreign write instead of waking on it; presentation is unaffected, so both the signal annotation and UNREAD STATUS still print those lines; written only by fm-classify-lib.sh's status_home_appends_record; its sibling .<id>.home-appends.lock serializes that ledger's read-merge-write; both removed by teardown, safe to delete
  .status-presentation-cursor .status-presentation-lock  fleet-wide per-task status identity plus independent annotation and outcome-backstop byte offsets, with a serialization lock preventing already-presented lines from replaying while preserving delayed signal annotations; owned by fm-classify-lib.sh, with each task's row retired by teardown
  .afk-contract      the away or quiet posture record; bin/fm-afk-contract.sh owns its mode, schema, entry, archive, and lock contract; its sibling .afk-contract.lock serializes actions authorized by the live record
  afk-contracts/     archived away and quiet records; bin/fm-afk-contract.sh owns their archive contract
  .afk               durable away/quiet-mode daemon flag on the harnesses that still launch the daemon (never on Pi); present = sub-supervisor may inject escalations, first line `away` (default, set by /afk, cleared on user return) or `quiet` (set by /quiet, cleared only on explicit /quiet off) per the single owner fm_afk_mode() in bin/fm-wake-lib.sh
  .lock-session      trusted Claude session-lock sidecar; written only by bin/fm-lock.sh; never touch
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .claude-autoarm.lock .claude-autoarm-epoch .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .turnend-claude-blocks .turnend-claude-blocks.lock   Claude Stop auto-arm single-flight, epoch, failure-episode, attended-alarm, guard-budget, and budget-lock records; never touch
  .cursor-park-owner .cursor-park-owner.lock .turnend-cursor-blocks   Cursor stop-hook owner record, publication and commit lock, and bounded repair-nag budget; never touch
  .hash-* .count-* .stale-* .stale-since-* .churn-since-* .paused-* .wedge-escalations-* .dead-reported-* .writing-* .waiting-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak .secondmate-liveness-tick .secondmate-liveness-*.lock*   watcher internals; never touch
  .secondmate-relaunch-<id> .secondmate-relaunch-bound-<id>   durable relaunch history and parked-bound state; never touch (bin/fm-secondmate-liveness-lib.sh owns the ledger contract)
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts read it
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
.no-mistakes/        local validation state and evidence; gitignored
```
