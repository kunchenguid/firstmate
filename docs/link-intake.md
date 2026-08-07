# Link intake

When the captain sends one or more meaningful URLs, the active Firstmate inspects every link and retains a private searchable record for each result.
Records live in the generation selected by `FM_HOME/data/link-intake/current`, which remains gitignored with the rest of `data/`.
The record keeps the canonical URL, every supplied original URL, title, retrieval date, source type, summary, claims or takeaways, searchable terms, transcript outcome, and a visible failure reason when retrieval is unavailable.

The supported captain entry points are session chat and an enabled Relay `state/x-inbox/` mention.
Each first reaches `bin/fm-link-intake.sh capture` with its channel before source inspection, then the active agent uses the existing browser or media tool suitable for the source and upserts the normalized result.
`capture` publishes a searchable pending record, so a process crash after receiving a link cannot silently discard it.
If capture cannot publish, it exits nonzero with `error: link-intake-unavailable:` and the caller must surface that error without acknowledging session input or clearing the Relay inbox file.
The durable wake queue, process-event inbox, and pending-reply records deliver operational state rather than captain link input, so they are not link-capture surfaces.
The helper's header and `--help` own the record format, exact flags, canonicalization, validation, history snapshots, and process-crash atomic-write behavior.
Each update stages and validates a complete generation, then publishes its records, searchable index, history, and transcripts through one process-crash atomic `current` switch.
An interrupted updater leaves the prior or next complete generation selected, and the next helper invocation reclaims stale lock and staging state.
The helper does not issue filesystem sync barriers or claim power-loss durability, which is explicitly out of scope.
Repeated intake of a canonical URL updates one current record while retaining original URLs and preserving the replaced record as private history.

Video and audio intake retains a legally and technically accessible transcript under the same private location or records why no transcript can be obtained.
An inaccessible, private, deleted, or otherwise unreadable source still receives a visible record with its failure reason.
Link intake preserves attribution and verification evidence only.
It never authorizes publishing, messaging, buying, sensitive-account login, or any other external mutation.

Run `bin/fm-link-intake.sh validate --all` to verify the selected generation's records, index, history, and transcript references in both directions.
[`verification/link-intake.md`](verification/link-intake.md) carries the active maintainer evidence.
