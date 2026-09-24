Supervision host: on for this home (`config/supervision-host`; [`supervision-host.md`](../supervision-host.md) owns the design).
The Stop hook runs the supervision host in the arm's place, and everything above still holds with these additions:
1. Attended (no away-posture record `state/.afk-contract`): every wake reaches you exactly as above.
2. Away (the record exists and no daemon runs): the host hands each wake to a headless away session that runs the supervision branch's contract under the record, and you are parked.
   Only a wake the host hands back reaches you, as `Stop hook feedback` carrying the close plus one `supervision-host: <why>` line.
   That wake is automatic supervision, not the captain's return: drain and handle it under the away posture, and never run the return from it.
   After the return, a `supervision-host:` line naming the captain's return during a turn means that turn's outcomes missed the return brief, whether the wake was handled or handed back: relay every following `supervision-host: outcome ...` line to the captain (the rows also remain in `bin/fm-branch-outcome.sh list`), then drain and handle any queued wake before acknowledging.
3. `supervision-host: cycle boundary ...` means the host ended its park before the Stop hook timeout: run `bin/fm-wake-drain.sh`, handle whatever it presents, run its printed acknowledgement (an empty queue prints `--ack-through 0`), and end the turn; the next park starts at that turn end.
4. A guarded command that exits 6 naming the branch actor's lease means the away session is handling that task right now: leave the lease alone and retry after it releases, which it does when its turn ends.
5. Captain outcomes the away session records wait in the outcome store for the return brief (`bin/fm-afk-return.sh`); nothing processes them in this conversation before the return.
6. `/afk` writes only the record here (`bin/fm-afk-launch.sh start-native` refuses the away daemon on this home), while `/quiet` still launches the daemon, which then owns supervision as above.
