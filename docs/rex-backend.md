# Rex Backend

Rex (`https://www.superlogical.com/rex`) is an EXPERIMENTAL Firstmate session provider for crewmates, scouts, and second mates, local or remote.
Rex is a terminal multiplexer with a server > session > window (tab) > block (pane) hierarchy and a scriptable `rex` CLI.
The adapter is `bin/backends/rex.sh`; worktrees still come from treehouse.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Install the Rex app and its `rex` CLI (`https://www.superlogical.com/rex/docs/installation`).
The adapter finds `rex` in `REX_BIN_DIR`, then on `PATH`, then at the CLI bundled inside the Rex app's server, because Rex exports `REX_BIN_DIR` into every pane while shell startup files commonly reset `PATH`.
It also needs `jq` and `treehouse`, which bootstrap reports when rex is the resolved backend.

The Rex server is the shared container, like a tmux server, and Firstmate never starts, stops, or restarts it.
The adapter uses the default local server unless `FM_REX_SERVER` names another one.
A spawn stops with an actionable setup message when the CLI, `jq`, the server, API revision 5 on both the CLI and the server, or the block methods the adapter calls are unavailable.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without moving the captain's view.

Verify setup by spawning a small task and confirming metadata contains `backend=rex`, `rex_server=`, and `rex_block_id=`.

## Selection and detection

Select Rex with local `config/backend` containing `rex`, `FM_BACKEND=rex` for one launch, or `--backend rex` on a spawn.

Rex is also auto-detected when Firstmate itself runs in a Rex pane.
Detection stays innermost-first: `$TMUX` wins, then `HERDR_ENV`, then Rex.
Rex exports `REX_SERVER`, `REX_SESSION`, `REX_BLOCK`, `REX_CLIENT`, and `TERM_PROGRAM=rex` into every descendant process, including a tmux server started from a Rex pane, so those markers alone never select Rex.
Detection requires structural proof: `REX_BLOCK` is live on the server, it sits in `REX_SESSION`, and that block's child process is an ancestor of the detecting process.
A detected selection prints a one-line notice naming the experimental backend and how to opt out.

## Task shape and metadata

