# Telemetry schema

One schema document for the two append-only operational ledgers. Both ledger
writers validate new rows against the contracts defined here; a payload that
does not satisfy this document is refused with a named reason, never defaulted.
Both ledgers are append-only: rows already written are history, are never
rewritten or backfilled, and readers keep accepting their legacy shapes.

Failure fields are typed at the source. The caller that ends a unit of work
already knows why it ended and passes the class as a typed field; no reader
derives a class from free text. Free text may ride along in bounded evidence
references, never as the class itself.

## Attempt ledger: `data/routing-outcomes.jsonl`

Owner: `bin/fm-model-telemetry.sh`. One JSON event per line; terminal events
carry the outcome of one model attempt.

### `attempt-intake.taskId`

Every new intake event carries the task slug its caller passed as `taskId` on
the event envelope. An intake without a task slug is refused. Rows written
before this field was required do not carry it and remain valid when read. The
attempt sheet surfaces it as the additive `taskId` column (null on legacy
rows).

### `attempt-intake.selection.quota.decision`

Closed enum: `selected`, `stopped`, `not-applicable`. Every new intake carries
the quota decision its caller made: `selected` when quota-aware dispatch
selected this tuple, `stopped` when it stopped on quota, `not-applicable` when
quota was not consulted for this dispatch. A new intake whose decision is
missing, invented, or the legacy placeholder `unknown` is refused with a named
reason; `unknown` stays legal only when reading rows written before typed
decisions were required. The attempt sheet surfaces it as the additive
`quotaDecision` column (null on legacy rows).

### `terminal.primaryFailureClass`

Closed enum. Writers refuse any value outside this list.

| Value | Meaning |
| --- | --- |
| `none` | The attempt delivered; nothing failed or blocked it. |
| `capability` | The model could not produce a passing change. |
| `refusal` | The model declined the task. |
| `timeout` | The attempt exceeded its time bound. |
| `quota` | A provider quota or budget stopped the attempt. |
| `tool` | A tool the attempt depended on failed. |
| `transport` | The harness or provider connection failed. |
| `environment` | The machine or task environment was broken. |
| `external-wait` | The attempt waited on an external party or event. |
| `scope-change` | The task scope changed under the attempt. |
| `integrity` | A safety or integrity check stopped the attempt. |
| `approval-wait` | Blocked on an unanswered trust or permission dialog. |
| `custody-wait` | Branch or worktree custody held pending an external merge. |
| `lease-conflict` | A slot or lease was held by a record whose work already finished. |
| `state-divergence` | Durable state contradicted observable truth, e.g. a failed state recorded for work that had merged. |
| `unknown` | Legacy placeholder. Legal only when reading rows written before typed classes were required; writers refuse it on new terminal rows. A non-green terminal whose facts carry no class from this enum, or carry `unknown`, is refused. |

## Review ledger: `data/review-outcomes.jsonl`

Owner: `bin/fm-review-outcome.sh`. The row schema for this ledger is defined in
this document alongside its writer; see the review-ledger section once that
writer lands.
