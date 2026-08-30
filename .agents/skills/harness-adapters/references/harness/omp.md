# OMP

Verified on 2026-08-30 with `omp/18.0.11`.
OMP is a 186 MB compiled binary, distinct from the Node-bundled Pi executable.
Its help advertises `PI_SMOL_MODEL`, `PI_SLOW_MODEL`, and `PI_PLAN_MODEL`, and its installed Herdr integration uses the Pi-shaped extension API, so the shared lifecycle lineage is evidenced without treating the programs as identical.

## Operating facts

| Fact | Value |
| --- | --- |
| Launch | One positional launch brief, `--auto-approve`, and a per-task `-e` extension outside the worktree. |
| Busy state | The per-task extension marks `agent_start` busy and normally debounces `agent_end` to idle. Retryable provider-error ends remain busy for OMP's observed retry grace and then become unknown if no retry starts. Unlike Pi, OMP exposes `agent_end`, not `agent_settled`. Herdr's installed OMP integration independently reports native pane state. |
| Turn end | OMP's `turn_end` event touches `state/<id>.turn-ended`; this is a watcher notification, not current-state truth. |
| Exit | `/exit`, one Enter; observed output was `Closing session…` and `Resume this session with omp --resume <id>`. |
| Interrupt | Single Escape; an active Bash tool call visibly changed to `Command aborted` and returned to the `❯` composer. No interrupt acknowledgement is credited, so control reports `cancel=unconfirmed`. |
| Model | `--model=<model>`; discover configured models with `omp models --json`. The observed default store listed `deepseek-v4-flash`, `deepseek-v4-flash-vision-exp`, and `deepseek-v4-pro`. |
| Effort | `--thinking=<low\|medium\|high\|xhigh\|max>`. OMP also advertises `off`, `minimal`, and `auto`, which are outside Firstmate's shared effort axis. `max` is passed only for an explicit choice and is never selected by the fallback. |
| Trust | A normal configured-profile launch in a clean worktree showed no project trust dialog. A blank isolated profile instead opened provider onboarding despite `--auto-approve`, so a fresh unauthenticated profile cannot carry a worker. |
| Detection | `FM_OMP_HARNESS=omp` wins before the shared `PI_CODING_AGENT` marker; otherwise exact `omp` ancestry identifies the binary. |
| Composer | The observed busy footer was a braille spinner followed by elapsed time, for example `⠹ 3s`; this is delivery-only confirmation, never a worker-state source. |

OMP accepts `--approval-mode=always-ask|write|yolo`, `--cwd`, `--add-dir`, `--profile`, `--skills` or `--no-skills`, `--max-time`, and `--mode=text|json|rpc|rpc-ui` in its help.
Firstmate uses only `--auto-approve` for unattended worker autonomy.

## Resume and task kinds

OMP's native `--resume <id>` form was observed at exit, but there is no verified Firstmate pane-resume contract.
Use deterministic `relaunch` from the durable brief instead.

OMP is verified for crewmate and scout workers on Herdr.
The tmux process-name branch has portable coverage but no supervised OMP tmux launch in this audit, so tmux remains unverified for OMP worker dispatch.
On Herdr, OMP's installed lifecycle registration persists as idle after `/exit`, so Firstmate proves the pane holds one recognized idle foreground shell with no `omp` process left beneath it rather than treating that idle registration itself as exit proof.
The same pane-process proof licenses a deterministic `relaunch` into the stopped endpoint; without it the stale registration would read as a live agent forever.
`../../../bin/fm-spawn.sh` refuses OMP secondmates before endpoint creation because no primary supervision protocol was verified.
OMP primary integration is unsupported for the same reason, so `fm-session-lock-lib.sh`, `fm-wake-lib.sh`, and the primary-hook surface have no OMP branch.
