# Polytoken CLI

Verified on 2026-10-07 with Polytoken CLI 0.8.19 as a crewmate/scout adapter (the TUI-pane-plus-REST-control hybrid the captain approved the same day).
The router owns the crewmate/scout-only boundary; primary and secondmate integration is Phase 2 follow-up.
[Verification evidence](../../../../../docs/verification/polytoken.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | `pre_user_prompt` and `pre_model_turn` open, `stop` closes, through the generation-bound writer; `../../../bin/fm-busy-lib.sh` owns trust. A REST-cancelled turn emits no `stop` (verified live), so the control plane writes the close itself as `idle fm-interrupt` after the typed settle. `post_model_turn` fires per model response - mid-turn, between tool phases (verified live) - and is deliberately never wired as a close. |
| Exit command | `/quit` through the shared slash-palette settle: Enter accepts the preselected row, the TUI exits, the pane falls to its shell, the daemon deletes its credential and exits on its own shortly after (all verified live). `POST /terminate` is NOT used on attached sessions: it wedges the TUI on an SSE reconnect error for ~20s and records a crash log (verified live). |
| Interrupt | No TUI chord exists at all (`print tui-command-actions` has no cancel action in Prompt scope; a single Escape does nothing; Escape Escape opens the rewind picker). Interrupt is `POST /turn/cancel` on the session daemon, answering `{"status":"cancel_requested","generation":N}`, with `GET /sync`'s `turn: null` as the typed settle. Firstmate never sends interrupt keys. |
| Skill invocation | `@skill:<name>` in prompt text and the model's `skill` tool; no slash-command skill form. |
| Resume | `polytoken continue --no-attach <session-id>` restarts from history on a new port with a rotated credential (verified by the scout). Firstmate's deterministic relaunch-from-brief remains the recovery path; the control plane relaunches fresh sessions. |
| Model flag | `--model <ref>`, exactly the selectable references `polytoken print models` lists, including effort variants like `zai/glm-5.3-flash(low)`. An unlisted model on a reachable listing refuses the spawn; an unreachable listing launches unvalidated with a notice. |
| Effort flag | None separate: effort rides the model reference as `<model>(<effort>)` when that form is listed, else it is recorded in task metadata and omitted (record-and-omit). |
| Model discovery | `polytoken print models` (one selectable reference per line); `polytoken models` for the full human report. |
| Marker | None; the daemon's anchored `polytoken` comm in tool-subprocess ancestry identifies the adapter (a tool subprocess's parent IS the daemon, verified live), and a structural polytoken ancestor outranks foreign inherited markers. |
| Trust dialogs | None at launch: the permission posture comes from the generated config dir's `default_permission_matcher: bypass`, and the first-start license dialog is a BLOCKER by captain decision (2026-10-07) - `--accept-license-terms` is never passed, and the readiness gate fails loudly on a pane that never starts processing its brief. |
| Imported config | The worktree `.polytoken/` project layer (hooks and facets) plus the generated per-task config dir, which fully replaces the global config (verified live: a `version: 4`-only project config.yaml fails startup with zero providers, and no `--global-config-dir` reaches the daemon). |
| Commit attribution | The shared `state/<id>.git-hooks` commit-msg strip covers polytoken like every launched runtime. |

## Worker lifecycle limits

Hook handlers receive the event JSON on stdin and `POLYTOKEN_*` variables but NO argv (verified live: a handler written as `<script> <arg>` runs with `$*` empty), so every firstmate hook is a generated self-contained script referenced by absolute path.
A failing hook breaks the turn (verified live: a pre_model_turn hook exiting 1 errors the whole turn), so every generated hook wraps its writer in `|| true` and exits 0.
A project hook that negates a global hook by name fails daemon startup (the scout's finding), so per-task hooks are self-contained and negate nothing.
Enter while a turn runs queues the text for the next agent pause - `Queued for the next agent pause` - exactly like OpenCode (verified live), and the queued text renders above the composer separator.
There is no verified composer-clear key: Ctrl+Shift+Y copies the prompt but leaves it in the composer (verified live), so text is only ever typed into a composer proven empty and pending text is never typed onto.
Ctrl+C ends the session; Escape Escape opens the rewind picker; neither is ever sent by firstmate.
A TUI-attached daemon stays alive while idle (verified minutes-scale) and exits on its own after its session ends, so the pane design needs no daemon-lifetime supervision.
The daemon imposes no cap on consecutive `stop`-hook `continue` outcomes (verified live: five forced continuations all ran), so any Phase 2 turn-end guard must self-bound with its own latch.

`../../../../../bin/fm-spawn.sh` owns autonomy (the generated config dir), the worktree hook and facet wiring, session discovery into task metadata (`polytoken sessions --format json` with the launch's `--config-dir` and `--sessions-dir`), the foreign-marker clearing loop, and the readiness gate.
`../../../../../bin/fm-polytoken-lib.sh` owns every generated artifact and the REST control core.
`../../../../../bin/fm-control-lib.sh` owns the REST interrupt transport (`fm_control_interrupt_transport`), the `/quit` exit command, and the wiring tables.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified separated composer shape: a full-width separator pair over one blank or pending content row with a footer below.
The shared classifier reaches it through the Pi-shape identity conjunction, with polytoken as the second verified owner of that shape: an idle pane proves an empty composer and a working pane keeps the strict `unknown` so the busy-queue conversion stays honest.
The busy footer token is the pinned `Running for <elapsed>` row with a leading space (verified live); `Completed in`, `Errored after`, and `Canceled after` are the distinct turn-end rows and never match it.
The token is also part of the harness-less default union, for the same reason agy's is: a submit's only turn-started acknowledgement on this pane is the busy footer.
The delivery guard is never a busy-state source; recorded state comes from the polytoken-hook fold.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract is verified for polytoken; Phase 1 verified only the crewmate/scout adapter.
Do not launch a primary or secondmate with this adapter.
The complete lifecycle hook surface (session_start, post_clear, pre/post_compaction, stop-continue) and the REST event plane exist and were verified by the scout, so Phase 2 is follow-up work rather than new vendor surface.
