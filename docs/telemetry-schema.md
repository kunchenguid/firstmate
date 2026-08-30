# Telemetry schema

One schema document for the two append-only operational ledgers. Both ledger
writers validate new rows against the contracts defined here; a payload that
does not satisfy this document is refused with a named reason. The deliberate
defaults named in this document are the only exceptions. Both ledgers are
append-only: rows already written are history, are never rewritten or
backfilled, and readers keep accepting their legacy shapes.

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
| `unknown` | Legacy placeholder for rows written before typed classes were required. `terminal-facts` may default a missing non-green `primaryFailureClass` to `unknown`. An explicit `terminal` payload may still carry `unknown` when the classification warrants it. Writers refuse any invented class outside this enum. |

### `terminal.usageSource`

Closed enum on new terminal rows: `recorded`, `no-verified-source`,
`session-not-found`, `session-matched-no-tokens`, `unreadable`,
`worktree-missing`. A terminal row without `usageSource` is valid for legacy
callers. The attempt sheet surfaces the additive `usageSource` column and uses
the sentinel `absent` when the sealed terminal omitted the field.

## Review ledger: `data/review-outcomes.jsonl`

Owner: `bin/fm-review-outcome.sh`. One JSON object per line; each new row
records the typed outcome of one review round. Rows already written are history,
are never rewritten or backfilled, and the sheet reader keeps accepting their
legacy shapes through an explicit normalization table.

### Required envelope fields

Every new append payload carries all of:

| Field | Requirement |
| --- | --- |
| `schemaVersion` | Must be `4`, the typed review-outcome schema version. |
| `taskId` | Non-empty task slug string. |
| `repository` | Non-empty repository identifier string (`owner/name`). |
| `pr` | Pull request number (integer ≥ 1). |
| `roundKind` | Non-empty string naming the round kind (for example `initial`, `follow-up`). |
| `timestamp` | UTC RFC3339 timestamp for when the round ended. |
| `status` | Closed enum below; must be typed at the source, never inferred from prose. |

A payload missing any required field is refused with a named reason naming the
missing field. A payload whose `status` is outside the closed enum is refused
with a named reason naming the value. The writer never defaults a missing or
invented status.

### `status` (writer closed enum)

| Value | Meaning |
| --- | --- |
| `posted` | The round posted a review to the forge. |
| `abandoned-unposted` | The round ended without posting (draft abandoned, head moved, route satisfied without post, etc.). |
| `blocked` | The round could not proceed (approval, custody, environment, or similar block). |
| `superseded` | A later round or merge superseded this one before or instead of posting. |
| `no-round` | No review round ran (eligibility skip, stability gate, merged-before-publication, etc.). |

`legacy-unclassified` is a read-only canonical marker for historic rows whose
original spelling does not match the normalization table. The writer refuses
`legacy-unclassified` and any invented value (for example `finished-maybe`).

### Historic normalization (reader only)

The sheet reader maps exact legacy spellings to canonical `status` values through
an explicit exact-match table documented here as rows are classified. Any legacy
`status` or schemaVersion 1 `result` value not listed maps to
`legacy-unclassified`. The reader never regexes free text and never guesses.

Frequent schemaVersion 3 `status` mappings:

| Legacy spelling | Canonical status |
| --- | --- |
| `posted` | `posted` |
| `completed` | `posted` |
| `completed-posted` | `posted` |
| `posted-clean` | `posted` |
| `passed` | `posted` |
| `abandoned-unposted` | `abandoned-unposted` |
| `abandoned-unposted-draft` | `abandoned-unposted` |
| `abandoned-unposted-head-moved` | `abandoned-unposted` |
| `abandoned-unposted-merged` | `abandoned-unposted` |
| `abandoned-unposted-route-satisfied` | `abandoned-unposted` |
| `completed-unposted` | `abandoned-unposted` |
| `no-round` | `no-round` |
| `superseded-no-post` | `superseded` |
| `completed-merged-before-publication` | `superseded` |

Frequent schemaVersion 1 `result` mappings:

| Legacy spelling | Canonical status |
| --- | --- |
| `posted-zero-findings` | `posted` |
| `clean-exact-head-comment` | `posted` |
| `posted-one-p2-finding` | `posted` |
| `posted-one-p2` | `posted` |
| `posted-clean` | `posted` |
| `approved-round-complete` | `posted` |
| `retired-merged-closed` | `superseded` |
| `stability-required-no-publication` | `no-round` |
| `private-two-p1-no-post` | `no-round` |
| `eligibility-skipped-merged` | `no-round` |

