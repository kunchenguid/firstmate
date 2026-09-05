# Promised public reply verification

Audience: maintainer verification.

This record supports six active guarantees for promised public replies made through the myfirstmate relay:

1. A promised final reply survives compaction and restart, reconciles from disk alone, and lands in the original thread exactly once.
2. A home that never opted into the relay pays nothing for any of it.
3. Delivering a final does not close the public loop: the registration is retained as `state=delivered` until `retire --reason`, session start surfaces an `open-loop` line, and `rechain` can bind follow-on work to the same thread.
4. A first registration with no registry lock already held succeeds under stock macOS Bash 3.2 with `set -u`.
5. A public loop whose work lives in a REMOTE secondmate home retires when readable remote state proves no link exists, or after readable and writable remote state clears the matching bound legacy Relay link; unreadable state, a non-writable matching link, an identity mismatch, a metadata lock it cannot acquire within its bound, or unconfirmed completion retains the loop instead of hanging, and `--force` still covers only the unresolved obligation.
6. Work bound to a REMOTE secondmate home can report its typed terminal result: the instructions name paths that exist on the worker's own machine, the owning home collects results for open registrations over that route, an unreachable route fails loudly, an empty reachable route is a healthy no-op, and a non-open registration is skipped without contact.

[`docs/configuration.md`](../configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, [`docs/architecture.md`](../architecture.md#optional-relay) owns the mechanism boundary, and `tasks-axi public-followup --help` owns the typed obligation schema.
Task chronology and delivery evidence stay outside this record.

## Environment

Recorded 2026-09-01 on Darwin 25.5.0 (arm64) with GNU bash 5.3.9, tasks-axi 0.2.5, jq 1.8.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
The stock macOS compatibility lane additionally runs the focused first-registration regression with `/bin/bash` 3.2.57 and a real `tasks-axi` installation.
The relay is a fakebin `curl` in every case, so no public post is ever made; `tasks-axi` and `jq` are the real tools, because stubbing the obligation state machine would verify nothing.
The remote-route cases fake only the SSH binary at the `FM_SSH_BIN` process seam and then run the real tracked `fm-remote-entrypoint.sh` against a local checkout standing in for the remote one, so the work that has to reach the remote home actually runs there; no host and no network are involved.

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
ok - first register succeeds with an empty lock list under /bin/bash
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
ok - a public loop bound to a remote secondmate home delivers and retires
ok - delivered remote registrations skip offline collection routes
ok - --force still covers only the unresolved obligation, not the link clear
ok - retire fails closed when a remote route is reassigned
ok - retire fails closed when remote state is unreadable
ok - retire fails closed when remote state is non-writable
ok - retire accepts link absence in non-writable remote state
ok - the guarded remote clear refuses a lock it cannot acquire instead of hanging
ok - an unconfirmed remote clear is unknown completion, never a silent close
ok - a typed terminal result emitted in a remote work home reaches the owning home
ok - an unreachable remote work home fails loudly instead of reporting an empty inbox
ok - an unreadable remote outbox fails collection without losing its result
ok - invalid registration fails collection without dropping the staged result
ok - unsafe registration entries fail collection without dropping staged results
ok - route loss fails brief and consume without dropping the staged result
ok - empty reachable remote collection remains a healthy no-op
ok - remote brief rejects traversal and empty route path components
ok - a local work home's emit path is unchanged
ok - a duplicate report from a remote work home stays a no-op
ok - staging requires the matching secondmate firstmate home
```

The restart case is the end-to-end proof of guarantee 1.
It reproduces the stranded state first (work bound, no reconciled terminal result, delivery refused with "still waiting on its bound work" and zero posts), then has a secondmate-shaped child report a typed `pr-merged` result, deletes the drained inbox payload, reconciles from disk, and asserts exactly one `connector/followup` call carrying the original `request_id`, a validated `posted` receipt, and a Done obligation.

The dropped-baton case is the end-to-end proof of guarantee 3.
It delivers a `report-ready` promised-final, asserts the registration is retained and `pending` prints `open-loop`, then shows that an unbound follow-on ship is not teardown-refused (the one-variable control still refuses the moment a commitment is registered for that work).
`rechain` then binds a fresh `pr-merged` obligation onto the same request/thread, and a second follow-up carries the shipped text.
`retire --reason` records its private receipt before removal and is the only close; replayed registration cannot reopen that retired loop.
The concurrency and interrupted-bind cases verify that one delivered source cannot fork and that retry converges on the same destination obligation.
A pre-change on-disk record (no `state=`, no `request_context_b64`) is an open loop and un-rechainable rather than a crash.
The stock macOS Bash lane in [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) sets `FM_TEST_ONLY=test_first_register_succeeds_with_empty_lock_list_under_bash32` and runs `tests/fm-public-followup.test.sh` through real `/bin/bash` 3.2, proving the first `register` path is safe when its registry lock list starts empty.

The eight remote-route cases are the proof of guarantee 5.
A remote secondmate home exists only on its own machine, so its registration records no local path, and every close that must first clear the bound legacy Relay link had nothing local to act on.
The first case pins that empty recorded path so it cannot go vacuous, then drives `deliver` and `retire` end to end and asserts the matching link inside the remote home is actually gone and the retirement receipt is written.
The second case shows `--force` still governs only the unresolved-obligation refusal: a plain `retire` of an unresolved remote loop is still refused with the remote link untouched, while a forced one closes and clears it.
The reassignment case replaces a delivered loop's route with a remote home whose reused work ID carries another Relay request and asserts that retirement retains the registration and leaves the replacement link untouched.
The unreadable-state case makes the remote state directory non-searchable while it still contains a matching link and proves that an unconfirmable path fails closed without mutation.
The two non-writable-state cases prove that a matching link refuses before lock acquisition because mutation is impossible, while a confirmed absent link succeeds because no mutation is needed.
The unacquirable-lock case is the proof that the guarded clear refuses rather than wedges.
It leaves the remote state directory WRITABLE, so the refusal can only come from the bounded lock wait and never from the writability precondition, and holds the metadata lock with a genuinely live process so the lock can never be reclaimed as stale.
The writability precondition narrows the wedge window but cannot close it, because the parent can turn non-writable between that check and lock creation and a live holder is indistinguishable from it at the acquire; the ordinary unbounded wait retries forever, so before the bounded acquire this path hung with nothing reported instead of returning the reconciliation refusal.
The case asserts the refusal, the retained registration, the absent receipt, the untouched remote link, and that the call returns at all, which is the observable difference from a wait that never ends.
The final case makes the transport unreachable and asserts the close is refused with the registration retained, the remote link untouched, and unknown completion named rather than reported as a definite failure.
A remote home running an older Firstmate copy does not recognize the guarded clear flag and therefore fails closed through the same retained-for-reconciliation message; operators must update that home before retrying, and there is deliberately no unguarded fallback.

## Reporting a terminal result from a remote work home

The twelve collection and emit cases are the proof of guarantee 6.
They share the same faked-transport fixture as the retire cases above, so the collection that has to happen actually happens with no live host and no network.

The first emit case pins the trap condition before asserting anything else: the instructions a remote-bound worker receives must not name the owning home's own path, which exists only on the owning machine.
It then runs exactly the printed command, so what is verified is the instruction the worker actually gets rather than a hand-written approximation, and asserts the typed result reaches the owning home's inbox, that `consume` reports the loop ready, and that the staged copy is retired from the work home afterwards.
The duplicate case replays both halves - the worker re-reports and the owning home re-collects - and asserts no second ready announcement and no change to the promise, so a retained staged copy after a failed retirement cannot produce a second public reply.
The route and record refusal cases assert that unreachable transport, an unreadable outbox, invalid or unsafe registration state, and route loss all fail loudly without dropping the staged result.
The empty-route case proves that a reachable route with nothing staged is an ordinary silent no-op, while the delivered-registration case proves a settled loop never contacts an offline route.
The route-path and staging-destination cases prove that the printed remote command cannot target an unsafe or mismatched home.
The local case asserts the unchanged path in the same terms: a main-home work binding is still told to emit straight into this home with this checkout's script, that command still runs as printed, and it still publishes into `events/` with nothing staged.

Outward delivery for a remote-home loop is the separate legacy-link clear proven above, not part of this collection path.

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

Runtime backends (tmux, herdr): not applicable after inspection.
No command here reads `state/<id>.meta`'s backend fields, resolves an endpoint, or captures a pane.
The lifecycle integrations are backlog-handoff warnings, promotion rechain hints, and `bin/fm-teardown.sh`'s owed-reply refusal plus non-blocking open-loop and legacy `x_request=` warnings.
They inspect home, task, parent-binding, and registration records rather than backend fields or endpoints, so they behave identically on every backend.
