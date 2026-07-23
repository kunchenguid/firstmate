# Completion report stack

Firstmate publishes one durable report for every task created after the report-stack cutover.
The default store is `$XDG_DATA_HOME/firstmate/report-stack` when `XDG_DATA_HOME` is set, otherwise `~/.local/share/firstmate/report-stack`, outside every Firstmate home and Claude or Codex account profile.
Set `FM_REPORT_STACK_ROOT` to relocate it.
Every locked report-stack operation performs one bounded retention batch.
Scheduled retention is owned by a per-user macOS LaunchAgent only when it is installed explicitly with `bin/fm-bootstrap.sh install report-retention` after captain approval.
The installer publishes immutable self-contained generations and atomically advances the LaunchAgent plist only after the referenced generation is complete, so a crash or reboot never depends on a later Firstmate session to restore executable code.
Each sweep uses a crash-recoverable namespace cutover to isolate expired cohorts, publishes the authoritative retention cutoff, regenerates the visible index, and then makes bounded physical-deletion progress, so cleanup may span later runs without restoring an expired report to readers.
The installed owner is a stable self-contained bundle, runs at boot and every five minutes by default, retries failed runs, and records a successful-prune heartbeat that session bootstrap validates.
Merging the code does not install or activate the owner.
The authoritative visibility cutoff is the later of its prior value and the current `now - 30 days` boundary, so ordinary forward wall time tracks that boundary exactly while a backward clock adjustment never re-exposes expired reports.
Physical cleanup still waits for each report's 30-day minimum age, its five-minute cohort deadline, and a later retention sweep, so the shipped five-minute defaults normally remove an expired report about zero to ten minutes after its minimum age.
The cohort width plus owner sweep interval may total at most 15 days, bounding scheduled visibility removal and tombstoning to 45 days after completion while physical tombstone deletion remains best-effort and bounded per sweep.
Expired entries are renamed to deletion tombstones before the index changes, and interrupted recursive deletion resumes from those tombstones without restoring partial entries.

## Completion contract

New task metadata carries `report_required=1`.
A ship task writes `data/<id>/completion.md`, while a scout keeps using `data/<id>/report.md`.
Both may attach screenshots, diagrams, or other review artifacts under `data/<id>/visuals/`.
Every post-cutover ship and scout report must use the level-two sections Summary, What changed, Verification, Visual evidence, Artifacts, and Follow-ups.
Every required section must contain substantive body content, with an explicit `None.` accepted when the section has nothing to report.
Within a real required section, meaningful fenced transcript or literal-code lines count as body content, but an empty fence body, whitespace, a bare Markdown blockquote or list marker, or Unicode control and format characters alone do not.
Fence delimiters never count as body content, and heading-like lines inside a fence never satisfy a required section heading.

For `report_required` tasks, `fm-teardown.sh` first quiesces the endpoint and confirms it gone while failing closed on an alive or unknown state, then runs non-destructive safety validation including the Orca path match and worktree checks, reconciles rollback state, and publishes before releasing an account lease or removing a worktree.
A safety refusal after quiescence preserves all work and metadata but leaves the crewmate endpoint stopped.
If a required heading is absent or lacks substantive content, publication names every missing or empty section, identifies the exact report source to edit, and gives the publish and teardown retry commands.
Publication failure leaves the prior durable entry unchanged and stops teardown before destructive cleanup, preserving the task for repair and retry.
Tasks that were already in flight at cutover lack the marker and retain the earlier teardown contract.
`--force` does not bypass completion-report publication or any work-retention proof.
Retiring a persistent secondmate is also not a completion; ordinary tasks completed inside its home publish to the same machine-global stack.

## Stored entry

Each entry contains a manifest, the completion report, the original task brief, the status trail, optional visual artifacts, and a standalone HTML review page.
The entry id is deterministic from the canonical Firstmate home path plus task id, so publication retries replace the same entry instead of duplicating it.
The manifest's task generation identity distinguishes a same-generation retry from a replacement generation, preserving prior completion provenance only when it still belongs to the current work.
The manifest records routing labels useful for review but never stores provider session ids, auth material, environment values, or account-home contents.
Task briefs, status trails, completion reports, and attachments are trusted internal artifacts preserved verbatim without heuristic redaction or transformation.
Bounded decoded views are used only for validation and HTML metadata; the stored source files retain their original bytes.
Publication reads only real files and directories contained beneath the configured task roots, refusing symlinks and path escapes.
It limits a completion report to 16 MiB and visual evidence to 20 MiB total, 512 entries, and 24 nested directory levels; oversized or unsafe input leaves the previous durable entry unchanged for repair and retry.

The generated `index.html` is an offline searchable card stack with task-type filtering and links to each report page.
Run `bin/fm-report-stack.mjs open` or use `/reports` to regenerate and open it.
Use `list`, `path`, `render`, and `prune` for terminal or automation access.
Use `publish <id> --legacy` only when intentionally archiving a pre-cutover task; it synthesizes a compatibility report if no normal report source exists.
