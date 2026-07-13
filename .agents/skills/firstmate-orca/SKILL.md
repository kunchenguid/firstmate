---
name: firstmate-orca
description: Operator reference for the Orca backend. Load before operating the orca backend, supervising an orca-backed crewmate, recovering from a stale_bootstrap daemon, debugging orca spawn refusals, or steering work that uses --backend orca. Use when an orca session needs triage, when fmod reports protocol-version mismatch, when bin/fm-supervise-orca.sh needs (re)arming, or when the captain asks to switch the active backend to orca.
user-invocable: false
metadata:
  internal: true
---

# firstmate-orca

Operator reference for firstmate's orca backend. The Orca backend creates the task git worktree directly and attaches an Orca daemon terminal; the orca adapter (`bin/backends/orca.sh`) talks to the daemon via `bin/fmod` because the `orca` CLI cannot run while the GUI holds the single-instance lock.

## When to load

- A crewmate was spawned with `--backend orca` and supervision needs firstmate to know the orca semantics.
- The captain asks to switch the active backend to orca, or asks why spawns are being refused.
- `fm-bootstrap.sh` reports `ORCA: daemon unreachable` or `ORCA: daemon still unreachable after relaunch`.
- An orca crewmate is wedged, stale, or off-nominal and the captain wants it surfaced in operator language.
- A new orca AppImage was installed and `bin/fmod` is reporting a protocol mismatch.
- The captain asks to enable the orca daemon supervisor or change its cadence.

Do NOT load for tmux, herdr, zellij, or cmux backends; those have their own adapter contracts and this skill is orca-specific.

## The orca backend, in one screen

- **Backend selection**: `config/backend=orca` (LOCAL, gitignored) or `FM_BACKEND=orca` env override for one session. Never auto-detected - always explicit.
- **Worktree**: created by `git worktree add` (the daemon has no worktree primitive and the broken `orca worktree create` CLI is what drove the daemon-direct rewrite). Path: `state/orca-worktrees/<repo>/<id>`.
- **Terminal**: created by `bin/fmod create` against the daemon's `createOrAttach` RPC. The terminal id IS the daemon session id, so reattach is automatic.
- **Transport**: `bin/fmod` is a small Python client that talks NDJSON over the daemon's unix socket (`~/.config/orca/daemon/daemon-v<N>.sock`). The `orca` CLI is never used at spawn time.
- **Protocol**: the daemon's hello is strict on `version` - `bin/fmod` tries the hardcoded default first, falls through to discovery (scans `daemon-v*.sock` in the daemon dir), and accepts `FMOD_PROTOCOL_VERSION=<n>` env override to pin.
- **Supervisor**: `bin/fm-supervise-orca.sh` is the per-runtime daemon keeper, separate from `fm-watch.sh` (per-task supervisor). Different cadence, different escalation, different restart semantics.

## Commands the operator will reach for

Daily-driver setup (run once per host):
```sh
bin/fm-use-orca.sh start      # full setup: verify, write config, start
                              # supervisor, install XDG autostart, end-to-end
                              # smoke. Idempotent and safe to re-run.
bin/fm-use-orca.sh status     # current backend wiring + supervisor + autostart
bin/fm-use-orca.sh stop       # stop supervisor and remove autostart
bin/fm-use-orca.sh restart    # stop + start
bin/fm-use-tmux.sh start      # symmetric switch back to tmux
```

Daemon liveness:
```sh
bin/fm-supervise-orca.sh status        # supervisor + daemon state
bin/fm-supervise-orca.sh once          # one-shot reachability check (no relaunch)
bin/fm-supervise-orca.sh start         # background the supervisor
bin/fm-supervise-orca.sh stop          # stop a running supervisor
bin/fmod info                          # low-level: socket/token/pid + pong
bin/fmod ping                          # lowest-level: daemon pong?
```

Direct daemon access (use sparingly - supervisor is the normal path):
```sh
bin/fmod list                          # list live sessions
bin/fmod snapshot <terminal> --strip-ansi --lines N    # bounded capture
bin/fmod write <terminal> --data 'text'$'\n'           # send text + Enter
bin/fmod write <terminal> --data $'\003'               # send Ctrl-C
bin/fmod get-foreground <terminal>     # current foreground process
bin/fmod get-cwd <terminal>            # current working directory
bin/fmod kill <terminal> --immediate   # force-kill a session
```

Session-target shape:
- A task's recorded `terminal=` (e.g. `fm-smoke01`) IS the daemon session id. Pass it to fmod directly.
- For the orca supervisor, the target is implicitly the daemon, never a specific session.

## Recovery recipes

### `ORCA: daemon unreachable` at bootstrap

