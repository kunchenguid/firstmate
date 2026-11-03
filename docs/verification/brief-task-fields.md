# Brief task-field verification

Audience: maintainer verification.

This record supports the four required task fields a ship or scout brief carries, owned by [`bin/fm-brief.sh`](../../bin/fm-brief.sh) (scaffold) and [`bin/fm-brief-heading-lib.sh`](../../bin/fm-brief-heading-lib.sh) (the field list and the unfilled-field reader).
It states the mechanism claim, the structural proof that holds in every home, and a re-measurement procedure a maintainer can run against their own home's dispatch record.
No home's own data is recorded here: the numbers are meant to be produced by the reader, on the reader's sessions, with the same procedure.

## What changed

A ship or scout brief's `# Task` section now carries four required fields, each scaffolded as its own section with a fill placeholder.

| Field | Placeholder | States |
| --- | --- | --- |
| `## Acceptance criteria` | `{ACCEPTANCE_CRITERIA}` | what "done" means |
| `## Verification path` | `{VERIFICATION_PATH}` | the exact command or check that proves it |
| `## Required artifact` | `{REQUIRED_ARTIFACT}` | what the task produces |
| `## Out of scope` | `{OUT_OF_SCOPE}` | what the task does not cover |

`bin/fm-spawn.sh` and `bin/fm-promote.sh` refuse a brief whose field is absent, empty, or still its placeholder, and the refusal names the field to write.
A brief that carries none of the four sections predates the contract and stays dispatchable, so a task already in flight can still be relaunched.

## How `## Acceptance criteria` relates to `## Captain's intent`

`## Captain's intent` is the captain's own ask in the captain's own words, and it stays authoritative: the reviewer treats that subsection as the acceptance criteria, and `bin/fm-dod-lib.sh` passes its body, and only its body, as the no-mistakes `--intent`.
`## Acceptance criteria` is that same ask restated as conditions someone else can check, so it may narrow or sharpen the ask but must stay entailed by it.
A criterion the captain's words do not support is not an acceptance criterion: it belongs in `## Out of scope` as follow-up, or the brief itself is wrong.
When the two disagree, the intent governs and the brief is corrected, so a brief never carries two competing definitions of done.

## What is proven structurally

The mechanism claim is narrow: a brief the generator scaffolds carries the four sections with their placeholders, the dispatch path refuses a brief whose field is unfilled and names that field, a filled brief dispatches, and a brief predating the contract still dispatches.
This holds in any home and needs no measurement; [`tests/fm-brief.test.sh`](../../tests/fm-brief.test.sh) covers the scaffold and the single fill site per field, and [`tests/fm-task-delivery.test.sh`](../../tests/fm-task-delivery.test.sh) covers the refusal and the pre-contract acceptance.

The behavioral claim is separate and weaker: briefs carrying an explicit contract should produce fewer sessions whose record shows missing success criteria or repeated prompts.
That claim is home-specific, so it is re-measured rather than recorded.

## Re-measurement procedure

1. Before landing the change, choose the home's own dispatch record and count the dispatched cohort: sessions a ship or scout brief launched, identified by the brief marker those sessions carry in their first user message, so a session started by a human is never counted as dispatched.
   For that cohort, record the cohort size, how many sessions carried an `## Acceptance criteria` section, and the record's own prompt-quality counters for missing success criteria and repeated prompts. Record the date, the counter version the record reports, and the query used.
2. Land the change, so newly scaffolded briefs carry the four fields.
3. Dispatch a batch of ship or scout tasks through the generator, each with all four fields filled.
   A task whose fields are not filled is refused at dispatch, so a refused dispatch is the generator working, not a missing sample.
4. Re-run the same query, unchanged, against the same record, and read the same rows.
5. Record the dated before and after rows together, with the cohort size of each.

## What counts as improvement

Three conditions must all hold before a lift is claimed.

- The count of sessions carrying an `## Acceptance criteria` section equals the cohort size, which proves the sample actually ran under the new generator rather than under a mix of old and new briefs.
- The signal rates for missing success criteria and repeated prompts are below the before-state.
- The cohort is large enough that the difference is not noise: state the cohort size with the number, because a single session flipping is a large swing when the before-cohort is small.

A measured change in a small cohort is a signal to investigate, not a result to publish.

## Re-measurement notes

- Read the session record read-only; it is written by a live process, so the newest session may not have been ingested yet, and the UI over it is a view rather than the record.
- A session is dispatched when its first user message carries the brief marker.
  A session without the marker was not dispatched through this generator, whatever else it looks like.
- The prompt-quality counters are per-session, and the counters and the signals they produce count different things: a session can carry more than one signal.
- The record names which signal computation produced the counters.
  A version change invalidates a comparison with an earlier one, so record the version with every result.
- A degenerate multiplier, such as a reported `0.0x` lift, means the cohort had zero qualifying sessions or a divide-by-zero: it is unmeasured, not safe, and it cannot serve as a baseline.
- A signal generator's grade, ratios, and multipliers are not a measurement until the home that owns it has inspected the methodology.
