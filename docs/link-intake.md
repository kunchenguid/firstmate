# Link intake

When the captain sends one or more meaningful URLs, the active Firstmate inspects every link and retains a private searchable record for each result.
Records live in the generation selected by `FM_HOME/data/link-intake/current`, which remains gitignored with the rest of `data/`.
The record keeps the canonical URL, every supplied original URL, title, retrieval date, source type, summary, claims or takeaways, searchable terms, transcript outcome, and a visible failure reason when retrieval is unavailable.

The active agent uses the existing browser or media tool suitable for the source, then gives the normalized result to [`bin/fm-link-intake.sh`](scripts.md#the-bin-toolbelt).
The helper's header and `--help` own the record format, exact flags, canonicalization, validation, history snapshots, and process-crash atomic-write behavior.
Each update stages and validates a complete generation, then publishes its records, searchable index, history, and transcripts through one process-crash atomic `current` switch.
An interrupted updater leaves the prior or next complete generation selected, and the next helper invocation reclaims stale lock and staging state.
The helper does not issue filesystem sync barriers, so power-loss durability depends on the host filesystem.
Repeated intake of a canonical URL updates one current record while retaining original URLs and preserving the replaced record as private history.

Video and audio intake retains a legally and technically accessible transcript under the same private location or records why no transcript can be obtained.
An inaccessible, private, deleted, or otherwise unreadable source still receives a visible record with its failure reason.
Link intake preserves attribution and verification evidence only.
It never authorizes publishing, messaging, buying, sensitive-account login, or any other external mutation.

Run `bin/fm-link-intake.sh validate --all` to verify the selected generation's records, index, history, and transcript references in both directions.
[`verification/link-intake.md`](verification/link-intake.md) carries the active maintainer evidence.
