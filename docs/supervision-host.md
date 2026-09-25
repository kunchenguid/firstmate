# Supervision host

The supervision host runs the supervision branch's contract beside a primary that is not Pi.
This doc explains how it does that and which script owns each part, for maintainers changing the host, its engine, or a primary's arm owner.

On Pi the branch is a second conversation inside the captain's own process ([pi-supervision-branch.md](pi-supervision-branch.md)).
Off Pi no such process exists.
So the host owns the watcher cycle for the primary and runs the branch as a headless engine session.

It is one architecture with Pi's, not a second one.
These parts are shared with Pi and decide what the branch may do:

- The same branch prompt.
- The same row eligibility.
- The same records.
- The same guarded scripts.

A close is the output a watcher cycle prints when it ends.
An arm owner is the component in each primary harness that starts watcher cycles and reads their close.

## Scope today

The host is opt-in per home through `config/supervision-host`; [configuration.md](configuration.md#supervision-host-configsupervision-host) owns the file.
Without the file every home behaves exactly as it does without the host.
Today it runs beside a Claude, Cursor, OpenCode, omp, Grok, or Codex primary and only takes wakes in the away posture.

### Behavior by posture and harness

- Attended (no away-posture record `state/.afk-contract`), the host is a pass-through.
  Every close reaches main exactly as the plain watcher arm delivers it.
- Away (the record exists), the host hands each close to the engine.
  Main stays parked unless the host hands the wake back.
- `/afk` launches no away daemon on an opted-in home of those harnesses, because the host is the away session there.
- `/quiet` still launches the daemon.
  While its flag `state/.afk` exists, the host stands aside exactly as the plain arm does.
- Pi keeps its in-process branch whether or not the file exists, and no Pi engine is built.
- Kimi has no primary supervision protocol, so it has no arm owner to run the host.

### Not yet on the host

Attended supervision on the host, `/quiet` on the host, and the daemon's retirement are later steps of the same design.
Until they land, their current behavior stays as described in their own owners.

## Components and their owners

| Component | Owner | Role |
|---|---|---|
| The loop | `bin/fm-supervision-host.sh` | Its header owns the per-close order, the park boundary, ownership checks, predecessor cleanup, state files, and tunables. |
| The arm owners | Each primary's existing arm owner | Runs the host for an opted-in home and delivers a handed-back wake to main; see [Arm owners](#arm-owners). |
| The engine | `bin/fm-supervision-engine-lib.sh` | Owns the opt-in parse, the verified-engine list, and one bounded engine turn, including the reap of engine tool processes that outlive it. |
| Row eligibility | `bin/fm-branch-dispatch.mjs` | The command entry to `.pi/extensions/lib/fm-branch-dispatch.ts`, so the host and the Pi extension compute branch-claimable rows and their task scope from one owner; it also renders the wake message with the same away-posture tail. |
| The grant and the drain | `bin/fm-wake-grant.sh` | Publishes the branch's rows bound to the host's own process; [watcher-continuity.md](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor drain and acknowledgement the engine runs. |
| The prompt | `bin/fm-branch-prompt.sh` | Emits the same byte-stable prompt the Pi branch runs; each wake names its host's report surface. |
| The report surface | `bin/fm-branch-report.sh` | The command twin of the Pi branch's `fm_branch_report` tool, with the same task scoping; see [The report surface](#the-report-surface). |
| Leases and authority | `bin/fm-lease-lib.sh` | Owns the per-task leases, the main-owned role partition, and the away relocation; see [Leases and authority](#leases-and-authority). |
| The main side | [supervision-protocols/supervision-host.md](supervision-protocols/supervision-host.md) | What main reads at session start on an opted-in home, rendered for its harness. |

### Arm owners

For an opted-in home, each primary's existing arm owner runs the host in place of its watcher command.
The arm owner delivers a handed-back wake through the wake path that harness already trusts.
The host's header owns the output contract they read.

| Primary | Arm owner | A handed-back wake reaches main as |
|---|---|---|
| Claude | the Stop auto-arm, `bin/fm-claude-stop-autoarm.sh`, inside its single-flight generation | the hook's exit-2 rewake (`Stop hook feedback`) |
| Cursor | the `stop` hook park, `bin/fm-turnend-guard-cursor.sh` | the park's `watcher` follow-up |
| OpenCode | the TUI plugin, `.opencode/plugins/fm-primary-watch-arm.js`, which restarts its own successor after each close | a `watcher` prompt through `promptAsync` |
| omp | the watch extension, `.omp/extensions/fm-primary-omp-watch.ts`, which restarts its own successor after each close | the extension's `watcher` follow-up |
| Grok | the model's tracked background call, rendered as `bin/fm-supervision-host.sh park` at session start | the background task's completion notification |
| Codex | the foreground checkpoint, `bin/fm-watch-checkpoint.sh`, in the watcher's place | the checkpoint's own output |

Hook, plugin, extension, and checkpoint owners pass their harness as the primary pin.
Grok's model-owned call relies on primary detection.
The host pins dispatched work to the primary's crew harness rather than the engine's.

Grok's arm command is fixed when the session-start block renders.
So adding or removing the file on a Grok home takes effect at the next session start.
The other owners read the file at every arm.

### The report surface

`bin/fm-branch-report.sh` appends to the outcome store (`bin/fm-branch-outcome.sh`) plus a per-turn receipt the host requires.
A row recorded after the captain returned is also queued for main as a durable check wake.

### Leases and authority

The host's engine runs with these settings:

- `FM_SUPERVISION_ACTOR=branch`.
- The session-lock holder as `FM_LEASE_HOLDER_PID`.
- The primary's harness pin.

So every guarded script treats it exactly as it treats the Pi branch.

## One away wake

On each actionable close under the away record, the host runs these steps:

1. It starts and verifies the successor watcher cycle and confirms the handling handoff, so the fleet stays supervised while the engine works.
2. It computes the branch-claimable rows and publishes the grant.
3. It runs one bounded engine turn with the branch prompt and the wake message carrying the record's read-back.
   The engine drains, handles, reports through `bin/fm-branch-report.sh`, and acknowledges, exactly as the Pi branch does.
4. It releases the branch's leases and grant, whether or not the wake was handled.
5. It parks on the successor only for a handled wake.

The host counts the wake handled only when all three hold:

- The turn exited cleanly.
- The turn recorded at least one report.
- The turn left none of its granted rows in the wake queue.

### Where a handled wake's outcome goes

A handled wake never reaches main, whether its outcome was routine or captain.
Captain outcomes wait in the outcome store, and the return brief (`bin/fm-afk-return.sh`) presents them.

### A captain who returns during a turn

The one exception to that rule is a captain who returns while a turn is still running.
The return brief was rendered before that turn's outcomes existed.
So the host hands the close to main with those outcomes for main to relay, whether or not the turn handled its wake.

That handoff is only the prompt delivery.
Each outcome recorded after the return is already a queued `check` wake, for two reasons:

- The return owner archives the record before it reads the store.
- The report surface queues any row it records once the record is gone.

So the outcome reaches main's drain even when the handoff is lost.
One example is a Cursor park superseded by the return turn's own end, which stops its host as the engine turn finishes.

## Failure direction

Every path that cannot finish an away wake on the engine hands that wake to main, with one `supervision-host: <why>` line after the close.
Before handing it back, the host stops its successor cycle.
So the owner's next arm starts from the same state as without the host, and the wake stays durable in the queue.

### Paths that hand the wake back

- An unverified successor.
- A refused handoff.
- An unreadable queue.
- Rows main already claimed.
- A missing engine or node.
- A turn that timed out or failed.
- A turn that recorded no report.
- A turn that reported but left any of its granted rows unacknowledged.
  Its line names those rows, which stay durable in the queue for main's drain.

A turn that fails also starts the next wake on a fresh engine conversation.
When the captain returned during a failed turn that recorded outcomes, the handback carries those outcomes too, for main to relay.

### Lost ownership

When the host loses session-lock ownership or its auto-arm generation, it stands down silently and leaves continuity to whoever owns it now.
A host that starts without that ownership stands down before activation.
So it never stops the owner's host or watcher or releases its leases.

### A host that dies without a close

The host's owner retries it.
Grok's model and Codex's checkpoint see it as a failed cycle and start the next one.
Before it arms, the next host does two things:

- It stops, by recorded identity, whatever its predecessor left running, including the engine descendants a killed turn recorded.
- It removes that turn's files.

## The park boundary

The host stays parked across every close it handled itself and exits only when main is needed.
Claude drops the exit 2 of a Stop hook it terminated at the hook timeout ([verification](verification/supervision.md#claude-drops-the-exit-2-of-a-hook-it-timed-out-2026-09-23)).
Cursor's `stop` hook carries the same tracked 28,800-second registration.
A plain watcher park rarely lasts that long, because heartbeat closes wake main.
But a host absorbs its own wakes, so it ends its park itself before that registration.

### Setting the boundary

`FM_SUPERVISION_HOST_PARK_SECONDS` sets that boundary (default 27,000).
A value that is not a positive integer below 28,800 is treated as the default.
The OpenCode, omp, and Grok owners have no hook timeout and keep the same default, so their parks end on the same cadence.

### At the boundary

At the boundary the host stops the home's watcher and exits with one `supervision-host: cycle boundary` line.
Main drains and acknowledges, and the owner starts the next park:

| Primary | When the next park starts |
|---|---|
| Claude and Cursor | At the next turn end. |
| OpenCode and omp | At once. |
| Grok | At the model's re-arm. |

The host checks the boundary on every loop pass, so closes that are already waiting cannot carry it past the boundary.
It also starts no engine turn that could still be running at the boundary (the turn bound plus the engine grace).
It judges this when the close arrives and again just before the turn starts.
When it declines such a turn, that close reaches main ahead of the boundary line instead, and its wake stays durable in the queue.
One short main turn per boundary is the cost of never losing the park silently.

### Codex checkpoint bound

Codex has no asynchronous wake, so its checkpoint's own bound is the park.
The checkpoint passes it as the boundary and reports the boundary as its ordinary quiet line (`checkpoint: no actionable wake within <n>s`).

| Posture | Checkpoint bound |
|---|---|
| Attended | `FM_CODEX_WATCH_CHECKPOINT` (default 180 seconds). |
| Away record exists | Raised to `FM_CODEX_WATCH_CHECKPOINT_AWAY` (default 3,600) if longer, then capped at 27,000 seconds so a parked main is not woken every few minutes. |

Because that bound is not a harness timeout, the checkpoint also sets `FM_SUPERVISION_HOST_PARK_LIMIT`.
That setting lets an engine turn that starts before the boundary finish after it.
A captain message typed during the park waits for the checkpoint to return, at most the bound plus one engine turn, unless the captain interrupts it.

## Engine conversations

The engine keeps one conversation across wakes so the byte-stable prompt stays cached.
That conversation is keyed to the current main session.
A new one opens in two cases:

- At every main session start.
- Every `FM_SUPERVISION_HOST_ROTATE_TURNS` turns, because each wake adds history and the per-wake cost grows with it.

Nothing captain-facing rides on that conversation, because the outcome store carries every result.
The engine sees no mirror of main's dialog.
The away record's read-back at the tail of every wake is the captain context it acts on.

### Where engine cost is read

`state/.supervision-host.log` records where every close went.
Each engine turn's line carries these fields, and this log is where engine cost is read today:

- Its result.
- The engine's reported usage.
- The turn's cost.
- The conversation's running cost.

## Engines

A verified engine is a headless mode of a harness whose isolation, actor propagation, promptless permissions, bounding, and caching were measured.
Today the only verified engine is Claude's print mode, measured on Claude Code 2.1.278 and 2.1.281.

### Claude print mode behavior

**Isolation**

- `--safe-mode` loads none of the home's hooks, `CLAUDE.md`, skills, plugins, or MCP servers.
  So the engine can never fire the home's own Stop or SessionStart hooks.
- `--bare` is unusable because it never reads claude.ai OAuth.
- From inside the engine's shell the primary is not in the harness ancestry, so the engine can never act as the session-lock owner.

**Permissions**

- `--permission-mode dontAsk` with the `Bash` and `Read` allowlist never prompts.
  A denied call reaches the model as a tool error and never wedges the turn.
- `--safe-mode` does not override the user's default mode, so the mode is always passed.
- Claude path-checks direct file reads against its working directories.
  So a home or state directory outside the code root is passed with `--add-dir`.

**Conversation and input**

- The conversation starts with `--session-id` and continues with `--resume`.
- The prompt is the first argument and stdin is `/dev/null`, because an open stdin costs a three-second wait.
- The engine runs from the tracked code root.
  So its session files land in Claude's own project store for that directory and appear in that directory's resume list.

**Result and cost**

- `--output-format json` carries the error flag, turn count, usage, and the tool's own cost estimate.
- On a resumed conversation that cost is the conversation's running total, while the usage and turn count are the turn's own.
  So the engine lib derives each turn's cost from the total the host recorded after the previous turn.
- The host counts a turn successful only when that result is complete:
  - `type` is `result`.
  - `subtype` is `success`.
  - `is_error` is false.
  - `total_cost_usd`, `num_turns`, and the four `usage` token counts (input, cache read, cache creation, output) are finite numbers.
- Any other result fails the turn and hands its wake to main.

**Tool process reaping**

Tool commands run in process groups of their own, which a bound's group signal cannot reach.
So the engine lib records the engine's descendants once a second and reaps them by recorded identity after every turn.
The reap is best-effort for what it observed, not a bound.
A process escapes it when a tool detaches it into a process group of its own and it loses its ancestry to the engine between two snapshots.
Such a process is never recorded and survives the turn, the same residual `bin/fm-timeout-lib.sh` names.

### Model and engine selection

The default model is `sonnet`, which handled every measured wake correctly at a fraction of a larger model's cost.
`config/supervision-host` can name another.

The Claude engine runs beside any of the six primaries, but only a Claude primary selects it by default.
A Cursor, OpenCode, omp, Grok, or Codex home names it (`claude`, optionally with a model) in `config/supervision-host`.
`/afk` there says so when the file selects no engine.

## Verification

Each arm owner's own suite covers its host mode against a stub host.

| Test | What it covers |
|---|---|
| `tests/fm-supervision-host.test.sh` | Drives the real host, auto-arm, grant, drain, report, and lease scripts against a stub engine. |
| `tests/fm-claude-stop-autoarm.test.sh` | The Claude arm owner's host mode against a stub host. |
| `tests/fm-cursor-primary.test.sh` | The Cursor arm owner's host mode against a stub host. |
| `tests/fm-pi-watch-extension.test.sh` | The OpenCode plugin's host mode against a stub host. |
| `tests/fm-omp-harness.test.sh` | The omp arm owner's host mode against a stub host. |
| `tests/fm-watch-checkpoint.test.sh` | The Codex checkpoint's host mode against a stub host. |
| `tests/fm-supervision-instructions.test.sh` | The rendered protocol, including Grok's arm command. |
| `tests/fm-supervision-host-live-e2e.test.sh` | Runs a real engine turn; opt-in because it spends tokens. |

[verification/supervision.md](verification/supervision.md#supervision-host) records the dated live results.
