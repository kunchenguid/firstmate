# Bob CLI

Verified for crewmate/scout work only: a full worker run on IBM Bob CLI 2.0.9 and 2.0.6, plus identity, interrupt, exit, and relaunch on 2.0.6.
Not verified as a secondmate: bob has no primary supervision protocol, so `../../../bin/fm-spawn.sh` refuses `--secondmate` on it, the same gap that scopes kiro, muse, and rovo to crewmate/scout.
A Bob session is recognized for harness detection and the session lock so firstmate's own commands run from one identify Bob instead of its launcher and take the generic supervision fallback; it is no supervision-branch pin, and [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#bob-session-identity-and-session-lock) owns that evidence.

## Operating facts

| Fact | Value |
|---|---|
| Launch | Bare `bob chat --auto-approve --trust --workspace <worktree>`: `bob chat` has no positional prompt, so the brief is delivered after the TUI attaches, the kimi/rovo launch-then-send shape (see "Launch and readiness"). |
| Models and effort | No `--model` or `--effort` flag; both axes are recorded in task metadata and never reach the launch command. |
| Trust | `--auto-approve` and workspace hooks are silently suppressed in an untrusted folder, so `../../../bin/fm-spawn.sh` pre-registers the worktree in `~/.bob/trustedFolders.json` through `../../../bin/fm-bob-trust.sh` and refuses the spawn if that fails. |
| Busy state | `bob-hook`, bob's only state source: the per-task `.bob/settings.json` in the worktree carries a `UserPromptSubmit` hook that opens a turn and a `Stop` hook that closes it and keeps the turn-ended touch. Bob has no `StopFailure` or `SessionEnd` equivalent, so an abnormal turn end leaves the record busy until the next prompt; `../../../bin/fm-busy-lib.sh` owns the disclosure. |
| Exit command | `/exit`. |
| Interrupt | Single Escape, which ends the running tool call (verified live, 2.0.6); `Stop` does not fire on it, so `../../../bin/fm-control.sh` preserves the adapter-owned busy record and `../../../bin/fm-control-lib.sh` records the acknowledgement source as `none`. |
| Identity | `BOB_SESSION=1`, set by bob's session process for its tool subprocesses, named by `../../../bin/fm-harness.sh` after the claude and pi markers, plus the installed entry script, owned by `../../../bin/fm-bob-process-lib.sh`; the npm package is `@ibm/bob` at 2.0.9 and `bobshell` at 2.0.6. |
| Locale | Bob translates its UI from `LC_ALL`, `LC_MESSAGES`, then `LANG`, so the composer read proves an empty row from styling rather than from the placeholder wording. |
| Self-update | Bob's default `bobShell.autoUpdate` runs `npm install -g --force` against whichever node is active, which can write outside the running install; it reads only the user settings, so firstmate cannot pin it per task and the operator sets it in `~/.bob/settings/settings.json`. |
| Composer | `❯` row between two `─` rules with the idle placeholder `Build Anything, @ for context, / for commands, $ for skills` in a 256-colour grey; `../../../bin/fm-composer-lib.sh` owns the classifier. Bob hides its terminal cursor on the last pane row, so the tmux composer read ignores the cursor row when the caller names the harness bob. |

## Launch and readiness

The launch template clears `BOB_SESSION` (bob's source throws on a nested session), `CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, and `FM_PI_HARNESS` inline, and the shared outer wrap clears `CURSOR_AGENT`, `CURSOR_INVOKED_AS`, and `GEMINI_CLI`, so neither a foreign primary marker nor a nested-session marker reaches the worker.
The spawn refuses when the project tracks its own `.bob/settings.json` or `.bob/launch-brief.md`, because firstmate writes to those paths and would replace the committed content, and when `.bob` is a symlink, because those writes would leave the worktree.
The spawn also refuses a missing `bob` executable before it provisions the worker.
A relaunch onto bob applies the same refusals and the trust registration before the current worker stops.
It also copies the brief to `.bob/launch-brief.md` in the worktree, because bob blocks file reads outside its workspace by default; both `.bob/` files are kept out of git through the worktree exclude and removed when the worktree returns to its pool.
After launch, `../../../bin/fm-spawn.sh` runs two gates in the rovo/kimi shape:

1. **Readiness gate** (`bob_wait_for_ready`): poll until the composer reads empty; a pane whose composer is never recognized fails the spawn loudly after `FM_BOB_READY_POLLS` polls.
   On tmux a visible cursor reads as not ready, because a relaunch reuses the pane and the previous composer stays on screen until Bob repaints; Herdr has no such read and its Bob path has no live evidence yet.
2. **Submit and delivery gate** (`bob_wait_for_delivery`): type `Brief <busy-gen>: read <worktree>/.bob/launch-brief.md and follow it exactly.` and confirm delivery from bob's own `UserPromptSubmit` hook record, or from this launch's pointer in the transcript above an empty composer.

`../../../tests/fm-bob-harness.test.sh` pins the launch and gates against a fake `tmux` and fake `bob`; `FM_BOB_SIGNALS_LIVE=1 ../../../tests/fm-bob-signals-live-e2e.test.sh` is the live guard for the vendor-rendered facts, runs without a credential, and is what to rerun after a Bob upgrade.
