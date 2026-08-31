# Configuration

This document owns the current local configuration surface, private-state formats, and supported toolchain requirements.

`AGENTS.md` owns the always-loaded operating contract, and script headers own exact commands and flags.

## Operational home layout and state

`FM_HOME` selects the private `data/`, `state/`, `config/`, and `projects/` directories for one Firstmate home.

Scripts remain in the tracked repository root.

When `FM_HOME` is unset, the repository root is the home for local use.

`FM_HOME` is explicit for `bin/fm-send.sh`, so a steer cannot resolve against another home.

Tracked files hold shared instructions and tooling.

`data/` holds durable private fleet records, `state/` holds runtime records and wake signals, `config/` holds local operating choices, and `projects/` holds local project clones.

## Runtime backend

tmux is the only supported runtime backend.

`config/backend` and `FM_BACKEND` are ignored by the lean product contract.

Every local crewmate and local secondmate runs through the tmux adapter.

See [tmux-backend.md](tmux-backend.md) for setup and runtime behavior.

## Local secondmates

`data/secondmates.md` records local secondmate homes only.

Each secondmate has an isolated `FM_HOME`, its own `data/`, `state/`, `config/`, `projects/`, and session lock, and a local tmux endpoint.

The primary owns routing and provisioning, while a secondmate acts only on work explicitly handed to its home.

Secondmate registry syntax and mutation mechanics are owned by `bin/fm-home-seed.sh` and the `secondmate-provisioning` skill.

Local inherited material is limited to the configuration declared by `bin/fm-config-inherit-lib.sh`.

## Backlog and captain records

`data/backlog.md` is the durable task queue.

`.tasks.toml` configures the default `tasks-axi` backend for routine backlog updates.

`config/backlog-backend` may contain `manual` to opt out of routine `tasks-axi` mutations.

`data/captain.md` owns local captain preferences, `data/captain-shared.md` owns primary-propagated preferences for local secondmate homes, and `data/learnings.md` holds curated local operational facts.

These files are gitignored and must be updated through their owning workflow.

## State records

`state/<id>.meta` contains task metadata.

Each producer script header owns its exact fields and mutation contract.

`state/<id>.status` is an append-only wake-event log, not current-state truth.

Use `bin/fm-crew-state.sh <id>` when current state matters.

`state/<id>.check.sh` is a registered slow watcher check, and `state/<id>.check-trust` binds its approved bytes.

`state/<id>.pr-poll` and its registration files hold validated pull-request poll data.

`state/<id>.turn-ended` and harness-specific token files record turn-end guard state.

`state/.afk` marks away mode.

`state/.last-watcher-beat` is the watcher liveness beacon.

## Wake queue and decisions

`state/.wake-queue` stores durable wake records as `epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload`.

The watcher appends records, and `bin/fm-wake-drain.sh` presents and acknowledges them through the exact generation-bound command it prints.

Wakes remain durable until acknowledged after handling.

`signal:` wakes identify appended status events, `stale:` wakes require endpoint reconciliation, `check:` wakes identify registered check results, and `heartbeat:` wakes request fleet review.

`state/decision-bindings/` binds captured captain answers to durable decision holds.

`bin/fm-decision-hold.sh` owns decision creation, completion, and closure.

## Process-to-event sources

`state/procevent/` contains one registered source record per canonical source id.

`state/procevent-inbox/` contains captured source results and their durable handled acknowledgements.

`bin/fm-procevent.sh` owns source registration, capture, result retention, and retirement.

`bin/fm-procevent-when.sh` owns deterministic condition-to-action watches under `state/when/`.

The `process-event-sources` skill owns the handling boundary and source-specific wake routing.

## Watcher supervision

`bin/fm-watch.sh` is the singleton local watcher.

It absorbs benign changes and exits after queuing actionable wakes.

`bin/fm-watch-arm.sh` owns watcher arming, while the session-start supervision block owns the primary harness wait loop.

Away mode is presence-gated by `state/.afk` and is owned by the `/afk` skill.

## Toolchain

The universal local toolchain is Git, the GitHub CLI with the required authentication for the requested action, tmux, the selected supported harness, compatible `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, and `quota-axi`.

`treehouse` provides isolated worktrees for tmux task spawns.

Bootstrap detects missing tools and asks for approval before installation.

Validation output can support a recommendation, but never grants authority for a sensitive action.

## Environment variables

```sh
FM_HOME=                         # local Firstmate home
FM_STATE_OVERRIDE=               # alternate state directory, primarily for tests
FM_DATA_OVERRIDE=                # alternate data directory, primarily for tests
FM_PROJECTS_OVERRIDE=            # alternate projects directory, primarily for tests
FM_CONFIG_OVERRIDE=              # alternate config directory, primarily for tests
FM_TRACE_CONTEXT=                # trace-context override; see trace-context.md
FM_SESSION_START_STATUS_TAIL=5   # status lines per task in the session-start digest
FM_SESSION_START_QUEUED_LIMIT=20 # queued backlog rows in the digest
FM_CHECK_INTERVAL=300            # seconds between registered slow checks
FM_CHECK_TIMEOUT=30              # seconds allowed per slow check
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576 # maximum captured source-result bytes
FM_LOCK_STALE_AFTER=2            # dead-process lock reclamation threshold
FM_GUARD_GRACE=300               # watcher-beacon grace period
FM_SEND_RETRIES=3                # send Enter retry attempts
FM_SEND_SLEEP=0.4                # seconds between send submit checks
FM_SEND_SETTLE=1                 # post-submit settle delay
FM_INACTIVE_RECONCILE_SECS=900   # inactive fleet reconciliation cadence
FM_WEDGE_ALARM_CHANNEL=          # away-mode alert channel; see wedge-alarm.md
```

The exact accepted values, defaults, and validation rules remain in the relevant script headers.
