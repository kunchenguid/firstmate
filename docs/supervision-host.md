# Supervision host

The supervision host runs the supervision branch's contract beside a primary that is not Pi.
On Pi the branch is a second conversation inside the captain's own process ([pi-supervision-branch.md](pi-supervision-branch.md)); off Pi no such process exists, so the host owns the watcher cycle for the primary and runs the branch as a headless engine session.
It is one architecture with Pi's, not a second one: the same branch prompt, the same row eligibility, the same records, and the same guarded scripts decide what the branch may do.

## Scope today

The host is opt-in per home through `config/supervision-host`; [configuration.md](configuration.md#supervision-host-configsupervision-host) owns the file.
Without the file every home behaves exactly as it does without the host.
Today it runs only on a Claude primary and only takes wakes in the away posture:

- Attended (no away-posture record `state/.afk-contract`), the host is a pass-through: every close reaches main exactly as the plain watcher arm delivers it.
- Away (the record exists), the host hands each close to the engine, and main stays parked unless the host hands the wake back.
- `/afk` launches no away daemon on an opted-in Claude home, because the host is the away session there; `/quiet` still launches the daemon, and while its flag `state/.afk` exists the host stands aside exactly as the plain arm does.
- Pi keeps its in-process branch whether or not the file exists, and no Pi engine is built.

Attended supervision on the host, other primary harnesses, `/quiet` on the host, and the daemon's retirement are later steps of the same design; until they land, their current behavior stays as described in their own owners.

## Components and their owners

- The loop: `bin/fm-supervision-host.sh`, whose header owns the per-close order, the park boundary, ownership checks, predecessor cleanup, state files, and tunables.
- The arm owner: `bin/fm-claude-stop-autoarm.sh` runs the host in place of `bin/fm-watch-arm.sh` for an opted-in home, inside its existing single-flight generation, and delivers the host's output through the same exit-2 rewake; its header owns how host output is classified.
- The engine: `bin/fm-supervision-engine-lib.sh` owns the opt-in parse, the verified-engine list, and one bounded engine turn, including the reap of engine tool processes that outlive it.
- Row eligibility: `bin/fm-branch-dispatch.mjs` is the command entry to `.pi/extensions/lib/fm-branch-dispatch.ts`, so the host and the Pi extension compute branch-claimable rows and their task scope from one owner; it also renders the wake message with the same away-posture tail.
- The grant and the drain: `bin/fm-wake-grant.sh` publishes the branch's rows bound to the host's own process, and [watcher-continuity.md](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor drain and acknowledgement the engine runs.
- The prompt: `bin/fm-branch-prompt.sh` emits the same byte-stable prompt the Pi branch runs; each wake names its host's report surface.
- The report surface: `bin/fm-branch-report.sh` is the command twin of the Pi branch's `fm_branch_report` tool, with the same task scoping, and it appends to the outcome store (`bin/fm-branch-outcome.sh`) plus a per-turn receipt the host requires.
- Leases and authority: `bin/fm-lease-lib.sh` owns the per-task leases, the main-owned role partition, and the away relocation; the host's engine runs with `FM_SUPERVISION_ACTOR=branch`, the session-lock holder as `FM_LEASE_HOLDER_PID`, and the primary's harness pin, so every guarded script treats it exactly as it treats the Pi branch.
- The main side: [supervision-protocols/supervision-host.md](supervision-protocols/supervision-host.md) is what main reads at session start on an opted-in Claude home.

## One away wake

On each actionable close under the away record, the host first starts and verifies the successor watcher cycle and confirms the handling handoff, so the fleet stays supervised while the engine works.
It then computes the branch-claimable rows, publishes the grant, and runs one bounded engine turn with the branch prompt and the wake message carrying the record's read-back.
The engine drains, handles, reports through `bin/fm-branch-report.sh`, and acknowledges, exactly as the Pi branch does.
The host counts the wake handled only when the turn exited cleanly and recorded at least one report; it then releases the branch's leases and grant and parks on the successor.
A handled wake never reaches main, whether its outcome was routine or captain: captain outcomes wait in the outcome store, and the return brief (`bin/fm-afk-return.sh`) presents them.

## Failure direction

Every path that cannot finish an away wake on the engine hands that wake to main, with one `supervision-host: <why>` line after the close.
Before handing it back, the host stops its successor cycle, so main's next turn end starts from the same state as without the host and the wake stays durable in the queue.
That covers an unverified successor, a refused handoff, an unreadable queue, rows main already claimed, a missing engine or node, a turn that timed out or failed, and a turn that recorded no report.
A turn that fails also starts the next wake on a fresh engine conversation.
Rows the engine claimed but did not acknowledge stay durable and are presented again by the next drain, whichever actor runs it.
When the host loses session-lock ownership or its auto-arm generation, it stands down silently and leaves continuity to whoever owns it now.
A host that dies without a close is retried by the auto-arm, and the next host stops, by recorded identity, whatever its predecessor left running before it arms.

## The park boundary

Claude drops the exit 2 of a Stop hook it terminated at the hook timeout ([verification](verification/supervision.md#claude-drops-the-exit-2-of-a-hook-it-timed-out-2026-09-23)).
A plain watcher park rarely lasts that long, because heartbeat closes wake main, but a host absorbs its own wakes, so it ends its park itself before the tracked 28,800-second registration.
At the boundary it stops the home's watcher and exits with one `supervision-host: cycle boundary` line; main drains, acknowledges, and ends its turn, and that turn end starts the next park.
One short main turn per boundary is the cost of never losing the park silently.

## Engine conversations

The engine keeps one conversation across wakes so the byte-stable prompt stays cached, keyed to the current main session: every main session start opens a new one, and so does every `FM_SUPERVISION_HOST_ROTATE_TURNS` turns, because each wake adds history and the per-wake cost grows with it.
Nothing captain-facing rides on that conversation, because the outcome store carries every result.
The engine sees no mirror of main's dialog; the away record's read-back at the tail of every wake is the captain context it acts on.
Each turn appends one line to `state/.supervision-host.log` with its result and the engine's reported usage, which is where engine cost is read today.

## Engines

A verified engine is a headless mode of a harness whose isolation, actor propagation, promptless permissions, bounding, and caching were measured.
Today the only verified engine is Claude's print mode, measured on Claude Code 2.1.278 and 2.1.281:

- `--safe-mode` loads none of the home's hooks, `CLAUDE.md`, skills, plugins, or MCP servers, so the engine can never fire the home's own Stop or SessionStart hooks; `--bare` is unusable because it never reads claude.ai OAuth.
- `--permission-mode dontAsk` with the `Bash` and `Read` allowlist never prompts: a denied call reaches the model as a tool error and never wedges the turn; `--safe-mode` does not override the user's default mode, so the mode is always passed.
- Claude path-checks direct file reads against its working directories, so a home or state directory outside the code root is passed with `--add-dir`.
- The conversation starts with `--session-id` and continues with `--resume`; the prompt is the first argument and stdin is `/dev/null`, because an open stdin costs a three-second wait.
- `--output-format json` carries the error flag, turn count, usage, and the tool's own cost estimate.
- The engine runs from the tracked code root, so its session files land in Claude's own project store for that directory and appear in that directory's resume list.
- Tool commands run in process groups of their own, which a bound's group signal cannot reach, so the engine lib reaps them by recorded identity after every turn.
- From inside the engine's shell the primary is not in the harness ancestry, so the engine can never act as the session-lock owner.

The default model is `sonnet`, which handled every measured wake correctly at a fraction of a larger model's cost; `config/supervision-host` can name another.

## Verification

`tests/fm-supervision-host.test.sh` drives the real host, auto-arm, grant, drain, report, and lease scripts against a stub engine.
`tests/fm-supervision-host-live-e2e.test.sh` runs a real engine turn and is opt-in because it spends tokens.
[verification/supervision.md](verification/supervision.md#supervision-host) records the dated live results.
