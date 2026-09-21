# Devin CLI

Cognition's `devin` TUI, verified end to end on 2026-09-21 with devin 3000.10.31 on Linux through the tmux backend and re-verified on 3000.11.1.
Launch shape: `devin --config <firstmate-owned task config> --permission-mode bypass --model <slug|alias|id> -- "<brief>"`.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no devin wake protocol.
`../../../../../docs/verification/devin.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `devin` from `PATH`, refused if absent; a natively-compiled single binary, so the live process name is exactly `devin` with `argv[0]=devin` or the versioned install path. |
| Launch | `devin --config <task config> --permission-mode bypass --model <id> -- "<brief>"`, with the resolved absolute binary; the positional brief auto-submits with no extra Enter. The spawn pre-registers the worktree in devin's trust store first, then waits for the semantic busy verdict (answering the workspace-trust dialog if it renders anyway) before reporting success. |
| Busy state | Semantic `devin-hook`: `SessionStart` and `UserPromptSubmit` open a turn, `Stop` and `SessionEnd` close it. `Stop` fires on normal completion only, never on a manual interrupt, so an interrupted turn keeps its busy record until the next hook event, the Claude shape. |
| Rendered tail | Not a state source. The running turn shows a transient `Typing` / `Running tools · <n>s (esc twice to interrupt)` row, and the composer keeps the submitted prompt rendered bright while the turn runs; neither is ever a signal. |
| Turn end | `Stop` fires once per normal turn, carrying `stop_hook_active`, `last_assistant_message`, `session_id`, and `prompt_id`. On a cancelled turn no `Stop` fires. |
| Exit | `/exit` (alias `/quit`; bare `exit`/`quit` also work), one Enter, exit status 0; `SessionEnd` fires with `reason: prompt_input_exit`. `Ctrl+C` cancels input or the turn and `Ctrl+D` exits on an empty buffer. |
| Interrupt | Two SEPARATED `Escape` presses, which print `Canceled. What should Devin do?` and leave an idle composer with no repollution, so no clear key follows. A single `Escape` alone does not cancel (the running turn names the key itself: `esc twice to interrupt`), and neither does a back-to-back pair in one key-sending call; pause between the presses. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--permission-mode bypass` (a verified alias of the dangerous mode) auto-approves tool calls for the run; the footer renders `(bypass permissions on)` while it is on. |
| Marker | None; a live TUI carries no identity variable (`DEVIN_*` values are inherited launch configuration, `CHISEL_SESSION_DB` is a sessions-db path, and `AI_AGENT=devin_*_agent` is ambient multiplexer state inherited fleet-wide from any multiplexer started under devin, never promoted). |
| Resume | `-c/--continue` and `-r/--resume` exist but carry no verified pane-resume contract; use deterministic relaunch. |
| Model | `--model <slug|alias|id>` with the family slug, alias, or full model id from `devin models list --format json` (for example `opus`, `swe`, `claude-opus-5-medium`); `bin/fm-spawn.sh` refuses a requested value a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable or hung listing launches unvalidated with a notice. |
| Effort | None. `devin --help` on 3000.10.31 exposes no effort, reasoning, or thinking flag (`Alt+T` cycles it interactively only), so `references/common/model-and-effort.md`'s record-and-omit contract applies. |
| Composer | Bare `❭` (U+276D) glyph row; the shared classifier reads it as `empty` with the dim placeholder stripped, `pending` with typed text. Idle placeholder `Ask Devin to build features, fix bugs, or work on your code`, busy placeholder `Guide Devin while it works`. |
| Trust dialog | `Do you trust the authors of this directory?` with the safe `1 Yes, trust` preselected; one Enter answers it. |

## Trust, and where the decision persists

Every task worktree is a path devin has never seen, so an unregistered launch parks on `Do you trust the authors of this directory?` before the brief is ever read, and the dialog displays the resolved path.
A `trusted_paths` entry in devin's data-store `trusted_workspaces.json` (`${XDG_DATA_HOME:-$HOME/.local/share}/devin/cli/trusted_workspaces.json`, verified XDG-aware) written ahead of launch suppresses it, so `../../../../../bin/fm-spawn.sh` pre-registers the worktree through `../../../../../bin/fm-devin-trust.sh` before launch, the claude shape: the helper refuses anything but a linked worktree of the spawning project, records both the logical pane path and its resolved form when they differ, and preserves every other key in the store.
The post-launch readiness gate is the backstop: it answers a dialog that renders anyway with a single Enter, then requires the `busy devin-hook` verdict before the spawn reports success, and on a path that was not pre-registered it never counts a busy verdict as ready until the dialog has been answered.
A pane whose brief cannot be confirmed to run in the worktree fails the spawn, records the failure in the task status, and closes the endpoint.
Never steer into a pane still showing the dialog; a spawn that reported success has already cleared it.

## Credential precondition

A verified devin worker ran signed in (`devin auth status` reports `Logged in`) with no key export and no dialog.
The unauthenticated failure mode was not observed, so treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process name `devin`, never `*devin*`.
No environment marker is promoted: `DEVIN_PERMISSION_MODE` observed on a live TUI is inherited launcher state, `CHISEL_SESSION_DB` is a path, not an identity, the muse precedent, and `AI_AGENT=devin_*_agent` (observed live on 3000.11.1) is ambient multiplexer state - a whole fleet under a devin-started multiplexer inherits it, so promoting it would rename every harness on that fleet.
devin is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, and rovo are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` writes a firstmate-owned per-task config file at `state/<id>.devin-config.json` with four hooks bound to the minted busy generation, and the launch reaches it through devin's `--config` flag.
The file is the launching user's own user config copied through opaquely (account, permissions, and existing hooks all survive) with firstmate's hooks merged into its `hooks` key; a present-but-unparseable user config refuses the spawn rather than silently dropping the operator's settings.
This wiring belongs only to the canonical exact `devin` adapter template, which receives busy-state wiring, the turn-end hook, and trusted busy state together.
A raw devin-shaped launch is an unverified escape hatch: it receives no busy-state wiring or turn-end hook and therefore has no trusted busy state.
Nothing is written into the worktree and the captain's own user config is never mutated.
Hook layers MERGE across devin's config sources rather than overriding, so a project's own hooks still run alongside firstmate's; both were observed firing for one turn.
`../../../../../bin/fm-teardown.sh` removes the file, so nothing survives into a pooled worktree.
`UserPromptSubmit` records busy, `Stop` records idle and keeps the `state/<id>.turn-ended` touch as the watcher NOTIFICATION, and `SessionEnd` records idle so an abnormal end cannot strand a busy record.
`SessionStart` records busy as lifecycle evidence that the session started under firstmate's config; the spawn's readiness gate requires the `busy devin-hook` verdict (never the `fm-spawn` seed) before reporting success.
Each hook command tolerates a refused event, so a stale-generation writer can never break devin's own lifecycle, and each stays silent on stdout because devin's hook contract requires no output object.

## Submit behavior

A typed Enter is occasionally swallowed with the text left unsubmitted; a further Enter submits the pile, and the shared submit core's Enter-only retries (never retype) resolve it wherever the composer verdict reads `pending`.
A multi-row unsubmitted composer can read `unknown` under the strict blank-row rule rather than `pending`, so a single ring's Enter is best-effort and the watcher's re-ring ladder owns redelivery; the doorbell line is constant and idempotent, so a duplicated ring is harmless.
Enter on an empty composer while a turn runs interrupts it (vendor changelog), so steering a busy pane must always carry text; the doorbell line is typed before its Enter and never sent bare.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no devin protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
