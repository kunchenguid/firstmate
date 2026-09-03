# Exact work identity

Firstmate can bind one task to an exact project or initiative, plan, stage, one or more work units, and one or more source-system records before dispatch.
Tasks without an intake record remain compatible and are projected explicitly as unlinked.
The public intake command is [`bin/fm-work-identity.sh`](../bin/fm-work-identity.sh).
Its header and `--help` output are the single owner of the complete `fm-work-identity.v1` schema, namespace matrix, syntax, storage, binding, and refusal rules.
This guide covers the operator workflow without copying that contract.

## Record an intake relation

Run the commands from the active Firstmate home so the generated binding names the correct physical and stable home identity.
Create the editable manifest as a private regular file rather than redirecting to a predictable path:

```sh
manifest=$(mktemp "${TMPDIR:-/tmp}/fm-work-identity.XXXXXX")
trap 'rm -f -- "$manifest"' EXIT HUP INT TERM
bin/fm-work-identity.sh template <task-id> > "$manifest"
```

Edit only the generated identity objects, leaving `schema` and `binding` unchanged.
Use accepted exact IDs from the authoritative project, plan, DTM, or ticket source.
The command validates the local identity contract but does not contact an external system to prove that an ID currently exists there.

Record the completed manifest before generating the task brief:

```sh
bin/fm-work-identity.sh record <task-id> --file "$manifest"
bin/fm-work-identity.sh verify <task-id> | jq .
```

Then scaffold and dispatch the task normally.
`fm-brief.sh` and `fm-spawn.sh` consume the contract owner's validated binding so the frozen worker instructions, metadata, and later projections agree.
Repeating `record` with the same manifest is an idempotent no-op.
A recorded relation is immutable, so a different relation requires a new task identity.
Persistent secondmate control tasks remain explicitly unlinked, while ship and scout tasks dispatched inside a secondmate home use the ordinary intake flow.

## Namespaces and labels

The accepted namespace and kind combinations distinguish Work Aligner plans and work units, DTM projects and issues, Data Team Tickets, and local Firstmate plans and work units.
Consult the command header for the complete closed matrix rather than inventing a namespace or kind.
Every human label is display-only, and only the namespace, kind, and ID tuple establishes identity.
One task may carry several exact work units while still counting as one worker.
Never construct a relation from a title, repository, branch, endpoint, worker name, timestamp, label, or status text.

## Read-only projections and handoff

The authoritative fleet snapshot exposes the structured relation for task rows, structured backlog rows, and validated secondmate child summaries.
Fleet view and Bearings render that snapshot, including delegated child work, without reconstructing a local or remote child tree.
`fm-backlog-handoff.sh` preserves linked relations and explicit unlinked status when queued work moves to a secondmate; its header owns the exact transfer and recovery mechanics.
The public `template`, `record`, and `verify` operations do not change task lifecycle state, assignment, GitHub, DTM, a Data Team Ticket, or a Work Aligner plan.
Malformed, stale, unsafe, cross-home, or task-mismatched linked records are refused, and fleet publication fails rather than silently downgrading them to unlinked.

Maintainer coverage and the backend and worker-tool applicability review are recorded in [`verification/work-identity.md`](verification/work-identity.md).
