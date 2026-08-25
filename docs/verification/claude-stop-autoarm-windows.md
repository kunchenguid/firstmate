# Claude Stop auto-arm on Windows

Audience: maintainer verification.

This record holds the platform evidence behind `fm_harness_env_session_pid` in `bin/fm-session-lock-lib.sh` and the two callers that depend on it, `fm_session_lock_owned_by_self` and `fm_harness_ancestry_pids`.
That file owns the identity decision procedure; this record owns why the Windows answers count as proof, because CI never runs there.
Re-establish it after a Claude Code, Git for Windows, or MSYS runtime upgrade.

Verified 2026-08-24 on Windows 11 (10.0.26200) with Claude Code 2.1.241, MSYS runtime 3.6.4, `git version 2.51.0.windows.2`, and Windows PowerShell 5.1.26100.9168.

```sh
$ uname -s
MINGW64_NT-10.0-26200
```

## What was actually broken

The reported symptom was that the `asyncRewake` Stop hook never fires on Windows, so `bin/fm-claude-stop-autoarm.sh` never armed the watcher and firstmate armed it by hand after every wake.

`asyncRewake` fires.
A Stop hook registered with `"asyncRewake": true` runs its command on this host exactly as a synchronous Stop hook does; both were observed writing their marker files from the same session.
What failed is one step later: the hook resolved no harness ancestry, so its identity gate treated the live `claude.exe` named in `state/.lock` as a competing session and the hook exited 0 without arming, on every turn end.

The synchronous guard shares the blindness but fails open, which is why it looked healthy: `bin/fm-turnend-guard.sh --claude` reaches the same false `fm_session_lock_owned_by_self` and prints "supervision deferred to the live session holding the fleet lock", deferring supervision to the very session that is running it.

## Why the ancestry walk resolved nothing

The Windows walk in `fm_harness_windows_ancestry_pids` climbs the native parent chain, so it needs this process's immediate native parent to still exist.
A hook command that is anything other than a single simple command defeats that: MSYS `bash` replaces itself for the final command of the string, so the surviving shell is parented to a fork stub that has already exited and `Win32_Process` has no row for it.

Six Stop hooks in one session, each probing its own native parent chain, isolate the discriminator.
The command strings differ only in shape; `asyncRewake` is set on the three `*-ASYNC` rows.

```
=== BARE-SYNC          "$CLAUDE_PROJECT_DIR"/probe.sh ...
  10760:bash.exe -> 13784:bash.exe -> 19288:bash.exe -> 22960:claude.exe -> ...
=== BARE-ASYNC         "$CLAUDE_PROJECT_DIR"/probe.sh ...
  24060:bash.exe -> 20504:bash.exe -> 9152:bash.exe -> 22960:claude.exe -> ...
=== PREFIX-SYNC        [ -z "${NOPE:-}" ] || exit 0; "$CLAUDE_PROJECT_DIR"/probe.sh ...
  4504:bash.exe -> 18356<DEAD>
=== PREFIX-ASYNC       [ -z "${NOPE:-}" ] || exit 0; "$CLAUDE_PROJECT_DIR"/probe.sh ...
  14476:bash.exe -> 16228<DEAD>
=== PREFIXEXEC-SYNC    [ -z "${NOPE:-}" ] || exit 0; exec "$CLAUDE_PROJECT_DIR"/probe.sh ...
  13584:bash.exe -> 20212<DEAD>
=== PREFIXEXEC-ASYNC   [ -z "${NOPE:-}" ] || exit 0; exec "$CLAUDE_PROJECT_DIR"/probe.sh ...
  24008:bash.exe -> 4104<DEAD>
```

Sampling each chain again three seconds later returned byte-identical rows, so the missing parent is structural rather than a parent that exits while the probe runs.
`asyncRewake` does not appear in the split: both bare shapes resolve and all four compound shapes dead-end.
The tracked registration in `.claude/settings.json` is a compound shape, which is why every Stop hook firing in production landed in the dead-ending column.

Once the chain is severed there is nothing left to recover it from: the one process that knew the parent link is gone, MSYS reports the hook shell's own ppid as 1, and `Win32_Process` cannot answer for an exited pid.

## What the harness publishes instead

Claude Code exports its session pid into every hook command and tool call it runs.

