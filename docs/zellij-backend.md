# Zellij runtime backend

Zellij is an experimental explicit-only session backend.
It provides the terminal session while Treehouse continues to provide task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick Zellij when you already use it as a terminal multiplexer and accept its current focus, liveness, and polling limits.

Prerequisites:

- Zellij 0.44 or newer.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select it with local `config/backend` containing `zellij`, `FM_BACKEND=zellij` for one launch, or an explicit request to Firstmate.
It is never auto-detected.
A spawn stops before creating a session or acquiring a worktree when Zellij or `jq` is missing or Zellij is below 0.44.

Firstmate uses one shared session named `firstmate` by default.
`FM_ZELLIJ_SESSION` can select another name for isolated verification.
Attach with:

```sh
zellij attach <session-name>
```

Routine supervision does not require attachment.
Use `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` against the metadata-routed endpoint.

Verify setup by spawning a small task and confirming metadata contains `backend=zellij`, `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.

## Task shape and home isolation

Every task receives one tab in the shared Zellij session.
The caller-facing label remains `fm-<id>`, while the visible title is home-scoped as `fm-<home-label>-<id>`.
The home label is `firstmate` or `2ndmate-<id>` plus a short stable hash of the resolved Firstmate root.
This prevents task-id collisions between a primary, secondmates, and separate Firstmate installations sharing one session.

Zellij does not enforce tab-name uniqueness, so the adapter performs its own duplicate check against the scoped title.
Create, recover, list, and cleanup paths all use the same scoped title owner in `bin/fm-backend-hometag-lib.sh`.
Moving a Firstmate installation changes its path hash and leaves old titles unmatched, consistent with worktree paths also becoming stale after a move.

A pre-home-tag task remains reachable through its recorded metadata only when exactly one live tab has the old unscoped title.
Multiple old tabs with the same title cause a refusal rather than a guess.
Bulk recovery never adopts unscoped legacy tabs because it has no safe home identity for them.

```text
backend=zellij
window=<session>:<pane-id>
zellij_session=<session>
zellij_tab_id=<tab-id>
zellij_pane_id=<pane-id>
```

Recorded pane ids are numeric and are never trusted alone after a session recreation.
Metadata-routed operations also verify the owning tab's expected scoped or unambiguous legacy title.
An explicit raw `session:pane` target remains a pane-existence-only operator escape hatch.

Zellij exposes no per-pane pid (see "Active limits" below), so it has no process-identity signal at all, unlike tmux or herdr.
`bin/fm-spawn.sh` compensates by writing fm-composer-lib.sh's `FM_COMPOSER_ENDPOINT_SHELL_MARKER` into the pane's own shell prompt, as a `PS1=` line of its own sent immediately before the launch text - never chained onto the launch command, because a `VAR=value` prefix is a parse error on a non-POSIX pane shell (fish, nushell) and those shells reject the whole line, which would stop the agent from launching at all; `bin/fm-busy-lib.sh`'s `fm_busy_classify` reads it back through `dump-screen` to report `dead endpoint-shell` for a pane that has reverted to that marked shell, rather than the generic `unknown` a bare Zellij prompt reported before.
This is a busy-state read only: it does not change `fm_control_backend_state_verified`'s tmux/herdr-only recovery-grade gate, so `exit` and `relaunch` still refuse on Zellij.
Zellij types a text line in two phases - a bracketed paste followed by a separate Enter - so a marker send that reports the line pasted but neither submitted nor cleared leaves it stranded on the pane's input line.
Spawn then clears that line, re-reads the pane, and aborts the spawn with a named error rather than sending the launch command on top of text it cannot positively prove is gone, because one concatenated line would launch nothing and say nothing.
The pane does show a bare marked prompt while spawn is still launching, and the bound on that window differs per path.
On a **fresh spawn** `PS1` is not the marker until that one send, so no bare marked prompt exists before it and the launch text follows with nothing in between: the window is bounded by those two adjacent sends.
That is the only window on this backend: `relaunch` refuses on Zellij (the recovery-grade gate above), so the wider relaunch window - where `PS1` already carries the marker before the pre-launch sequence even starts - can only arise on herdr, and is documented in docs/herdr-backend.md.
The read is therefore decided from the bottom-most marked row - the pane's current prompt - and never from stale scrollback above it.
The fresh-spawn window is a real residual race and is accepted: a capture landing in the instant between the marker line and the launch text reads `dead endpoint-shell` for a healthy launching endpoint.
That read is per task and sits last in `fm_busy_classify`, so it is reached only when the task has no busy record at all and no earlier harness-specific arm has already resolved it.
`cursor`, `grok`, and `muse` tasks always resolve inside their own arm and never reach it, so an exited agent on those harnesses still reports that arm's verdict rather than `dead endpoint-shell`.
`codex` and `kimi` tasks reach it only once their own semantic source is verified; until then they resolve as `unknown codex-unverified` / `unknown kimi-unverified`.
Every other harness (`claude`, `opencode`, and the Pi-hosted harnesses) reaches it whenever the task has no record.
The marker is planted with a one-shot `PS1=` assignment on the pane's interactive shell, so it is absent whenever that shell regenerates its prompt per command (starship, powerlevel10k, a `PROMPT_COMMAND` or `precmd` git prompt) or never consults `PS1` at all (fish, nushell).
An absent marker therefore proves nothing about the pane: it is read as undetermined, never as "the agent is alive", never as "this was never a firstmate endpoint", and never on its own as `dead endpoint-shell`.
A pane with no marker classifies exactly as it did before this feature existed.

## Current operation and safety

Zellij's CLI action commands return exit 0 even for missing sessions or panes.
The adapter therefore verifies session, terminal pane, and expected title before an operation and validates JSON or integer response shapes afterward.
A pane can still disappear between verification and the operation; downstream submit, worktree-discovery, and stale detection report that narrow race rather than treating exit 0 as success.

Every pane operation passes an explicit `--pane-id` because a new session can focus its release-notes plugin pane, whose numeric plugin id is in a separate namespace from terminal pane ids.

`pane_cwd` follows a top-level shell `cd` but not the foreground subshell opened by `treehouse get`.
Worktree discovery therefore sends begin and end markers around `pwd`, captures the marked block, and joins wrapped path lines.
This active probe is scoped to spawn-time worktree discovery and is not advertised as a general live-cwd API.

`new-tab` has no no-focus flag and temporarily focuses the created tab in attached clients.
The adapter records the previously active tab and immediately restores it with `go-to-tab-by-id`.
There is a narrow visible race between those calls that no current Zellij flag can remove.

An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through Zellij's submit machinery.
On the typed plane, literal send uses bracketed paste followed by a separate explicit Enter.
Before sending Enter, the adapter proves that the selected composer's normalized content changed by exactly the pasted text; an unreadable composer, a paste that lands elsewhere, or unrelated pane output fails without submitting.
The adapter supports `Enter`, `Esc`, and the one-argument key expression `Ctrl c` through the shared key vocabulary.
Zellij exposes no cursor-row or native agent-state signal, but `dump-screen --ansi` (verified at 0.44.0) preserves styling, so the composer is read through the same fleet-wide classifier as tmux and herdr (`bin/fm-composer-lib.sh`), with ghost and placeholder text stripped before the verdict.
Submit acknowledgement requires a positively classified empty composer.
The retired content-delta acknowledgement could report a message delivered whenever the pane changed for any reason - a spinner, streaming output, a clock - which could silently close a decision record for a message the crew never received; a pane that merely changed no longer confirms anything.
A dead pane still fails safe: Zellij's unconditional-exit-0 actions dump nothing, and an empty dump classifies `unknown`, never a confirmation.

Viewport capture has no line-bound option.
Routine reads use `dump-screen` and larger peeks use `dump-screen --full`, followed by local trimming.
A short viewport may expose fewer lines than requested.

Closing a pane leaves an empty tab.
Cleanup resolves and verifies the owning tab, then uses `close-tab-by-id` so both the task pane and tab disappear.
Real test cleanup uses only an isolated non-`firstmate` session and the guard in `tests/zellij-test-safety.sh`; it never calls all-session deletion commands.

## Active limits

- Zellij is experimental and explicit-only.
- All homes share one session and tab bar; scoped titles prevent cross-home identity collisions but do not create per-home visual containers.
- There is no native busy or push-event signal, so supervision uses capture/hash polling for screen changes and each harness adapter's semantic lifecycle for worker state.
  Grok alone retains its isolated rendered-tail fallback.
- There is no verified agent-process liveness signal, so a dead Zellij secondmate is reported inconclusive rather than auto-respawned.
- New-tab focus restoration has a narrow visible race.
- CLI exit status is not meaningful; a target can still disappear after structural readiness checks.
- Worktree cwd discovery requires the spawn-time marker probe.
- An ambiguous unscoped legacy title requires manual cleanup and respawn.

## Regression entry points

```sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-zellij-smoke.test.sh
```

The real smoke test uses a unique session and guarded deletion.
[`verification/runtime-backends.md`](verification/runtime-backends.md#zellij) records the active CLI matrix and lifecycle evidence.
