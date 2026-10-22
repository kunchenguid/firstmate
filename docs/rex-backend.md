# Rex Backend

Rex (`https://www.superlogical.com/rex`) is an EXPERIMENTAL Firstmate session provider for crewmates, scouts, and second mates, local or remote.
Rex is a terminal multiplexer with a server > session > window (tab) > block (pane) hierarchy and a scriptable `rex` CLI.
The adapter is `bin/backends/rex.sh`; worktrees still come from treehouse.

## Setup

Install the Rex app and its `rex` CLI (`https://www.superlogical.com/rex/docs/installation`).
The adapter finds `rex` in `REX_BIN_DIR`, then on `PATH`, then at the CLI bundled inside the Rex app's server.
It also needs `jq` and `treehouse`, which bootstrap reports when rex is the resolved backend.

The Rex server is the shared container, like a tmux server, and Firstmate never starts, stops, or restarts it.
The adapter uses the default local server unless `FM_REX_SERVER` names another one.
A spawn stops with an actionable setup message when the CLI, `jq`, the server, or the minimum API revision (4) and the block methods the adapter calls are unavailable.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without moving the captain's view.

Verify setup by spawning a small task and confirming metadata contains `backend=rex`, `rex_server=`, and `rex_block_id=`.

## Selection and detection

Select Rex with local `config/backend` containing `rex`, `FM_BACKEND=rex` for one launch, or `--backend rex` on a spawn.

Rex is also auto-detected when Firstmate itself runs in a Rex pane.
Detection stays innermost-first: `$TMUX` wins, then `HERDR_ENV`, then Rex.
Rex exports `REX_SERVER`, `REX_SESSION`, `REX_BLOCK`, and `REX_CLIENT` into every descendant process, including a tmux server started from a Rex pane, so those markers alone never select Rex.
Detection requires structural proof: `REX_BLOCK` is live on the server, it sits in `REX_SESSION`, and that block's child process is an ancestor of the detecting process.
A detected selection prints a one-line notice naming the experimental backend and how to opt out.

## Task shape and metadata

Each task is one Rex tab holding one block, in its home's own worker session:

| Home | Session label | What it holds |
| --- | --- | --- |
| The primary home | `fm-local` | Every ship and scout tab, never in the session Firstmate itself runs in |
| A second mate's home | `fm-<secondmate-id>` | The second mate's own pane as the first tab, then its workers as further tabs |

One adapter function, `fm_backend_rex_task_session_locked` in `bin/backends/rex.sh`, makes every placement and naming decision.
A session label is display and an identity check, never routing:

- A relaunch or reclaim reuses the session its record names while that session is live and still carries the label.
- Otherwise the one live session with the label is adopted, and one is created, with the task as its first tab, when none exists.
- Two or more sessions with the label refuse as ambiguous.
- A second mate's own workers prefer the session the second mate is proven to run in.
- A primary-home task never opens in Firstmate's own session; if that session is itself labeled `fm-local`, the spawn refuses.

Tabs open with `--focus=false`, so a spawn never moves the captain's view.
The tab label is short enough for the Rex sidebar, at most 24 visible characters and clipped with an ellipsis beyond that.
An explicit `fm-spawn.sh --title <text>` is used as given; otherwise the label is a kind marker (`Ship`, `Scout`, or `Mate`) plus the backlog item's title condensed to its first clause, else the task id, for example `Ship · Rex-native status`.
The label is recorded as `rex_tab_label=`.
A relaunch keeps the recorded label unless it passes a new `--title`.
The block label `fm-<home-label>-<id>` stays the identity cross-check; it is home-scoped so two homes sharing one server never cross-match.

Rex labels are not unique, so the recorded full block id on the recorded server is the routing authority; the block label is only an identity check made before every send.
The window id is advisory, because moving a block to another tab keeps its block id.

```text
backend=rex
window=<session-uuid>:<block-uuid>
rex_server=<server endpoint>
rex_server_instance=<server instance id>
rex_session_id=<session-uuid>
rex_window_id=<window-uuid>
rex_block_id=<block-uuid>
rex_tab_label=<sidebar label>
```

`rex_server_instance` lets recovery tell a restarted server from a closed pane.
Rex children inherit the login shell's environment, not the calling CLI's, so the spawn exports the recorded server as `REX_SERVER` into the worker's shell before launching the agent.

## Current operation and safety

Every `rex` call the adapter makes passes the recorded server with `-S` and `--autostart=false`, because a call aimed at a missing socket would otherwise start a fresh, empty server.
Every call addresses its session and block by full id with `-s` and `-b`, and runs with `REX_SESSION`, `REX_BLOCK`, `REX_CLIENT`, and `REX_SERVER` removed from its environment, because several commands fall back to the caller's own pane or the focused block when no target is given.

