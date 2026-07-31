# psmux runtime backend

psmux is a native Windows tmux-compatible terminal multiplexer built on the
Windows ConPTY API - no WSL, no MSYS multiplexer, and no administrator rights.
It is firstmate's spawn backend for Windows hosts, where none of the Unix/macOS
backends (tmux, herdr, zellij, orca, cmux) can run.

psmux reuses firstmate's reference tmux adapter.
bin/backends/psmux.sh sources bin/backends/tmux.sh (and, through it,
bin/fm-tmux-lib.sh) with FM_TMUX_CMD pointed at the resolved psmux binary, so the
session/send/capture/state/kill logic is shared one-for-one with tmux.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend)
owns shared backend selection and metadata semantics.

## Setup

Prerequisites:

- psmux, installed with `winget install --exact --id marlocarlo.psmux` (no admin).
  `bin/fm-bootstrap.sh install psmux` runs the same command.
- Git Bash (MINGW64) as the firstmate shell, providing `bash.exe` and `cygpath`.
- The universal harness and toolchain requirements in
  [`configuration.md`](configuration.md#toolchain).

winget installs psmux into a per-package directory whose name carries a version
hash and adds that directory to the persisted user PATH, so a shell started after
the install finds `psmux` normally.
The adapter also resolves the binary directly from that winget directory, so a
psmux installed in the current session works before the shell is restarted.

## Selection

psmux is explicit-only and is never runtime auto-detected.
Select it with local `config/backend` containing `psmux`, `FM_BACKEND=psmux` for
one launch, or an explicit request to firstmate.
On a Windows home this is the normal way to make firstmate spawn workers: set
`config/backend=psmux` once.
A spawn stops with an actionable message when the psmux binary or `bash.exe`
cannot be resolved.

## Task shape and metadata

Each task owns one window named `fm-<id>` inside a shared `firstmate` psmux
session - the same session/window topology as the tmux backend - so endpoint
metadata is `window=<session>:<window>` plus `backend=psmux`, with no other
backend-specific fields.

## Two psmux differences from tmux, and how they are handled

psmux implements the tmux subcommands firstmate drives, with two exceptions that
`fm_backend_psmux_create_task` (bin/backends/psmux.sh) handles:

- psmux's `new-window` does not print the created window id (tmux's `-P -F` is
  ignored), so the stable window id (`@N`) is resolved afterwards with
  `list-windows -t <session> -F '#{window_id}'`.
- psmux resolves a launched command against the Windows PATH, which does not
  contain bash, and otherwise defaults new windows to PowerShell - so task
  windows are launched with the full path to bash.exe:
  `new-window ... -c <dir> -- "$(cygpath -w bash.exe)" -li`.
  firstmate's bash-syntax sends (treehouse, the harness launch command) then run.

## Active limits

- psmux is EXPERIMENTAL and Windows-only.
- Explicit-only; never runtime auto-detected.
- The worktree provider (treehouse) must be available on the host for a full task
  spawn; psmux provides only the session and terminal.
- `current_directory` is reported as a Windows path (`C:\...`), so worktree-path
  comparison in the full spawn path must account for that form.

## Regression entry points

```sh
tests/fm-backend-psmux-smoke.test.sh
```

The smoke test skips when psmux is not installed; otherwise it drives a real
psmux session through firstmate's own backend functions (source, container,
create a bash task window, send, capture, kill) and asserts the window runs bash.
