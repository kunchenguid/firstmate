# Antigravity CLI (agy)

Google's `agy` TUI, verified 2026-09-02 on agy 1.1.24, macOS arm64, under Herdr 0.8.2.
The router owns agy's task-kind boundary: it is a **crewmate and scout adapter only**, the same limited scope as Muse.
`../../../bin/fm-spawn.sh` refuses a `--secondmate` launch on it and `../../../bin/fm-control-lib.sh` refuses that kind before stopping anything.
Launch shape: `agy --dangerously-skip-permissions -i "<brief>"`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Single native `agy` on `PATH`; `ps -o comm=` reports the bare name with no version or path component. |
| Launch | `-i/--prompt-interactive` carries the brief. A POSITIONAL prompt is rejected with `Error: unexpected argument`; only `-p/--print`, `-i`, or stdin are read. |
| Autonomy | `--dangerously-skip-permissions`, footer shows `accept-edits`, verified unattended for file writes and shell commands. |
| Turn end | Global `Stop` hook, and **only a payload with `fullyIdle: true` counts**. See "Turn end" below; this is the single most important fact about this adapter. |
| Busy | None. agy has no worker-state source and classifies `unknown agy-unverified`; `../../../bin/fm-busy-lib.sh` owns why. |
| Interrupt | Single Escape; composer is left EMPTY, so no clear key follows. |
| Exit | `/exit` plus Enter; prints `Resume with -c (or command below): agy --conversation=<id>` and the pane returns to the shell. |
| Resume | `agy --conversation=<id>`, or `-c` for the most recent. Firstmate uses `relaunch` instead, per the control plane's no-`resume`-verb rule. |
| Marker | `ANTIGRAVITY_AGENT=1` on child/tool processes, plus `ANTIGRAVITY_LS_VERSION`, `ANTIGRAVITY_CONVERSATION_ID`, `ANTIGRAVITY_PROJECT_ID`. Sets neither `CLAUDECODE` nor `GROK_AGENT`. |
| Trust | Dialog `Do you trust the contents of this project?` with `Yes, I trust this folder` preselected; one Enter resolves it. `--dangerously-skip-permissions` does NOT suppress it. |
| Composer | Prompt `>` between two horizontal rules `───`, no box. Classifies `unknown`, never `empty`; see "Composer" below. |
| Model | `--model <id>`; discover with `agy models`, which answers without opening a session. |
| Effort | `--effort low\|medium\|high`. `xhigh` and `max` are omitted rather than passed; `../common/model-and-effort.md` owns fallback, and the generic ceiling is `high` as it is for Grok. |
| Quota | No `spendPriority`; see "Quota" below. |

## Turn end: only `fullyIdle: true`

agy pushes a long-running command into the background after about ten seconds, **ends the turn** saying it will wait, then wakes itself and ends a SECOND turn once the work lands.
Only the second carries `fullyIdle: true`.

This is not an edge case, it is how agy runs any long command, which is exactly what a validation pipeline is.
Measured on a real 90-second command: a `fullyIdle: false` Stop arrived with `workspacePaths` **already populated**, 81 seconds before the true end.
A Grok-shaped hook keyed on the workspace alone would have reported the run finished while it was still going, and a ship task would have been treated as complete with its pipeline mid-flight.

Every other Stop is an event to ignore, and there are several: agy fires one while blocked on its own trust dialog (with `workspacePaths` empty) and another on an interrupt.
`protojson` omits default values, so a false `fullyIdle` can arrive as an ABSENT key rather than an explicit `false`; the gate tests `== true` and never uses jq's `//`, which treats `false` as null.

Installation differs from Grok's in one way that matters.
agy's global hooks live in ONE shared `hooks.json` keyed by hook name, which is the operator's own file, so firstmate installs a **plugin** instead: `${FM_AGY_CONFIG_HOME:-$HOME/.gemini/config}/plugins/fm-turn-end/`.
agy discovers and enables it on its own, and its `config.json` was verified byte-identical afterwards, so nothing firstmate writes can clobber operator configuration.
Everything else is Grok's guarded pattern unchanged: a `.fm-agy-turnend` worktree pointer, a private registry token, a hook that is a silent no-op for every non-firstmate agy session, and teardown that retires the per-task entries.
The hook needs `jq`, and the spawn refuses naming that requirement rather than installing a hook that could never fire.
Because the hook's working directory is the plugin directory rather than the workspace, the worktree can only come from the payload's `workspacePaths`.

## Busy state and the composer

agy has **no worker-state source**, and this is a deliberate, evidence-backed gap rather than an omission.

Its rendered footer cannot separate a waiting turn from a finished one: while agy waits on backgrounded work it renders the same `? for shortcuts` as it does once the turn is genuinely over, and the busy footer `esc to cancel` appears only while tokens are actually streaming.
A Grok-shaped regex arm would therefore report a working agent as idle for minutes, which is the one verdict the busy contract never permits.
Its `Stop` hook cannot be a semantic writer either: `fullyIdle: false` Stops must be ignored, so a source that only ever writes idle on `fullyIdle: true` would leave an interrupted turn's busy record with nothing to settle it.
`PreInvocation` fires once per model invocation rather than once per turn (measured: ten across two turns), so pairing it with `Stop` would not close that gap.

The consequence is that agy classifies `unknown agy-unverified` everywhere except a natively streaming Herdr turn, which the native arm still proves busy.
`esc to cancel` IS registered in `../../../bin/fm-composer-lib.sh` as a DELIVERY signature, which is a positive-only submit acknowledgement whose worst case is one extra retry; it collides with no other adapter's signature.

The composer classifies `unknown`, never `empty`, because the `>` prompt sits between horizontal rules that the shared classifier does not recognize as a container.
No admission rule was added, so this stays **degraded but safe**: the steering doorbell is advisory and only gives up on a proven `pending`, and the two consumers that require `empty` are away-mode injection (which writes to firstmate's own pane) and Kimi's startup readiness gate (which does not apply).

## Quota

`quota-axi` reads agy through `cli-rpc` but marks its windows `unresolved_windows`, so agy has **no `spendPriority`** and cannot take part in a quota-balanced profile array.
Until that changes on the `quota-axi` side, agy is usable only as an explicit per-task choice.

## Verified boundaries

Everything above was measured under Herdr. Do not infer beyond it:

- **tmux is unverified.** The process name `agy` is a kernel-level fact confirmed directly through `ps`, and it is registered in `../../../bin/backends/tmux.sh` because that classifier serves crewmate liveness and the control plane's exit and relaunch proofs, not only secondmates. No other tmux behaviour was checked: not the composer, not the footer under tmux capture.
- One conversation and one model (Gemini 3.7 Flash). The Claude and GPT-OSS models inside agy were not tested.
- Husk recovery, relaunch, and durable steering-inbox delivery were not tested.
- agy is deliberately absent from `../../../bin/fm-session-lock-lib.sh`'s harness identity tables, which are the PRIMARY-session surface. Adding it there would imply a primary supervision protocol that does not exist.
- Exit was verified from a stopped agent. The control plane interrupts a busy agent before submitting the exit command, so the busy path runs through interrupt-then-exit rather than a bare exit.

`../../../docs/verification/agy.md` holds the dated record and the exact commands, and `../../../tests/fm-agy-surface-live-e2e.test.sh` is the opt-in guard that refreshes it.