With full ids, exit 3 ("target not found") means the block is gone.
Exit 4 means the server could not be reached, which is unknown and never gone; recovery treats it as unproven rather than closing anything.

Text rides `rex send`'s standard input, so option-shaped text arrives literally; keys go through the same command as terminal bytes.
The adapter maps Enter, Escape, Tab, Space, BSpace, C-c, C-d, C-u, and C-l, and refuses any other key name.
`rex capture --trim` reads plain text; the composer read uses `--format vt` so SGR styling survives for the shared classifier in `bin/fm-composer-lib.sh`.
The live worktree path comes from the block's foreground process cwd, so spawn-time discovery needs no echoed markers.

`fm_backend_agent_state` reads the block's foreground process, plus the terminal's foreground process group, through the same agent-process classifier tmux and herdr use: a recognized harness process is alive, a bare shell or a recorded exit is dead, anything else is ambiguous, and a closed block is missing.

Cleanup closes only the task's block and then requires exit 3 on that block id before reporting success; an already-gone block stays quiet.
When the closed tab was the last one in the home's own `fm-local` or `fm-<id>` session, cleanup closes that session too, unless it is Firstmate's own session or still holds a detached block.
Spawning and that cleanup share one home-wide lock (`state/.rex-session.lock`), so a new task's tab can never land in a session between its empty check and its close.

- Rex's agent SessionStart hook (`rex __internal session-start`) tells every Claude and Codex agent to rename its session, which for a Rex-backed worker or second mate is a shared session Firstmate finds by name; every brief and charter `bin/fm-brief.sh` scaffolds therefore tells the agent to ignore that prompt, and the captain can also turn off automatic agent session naming in Rex Settings -> Integrations.

## Second mates

`bin/fm-spawn.sh <id> --secondmate --backend rex` opens the second mate as the first tab of its own `fm-<id>` session.

- The parent never adopts an unrecorded `fm-<id>` session for a new second mate pane, because another parent home on the same server may own it.
- A respawn after the pane is proven gone (exit 3) reuses the session the record names while it is live, moving the new tab to the front.
- An unreachable server (exit 4) leaves the second mate unproven and is never treated as dead.
- The second mate's block keeps the parent home's scoped label, so the parent's sends, reads, and cleanup cross-check it.
- Retiring the second mate closes its pane and, once nothing else is left in it, its `fm-<id>` session.
- A forced child cleanup closes the second mate's own workers as that home, so each label check uses the home that created it.

## Remote second mates

A remote second mate on Rex runs in a visible `fm-<id>` session on that host's own Rex server, the one its Rex app runs, so a Rex client connected to that server shows it in its tree.
[`remote-secondmates.md`](remote-secondmates.md) owns the route, the `--backend rex` choice, and the readiness checks; the host runs the same placement as a local second mate.

## Away mode

`/afk` works when Firstmate runs in a Rex pane.

- Supervisor discovery accepts Firstmate's own pane only through the same structural proof as detection.
  An inherited `REX_BLOCK` alone never names the pane to inject into.
- The away daemon runs in a detached block of the captain's session: it is addressable by id but sits in no tab, so the captain's tab strip never changes.
- The away record stores the block's target and its server, and closing it is verified by exit 3 on that block id.
- Injects pass the shared composer gate, so an escalation never lands on text the captain is typing.

## Attention marks

The captain sees which worker needs them from Rex itself.
`bin/fm-rex-marks.sh` turns each Rex task's latest status into one program-status record (OSC 7501, `app=firstmate`, `id=fm`) on that worker's pane, so Rex badges its tab, session, and Activity entry while the worker's own agent keeps the pane's root status.

| Worker status | Record | Message |
| --- | --- | --- |
| `needs-decision`, or a captain hold | `blocked`, kind `question` | `Needs your decision: <note>` |
| `blocked` naming a credential or login | `blocked`, kind `auth` | `Blocked: <note>` |
| other `blocked` | `blocked`, kind `permission` | `Blocked: <note>` |
| `failed` | `error` | `Failed: <note>` |
| `done` with a PR URL | `done` | `PR ready: <note>` |
| other `done` | `done` | `Done: <note>` |
| anything else | removed | |

Each new record that needs the captain also carries an OSC 777 desktop notification titled `Firstmate: <tab label>`, because Rex sounds and notifications follow each pane's root program status, not a child record.
The notification fires once per change, never on a repeated sync.
Rex has no API to set a record, so the mark is one small write to the pane's terminal device; a `working` or `blocked` record is dropped when the agent's shell prints its next prompt or exits, and the next sync writes it again.
The watcher runs `fm-rex-marks.sh sync` once per poll while any Rex task or cached mark exists, and cleanup clears the mark before closing the pane.
Every write first checks the block label, so a mark never lands on a pane that no longer belongs to the task.

