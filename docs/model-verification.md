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

The shipped placement is a standalone verifier rendered by the structured fleet snapshot, which firstmate already reviews every heartbeat.

## Evidence

The evidence is the harness's own session transcript.
The runtime writes it, the agent never authors it, and it records the model that served each assistant turn.
This matters more than convenience: a check that asked the worker what it ran on would be asking the one party that cannot see the answer and has every incentive to report the requested tier.

Only a harness with an empirically verified evidence source is ever treated as verifiable.

| Harness | Evidence source | Status |
| --- | --- | --- |
| Claude | `<config>/projects/<encoded-cwd>/<session>.jsonl`, `.message.model` per assistant record | Verified and wired. |
| Codex, OpenCode, Pi, Grok, Kimi | not established | Reported `unverifiable`, never assumed correct. |

`<config>` is `$CLAUDE_CONFIG_DIR` when set, else `~/.claude`.
`bin/fm-spawn.sh` forwards firstmate's own `CLAUDE_CONFIG_DIR` onto a claude launch, so resolving it the same way reads the store the worker actually wrote to.
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

`bin/fm-spawn.sh` records `spawned_at=` (epoch seconds) alongside `model=`.

A worktree drawn from a reusable pool can still carry the transcripts of a previous occupant, whose model would otherwise be attributed to the current task.
Those transcripts are never appended to again, so their modification time precedes this dispatch, and the timestamp separates them.

A record written before `spawned_at=` existed cannot be bound.
In that case unanimous evidence is still attributed, with the weaker binding disclosed in the detail text, and disagreeing evidence is reported `unverifiable` rather than guessed at.

## Surfacing

`bin/fm-fleet-snapshot.sh` carries `model:{verdict,recorded,actual[],source,detail}` per task.
An unreadable or absent verifier answer becomes an explicit `unverifiable` verdict there, so a broken verifier can never render as a clean one.

`bin/fm-fleet-view.sh` renders a `## Model Routing` section listing every task whose verdict is `mismatch` or `unverifiable`, and renders nothing at all when every worker verifies.
Correctly routed work therefore looks exactly as it did before.

## Automated validation

`tests/fm-model-verify.test.sh` owns the acceptance matrix and is registered in the `pure-contract-unit` family in `bin/fm-test-run.sh`.
It covers family-alias and pinned-id comparison, the context-window suffix, a downgrade below the dispatched family, a mid-dispatch model change where one value still matches, every `unverifiable` path, the `pending` and `unpinned` no-verdict outcomes, the synthetic placeholder in both directions, dispatch-timestamp binding against a reused worktree in both directions, secondmate evidence resolved from its own home, `--all` exiting on the worst verdict, and the structured output.

`tests/fm-fleet-snapshot-view.test.sh` covers the snapshot field and the view section, including that a correctly routed fleet renders no section.

Run:

```sh
bin/fm-lint.sh
tests/fm-model-verify.test.sh
tests/fm-fleet-snapshot-view.test.sh
```
