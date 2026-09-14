# Durable supervision keeper

`bin/fm-watch.sh` is intentionally a one-cycle watcher: it exits after a wake
so the harness can resume the captain session. A long-lived owner must therefore
re-arm it after every wake and after every unexpected exit.

On macOS, install the durable owner with:

```sh
bin/fm-supervision-keeper-install.sh install
```

The installer creates a user-scoped LaunchAgent with `RunAtLoad`, `KeepAlive`,
and a five-second launchd throttle. The keeper itself uses the home-scoped
watcher lock and process identity, starts `fm-watch-arm.sh` as a child, records
bounded crash/restart evidence, and re-arms the child with exponential backoff.
It only starts the away-mode injection daemon while `state/.afk` exists; normal
captain sessions therefore get a durable watcher without an unsolicited
injection path.

Useful checks:

```sh
bin/fm-supervision-keeper.sh --status
bin/fm-supervision-keeper-install.sh status
tail -f state/.supervision-keeper.log
```

The keeper is deliberately home-scoped and never uses broad process matching.
`launchd` is the outer restart boundary; the keeper is the inner restart
boundary for the one-cycle watcher. If launchd cannot bootstrap the job, the
installer exits non-zero and leaves the plist in place for diagnosis.

## Resource exhaustion behavior

macOS can report `No space left on device` when a process cannot allocate a
file descriptor. The message does not prove that the filesystem is full.
Long-lived TypeScript servers, Git upload-pack processes, and worktree tools
can consume the host-wide descriptor budget first.

The keeper treats a failed heartbeat write as a resource incident. It records
the current `kern.num_files/kern.maxfiles` ratio when available, backs off, and
opens a circuit after three consecutive failures. The default 60-second
cooldown gives launchd a quiet restart boundary instead of a five-second
retry storm. Override `FM_KEEPER_MAX_RESOURCE_FAILURES` or
`FM_KEEPER_RESOURCE_COOLDOWN` only for tests or controlled diagnosis.

After recovery, inspect the processes that own the descriptors. Do not delete
Firstmate state to hide the symptom. Recycle the owning long-lived process or
fix its watcher lifecycle, then verify a fresh `.last-watcher-beat`.
