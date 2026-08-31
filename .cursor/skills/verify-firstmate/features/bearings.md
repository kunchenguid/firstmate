# Bearings

The captain asks Firstmate where the fleet stands and gets a four-section digest gathered from one local snapshot: Captain's Call, Recently Landed, Underway, and Charted Next.

## Sub-features

- `plain` - chat-only four-section digest from a fresh local snapshot
- `file` - same digest plus today's `data/status-report-<YYYY-MM-DD>.md`
- `local-snapshot` - `bin/fm-bearings-snapshot.sh` emits `fm-bearings.v1` with zero network calls
- `include-prs` - optional live PR enrichment, the only network path

## How to get to it (user POV)

- Type `/bearings` (or `$bearings` on Codex, `/skill:bearings` on Pi) in the Firstmate chat
- Type `/bearings file` to also write today's dated report
- Type `/bearings include PRs` or `/bearings file include PRs` to add live PR checks
- Type `/bearings lavish` only when an interactive board is wanted; that path needs `lavish-axi`

## Driving it with bin/fm-bearings-snapshot.sh

Preconditions: scratch home launched and doctor-passed; `FM_HOME` exported to that home; `jq` on `PATH` for `--json`.

- Gather the local snapshot: run `bin/fm-bearings-snapshot.sh --json` and observe `"schema": "fm-bearings.v1"` and `"home"` equal to the last two path components of `$FM_HOME`.
- Confirm local-only: observe `"prs": "not_requested (run: /bearings include PRs)"` and that no `candidate_prs` object is present.
- Prove empty fleet: on a newly launched home with no backlog, observe `in_flight` is an empty array.
- Prove visible work: write `data/backlog.md` with one `## In flight` row `- [ ] verify-ship - Seeded verify item (repo: firstmate) (kind: ship)` and a matching `state/verify-ship.meta` containing `kind=ship`, then re-run `bin/fm-bearings-snapshot.sh --json` and observe `in_flight` contains `id` `verify-ship` and `kind` `ship`.
- Keep the file-mode write off this prove unless you are explicitly driving `/bearings file`; that write is `$FM_HOME/data/status-report-<YYYY-MM-DD>.md` only.

## Gotchas

The chat digest is agent-composed from this snapshot; do not invent a second fleet reader.

`--include-prs` is the only GitHub path; skip it unless auth is valid and the captain asked for PRs.

An in-flight backlog row without matching `state/<id>.meta` is an inventory gap, not Underway.

`/bearings lavish` needs `lavish-axi` and is not the primary prove path.
