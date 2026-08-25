# Pi autonomous development

Pi autonomous development is an opt-in operating mode that extends the existing Pi supervision branch into a read-only attention router for explicitly allowlisted Linear work.
It is disabled unless one local configuration validates completely, its named runtime credential is present, every repository mapping is unambiguous, every mapped Firstmate project is registered for PR delivery with autonomous green-merge posture, and the kill switch is absent.
[Configuration](configuration.md#pi-linear-autonomy-configpi-autonomyjson) owns activation and the local schema.
[Verification](verification/pi-autonomous-development.md) owns repeatable evidence and the accepted held-out baseline.

## One main session and one supervision session

The captain-facing Pi session remains the only authoritative brain.
Only after the Pi session proves it owns the Firstmate home does `.pi/extensions/fm-branch-supervision.ts` validate provider authentication and create one independent persistent `AgentSession` under `state/autonomy-session/`; a cold pre-lock session leaves the first notification on main while activation finishes.
The branch selects the separately configured provider, model, and thinking level through Pi's `ModelRuntime` without a network catalog refresh.
The model's `maxTokens` is lowered to the configured output ceiling before session creation.
The supervision session loads one byte-stable prompt from `bin/fm-autonomy-prompt.sh`, one fixed tool named `fm_supervision_decide`, no project resources, no context files, no skills, and no read, shell, Linear, dispatch, edit, write, or merge capability.
Its only structured actions are `coalesce`, `nextTurn`, and `wake`.
The normal Pi supervision branch remains unchanged when autonomy is not active.
Pi and pi-signed primaries share this tracked Pi extension surface; Claude, Codex, OpenCode, Grok, Kimi, Cursor, and Muse primaries never load it, and every worker runtime keeps its existing behavior.

Main's finalized visible user and assistant text is mirrored in append order as hidden `fm-main-mirror` custom messages without opening a model turn.
The collector copies only text blocks from finalized user and assistant messages.
It excludes thinking blocks, tool calls, tool results, operational Firstmate injections, and autonomy merge messages.
Every mirrored entry also receives a stable transcript-commit record in the autonomy journal before the mode-specific `state/.autonomy-mirror-cursor` advances.
The supervision prompt frames mirrored dialog as judgment context rather than instructions or delegated authority.

## Deep orchestration module

`.pi/extensions/lib/fm-autonomy.ts` is the single mechanism owner.
Its public orchestration surface is deliberately small:

- `appendEvent` records one stable external or Firstmate event.
- `appendMainTranscriptCommit` records one finalized visible main-session message.
- `classifyPendingBatch` offers one bounded ordered batch to the structured classifier.
- `deliverDecision` applies the one safe Pi delivery mode and records evidence.
- `reconcile` repairs pending delivery and issue-claim transactions after replacement or restart.
- `reportStatus` emits sanitized activation, journal, usage, cache, cost, and claim totals.

The module keeps Linear, durable storage, time, Pi delivery, and Firstmate project operations behind internal adapter interfaces.
The production Firstmate adapter does not replace the existing lifecycle.
It scaffolds the ordinary task instructions, records the ordinary backlog item, and invokes `bin/fm-spawn.sh` with an explicit delivery mode, autonomy posture, and main-selected worker profile.
The worker still owns implementation and its selected delivery path.
No-mistakes still owns every active validation run and fix cycle.

## Durable event journal

`state/autonomy/journal.jsonl` is an owner-only append-only JSONL journal.
Every record carries schema `fm-autonomy-journal.v1`, a contiguous sequence number, timestamp, stable record ID, kind, key, and canonical JSON data.
The writer serializes processes with a bounded owner lock, fsyncs each appended record, deduplicates stable record IDs, and refuses a torn tail, duplicate identity, or sequence discontinuity rather than reusing a sequence.
The journal records events, transcript commits, classifications, delivery attempts, accepted deliveries, delivery acknowledgements, usage, claims, dispatches, pull-request links, merge intents, merge confirmations, conflicts, and completion.
An event remains pending until one structured decision accounts for its exact stable ID.
A delivery remains pending until the main session contains the decision ID or Pi emits equivalent finalized-message evidence.

A delivery attempt records the main session ID and process generation before Pi receives the message.
An accepted in-memory queue is not treated as durable across process replacement.
On replacement, reconciliation searches the new main session for the stable decision ID and acknowledges it if present.
If no evidence exists, the same decision replays from the journal.
This closes the crash window without treating a lost `nextTurn` queue as delivered.

## Pi delivery semantics

A `coalesce` decision records an acknowledgement and opens no main turn.
It is invalid for a new Linear issue, an urgent event, or stronger-boundary work.
A `nextTurn` decision always uses Pi's `deliverAs: "nextTurn"` custom-message path and never triggers a turn.
A `wake` decision uses a triggered follow-up when main is idle and uses `deliverAs: "steer"` when main is working, so the message lands at the next safe assistant boundary rather than duplicating or interrupting a tool midway.
Stable decision IDs, in-process accepted-attempt tracking, finalized-message evidence, and replay together make an urgent idle wake exact once under ordinary execution and recoverable after process replacement.

## Prompt caching and budgets

Main keeps Pi's ordinary per-session cache behavior.
The autonomy session uses one per-home cache key, one byte-stable prompt, one tool schema in one order, one separately persisted session, and append-only mirrors and event prompts.
Its pointer resumes only when `state/.autonomy-session-binding` still matches the prompt hash, decision contract, model, thinking level, and tool order; otherwise a fresh autonomy conversation starts without deleting the old record.
When persistent context plus a new batch would cross the configured input cap, the extension retains the old session file, starts a fresh contract-bound session, and silently replays only the newest journaled visible transcript commits that fit its bounded replay allowance.
Activation requires its configured model to be distinct from main and strictly cheaper at the configured uncached input/output batch ceiling.
No timestamps, fleet snapshots, credentials, allowlist values, issue text, or current-state data enter the standing prefix.
Usage records retain provider and model identifiers plus input, output, cache-read, cache-write, and total cost numbers, never message content or credentials.
Status reports aggregate those records and calculate the cache-read ratio.
The active configuration bounds event count, issue count, estimated input tokens, output tokens, turn time, model iterations, cost per window, Linear pages, Linear retries, retry delay, active issues, workers, and simultaneous heavy validations.
Before each batch, the configured input cap covers persistent session context plus the new batch, and unknown context usage is conservatively priced at the full cap.
Recorded window cost plus a catalog-priced worst-case estimate for that bounded input, configured maximum output, and complete iteration allowance must fit within the ceiling.
Crossing a ceiling stops new classification or claims, preserves the original events for bounded retry, and routes the concrete problem to main.

## Linear adapter

The adapter follows Linear's current [GraphQL](https://linear.app/developers/graphql), [authentication](https://linear.app/developers/oauth-2-0-authentication), [pagination](https://linear.app/developers/pagination), [filtering](https://linear.app/developers/filtering), [rate-limiting](https://linear.app/developers/rate-limiting), and [attachment](https://linear.app/developers/attachments) contracts.
The adapter uses Linear's official GraphQL endpoint at `https://api.linear.app/graphql`.
A personal API key is sent as the raw `Authorization` value, while an OAuth access token uses `Authorization: Bearer <token>`.
The credential is read only from the configured runtime environment variable and is never tracked, journaled, rendered, included in an error, or propagated into Firstmate script and worker subprocess environments.
Activation removes every Linear variable observed during the Pi session from the ambient provider and worker environment, independently resolves main and supervision request authentication, and refuses any value collision before a model turn can run. Observed credentials remain retained only for restoration at session shutdown, including when a later configuration is otherwise invalid.
The implementation inspects GraphQL `errors` even on HTTP 200 responses.
It follows Relay pagination through `first`, `after`, `pageInfo.hasNextPage`, and `pageInfo.endCursor` under the configured page and issue ceilings.
It treats `RATELIMITED` as retryable and bounds delay with Linear's returned reset headers rather than hard-coding an account limit.

Issue intake filters by configured team, project, and intake-state IDs in GraphQL, then rechecks exact workspace, team, project, status, required labels, blocked labels, and repository mapping locally.
Claim, progress, link, reconciliation, and completion evidence reads also recheck the exact workspace before their mutation.
All required labels must be present, every blocked label must be absent, and one issue must resolve to exactly one scope and one repository.
Linear issue relations contribute directional blocking dependencies.
A label, issue author, priority, or status can satisfy eligibility policy but can never grant authority beyond the local file.
A claim without a stronger-boundary flag may use only predicted path, glob-prefix, and symbol strings grounded in the durable issue title or description; unsupported repository investigation routes to main rather than becoming invented parallelism evidence.

The adapter uses `issueUpdate` for configured state transitions, `commentCreate` for stable ownership and progress evidence, and Linear's documented issue-ID-plus-URL idempotence for repeated `attachmentCreate` pull-request links.

## Claim and reconciliation transaction

A Linear issue gets one deterministic Firstmate task ID and claim ID.
Before any remote mutation, main appends a local claim intent under the issue ID.
The Linear adapter creates or reuses the stable claim marker, transitions to the configured claimed status, rereads comments and status, and refuses competing ownership evidence.
Only a confirmed owned claim may produce a dispatch intent.
Only a confirmed dispatch may receive progress, pull-request, landing, or completion updates.
Duplicate event delivery, repeated tool calls, and restart reconciliation reuse the same claim and task IDs.
They cannot create a second local worker for one issue.

Reconciliation retries an incomplete remote claim, re-evaluates a durable unclaimed dispatch after dependency, collision, or machine capacity clears, retries a persisted owned dispatch intent through the idempotent existing task ID, repairs pending Linear progress and PR links, and records competing evidence as a conflict.
The kill switch blocks every new remote claim, including a local intent whose remote claim is still missing, while still reconciling evidence and continuing an already-owned claim or dispatch intent.
A conflict is escalated and never resolved by inventing a new owner.

## Work claims, collisions, and capacity

Every Linear issue classification requires a structured work claim before selection.
The claim covers repository, blocking dependencies, predicted files, globs, symbols, migration or schema impact, shared external resources, semantic-coupling keys, concrete evidence, validation weight, product surface, and every stronger-boundary boolean.
Unknown file, glob, and symbol scope or missing evidence makes the claim conservative rather than optimistic.

The deterministic conflict graph sorts claims by issue identifier and stable issue ID.
It adds an edge for a dependency, unknown or unsupported scope evidence, a shared mutable external resource, shared semantic coupling, migration or schema work in one repository, a conservatively overlapping file or glob, or a shared symbol.
A greedy deterministic independent-set pass selects only claims with no edge to an already selected claim and with a current worker, active-issue, and heavy-validation slot.
Same-file editing alone is not a universal serialization rule outside this module, but an autonomy work claim with overlapping predicted paths is not allowed to guess that reconciliation will be easy.
Different repositories are not independent when they share mutable external state.

## Landing and stronger boundaries

The mapped Firstmate project must already be registered for a PR-based delivery mode with `+yolo` before doctor can pass.
A conditional `no-mistakes-prod-only` mapping resolves internal-only work to direct PR and product, mixed, or uncertain work to no-mistakes.
A local-only mapping is refused.

Main may call `fm_autonomy action=land` only for an owned dispatched task whose canonical PR URL already has a confirmed idempotent Linear link and a current-code passing result.
The adapter records the PR through the ordinary helper, requires a full valid current head, and journals that expected head before invoking `bin/fm-pr-merge.sh --green-head <sha>`.
A restart verifies a previously accepted merge at that durable head without a second merge, or resumes the same guarded merge intent only while the task still proves current-code passing state.
The guarded mode accepts no caller-controlled merge arguments.
The GitHub path rereads open, draft, mergeable, clean, current-head, and complete check state through `gh-axi`, requires at least one passed check with none failed or pending, and binds the GraphQL merge mutation to `expectedHeadOid`.
The GitLab path retains its existing successful-current-head pipeline checks and adds exact equality with the required green head.
The adapter also rechecks exclusive Linear claim evidence immediately before merge and again after landing.
After merge, it rereads the forge and requires merged evidence at the expected source head.
Only then does it move Linear to the configured completed status.

Destructive, irreversible, production, migration, release, credential, security-sensitive, ambiguous, and red-validation work always routes to main and cannot be autonomously claimed or landed.
The same applies to missing scope, missing evidence, missing authentication, an unavailable configured supervision model, a moved head, no check suite, pending checks, failed checks, a draft, a conflict, a blocked merge, an unconfirmed landing, or any malformed durable record.
The local allowlist never weakens Firstmate's stronger authority rules.

## Maintainer extension points

Add a new event source by implementing the event adapter and preserving stable event identity.
Add a tracker by implementing the issue adapter without changing the supervision tool's authority.
Add a forge by extending the existing guarded Firstmate landing helper rather than merging inside the supervision session.
Do not add a second journal, task lifecycle, worker launcher, validation owner, or merge path.
Any prompt, default model policy, or tool-schema change must capture fresh classifier outputs through the production decision interface, run `bin/fm-autonomy.sh eval` against those held-out recordings, run the environment-gated configured-model guard, and update the accepted baseline only with retained disconfirming cases and explicit review.
