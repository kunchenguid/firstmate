Mode: Pi extension background wake.

When this session owns supervision:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the Pi primary auto-loaded both project extensions (`pi`, after approving project trust once per clone); if not, restart the selected executable with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. Initial process cycle only: make the one required `fm_watch_arm_pi` call; if startup already owned the fleet lock, this is an ownership-based no-op.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pi` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns every later successor launch.
6. Ordinary same-process session replacement (`/new`, `/resume`, `/fork`, reload) retires only the prior generation; when the replacement owns the fleet lock, its `session_start` arms the new generation without a model turn or another `fm_watch_arm_pi` call.
   The generation-owner contract and in-flight actionable-close handoff live in `.pi/extensions/fm-primary-pi-watch.ts`.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_pi` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_pi`, and restart the selected Pi-family executable with both extensions loaded if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The supervision branch is default-on whenever this session owns the fleet lock. Preserved legacy mode records do not affect this path.
[Pi supervision branch](../pi-supervision-branch.md#components-and-their-owners) owns eligible-row routing, asynchronous admission rechecks, mixed-queue isolation, and decision-owned whole-batch precedence.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is delivered silently with no rendered note, while every other routine outcome returns as an appended, rendered note that leads with ⛵ then the dim outcome text.
A captain-facing outcome instead appears as one exact, sequence-keyed visible transcript entry, and then arrives in this conversation as one hidden supervision processing request listing each `[seq N] task=<task>` identity it covers.
The request directly includes an inline-size successful ShortTask result only when the extension authenticates it against the bound durable result and operation receipts; treat that body as already loaded and do not call `fm_branch_outcomes` for its sequence.
An oversized successful ShortTask instead includes an authenticated bounded result reference; use `fm_short_task` with `action=result` once to load the complete unchanged result and its acknowledgement evidence, not `fm_branch_outcomes` to reload the same bounded notice.
For every identity-only sequence, call `fm_branch_outcomes` once with the request's exact sequence membership and treat each returned durable row plus current task/executor observation as the trusted processing input; then give the captain a visible response where one is due, answer or escalate a decision, act on a blocker or failure, or record that no further action is needed.
After processing every listed outcome, call `fm_branch_processed` with that complete comma-separated sequence membership, exactly once.
That acknowledgement is refused unless every named outcome was authenticated, its task/executor observation is still current, and the membership exactly matches the active request.
Only that call closes the outcome; an unrelated, empty, or paraphrased answer leaves it open, and the current unprocessed sequence set is presented again at the next run boundary and at session start until it is acknowledged.
The persisted entry is already the captain-visible record, so MAIN must not re-emit it verbatim merely because it appeared.
Before MAIN steers, controls lifecycle, or cleans up a task, claim its lease with `bin/fm-lease.sh claim <task>` and release it afterwards; a refused claim means the branch is acting on that task right now.
For an instruction authorized by one task but addressed to a different local worker, use `bin/fm-task-handoff.sh send <source-task> <target-task> --id <stable-id> '<exact instruction>'` before any target claim; this preserves the body across a refused claim and hands successful delivery to the target's ordinary inbox acknowledgement and retry ladder.
This conversation still receives each row-local main-only trigger, branch fallbacks when the branch is unavailable or busy with an unsettled turn that does not already own the new rows, and every watcher-failure alarm regardless, so the arm and repair contract above is unchanged.
An unresolved retired-task row remains available here without making unrelated resolvable rows main-owned.
Treat the merged fleet event as already handled for fleet operations: MAIN must not re-drain, re-run, or acknowledge it.
Separately, MAIN applies judgment about whether and how to surface, summarize, reference, or incorporate a merged sailboat outcome in the captain conversation; event ownership does not decide the conversational treatment.
Read the durable outcome store with the fm_branch_outcomes tool when the captain asks what happened.
[Live task continuation](../pi-supervision-branch.md#live-task-continuation) owns progress within the canonical task record, actionable MAIN reminders and the MAIN final-acceptance boundary.

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.
