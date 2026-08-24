# Promised public reply verification

Audience: maintainer verification.

This record supports three active guarantees for promised public replies made through the myfirstmate relay:

1. A promised final reply survives compaction and restart, reconciles from disk alone, and lands in the original thread exactly once.
2. A home that never opted into the relay pays nothing for any of it.
3. Delivering a final does not close the public loop: the registration is retained as `state=delivered` until `retire --reason`, session start surfaces an `open-loop` line, and `rechain` can bind follow-on work to the same thread.

[`docs/configuration.md`](../configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, [`docs/architecture.md`](../architecture.md#optional-relay) owns the mechanism boundary, and `tasks-axi public-followup --help` owns the typed obligation schema.
Task chronology and delivery evidence stay outside this record.

## Environment

Recorded 2026-08-21 on Darwin 25.5.0 (arm64) with GNU bash 5.3.9, tasks-axi 0.2.5, jq 1.8.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
The relay is a fakebin `curl` in every case, so no public post is ever made; `tasks-axi` and `jq` are the real tools, because stubbing the obligation state machine would verify nothing.

## Restart end-to-end and regressions

```sh
bash tests/fm-public-followup.test.sh
```

```
ok - outcome text is collapsed to one line, bounded by codepoint, and never corrupts characters
ok - restart end-to-end: typed result reconciles from disk and delivers one reply to the original thread
ok - duplicate terminal results, restart replay, and repeated delivery are all no-ops
ok - wrong source, wrong work id, stale generation, malformed, unsupported deliverable, and forged identity are all refused
ok - a relay transport failure is held as retryable with no false completion, and the retry posts once
ok - a dry-run records no public delivery and leaves the commitment retryable
ok - a late success receipt closes the exact attempt with no second post, and a mismatched attempt is refused
ok - typed terminal cleanup clears the legacy link without posting
ok - a delivery interrupted between post and receipt refuses to repost
ok - a child home reports typed results but can never become the outward-post owner
ok - typed delivery refuses to post when its cleanup registration is missing
ok - marked secondmate teardown resolves its parent and fails closed when unavailable
ok - local seeding publishes durable parent state before its identity marker
ok - a lost launch-time parent binding is recovered from the durable local record
ok - a durable local parent record does not bypass a genuinely missing parent-side registration
ok - unknown durable parent fields remain forward-compatible
ok - conflicting live and durable parent bindings fail closed
ok - unsafe durable parent records fail closed before cleanup
ok - a NUL-bearing durable parent record fails closed before cleanup
ok - relay-disabled unmarked teardown runs no public-followup work
ok - a marked child proceeds without tasks-axi when its parent relay is disabled
ok - secondmate parent resolution matches the durable registry id literally
ok - traversal-shaped registrations are rejected before path construction or posting
ok - pending keeps registrations when tasks-axi returns malformed JSON
ok - the retained private request context keeps the original thread deliverable after inbox cleanup
ok - cleanup refuses while a public reply is owed and proceeds once it has landed
ok - a relay-disabled home runs no tasks-axi call, prints nothing, and gains no artifact
ok - a relay-enabled home with no commitments makes no backlog call and stays silent
ok - a relay-exhausted follow-up binding is escalated rather than retried into the thread
ok - the relay poll stays inert without a token, silent with no commitments, and surfaces a new result once
ok - startup surfaces unresolved public commitments only in a relay home that owes one
ok - typed public-followup records carry only public-safe summaries and deliverables
ok - dropped-baton regression: delivery retains the loop and pending prints open-loop
ok - CONTROL: the identical teardown REFUSES the moment a commitment is registered
ok - rechain posts the shipped follow-on into the same thread
ok - rechain resumes the same obligation after an interrupted bind
ok - concurrent rechains cannot fork one delivered source
ok - failed rechain retirement keeps the source claimed by one resumable destination
ok - registration replay preserves delivered and retired loop states
ok - redelivery does not report a retired loop as open
ok - retire closes delivered loops after secondmate home removal
ok - retire fails closed for an unbound existing secondmate
ok - retire fails closed when a secondmate ID is reassigned
ok - rechain refuses an unrelated existing destination
ok - pending skips a registration retired during settlement
ok - retire --reason closes the loop and drops the open-loop line
ok - retention creates no false teardown refusal and pending no longer prunes
ok - expiry escalation is pinned by FMX_NOW_OVERRIDE
ok - brief fails explicitly when typed deliverable keys are unavailable
ok - pre-change registrations are open loops and un-rechainable, never a crash
ok - teardown reports an unreconciled legacy Relay link
ok - secondmate promotion matches teardown parent resolution
```

The restart case is the end-to-end proof of guarantee 1.
It reproduces the stranded state first (work bound, no reconciled terminal result, delivery refused with "still waiting on its bound work" and zero posts), then has a secondmate-shaped child report a typed `pr-merged` result, deletes the drained inbox payload, reconciles from disk, and asserts exactly one `connector/followup` call carrying the original `request_id`, a validated `posted` receipt, and a Done obligation.

The dropped-baton case is the end-to-end proof of guarantee 3.
It delivers a `report-ready` promised-final, asserts the registration is retained and `pending` prints `open-loop`, then shows that an unbound follow-on ship is not teardown-refused (the one-variable control still refuses the moment a commitment is registered for that work).
`rechain` then binds a fresh `pr-merged` obligation onto the same request/thread, and a second follow-up carries the shipped text.
`retire --reason` records its private receipt before removal and is the only close; replayed registration cannot reopen that retired loop.
The concurrency and interrupted-bind cases verify that one delivered source cannot fork and that retry converges on the same destination obligation.
A pre-change on-disk record (no `state=`, no `request_context_b64`) is an open loop and un-rechainable rather than a crash.

The existing Relay mention suite (`tests/fm-x-mode.test.sh`) is unchanged by this work.

## Relay-disabled zero overhead

The relay-disabled case in `tests/fm-public-followup.test.sh` invokes every public-followup entry point against a home with no `.env`, logs every `tasks-axi` invocation, and compares the state tree before and after.
It proves the feature makes no `tasks-axi` call, prints nothing, and creates no `state/public-followup` artifact without coupling that guarantee to session start's independently owned state files.

The whole added cost in that home is the activation predicate, measured over 1000 in-process calls including loop overhead:

```sh
. bin/fm-public-followup-lib.sh
for i in $(seq 1 1000); do fm_pf_relay_active "$HOME_DIR" || true; done
```

```
total_ns=22305959 per_call_us=22
```

Roughly 0.02 ms per session start, from a single `[ -f "$FM_HOME/.env" ]` test that returns false before anything else runs.

## Compatibility axes reviewed

Primary harnesses (`claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`): not applicable after inspection.
Nothing here reads or renders harness-specific state.
The only supervision surfaces touched are the session-start digest, which `bin/fm-supervision-instructions.sh` already renders per harness without knowing this section exists, and the wake payload produced by the existing relay poll, which every harness protocol consumes identically.

Runtime backends (tmux, herdr, zellij, orca, cmux): not applicable after inspection.
No command here reads `state/<id>.meta`'s backend fields, resolves an endpoint, or captures a pane.
The lifecycle integrations are backlog-handoff warnings, promotion rechain hints, and `bin/fm-teardown.sh`'s owed-reply refusal plus non-blocking open-loop and legacy `x_request=` warnings.
They inspect home, task, parent-binding, and registration records rather than backend fields or endpoints, so they behave identically on every backend.
