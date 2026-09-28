# TraeX

Current per-version evidence is recorded in [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#traex-thin-worker-adapter).
The router owns TraeX's role and backend boundary.

## Operating facts

| Fact | Value |
|---|---|
| Launch | `FM_TRAEX_HARNESS=traex traex -y [--model <model>] [-c 'model_reasoning_effort="<level>"'] <one positional brief>`. The marker outranks ancestry so unrelated TraeX processes are not detected as workers. |
| Backend lifecycle | Generic Herdr `agent get`, pane and process inspection, text or key input, busy observation, and pane cleanup, identical to other ordinary Herdr harnesses. TraeX owns no readiness state machine, transition journal, or completion protocol. |
| Models | `--model <model>`; discover current-account support with `traex models --json`. |
| Authentication | `traex login status` checks the credential used by TraeX without printing it. |
| Effort | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`; `max` is refused before endpoint creation. |
| Busy state | Managed workers use the task-bound transcript reader owned by `bin/fm-busy-transcript.py`, with structural process liveness from Herdr. Native unknown does not mask a valid bound transcript; missing or unsupported evidence stays unknown. Current verification: [semantic busy state](../../../../../docs/verification/supervision.md#semantic-busy-state). |
| Exit | Use the generic backend pane-cleanup owner. |
| Interrupt | Single Escape, followed by generic Herdr `Ctrl+U` because TraeX restores interrupted input into the composer. |
| Skill invocation | No separately verified command form; use natural language. |
| Resume | Unsupported in this adapter. Use ordinary stopped-worker recovery to relaunch the worker in its preserved isolated copy. |
| Autonomy | `-y` or `--dangerously-bypass-approvals-and-sandbox`; this does not suppress the separate fresh-directory trust chooser. |
| Trust | A fresh isolated copy may show `Do you trust the contents of this directory?`. Accept the old Herdr `directory_trust_prompt` or the exact newer `enter continue \| esc quit` chooser with `1. Yes, continue` visibly preselected and exact TraeX/pane/cwd provenance, then require native `working`; generic `unknown` and key transport alone are not launch success. |
| Composer | Bare `❯` row covered by the shared structural composer owner. |

Raw TraeX launch commands are refused so the scoped marker and trust owner cannot be bypassed.
The bounded raw-command detector covers direct and ordinary shell-wrapped invocations, while deliberately dynamically constructed interpreter execution is outside its supported guarantee and general raw execution remains available.
