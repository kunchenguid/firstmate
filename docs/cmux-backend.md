# cmux runtime backend

cmux is an experimental macOS GUI terminal backend.
It provides task workspaces and surfaces while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick cmux when you already use the app as your terminal and want task workspaces in its sidebar.
cmux is macOS-only, GUI-first, and unsuitable for a headless or SSH-only Firstmate session.

Prerequisites:

- cmux 0.64 or newer, installed from [cmux.com](https://cmux.com) or with `brew install --cask cmux`.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The CLI is not always installed on `PATH` with the app.
The adapter prefers `command -v cmux` and otherwise uses `/Applications/cmux.app/Contents/Resources/bin/cmux`.

### Required socket access

cmux defaults to a control mode that rejects external shells, while Firstmate always controls it from an external process.
Open Settings > Automation and choose a viable Socket Control Mode before the first cmux-backed spawn.

| Setting | Value | Firstmate support | Security boundary |
| --- | --- | --- | --- |
| Off | `off` | No | The socket listener is disabled. |
| cmux processes only | `cmuxOnly` | No | Only descendants of the cmux app can connect. |
| Automation mode | `automation` | Yes, recommended | The owner-only 0600 socket admits processes of the current macOS user. |
| Password mode | `password` | Yes | The 0600 socket also requires an auth handshake. |
| Full open access | `allowAll` | Yes, not recommended | The 0666 socket admits every local user without authentication. |

Automation mode is the recommended same-user boundary.
`allowAll` can execute commands through a world-writable control socket and should be selected only as an explicit security tradeoff.

For Password mode, store the password as the first line of local gitignored `config/cmux-socket-password` or provide `CMUX_SOCKET_PASSWORD` in Firstmate's environment.
The adapter reads the file fresh from the effective config directory and does not overwrite an ambient password when the file is absent.
Configure the mode and password through the cmux UI rather than editing `cmux.json`; the app does not retain a hand-added password key, and socket-based reload cannot fix a socket that is rejecting the caller.

Select cmux with local `config/backend` containing `cmux`, `FM_BACKEND=cmux` for one launch, or an explicit request to Firstmate.
It can also be runtime auto-detected when Firstmate itself runs inside cmux.
A spawn stops with an actionable setup message when the app, minimum version, `jq`, socket access, or password is unavailable.
The adapter may launch the app with `open -a cmux` only when the socket is down; it does not relaunch the app for access-denied or authentication errors.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without bringing the cmux window forward.
Task workspace and surface creation use `focus=false`.

Verify setup by spawning a small task and confirming metadata contains `backend=cmux`, `cmux_workspace_id=`, and `cmux_surface_id=`.

## Runtime detection

`CMUX_WORKSPACE_ID` is the primary cmux runtime marker.
`CMUX_SOCKET_PATH` is not sufficient because operators may set it outside cmux.
Detection checks tmux first, then Herdr, then cmux, so a multiplexer nested inside cmux remains the active backend.

cmux's bundled Claude wrapper can remove every `CMUX_*` variable when its internal socket probe fails, including in Password mode.
On macOS only, detection therefore falls back first to `__CFBundleIdentifier=com.cmuxterm.app`, then to process ancestry reaching the running cmux app.
Those fallbacks are consulted only when neither tmux nor Herdr already won.
An environment-scrubbed or launchd-reparented process with no reliable marker is not auto-detected.

Auto-detection selects only the backend.
It never changes socket access or grants credentials.
The spawn refusal explains how to finish cmux setup or opt back into tmux.

## Task shape and metadata

Each task owns one cmux workspace with one surface.
The caller-facing label remains `fm-<id>`, while the visible workspace title is `fm-<home-label>-<id>`.
The home label is `firstmate` or `2ndmate-<id>` plus a stable short hash of the resolved Firstmate root.
cmux does not enforce title uniqueness, so create, recovery, list, and cleanup paths all validate this scoped title.
Relocating the Firstmate installation changes the hash and leaves old titles unmatched, consistent with recorded worktree paths also becoming stale.

```text
backend=cmux
window=<workspace-uuid>:<surface-uuid>
cmux_workspace_id=<workspace-uuid>
cmux_surface_id=<surface-uuid>
```

The UUID pair is the active endpoint authority within one app run.
Workspace UUIDs are not stable across an app relaunch, so recovery searches by the scoped title and then resolves the current surface id.

## Current operation and safety

A genuinely fresh surface returns an internal error from `read-screen` until something has been written.
Target readiness therefore uses the structural `list-panes` response instead of a content read.
Capture remains bounded and locally trimmed after `read-screen` becomes available.

`current_directory` follows a top-level shell `cd` but not the foreground subshell opened by `treehouse get`.
Spawn-time worktree discovery sends begin and end markers around `pwd`, captures the marked block, and joins wrapped path lines.

An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and only its best-effort constant doorbell passes through cmux's submit machinery.
On the typed plane, literal send and Enter are separate calls.
Enter, Escape, and Ctrl-C are supported.
The composer verifier is a thin adapter: it captures a bounded plain-text tail and hands it with cmux's capability facts to the fleet-wide classifier in `bin/fm-composer-lib.sh`, which owns every shape, including Claude's borderless `❯` row with its U+00A0 separator.
`read-screen` is plain text with no cursor primitive, so the shared classifier degrades a glyph row carrying trailing text to `unknown` rather than misreading a harness's own idle suggestion as unsent input.
An unstructured bare prompt is `unknown`, and a slash-popup placeholder remains `pending`, so only Enter is retried and text is never retyped.
cmux exposes no native generic agent busy signal, so supervision uses capture/hash polling for screen changes and each harness adapter's semantic lifecycle for worker state.
Grok alone retains its isolated rendered-tail fallback.

A task workspace's last surface cannot be closed directly.
Cleanup owns the whole workspace and uses `close-workspace`.
cmux also refuses to remove the only workspace in a macOS window while returning a misleading success response.
When the task is last in its window, Firstmate creates one unfocused unnamed sibling workspace in that same window, closes the task workspace, and leaves the window with cmux's fresh default workspace.
The sibling never carries an `fm-` title and is ignored by recovery.

The exact window membership is re-read before this operation.
A selected workspace that is not last closes normally; selection itself is not the trigger.
Firstmate does not attempt to close the macOS window because cmux's socket cannot close a window holding a live terminal.

Real tests share the captain's running app rather than creating an isolated cmux session.
`tests/cmux-test-safety.sh` permits cleanup only for an exact currently listed `fm-test-` workspace and never enumerates and closes unrelated workspaces or relaunches the app.

## Adopting an existing workspace (fm-adopt)

`bin/fm-adopt.sh <id> --workspace <ws-uuid> [--surface <surf-uuid>]` registers an ALREADY-RUNNING cmux workspace - one a human started, not a firstmate spawn - as a supervised task.
It creates no treehouse worktree and no branch: it records `kind=adopted`, `mode=adopted`, `backend=cmux`, `window=<ws>:<surface>`, `cmux_workspace_id=`/`cmux_surface_id=`, and a `worktree=` that points at the workspace's own live `current_directory` (falling back to `$HOME` with a loud notice when cmux reports no usable cwd), so `fm-peek.sh`, `fm-send.sh`, `fm-crew-state.sh`, and the watcher all operate on the workspace.
It never renames the human's workspace: peek and send target the surface by pure UUID because `kind=adopted` makes `fm_backend_expected_label_of_selector` return an empty expected-label, so `fm_backend_cmux_target_ready` verifies liveness with `surface_exists` alone and never applies the scoped-title check that would reject the human's own title.
`bin/fm-teardown.sh` on a `kind=adopted` task un-registers it (removes its `state/<id>.meta`) but NEVER runs `close-workspace` and NEVER runs `treehouse return`, so the human's workspace and its shell are left exactly as they were.
`bin/fm-watch.sh` exempts `kind=adopted` windows from stale-pane wakes, exactly like a secondmate, because a human-driven or idle session being quiet is healthy rather than stuck.

KNOWN LIMITATION - adopted tasks are session-scoped and do not survive a cmux relaunch.
Workspace ids do not survive an app relaunch, and an adopted workspace keeps the human's own title rather than a firstmate `fm-<home-label>-<id>` title, so title-based recovery (`fm_backend_cmux_list_live`) cannot re-find it after a relaunch the way it re-finds a spawned task.
After a cmux relaunch, re-run `fm-adopt` against the workspace's new UUID to re-register it.

Empirical verification (2026-07-05, real cmux 0.64.17, macOS aarch64), touching only an `fm-test-`-prefixed throwaway workspace and closing only what this pass itself created:

```
$ cmux new-workspace --name fm-test-adopt-probe --focus false --id-format uuids
OK workspace:14
$ cmux workspace list --json --id-format uuids | jq -r '.workspaces[]|select(.title=="fm-test-adopt-probe")|"\(.id)\t\(.current_directory)"'
1BC9DFBA-067B-4596-A2C7-DD46197D1597	/home/dev/example-project

# Adopt it by UUID (surface auto-resolved), into a scratch FM_HOME/state:
$ bin/fm-adopt.sh probe-live --workspace 1BC9DFBA-067B-4596-A2C7-DD46197D1597
adopted probe-live backend=cmux window=1BC9DFBA-067B-4596-A2C7-DD46197D1597:57F297C6-94CA-46A1-A7A2-3292F6B03CC5 worktree=/home/dev/example-project
# state/probe-live.meta recorded kind=adopted, mode=adopted, backend=cmux,
# worktree=/home/dev/example-project, and both cmux ids.

# Steer and read it by pure UUID (empty expected-label, human title preserved):
$ bin/fm-send.sh fm-probe-live "echo adopted-probe-ok"     # rc 0; text landed at the composer
$ bin/fm-peek.sh fm-probe-live 12                          # rc 0; showed the live human surface

# Teardown un-registers WITHOUT closing the workspace:
$ bin/fm-teardown.sh probe-live
teardown probe-live complete (window 1BC9DFBA-...:57F297C6-..., worktree /home/dev/example-project)
Backlog: adopted task probe-live released - its cmux workspace was left running (never closed) ...
# state/probe-live.meta removed; the workspace was still listed afterward:
$ cmux workspace list --json --id-format uuids | jq -r '.workspaces[]|select(.id=="1BC9DFBA-067B-4596-A2C7-DD46197D1597")|.title'
fm-test-adopt-probe

# Cleanup performed by this verification pass itself (never firstmate teardown):
$ cmux close-workspace --workspace 1BC9DFBA-067B-4596-A2C7-DD46197D1597
OK workspace:14
```

The `send`/`peek` steps confirm the empty-expected-label path against the REAL app: the workspace's human title (`fm-test-adopt-probe`) is not a firstmate-scoped title, so a title check would have rejected it, yet both operations reached the surface by pure UUID.
The teardown step confirms the never-closes guarantee live: `state/probe-live.meta` was removed while `cmux workspace list` still reported the workspace present.

## Active limits

- cmux is experimental, macOS-only, GUI-first, and requires the app running.
- Socket access requires a one-time manual Settings change.
- Secondmate spawns are unsupported until a per-home lifecycle design is verified.
- There is no native busy or push-event signal.
- A target can disappear after structural readiness and before the operation.
- The only-workspace cleanup path leaves a fresh default workspace and cannot close the window.
- Label lookup and recovery are currently scoped to the current cmux window, so a task moved to a non-current window is a known recovery blind spot.
- Workspace ids do not survive app relaunch and are never recovery authority.

## Regression entry points

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-cmux-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#cmux) records the active source and live evidence, including socket modes and last-in-window cleanup.
