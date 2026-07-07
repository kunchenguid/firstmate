# WezTerm Runtime Backend

WezTerm is an explicit runtime backend for firstmate setups that want native WezTerm panes.
Shared installs still fall back to tmux unless `config/backend`, `FM_BACKEND`, or `--backend` selects WezTerm explicitly.

Firstmate uses native WezTerm multiplexing:

- One WezTerm tab per firstmate project/home.
- One WezTerm pane per crewmate or sub-agent inside that tab.
- Treehouse still provides each task's isolated git worktree.

## Setup

Install WezTerm and make its CLI available as one of:

- `wezterm`
- `wezterm.exe`
- `/mnt/c/Program Files/WezTerm/wezterm.exe`
- `/c/Program Files/WezTerm/wezterm.exe`
- the explicit path in `FM_WEZTERM_BIN`

Select it with local config:

```sh
mkdir -p config
printf '%s\n' wezterm > config/backend
```

`fm-bootstrap.sh` requires WezTerm, `jq`, `node`, `gh`, Treehouse, no-mistakes, gh-axi, chrome-devtools-axi, and lavish-axi for this backend. It does not require tmux for `backend=wezterm`.
WezTerm itself is a manual install: `fm-bootstrap.sh install wezterm` refuses instead of trying to run the installer guidance as a shell command.
The adapter also requires these mux CLI features: `list --format`, `get-text --start-line`, `send-text --no-paste`, `split-pane --percent`, and `kill-pane --pane-id`.

Away-mode (`/afk`) supervision can inject escalation digests back into firstmate's own WezTerm pane when `WEZTERM_PANE` is present, or when `FM_SUPERVISOR_BACKEND=wezterm` and `FM_SUPERVISOR_TARGET=wezterm:<pane-id>` are set explicitly.

## Shell Contract

Each task pane starts an explicit POSIX shell before firstmate sends `treehouse get`, environment assignments, or harness launch commands.
The adapter prefers `bash -l` when `bash` is available and falls back to `sh`.
When running under Git Bash or MSYS with a native `wezterm.exe`, the adapter passes WezTerm the Windows path for the Git Bash/MSYS `bash.exe`.
WSL and Linux paths remain POSIX paths.

## Layout

The first task for a project creates a tab titled:

```text
FM - <home-label> - <project>
```

Later tasks for the same project reuse that tab and split panes:

- second pane: split down
- third and fourth panes: split right to form a grid
- later panes: split the largest known pane, alternating direction for balance

The local tab registry lives at:

```text
state/wezterm-tabs.tsv
```

It is local runtime state, not committed.
The registry is reused only when an existing task meta file proves a live pane in the recorded tab; stale entries without live task proof are ignored and replaced.

## Metadata

A WezTerm task records:

```text
backend=wezterm
window=wezterm:<pane-id>
wezterm_window_id=<window-id>
wezterm_tab_id=<tab-id>
wezterm_pane_id=<pane-id>
wezterm_tab_title=<title>
```

`window=` is intentionally opaque to callers. Use `fm-<id>` selectors for normal `fm-send.sh`, `fm-peek.sh`, and `fm-teardown.sh` calls.

When an operation is routed from `fm-<id>` metadata, firstmate verifies the live WezTerm `window_id`, `tab_id`, `pane_id`, and cwd-under-recorded-worktree against the recorded task metadata before sending text, capturing output, or killing a pane.
This keeps a stale `wezterm:<pane-id>` target from acting on an unrelated pane after WezTerm restarts or reuses ids.

Forced secondmate teardown rebinds WezTerm child cleanup to the secondmate home's own `state/` directory before validating metadata.
That keeps child panes killable even when the parent firstmate home is driving the cleanup.

For `--secondmate` launches, the parent records `backend=wezterm` and the WezTerm pane metadata in its own `state/<id>.meta`, but the child agent command clears ambient `FM_BACKEND` before setting `FM_HOME`.
That keeps the secondmate home's runtime backend independent unless its own local `config/backend` selects one.

## Known Limits

WezTerm's CLI sends Enter through `send-text --no-paste` with a carriage return byte.
The committed coverage uses a fake WezTerm CLI; run a real-environment smoke test before relying on this backend in a new setup.

## Verification Notes

Fake WezTerm CLI coverage verifies spawn, split, current-path probing, send, capture, kill, composer-state checks, feature probes, stale-pane rejection, secondmate `FM_BACKEND` clearing, and forced secondmate child cleanup paths.
It also verifies the Git Bash/MSYS WezTerm install path and explicit POSIX shell arguments for spawn and split-pane calls.
Commands run:

```sh
bash tests/fm-backend.test.sh
bash tests/fm-backend-wezterm.test.sh
bash tests/fm-bootstrap.test.sh
bash tests/fm-daemon.test.sh
bash tests/fm-session-start.test.sh
bash tests/fm-teardown.test.sh
bash tests/fm-update.test.sh
```

Observed output included:

```text
ok - wezterm target_ready: expected labels reject stale pane ids reused by another tab
ok - wezterm bin: discovery includes the Git Bash/MSYS Windows install path
ok - wezterm shell args: Git Bash/MSYS prefers the converted bash.exe path
ok - force teardown kills WezTerm children using the child home state
```
