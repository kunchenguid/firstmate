# Dispatched-model verification

This document is the authoritative human-readable contract for checking that a dispatched worker actually ran on the model firstmate recorded for it.

The shipped mechanism is `bin/fm-model-verify.sh`, a read-only verifier surfaced through `bin/fm-fleet-snapshot.sh` and `bin/fm-fleet-view.sh`.
It is unrelated to the delegation fence in [`subagent-guard.md`](subagent-guard.md), which stops a primary from creating work the fleet never sees.
This one assumes dispatch happened correctly and asks a different question: did the worker run on the tier it was dispatched with?

## Why this exists

Firstmate resolves a concrete model and effort at intake, sometimes after a deliberate quota-balanced choice across candidate profiles, and `bin/fm-spawn.sh` records `model=` in `state/<id>.meta`.

That record is what was **requested**.
Nothing verified what **ran**.
A worker served below its dispatched tier still reports done, and the record still reads as the intended model, so every later quota-aware dispatch decision built on that record is fiction.

The failure class was reproduced one level down, in the harness's own subagent routing, and documented in the 2026-07-28 investigation.
Model resolution there is explicit model, then the named subagent type's own definition frontmatter, then the parent - so a contract assuming an omitted model inherits the parent is wrong about the middle clause.
Real transcripts on the development host showed an Opus 4.8 parent's omitted-model dispatch running on Sonnet 5, and a Fable 5 parent's running on Opus 4.8.
Other dispatches in the same sample did inherit correctly, which is what makes the class dangerous: it is right often enough to look right.

## Where the check belongs

Three placements were considered.

- **At spawn time.** Rejected: at spawn the worker has produced no turn, so there is nothing to compare against. Verification is necessarily after the fact.
- **In a `PostToolUse` guard.** Rejected as the primary mechanism: that surface observes `resolvedModel` for the harness's own delegation tool, which a firstmate primary already denies, and it never observes a `bin/fm-spawn.sh` dispatch - the record actually at risk. The empirical work behind that lever is recorded in [`verification/model-verification.md`](verification/model-verification.md) and stays available if the delegation surface ever needs its own check.
- **Folded into `bin/fm-crew-state.sh`.** Rejected: that helper owns one contract, reconciling a crew's current run state. Model provenance is orthogonal to run state.

The shipped placement is a standalone verifier rendered by the structured fleet snapshot, which firstmate already reviews every heartbeat, and required by non-forced teardown before any evidence or task metadata is removed.

## Evidence

The evidence is the harness's own session transcript.
The runtime writes it, the agent never authors it, and it records the model that served each assistant turn.
This matters more than convenience: a check that asked the worker what it ran on would be asking the one party that cannot see the answer and has every incentive to report the requested tier.

Only a harness with an empirically verified evidence source is ever treated as verifiable.

| Harness | Evidence source | Status |
| --- | --- | --- |
| Claude | `<config>/projects/<encoded-cwd>/<session>.jsonl`, `.message.model` per assistant record | Verified and wired. |
| Codex, OpenCode, Pi, Grok, Kimi | not established | Reported `unverifiable`, never assumed correct. |

`<config>` is the canonical `model_evidence_store=` persisted in the dispatch record.
`bin/fm-spawn.sh` resolves symlinks and parent components in filesystem order for `$CLAUDE_CONFIG_DIR` when set, else `~/.claude`, records that physical identity before launch, and explicitly sets every Claude launch to the same store.
If the resolved physical path contains a newline, canonicalization fails and spawn refuses before serializing or launching with an altered store.
Later verification never replaces that recorded store with the verifier process's ambient configuration.
The directory name encodes the worker's working directory with every character outside `[A-Za-z0-9]` replaced by `-`.

The bounded follow-up for the unverified harnesses is the same shape as the Codex procedure in [`subagent-guard.md`](subagent-guard.md): on a host with the binary installed, establish where that harness records the serving model, then add an adapter and extend the verification record.
Wiring an unvalidated evidence path would trade a known gap for a false verdict, which is worse than the gap.

## Verdicts

A verdict is never `match` unless a model was actually read and actually compared.

| Verdict | Meaning | Exit |
| --- | --- | --- |
| `match` | every model attributed to this worker satisfies the record | 0 |
| `mismatch` | at least one attributed model does not | 3 |
| `unverifiable` | the record cannot be checked at all | 4 |
| `pending` | an adapter exists and the worker has not produced a model-attributed turn yet | 0 |
| `unpinned` | `model=default`: no tier was pinned, so there is no record for the runtime to contradict | 0 |

`pending` and `unpinned` are explicitly no-verdict outcomes, not passes.
Nothing may render them as verified.
Only the exact record `model=default` is unpinned.
A missing or empty `model=` is malformed dispatch metadata and therefore `unverifiable`.