```sh
$ echo "$CLAUDE_PID"
6000
$ MSYS_NO_PATHCONV=1 tasklist.exe /FI "PID eq 6000" /FO CSV /NH
"claude.exe","6000","Console","1","675,236 K"
```

It is a native pid, answerable by `tasklist`, and it agrees with the walk wherever the walk still works, so accepting it changes no answer that was already correct:

```sh
$ . bin/fm-session-lock-lib.sh; fm_harness_ancestry_pids; fm_harness_ancestry_pid
6000
6000
```

This is why the fix is keyed on the variable being published and naming a live verified harness, never on `uname`: a host or harness that does not publish it leaves every caller's walk behavior exactly as it was.

## The fix, end to end

Same isolated `FM_HOME`, same fixture, same tracked compound registration, real Claude Code, one session with work in flight.
The arm wrapper and wake drain are fixtures; everything else is the tracked code.

Before:

```
arm-ran:   NONE
epoch:     NONE
```

After:

```
arm-ran:   arm-run=1 pid=582750
epoch:     epoch=2 owner_pid=582368 outcome=rewake updated_at=1787598055
```

A bare registration reaches the same outcome without the fix, which is the control that ties the two halves together: the hook was always firing, and identity was always the thing that failed.

The live guard's new async phase drives that same tracked registration against real Claude Code with a stale dead-owner lock.
Because the guard's first phase does not pass on this host (below), the phase was exercised on its own, with the first phase's session removed and everything else byte-for-byte.
Against the `e223b8a` library it reproduces the reported symptom exactly:

```
not ok - the backgrounded asyncRewake Stop hook never armed; epoch: none
```

Against this change the same run reaches the end of the phase, having armed once, written `outcome=rewake`, and replaced the dead `9999999` owner in `state/.lock` with the live session pid.
That reclaim is what proves the second half of the change: arming alone needs only the published-pid fast path, while `bin/fm-lock.sh` reclaiming a dead owner from inside the hook needs the severed-walk fallback in `fm_harness_ancestry_pids`.

## Regression coverage

`tests/fm-session-lock-ancestry.test.sh` pins the contract portably, on the unit layer's shimmed-`uname` POSIX branch so it runs identically from any host:

- a severed walk resolves identity from the published pid, with a divergence guard asserting the fixture resolves nothing once that pid is removed, so the case cannot pass vacuously through the walk;
- a published pid is rejected unless it is live, a verified harness, and the lock holder;
- a walk that resolves on its own keeps deciding identity, gap protection included, so no POSIX host starts writing a session lock its ancestry never agreed to.

## Windows host test state

Two suites that exercise this area are red on this host at `e223b8a`, before and after the change, and were confirmed by running the same scripts from a clean clone of that commit:

```
not ok - stale session lock was not claimed by the current harness: expected 610746, got 13568
  tests/fm-claude-stop-autoarm.test.sh
not ok - hook must exit 0 with a live identity-matched watcher lock and fresh beacon: expected exit 0, got 2
  tests/fm-turnend-guard.test.sh
```

Both fixtures build process trees and then let the real Windows walk read the real process table, so they answer about the session running the suite rather than the fixture.

The unit layer of `tests/fm-session-lock-ancestry.test.sh` had the same defect and is fixed here by shimming `uname` alongside its existing fake `ps`, so all seven unit cases now pass on this host instead of aborting at the first one.
Reaching the end of that layer exposes its end-to-end layer, which fails here with `the fixture hook never finished` and a fixture state directory the detached tree cannot write.
That failure is not caused by anything in this change: running the same end-to-end case against the `e223b8a` library, with no `fm_harness_env_session_pid` in it at all, reproduces it exactly, and `run_fixture_tree` now clears `CLAUDE_PID` so the fixture path is byte-identical to that commit either way.
The live guard's first phase is red here too, and for a third reason again unrelated to identity.
Its model-driven sequence asserts exactly two hook-owned arm cycles; this host produced four, because the model took one wake turn rather than two, so the fixture arm reached its own task-clearing branch while supervision was still needed and the hook's bounded retry armed once more inside the same firing.
The counts observed were two drains and four arms against the three and two the phase expects.
Nothing about that sequence is an identity question, and it is left alone rather than loosened to fit one platform's timing.

The suites named here are a known Windows-host fixture gap rather than a CI gap; Linux CI is unaffected, where the `uname` shim is a no-op and the walk under test is the one the fixtures already exercise.
