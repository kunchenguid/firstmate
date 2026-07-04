# tmux runtime backend (reference)

tmux is firstmate's verified reference runtime backend: the session provider every other backend is compared against, and the fully verified baseline for secondmate support.
This is the setup guide; for the shared runtime-backend abstraction and selection order, see [`docs/architecture.md`](architecture.md) ("Runtime session backends") and [`docs/configuration.md`](configuration.md) ("Runtime backend").

## What it is and when to pick it

tmux is a terminal multiplexer.
Firstmate gives each worker agent its own tmux window inside a session, so you can attach and watch a task work, or type into its window to intervene directly.
Pick tmux unless you have a specific reason to try an experimental backend (herdr, zellij, cmux, or Orca) - it is the fully verified reference path for secondmate homes, while Orca is the backend that does not support secondmate spawns.

## Prerequisites

- tmux itself: `brew install tmux` (or your platform's package manager).
- A verified crew harness: `claude`, `codex`, `opencode`, `pi`, or `grok`.
- `git` with GitHub auth (`gh auth login`).
- `node`, required by firstmate's universal toolchain.
- `treehouse` for pooling clean worktrees; `no-mistakes` for the validation pipeline; `gh-axi`, `chrome-devtools-axi`, and `lavish-axi` for GitHub, browser, and rich-review operations.

The orchestrator detects missing tools at session start and offers to install them after you approve.

## Selecting it

tmux is the hard default: it needs no explicit selection.
It is also what firstmate falls back to when nothing else is set - no local `config/backend` file, no `FM_BACKEND`, no explicit `--backend` flag firstmate passes internally when it spawns a task - and runtime auto-detection (see below) does not pick anything either.
You can still select it explicitly by putting `tmux` in a local `config/backend` file - the durable way to pick it - or by exporting `FM_BACKEND=tmux` when you launch your harness for a one-off session; telling the orchestrator in chat to use tmux also works.
This mainly matters as an opt-out of herdr's runtime auto-detection (see [`docs/herdr-backend.md`](herdr-backend.md)).

## First run

Nothing to provision up front.
The first worker spawn creates whatever tmux session and window it needs.

## Run inside tmux for the best experience

Launch your harness from inside a tmux session (`tmux new -s firstmate` or similar, then start your agent).
Every worker window then lands in that same session, where you can watch the staff work in real time or type into any window to intervene.
When following the commands below, use that session's actual name.
Inside tmux, `tmux display-message -p '#S'` prints it.

## Outside tmux: the detached `firstmate` session

If you launch your harness outside of tmux, worker windows land in a detached session named `firstmate`, created on first use.
Attach to it any time with:

```sh
tmux attach -t firstmate
```

## Watching and typing into worker windows

Once attached, each worker is its own window named `fm-<id>`:

```sh
tmux list-windows -t <session-name>          # see every worker window
tmux select-window -t <session-name>:fm-<id> # jump to one, or use ctrl-b <n>
```

Use the current tmux session name when firstmate was launched inside tmux; use `firstmate` only for the detached outside-tmux path.
Typing directly into an attached window is authoritative direct intervention - the orchestrator treats it the same as any other user instruction and reconciles at the next heartbeat.
You do not need to attach at all for routine supervision: the orchestrator reads worker windows itself with `bin/fm-peek.sh fm-<id>` (a bounded, read-only capture) and steers a worker with `bin/fm-send.sh fm-<id> "<text>"` when it needs to intervene.

## Verifying it works

Ask the orchestrator for any small piece of work, or spawn a trivial scout task, and confirm a new window shows up:

```sh
tmux list-windows -t <session-name>
```

Use the current tmux session name for the run-inside-tmux path, or `firstmate` for the detached outside-tmux path.
You should see a `fm-<id>` window for the task, live and updating as the worker runs.

## Limitations

None specific to tmux - it is the fully verified reference backend, while Orca is the backend without secondmate support.