Each task is one Rex tab holding its block, plus any [side panes](#side-panes) the worker opens, in its home's own worker session:

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
An unviewed block starts at 80x24, so each new task block is resized to 200x50; a client that later views it takes ownership and applies its own size, and the first tab of a session the spawn just created keeps the creating CLI as its size owner, so the resize does not apply there.
The tab label is short enough for the Rex sidebar, at most 24 visible characters and clipped with an ellipsis beyond that.
An explicit `fm-spawn.sh --title <text>` is used as given; otherwise the label is a kind marker (`Ship`, `Scout`, or `Mate`) plus the backlog item's title condensed to its first clause, else the task id, for example `Ship · Rex-native status`.
The label is recorded as `rex_tab_label=`.
A relaunch keeps the recorded label unless it passes a new `--title`.
The block label `fm-<home-label>-<id>` stays the identity cross-check; it is home-scoped so two homes sharing one server never cross-match.

Rex labels are not unique, so the recorded full block id on the recorded server is the routing authority; the block label is only an identity check made before every send.
Rex never reuses an id, so the recorded block names exactly one block for its whole life.
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

Text rides `rex send`'s standard input, so option-shaped text arrives literally; keys go through `rex send-key`.
The adapter maps Enter, Escape, Tab, Space, BSpace, C-c, C-d, C-u, and C-l, and refuses any other key name.
`rex capture --trim` reads plain text, the screen plus scrollback, and the adapter trims the tail locally.
The live worktree path comes from the block's foreground process cwd, which follows the nested subshell `treehouse get` opens, so spawn-time discovery needs no echoed markers.

Rex has no viewport-only read, so the visible viewport is derived from one styled read through the `format` block method (`vt` with `extra_cursor`), which returns the scrollback plus the full screen grid, blank rows included, and then the cursor position as a trailing `ESC[<row>;<col>H`.
The vt grid joins rows with CRLF, so an empty bottom row leaves the content ending in CRLF with that row implicit; the adapter restores it and takes the last `size.rows` rows as the viewport.
A full-screen program's grid is the screen alone, so the derivation holds on both screens; a resize landing between the size read and the grid read can skew it by the size difference.
Rex is therefore in `FM_BACKEND_VISIBLE_CAPTURE`, so viewport-only callers such as Kimi's trust-dialog check work on it.
The shared composer classifier in `bin/fm-composer-lib.sh` reads that styled viewport with styling, row count, process identity, and the cursor row available, the same evidence tmux gives it: the shape holding the cursor is the composer, so furniture a harness draws below its composer cannot decide the verdict.
Where that cursor-anchored read is `unknown`, as for a harness that parks its cursor outside its composer, the cursorless read that takes the bottom-most shape decides instead.

`fm_backend_agent_state` reads two independent sources through the same agent-process classifier tmux and herdr use: Rex's `process` view of the foreground process and every one of its ancestors, and the kernel's foreground process group on the block's tty.
A recognized harness anywhere in either is alive (a harness running a pager or an interactive shell escape is still there), a foreground that is nothing but shells or a recorded exit is dead, anything else is ambiguous, and a closed block is missing.

Cleanup closes only the task's block and then requires exit 3 on that block id before reporting success; an already-gone block stays quiet.
It then closes the task's [side panes](#side-panes) in the task's current and recorded tabs (only the recorded one when the block was already gone), and leaves every other pane alone.
An unreadable pane list or a side pane still present after close fails the cleanup, so the task's record stays and cleanup can be retried.
When the closed tab was the last one in the home's own `fm-local` or `fm-<id>` session, cleanup closes that session too, unless it is Firstmate's own session or still holds a detached block.
Spawning, reclaiming, and that cleanup share one home-wide lock (`state/.rex-session.lock`), so a new task's tab can never land in a session between its empty check and its close.

`bin/fm-control.sh` `exit` and `relaunch` work on Rex; [`agent-control.md`](agent-control.md#reclaiming-a-task-whose-endpoint-is-gone) owns the recorded-server absence proof and reclaim placement.
An ordinary spawn refuses any block carrying the task's scoped label.
A reclaim closes such a block first when it is a bare shell, the husk of an earlier reclaim that refused before its record was republished, and refuses one that still runs an agent.

## Side panes

A worker running in its own Rex pane can open side panes beside itself in its tab, so the captain sees a test run, a dev server, or validation progress next to the worker.

```sh
bin/fm-rex-side.sh open tests -- make test
bin/fm-rex-side.sh open dev -- env PORT=3000 npm run dev
bin/fm-rex-side.sh list
bin/fm-rex-side.sh close dev
```

- A side pane opens below the worker without taking focus and stays open after its command exits, so its last output stays readable; `list` shows whether each one is running or exited, with its exit status.
- A name already open in the tab refuses until `close <name>` closes it.
- Its label is `<worker block label>/<name>`, for example `fm-firstmate-42de5bad-t1/tests`, because Rex records no creating client on a block.
- The helper acts only from a proven worker pane, with the same structural proof as detection, and refuses with nothing changed anywhere else.
- Cleanup closes exactly the task's labeled side panes in its current and recorded tabs, so no orphan tab is left even after the worker's pane moved; a foreign pane in those tabs is never closed, and a side pane that does not close fails the cleanup.
- The command runs with the login shell's environment, not the caller's.

Every ship and scout brief tells the worker about the helper, except a `--rex-lab` brief, whose contract keeps the worker off the live server.
The script's header owns the options and exit codes.

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
- The palette's **Show or Hide Away Pane** command shows that block below the focused pane and hides it again; see [Command palette](#command-palette).

## Command palette

Firstmate can add its own commands to the Rex command palette, grouped under **Firstmate**.
Installing them edits the captain's Rex `init.lua` and reloads every connected client's keymap, so Firstmate installs them only on the captain's word:

```sh
bin/fm-rex-palette.sh install    # also: uninstall
```

- The installer owns only one marked block at the top of that file, so the captain's own later lines always win, and `uninstall` leaves the rest of the file byte for byte as it was.
- It works only on this machine's own Rex server, because Rex reloads its config only over the local socket; its header owns the backup, check, and symlink mechanics.
- No key is bound: the captain assigns a shortcut to any command in the Rex app.
- When Firstmate's module fails to load, the captain's config still loads and the palette shows **Firstmate: Palette Failed to Load** with the reason.

| Command | What it does |
| --- | --- |
| Show Fleet | A popup with the fleet view. |
| This Worker | A popup with the focused worker's task, latest status, open decisions, and pull request. |
| Peek Worker | A popup that follows the focused worker's screen. |
| Go to Waiting Worker | Shows the tab of the worker waiting on the captain: a decision first, then a blocker, a failure, and a ready pull request. |
| Show or Hide Away Pane | Shows away mode's hidden supervisor pane below the focused pane, or hides it again; it keeps running either way. |
| Answer Decision | A popup listing open decisions and captain holds; the typed answer is filed as `Answer for <task> [key=<key>]: <text>`. |
| Tell Firstmate | A popup for a free note, filed with `About <task>:` in front when a worker is focused. |
| Request Merge | A popup listing recorded pull requests; a confirmed pick is filed as `Merge request: <PR URL> (task <task>)`. |

The three acting commands only file a note in Firstmate's captain inbox through `bin/fm-inbox.sh`, which wakes Firstmate.
Firstmate then answers the worker or merges through its usual paths and checks; the palette itself never steers a worker or merges.
A popup closes itself when its command ends.

On a pane that lives on another host, such as a remote second mate's, a command resolves the pane to that second mate from this home's records: its own pane, or any pane in its `fm-<id>` session, because Firstmate reaches a second mate's workers only through the second mate.
Peek then uses the remote route, and notes name the second mate.
A popup always runs on this machine, so for such a pane it opens in this machine's `fm-local` session and Rex is asked to show that session; without one the command says so.
Go to Waiting Worker likewise shows this machine's `fm-local` session for a remote second mate, never a session on the other host.

Rex gives a command 30 seconds and runs it in the Rex server's own environment, so each command only asks `bin/fm-rex-popup.sh plan` what to do and leaves slow work to the popup, and the installer records the operator's `PATH` and `FM_HOME`.
A command run from the CLI never moves the captain's view; only a key or palette use does.
`bin/fm-rex-popup.sh`'s header owns the plan and popup contracts.

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

Each record's title is the task's tab label, so Rex labels it with the name Firstmate gave the tab rather than a branch or the agent's terminal title.
Each new record that needs the captain also carries an OSC 777 desktop notification titled with the tab label, because Rex sounds and notifications follow each pane's root program status, not a child record.
Firstmate never writes the root record: the harness owns it, and a second root report for the same turn makes Rex notify twice.
Firstmate's own records never count as the worker's state, for busy detection or for push escalation.
The notification fires once per change, never on a repeated sync.
Rex has no API to set a record, so the mark is one small write to the pane's terminal device; a `working` or `blocked` record is dropped when the agent's shell prints its next prompt or exits, and the next sync writes it again.
The watcher runs `fm-rex-marks.sh sync` once per poll while any Rex task or cached mark exists, and cleanup clears the mark before closing the pane.
Every write first checks the block label, so a mark never lands on a pane that no longer belongs to the task.

`config/rex-status-marks` turns the marks `on` (the default when the file is absent) or `off`; turning them off clears every mark and progress record already shown.
`state/.rex-mark-<id>` caches the last mark so a sync writes only on change.

### Validation progress

While a ship validates through no-mistakes and has no mark, its pane carries a second record, `id=fm/validate` in state `working`, whose progress is the share of pipeline steps done and whose message names the active step, for example `Validating: review 3/9, auto-fix 1/3`.
Rex shows it in the tab and pane hover cards, so the captain can see how far each validation is without opening the worker.
The sync reads the run on the task's branch with one bounded `no-mistakes axi status` at most every 30 seconds per task (`FM_REX_PROGRESS_INTERVAL`), and removes the record when the run ends or the task gets a mark; clearing the mark also removes the record beneath it.
`state/.rex-progress-<id>` caches the last plan.

### State tint

`config/rex-tint` opts in to a subtle background tint on a worker that waits on the captain or on help (a `blocked` mark) or has failed (an `error` mark): `off` (the default when the file is absent), `subtle` for a dark theme, or `subtle-light` for a light theme.
A running or finished worker is never tinted, and the tint is reset when the mark leaves that state, at cleanup, and when the tint is turned off.
Rex applies a theme set through its API only to a pane no client owns, and the app owns every pane it shows, so the tint is an in-band OSC 11 written to the pane's terminal and the reset is OSC 111.
It changes only cells the program leaves at the default background, a harness that picked its colors from the background at startup keeps them, and a tint left by a stopped watcher stays until the next sync.
Firstmate never sends an OSC 11 query, because the answer would arrive in the worker as typed text.
`state/.rex-tint-<id>` records the tint written, since a tint cannot be read back.

## Push events

While the watcher waits between polls, a Rex home runs one bounded `rex do` reader ([`bin/backends/rex-eventwait.lua`](../bin/backends/rex-eventwait.lua)) on the session holding its task tabs, on the server their records name, listening only to those tasks' blocks.
The reader subscribes first and the current program status of each block is reconciled after, so a block that went `blocked` between waits is reported once and an edge during the reconcile is not lost.
A trusted `blocked` root program status takes the immediate escalation path instead of waiting for the stale-pane timer; [push verification](verification/runtime-backends.md#rex) records measured latency.
It counts only under the same trust rule as native busy state (see [Busy and submit signals](#busy-and-submit-signals)), and its wake reason carries Rex's blocked kind (`permission`, `question`, or `auth`) and the program's message, cut at 160 characters.
[`bin/fm-transition-lib.sh`](../bin/fm-transition-lib.sh) owns the shared policy and per-block escalation dedupe contract.
The watcher skips secondmate endpoints, declared waits, and captain-held work exactly as it does for Herdr's push path.

When a watched block's program exits or the block closes, the wait ends at once so the watcher's next poll reconciles that task immediately.
That never wakes the supervisor by itself, because a routine cleanup closes blocks too.

The push path only shortens latency, and polling stays the fallback.
Supervision polls when the CLI or server is below API revision 5 or unreachable (the reader never starts a server), when the reader cannot start or ends before its deadline, and after the watcher's consecutive-reader-failure threshold is reached (three by default).
Task tabs in a second Rex session stay on polling, because one reader covers one session.

## Busy and submit signals

A harness that speaks Rex's Program Status Protocol (OSC 7501) reports a root record on its pane.
A root record counts only while the process that reported it is the block's foreground process or one of its ancestors, because without shell integration a `working` record outlives the command that reported it; Firstmate's own records (`app=firstmate`, and every child `id`) never count.
For a trusted record, `fm_backend_busy_state` reads `working` as busy and `idle`, `done`, `blocked`, or `error` as idle; that native state is positive busy evidence only, exactly like Herdr's, so the harness's own lifecycle stays the busy authority.
[Worker-tool verification](verification/runtime-backends.md#rex) owns which harnesses report it.
A steer is confirmed submitted when the composer reads empty, or when the trusted root status moves to `working` from a baseline that was not already working.
Still-pending text after the Enter retries counts as a queued delivery only when the shared queued-Enter policy accepts a trusted native busy state or the harness's rendered busy footer.

## Active limits

- Rex is a beta that changes often; the adapter gates on API revision 5 and the block methods it calls, and the dated verification record should be re-run after each Rex update.
- A server holds 64 sessions, 64 tabs per session, 64 panes per tab, and 1024 blocks by default (`rex server start --help`), so one session holds at most 64 concurrent tasks and a worker's tab at most 63 side panes.
- A server restart ends every worker on it; recovery proves such tasks gone from the restarted server and reclaims them into fresh tabs, while a stopped server stays unproven until it is running again.
- The viewport is derived, not read directly, as described above.
- Only harnesses that report OSC 7501 contribute native busy evidence; the others are classified from their own lifecycle and rendered footer.
- Command Code is refused on Rex until it is live-verified there, and Cursor Agent is not yet live-verified on Rex.
- An attention mark or progress record is a terminal write, so a `blocked` or `working` record disappears at the agent's next shell prompt until the next watcher poll writes it again.
- There is no Rex CI lane; see "Regression entry points" below for real-Rex validation.

## Deferred upstream asks

These asks to Superlogical are deliberately unfiled, pending a later decision; each line names the Firstmate impact that would go away.

- **Viewport-only capture**: the viewport would be read directly instead of derived from the last `size.rows` rows of a full capture, removing the resize skew.
- **Cursor position as a JSON field**: the adapter would stop parsing the cursor out of the trailing escape sequence of the `format` read.
- **Dropping `working` and `blocked` program-status records when their owner exits**: native busy state could be trusted without cross-checking every record against the live process view.
- **A documented compatibility floor and machine-readable version output with the API revision**: the version gate would stop parsing `rex version` text.
- **A per-session or per-block opt-out for the agent hook's automatic session rename**: a harness running in a task tab could not rename the shared session Firstmate finds it by.
- **A configurable default size for unviewed blocks**: spawn would no longer need to resize every new 80x24 task block to 200x50.
- **`rex` on `PATH` inside blocks even when shell startup files reset it**: the adapter could drop its `REX_BIN_DIR` and server-bundle fallbacks.

## Lab helper

`bin/fm-rex-lab.sh` runs a private headless Rex server on a short socket under `/tmp` for tests and Rex-driving tasks, can restart it to prove recovery after a server restart, and checks on teardown that the live server's instance and sessions are unchanged.
A brief scaffolded with `fm-brief.sh --rex-lab` carries the matching safety contract.

## Regression entry points

```sh
tests/fm-backend-rex.test.sh
tests/fm-backend-rex-smoke.test.sh
tests/fm-backend-rex-eventwait-smoke.test.sh
tests/fm-afk-inject-rex-e2e.test.sh
tests/fm-remote-doctor-rex.test.sh
tests/fm-rex-palette.test.sh
tests/fm-rex-palette-smoke.test.sh
FM_REX_SECONDMATE_E2E=1 tests/fm-rex-secondmate-e2e.test.sh
FM_REX_COMPOSER_LIVE=1 tests/fm-backend-rex-composer-live-e2e.test.sh
FM_REX_CLAUDE_LIVE=1 tests/fm-rex-claude-live-e2e.test.sh
FM_REX_STATUS_LIVE=1 tests/fm-rex-program-status-live-e2e.test.sh
```

- `fm-backend-rex.test.sh`, `fm-remote-doctor-rex.test.sh`, and `fm-rex-palette.test.sh` use a fake `rex`.
- The smoke, push smoke, palette smoke, and away-mode tests drive the real binary on a lab server without tokens; the smoke test also restarts its lab server to verify recovery after a restart.
- The composer guard launches every installed harness idle on a lab server, without submitting a prompt, and requires its composer to read empty.
- The program-status test spawns one trivial scout per installed harness and records which root states each publishes.
- The second mate test launches a real Pi second mate on a lab server, aborting before any model request, and retires a second one with a single teardown, so it only runs when opted in.
- The Claude live test spawns a real Claude scout and submits prompts, so it only runs when opted in.
[`verification/runtime-backends.md`](verification/runtime-backends.md#rex) records the active source and live evidence.
