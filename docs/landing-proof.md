# Landing proof

A worker's `done:` is a claim, not proof.
Work has landed only when an independent read of the system of record shows it, so every `done:` line must carry the command that proves it and the output that command must produce.
This page owns that contract; `bin/fm-classify-lib.sh`'s `status_line_landing_fields_core` owns the field grammar, `bin/fm-dod-lib.sh`'s `fm_landing_proof_block` is its only worker-facing rendering, and `bin/fm-landing-claim.sh`'s header owns the recorder's exact behavior.

## The claim

Every generated Definition of done - no-mistakes, direct-PR, local-only, and scout - states the rule, and a `done:` line carries its claim text followed by labeled clauses in any order:

```
done: <claim> kind: <kind> proof: <one shell command> expect: <extended regex> told: <command> told-expect: <regex> lesson: <fact>
```

- `proof:` and `expect:` are required: the command is run and its stdout matched against the regex, and together they must show the change landed.
  The command runs unchanged from any directory, read-only, in a few seconds, with absolute paths and no variables from the worker's own shell.
  It is the command that will pass once the work has truly landed, so it need not pass at the moment the worker writes it.
- `kind:` names what is claimed, and each kind has its own system of record: `pr` (merged, deployed, and the running version contains the merge commit), `data` (a production count or metric moved), `flag` (the live value read back through the application's own path), `asset` (the deployed build serves the bytes), `notify` (the send ledger holds a real provider message id), `branch` (the commit is in the shared object store), `report` (the report file exists with content).
  An absent `kind:` is inferred from the claim text.
- `told:` and `told-expect:` are required for customer-facing work: the proof that the customer was actually told.
- `lesson:` is the house-wiki clause and is split off, never part of the claim.

A `done:` line without `proof:` is reported as unproven and the task goes back to in progress; a claim whose proof still does not match 30 minutes later is treated as not landed.

## The record

`bin/fm-landing-claim.sh` parses a line through that grammar and appends one row per claim to the landing police's claims file, `data/landing-police/claims.tsv` under the active home: task, epoch, kind, customer-facing flag, claim, proof, expect, told, told-expect.
The append is deterministic and model-free, and an identical claim is not appended twice, so a replayed wake is harmless.
It refuses a claim with no `proof:` and a malformed one, appending nothing in either case.

`bin/fm-landing-claim.sh from-status <task-id>` reads the newest `done:` line in that task's status log, which is how firstmate records a claim at a done wake without re-reading the line by hand.

## The check

The landing police is home-local, not tracked here: it lives in the firstmate home that owns the claims file, runs each claim's proof command on a schedule, and reports a claim that is still unproven, or one whose proof never matched, as not landed.
It involves no model, so a worker saying "done" never counts as landed on its own.
