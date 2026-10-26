# Fleet flow lane cap

## User outcome

A home's lane cap counts live lanes only. A lane whose last event is more than 4 h old and whose `bin/fm-crew-state.sh` read answers anything but `working` occupies no working slot, so a kept copy of a stopped lane - its record, worktree and status kept for inspection and cleanup - stays in the lane list while no longer filling the cap: a home with four live lanes and three kept copies can start work instead of reading seven open lanes against a cap of six.

## Drive

Run `bash fleet-flow/tests/fm-flow-check.test.sh`. It drives the real check over fixture lead homes with stub `fm-tasks-axi.sh` and `fm-crew-state.sh` (the stub prints a whole emitted line when its fixture holds one, so a kept copy reads exactly as the real script reports it).

## Evidence

The run prints one `ok:` line per assertion and `PASS: fm-flow-check lane slots`. The kept-copy cases cover: kept copies stay listed as open records while `counted` leaves them out; a live working lane still counts as working; four live lanes with three kept copies accept a start; six live lanes plus three kept copies count six and refuse a seventh start.
