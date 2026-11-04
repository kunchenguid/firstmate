# Polytoken CLI

Polytoken is a crewmate/scout adapter using a TUI pane and per-session REST control.
Capability discovery uses the installed binary; no Polytoken release number gates or warns on dispatch.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/polytoken.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | `pre_user_prompt` and `pre_model_turn` open, `stop` closes, through the generation-bound writer; `../../../bin/fm-busy-lib.sh` owns trust. A REST-cancelled turn emits no `stop` (verified live), so the control plane writes the close itself as `idle fm-interrupt` after the typed settle, unless a `pre_user_prompt` written since the pre-cancel snapshot shows a queued prompt reopened the turn or `GET /sync` shows a turn running again right before the write (`fm_polytoken_interrupt_task`). `post_model_turn` fires per model response - mid-turn, between tool phases (verified live) - and is deliberately never wired as a close. |
| Exit command | `/quit` through the shared slash-palette settle: Enter accepts the preselected row, the TUI exits, the pane falls to its shell, the daemon deletes its credential and exits on its own shortly after (all verified live). `POST /terminate` is NOT used on attached sessions: it wedges the TUI on an SSE reconnect error for ~20s and records a crash log (verified live). |
| Interrupt | No TUI chord exists at all (`print tui-command-actions` has no cancel action in Prompt scope; a single Escape does nothing; Escape Escape opens the rewind picker). Interrupt is `POST /turn/cancel` on the session daemon, answering `{"status":"cancel_requested","generation":N}`, with `GET /sync`'s `turn: null` as the typed settle. Firstmate never sends interrupt keys. |
| Skill invocation | `@skill:<name>` in prompt text and the model's `skill` tool; no slash-command skill form. |
| Resume | `polytoken continue --no-attach <session-id>` restarts from history on a new port with a rotated credential (verified by the scout). Firstmate's deterministic relaunch-from-brief remains the recovery path; the control plane relaunches fresh sessions. |
| Model flag | `--model <ref>`, exactly the selectable references `polytoken print models` lists, including effort variants like `zai/glm-5.3-flash(low)`. Canonical launches require concrete model and effort axes; an unlisted model or unreachable catalog refuses the spawn, and a relaunch onto polytoken refuses the same profile, the whitespace handler path below, and a hook layer firstmate did not generate before stopping the running worker. |
| Effort flag | None separate: `fm_polytoken_model_ref` in `bin/fm-polytoken-lib.sh` owns nearest-level mapping into `<model>(<effort>)`; task metadata retains the requested axis. |
| Model discovery | `polytoken print models` (one selectable reference per line); `polytoken models` for the full human report. |
| Marker | None; the daemon's anchored `polytoken` comm in tool-subprocess ancestry identifies the adapter (a tool subprocess's parent IS the daemon, verified live), and a structural polytoken ancestor outranks foreign inherited markers. |
| Trust dialogs | None at launch: the permission posture comes from the generated config dir's `default_permission_matcher: bypass`, and the first-start license dialog requires an operator decision - `--accept-license-terms` is never passed, and the readiness gate fails loudly on a pane that never starts processing its brief. |
| Imported config | The worktree `.polytoken/` project layer (hooks and facets) plus the generated per-task config dir, which fully replaces the global config (verified live: a `version: 4`-only project config.yaml fails startup with zero providers, and no `--global-config-dir` reaches the daemon). |
| Commit attribution | The shared `state/<id>.git-hooks` commit-msg strip covers polytoken like every launched runtime. |

## Worker lifecycle limits

Hook handlers receive the event JSON on stdin and `POLYTOKEN_*` variables but NO argv (verified live: a handler written as `<script> <arg>` runs with `$*` empty), so every firstmate hook is a generated self-contained script referenced by absolute path, and a state dir whose busy-script path contains whitespace refuses polytoken wiring at spawn because the handler's splitting rules are unverified.
A failing hook breaks the turn (verified live: a pre_model_turn hook exiting 1 errors the whole turn), so every generated hook wraps its writer in `|| true` and exits 0.
A project hook that negates a global hook by name fails daemon startup (the scout's finding), so per-task hooks are self-contained and negate nothing.
Enter while a turn runs queues the text for the next agent pause - `Queued for the next agent pause` - exactly like OpenCode (verified live), and the queued text renders above the composer separator.
There is no verified composer-clear key: Ctrl+Shift+Y copies the prompt but leaves it in the composer (verified live), so text is only ever typed into a composer proven empty and pending text is never typed onto.
Ctrl+C ends the session; Escape Escape opens the rewind picker; neither is ever sent by firstmate.
File tools are confined to the worktree plus session-granted paths, and no launch-time grant exists ([evidence](../../../../../docs/verification/polytoken.md#task-directory-file-access)): direct `file_read` and `file_write` reach the Firstmate task directory under the generated `bypass` matcher, but `tool_flow` cannot, so the worker facet points the model at the direct tools or the shell for that directory.
A TUI-attached daemon stays alive while idle (verified minutes-scale) and exits on its own after its session ends, so the pane design needs no daemon-lifetime supervision.
The daemon imposes no cap on consecutive `stop`-hook `continue` outcomes (verified live: five forced continuations all ran), so any future primary turn-end integration would need its own bounded latch.

`../../../../../bin/fm-spawn.sh` owns autonomy (the generated config dir), the worktree hook and facet wiring, session discovery into task metadata (`polytoken sessions --format json` with the launch's `--config-dir` and `--sessions-dir`), the foreign-marker clearing (the fixed `env -u` set, including the generic `AGENT`, plus the ORCA_*/FM_ loop), and the readiness gate.
A fresh polytoken spawn that fails and leaves no task record also closes the endpoint it opened before launch, removes its wiring, task temp root, and staged launch file (only after retaking the per-id spawn lock with no task record present; a concurrent spawn of the same id holding the lock leaves them in place), and drops its slot claim even after metadata publication; every other harness keeps the shared abort behavior.
`../../../../../bin/fm-polytoken-lib.sh` owns every generated artifact and the REST control core.
`../../../../../bin/fm-control-lib.sh` owns the REST interrupt transport (`fm_control_interrupt_transport`), the `/quit` exit command, and the wiring tables.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified separated composer shape: a full-width separator pair over one blank or pending content row with a footer below.
The shared classifier reaches it through the Pi-shape identity conjunction, with polytoken as the second verified owner of that shape: an idle pane proves an empty composer and a working pane keeps the strict `unknown` so the busy-queue conversion stays honest.
The busy footer token is the pinned `Running for <elapsed>` row with a leading space (verified live); `Completed in`, `Errored after`, and `Canceled after` are the distinct turn-end rows and never match it.
The token is read only under the recorded polytoken harness and the polytoken composer identity, never through the harness-less default union, so a pane with no recorded harness never reads it as busy; the submit cores scope their idle-to-busy and busy-queue reads to polytoken only when the pane's composer identity (tmux) or native identity (herdr) names polytoken.
The delivery guard is never a busy-state source; recorded state comes from the polytoken-hook fold.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract is verified for Polytoken.
Do not launch a primary or secondmate with this adapter.
The worker facet removes `switch_facet`, `handoff_plan`, `subagent`, and `message_subagent` from its tool registry so a facet change or delegation cannot substitute a routed model for the explicit worker pin.