`unverifiable` covers a harness with no evidence adapter, evidence that cannot be located or read, `jq` absent, a durable record that names no working directory, and evidence that cannot be attributed to this dispatch.
This is the load-bearing design rule: **a guard that silently passes when it cannot read the truth is worse than no guard, because it manufactures false confidence.**
Every unreadable path therefore ends in `unverifiable`, never in silence and never in `match`.

## Comparison granularity

A record is compared at the granularity it expresses.

- A bare family alias (`opus`) promises a tier, so any member of that family satisfies it.
- A specific model id (`claude-opus-4-8`) promises that model, so another version of the same family is a mismatch.

The runtime appends a context-window suffix such as `claude-opus-5[1m]`; it names the same model and is stripped before comparison.
`<synthetic>` is a runtime placeholder for messages no model served.
It names no model, so it is dropped: it can neither manufacture a mismatch nor stand in as evidence of a match.

## Binding evidence to one dispatch

Before launching Claude, `bin/fm-spawn.sh` records the canonical `model_evidence_store=`, `model_evidence_watermark=claude-transcript-v1`, and one `model_evidence_before=` row for every transcript identity already present in the worker's transcript directory.
The endpoint, worktree, requested model, and dispatch timestamp are published first, so watermark failure leaves a recoverable durable record rather than an unowned live endpoint.

A worktree drawn from a reusable pool can still carry the transcripts of a previous occupant, whose model would otherwise be attributed to the current task.
The verifier excludes exactly those identities, so a prior transcript and the new worker's transcript remain distinguishable even when both files share the one-second modification timestamp recorded by the filesystem.

`spawned_at=` remains as a compatibility anchor for records without an identity watermark.
A transcript whose modification time equals that legacy anchor is ambiguous and therefore `unverifiable`, never a match.
A present but empty or nonnumeric `spawned_at=` is malformed and therefore `unverifiable`; only a genuinely absent field enters legacy attribution.
A current record with a timestamp or watermark but no evidence-store identity is also `unverifiable`.

A record written before either binding existed cannot be bound.
In that case unanimous evidence is still attributed, with the weaker binding disclosed in the detail text, and disagreeing evidence is reported `unverifiable` rather than guessed at.

## Surfacing

`bin/fm-fleet-snapshot.sh` carries `model:{verdict,recorded,actual[],source,detail}` per task.
An unreadable or absent verifier answer becomes an explicit `unverifiable` verdict there, so a broken verifier can never render as a clean one.

`bin/fm-teardown.sh` always runs terminal verification before cleanup.
Non-forced teardown accepts only `match` or `unpinned`.
It refuses on `mismatch`, `unverifiable`, or `pending` while the worktree, transcript evidence, and task metadata still exist for inspection.
Forced teardown surfaces the verdict but retains its existing authority to discard, including for every recursively cleaned secondmate child.

`bin/fm-fleet-view.sh` renders a `## Model Routing` section listing every task whose verdict is `mismatch` or `unverifiable`.
It deliberately omits `pending` because every healthy worker is briefly pending before its first model-attributed turn, and a routine false alarm would make the section less useful.
The residual gap is explicit: a worker that never produces a readable model turn remains `pending` and is not raised in the human fleet view, while its no-verdict state remains visible in the structured snapshot's per-task model object and blocks non-forced teardown.
Deliberate `unpinned` dispatches are also omitted, and correctly routed work therefore looks exactly as it did before.

## Automated validation

`tests/fm-model-verify.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
It covers family-alias and pinned-id comparison, the context-window suffix, a downgrade below the dispatched family, a mid-dispatch model change where one value still matches, enumeration and modification-time failures, the `pending` and exact-`default` `unpinned` outcomes, missing model metadata, malformed timestamps, canonical evidence-store binding across ambient configuration changes, symlink-plus-parent paths, and newline-bearing physical paths, the synthetic placeholder in both directions, exact transcript-identity binding including the equal-second boundary, legacy timestamp binding, secondmate evidence resolved from its own home, `--all` exiting on the worst verdict, and the structured output.

`tests/fm-fleet-snapshot-view.test.sh` covers the snapshot field and the view section, including that a correctly routed fleet renders no section.
It also proves that bounded secondmate-home summaries do not scan model transcripts.

`tests/fm-spawn-dispatch-profile.test.sh` covers durable metadata publication before watermark capture, preservation when capture fails, explicit default-store pinning over a backend daemon's ambient configuration, and refusal before launch for a newline-bearing physical store.

`tests/fm-teardown.test.sh` covers terminal refusal before cleanup on a mismatch, unchanged teardown on a match, forced surfacing without loss of discard authority, and recursive child surfacing.

Run:

```sh
bin/fm-lint.sh
tests/fm-model-verify.test.sh
tests/fm-fleet-snapshot-view.test.sh
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-teardown.test.sh
```
