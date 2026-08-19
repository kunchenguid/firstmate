# `state/` directory layout

Full field-by-field inventory of `state/`, the runtime records and signals directory. Referenced from `AGENTS.md` section 2.

`state/` holds runtime records and append-only status events; every path below is gitignored.

```
state/               runtime records and signals; gitignored
  <id>.status        appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended    touched by turn-end hooks
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.kimi-turnend-token   firstmate-owned Kimi hook registry token for the task; removed by teardown
  <id>.muse-session  muse busy-source binding (sessions root plus task worktree) written by fm-spawn; removed by teardown
  <id>.cursor-session  cursor busy-source binding (projects root, task worktree, prior conversations) written by fm-spawn; removed by teardown
  <id>.meta          task metadata; each producer script's header owns its exact fields and mutation contract, with docs/configuration.md routing operator-facing backend and trace-context details
  <id>.herdr-presentation  quarantinable attempt and restart-binding journal for Herdr's optional visual projection; never task or endpoint authority; see docs/herdr-backend.md "Presentation spaces"
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified Relay shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  <id>.check-trust   private content binding created by fm-check-register.sh for an intentional custom check
  <id>.pr-poll       private validated data sidecar for the byte-static PR merge poll
  <id>.pr-poll-registration  private transactional provenance record binding the task, canonical metadata identity, sidecar, and static poll publication
  <id>.pr-poll-retirement  private identity-bound crash-recovery receipt for one exact validated merged result; removed after its poll artifacts retire
  .pr-check-quarantine/  private non-runnable storage for checks neutralized by the non-executing migration
  .pr-check-migration.log  private per-task outcomes distinguishing rebuilt or canonically registered replacement polls, quarantined unarmed polls, and incomplete migrations
  .pr-check-migration-scan-v1  private marker proving the non-executing scan disabled every unsafe legacy check; .pr-check-migration-v1 separately records completed private repairs
  x-watch.check.sh   generated Relay poll shim; present only when opted in (section 14)
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  procevent/         registered process-to-event sources, one private record per canonical source id; written only by bin/fm-procevent.sh, and their presence alone keeps supervision required (section 13)
  procevent-inbox/   private captured results and their durable handled-acknowledgement markers; source output lives here and never in an event line
  decision-bindings/ private bindings from a captured-answer source id to the captain-hold origin its keyed answers close; written only by bin/fm-decision-hold.sh bind, dropped by unbind and by source retirement (section 13; docs/decision-hold-lifecycle.md)
  when/              private condition->action watch specs, their trust bindings, and single-fire markers; written only by bin/fm-procevent-when.sh (section 13's process-event-sources trigger)
  x-inbox/           generated Relay pending mention payloads; fmx-respond drains it (section 14)
  x-context/         generated Relay durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (section 14; bin/fm-x-lib.sh)
  x-outbox/          generated Relay dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (section 14)
  public-followup/   generated private transport for promised public replies: commitment registrations, typed terminal-result inbox, accepted/rejected ledgers (section 14; bin/fm-public-followup.sh)
  x-poll.error x-poll.claim-error  generated Relay and offer-claim diagnostic dedupe markers
  .startup-network.*  status, report, per-step elapsed timings, inline-print claim, and lock for the deferred network stage session start runs off its blocking path; bin/fm-startup-network.sh
  .wake-queue        durable queued wakes retained until post-handling acknowledgement: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .watcher-down      private generation-bound recovery state coupling watcher downtime, durable wake presentation, and post-handling acknowledgement; never touch
  .<id>.open-decisions-cursor  per-task byte cursor and folded open-decision set bounding the OPEN DECISIONS scan's cost to new status-log appends; written only by fm-classify-lib.sh's status_open_decisions_incremental, removed by teardown, safe to delete (forces one full re-fold)
  .status-presentation-cursor .status-presentation-lock  fleet-wide per-task status identity/byte-offset manifest and serialization lock preventing already-presented status lines from being replayed as new; owned by fm-classify-lib.sh, with each task's row retired by teardown
  .afk               durable away-mode flag; present = sub-supervisor may inject escalations (set by /afk, cleared on user return)
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .claude-autoarm.lock .claude-autoarm-epoch .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .turnend-claude-blocks .turnend-claude-blocks.lock   Claude Stop auto-arm single-flight, epoch, failure-episode, attended-alarm, guard-budget, and budget-lock records; never touch
  .cursor-park-owner .cursor-park-owner.lock .turnend-cursor-blocks   Cursor stop-hook owner record, publication and commit lock, and bounded repair-nag budget; never touch
  .hash-* .count-* .stale-* .stale-since-* .paused-* .wedge-escalations-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak   watcher internals; never touch
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts read it
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
```

A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconciliation.
