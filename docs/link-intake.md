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

Storing a retrievable record also prepares one ingest scout for that link: a scout brief under `FM_HOME/data/<task-id>/` and a queued backlog item.
The scout's own instructions have it ingest the source with the existing browser or media tool, keep the ingested text as a durable artifact beside its report, report what the fleet can build from it along with out-of-the-box ideas, blindspots, and other angles mapped to current lanes, and file promising ideas as further queued backlog items.
Its specialized write contract permits authoritative output only under its own `FM_HOME/data/<task-id>/` directory, link-record updates through the absolute intake helper with explicit `FM_HOME`, queued backlog additions through `tasks-axi`, and its status file.
Every other file stays inside the disposable worktree, and the scout never edits a project.
The selected scout repository is stored on the queued ingest-scout item, while each promising-idea command requires the repository of the current lane that idea is mapped to in the report.
Preparation stops there: the scout is never spawned, started, or dispatched, so firstmate keeps dispatch authority, spawn safety, dispatch-profile consultation, and capacity judgment.
The task id derives from the canonical URL alone, so re-recording the same link converges on the one brief and backlog item instead of queueing a second scout.
An inaccessible record prepares no scout because there is nothing to ingest, `--no-scout` skips preparation for one invocation, and `prepare-scout` prepares or repairs one for an already-stored record.
A home whose backlog backend is manual gets the brief plus the exact queued item to add by hand.
A missing or incompatible `tasks-axi` under the default backend fails scout preparation after the link record is published instead of being treated as manual mode.

Video and audio intake retains a legally and technically accessible transcript under the same private location or records why no transcript can be obtained.
An inaccessible, private, deleted, or otherwise unreadable source still receives a visible record with its failure reason.
Link intake preserves attribution and verification evidence only.
It never authorizes publishing, messaging, buying, sensitive-account login, or any other external mutation.

Run `bin/fm-link-intake.sh validate --all` to verify the selected generation's records, index, history, and transcript references in both directions.
[`verification/link-intake.md`](verification/link-intake.md) carries the active maintainer evidence.
