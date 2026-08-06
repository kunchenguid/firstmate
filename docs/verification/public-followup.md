# Promised public reply verification

Audience: maintainer verification.

This record supports two active guarantees for promised public replies made through the myfirstmate relay:

1. A promised final reply survives compaction and restart, reconciles from disk alone, and lands in the original thread exactly once.
2. A home that never opted into the relay pays nothing for any of it.

[`docs/configuration.md`](../configuration.md#promised-public-replies-statepublic-followup) owns the operator-facing contract, [`docs/architecture.md`](../architecture.md#optional-relay) owns the mechanism boundary, and `tasks-axi public-followup --help` owns the typed obligation schema.
Task chronology and delivery evidence stay outside this record.

## Environment

Recorded 2026-07-30 on Darwin 25.5.0 (arm64) with GNU bash 5.3.9, tasks-axi 0.2.3, jq 1.8.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).
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
ok - a late success receipt closes the exact attempt with no second post, and a mismatched attempt is refused
ok - a delivery interrupted between post and receipt refuses to repost
ok - a child home reports typed results but can never become the outward-post owner
ok - the retained private request context keeps the original thread deliverable after inbox cleanup
ok - cleanup refuses while a public reply is owed and proceeds once it has landed
ok - a relay-disabled home runs no tasks-axi call, prints nothing, and gains no artifact
ok - a relay-enabled home with no commitments makes no backlog call and stays silent
ok - a relay-exhausted follow-up binding is escalated rather than retried into the thread
ok - the relay poll stays inert without a token, silent with no commitments, and surfaces a new result once
ok - startup surfaces unresolved public commitments only in a relay home that owes one
ok - typed public-followup records carry only public-safe summaries and deliverables
```

The first case is the end-to-end proof.
It reproduces the stranded state first (work bound, no reconciled terminal result, delivery refused with "still waiting on its bound work" and zero posts), then has a secondmate-shaped child report a typed `pr-merged` result, deletes the drained inbox payload, reconciles from disk, and asserts exactly one `connector/followup` call carrying the original `request_id`, a validated `posted` receipt, and a Done obligation.

The existing Relay suite is unchanged by this work:

```sh
bash tests/fm-x-mode.test.sh | grep -c '^ok -'
```

```
103
```

## Relay-disabled zero overhead

A home with no `.env` at all, a `tasks-axi` shim that logs every invocation, and a full session-start run:

```sh
find "$HOME_DIR/state" | LC_ALL=C sort > state-before.txt
FAKE_TASKS_AXI_LOG=tasks-axi.log bin/fm-session-start.sh > session-start.out 2>&1
find "$HOME_DIR/state" | LC_ALL=C sort > state-after.txt
grep -c 'public-followup' tasks-axi.log
grep -ci 'public commitment' session-start.out
diff state-before.txt state-after.txt | grep '^>'
```

```
0
0
> <home>/state/.lock
> <home>/state/.pr-check-migration-scan-v1
> <home>/state/.pr-check-migration-v1
> <home>/state/.wake-queue
```

No `tasks-axi public-followup` invocation, no public-commitments output, and no `state/public-followup` directory.
The four created paths are session-start's pre-existing session lock, PR-check migration markers, and wake queue, none of which this work touches.

The whole added cost in that home is the activation predicate, measured over 1000 in-process calls including loop overhead:

```sh
. bin/fm-public-followup-lib.sh
for i in $(seq 1 1000); do fm_pf_relay_active "$HOME_DIR" || true; done
```

```
total_ns=69694000 per_call_us=69
```

Roughly 0.07 ms per session start, from a single `[ -f "$FM_HOME/.env" ]` test that returns false before anything else runs.

## Compatibility axes reviewed

Primary harnesses (`claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`): not applicable after inspection.
Nothing here reads or renders harness-specific state.
The only supervision surfaces touched are the session-start digest, which `bin/fm-supervision-instructions.sh` already renders per harness without knowing this section exists, and the wake payload produced by the existing relay poll, which every harness protocol consumes identically.

Runtime backends (tmux, herdr, zellij, orca, cmux): not applicable after inspection.
No command here reads `state/<id>.meta`'s backend fields, resolves an endpoint, or captures a pane.
The one lifecycle integration is `bin/fm-teardown.sh`'s refusal, which runs before any backend command and keys only on the task id, so it behaves identically on every backend.
