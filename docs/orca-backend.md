# Orca Backend

Orca is an experimental runtime backend for firstmate.
It is distinct from the crewmate harness: the harness is the agent process firstmate launches (`claude`, `codex`, `opencode`, `pi`, or `grok`), while Orca owns the task worktree and terminal endpoint underneath that process.

## Setup

Pick Orca if you already run the Orca macOS app as your terminal environment and want firstmate tasks to live in Orca-managed worktrees and terminals instead of a treehouse/tmux pair.
Orca is macOS-only, explicit-only (never auto-detected), and has no secondmate support.

Prerequisites:

- The Orca app installed at `/Applications/Orca.app`, and **running**.
- The `orca` CLI: `brew install orca`.
- `node`, used by firstmate's adapter to parse Orca's JSON output and to gate spawns on runtime readiness.
- `git` with GitHub auth, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, and `lavish-axi` - the same universal requirements as tmux, minus `tmux` and `treehouse` (Orca replaces both).

Select Orca by putting `orca` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=orca` when you launch your harness for a one-off session; telling the first mate in chat to use Orca also works.
It is never auto-detected.
When bootstrap resolves Orca from `FM_BACKEND=orca` or `config/backend=orca`, it checks for `orca`, keeps the universal `node` requirement, and skips `tmux` and `treehouse`.

First run: before spawn mutates any repo or worktree state, firstmate runs `orca status --json` and requires the app to report `reachable=true` and `state="ready"` - start the Orca app and wait for it to finish loading before spawning.
Spawn fails closed if the runtime is not ready.
The first spawn against a given project also auto-registers that project's repo in Orca (`orca repo add --path`) if it is not already registered - no manual registration step is needed.

Watching and attaching: Orca owns both the worktree and the terminal for its tasks, so there is nothing to attach to outside the Orca app itself - open the app and find the terminal for the task (recorded as `terminal=<handle>` in the task's meta, with `window=fm-<id>` as the shared firstmate alias).
You do not need to open the app for routine supervision: `bin/fm-peek.sh fm-<id>` reads a task's terminal without opening Orca, and `bin/fm-send.sh fm-<id> "<text>"` steers it (Enter and Ctrl-C are supported; Escape is not).

Verify it works by spawning a trivial task with `--backend orca` and confirming the task's meta records `backend=orca`, `terminal=`, `orca_worktree_id=`, and `worktree=`; the Orca app should show a new terminal for the task.

Limitations: `--secondmate` spawns refuse `backend=orca` (secondmate-home semantics need a separate design), Escape is unsupported, Orca is macOS-only and explicit-only, and it exposes no stable CLI version marker, so spawn gates on runtime reachability instead of a version floor - see "Limitations" below for the complete list.

## Status

PR #210 landed the primitive Orca terminal adapter: bounded capture, text send, Enter, Ctrl-C interrupt, and close for already-created Orca terminals.
This follow-up adds full ship/scout task lifecycle support for `backend=orca`: spawn, metadata, send/peek/watch/crew-state routing from metadata, and guarded teardown through Orca.

Orca remains explicit-only.
Select it by putting `orca` in a local `config/backend` file, by exporting `FM_BACKEND=orca`, or by telling the first mate in chat to use Orca.
It is not auto-detected from the current process environment.
Before spawn mutates any repo/worktree state, firstmate runs `orca status --json` and requires the Orca runtime to report reachable/ready.

## Task Shape

An Orca task is one Orca-managed git worktree plus one Orca terminal.
Unlike `tmux`, `herdr`, `zellij`, and `cmux`, Orca is not only a session provider; it also provides the task worktree, so `fm-spawn.sh` does not run `treehouse get` for Orca tasks.

The normal firstmate invariant still applies: a ship or scout task must run outside the project primary checkout, and teardown must refuse to discard unlanded ship work.

## Metadata

An Orca-spawned task records the normal task fields plus these Orca-specific fields:

```text
backend=orca
window=fm-<id>
terminal=<orca terminal handle>
orca_worktree_id=<orca worktree id>
worktree=<absolute path to the Orca-created git worktree>
```

`window=` remains the shared firstmate selector field used by `fm-peek.sh`, `fm-send.sh`, `fm-watch.sh`, `fm-crew-state.sh`, and `fm-teardown.sh`.
For Orca, `window=` keeps the stable firstmate alias while `terminal=` carries the stable Orca terminal handle that backend operations use.
The recorded `backend=orca` field tells shared call sites to route capture, send, interrupt, and close through `bin/backends/orca.sh` instead of tmux assumptions.

## Lifecycle

Spawn:

1. Ensure the project repo is registered in Orca, adding it with `orca repo add --path` when needed.
2. Create an independent Orca worktree with `orca worktree create --repo id:<repo> --name fm-<id> --no-parent --setup skip`.
3. Reuse the terminal returned by Orca worktree creation only when it appears in the verified `result.terminal.handle` shape, or create a titled terminal in that worktree when Orca returns only the worktree.
4. Install firstmate's per-harness turn-end hooks in the Orca worktree.
5. Write metadata, then send `GOTMPDIR` export and the selected harness launch through the recorded Orca terminal.

Operation routing:

- `fm-peek.sh` captures with `orca terminal read`.
- `fm-send.sh` types text with `orca terminal send --text ...`, submits with Enter, and verifies the composer row cleared before returning; when Orca reports a limited page, the verifier follows `oldestCursor` and preserves the current tail so older text cannot hide still-pending composer input.
  A slash-command popup that closes by filling an argument-hint placeholder still reads as pending, so the retry loop sends the required second Enter rather than treating the first Enter as a submission.
- `fm-send.sh --key Enter` and `--key C-c` are supported.
- `fm-watch.sh` treats Orca as a pull backend with no native busy-state primitive, so it falls back to the same terminal-tail busy regex used for tmux, zellij, and cmux.
- `fm-crew-state.sh` reads the recorded Orca terminal when no no-mistakes run-step applies.

Teardown:

- Scout teardown still requires `data/<id>/report.md` unless `--force` is explicitly used.
- Ship teardown still refuses dirty or unlanded work before any terminal/worktree cleanup.
- Ship teardown resolves `orca_worktree_id` back through Orca and verifies it matches the inspected `worktree=` path before removing anything; mismatches or uninspectable paths preserve metadata and fail closed.
- After the existing firstmate safety checks pass, teardown closes the recorded Orca terminal and releases the recorded worktree through `orca worktree rm --worktree id:<orca_worktree_id> --force`.
- Teardown does not raw-delete Orca worktrees.

## Limitations

- `--secondmate` spawns still refuse `backend=orca`; secondmate-home semantics need a separate design.
- Escape is unsupported because the current Orca terminal send primitive exposes Enter and interrupt-style input but no verified Escape operation.
- Orca is explicit-only and is not selected by runtime auto-detection.
- Orca exposes no CLI version marker, but its daemon DOES speak a strict `PROTOCOL_VERSION` over its unix-socket hello. `bin/fmod` is now resilient to that drift: it tries the hardcoded default version first, falls through to discovery (any `daemon-v*.sock` in `~/.config/orca/daemon/`), and pins via `FMOD_PROTOCOL_VERSION` env override when set. See "Daemon protocol" below.

## Daemon protocol

The `orca` CLI is a thin shim that talks to the same Unix-socket daemon the GUI uses. While the GUI holds the single-instance lock, the CLI refuses to run with "Another Orca instance is already running..."; the proper integration path is therefore to talk to the daemon directly, not to shell out to `orca`.

`bin/fmod` is firstmate's small Python client for that daemon. It is the only path `bin/backends/orca.sh` uses; the CLI is never invoked at spawn time.

Why this matters:

- The CLI hangs (or fails fast with single-instance-lock errors) when the GUI is the active holder. The daemon does not.
- The daemon is the same transport the GUI itself uses, so capture/send/kill semantics match exactly what the captain sees on screen.
- The hello handshake is strict on `version`. A hardcoded `PROTOCOL_VERSION = 21` will be silently rejected by an older daemon, and an installed AppImage newer than the source will silently fail. Discovery closes that gap.

### Resilience knobs

- `FMOD_PROTOCOL_VERSION=<int>` — pin a specific version (no discovery).
- `FMOD_SOCKET`, `FMOD_TOKEN`, `FMOD_PIDFILE` — pin socket/token/pid paths explicitly (escape hatch for non-default install layouts).
- Hardcoded default is bumped when the installed AppImage outruns the source; discovery is the safety net for the next bump.

## Daemon supervision

The orca GUI is a single-instance AppImage. On Linux without a desktop session, or after any crash, the daemon can die while `orca-runtime.json` still reads `runtimeState: stale_bootstrap`. Every spawn then refuses with the runtime check.

`bin/fm-supervise-orca.sh` is firstmate's firstmate-owned daemon keeper. It is intentionally separate from `fm-watch.sh` (per-task supervision) so a flaky daemon never widens into per-task noise:

- `bin/fm-supervise-orca.sh once` — single health check (returns 0 if reachable, non-zero otherwise; no relaunch).
- `bin/fm-supervise-orca.sh start` — background the supervisor (writes pid to `state/.orca-supervisor.pid`).
- `bin/fm-supervise-orca.sh stop` — stop a running supervisor.
- `bin/fm-supervise-orca.sh status` — print supervisor liveness and daemon reachability.
- `bin/fm-supervise-orca.sh --follow` — foreground loop (harness-tracked background).

`bin/fm-bootstrap.sh` integrates the supervisor: when `config/backend=orca` (or `FM_BACKEND=orca`), bootstrap calls `once` and reports `ORCA: daemon reachable`. In a mutating bootstrap it will additionally call `start` to relaunch a dead daemon and report `ORCA: daemon recovered`. In `FM_BOOTSTRAP_DETECT_ONLY=1` it only reports; the lock holder's next bootstrap can recover.

## Verification

Real-Orca smoke verification was run against `/usr/local/bin/orca` with `/Applications/Orca.app` reporting bundle version `1.4.116`; `orca status --json` reported `result.runtime.reachable=true` and `result.runtime.state="ready"`.
The verified terminal creation handle field is `result.terminal.handle` from `orca terminal create --json`; worktree creation returned `result.worktree.id` and `result.worktree.path` in the same smoke run.
Firstmate intentionally ignores speculative terminal-handle shapes such as bare `result.id` and nested `result.worktree.terminal` until a real Orca smoke run proves them.

Live-Linux smoke (recorded against the captain's AppImage install, daemon protocol v21):

- `bin/fm-supervise-orca.sh start` then `pkill -KILL -x orca-ide` recovers the daemon in ~3s.
- `bin/fm-spawn.sh <id> projects/<repo> --backend orca --harness pi` reaches pi's composer with the brief loaded, the per-task external turn-end extension (`state/<id>.pi-ext.ts`) loaded, and `state/<id>.turn-ended` touched after the first turn.
- Two general bugs found and fixed: `fmod get-cwd` returns a trailing-slash path that the spawn's cwd-equality check did not normalize; pi 0.80's project-trust gate blocks unattended spawns and needs `--approve` on the launch template. Both fixes are general firstmate bugs and are candidates for upstream PRs.

Fake-Orca tests cover:

- helper parsing for repo registration, worktree creation, verified implicit-terminal reuse, terminal creation, terminal sends, and worktree removal;
- rejection of undocumented terminal-handle result shapes;
- runtime readiness gating through `orca status --json`;
- `fm-spawn.sh --backend orca` metadata creation and harness launch;
- `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` routing through recorded Orca metadata;
- slash-command popup placeholder handling that requires a second Enter before `fm-send.sh` reports submission;
- scout teardown releasing an Orca worktree through `orca worktree rm`;
- ship teardown failing closed when the recorded Orca worktree id is missing, cannot resolve to a path, or resolves to a different path than `worktree=`.

Run the focused suite with:

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```
