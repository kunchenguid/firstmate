# Verification: the codex crewmate sandbox and its writable roots

Active empirical evidence for the filesystem sandbox firstmate launches codex crewmates, scouts, and secondmates inside, and for the writable roots `bin/fm-spawn.sh` grants them.
[`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts; `bin/fm-spawn.sh`'s header owns the exact flags; this record owns how the facts were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `codex-cli 0.150.1` |
| Verified | 2026-08-31 |
| Platform | macOS arm64 (Darwin 27.0.0), Apple seatbelt |
| Refresh command | `FM_CODEX_LIVE_E2E=1 tests/fm-codex-sandbox-grant-live-e2e.test.sh` |

Two earlier codex records in the adapter skill were verified against 0.139.0 and 0.142.1.
This record supersedes nothing in them; it adds the sandbox axis, which they never covered.

Every measurement below used a scratch git repository with a real linked worktree, plus a scratch firstmate home, both **outside** `/tmp` and `$TMPDIR`.
That placement is load-bearing: codex's `workspace-write` mode grants `/tmp` and `$TMPDIR` by default, so the same probes run in a temp directory report every write as allowed and prove nothing.

## What `workspace-write` denies

`-s workspace-write` confines every shell command the worker runs to its own working directory.
A sibling directory in the same tree is denied:

```
$ codex sandbox -c sandbox_mode='"workspace-write"' -- bash -c "echo one >> $T/home/state/fm-x.status"
bash: .../home/state/fm-x.status: Operation not permitted
```

The confinement is by working directory, not by repository: the worktree's own `.git` file is inside it, but a **linked** worktree's git common directory is not, so staging fails before any commit does.

```
$ cd "$T/wt" && codex sandbox -c sandbox_mode='"workspace-write"' -- "$T/gitprobe.sh" "$T/wt"
fatal: Unable to create '.../main/.git/worktrees/wt/index.lock': Operation not permitted
```

That is the whole defect this grant exists for: every firstmate task worktree is a linked worktree, so an ungranted codex worker could neither deliver a report, append the status line supervision reads, pass the captain-hold completion gate, nor stage a single file.

## The grant mechanism

The installed CLI offers two mechanisms, both verified:

| Mechanism | Behavior measured |
|---|---|
| `--add-dir <DIR>` | Additive to the primary workspace, repeatable, accepted by both the interactive parser and `codex exec`. |
| `-c sandbox_workspace_write.writable_roots=[...]` | Sets the same policy, but **replaces** any value the operator's own `~/.codex/config.toml` sets. |

`--add-dir` is what firstmate ships, because additive is both narrower in effect and purpose-built.
Repeatability and effect were proven together through a real model turn:

```
$ codex exec -s workspace-write --skip-git-repo-check \
    --add-dir "$FMH/state" --add-dir "$FMH/data" \
    "Run exactly these three shell commands ... (1) ... state/p.status (2) ... data/p.md (3) ... config/p.txt"
1. Succeeded
2. Succeeded
3. Denied (`operation not permitted`)
```

The interactive parser accepts the same repeated flag; only the deliberately invalid argument was rejected:

```
$ codex -s workspace-write --add-dir /tmp --add-dir /private/tmp -a never --bogus
error: unexpected argument '--bogus' found
```

A root that does not exist is tolerated rather than fatal, and does not disturb the other roots in the same list.

## Why the grant is scoped per kind

A root may be a single **file**: granting `data/backlog.md` made exactly that file writable while its sibling `data/captain.md` stayed denied.
That single-file capability is what lets the grant be scoped to the narrowest path each kind actually needs, so a mistaken worker command cannot reach another task's authoritative records:

- A **ship crewmate** never runs the completion gate and writes no report. The paths it needs outside its worktree are its OWN two per-task state files - `state/<id>.status` (the supervision line it appends) and `state/<id>.turn-ended` (the wake marker the codex `notify` hook touches on every turn) - plus its OWN steering inbox `state/<id>.inbox/` and the git common directory. `bin/fm-spawn.sh` pre-creates both files at launch so the single-file roots resolve and neither the append nor the touch needs the directory-create permission a file grant withholds. Granting those files instead of `state/` keeps every OTHER task's status, meta, and completion locks out of reach.
- The **steering inbox** is a directory root for every kind, because the record names are allocated by firstmate after launch and cannot be named ahead of time. Every brief kind carries the same inbox section (`bin/fm-brief.sh`), whose acknowledgement is a `mv` of the handled record into `state/<id>.inbox/handled/`; without write on that directory a sandboxed worker could read its steering messages and never acknowledge one, and the re-ring ladder in `bin/fm-task-inbox-lib.sh` would escalate it as stuck for complying. `bin/fm-spawn.sh` creates the inbox and its `handled/` at launch so the root resolves. A scout needs no separate inbox root: its `state/` grant already covers it.
- A **scout** gets `state/` itself (a whole directory), the task's own `data/<id>/`, and the git common directory. `state/` must be the directory because `fm_lock_owner_dir` (`bin/fm-wake-lib.sh`) creates its owner directory with `mktemp -d "<lockpath>.owner.XXXXXX"` and `fm_meta_lock_path` makes a lock symlink beside it, both directly in `state/`; those new entries cannot be named ahead of time, so a per-file grant cannot serve them. The scout report at `data/<id>/report.md` does not exist yet at launch, while the task's `data/<id>/` directory already does (it holds `brief.md`), so the report grant names that directory.
- A **secondmate** gets only the parent's `state/<id>.status` file (pre-created) and its parent-side `state/<id>.inbox/`, because its own home is already its workspace and it runs its own completion gate there.

The report is scoped to the task's own `data/<id>/`, **not** the shared `data/` root, on purpose.
Backlog mutation is the parent firstmate's job and is never part of a crewmate's or scout's contract, so granting the whole of `data/` only exposed every other task's report and the shared `data/backlog.md` to a mistaken command for no contract reason.
Confirming that a file-only `backlog.md` grant would in any case fail a backlog mutation, had one been in the contract:

```
$ codex sandbox ... -c "sandbox_workspace_write.writable_roots=[\"$FMH/data/backlog.md\"]" -- tasks-axi hold ...
error: "EPERM: operation not permitted, open '.../data/backlog.md.lock'"
```

So a ship crewmate gets its two `state/<id>.*` files, its own `state/<id>.inbox/`, and the git dir; a scout gets `state/`, its own `data/<id>/`, and the git dir; a secondmate gets the parent's `state/<id>.status` file and its `state/<id>.inbox/` - never the shared `data/` root and never `$FM_HOME` itself, which keeps `.env`, `config/`, `projects/`, and every other home denied.

Every root is emitted with its symlinks resolved.
The launch's own `notify` hook path is built from a `pwd -P` state directory and codex resolves a granted root the same way, so a home reached through a symlink - a `/tmp` home on macOS, where `/tmp` is `/private/tmp` - would otherwise be granted a path the worker never writes.

Pre-creating a file under `state/` does make it a new signal file for the watcher's own scan, which reports any status file or turn-end marker whose signature differs from its persisted `state/.seen-*` one (`scan_signals` in `bin/fm-watch.sh`).
That applies to both files this grant pre-creates, `state/<id>.status` and `state/<id>.turn-ended`, so `bin/fm-spawn.sh` routes every pre-created root through one helper that marks it as already reported through `fm_wake_signal_mark_current` (`bin/fm-wake-lib.sh`), the inverse of the check the scan makes.
Codex has no verified semantic busy source that could absorb such a wake, so a file the spawn conjured would otherwise cost the captain a turn for activity nobody produced.
Later real activity changes the signature and surfaces normally, and a file that already exists is left untouched, because its unreported signature may be real activity nobody has surfaced yet.

The captain-hold completion gate needs the whole `state/` grant a scout gets: `fm-captain-hold.sh complete` and `verify` both succeeded with `state/`, and both create the mktemp-named lock owner directory there. A ship crewmate never runs the gate, which is why its narrower per-path grant is sufficient.

## What this grant does not change

**Network access is a separate axis from the writable roots, and no root affects it either way.**

`sandbox_workspace_write.network_access` is the switch, and `workspace-write` defaults it to denied.
Firstmate's own codex launch passes `-c sandbox_workspace_write.network_access=true` unconditionally on both templates, and a CLI `-c` override wins over `~/.codex/config.toml`, so egress is enabled on every firstmate codex crewmate regardless of the machine.
A launch with it on reports the grant line `sandbox: workspace-write [...] (network access enabled)`.

```
# with network access enabled (measured 2026-08-31, 0.150.1)
$ codex sandbox -c sandbox_mode='"workspace-write"' -- curl -sS -m 8 -o /dev/null -w '%{http_code}' https://api.github.com/
200
```

Adding, removing, or narrowing a writable root does not change network access either way, and enabling network access does not widen the write confinement: a write outside the granted roots is still denied with it on.
So `bin/fm-spawn.sh`'s dispatch notice claims no network limit, because there is none to claim.

**The no-mistakes pipeline data directory is denied.**

```
$ codex sandbox -c sandbox_mode='"workspace-write"' -- bash -c 'touch ~/.no-mistakes/.fm-probe'
touch: /Users/.../.no-mistakes/.fm-probe: Operation not permitted
```

`~/.no-mistakes` holds `state.sqlite`, `socket`, `daemon.lock`, and `daemon.pid`, so a sandboxed codex worker cannot drive `no-mistakes axi`.
Re-measured 2026-08-31 on 0.150.1 with network access enabled: still `Operation not permitted`, confirming this denial is independent of the network setting and is the ONLY blocker standing between a codex worker and the pipeline.
Widening the grant to a third-party tool home, its control socket, and the homes of every review agent the pipeline spawns is a different decision from firstmate's own supervision paths, and is deliberately not taken here.

## Other adapters

Only codex is launched inside a filesystem sandbox.
`claude`, `opencode`, `pi`, `pi-signed`, `grok`, and `kimi` are launched with approval flags and no sandbox flag at all, and `muse`'s `--yolo` explicitly disables its default-on sandbox.
`cursor` is the one other adapter launched with a sandbox flag (`--sandbox enabled`), and it is measurably not affected: on `cursor-agent 2026.08.25-3e8eec8`, writes to two directories outside the workspace both succeeded.

```
$ cursor-agent -p --force --sandbox enabled "Run exactly two shell commands ... (1) ... state/cursor-probe.status (2) ... config/cursor-probe.txt"
both probes succeeded - neither was denied
```

Cursor's sandbox therefore does not confine writes to the workspace the way codex's does, and firstmate's cursor launch is left untouched.

## Coverage and what is not proven

| Claim | Where it is enforced |
|---|---|
| The composed launch grants a ship crewmate only its own `state/<id>.status` + `state/<id>.turn-ended` files, its own `state/<id>.inbox/`, and the out-of-tree git common dir; a scout `state/`, its own `data/<id>/`, and the git dir; a secondmate only the parent's `state/<id>.status` file and its `state/<id>.inbox/`. The shared `data/` root, and (for ship/secondmate) the whole `state/` directory, are never granted | `tests/fm-codex-sandbox-grant.test.sh` (portable, no codex) |
| Every granted root is spelled with its symlinks resolved, matching the path the launch's own `notify` hook touches | `tests/fm-codex-sandbox-grant.test.sh` |
| A ship crewmate can perform the steering-inbox acknowledgement move under its own grant, and cannot once the inbox root is removed | `tests/fm-codex-sandbox-grant.test.sh` |
| A symlinked state record or inbox refuses the spawn instead of resolving through the link: nothing is created through it, and no root outside the task's own paths is emitted | `tests/fm-codex-sandbox-grant.test.sh` |
| A granted FILE root with more than one hard link to its inode refuses the spawn, so a worker cannot be granted a path whose writes reach a file outside the task's boundary through a shared inode | `tests/fm-codex-sandbox-grant.test.sh` |
| A pre-created record that exists with the wrong type (a directory where the file belongs, a file where the inbox belongs), or that cannot be created at all, refuses the spawn instead of granting a root the worker cannot write through | `tests/fm-codex-sandbox-grant.test.sh` |
| The out-of-tree git common dir grant is pinned to the RECORDED project's own common dir: a worktree whose `.git` file was repointed at another repository's metadata refuses the spawn rather than granting that other repository's git directory | `tests/fm-codex-sandbox-grant.test.sh` |
| A granted root containing `&` survives the launch-command substitution byte-for-byte on every bash version, so a project checked out under a path like `a&b` is granted the path it actually has | `tests/fm-codex-sandbox-grant.test.sh` |
| No other adapter's launch acquired a grant | `tests/fm-codex-sandbox-grant.test.sh` |
| The scout set is sufficient for a real status append, report, captain-hold completion gate, and commit, and each root is load-bearing; the ship set is sufficient for a status append, turn-ended touch, and commit while the shared `state/` stays unwritable so a sibling task's records cannot be reached | `tests/fm-codex-sandbox-grant.test.sh`, by making everything outside the emitted roots unwritable |
| Neither pre-created state file reads to the watcher as new activity, while a later real append still does | `tests/fm-codex-sandbox-grant.test.sh` |
| The dispatch notice about the denied pipeline directory fires for `no-mistakes` alone, and every ship mode still gets the same four roots | `tests/fm-codex-sandbox-grant.test.sh` |
| codex still denies the SCOUT's paths without the grant and allows exactly them with it | `tests/fm-codex-sandbox-grant-live-e2e.test.sh` (opt-in, real binary), scout halves |
| firstmate's own `--add-dir` flags reach that policy through a real model turn | `tests/fm-codex-sandbox-grant-live-e2e.test.sh`, `codex exec` halves |
| codex accepts and enforces the FILE form of `--add-dir` that is the whole ship and secondmate grant: the ship's own two state files become writable and a sibling task's status file in the same `state/` stays denied | `tests/fm-codex-sandbox-grant-live-e2e.test.sh`, ship half |

Not proven, stated plainly:

- The **interactive TUI** path was not driven end to end. What is proven is that the interactive parser accepts the exact repeated flag, and that the same flag reaches the sandbox policy in `codex exec`. Both surfaces share one top-level flag parser, but no test drives a real interactive pane through the three writes.
- The live guard composes a **scout** launch and a **ship** launch. The secondmate's grant is not composed against the real binary; it is the same single-file `state/<id>.status` form the ship half proves, plus its own inbox directory, so what the guard leaves unexercised is the secondmate spawn path rather than the mechanism its roots rely on.
- A codex worker **completing a no-mistakes ship** is not covered, and by the measurements above cannot work: the pipeline needs `~/.no-mistakes`, which stays denied. That is the sole blocker, and it is why `bin/fm-spawn.sh` fires its dispatch notice for `no-mistakes` alone. A `direct-PR` ship needs nothing denied: it commits through the granted git common dir, pushes and opens the PR over the granted network, and reports through its granted status file.
- `bin/fm-captain-hold.sh` **registering** a new captain hold from a crewmate would take `data/backlog.md.lock` and so is not served by the task-scoped `data/<id>/` grant; this is deliberate, because registering a hold is the parent firstmate's job and no crewmate or scout contract does it. The portable suite exercises `complete`, which needs only `state/`; `verify` is covered by the one-off measurement above rather than by any test.
- The recursion `fm_lock_try_acquire` performs when `fm_lock_try_create` fails for a **permanent** reason (the observed `.lock.steal.steal...` until `File name too long`) is not fixed here. Removing the denial removes the trigger seen on 2026-08-26, but any other permanent write failure - a full or read-only filesystem - would still recurse.
