# Promised public reply verification

Audience: maintainer verification.

This record supports four active guarantees for promised public replies made through the myfirstmate relay:

1. A promised final reply survives compaction and restart, reconciles from disk alone, and lands in the original thread exactly once.
2. A home that never opted into the relay pays nothing for any of it.
3. Delivering a final does not close the public loop: the registration is retained as `state=delivered` until `retire --reason`, session start surfaces an `open-loop` line, and `rechain` can bind follow-on work to the same thread.
4. A first registration with no registry lock already held succeeds under stock macOS Bash 3.2 with `set -u`.

[`docs/configuration.md`](../configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, [`docs/architecture.md`](../architecture.md#optional-relay) owns the mechanism boundary, and `tasks-axi public-followup --help` owns the typed obligation schema.
Task chronology and delivery evidence stay outside this record.

## Environment

Recorded 2026-09-01 on Darwin 25.5.0 (arm64) with GNU bash 5.3.9, tasks-axi 0.2.5, jq 1.8.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
The stock macOS compatibility lane additionally runs the focused first-registration regression with `/bin/bash` 3.2.57 and a real `tasks-axi` installation.
The relay is a fakebin `curl` in every case, so no public post is ever made; `tasks-axi` and `jq` are the real tools, because stubbing the obligation state machine would verify nothing.

## Restart end-to-end and regressions

```sh
bash tests/fm-public-followup.test.sh
```

```
ok - the suite's seeding never reaches a backlog named by ambient TASKS_AXI_FILE/BACKEND
ok - outcome text is collapsed to one line, bounded by codepoint, and never corrupts characters
ok - restart end-to-end: typed result reconciles from disk and delivers one reply to the original thread
ok - duplicate terminal results, restart replay, and repeated delivery are all no-ops
ok - wrong source, wrong work id, stale generation, malformed, unsupported deliverable, and forged identity are all refused
ok - a relay transport failure is held as retryable with no false completion, and the retry posts once
ok - a dry-run records no public delivery and leaves the commitment retryable
ok - a late success receipt closes the exact attempt with no second post, and a mismatched attempt is refused
ok - typed terminal cleanup clears the legacy link without posting
ok - a delivery interrupted between post and receipt refuses to repost
ok - typed delivery refuses to post when its cleanup registration is missing
ok - relay-disabled unmarked teardown runs no public-followup work
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
ok - first register succeeds with an empty lock list under /bin/bash
ok - registration replay preserves delivered and retired loop states
ok - redelivery does not report a retired loop as open
ok - rechain refuses an unrelated existing destination
ok - pending skips a registration retired during settlement
ok - retire --reason closes the loop and drops the open-loop line
ok - retention creates no false teardown refusal and pending no longer prunes
ok - expiry escalation is pinned by FMX_NOW_OVERRIDE
ok - brief fails explicitly when typed deliverable keys are unavailable
ok - pre-change registrations are open loops and un-rechainable, never a crash
ok - teardown reports an unreconciled legacy Relay link
ok - a local work home's emit path is unchanged
```

The restart case is the end-to-end proof of guarantee 1.

The dropped-baton case is the end-to-end proof of guarantee 3.
It delivers a `report-ready` promised-final, asserts the registration is retained and `pending` prints `open-loop`, then shows that an unbound follow-on ship is not teardown-refused (the one-variable control still refuses the moment a commitment is registered for that work).
`rechain` then binds a fresh `pr-merged` obligation onto the same request/thread, and a second follow-up carries the shipped text.
`retire --reason` records its private receipt before removal and is the only close; replayed registration cannot reopen that retired loop.
The concurrency and interrupted-bind cases verify that one delivered source cannot fork and that retry converges on the same destination obligation.
A pre-change on-disk record (no `state=`, no `request_context_b64`) is an open loop and un-rechainable rather than a crash.
The stock macOS Bash lane in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) sets `FM_TEST_ONLY=test_first_register_succeeds_with_empty_lock_list_under_bash32` and runs `tests/fm-public-followup.test.sh` through real `/bin/bash` 3.2, proving the first `register` path is safe when its registry lock list starts empty.

The local emit case runs exactly the command printed by `brief`, proving that a bound worker publishes the typed result directly into the owning home's `events/` inbox. Unsupported staging and cross-machine route options refuse instead of recreating the retired remote-home transport.

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

Primary harnesses (`pi`, `codex`): not applicable after inspection.
Nothing here reads or renders harness-specific state.
The only supervision surfaces touched are the session-start digest, which `bin/fm-supervision-instructions.sh` already renders per harness without knowing this section exists, and the wake payload produced by the existing relay poll, which every harness protocol consumes identically.

The Herdr runtime backend is not applicable after inspection.
No command here reads `state/<id>.meta`'s backend fields, resolves an endpoint, or captures a pane.
The lifecycle integrations are backlog-handoff warnings, promotion rechain hints, and `bin/fm-teardown.sh`'s owed-reply refusal plus non-blocking open-loop and legacy `x_request=` warnings.
They inspect home, task, parent-binding, and registration records rather than backend fields or endpoints, so the retained integration has no terminal-provider branch.
