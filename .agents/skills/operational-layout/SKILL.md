---
name: operational-layout
description: >-
  Load before locating, inspecting, or changing private operational files or configuration fields whose ownership is unclear.
user-invocable: false
metadata:
  internal: true
---

# Operational layout reference

`docs/configuration.md` owns layout and schemas; producing script headers and help own mutation mechanics.
This inventory is reference material, not permission to edit producer-owned records.
Paths below are relative to the tracked code root or effective `FM_HOME`, as specified in AGENTS.md section 2.
In the inventory below, `this file`, `section 4`, `section 6`, `section 10`, `section 13`, `section 14`, and `hard rule 1` all refer to `AGENTS.md`.

```
AGENTS.md            this file (CLAUDE.md is a real @AGENTS.md pointer to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (section 10)
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
.env                 optional Relay pairing token (presence-gates section 14) and mail-plane credentials (schema: docs/configuration.md "Mail plane"); LOCAL, gitignored
config/crew-harness  crewmate harness override; LOCAL, gitignored; absent or "default" = same as firstmate. Inherited as the literal file: a concrete primary adapter value also controls a secondmate home's own crewmates (section 4)
config/claude-permission-mode  optional one-token permission posture for every Claude worker launch: absent or "bypass" keeps --dangerously-skip-permissions, "auto" launches with --permission-mode auto; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Claude permission mode"
config/crew-dispatch.json  optional crewmate dispatch profiles; LOCAL, gitignored; firstmate-maintained but human-editable natural-language rules that choose a per-task harness/model/effort profile (section 4). Inherited by secondmate homes
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by a model and effort token on the same line ("<harness> [<model>] [<effort>]"; section 4); LOCAL, gitignored; absent or "default" harness falls back to config/crew-harness then firstmate's own. The primary's own setting; NOT inherited into secondmate homes (secondmates do not spawn secondmates)
config/backlog-backend  backlog backend override; LOCAL, gitignored; absent or "tasks-axi" = the configured tasks-axi backend, "manual" = force routine backlog updates to hand-editing; inherited by secondmate homes (section 10)
config/backend  runtime session-provider backend override for new tasks; LOCAL, gitignored; absent = falls through to runtime auto-detection (the runtime firstmate itself is executing inside), then tmux; tmux is the verified reference backend (docs/tmux-backend.md), herdr has its own required CI lane (docs/herdr-backend.md), while zellij, orca, and cmux remain experimental with no dedicated real-backend CI lane (docs/zellij-backend.md, docs/orca-backend.md, docs/cmux-backend.md) - herdr and cmux can also be selected by runtime auto-detection, zellij and orca never are (always explicit), and codex-app is not accepted; see docs/codex-app-backend.md; inherited by secondmate homes under the primary-authoritative contract in secondmate-provisioning
config/calm     Pi Calm presentation preference; LOCAL, gitignored, and not inherited; see docs/configuration.md "Pi Calm preference"
config/supervision-branch-model config/supervision-branch-effort  Pi supervision-branch model and reasoning-effort pins written by /supervision-model; LOCAL, gitignored, independently settable, and not inherited; see docs/configuration.md "Pi supervision branch model and effort"
config/startup-memory-budget     primary-authoritative per-home startup-memory budget; LOCAL, gitignored, materialized as 7,500 estimated tokens by locked primary bootstrap and inherited into secondmate homes; see docs/configuration.md "Startup memory budget"
config/stow-pass-horizon  optional presence flag opting this home in to /stow's default-off pass-count decay horizon; LOCAL, gitignored, and not inherited; see docs/configuration.md "Stow pass horizon"
config/herdr-presentation-spaces  optional "off" opt-out from, or "on" opt-in to, Herdr's default-on disposable single-task visual projection, which is unconfigured-default-on only at or above a Herdr version floor; LOCAL, gitignored; inherited by secondmate homes; see docs/herdr-backend.md "Presentation spaces"
config/trace-context  optional presence flag enabling default-off native W3C trace-context propagation to spawned agents; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Trace context propagation" and docs/trace-context.md
config/turnend-churn-absorb  optional presence flag opting this home into the default-off absorb of bare turn-end wakes on pane churn; LOCAL, gitignored, and not inherited; see docs/configuration.md "Turn-end pane-churn absorb"
config/cmux-socket-password  optional cmux control-socket password; LOCAL, gitignored; read fresh on every cmux CLI call and passed through without ever overriding an operator's own ambient CMUX_SOCKET_PASSWORD when absent (docs/cmux-backend.md "Setup")
config/wedge-alarm  optional away-mode wedge-alarm active-alert directives; LOCAL, gitignored; absent means auto (macOS Notification Center when available); see docs/wedge-alarm.md
config/watched-tools.json  optional list of the tools this home depends on, read by the update check armed with bin/fm-tool-update-check.sh; LOCAL, gitignored, firstmate-maintained but human-editable, and NOT inherited by secondmate homes; see docs/configuration.md "Watched tool updates"
config/x-mode.env    generated Relay watcher cadence; LOCAL, gitignored; source before arming watcher when present
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture; firstmate-private, parsed for mechanical sync and seeding by fm-project-mode.sh (section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (section 6)
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
projects/            cloned repos; gitignored; read-only except under hard rule 1's concrete captain-approved project operation exception
state/               runtime records and signals; gitignored
  <id>.status        appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended    touched by turn-end hooks
  <id>.progress      touched for observed native-harness activity inside one Pi turn; bin/fm-busy-event.sh owns its generation binding and bin/fm-watch.sh reads it beside turn-ended for the busy-age bound only, never as a completed turn
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.kimi-turnend-token   firstmate-owned Kimi hook registry token for the task; removed by teardown
  <id>.gemini-settings.json  firstmate-owned per-task Gemini settings carrying the busy-state and turn-end hooks, reached through GEMINI_CLI_SYSTEM_SETTINGS_PATH so nothing is written into the project's own .gemini/; removed by teardown
  <id>.muse-session  muse busy-source binding (sessions root plus task worktree) written by fm-spawn; removed by teardown
  <id>.cursor-session  cursor busy-source binding (projects root, task worktree, prior conversations) written by fm-spawn; removed by teardown
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
  branch-outcomes.jsonl .branch-outcomes-cursor .branch-outcomes-processed .<task>.branch-outcome-index .branch-outcome-index-ready  Pi supervision-branch durable outcome store, its read cursor, main's processed marker, bounded latest per-task status-coverage caches, and their recovery marker; bin/fm-branch-outcome.sh owns the formats
  branch-session/ .branch-session .branch-mirror-cursor  the branch's per-main-session conversations, the pointer to the current one, and the dialog-mirror cursor; extension-owned (docs/pi-supervision-branch.md)
  .branch-eligible-rows .branch-eligible-owner .main-eligible-rows  per-actor wake-row claims and branch-owner evidence; docs/watcher-continuity.md owns the acknowledgement contract
  .lease-<task>        per-task supervision lease naming which actor (main or branch) may change that task; bin/fm-lease-lib.sh owns the contract the guarded scripts enforce
  x-watch.check.sh   generated Relay poll shim; present only when opted in (section 14)
  tool-updates.check.sh  generated watched-tool update poll shim and its .check-trust binding; present only after bin/fm-tool-update-check.sh arm; its report record .tool-updates is what keeps one pending update from being reported on every poll
  mail.check.sh      generated received-mail poll shim and its .check-trust binding; present only after bin/fm-mail-check.sh arm; report record .mail-check (mail schema: docs/configuration.md "Mail plane")
  .mail-seen .mail-woken .mail-retry .mail-retry-pos .mail-turn .mail-seen.lock  mail-plane poll cursor, emission journal, transient-fetch retry set, retry-scan position, contended-slot turn flag, and overlapping-poll lock; written only by bin/fm-mail.sh (mail schema: docs/configuration.md "Mail plane")
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  procevent/         registered process-to-event sources, one private record per canonical source id; written only by bin/fm-procevent.sh, and their presence alone keeps supervision required (section 13)
  procevent-inbox/   private captured results and their durable handled-acknowledgement markers; source output lives here and never in an event line
  decision-bindings/ private records marking a captured-answer source as feeding the keyed-answer intake, with a legacy origin on pre-collapse records; written only by bin/fm-captain-hold.sh bind, dropped by unbind and by source retirement (section 13; docs/captain-hold-lifecycle.md)
  reconcile-requests/ private open obligations to re-check a captain call whose board selection was `reconcile`; written only by bin/fm-captain-hold.sh, retired by its verify-then-decide outcomes or a normal answer that settles the call (section 13; docs/captain-hold-lifecycle.md)
  when/              private condition->action watch specs, their trust bindings, and single-fire markers; written only by bin/fm-procevent-when.sh (section 13's process-event-sources trigger)
  inbox/             captain notes captured out of band by bin/fm-inbox.sh, including the voice handover's queued requests; each note appends one `check` wake and stays pending until acknowledged with `bin/fm-inbox.sh drain --ack <id>`, which moves it to inbox/handled/ (docs/voice-relay.md)
  x-inbox/           generated Relay pending mention payloads; fmx-respond drains it (section 14)
  x-context/         generated Relay durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (section 14; bin/fm-x-lib.sh)
  x-outbox/          generated Relay dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (section 14)
  public-followup/   generated private transport for promised public replies: retained open-loop registrations, typed terminal-result inbox, results staged for an owning home on another machine, accepted/rejected ledgers, and retirement receipts (section 14; bin/fm-public-followup.sh)
  x-poll.error x-poll.claim-error  generated Relay and offer-claim diagnostic dedupe markers
  .startup-network.*  status, report, per-step elapsed timings, inline-print claim, and lock for the deferred startup stage that runs network checks and the inactive-outcome scan off the digest's blocking path; bin/fm-startup-network.sh
  .wake-queue        durable queued wakes retained until post-handling acknowledgement: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .<id>.open-decisions-cursor  per-task byte cursor and folded open-decision set bounding the OPEN DECISIONS scan's cost to new status-log appends; written only by fm-classify-lib.sh's status_open_decisions_incremental, removed by teardown, safe to delete (forces one full re-fold)
  .status-presentation-cursor .status-presentation-lock  fleet-wide per-task status identity plus independent annotation and outcome-backstop byte offsets, with a serialization lock preventing already-presented lines from replaying while preserving delayed signal annotations; owned by fm-classify-lib.sh, with each task's row retired by teardown
  .afk-contract      the away-posture record: the captain's verbatim away words, expected return, reach profile, spend cap, and structured mandate clauses; written only by bin/fm-afk-contract.sh after the captain confirms the read-back, archived under afk-contracts/ at return; its presence IS the away posture in every harness
  afk-contracts/     archived away-posture records: one final record per away window keyed by entry time, plus any superseded mandates from that window
  .afk               durable away-mode daemon flag on the harnesses that still launch the daemon (never on Pi); present = sub-supervisor may inject escalations (set by the daemon entry, cleared on user return)
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts read it
.no-mistakes/        local validation state and evidence; gitignored
```