`config/rex-status-marks` turns the marks `on` (the default when the file is absent) or `off`; turning them off clears every mark already shown.
`state/.rex-mark-<id>` caches the last mark so a sync writes only on change.

## Event push

On Rex the watcher wakes on Rex events instead of only polling.
`fm_backend_rex_wait_transition` follows `rex events -s <session> --json` for the session holding the watched tasks and reacts to three events on a watched block:

- `program_status_changed` to `blocked` on the root record is an agent waiting on a human; it escalates at once, and a later `working` re-arms it.
- `child_exited` or `block_closed` is a worker that exited or a pane that closed; it escalates at once instead of waiting for the liveness poll.
  A tab Firstmate closes itself, such as at teardown, never escalates: the close records the `dead` edge as already handled first, and a `dead` edge for a pane no task record names any more is dropped.
- `idle` and `done` defer to the ordinary checks, and Firstmate's own records (`app=firstmate`, or any child `id`) are ignored.

The stream replays nothing, so every subscribe pokes the session until a `client_connected` event proves it live and then reconciles each watched block by reading its current state.
Exit 4, a closed stream, or a failed subscribe returns to plain polling for that cycle and is never read as a dead worker.
`bin/fm-transition-lib.sh` owns the shared transition record and policy that herdr also uses.

## Busy and submit signals

Claude Code publishes a root program status on Rex, proven by `tests/fm-rex-program-status-live-e2e.test.sh`, which also fails if that record still reads `working` after the worker reports done; so for it `fm_backend_busy_state` reads `working` as busy (only while the agent process is alive) and `idle`, `done`, or `blocked` as idle.
A steer is confirmed submitted when the composer reads empty, or when the root status moves to `working` from a baseline that was not already working.
`FM_BACKEND_REX_STATUS_APPS` lists the harnesses trusted this way; every other harness keeps capture and hash polling.

## Active limits

- Rex is a beta that changes often; the adapter gates on API revision 4 and the block methods it calls, and the dated verification record should be re-run after each Rex update.
- A server holds 64 sessions, 64 tabs per session, and 1024 blocks by default (`rex server start --help`), so one session holds at most 64 concurrent tasks.
- A server restart ends every worker on it.
- Rex has no viewport-only read: `rex capture` and the `format` block method both include scrollback and omit trailing blank rows, so the visible screen cannot be located. Rex is therefore not a visible-capture backend: Kimi spawns and devin and Command Code armed interrupts are refused, and the composer classifier runs without a cursor row.
- A Pi composer on Rex reads as unknown, because the classifier runs without a cursor row and Pi's prompt carries no identifying border; the composer gate then defers rather than types.
- Only harnesses proven to publish a root program status get the native busy signal; the others use capture/hash polling and each harness adapter's semantic lifecycle for worker state.
- An attention mark is a terminal write, so a `blocked` mark disappears at the agent's next shell prompt until the next watcher poll writes it again.

## Lab helper

`bin/fm-rex-lab.sh` runs a private headless Rex server on a short socket under `/tmp` for tests and Rex-driving tasks, and checks on teardown that the live server's instance and sessions are unchanged.
A brief scaffolded with `fm-brief.sh --rex-lab` carries the matching safety contract.

## Regression entry points

```sh
tests/fm-backend-rex.test.sh
tests/fm-backend-rex-smoke.test.sh
tests/fm-afk-inject-rex-e2e.test.sh
tests/fm-remote-doctor-rex.test.sh
FM_REX_SECONDMATE_E2E=1 tests/fm-rex-secondmate-e2e.test.sh
FM_REX_CLAUDE_LIVE=1 tests/fm-rex-claude-live-e2e.test.sh
FM_REX_STATUS_LIVE=1 tests/fm-rex-program-status-live-e2e.test.sh
```

- `fm-backend-rex.test.sh` and `fm-remote-doctor-rex.test.sh` use a fake `rex`.
- The smoke and away-mode tests drive the real binary on a lab server without tokens.
- The program-status test spawns one trivial scout per installed harness and records which root states each publishes; it fails if Claude Code stops publishing `working`.
- The second mate test launches a real Pi second mate on a lab server, aborting before any model request, so it only runs when opted in.
- The last spawns a real Claude scout and submits prompts, so it only runs when opted in.
[`verification/runtime-backends.md`](verification/runtime-backends.md#rex) records the active source and live evidence.
