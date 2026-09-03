# OMP

OMP is a first-class adapter named exactly `omp`. It shares some Pi-family TUI mechanics but has distinct identity, lifecycle, and supervision wiring.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `omp`; resolved to one absolute executable before endpoint creation. |
| Identity | `OMPCODE=1`, then exact `omp` process ancestry before the shared `CLAUDECODE` and `PI_CODING_AGENT` markers. |
| Launch | `omp --auto-approve [--model <model>] [--thinking <effort>] --extension <path> <single positional prompt>`. |
| Busy state | `state/<id>.omp-ext.ts`; `agent_start` writes busy and terminal `agent_end` writes idle only when `willContinue` is not true, `ctx.isIdle()` is true, and no pending messages remain. Source is exactly `omp-ext`. |
| Turn end | `turn_end` touches `state/<id>.turn-ended`; this is a wake notification, not current state. |
| Exit command | `/quit`. |
| Interrupt | Single Escape. |
| Model flag | `--model <provider/model>`. |
| Effort flag | `--thinking <low\|medium\|high\|xhigh\|max>`. |
| Model discovery | Use OMP's model selector or documented model catalog. Do not pass Pi-only `--list-models` assumptions to OMP. |

Foreign workers launched from an OMP session have `OMPCODE`, `CLAUDECODE`, `PI_CODING_AGENT`, `FM_PI_HARNESS`, and other harness markers cleared at the launch boundary. Their recorded FirstMate metadata remains authoritative.

The generated worker extension is explicitly loaded from FirstMate state, outside the task worktree. Missing, malformed, stale-generation, or foreign-source events remain unknown. A dead endpoint always overrides semantic idle state.

## Primary integration

OMP auto-discovers `.omp/extensions/fm-primary-watch.ts` and `.omp/extensions/fm-primary-turnend-guard.ts` when launched from the FirstMate root. Secondmates receive both through explicit `--extension` flags.

The watcher tool is `fm_watch_arm_omp`. The extension owns successor rearm and follow-up delivery. `session_stop` runs `bin/fm-turnend-guard.sh` before settlement and returns OMP's native block decision when supervision is missing. The same extension runs session-start context delivery and the watcher-arm and `cd` pre-tool guards.

Remote launch passes only harness, model, effort, backend, and trace context. OMP configuration and authentication come from the remote account's own `HOME`; FirstMate does not read or transmit provider credentials.