1. `bin/fm-supervise-orca.sh status` - supervisor running? daemon reachable?
2. If supervisor is not running: `bin/fm-use-orca.sh start` for the full re-setup (config + supervisor + autostart + smoke), or `bin/fm-supervise-orca.sh start` for just the supervisor. Both run `once` first and only succeed if recovery is possible.
3. If supervisor is running but daemon is dead: wait one tick (`FM_ORCA_CHECK_INTERVAL`, default 30s), then `bin/fm-supervise-orca.sh status` again.
4. If recovery fails: read `/tmp/fm-supervise-orca.log` for the supervisor's last action. Common causes:
   - `setsid` missing - install `util-linux`.
   - `orca` not on PATH - set `FM_ORCA_BIN=/path/to/orca.AppImage`.
   - Stale AppImage FUSE mount - supervisor attempts `fusermount -u` on `/tmp/.mount_orca.*`; if that fails, `sudo umount /tmp/.mount_orca.XXXX`.

### Protocol version mismatch

If fmod reports `Protocol version mismatch`:

1. `bin/fmod info` - check the `socket` field. If it points to a version that does not exist on disk, set `FMOD_PROTOCOL_VERSION=<correct>` for this session.
2. If the installed AppImage is newer than the source: discovery should handle it. Confirm with `ls ~/.config/orca/daemon/daemon-v*.sock` - the daemon writes one socket per version it has ever run.
3. Long-term fix: bump `PROTOCOL_VERSION` in `bin/fmod` to match the installed binary. This is a fork-local constant; upstream may want a different value.

### Spawn refusal

`bin/fm-spawn.sh ... --backend orca` exits with `error: backend=orca requires a ready Orca runtime` when:

- The daemon is dead (see above).
- The CLI path was somehow invoked instead of fmod (check `bin/backends/orca.sh` is chmod +x).
- A worktree name collision (the same `fm-<id>` is already attached in the daemon). List with `bin/fmod list` and either kill the orphan or rename the new task id.

### pi stuck on project trust gate (and the `--approve` fix)

If a pi crewmate is showing the `Trust project folder?` dialog instead of processing the brief, the launch template was missing `--approve`. The fix:

- `bin/fm-spawn.sh` `launch_template()` should emit `pi --approve ...` for both ship and secondmate.
- Verify with `bin/fm-spawn.sh <id> <project> --backend orca --harness pi` after editing.
- This is a general firstmate bug (not orca-specific); see `docs/orca-backend.md` for the upstream-PR rationale.

### Crewmate wedged in the orca terminal

1. `bin/fm-peek.sh fm-<id>` - see what the pane is doing.
2. `bin/fm-send.sh fm-<id> '<short steer>'` - wake it with a one-line steer.
3. If the pane is unresponsive: `bin/fm-send.sh fm-<id> --key C-c` (interrupts the current turn), then a steer.
4. Load `stuck-crewmate-recovery` for the full playbook.

### cwd trailing-slash false-positive

The most common spawn-abort message in orca.sh:

```
error: orca session fm-<id> attached at /path/, expected /path
```

`bin/fmod get-cwd` returns a normalized trailing-slash path; the spawn's strict equality check rejected it. The fix is in `bin/backends/orca.sh`:

```sh
if [ "${actual_cwd%/}" != "${cwd%/}" ]; then ...
```

If you see this error again, the patch is gone - re-apply or pull the fix.

## Edge cases worth knowing

- **The CLI hangs.** `orca status`, `orca worktree list`, etc. all hang while the GUI holds the single-instance lock. Always use `bin/fmod` for runtime data; never shell out to the CLI at spawn time.
- **Two daemons at once.** If two `orca-ide` processes run (e.g. the supervisor relaunched while a stale GUI was still exiting), each writes its own `daemon-v<N>.sock` and the bind-address race can land on either. fmod's discovery tolerates this; the CLI will not.
- **FUSE mount survives process exit.** When the AppImage crashes, `/tmp/.mount_orca.XXXX/` stays around until you `fusermount -u` it. The supervisor tries this on each relaunch.
- **`XDG_CONFIG_HOME` overrides.** fmod honors `XDG_CONFIG_HOME` for the daemon dir, but the CLI does not always. If you set `XDG_CONFIG_HOME` for testing, set it for both.

## What this skill does NOT do

- It does not load on tmux/herdr/zellij/cmux sessions. They have their own contracts and adapters.
- It does not own `bin/fm-watch.sh` semantics - that's per-task supervision, separate concern. Orca tasks are routed through fmod inside the watcher's per-wake path; the watcher itself does not change.
- It does not register the captain's project with orca. The daemon-direct adapter does not touch the orca repo registry; the project must be a real git repo.

## See also

- `docs/orca-backend.md` - full backend contract, daemon protocol details, and the daemon-supervision rationale.
- `harness-adapters` - load before spawning any pi/claude/codex/opencode/grok crewmate on orca; trust-dialog handling is harness-specific.
- `stuck-crewmate-recovery` - load on `stale`, looping, or unresponsive orca crewmates.
