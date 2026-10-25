# lead-wake

The lead-wake policy of the fork watcher as an optional add-on (fork exit 8: step A and slice 2). A secondmate home with ready backlog work (`fm-tasks-axi.sh ready`) that sits below its lane floor, or has no worker provably working, raises one `check:` wake; the wake is withdrawn when the ready set empties.

- `config/lane-target` is one positive integer, the lane floor (a floor, not a cap). Open lanes are `state/<task>.meta` of kind `ship` or `scout`; the fleet-flow check's `counted` column wins when installed. A secondmate home inherits the primary's value.
- Below the floor: `check: ready work waiting with free lane slots (<open>/<target> open): <ids> - ...`; at or above it, or without a usable target: `check: ready work waiting with no worker working: <ids> - ...`.
- The same set re-raises every `FM_READY_WORK_RESURFACE_SECS` (1800), a new set at once, at the base `FM_HEARTBEAT` without idle backoff. An empty set on a good read withdraws the queued row and keeps the resurface record.
- A stalled lead's drain ring (`secondmate_ring_to_drain`) names the frozen row and its acknowledgement: `Wake row <seq> is still queued in this home. Run bin/fm-wake-drain.sh ... run the exact WAKE_ACK_REQUIRED command it prints ...`. The lib redefines Kun's function after it, so Kun's two-argument call needs no hook line; the row is the oldest actionable one in the mate's queue.

`bin/fm-lead-wake-lib.sh` keeps the fork's names (`lane_target_value`, `open_lane_count`, `warn_invalid_lane_target_once`, `ready_work_waits_idle`, `record_ready_work_surfaced`, `fm_wake_withdraw`) plus `secondmate_ring_to_drain`, and adds `lead_wake_tick`; `bin/fm-lead-wake-inherit.sh` appends `lane-target` to `FM_INHERITABLE_CONFIG`. Step B puts three lines in Kun's files; each is a no-op under `set -e` when the add-on is absent (Kun behavior):

```bash
# fm-watch.sh, above `while :; do`
[ ! -r "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-lib.sh" ] || . "${FM_ADDONS_DIR:-$FM_HOME/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-lib.sh"
# fm-watch.sh, where the ready-work block was
if declare -F lead_wake_tick >/dev/null; then lead_wake_tick; fi
# fm-config-inherit-lib.sh, below FM_INHERITABLE_CONFIG
[ ! -r "${FM_ADDONS_DIR:-${FM_HOME:-}/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-inherit.sh" ] || . "${FM_ADDONS_DIR:-${FM_HOME:-}/projects/firstmate-addons}/lead-wake/bin/fm-lead-wake-inherit.sh"
```

No install state: remove the checkout to uninstall.

Proof: `FM_TEST_FORK=/path/to/read-only/firstmate bash lead-wake/tests/lead-wake-e2e.sh` stages step B into a private copy of the fork's `bin/` (`tests/stage-step-b.py`: fork definitions removed, Kun's ring restored, hook lines added) and runs the fork's own lead-wake cases, carried in `tests/fm-lead-wake.test.sh` on the fork's wake harness, through the real watcher: idle lead, lane floor (fleet-flow counted column, malformed row and target, resurface), transient empty, withdraw, full-but-idle and the drain-ring text. Add-on absent: Kun's ring text, no ready-work wake, no stderr. Needs `tasks-axi`; CI runs it.
