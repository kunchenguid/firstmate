# MiniMax Code

Verified on 2026-10-28 with MiniMax Code 0.7.1 (`mcode`, npm `@minimax-ai/code`) on macOS, model `minimax/MiniMax-M3.1-Flash`, through tmux and a named Herdr 0.9.5 lab session.
The adapter name is `mcode`, the executable Firstmate resolves.
The router owns the crewmate/scout-only boundary; primary and secondmate integration is unsupported.
[Verification evidence](../../../../../docs/verification/mcode.md) and its live guard refresh the vendor facts below.

## Operating facts

| Fact | Value |
|---|---|
| Unattended mode | The TUI has no permission flag; its mode is the global `permissionMode` key of `$MINIMAX_DATA_DIR/config.yaml` (default `~/.minimax/config.yaml`), which `/permission full` and Alt+M both write. The captain sets Full access (`bypassPermissions`) once; `../../../../../bin/fm-mcode-config.sh` refuses a launch until it reads that value and never writes it. |
| Busy state | No hook is loaded. `../../../../../bin/fm-busy-lib.sh` reads two independent signals: the terminal title mcode publishes as `<status> \| <session> \| MCode` (`Working` for the whole turn) and the spinner row `<glyph> Running <elapsed> · Option+Enter queue · Enter steer`, matched only in the slot above the composer's top rule where an idle pane draws `Message · Enter send`, so transcript text quoting the row reads neither busy nor delivered. Idle comes only from a settled title (`Ready`, `Done`, `Stopped`, `Failed`, `Error`) with no spinner row; `Needs approval`, `Needs input`, and `Needs login` read unknown. |
| Exit command | `/quit` (`/exit` is an alias), one Enter; prints `mcode --session <id>`. |
| Interrupt | One Esc cancels a running turn and prints `Interrupted after <n>s`. A turn cancelled before it produced anything prints `Stopped · message restored to the Composer.` and puts the prompt back, so the control plane follows with Ctrl+U. On an idle agent one Esc arms `Press Esc again to edit the latest message`, and a second within about 0.4 s opens `Editing the selected message · Enter replace and regenerate`, which one more Esc cancels; the control plane sends one press and dismisses that mode if it renders. |
| Skill invocation | `/<skill>` from the composer, labelled `Skill`; not exercised through `fm-send`. |
| Resume | `mcode --session <id>` and `--continue` exist; only deterministic relaunch is used. |
| Model flag | `-m`/`--model <provider>/<model>`, for example `minimax/MiniMax-M3.1-Flash`. An unknown id silently runs the default model, so the preflight refuses an id the `provider.<provider>.models` keys of the same config do not list, and launches unvalidated with a notice when that provider has no models list there. |
| Effort flag | None in the TUI (`mcode exec --effort` only); the effort axis stays in task metadata (record-and-omit), and dispatch validation rejects an effort on an mcode profile. |
| Model discovery | `/model` in the composer, or the provider `models` keys of the config file; `mcode provider list --json` lists no ids for the OAuth provider. |
| Marker | None; the node bundle sets its process title, so the anchored process name `minimax-code` identifies the adapter and outranks foreign inherited markers. |
| Trust dialogs | None on a fresh worktree. |
| Commit attribution | None observed; the live guard's worker commit carried no trailer. |

## Hook and data-directory limits

mcode loads hooks only from the user file `$MINIMAX_DATA_DIR/hooks.json` (global, needing a top-level `"enabled": true`) or a project `.minimax/hooks.json`, which does not run until the user switches it on per project path in Settings, and every task worktree is a new path.
Plugins install globally too, and no flag loads hooks or a plugin for one process, so busy state is the title and rendered-tail fallback rather than a hook.
`MINIMAX_DATA_DIR` relocates the sign-in along with the config, so a per-task data directory cannot carry the permission mode either.
The worker's sessions land in the captain's own mcode data directory, like any other mcode session.

## Herdr registration

Herdr 0.9.5 has no MiniMax Code detection, so a bare mcode pane answers `agent_not_found` and liveness would call it dead.
`../../../../../bin/fm-spawn.sh` reports the pane as agent `mcode` from source `firstmate:mcode` with state `unknown` on every readiness poll, because a report made while the shell still owns the pane is dropped when mcode starts.
Herdr keeps the registration for the whole turn and drops it when mcode exits, and a relaunch reports again.
The `unknown` state is deliberate: Herdr's native verdict never claims idle or busy for an mcode pane, and `../../../../../bin/backends/herdr.sh` lets the process view decide liveness for that one stateless registration.
The registration is also what exposes the pane's terminal title to the busy read.

## Composer and steering

mcode draws a bare `›` composer row between two rules, with a `Message · Enter send` header above it that reads `Prompt`, `Command`, or `Skill` once text is typed, and keeps the terminal cursor on the composer row.
Its placeholder `Ask Mcode to do anything` and its next-message suggestion (header `Suggested next message · Tab accept`) are truecolor 38;2;173;173;173 after a reverse-video cursor cell, while typed text is the default foreground and a typed slash command is bold 38;2;104;192;255, just under the placeholder's luminance.
`../../../../../bin/fm-composer-lib.sh` therefore strips that exact colour, never a luminance ceiling, and only for a screen whose identity is `mcode`: the tmux probe's `minimax-code` foreground process, or the Herdr registration read lazily through `mcode=ask`.
The launch clears `NO_COLOR` and pins `COLORTERM=truecolor` so those colours stay exact.
`../../../../../bin/fm-spawn.sh` refuses an mcode launch on zellij, cmux, orca, paseo, rex, tern, and t3code, which supply neither that identity nor the title.
After Ctrl+U clears a typed slash command, mcode 0.7.1 can leave its slash popup drawn; the composer then reads unknown and steering defers until the next redraw.
Text sent while a turn runs steers it, and Option+Enter queues instead.
Submit confirmation passes `mcode` to the delivery matcher only for a pane identified as mcode; the spinner row is not part of the harness-less union.

## Primary integration

No primary Stop guard, watcher protocol, pre-tool protection, or session-start contract was verified for mcode.
Do not launch a primary or secondmate with this adapter.
ACP (`mcode acp`), headless `mcode exec`, and quota-provider integration remain separate follow-ups.
