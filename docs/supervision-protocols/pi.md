Mode: Pi extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm the Pi primary auto-loaded both project extensions (plain `pi` or `pi-signed`, after approving project trust once per clone); if not, restart the selected executable with `-e __FM_PI_TURNEND_EXT__ -e __FM_PI_EXT__` as a trust-free fallback.
3. The extension starts monitoring automatically when supervision demand appears and retires monitoring automatically when that demand clears.
4. Demand includes published task records, Relay polling, registered process-event sources, and a pending durable wake until drain acknowledgement removes it.
   Dead, stalled, malformed, or unreadable published task state keeps monitoring active, while dot-prefixed spawn and relaunch staging records do not count.
5. Session start, each settled main run, and filtered debounced demand-state hints trigger serialized reconciliation without a model turn.
   Idle retirement re-reads demand after the child exits so a concurrent publication restarts monitoring immediately.
6. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live Pi process, and owns later successor launch or intentional idle retirement.
7. Ordinary same-process session replacement (`/new`, `/resume`, `/fork`, reload) retires only the prior generation and reconciles the replacement automatically.
   The generation-owner contract lives in `.pi/extensions/fm-primary-pi-watch.ts`.
8. After an actionable child close, the extension rechecks session-lock ownership and verifies one demanded successor before it delivers the follow-up wake; its bounded fallback is defined in `docs/watcher-continuity.md`.
9. Ordinary work, turn completion, and ordinary signal, stale, check, heartbeat, or other wake handling: do not call `fm_watch_arm_pi` because demand reconciliation and continuity are extension-owned.
10. Missing, failed, or unhealthy cycle only: drain queued wakes, inspect the failure text, call the rare explicit repair tool `fm_watch_arm_pi`, and restart the selected Pi-family executable with both extensions loaded if needed.
   Use `/fm-watch-arm-pi` only as a human-entered fallback.
   A redundant repair while the extension owns an arm child or scheduled retry is an ownership-based `watcher: unchanged` no-op, not an independent health claim.
11. Never run `bin/fm-watch-arm.sh` through Pi's bash tool and never use shell `&` for watcher supervision.
   The arm mechanism above is extension-owned, not a model tool call, but a manual recovery probe that backgrounds, pipes, or bundles the arm is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, wired into the turn-end guard extension at `__FM_PI_TURNEND_EXT__`).

The supervision branch is default-on (docs/pi-supervision-branch.md): whenever this session owns the fleet lock and away mode is not active, the watcher extension hands eligible task-local rows from ordinary actionable wakes, plus selected fleet-wide heartbeat reviews, to the persistent in-process supervision branch while main-only rows remain queued for this conversation.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is delivered silently with no rendered note, while every other routine outcome returns as an appended, rendered note that leads with ⛵ then the dim outcome text.
A captain-facing outcome instead opens exactly one follow-up turn on this conversation - MAIN must produce its captain-visible response in that turn, and no separate note is printed here.
Before MAIN steers, controls lifecycle, or cleans up a task, claim its lease with `bin/fm-lease.sh claim <task>` and release it afterwards; a refused claim means the branch is acting on that task right now.
This conversation still receives every other fleet-wide or unresolvable wake, the branch's wakes when it is unavailable or away mode is active, and every watcher-failure alarm regardless, so the arm and repair contract above is unchanged.
Treat the merged fleet event as already handled for fleet operations: MAIN must not re-drain, re-run, or acknowledge it.
Separately, MAIN applies judgment about whether and how to surface, summarize, reference, or incorporate a merged sailboat outcome in the captain conversation; event ownership does not decide the conversational treatment.
Read the durable outcome store with the fm_branch_outcomes tool when the captain asks what happened.

The turn-end guard extension lives at `__FM_PI_TURNEND_EXT__`.
The watcher extension lives at `__FM_PI_EXT__`.
Both are tracked, project-local `.pi/extensions/*.ts` files that Pi auto-discovers once the project is trusted; `bin/fm-session-start.sh` reports when the running Pi session has not loaded both required extensions.
