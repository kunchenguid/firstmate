# Promised public reply verification

Audience: maintainer verification.

This record supports three active guarantees for promised public replies made through the myfirstmate relay:

1. A promised final reply survives compaction and restart, reconciles from disk alone, and lands in the original thread exactly once.
2. Work routed to a secondmate uses the typed cross-home commitment instead of a home-local mention link, and a later handoff reports any commitment still bound to the old home.
3. A home that never opted into the relay creates no public-followup state, makes no `tasks-axi` call, and emits no relay guidance.

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

The cross-home selection and handoff guards are pinned by `tests/fm-x-mode.test.sh` and `tests/fm-backlog-handoff.test.sh`.
The first refuses to attach a home-local mention link to secondmate-routed work and points at the typed promised-final registration instead.
The second reports a moved item whose unresolved commitment still names `main/<task-id>`, while keeping a relay-disabled handoff silent.

## Relay-disabled no-op behavior

The relay-disabled case in `tests/fm-public-followup.test.sh` invokes every public-followup entry point against a home with no `.env`, logs every `tasks-axi` invocation, and compares the state tree before and after.
It proves the feature makes no `tasks-axi` call, prints nothing, and creates no `state/public-followup` artifact without coupling that guarantee to session start's independently owned state files.

Each direct public-followup entry point exits at the activation predicate, whose cost was measured over 1000 in-process calls including loop overhead:

```sh
. bin/fm-public-followup-lib.sh
for i in $(seq 1 1000); do fm_pf_relay_active "$HOME_DIR" || true; done
```

```
total_ns=69694000 per_call_us=69
```

The measured cost is roughly 0.07 ms per check, from a single `[ -f "$FM_HOME/.env" ]` test that returns false before anything else runs.
A backlog handoff now performs one such presence check per moved key so it can report a stale cross-home binding when Relay is enabled; with Relay disabled those checks still create no artifact, call no `tasks-axi`, and emit no public-reply guidance.

## Compatibility axes reviewed

Primary harnesses (`claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi`): not applicable after inspection.
Nothing here reads or renders harness-specific state.
The only supervision surfaces touched are the session-start digest, which `bin/fm-supervision-instructions.sh` already renders per harness without knowing this section exists, and the wake payload produced by the existing relay poll, which every harness protocol consumes identically.

Runtime backends (tmux, herdr, zellij, orca, cmux): not applicable after inspection.
No command here reads `state/<id>.meta`'s backend fields, resolves an endpoint, or captures a pane.
The lifecycle integrations run before any backend command and key only on task and home identity: `bin/fm-teardown.sh` refuses cleanup while a reply is owed, `bin/fm-backlog-handoff.sh` reports a binding left on the old home, and `bin/fm-x-link.sh` distinguishes a local task record from work routed to a registered secondmate.
They therefore behave identically on every backend.
