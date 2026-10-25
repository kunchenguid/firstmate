#!/usr/bin/env bash
# done-done journey: prove the ticket write-back end to end - the port, the lifecycle
# writer, the drift check, the fork shim, and the dashboard's stale count - and write the
# transcripts, captures and step record into $DONE_DONE_EVIDENCE_ROOT under fixed names.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DONE_DONE_EVIDENCE_ROOT:?run through done-done}
cd "$REPO" || exit 1
failed=0

# 1. The port plus the writer and the check, through the add-on's own suite and a
#    disposable fleet board: real tasks-axi, real sign-off-axi, no live board.
FM_TEST_FORK=$REPO bash addons/tickets-sync/tests/sync.test.sh >"$OUT/tickets-sync-test.log" 2>&1 || failed=1
if grep -q '^PASS:' "$OUT/tickets-sync-test.log" && ! grep -q '^FAIL' "$OUT/tickets-sync-test.log"; then
  grep '^PASS:' "$OUT/tickets-sync-test.log" >"$OUT/tickets-sync-passed.log"
else
  failed=1
fi

# 2. The fork shim: silent without the add-on or a board, and it hands an installed
#    writer this home's task and flags.
bash tests/fm-ticket.test.sh >"$OUT/fm-ticket-test.log" 2>&1 || failed=1

# 3. The dashboard's own core journey serves a seeded home at phone width; its
#    Tickets hero must name the open tickets nothing has updated for a day.
FM_BIN=$REPO/bin FM_ADDONS_DIR=$REPO/addons bash addons/fleet-dashboard/run-core-proof.sh \
  >"$OUT/fleet-dashboard-proof.log" 2>&1 || failed=1
stale=$(sed -n '/^stale tickets on the seeded board:/p' "$OUT/fleet-dashboard-proof.log")
[ -n "$stale" ] || failed=1

if [ "$failed" -ne 0 ]; then
  echo "tickets-writeback: a step failed; read tickets-sync-test.log, fm-ticket-test.log and fleet-dashboard-proof.log" >&2
fi

python3 - "$OUT/steps.json" "$(git rev-parse HEAD)" "$stale" <<'PY'
import json, sys
steps = [
    "Run the add-on sync test so a ticket publishes its stage and last event from the lane.",
    "Write a dispatched ticket's stage and state, then a delivered PR, through the lifecycle writer.",
    "Repeat the same write and read the board unchanged; confirm a ticket the poll never published is untouched.",
    "Make a ticket contradict its backlog item and read the check naming it, then settle the board and read silence.",
    "Run the fork shim test so a home without a board stays silent.",
    "Serve the dashboard at phone width and read the tickets view counting the open tickets gone quiet.",
]
with open(sys.argv[1], 'w') as out:
    json.dump({
        'target': {'version': sys.argv[2]},
        'start': 'A disposable board holds a ticket for a task seven days old and untouched; nothing on this branch has written a ticket yet.',
        'steps': steps,
        'result': 'Every ticket carries the stage, last event, state and delivered PR written when the work happens, '
                  'the check names a ticket that contradicts its work and falls silent when the board is true, '
                  'and the dashboard counts the open tickets gone quiet (' + (sys.argv[3] or 'no reading') + ').',
    }, out, indent=1)
    out.write('\n')
PY
exit "$failed"
