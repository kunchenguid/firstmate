# Bob CLI

Verified on IBM Bob CLI 2.0.9 for crewmate/scout work only.
Not verified as a secondmate: bob has no primary supervision protocol, so `../../../bin/fm-spawn.sh` refuses `--secondmate` on it, the same gap that scopes kiro, muse, and rovo to crewmate/scout.
Bob as a firstmate primary is recognized for harness detection and the session lock only; [`runtime-backends.md`](../../../../docs/verification/runtime-backends.md#bob-primary-identity-and-session-lock) owns that evidence.

## Operating facts

| Fact | Value |
|---|---|
| Launch | Bare `bob chat --auto-approve --trust --workspace <worktree>`: `bob chat` has no positional prompt, so the brief is delivered after the TUI attaches, the kimi/rovo launch-then-send shape (see "Launch and readiness"). |
| Models and effort | No `--model` or `--effort` flag; both axes are recorded in task metadata and never reach the launch command. |
| Trust | `--auto-approve` and workspace hooks are silently suppressed in an untrusted folder, so `../../../bin/fm-spawn.sh` pre-registers the worktree in `~/.bob/trustedFolders.json` through `../../../bin/fm-bob-trust.sh` and refuses the spawn if that fails. |
| Busy state | `bob-hook`, bob's only state source: the per-task `.bob/settings.json` in the worktree carries a `UserPromptSubmit` hook that opens a turn and a `Stop` hook that closes it and keeps the turn-ended touch. Bob has no `StopFailure` or `SessionEnd` equivalent, so an abnormal turn end leaves the record busy until the next prompt; `../../../bin/fm-busy-lib.sh` owns the disclosure. |
| Exit command | `/exit`. |
| Interrupt | Single Escape; `Stop` does not fire on it, so `../../../bin/fm-control.sh` preserves the adapter-owned busy record and `../../../bin/fm-control-lib.sh` records the acknowledgement source as `none`. |
| Environment marker | `BOB_SESSION=1`, set by bob's session process for its tool subprocesses; `../../../bin/fm-harness.sh` names bob from it after the claude and pi markers. |
| Composer | `❯` row between two `─` rules with the idle placeholder `Build Anything, @ for context, / for commands, $ for skills` in a 256-colour grey; `../../../bin/fm-composer-lib.sh` owns the classifier. Bob hides its terminal cursor on the last pane row, so the tmux composer read ignores the cursor row when the caller names the harness bob. |

## Launch and readiness

The launch template clears `BOB_SESSION` (bob's source throws on a nested session), `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` inline, and the shared outer wrap clears `CURSOR_AGENT`, `CURSOR_INVOKED_AS`, and `GEMINI_CLI`, so neither a foreign primary marker nor a nested-session marker reaches the worker.
The spawn refuses when the project tracks its own `.bob/settings.json`, because firstmate writes its hook file to that path and would replace the committed settings.
It also copies the brief to `.bob/launch-brief.md` in the worktree, because bob blocks file reads outside its workspace by default; both `.bob/` files are kept out of git through the worktree exclude.
After launch, `../../../bin/fm-spawn.sh` runs two gates in the rovo/kimi shape:

1. **Readiness gate** (`bob_wait_for_ready`): poll until the composer reads empty; a pane whose composer is never recognized fails the spawn loudly after `FM_BOB_READY_POLLS` polls.
2. **Submit and delivery gate** (`bob_wait_for_delivery`): type `Read the brief at <worktree>/.bob/launch-brief.md and follow it exactly.` and confirm delivery from bob's own `UserPromptSubmit` hook record, or from the pointer in the transcript above an empty composer.

`../../../tests/fm-bob-harness.test.sh` pins the launch, the readiness-before-pointer order, loud failure on unconfirmed delivery, the tracked-settings refusal, and the secondmate refusal against a fake `tmux` and fake `bob`; the readiness and delivery gates, `/exit`, and the Escape interrupt have not been run against a real Bob TUI, so a live run is the only evidence for them.
