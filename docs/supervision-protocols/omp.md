Mode: OMP extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Confirm the OMP primary auto-loaded both project extensions (plain `omp`, after approving project trust once per clone); if not, restart with `-e __FM_OMP_TURNEND_EXT__ -e __FM_OMP_EXT__` as a trust-free fallback.
3. Arm supervision with the `fm_watch_arm_omp` tool.
   Use `/fm-watch-arm-omp` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through OMP's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live OMP process, and sends a follow-up user message when the child exits with an actionable watcher reason.
5. If the extension says the watcher is already healthy, do not start another cycle.
6. If the extension reports a watcher failure, drain queued wakes, inspect the failure text, and restart OMP with both extensions loaded if needed.
7. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_OMP_TURNEND_EXT__`).

The turn-end guard extension lives at `__FM_OMP_TURNEND_EXT__`.
The watcher extension lives at `__FM_OMP_EXT__`.
Both are tracked, project-local `.omp/extensions/*.ts` files that OMP auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running OMP session has not loaded both required extensions.

OMP (Oh My Pi) is a Pi fork, so this protocol mirrors the Pi background-wake protocol. The extensions are ported from the Pi supervisors and kept in lockstep, including the #397 lifecycle fix: `stopArm()`, a one-shot `process.once("exit")` cleanup, awaited follow-up delivery, and the `fm_watch_arm_omp` tool + `/fm-watch-arm-omp` human fallback. Two OMP adaptations: the turn-end guard listens for `pi.on("turn_end")` because OMP has no `agent_settled` event (Pi 0.80.5-only), and the tool schema uses `pi.zod.object({})` rather than Pi's typebox. OMP sets `OMPCODE=1` (and `CLAUDECODE=1`) in its child/tool env, so `bin/fm-harness.sh` detects it as `omp` - and because `OMPCODE` is checked before `CLAUDECODE`, OMP never misdetects as claude. OMP auto-loads `.omp/extensions/` only, never `.pi/`. VERIFIED live 2026-07-10 (omp v16.3.15): a real omp primary ran this loop end-to-end - the turn-end guard fired with two crewmate tasks in flight and the primary re-armed the watcher rather than ending blind, while two omp crewmates shipped green PRs from treehouse worktrees. (Not yet exercised: a seatbelt deny, the tmux-backend busy signature, and exit/interrupt keys.)
