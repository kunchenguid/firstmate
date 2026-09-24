Supervision host: on for this home (`config/supervision-host`; [`supervision-host.md`](../supervision-host.md) owns the design).
{claude} The Stop hook runs the supervision host in the arm's place, and everything above still holds with these additions:
{cursor} The `stop` hook park runs the supervision host in the arm's place, and everything above still holds with these additions:
{opencode} The OpenCode TUI plugin runs the supervision host in the arm's place, and everything above still holds with these additions:
{omp} The omp watch extension runs the supervision host in the arm's place, and everything above still holds with these additions:
{grok} Your tracked background arm above runs the supervision host (`bin/fm-supervision-host.sh park`) in the plain arm's place, and everything above still holds with these additions:
{codex} Every foreground checkpoint runs the supervision host in the watcher's place, and everything above still holds with these additions:
1. Attended (no away-posture record `state/.afk-contract`): every wake reaches you exactly as above.
2. Away (the record exists and no daemon runs): the host hands each wake to a headless away session that runs the supervision branch's contract under the record, and you are parked.
{claude}    Only a wake the host hands back reaches you, as `Stop hook feedback` carrying the close plus one `supervision-host: <why>` line.
{cursor,opencode,omp}    Only a wake the host hands back reaches you, as a `watcher` follow-up carrying the close plus one `supervision-host: <why>` line.
{grok}    Only a wake the host hands back reaches you, as the arm's background-task-completed notification whose output carries the close plus one `supervision-host: <why>` line.
{codex}    Only a wake the host hands back reaches you, as checkpoint output carrying the close plus one `supervision-host: <why>` line.
{codex}    While the record exists each checkpoint uses the longer away bound (`FM_CODEX_WATCH_CHECKPOINT_AWAY`, default 3600s, subject to the host's park cap; see [`supervision-host.md`](../supervision-host.md#the-park-boundary)), so a captain message waits until the checkpoint returns unless the captain interrupts it.
   That wake is automatic supervision, not the captain's return: drain and handle it under the away posture, and never run the return from it.
   After the return, a `supervision-host:` line naming the captain's return during a turn means that turn's outcomes missed the return brief, whether the wake was handled or handed back: relay every following `supervision-host: outcome ...` line to the captain (the rows also remain in `bin/fm-branch-outcome.sh list`), then drain and handle any queued wake before acknowledging.
   Each such outcome is also a queued `check: supervision-host outcome <n> ... was recorded after the captain returned` wake, which the drain presents until acknowledged: relay each outcome once, whichever arrives first.
{claude,cursor} 3. `supervision-host: cycle boundary ...` means the host ended its park at its bound: run `bin/fm-wake-drain.sh`, handle whatever it presents, run its printed acknowledgement (an empty queue prints `--ack-through 0`), and end the turn; the next park starts at that turn end.
{opencode,omp} 3. `supervision-host: cycle boundary ...` means the host ended its park at its bound and the next park has already started: run `bin/fm-wake-drain.sh`, handle whatever it presents, and run its printed acknowledgement (an empty queue prints `--ack-through 0`).
{grok} 3. `supervision-host: cycle boundary ...` means the host ended its park at its bound: run `bin/fm-wake-drain.sh`, handle whatever it presents, run its printed acknowledgement (an empty queue prints `--ack-through 0`), and re-arm the same background host call.
{codex} 3. The host's park boundary returns as the checkpoint's ordinary `checkpoint: no actionable wake within <n>s` line; handle it as step 5 above says.
4. A guarded command that exits 6 naming the branch actor's lease means the away session is handling that task right now: leave the lease alone and retry after it releases, which it does when its turn ends.
5. Captain outcomes the away session records wait in the outcome store for the return brief (`bin/fm-afk-return.sh`); nothing processes them in this conversation before the return.
{claude,grok} 6. `/afk` writes only the record here (`bin/fm-afk-launch.sh start-native` refuses the away daemon on this home), while `/quiet` still launches the daemon, which then owns supervision as above.
{cursor,opencode,omp,codex} 6. `/afk` writes only the record here (`bin/fm-afk-launch.sh start` refuses the away daemon on this home), while `/quiet` still launches the daemon, which then owns supervision as above.
{grok} 7. The pre-tool seatbelt does not classify the host command, so keep it exactly the one background call above: never shell `&`, a pipe, or another command bundled onto it.
