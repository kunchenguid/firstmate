# Worktree pool ownership verification

Repeatable evidence that a treehouse pool slot is owned for the life of a task rather than the life of its agent.
The mechanism and rationale are owned by [`../../bin/fm-worktree-claim-lib.sh`](../../bin/fm-worktree-claim-lib.sh), the acquisition by [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh)'s header, and the release by [`../../bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s header; this page records evidence only.

Date: 2026-08-19.
Shell: GNU bash 5.3.9 (macOS, aarch64-apple-darwin25.4.0).
treehouse: v2.0.1.

## The vendor behavior the fix rests on

treehouse classifies a slot as free when no durable lease reserves it and no process is running inside it.
`treehouse prune --help` states the same rule in its own words: a worktree is reclaimable only when "no owner reservation or running process is using it".
Firstmate task records are not part of that decision, so a crewmate worktree taken with a bare `treehouse get` was held only for as long as its agent process lived.

Two vendor facts are load-bearing and are pinned by the self-skipping real-treehouse assertion in `tests/fm-worktree-pool-collision.test.sh`, which builds its own pool inside the test temp root (`root = "./"`) and never touches an operator's pool:

- a leased slot is not handed out by a later `treehouse get` even with zero processes inside it;
- `treehouse return` releases the lease, so the existing cleanup call is a sufficient release point.

That assertion prints `skip - treehouse not found; pool lease semantics unverified here` where the binary is absent, and never reports a pass for a check it did not run.

The pane is moved into the leased slot with a plain `cd`, not `treehouse enter`.
`enter` runs its own subshell, and a subshell that exits ends the pane it ran in, taking the worker's endpoint with it; the lease is already held by then, so `enter` offers nothing a `cd` does not.

## The pool return is forced only under the captain's authority

A plain `treehouse return` needs no `--force` for the normal path, and refuses rather than discarding when it finds uncommitted work.
Measured against treehouse v2.0.1 with no controlling terminal:

```console
$ treehouse return "$WT" </dev/null      # clean worktree
🌳 Worktree returned to pool.

$ treehouse return "$WT" </dev/null      # worktree with uncommitted changes
Worktree has uncommitted changes. Clean and return? [Y/n] 🌳 Aborted.
$ echo $?
0
```

Two facts follow, and both are load-bearing.
`--force` was never required to return a clean worktree, so its only effect was to discard changes the pool would otherwise have preserved - which matters exactly in the window cleanup cannot check, because the agent is alive until the return kills it.
A scout worktree and a secondmate home keep the forced return, passed explicitly: the scout is declared scratch and already exempt from the uncommitted-work refusal, and a home's local material is gitignored rather than uncommitted work.
And an aborted return exits `0` while leaving the slot held, so the outcome must be verified rather than trusted: a genuine return cleans and resets the worktree, so a still-dirty tree afterwards proves the return did not happen.

## Containment, proved from both ends

`tests/fm-worktree-pool-collision.test.sh` drives the real `bin/fm-spawn.sh` and `bin/fm-teardown.sh` against a fake terminal and a real git worktree.
It proves allocation refuses a slot a live `state/<id>.meta` still claims, that the refusal turns on endpoint liveness rather than on a `done` status, that an unclaimed slot is still allocated normally, that the pane is sent into the exact slot the task leased, that cleanup refuses to return a slot a live record claims while leaving that task's branch and record intact, that cleanup still proceeds when the other claim is provably gone, and that `--force` remains the captain's explicit discard authority.

```console
$ bash tests/fm-worktree-pool-collision.test.sh
ok - allocation refuses a slot a live task record still claims
ok - allocation refusal turns on liveness, not on a done status
ok - allocation proceeds when no live task claims the slot
ok - spawn leases the pool slot for the life of the task
ok - teardown refuses to return a slot a live task record still claims
ok - teardown proceeds when the other claim is provably gone
ok - --force overrides the live-claim refusal
ok - a real leased pool slot outlives its agent and is freed only by return
ok - the captain-authorized forced return still discards and returns
ok - an aborted pool return is reported as a failure, not a phantom success
ok - a declared-scratch scout worktree is still returned with force
```

Liveness is deliberately asymmetric.
Only a backend that authoritatively reports its endpoint gone clears a claim; `alive` and every ambiguous, unreadable, or unverified answer keep the slot owned, because "I could not tell" must never be spent as "it is gone" when the cost of being wrong is another task's work.
