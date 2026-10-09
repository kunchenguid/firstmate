# Local operator console

Run `bin/fm-console.sh` from a Firstmate checkout to open the local Status, Open decisions, and Queue tabs.
The page binds to IPv4 loopback and refreshes from the active home's structured fleet snapshot and GitHub issue and pull request records without starting an agent or using an AI model.

Status lists issues linked from admitted project work, grouped by registered project, with the exact GitHub title and issue state, lane stage, and linked pull request state.
Issue and pull request links are included only when their repository matches the registered clone's GitHub origin.
Unavailable GitHub fields stay labeled unavailable, and a failed fleet refresh retains the last good view as stale.

Open decisions are folded from the existing task status records and captain-hold summaries.
Structured decisions show their question, context, lettered options with pros and cons, and highlighted recommendation in a readable card.
An older decision without those fields is marked "Needs rewrite" and cannot be answered from the console.
Answering rechecks that the keyed decision is still open.
When a live worker is recorded, the console sends the answer through `bin/fm-send.sh --resolve-key`.
When a held call has no live worker target, the console records the answer through the owning home's `bin/fm-captain-hold.sh answers` intake.

Queue shows queued and in-flight work, the linked GitHub issue title and milestone, and a plain-language reason each queued item has not started.
Dependency reasons include each named dependency's current state, captain-held items link to their decision card, dated holds show their date, and a queued item without a blocker says it is ready to start now.
Home-level work is labeled "Home operations", and ready items appear before blocked or in-flight items.
