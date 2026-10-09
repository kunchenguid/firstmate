# Local operator console

Run `bin/fm-console.sh` from a Firstmate checkout to open the local Status, Open decisions, and Queue tabs.
The page binds to IPv4 loopback and refreshes from the active home's structured fleet snapshot and GitHub issue and pull request records without starting an agent or using an AI model.

Status lists issues linked from admitted project work, grouped by registered project, with the exact GitHub title and issue state, lane stage, and linked pull request state.
Issue and pull request links are included only when their repository matches the registered clone's GitHub origin.
Unavailable GitHub fields stay labeled unavailable, and a failed fleet refresh retains the last good view as stale.

Open decisions are folded from the existing task status records and captain-hold summaries.
Answering rechecks that the keyed decision is still open.
When a live worker is recorded, the console sends the answer through `bin/fm-send.sh --resolve-key`.
When a held call has no live worker target, the console records the answer through the owning home's `bin/fm-captain-hold.sh answers` intake.

Queue shows queued and in-flight backlog items, their project, recorded dependency blockers, and the recorded admission state.
When no authoritative admission result is available, queued rows explicitly show `admission state unknown`.
