Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi` or `pi-signed`, after approving project trust once per clone); if not, restart the selected executable with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. First cycle only: make the one required `fm_watch_arm_pi` call.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through Pi's bash tool because that foreground arm can wedge the agent and bypasses extension-owned cleanup.
4. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_pi` again.
5. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns every later successor launch.
6. Ordinary same-process session replacement (`/new`, `/resume`, `/fork`, reload) retires only the prior generation; call `fm_watch_arm_pi` once for the first cycle of the replacement session without restarting Pi.
   The generation-owner contract lives in `.pi/extensions/fm-primary-pi-watch.ts`.
7. After an actionable child close, the extension rechecks session-lock ownership and verifies one successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
8. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_pi` again because continuity is extension-owned rather than model-memory-owned.
9. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure instead of disappearing.
10. Missing, failed, or unhealthy cycle only: if a later notification explicitly reports one of those repair conditions, drain queued wakes, inspect the failure text, call `fm_watch_arm_pi`, and restart the selected Pi-family executable with both extensions loaded if needed.
   A redundant call while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The supervision branch is default-on (docs/pi-supervision-branch.md): whenever this session owns the fleet lock and away mode is not active, the watcher extension hands eligible task-local rows from ordinary actionable wakes, plus selected fleet-wide heartbeat reviews, to the persistent in-process supervision branch while main-only rows remain queued for this conversation.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is delivered silently with no rendered note, while every other routine outcome returns as an appended, rendered note that leads with ⛵ then the dim outcome text.
A captain-facing outcome instead opens exactly one follow-up turn on this conversation - that turn is the captain-visible result, and no separate note is printed here.
Before MAIN steers, controls lifecycle, or cleans up a task, claim its lease with `bin/fm-lease.sh claim <task>` and release it afterwards; a refused claim means the branch is acting on that task right now.
This conversation still receives every other fleet-wide or unresolvable wake, the branch's wakes when it is unavailable or away mode is active, and every watcher-failure alarm regardless, so the arm and repair contract above is unchanged.
Treat a merged note or an opened captain-facing turn as already handled - do not re-drain or re-handle its event - and read the durable outcome store with the fm_branch_outcomes tool when the captain asks what happened.

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.
