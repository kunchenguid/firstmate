# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh\|max>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertised only the first four values while omitting `max`; current codex-cli 0.153.4 catalog data at `${CODEX_HOME:-~/.codex}/models_cache.json` advertises `max` for `gpt-5.6-luna`, which Firstmate passes for that model. |
| Model discovery | Open the current interactive session's `/model` picker. |
| Marker | None; identity comes from ancestry, and `../../../bin/fm-harness.sh` is what keeps a retained foreign `CLAUDECODE` from renaming it. Verified on 2026-09-01 with codex-cli 0.152.0: the pane process is the `node` npm shim and the native `codex` binary runs as its foreground child, so a tool subprocess reaches the native name directly while the shim itself is identified from its script path. |

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.

## Hook trust

A second dialog, "Hooks need review - N hooks are new or changed", appears whenever the machine's `~/.codex/hooks.json` or a project's own `.codex/hooks.json` carries a hook Codex has not persisted trust for.
It is unanswerable rather than merely inconvenient: its selection starts on "Review hooks", which is neither trusting nor declining, and Firstmate's key plane carries Enter, Escape and Ctrl-C with no arrow navigation.
Writing Codex's own trust store to pre-accept it would manufacture an operator consent that was never given.
So crewmate and scout launches disable Codex's hook layer outright (`bin/fm-spawn.sh`'s launch template owns the flag), which is the opposite of `--dangerously-bypass-hook-trust` - that flag RUNS the untrusted hooks.
A crewmate loses nothing: its turn-end signal is the `-c notify=` program on the same launch, and the Firstmate hooks in a project's `.codex/hooks.json` are primary-session infrastructure that stands down in a child worktree.
A secondmate is a primary in its own home and keeps its hooks, so an unanswerable modal there is still possible and is the operator's own hook review to settle.

## Code-mode host

Crewmate and scout launches also carry `-c features.code_mode_host=false` alongside `--disable hooks`, for the same reason: on codex-cli 0.155.1 `code_mode_host` is stable and on by default, it routes every `exec` tool call through a code-mode host backed by whatever MCP servers the operator has configured (on the incident machine, ChatGPT-Desktop-app `node_repl` and `cua_repl`), and a task worker should not inherit that dependency.
The `-c features.*` form is deliberate: an unknown `--disable` name is a hard codex error, while an unknown `features.*` key is ignored, so older codex releases without the feature still launch (verified on 0.155.1 with a made-up feature key).
Verified from codex's own structured logs on codex-cli 0.155.1: without the flag, five crew workers in a real incident all timed out on their first `exec` call with "timed out negotiating with the code-mode host", 100% of attempts, both in the initial launch and a relaunch.
A secondmate keeps `code_mode_host` on along with its hooks, since it is a primary in its own home running under the operator's own posture.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
