# Orca runtime backend

Orca is an experimental macOS backend in which the Orca app owns both the task worktree and terminal endpoint.
The crewmate harness remains the agent process launched inside that endpoint.
Firstmate agents load [`firstmate-orca`](../.agents/skills/firstmate-orca/SKILL.md) before operating or recovering this backend.

## Setup

Pick Orca when you already use the Orca macOS app and want Orca-managed worktrees and terminals instead of Treehouse plus a session multiplexer.
Orca is macOS-only, explicit-only, and does not support secondmate spawns.

Prerequisites:

- `/Applications/Orca.app` installed, running, and ready.
- The `orca` CLI, installed with `brew install orca`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select Orca with local `config/backend` containing `orca`, `FM_BACKEND=orca` for one launch, or an explicit request to Firstmate.
It is never auto-detected.

Before any spawn mutates repository state, Firstmate requires `orca status --json` to report `reachable=true` and `state="ready"`.
The first task for a project registers that repository with `orca repo add --path` when needed.
No manual repository registration is required.

Open the Orca app to watch a task's terminal.
Routine supervision uses the recorded endpoint through `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'`.
Enter and Ctrl-C are supported; Escape is not.

## Task shape and metadata

Each task has one Orca-managed git worktree and one Orca terminal.
`fm-spawn.sh` does not call Treehouse for Orca tasks.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute Orca worktree path>
```

`window=` remains the caller-facing Firstmate alias.
`terminal=` and `orca_worktree_id=` are the backend authority used by operation and cleanup paths.

Orca exposes no process-identity or native agent-registration signal, so `bin/fm-spawn.sh` writes fm-composer-lib.sh's `FM_COMPOSER_ENDPOINT_SHELL_MARKER` into the terminal's own shell prompt, as a `PS1=` line of its own sent immediately before the launch text - never chained onto the launch command, because a `VAR=value` prefix is a parse error on a non-POSIX pane shell (fish, nushell) and those shells reject the whole line, which would stop the agent from launching at all, the same as on zellij and cmux.
`bin/fm-busy-lib.sh`'s `fm_busy_classify` reads it back through `terminal read` to report `dead endpoint-shell` for a terminal that has reverted to that marked shell, rather than the generic `unknown` a bare prompt reported before.
This is a busy-state read only: it does not change `fm_control_backend_state_verified`'s tmux/herdr-only recovery-grade gate, so `exit` and `relaunch` still refuse on Orca.
The pane does show a bare marked prompt while spawn is still launching, and the bound on that window differs per path.
On a **fresh spawn** `PS1` is not the marker until that one send, so no bare marked prompt exists before it and the launch text follows with nothing in between: the window is bounded by those two adjacent sends.
That is the only window on this backend: `relaunch` refuses on Orca (the recovery-grade gate above), so the wider relaunch window - where `PS1` already carries the marker before the pre-launch sequence even starts - can only arise on herdr, and is documented in docs/herdr-backend.md.
The read is therefore decided from the bottom-most marked row - the pane's current prompt - and never from stale scrollback above it.
The fresh-spawn window is a real residual race and is accepted: a capture landing in the instant between the marker line and the launch text reads `dead endpoint-shell` for a healthy launching endpoint.
That read is per task and sits last in `fm_busy_classify`, so it is reached only when the task has no busy record at all and no earlier harness-specific arm has already resolved it.
`cursor`, `grok`, and `muse` tasks always resolve inside their own arm and never reach it, so an exited agent on those harnesses still reports that arm's verdict rather than `dead endpoint-shell`.
`codex` and `kimi` tasks reach it only once their own semantic source is verified; until then they resolve as `unknown codex-unverified` / `unknown kimi-unverified`.
Every other harness (`claude`, `opencode`, and the Pi-hosted harnesses) reaches it whenever the task has no record.
The marker is planted with a one-shot `PS1=` assignment on the pane's interactive shell, so it is absent whenever that shell regenerates its prompt per command (starship, powerlevel10k, a `PROMPT_COMMAND` or `precmd` git prompt) or never consults `PS1` at all (fish, nushell).
An absent marker therefore proves nothing about the pane: it is read as undetermined, never as "the agent is alive", never as "this was never a firstmate endpoint", and never on its own as `dead endpoint-shell`.
A pane with no marker classifies exactly as it did before this feature existed.

## Current lifecycle and safety

Spawn registers the repository, creates an independent worktree, reuses only the verified `result.terminal.handle` returned by Orca or creates a terminal explicitly, installs harness hooks, records metadata, and launches the selected harness.
Exact command flags and response parsing are owned by `bin/backends/orca.sh` and script help.

`fm-peek.sh` reads with `orca terminal read`.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Orca's submit machinery.
On the typed plane, `fm-send.sh` verifies composer clearance through the fleet-wide classifier in `bin/fm-composer-lib.sh`, retrying Enter without retyping when a slash popup first fills an argument placeholder.
The composer read is one bounded tail of the live terminal and never pages backward into scrollback, so a stale startup banner cannot compete with the bottom-anchored composer.
A bare shell row is `unknown`, not an empty agent composer, and plain-text captures degrade a glyph row carrying trailing text to `unknown` rather than a false `pending`.
The watcher has no native Orca busy signal, so each harness adapter's semantic lifecycle supplies worker state.
Grok alone retains its isolated rendered-tail fallback.

Cleanup keeps all shared Firstmate safety checks.
A scout still requires its report and completed decision inventory.
A ship still refuses dirty or unlanded work.
Before release, cleanup resolves the recorded Orca worktree id and verifies its path matches the recorded worktree path.
A missing, unreadable, or mismatched identity preserves metadata and stops rather than deleting anything.
After those checks, Firstmate closes the exact terminal and releases the exact worktree with Orca's worktree command.
It never raw-deletes an Orca worktree.

## Active limits

- Orca is macOS-only and explicit-only.
- The app must be running and report ready.
- Secondmate spawns are unsupported.
- Escape is unsupported.
- Orca exposes no stable CLI version or protocol marker, so readiness is the compatibility gate rather than a version floor.
- Only the verified terminal-handle and worktree result fields are accepted; speculative response shapes are rejected.
- Orca's worktree shape is unverified against the spawn-time Claude workspace-trust check in `bin/fm-claude-trust.sh`, which refuses any path that is not a linked git worktree sharing the project's git common dir, so a claude spawn on Orca fails loudly at that check rather than launching if Orca clones instead of linking.

## Regression entry points

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#orca) records the real readiness and response-shape smoke.
