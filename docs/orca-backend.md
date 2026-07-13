# Orca Backend

Orca is an experimental runtime backend for firstmate.
It is distinct from the crewmate harness: the harness is the agent process firstmate launches (`claude`, `codex`, `opencode`, `pi`, or `grok`), while the Orca backend creates the task git worktree and attaches an Orca daemon terminal underneath that process.

## Setup

Pick Orca if you run the Orca AppImage as your terminal environment and want firstmate tasks to live in git worktrees and Orca daemon sessions instead of a treehouse/tmux pair.
Orca is explicit-only (never auto-detected), experimental, and supports secondmates (each secondmate gets one persistent orca daemon session; see "Secondmates" below).

Prerequisites:

- The Orca AppImage or wrapper available on PATH as `orca`, or `FM_ORCA_BIN` pointing at the executable when daemon supervision needs to relaunch it.
- `python3`, used by firstmate's bundled `bin/fmod` daemon client.
- The bundled executable `bin/fmod`.
- `node`, retained as a universal firstmate dependency even though the daemon-direct Orca adapter no longer parses CLI JSON.
- `git` with GitHub auth, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, and `lavish-axi` - the same universal requirements as tmux, minus `tmux` and `treehouse` (Orca replaces both).

Select Orca by putting `orca` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=orca` when you launch your harness for a one-off session; telling the first mate in chat to use Orca also works.
It is never auto-detected.
When bootstrap resolves Orca from `FM_BACKEND=orca` or `config/backend=orca`, it checks for `fmod`, `python3`, and the universal tool set, and skips `tmux` and `treehouse`.

First run: before spawn mutates any repo or worktree state, firstmate runs `bin/fmod info` and requires the daemon to report `daemon_reachable=true` with a successful ping.
Spawn fails closed if the runtime is not ready.
Start the Orca AppImage and wait for its daemon socket under `~/.config/orca/daemon/` before spawning, or use `bin/fm-supervise-orca.sh start` to let firstmate relaunch a stale daemon.
The daemon-direct adapter does not register projects in Orca; it creates the task worktree with `git worktree add` and then attaches an Orca daemon session to that path.

Watching and attaching: firstmate owns the git worktree path and Orca owns the terminal session, so there is nothing to attach to outside the Orca app itself - open the app and find the terminal for the task (recorded as `terminal=fm-<id>` in the task's meta, with `window=fm-<id>` as the shared firstmate alias).
You do not need to open the app for routine supervision: `bin/fm-peek.sh fm-<id>` reads a task's terminal without opening Orca, and `bin/fm-send.sh fm-<id> "<text>"` steers it (Enter and Ctrl-C are supported; Escape is not).

Verify it works by spawning a trivial task with `--backend orca` and confirming the task's meta records `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`; the Orca app should show a new terminal for the task.

Limitations: Escape is unsupported, Orca is explicit-only, and its daemon protocol version can drift, so `bin/fmod` handles protocol discovery instead of relying on a CLI version floor - see "Limitations" below for the complete list.

## Status

PR #210 landed the primitive Orca terminal adapter: bounded capture, text send, Enter, Ctrl-C interrupt, and close for already-created Orca terminals.
This follow-up adds full ship/scout task lifecycle support for `backend=orca`: spawn, metadata, send/peek/watch/crew-state routing from metadata, and guarded teardown through Orca.

Orca remains explicit-only.
Select it by putting `orca` in a local `config/backend` file, by exporting `FM_BACKEND=orca`, or by telling the first mate in chat to use Orca.
It is not auto-detected from the current process environment.
Before spawn mutates any repo/worktree state, firstmate runs `bin/fmod info` and requires the Orca daemon to report reachable.

## Task Shape

An Orca task is one firstmate-created git worktree plus one Orca daemon session.
Unlike `tmux`, `herdr`, `zellij`, and `cmux`, Orca is not only a session provider; firstmate also creates the task worktree directly, so `fm-spawn.sh` does not run `treehouse get` for Orca tasks.

The normal firstmate invariant still applies: a ship or scout task must run outside the project primary checkout, and teardown must refuse to discard unlanded ship work.

## Metadata

An Orca-spawned task records the normal task fields plus these Orca-specific fields:

```text
backend=orca
window=fm-<id>
terminal=<orca daemon session id>
orca_worktree_id=<absolute worktree path>
worktree=<absolute path to the firstmate-created git worktree>
```

`window=` remains the shared firstmate selector field used by `fm-peek.sh`, `fm-send.sh`, `fm-watch.sh`, `fm-crew-state.sh`, and `fm-teardown.sh`.
For Orca, `window=` keeps the stable firstmate alias while `terminal=` carries the stable daemon session id that backend operations use.
The recorded `backend=orca` field tells shared call sites to route capture, send, interrupt, and close through `bin/backends/orca.sh` instead of tmux assumptions.

## Lifecycle

Spawn:

1. Verify the selected project is a git repo and create an independent task branch plus worktree with `git worktree add -b fm/<id>`.
2. Create or attach the deterministic daemon session id `fm-<id>` with `bin/fmod create --cwd <worktree> --shell-ready`.
3. Verify `bin/fmod get-cwd fm-<id>` matches the new worktree after normalizing a trailing slash; kill stale sessions and recreate once when an existing session is attached elsewhere.
4. Install firstmate's per-harness turn-end hooks in the Orca worktree.
5. Write metadata, then send `GOTMPDIR` export and the selected harness launch through the recorded daemon session.

Operation routing:

- `fm-peek.sh` captures with `bin/fmod snapshot`.
- `fm-send.sh` writes text with `bin/fmod write`, submits with a newline, and verifies the composer row cleared before returning.
  A slash-command popup that closes by filling an argument-hint placeholder still reads as pending, so the retry loop sends the required second Enter rather than treating the first Enter as a submission.
- `fm-send.sh --key Enter` and `--key C-c` are supported.
- `fm-watch.sh` treats Orca as a pull backend with no native busy-state primitive, so it falls back to the same terminal-tail busy regex used for tmux, zellij, and cmux.
- `fm-crew-state.sh` reads the recorded Orca terminal when no no-mistakes run-step applies.

Teardown:

- Scout teardown still requires `data/<id>/report.md` unless `--force` is explicitly used.
- Ship teardown still refuses dirty or unlanded work before any terminal/worktree cleanup.
- Ship teardown treats `orca_worktree_id` as the worktree path and verifies it matches `worktree=` before removing anything; mismatches preserve metadata and fail closed.
- After the existing firstmate safety checks pass, teardown kills the recorded daemon session with `bin/fmod kill --immediate` and removes the git worktree with `git worktree remove --force`.
- Teardown deletes the just-created task branch only when it still points at the original project HEAD, preserving any branch that accumulated work.

## Limitations

- Escape is unsupported because the current Orca terminal send primitive exposes Enter and interrupt-style input but no verified Escape operation.
- Orca is explicit-only and is not selected by runtime auto-detection.
- Orca exposes no stable CLI version marker, but its daemon DOES speak a strict `PROTOCOL_VERSION` over its unix-socket hello. `bin/fmod` is now resilient to that drift: it tries the hardcoded default version first, falls through to discovery (any `daemon-v*.sock` in `~/.config/orca/daemon/`), and pins via `FMOD_PROTOCOL_VERSION` env override when set. See "Daemon protocol" below.

## Secondmates

`--backend orca --secondmate` is supported. Each secondmate maps to a single Orca daemon session whose id is `fm-secondmate-<basename-of-home>`; the home itself is a pre-existing git worktree of the primary repo, registered through `bin/fm-home-seed.sh`. The orca adapter does not call `worktree_create` for secondmates (it must not create a worktree of a worktree); it uses `create_terminal` directly with the home path as cwd. A recovery respawn with the same id reattaches to the existing daemon session instead of creating a new one, so a crashed primary that comes back online does not leave orphan secondmate terminals behind.

Spawn writes `orca_worktree_id=<home path>` and `terminal=<session id>` to meta, and the same `kind=secondmate` fields the other backends already record (`home=`, `projects=`). Teardown kills the orca terminal and removes the spawn state; the home directory and the `data/secondmates.md` registry entry are preserved so a re-spawn can re-create the orca session without re-seeding. This is intentionally different from the tmux/herdr/zellij teardown, which removes the home on a normal teardown - orca secondmates are persistent firstmate homes, and a re-spawn is the much more common case than a retire.

## Daemon protocol

The `orca` CLI is a thin shim that talks to the same Unix-socket daemon the GUI uses. While the GUI holds the single-instance lock, the CLI refuses to run with "Another Orca instance is already running..."; the proper integration path is therefore to talk to the daemon directly, not to shell out to `orca`.

`bin/fmod` is firstmate's small Python client for that daemon. It is the only path `bin/backends/orca.sh` uses; the CLI is never invoked at spawn time.

Why this matters:

- The CLI hangs (or fails fast with single-instance-lock errors) when the GUI is the active holder. The daemon does not.
- The daemon is the same transport the GUI itself uses, so capture/send/kill semantics match exactly what the captain sees on screen.
- The hello handshake is strict on `version`. A hardcoded `PROTOCOL_VERSION = 21` will be silently rejected by an older daemon, and an installed AppImage newer than the source will silently fail. Discovery closes that gap.

### Resilience knobs

- `FMOD_PROTOCOL_VERSION=<int>` - pin a specific version (no discovery).
- `FMOD_SOCKET`, `FMOD_TOKEN`, `FMOD_PIDFILE` - pin socket/token/pid paths explicitly (escape hatch for non-default install layouts).
- Hardcoded default is bumped when the installed AppImage outruns the source; discovery is the safety net for the next bump.

## Daemon supervision

The orca GUI is a single-instance AppImage. On Linux without a desktop session, or after any crash, the daemon can die while `orca-runtime.json` still reads `runtimeState: stale_bootstrap`. Every spawn then refuses with the runtime check.

`bin/fm-supervise-orca.sh` is firstmate's firstmate-owned daemon keeper. It is intentionally separate from `fm-watch.sh` (per-task supervision) so a flaky daemon never widens into per-task noise:

- `bin/fm-supervise-orca.sh once` - single health check (returns 0 if reachable, non-zero otherwise; no relaunch).
- `bin/fm-supervise-orca.sh start` - background the supervisor (writes pid to `state/.orca-supervisor.pid`).
- `bin/fm-supervise-orca.sh stop` - stop a running supervisor.
- `bin/fm-supervise-orca.sh status` - print supervisor liveness and daemon reachability.
- `bin/fm-supervise-orca.sh --follow` - foreground loop (harness-tracked background).

`bin/fm-bootstrap.sh` integrates the supervisor: when `config/backend=orca` (or `FM_BACKEND=orca`), bootstrap calls `once` and reports `ORCA: daemon reachable`. In a mutating bootstrap it will additionally call `start` to relaunch a dead daemon and report `ORCA: daemon recovered`. In `FM_BOOTSTRAP_DETECT_ONLY=1` it only reports; the lock holder's next bootstrap can recover.

## Verification

Real-Orca smoke verification was run against the captain's AppImage install with daemon protocol v21; `bin/fmod info` reported a reachable daemon and `bin/fmod create/get-cwd/snapshot/write/kill` exercised the daemon-direct session lifecycle.
The daemon session id is the firstmate window name (`fm-<id>`), and the worktree id recorded in metadata is the git worktree path created by firstmate.
Firstmate intentionally avoids the Orca CLI during spawn because the GUI single-instance lock makes CLI status and worktree commands unreliable while the app is running.

Live-Linux smoke (recorded against the captain's AppImage install, daemon protocol v21):

- `bin/fm-supervise-orca.sh start` then `pkill -KILL -x orca-ide` recovers the daemon in ~3s.
- `bin/fm-spawn.sh <id> projects/<repo> --backend orca --harness pi` reaches pi's composer with the brief loaded, the per-task external turn-end extension (`state/<id>.pi-ext.ts`) loaded, and `state/<id>.turn-ended` touched after the first turn.
- Two general bugs found and fixed: `fmod get-cwd` returns a trailing-slash path that the spawn's cwd-equality check did not normalize; pi 0.80's project-trust gate blocks unattended spawns and needs `--approve` on the launch template. Both fixes are general firstmate bugs and are candidates for upstream PRs.

Fake-Orca tests cover:

- runtime checking, daemon session creation, worktree cleanup, capture, send, interrupt, and kill routing through fake `bin/fmod`;
- stale-session recreation, trailing-slash cwd normalization, and cwd-verification failure cleanup;
- runtime readiness gating through `bin/fmod info`;
- `fm-spawn.sh --backend orca` metadata creation and harness launch;
- `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` routing through recorded Orca metadata;
- slash-command popup placeholder handling that requires a second Enter before `fm-send.sh` reports submission;
- scout teardown killing the recorded daemon session and removing the git worktree;
- ship teardown failing closed when the recorded Orca worktree id is missing or differs from `worktree=`.

Run the focused suite with:

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```
