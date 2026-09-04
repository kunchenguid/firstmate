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
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`, re-verified on codex-cli 0.150.1 whose installed schema contains `model_reasoning_effort` and whose active config uses it. The bundled catalog advertises these four on every model, and `max` (plus `ultra` on two) on SOME models only, so Firstmate omits `max` as per-model rather than universal - passing it would be a known-bad value on gpt-5.4/5.5. |
| Model discovery | Open the current interactive session's `/model` picker. |
| Autonomy | `-s workspace-write -a never` with `-c sandbox_workspace_write.network_access=true`, so the worker runs under codex's own sandbox and never prompts, rather than with both switched off as `--dangerously-bypass-approvals-and-sandbox` did. Verified on codex-cli 0.150.1. |
| Sandbox | `workspace-write` confines the worker's writes to the task worktree plus `/tmp` and `$TMPDIR`, which is why the launch also grants back the per-kind `--add-dir` roots each brief needs outside it. The explicit `network_access` grant is a separate axis, because that sandbox otherwise denies network egress by default and a crewmate could not push, use `gh`, or install dependencies. "Sandbox and writable roots" below owns both. |

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.

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

## Sandbox and writable roots

Verified 2026-08-31 on codex-cli 0.150.1.
Codex is the ONLY adapter Firstmate launches inside a filesystem sandbox: `-s workspace-write` confines every shell command the worker runs to its own working directory plus `/tmp` and `$TMPDIR`.
Every Firstmate task worktree is a LINKED worktree, so that confinement denies what the crewmate contract needs outside it - the scout report, the status appends supervision reads, the turn-end wake marker the `notify` hook touches, the captain-hold completion gate's lock, and `git add` itself, whose index lock lives in the primary checkout's git directory.

`../../../../../bin/fm-spawn.sh` grants these back with repeatable `--add-dir` roots, scoped PER KIND as narrowly as the sandbox allows so a mistaken worker command cannot reach another task's authoritative records:

- A ship crewmate gets only its OWN two per-task state FILES - `state/<id>.status` and `state/<id>.turn-ended` - plus its OWN steering inbox `state/<id>.inbox/` and the out-of-tree git common directory. Both files are pre-created at launch so the single-file roots resolve and neither the append nor the touch needs the directory-create permission a file grant withholds. Granting the files rather than `state/` keeps every OTHER task's status, metadata, and completion locks out of reach.
- A scout gets the same per-task state set a ship crewmate gets, plus two directory roots a ship never needs: `state/.locks/<id>/` for its completion gate and its own `data/<id>/` for the report. The metadata lock (`fm_meta_lock_path` in `../../../bin/fm-wake-lib.sh`) lives entirely inside the task's own `state/.locks/<id>/` - the lock symlink, the mktemp-named owner directories, and the `.steal` lock all land there - so granting that one pre-created directory serves the gate's every lock artifact while `state/` itself stays denied, and every OTHER task's status, inbox, and lock records stay out of reach with it.
- A secondmate gets ONLY the parent's `state/<id>.status` file and its parent-side `state/<id>.inbox/`, because its own home is already its workspace and it runs its own completion gate there.

The steering inbox is a DIRECTORY root for every kind, because firstmate allocates the record names after launch and they cannot be named ahead of time.
Every brief kind carries the same inbox section, whose acknowledgement is a `mv` of the handled record into `state/<id>.inbox/handled/`; without write on that directory a sandboxed worker would read its steering messages, be unable to acknowledge one, and be escalated as stuck for complying.
Firstmate creates the inbox and its `handled/` at launch so the root resolves.

Every root is emitted with its symlinks resolved, because codex resolves a granted root that way and the launch's own turn-end path is already canonical.
A state or data RECORD that is itself a symlink refuses the whole codex launch instead of resolving through the link or composing a grant short of what the brief needs, and the refusal names the path to repair before respawning.

`$FM_HOME` itself, `.env`, `config/`, `projects/`, and every other home stay denied, and the brief's own rule against writing outside the worktree remains stricter than the sandbox.

One limit no writable root and no operator setting lifts: `~/.no-mistakes` stays denied, so a Codex worker cannot drive `no-mistakes axi` and cannot run validation itself.
Network is NOT such a limit and is a separate axis from the roots: `workspace-write` defaults `sandbox_workspace_write.network_access` to denied, but Firstmate's launch passes `-c sandbox_workspace_write.network_access=true` unconditionally and a CLI `-c` override wins over `~/.codex/config.toml`, so egress is on for every Firstmate Codex crewmate regardless of the machine.

[`../../../../../docs/verification/codex-sandbox.md`](../../../../../docs/verification/codex-sandbox.md) owns the evidence and the refresh command.