All other observed legacy spellings remain `legacy-unclassified`.

The sheet (`bin/fm-review-outcome.sh sheet --format json`) emits one object per
ledger line, never dropping a row, with the same canonical column set on every
row: `status`, `legacyStatus`, `candidates`, `kills`, `survivors`, `agreement`,
`metricsUnavailable`, `metricsUnavailableReason`. `legacyStatus` is the original
`status` or schemaVersion 1 `result` spelling, or `null` when neither was
present or the row is already a typed schemaVersion 4 write.

### Window summary (reader only)

`bin/fm-review-outcome.sh sheet --from <bound> --to <bound> --format json` emits
the same canonical rows alongside a per-window `summary` object, in one command.
A bound is a UTC RFC3339 timestamp or a bare `YYYY-MM-DD` date; a bare date on
`--to` covers that whole day. Anything else is refused rather than silently
narrowing the window. The round's date is `timestamp`, else `completedAt`; a row
with neither is never inside any window.

The output is `{rows: [...], summary: {...}}`. The summary carries:

| Field | Meaning |
| --- | --- |
| `rounds` | Rows whose date falls inside the window. |
| `posted`, `abandonedUnposted`, `blocked`, `superseded`, `noRound`, `legacyUnclassified` | Counts of in-window rows by canonical status. |
| `undated` | Rows with neither `timestamp` nor `completedAt`; never inside any window. |
| `metricsUnavailable` | In-window rows carrying `metricsUnavailable: true`. |
| `kills`, `survivors` | Sums of `kills` and `survivors` over in-window rows that carry metrics. Undated and metrics-unavailable rows contribute nothing. |
| `killRate` | `kills / (kills + survivors)` over in-window rows that carry metrics. `null` - not `0` - when that denominator is `0`. |

### Historic metrics (reader only)

The reader never mixes carriers and never fills missing counts with zero.

| Era | Status source | Metrics source |
| --- | --- | --- |
| schemaVersion 4 | typed `status` | typed `candidates`/`kills`/`survivors`/`agreement`, or `metricsUnavailable` with its reason |
| schemaVersion 1 | `result` via the table above | `compiler.killCount` (else `compiler.strictKillCount`) and `compiler.survivorCount`; `candidates` from `candidateCounts.raw` when that is a non-negative integer; `agreement` from `compiler.agreement` when that is a string |
| schemaVersion 3 | `status` via the table above | `kills` = length of `rulings.kills`; `survivors` = length of `rulings.survivors` when that is an array; `candidates` from `accounting.candidatesUnique` when that is a non-negative integer. The v3 `agreement` object is not a closed-enum string and is emitted as `null`. |
| unmatched spelling, version-absent persona rows, or a preferred carrier that is missing | `legacy-unclassified` | `metricsUnavailable=true` with reason `legacy-shape`; `candidates`, `kills`, `survivors`, and `agreement` are `null`, never `0` |

### Metrics (writer)

A valid new row either carries all four typed metrics (`candidates`, `kills`,
`survivors` as non-negative integers, and `agreement` from the closed set
below), or carries `metricsUnavailable=true` with `metricsUnavailableReason`
from the writer closed set below. The writer refuses a row with none of those
fields, a row that carries some but not all four typed metrics, and a row with
`metricsUnavailable=true` but no reason or a reason outside the writer enum,
each time naming the missing field or invented value. It never defaults
metrics to zero. A refused append leaves the ledger byte-identical; an
accepted append only adds one line.

### `agreement` (writer closed enum, when metrics present)

| Value | Meaning |
| --- | --- |
| `unanimous` | All personas agreed on kill/survivor disposition. |
| `majority` | A majority agreed; minority dissent is recorded elsewhere. |
| `split` | Personas disagreed without a clear majority. |
| `not-applicable` | Agreement is not meaningful for this round (for example a no-round). |

### `metricsUnavailableReason` (writer closed enum, when metrics absent)

| Value | Meaning |
| --- | --- |
| `no-round` | No review round ran; metrics do not exist. |
| `abandoned-before-compile` | The round abandoned before compilation produced counts. |
| `legacy-shape` | Read-only marker for historic rows the reader could not normalize; the writer refuses this value. |
