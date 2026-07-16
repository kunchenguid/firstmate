# Paseo runtime backend (experimental)

This document records the empirical verification behind `bin/backends/paseo.sh`, the Paseo agent-session-provider adapter.
It is the Paseo equivalent of the tmux facts in the `harness-adapters` skill and the herdr/orca/cmux backend docs.

Paseo ([paseo.sh](https://paseo.sh), getpaseo/paseo) is a self-hosted TypeScript daemon that manages headless coding-agent sessions and surfaces them in desktop/mobile/web clients.
Unlike tmux/herdr/zellij/cmux it is NOT a terminal multiplexer: there is no pane to type into.
`paseo run` launches a provider agent directly with a prompt and a `--cwd`, and `paseo send` delivers a follow-up message to that agent over the daemon API.

All facts below were verified against the real installed CLI on 2026-07-16.

- Paseo CLI: v0.1.104 (`paseo --version` -> `0.1.104`), at `~/.local/bin/paseo`.
- Daemon: `paseo status --json` -> `localDaemon: "running"`, `connectedDaemon: "reachable"`, `listen: "127.0.0.1:6767"`, `cliVersion: "0.1.104"`, `daemonVersion: "0.1.104"`.
- node is used to parse Paseo's `--json` output (the universal firstmate JSON tool, as in `bin/backends/orca.sh`).

## Status: experimental

Paseo is experimental, exactly like every non-tmux backend.
Select it by putting `paseo` in a local `config/backend` file, by exporting `FM_BACKEND=paseo`, or by telling the first mate in chat.

Paseo is NEVER runtime auto-detected, even though firstmate itself commonly runs AS a Paseo agent (verified: this repo's own sessions appear in `paseo ls`).
This follows the zellij/orca precedent: auto-detecting the runtime firstmate happens to run inside would silently opt every fleet into the experimental backend, so backend selection stays explicit.

A paseo spawn refuses loudly before leasing a worktree if the `paseo` CLI or `node` is missing, if the daemon is not running/reachable, if the CLI is older than the verified floor, or if the resolved harness is not a Paseo provider (see below).

## Worktree provider stays treehouse

Paseo is a session provider only.
Treehouse remains the worktree provider, exactly as it is for tmux/herdr - NOT like Orca, which owns its own worktree.
Paseo's own `paseo worktree` and `paseo run --worktree` features are never used.

Because `paseo run` has no bare shell to type `treehouse get` into, `bin/fm-spawn.sh` acquires the worktree first, non-interactively:

```
treehouse get --lease --lease-holder fm-<id>
```

`--lease` prints ONLY the worktree's absolute path to stdout (all banners go to stderr) and durably reserves the pool slot; teardown releases it through the standard `treehouse return --force` path in `bin/fm-teardown.sh`.
Verified: `treehouse get --lease` from a scratch pooled repo printed `/Users/jacobcole/.treehouse/proj-472f6f/1/proj` on stdout with setup banners on stderr.

## Provider gating: grok is refused

`paseo provider ls --json` (verified) lists:

| provider | status |
|---|---|
| claude | available |
| codex | available |
| opencode | available |
| pi | available |
| copilot | unavailable |
| omp | disabled |

There is no `grok` provider.
`fm_backend_paseo_provider_for_harness` maps a firstmate harness to a Paseo provider and refuses `grok` (and any non-`{claude,codex,opencode,pi}` harness) LOUDLY at spawn time, before a worktree is leased.
A backend refusal is terminal, never a silent fallback to another backend (AGENTS.md section 4).

## Verified CLI facts

| Operation | Verified paseo call | What was verified |
|---|---|---|
| Version / daemon gate | `paseo status --json` -> `.localDaemon`/`.connectedDaemon`/`.cliVersion` | `running`/`reachable` and `cliVersion` `0.1.104`. The floor is pinned to the exact verified version (`FM_BACKEND_PASEO_MIN_VERSION`) because Paseo is pre-1.0 and its `--json` shapes are still moving; raise it only after re-verifying against the newer build. |
| Spawn | `paseo run --detach --cwd <wt> --provider <name>[/<model>] --mode bypassPermissions --title fm-<id> --label fm-task=<id> --env GOTMPDIR=<path> --json "<brief>"` | Returns `{"agentId": "...", "status": "running", "provider": "...", "cwd": "...", "title": "..."}`. The brief CONTENT is the run prompt (Paseo takes the initial task as the prompt, not a shell launch command). `bypassPermissions` is the verified claude mode id (from `paseo inspect`'s `AvailableModes`) - the autonomous equivalent of claude's `--dangerously-skip-permissions`. GOTMPDIR rides `--env` since there is no pane to `export` into. |
| Steer | `paseo send <id> --no-wait --prompt "<text>"` | Delivers one message atomically over the daemon API - no composer to submit, no autocomplete-popup hazard. Verified: a `send` after the agent went idle started a fresh turn that produced the requested reply. `send_text_submit` reports the shared `empty` ("submitted") verdict on success. |
| Peek | `paseo logs <id> --tail N` | Returns the activity timeline (the closest analogue to tmux's `capture-pane` for a message-based agent). Verified against a real claude agent's `[User]`/`[Shell]`/`[Write]` timeline. |
| Busy state | `paseo inspect <id> --json` -> `.Status` | `running` while a turn is active, `idle` once it finishes. Mapped: `running` -> busy; `idle` -> idle; anything else/unreadable -> unknown. NOTE: `inspect` uses PascalCase keys (`Status`, `Id`, `Mode`, `Cwd`); `ls --json` uses lowercase (`status`, `id`). |
| Agent liveness | `paseo inspect <id> --json` | `running`/`idle` -> `alive`; a not-found agent (`{"error":{"code":"INSPECT_FAILED","message":"...Agent not found..."}}`, non-zero exit) -> `dead`; `error`/`closed`/`failed`/`stopped` -> `dead`; anything unreadable -> `unknown` (fail-safe toward refusal, exactly like the tmux/herdr probes). Verified: a deleted agent's id returns `dead`. |
| Interrupt | `paseo stop <id>` | Interrupts a running agent (no-op for an idle one). Bound to the `C-c` key in `fm_backend_paseo_send_key`. |
| Teardown / kill | `paseo delete <id> --json` | Interrupts a running agent then hard-deletes it, returning `{"deletedCount":1,"agentIds":[...]}`. Best-effort (`|| true`); deleting an already-gone agent is a harmless no-op. Verified: `inspect` after `delete` reports the agent not found. |

### Escape is unsupported

Paseo is message-based, so most terminal "keys" have no meaning.
`fm_backend_paseo_send_key` maps `C-c` to `paseo stop` (interrupt) and treats `Enter` as a no-op success (a `send` already delivers its message atomically).
`Escape` is refused loudly, the same Orca precedent (`bin/backends/orca.sh`) - Paseo exposes no terminal-composer key primitive.

## Turn-end signal: the claude Stop hook fires under `paseo run`

Deliverable #3 required an empirical decision: does `bin/fm-spawn.sh`'s existing claude turn-end Stop hook (written into the worktree's `.claude/settings.local.json`) fire when the agent is launched via `paseo run`, or is a `paseo wait`-based sidecar needed?

**It fires.** Paseo's claude provider spawns the real `claude` binary in `--cwd`, which reads `.claude/settings.local.json` and runs its `Stop` hook at every turn boundary.

Smoke test (2026-07-16), reproduced twice:

1. A worktree with `.claude/settings.local.json` containing `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch '<TURNEND>'"}]}]}}`.
2. `paseo run --detach --cwd <wt> --provider claude --mode bypassPermissions ...`.
3. `paseo wait <id>` returned `idle`, and `<TURNEND>` was touched - the Stop hook fired.

Confirmed end to end through the real `bin/fm-spawn.sh` paseo path: after the spawned claude crewmate finished its first turn, `state/<id>.turn-ended` was touched; after a `fm-send.sh` steer started a second turn, the file was re-touched.
So the watcher wakes on every crew turn completion, through the existing turn-end mechanism, with no sidecar added.

`bin/fm-spawn.sh` writes the claude Stop hook into the leased worktree BEFORE the `paseo run` call (the run happens after the turn-end-hook block, not in the container-ensure case), so the hook is already present when the agent starts.

### Known limitation: non-claude providers

Only claude's turn-end hook is filesystem-based (`.claude/settings.local.json`) and therefore survives Paseo's own provider invocation.
The codex (`-c notify=`) and pi (`-e` extension) turn-end signals in `bin/fm-spawn.sh` ride the SHELL LAUNCH COMMAND, which Paseo does not use - Paseo constructs the provider invocation itself - so those signals are not wired under the paseo backend yet.
A codex/opencode/pi crewmate on paseo is still supervised by the watcher's heartbeat and stale-detection paths, just without the prompt per-turn wake claude gets.
The provider-agnostic generalization would be a per-task `paseo wait <id>` sidecar that touches `state/<id>.turn-ended` on each idle transition (respawned by the poll path if it dies); it is left as future work since the live-verified target (claude) already has a working turn-end signal.

## End-to-end verification (spawn -> peek -> send -> busy -> alive -> turn-end -> interrupt -> teardown)

Driven 2026-07-16 through this branch's own scripts, in a scratch `FM_HOME`, a scratch pooled git project, and a real `claude` crewmate:

1. `FM_BACKEND=paseo bin/fm-spawn.sh e2e-t1 <proj> claude` - spawned successfully; printed `window=fm-e2e-t1 worktree=<leased path>`, and wrote `backend=paseo` plus `paseo_agent_id=2a558bb8-...` to the task's meta with `window=fm-e2e-t1` kept as the display alias.
2. `fm_backend_agent_alive paseo <id>` -> `alive`; `fm_backend_busy_state paseo <id>` -> `idle` once the turn finished; `fm_backend_target_exists paseo <id>` -> success.
3. `state/e2e-t1.turn-ended` was touched (the claude Stop hook), and the crewmate created `hello.txt` (`ahoy`) in the leased worktree.
4. `bin/fm-peek.sh fm-e2e-t1` - showed the agent's `[User]`/`[Shell]`/`[Write]`/`DONE` timeline.
5. `bin/fm-send.sh fm-e2e-t1 "..."` - delivered a fresh turn (verified in the timeline); `state/e2e-t1.turn-ended` was re-touched after that turn.
6. `fm_backend_send_key paseo <id> C-c` succeeded (`paseo stop`); `fm_backend_send_key paseo <id> Escape` was refused as expected.
7. `bin/fm-teardown.sh e2e-t1` REFUSED (uncommitted work: `REFUSED: worktree ... has uncommitted changes.`); `bin/fm-teardown.sh e2e-t1 --force` then completed, `paseo delete`d the agent (verified gone via `paseo inspect`), returned the treehouse lease, and removed the task's `state/` files.

The scratch agent, project, and `FM_HOME` were all deleted after the run; no real repo or the captain's own agents were touched.

## Daemon-restart semantics (as observed)

The Paseo daemon persists agent records: `paseo ls` and `paseo inspect` continued to resolve agents created hours/days earlier across the verification window, and `paseo status` reported a single long-running daemon (`startedAt` days prior, one `pid`).
One transient `paseo status` flake was noted during the earlier feasibility research; not reproduced during this verification.
A stored `paseo_agent_id=` is therefore a durable operational target for the life of the daemon; `fm_backend_paseo_agent_alive` re-checks it live rather than trusting the stored id blindly.
Full daemon-restart survival (kill + restart the daemon, then reconcile in-flight agents) was NOT exercised and is not claimed here.

## Out of scope (initial)

- `--secondmate` spawns: refused (`backend=paseo does not support --secondmate spawns yet`), like orca/cmux.
- Paseo-native worktrees (`paseo run --worktree`): never used; treehouse owns worktrees.
- The MCP layer (`create_agent` `notifyOnFinish`, `relationship:subagent`): an opportunistic push bonus only; the bash watcher backbone cannot call MCP, so supervision is never built on it.
- Runtime auto-detection: deliberately never, even when firstmate runs as a Paseo agent.
- Effort/`--thinking`: Paseo's `--thinking <id>` takes a thinking-option id, not firstmate's `low|medium|high|xhigh` vocabulary, so the effort axis is not threaded into paseo spawns.
