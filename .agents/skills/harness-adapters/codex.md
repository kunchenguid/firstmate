# harness-adapters: codex

Load this reference only when a Codex CLI runtime is being selected, spawned, recovered, interrupted, exited, resumed, or verified.
The core [harness-adapters](SKILL.md) reference owns universal selection, dispatch, backend, and verification invariants.
Worker operation facts below were verified 2026-06-11 on codex-cli 0.139.0 unless a narrower fact gives its own evidence.

## Launch profile and model discovery

| Axis | Verified support |
|---|---|
| Model flag | `--model <model>` |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'` |
| Evidence | Verified on codex-cli 0.142.1. |

The installed binary schema contains `model_reasoning_effort`, the active config uses it, and the bundled model catalog advertises only low, medium, high, and xhigh.
`max` is omitted.
Open the current interactive session's `/model` picker to discover available models.
If the current authenticated environment does not establish the requested model or provider relationship, fail loudly and report the unresolved candidate.

## Worker operation facts

| Fact | Value |
|---|---|
| Busy-pane signature | `esc to interrupt`, shown as `• Working (Xs • esc to interrupt)` |
| Exit command | `/quit`, with the slash popup needing about 1 second between text and Enter; `fm-send` handles it |
| Interrupt | single Escape |
| Skill invocation | `$<skill>`; `/<skill>` is claude-only and codex rejects it as `Unrecognized command` |
| Resume | `codex resume <session-id>` using the session id printed on quit |

A `$<skill>` invocation opens a `$`-autocomplete skill popup, the same hazard as the `/` slash popup: submitting too fast lets the popup swallow the Enter, so the invocation never lands.
`fm-send` handles it the same way it handles `/` by giving the popup a longer settle of 1.2s between typing and the first Enter, with the target backend's submit retry as the safety net.
The `$` settle is scoped to `harness=codex`, read from the target metadata for exact task ids or legacy `fm-<id>` labels.
That scope matters because, unlike `/`, a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`, so a universal `$` rule would needlessly slow plain steers to claude, opencode, or pi.
Only a codex target receiving a `$...` message gets the popup-settle.
An explicit `session:window` target has no meta, so its harness is unknown and treated as non-codex, which is the safe fast-path default.
This is why a `$<skill>` invocation to a codex worker lands instead of being swallowed by the popup.

Directory trust dialog on first run per repo root: "Do you trust the contents of this directory?"
Accept with Enter.
The decision persists for the repo, so later worktrees of the same project skip it.

## Primary integration facts

`codex` blocks directly through Stop hooks that preserve exit status 2 and stderr from `bin/fm-turnend-guard.sh`.
`codex` blocks watcher-arm anti-patterns directly through PreToolUse hooks.
Codex uses bounded foreground checkpoints through `bin/fm-watch-checkpoint.sh` because Codex cannot reason while a foreground tool call is running.

`bin/fm-sessionstart-nudge.sh` is verified on 0.144.4.
`.codex/hooks.json` receives `source=startup`, and wrapper stdout reaches model context.

**Primary-session guard fact, verified 2026-07-08 on codex-cli 0.142.1.**
The firstmate primary's own `.codex/hooks.json` registers a Stop hook that pipes Codex's Stop payload to `bin/fm-turnend-guard.sh`.
Codex Stop hooks block on exit 2 and expose `stop_hook_active` for the same one-block loop safety Claude uses.
Codex's Stop payload includes `cwd`, but the tracked primary hook does not use it to choose the guard executable.
Verified on 2026-07-08: Codex runs the Stop hook command with process PWD set to the hook-loaded project root, and no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is firstmate-shaped and hook-bearing, and then invokes `bin/fm-turnend-guard.sh` with the original payload.
Codex's primary watcher protocol is `bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `bin/fm-watch-arm.sh`.
The checkpoint is deliberately foreground and bounded so Codex regains control regularly to process user messages and queued wakes.
