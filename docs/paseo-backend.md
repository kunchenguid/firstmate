# Paseo runtime backend

Paseo is an experimental macOS GUI terminal backend.
It provides task workspaces and terminals while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick Paseo when you already use the app as your terminal and want each project's tasks as tabs of one `firstmate` workspace in its sidebar, with the same UX as Herdr.
Paseo is macOS-only, GUI-first, and unsuitable for a headless or SSH-only Firstmate session.

Prerequisites:

- Paseo 0.8 or newer, installed from [paseo.sh](https://paseo.sh) (`/Applications/Paseo.app`).
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

The bundled CLI is not always installed on `PATH` with the app.
The adapter prefers `command -v paseo` and otherwise uses `/Applications/Paseo.app/Contents/Resources/bin/paseo`.

No socket-access configuration is needed.
The daemon listens on `127.0.0.1:6767` by default, and `paseo status` reports its reachability.
The adapter starts the daemon with `paseo start` only when it is simply not up yet, and fails fast with a pointer here when a started daemon does not become reachable.

Select Paseo with local `config/backend` containing `paseo`, `FM_BACKEND=paseo` for one launch, or an explicit request to Firstmate.
It can also be runtime auto-detected when Firstmate itself runs inside a Paseo-managed agent environment.
A spawn stops with an actionable setup message when the CLI, minimum version, `jq`, or daemon reachability is unavailable.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without bringing the Paseo window forward.

Verify setup by spawning a small task and confirming metadata contains `backend=paseo`, `paseo_terminal_id=`, and `paseo_workspace_id=`.

## Runtime detection

`PASEO_AGENT_ID` is the primary Paseo runtime marker.
On macOS only, detection falls back to `__CFBundleIdentifier=sh.paseo.desktop` when a wrapper stripped the `PASEO_*` variables.
Detection checks tmux first, then Herdr, then cmux and its fallback signals, then Paseo, so a multiplexer nested inside Paseo remains the active backend (innermost wins: `TMUX` > `HERDR_ENV` > `CMUX_WORKSPACE_ID` > `PASEO_AGENT_ID`).

Auto-detection selects only the backend.
It never grants credentials.
The spawn notice names the winning signal, and the spawn refusal explains how to finish Paseo setup or opt back into tmux.

## Task shape and metadata

Paseo's sidebar is project > workspace > terminal tab, and Firstmate uses one shared workspace per project with one tab per task, the same container shape as Herdr.
The shared workspace is titled `firstmate` (or `2ndmate-<id>` for a secondmate home), created once with `workspace create --path <project> --isolation local --title <label>` and adopted on later spawns by matching that cwd and title in `workspace ls`.
The adapter never runs a `paseo project` command: Paseo registers or reuses the project by path when the workspace is created, so a fleet of tasks appears as tabs under one sidebar entry rather than as one workspace or one project per task.
Agents running inside a task tab may open further tabs or workspaces of their own; nothing in the adapter depends on them.

Each task owns one terminal tab in that workspace.
The terminal's NAME (`terminal create --name fm-<home-label>-<id>`) is the firstmate-facing routing authority, home-scoped so two Firstmate homes sharing one daemon can never cross-match each other's terminals.
The workspace title only identifies the shared workspace to adopt; it is never used to route a task.

The recorded target is the pair `<terminal_id>:<workspace_id>`:

```text
backend=paseo
window=<terminal-uuid>:<workspace-uuid>
paseo_terminal_id=<terminal-uuid>
paseo_workspace_id=<workspace-uuid>
```

The recorded terminal id is validated against the live `terminal ls` inventory before every send.
When the recorded id is gone, recovery re-resolves the terminal by its home-scoped NAME from the same inventory, never by title.

## Current operation and safety

`terminal send-keys <id> -l -- <text>` sends literal, unsubmitted input.
The caller sends Enter separately.
Enter, Escape, and Ctrl-C are supported token sends.

`terminal capture <id> -S --json` returns plain-text lines with ANSI stripped.
There is no per-call line bound, so the adapter fetches the scrollback whole and trims the tail locally.
Because capture strips styling, the capability descriptor declares `styled=0`, and the shared classifier in `bin/fm-composer-lib.sh` degrades a glyph row carrying trailing text to `unknown` rather than misreading an idle suggestion as unsent input.

A terminal's `cwd` field in `terminal ls` is creation-time-frozen and never follows the foreground subshell opened by `treehouse get`.
Spawn-time worktree discovery therefore sends begin and end markers around `pwd`, captures the marked block, and joins wrapped path lines, exactly like cmux and zellij.

Cleanup closes only the task's tab with `terminal kill`; sibling task tabs and the shared workspace stay alive.
It is best-effort like every backend's kill, so an already-gone target stays quiet.
The adapter never archives the shared workspace; an operator who archives it by hand simply makes the next spawn create a fresh one.
Mutating `--json` calls keep stderr out of the parsed output, because the CLI prints an Electron warning on stderr when Firstmate itself runs inside a Paseo agent.
Paseo exposes no native generic agent busy signal, so supervision uses capture/hash polling for screen changes and each harness adapter's semantic lifecycle for worker state.

## Visible tabs versus nested agent views

Paseo can show sub-agents nested inside the current tab, clickable to open as their own view, without opening a separate top-level tab.
Firstmate's design keeps the terminal-per-task model as the authority: every task gets exactly one terminal tab in the project's shared workspace, opened at spawn and closed at cleanup.
A nested sub-agent view therefore never becomes routing or lifecycle authority for Firstmate - it is an extra view the captain may click into while the task's single terminal remains the endpoint.

The practical tradeoff: a task terminal running a harness that itself spawns sub-agents will show those agents nested inside the task's tab, not as new top-level tabs, so the tab count under the shared workspace matches Firstmate tasks exactly.
The tradeoff surfaced is agent surface versus terminal surface - a nested agent view is visible and clickable but not separately addressable by `fm-send`/`fm-peek`, which always target the task's one recorded terminal.

A closed tab does not preserve its visible scrollback history: `terminal kill` reclaims the endpoint with no transcript left behind for later reading.
Durable history for a finished task therefore lives in the status log, the report, and the PR, never in tab scrollback - the same reason firstmate never treats a status line as more than a wake event.

## Active limits

- Paseo is experimental, macOS-only, GUI-first, and requires the app running.
- Secondmate spawns are unsupported until a per-home lifecycle design is verified.
  An explicitly selected Paseo refuses `--secondmate`, while an auto-detected Paseo spawns the secondmate on tmux instead.
- There is no native busy or push-event signal, and `fm_backend_agent_state` reports `unverified` for Paseo.
- A target can disappear after structural readiness and before the operation.
- Workspace and terminal ids are not assumed stable across daemon restarts; recovery re-resolves by terminal NAME.

## Regression entry points

```sh
tests/fm-backend-paseo.test.sh
tests/fm-backend-paseo-smoke.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#paseo) records the active source and live evidence.
