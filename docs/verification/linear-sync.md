# Linear synchronization verification

Audience: maintainer verification.

This record supports five active guarantees for firstmate's durable Linear synchronization:

1. A handback target is established, never inferred: a missing or ambiguous target refuses.
2. A comment Linear committed but never acknowledged is recovered from Linear's own copy, so no retry, crash, or restart produces a duplicate comment or a second status change.
3. Two concurrent deliveries cannot both post, and an abandoned lock never strands a handback.
4. A disconnected, misconfigured, or unreachable Linear preserves the owed handback, surfaces one concise blocker, and never becomes a completion.
5. A home that never bound a Linear issue pays nothing: no artifact, no output, no extra call.

[`docs/linear-sync.md`](../linear-sync.md) owns the operator contract, [`docs/configuration.md`](../configuration.md#linear-synchronization-configlinearenv--statelinear) owns the two files an operator sets, and `bin/fm-linear-sync.sh --help` owns the commands and flags.
Task chronology and delivery evidence stay outside this record.

## Environment

Recorded 2026-08-20 on Darwin 25.5.0 (arm64, macOS 26.5.2) with GNU bash 3.2.57(1), jq 1.7.1-apple, git 2.50.1, curl 8.7.1, and ShellCheck 0.11.0 (the version `bin/fm-lint.sh` pins).

Linear is a hermetic fake transport in every automated case, so no Linear mutation is ever made and no credential is ever needed.
`FM_LINEAR_TRANSPORT` is the seam: `bin/fm-linear-sync.sh` reaches Linear only through the two-argument transport contract in `bin/fm-linear-transport.sh`, and the suite points that at a fake workspace held in a temp directory.
The one case that exercises the real transport substitutes a fake `curl` and asserts local secret handling only.

## Guarantees and regressions

```sh
bash tests/fm-linear-sync.test.sh
```

```
ok - an unbound task, an ambiguous binding, and a prose target all refuse instead of guessing
ok - an empty comment, a forged marker, an oversized body, and a malformed status all refuse
ok - a delivery posts one comment, applies the status once, and repeats as a no-op
ok - re-queueing an identical handback resolves to one delivery, and a changed one is distinct
ok - a delivery already under way holds, and an abandoned lock is taken over rather than stranding it
ok - a comment committed by Linear with a lost acknowledgement converges with no duplicate
ok - a lost local receipt is recovered from Linear's own copy, never by reposting
ok - a read-back that cannot be completed holds rather than risking a duplicate
ok - a disconnected or misconfigured Linear preserves the handback and never claims completion
ok - an unreachable Linear holds the handback and the later retry posts exactly once
ok - a comment that landed without its status is completed on retry with no second comment
ok - an issue Linear does not have is quarantined, keeps blocking, and clears only on an explicit discard
ok - cleanup refuses while a Linear handback is owed and proceeds once the issue is current
ok - the completion gate blocks only the task that owes the handback
ok - session start surfaces an owed Linear handback from disk, and stays silent otherwise
ok - a home that never bound a Linear issue gains no artifact and prints nothing
ok - the hook is active in a primary and secondmate home and inert in a task worktree or project repo
ok - the credential never reaches a request body, a durable record, or any output
ok - the real transport passes its credential by private file, never in argv or the environment
ok - delivery records are typed, private, and refused when they no longer match their identity
ok - comment text cannot forge the record fields the jq-free cleanup gate reads
```

The sixth case is the end-to-end proof for guarantee 2.
The fake commits the comment and then exits non-zero without answering, which is exactly the interval a local receipt cannot cover.
The suite asserts the delivery holds with no receipt, the handback stays owed, and the retry finds the marker in Linear's own comment list, reports `read-back` as its proof, adds no second comment, and clears the pending set.

The seventh case covers the same interval from the other side: a home restored from an older copy whose receipt is gone re-derives the same delivery identity from the same content and still converges without reposting.

The eighth case pins the anti-duplicate rule that makes the read-back trustworthy.
With `FM_LINEAR_COMMENT_PAGE_SIZE=2` and `FM_LINEAR_COMMENT_PAGE_MAX=2` against a twelve-comment issue, the read-back cannot complete, so the delivery holds and posts nothing; with the bound restored, the same delivery adds exactly one comment.
An absence that could not be proven is treated as unknown, never as new.

The read-back cannot prevent one duplicate on its own: two concurrent deliveries would both prove absence before either posted.
`a delivery already under way holds, and an abandoned lock is taken over rather than stranding it` covers both halves of the per-delivery lock that closes it, including the takeover that keeps a crashed delivery retryable rather than stranded.

`comment text cannot forge the record fields the jq-free cleanup gate reads` covers the one place a delivery record is parsed without `jq`, so that the cleanup gate keeps working on a home with no `jq`.
A comment whose own text contains `"status":`, `"issue":`, and `"task_id":` lines must not change what that gate sees, in either direction: the gate must still block the task that owes the handback and must still pass the task named only inside the comment.

## Secret handling

Two cases cover it, because the credential can leak in two different places.

`the credential never reaches a request body, a durable record, or any output` runs a full delivery with a distinctive key and then greps the fake transport's whole workspace (including every captured request body), the home's whole `state/` tree, and the command's stdout and stderr for that key.
Any hit fails the case.
The same case asserts the key is still present in `config/linear.env`, so the check cannot pass vacuously.

`the real transport passes its credential by private file, never in argv or the environment` runs the real `bin/fm-linear-transport.sh` against a fake `curl` that records its full argv and its full environment.
The key must be absent from argv, from the request body, and from the environment; must be present as a complete `Authorization:` line in the mode-0600 file that `curl` was pointed at with `-H @file`; and that file must no longer exist once the transport has exited.

## Zero overhead and scope

`a home that never bound a Linear issue gains no artifact and prints nothing` asserts that `hook`, `pending`, and `bindings` are all silent, that `guard-work` passes, and that neither `state/linear` nor `config/linear.env` comes into existence.

`the hook is active in a primary and secondmate home and inert in a task worktree or project repo` builds the four real shapes rather than standing in for them: a plain non-worktree checkout with `AGENTS.md`, `bin/`, and `state/`; a genuine linked `git worktree` of that home, which is what `bin/fm-spawn.sh` hands a crewmate or scout; an ordinary project repo; and a linked worktree carrying the `.fm-secondmate-home` marker.
Each child copy is given a populated `state/linear` first, so a passing inert verdict is a scope decision and not an empty-directory accident.
Binding from inside the task worktree refuses with a named scope error rather than creating state in the wrong place.

The same verdict was observed directly in a real crewmate worktree that `bin/fm-spawn.sh` had produced (a treehouse-leased linked worktree of the primary checkout), rather than only in the synthetic fixture:

```
$ bin/fm-linear-sync.sh hook ; echo "exit=$?"
exit=0
$ bin/fm-linear-sync.sh status
scope: inert (.../.treehouse/firstmate-7bab20/1/firstmate is not a firstmate primary home)
$ bin/fm-linear-sync.sh bind t1 ENG-1 ; echo "exit=$?"
fm-linear-sync: .../.treehouse/firstmate-7bab20/1/firstmate is not a firstmate primary home; Linear synchronization is inert here
exit=1
```

No `state/` directory came into existence in that worktree as a result.

## Harness surfaces inspected

The captain's rule is enforced at two harness-independent points - the cleanup completion gate in `bin/fm-teardown.sh` and the owed-handback subsection in `bin/fm-session-start.sh` - and no harness hook file was changed.
That is a decision, so the alternative was inspected first.

Every supported primary-harness turn-end registration was read: Claude's two `Stop` entries in `.claude/settings.json`, Codex's `Stop` entry in `.codex/hooks.json`, OpenCode's `session.idle` plugin in `.opencode/plugins/`, Pi's `agent_settled` extension in `.pi/extensions/`, Grok's `Stop` registration in `.grok/hooks/`, and Cursor's `stop` registration in `.cursor/hooks.json`.
All six already delegate to one continuation state machine whose verdict is watcher liveness, whose blocking semantics differ per harness (Claude and Codex block on exit 2; OpenCode and Pi are passive and force one bounded follow-up; Grok selects natively from its payload; Cursor cannot block at all and parks instead), and whose per-harness loop bounds and fail-open tradeoffs are recorded in [`../turnend-guard.md`](../turnend-guard.md).
Adding a second, unrelated verdict there would let an unfinished Linear handback hold a turn open on six separately-behaving surfaces, and would need six pieces of per-harness work, for no coverage the cleanup gate does not already provide with certainty.
`.codex/hooks.json` therefore needs no new registration, and none was added.

`bin/fm-linear-sync.sh hook` exists as the passive surface for an operator who does want that nag, and is inert by the scoping evidence above.
Because nothing registers it, no real harness hook was changed and no scratch-project hook validation was required.

## Lint

```sh
bin/fm-lint.sh bin/fm-linear-lib.sh bin/fm-linear-sync.sh bin/fm-linear-transport.sh tests/fm-linear-sync.test.sh
```

```
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

## Not covered here

The GraphQL documents in `bin/fm-linear-sync.sh` are written against Linear's published API and are exercised end to end only against the hermetic fake.
They have not been run against the live Linear service from this repository, because no credential was available and the work was explicitly barred from making a live mutation.
The failure mode of a schema mismatch is a hold carrying Linear's own message, with the handback preserved, which is the same path the transport-failure and HTTP-500 cases already pin.
Refreshing this record against a live workspace needs a `config/linear.env` and a throwaway issue, and is the one claim above that a reader should not treat as live-verified.
