Mode: Pi extension background wake.

When this session owns supervision:
1. Drain first with `bin/fm-wake-drain.sh`.
   Apply the section 8 reconciliation rules, then run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; interruption before it leaves the work durable.
2. Confirm the Pi primary auto-loaded both project extensions (`pi`, after approving project trust once per clone); if not, restart the selected executable with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. Initial process cycle only: make the one required `fm_watch_arm_pi` call; if startup already owned the fleet lock, this is an ownership-based no-op.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pi` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, attaches the child to the live Pi process, and owns successor launch, same-process replacement, actionable-close handoff, and bounded retry as specified by `.pi/extensions/fm-primary-pi-watch.ts` and `docs/watcher-continuity.md`.
6. Ordinary work and wakes need no new arm call; an exhausted retry or lost lock surfaces as a watcher failure.
7. Missing, failed, or unhealthy cycle only: drain, inspect the failure, call `fm_watch_arm_pi`, and restart the selected Pi-family executable with both extensions if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
8. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The supervision branch is default-on with the fleet lock; preserved legacy mode records do not affect it, and [Pi supervision branch](../pi-supervision-branch.md#components-and-their-owners) owns admission and routing.
Only `task=fleet silent=true` no-change heartbeats are silent; routine outcomes render as appended notes, while captain-facing outcomes render once and then produce a hidden request with exact `[seq N] task=<task>` membership.
Treat an authenticated inline ShortTask body as loaded; for an oversized authenticated reference, call `fm_short_task` with `action=result` once.
For identity-only sequences, call `fm_branch_outcomes` once with the request's exact membership and use its durable rows plus current observation to respond, decide, act, or record no action.
After processing every listed outcome, call `fm_branch_processed` exactly once with the complete comma-separated sequence membership.
Only that authenticated, unchanged, exact-membership acknowledgement closes the outcomes; presentation grants no authority, and an unrelated or paraphrased answer leaves them open for replay.
The persisted entry is already captain-visible, so MAIN must not re-emit it verbatim.
Before MAIN steers, controls lifecycle, or cleans up a task, claim its lease with `bin/fm-lease.sh claim <task>` and release it afterwards; a refused claim means the branch is acting on that task right now.
For an instruction authorized by one task but addressed to a different local worker, use `bin/fm-task-handoff.sh send <source-task> <target-task> --id <stable-id> '<exact instruction>'` before any target claim; this preserves the body across a refused claim and hands successful delivery to the target's ordinary inbox acknowledgement and retry ladder.
This conversation still receives row-local MAIN triggers, unavailable or busy branch fallbacks, every watcher failure, and unresolved retired-task rows without making unrelated rows MAIN-owned.
Treat the merged fleet event as already handled for fleet operations: MAIN must not re-drain, re-run, or acknowledge it.
MAIN applies judgment about whether and how to surface, summarize, reference, or incorporate a merged sailboat outcome; read the durable store with `fm_branch_outcomes` when asked what happened.
[Live task continuation](../pi-supervision-branch.md#live-task-continuation) owns progress within the canonical task record, actionable MAIN reminders and the MAIN final-acceptance boundary.

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked project-local extensions auto-discovered after trust; `bin/fm-session-start.sh` reports when either is missing.
