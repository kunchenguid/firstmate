# Rex runtime backend

Rex is an experimental terminal multiplexer backend from [Superlogical](https://www.superlogical.com/rex).
It provides task tabs and their terminal blocks while Treehouse continues to provide git worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick Rex when you already run Firstmate inside Rex and want each task as its own tab next to your session.
Rex is in beta, and its sessions live in a personal server that does not keep them across a server stop.

Prerequisites:

- Rex with API revision 5 or newer, for both the `rex` CLI and the running server.
- `jq` for JSON responses.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Rex ships its CLI inside the server bundle and exports `REX_BIN_DIR` into every block, but shell startup files commonly reset `PATH`.
The adapter therefore prefers `$REX_BIN_DIR/rex`, then `rex` on `PATH`, then the server bundle path under `~/Library/Application Support/com.superlogical.rex/`.

Select Rex by running Firstmate directly inside a Rex block (see "Auto-detection"), with local `config/backend` containing `rex`, with `FM_BACKEND=rex` for one launch, or with an explicit request to Firstmate.
A spawn stops with an actionable setup message when the CLI, `jq`, the API revision, or the server is unavailable.

Routine supervision uses `bin/fm-peek.sh <id>` and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` without bringing any tab forward.

Verify setup by spawning a small task and confirming its metadata contains `backend=rex`, `rex_server=`, `rex_session_id=`, `rex_window_id=`, and `rex_block_id=`.

## Auto-detection

Rex exports `TERM_PROGRAM=rex` with `REX_SESSION`, `REX_BLOCK`, `REX_SERVER`, and `REX_BIN_DIR` into every block.
`TERM_PROGRAM=rex` together with `REX_BLOCK` selects Rex, checked after `$TMUX` and `HERDR_ENV=1` and before cmux.
A tmux or Herdr started inside a Rex block rewrites `TERM_PROGRAM` but inherits the `REX_*` variables, so a nested multiplexer is detected as itself and `REX_BLOCK` alone never selects Rex.
Auto-detected Rex stays silent, and explicit `--backend`, `FM_BACKEND`, or `config/backend` always win.
Spawned workers keep the `REX_*` variables and `TERM_PROGRAM`, so a secondmate launched from a Rex-hosted home stays on Rex too.

## Task shape and metadata

Rex's hierarchy is server > session > window (a tab) > block (a pane), and each task is one window holding one block.
When Firstmate itself runs directly inside a Rex block, every task tab opens in Firstmate's own session, once the server confirms that the block named by `REX_BLOCK` lives in the session named by `REX_SESSION`.
A claim the server cannot confirm refuses rather than guessing a placement.
Otherwise, and always for a secondmate's own home, the tab opens in one session per home labeled with the home tag (`firstmate-<hash>` or `2ndmate-<id>-<hash>`), adopted when exactly one session carries that label, created once when none does, and refused when several do.
A newly created local secondmate session is placed immediately after the launching session when `REX_SESSION` is available; a respawned secondmate tab in an adopted session is moved to the first position ahead of its crews.
Both ordering steps are best-effort: a failure warns without failing the launch.
The secondmate session label's hash is based on the secondmate home, not the launching home's code root.

Tabs in an existing session are created with `window new --focus=false`; when a per-home session must be created, its initial window becomes the first task's tab.
An unviewed block starts at 80x24, so the adapter attempts to resize each new task block to 200x50 and warns if resizing fails; a client that later views it takes ownership and applies its own size.
The tab is labeled `fm-<id>` for you, and the block carries the home-scoped label `fm-<home-tag>-<id>`, used only for duplicate refusal and recovery listing.

The recorded target is `<session-uuid>:<block-uuid>`, because Rex ids carry their own colon (`session:<uuid>`, `block:<uuid>`):

```text
backend=rex
window=<session-uuid>:<block-uuid>
rex_server=<server endpoint>
rex_session_id=session:<uuid>
rex_window_id=window:<uuid>
rex_block_id=block:<uuid>
```

The immutable block id is the routing authority.
Rex never reuses an id, so the recorded block names exactly one block for its whole life.
Every CLI call passes the recorded session with `-s`, because the CLI otherwise defaults to the caller's own session.

## Current operation and safety

`send -- <text>` sends literal, unsubmitted input, and the caller sends Enter separately.
Keys map to Rex names (`enter`, `escape`, `tab`, `ctrl+c`, `ctrl+u`); any other key is refused rather than guessed.
Verified submit types the payload once, retries only Enter through the shared composer classifier, and converts still-pending text to success only when the shared queued-Enter policy accepts the trusted native busy state or rendered busy footer.

`capture --trim` returns the scrollback plus the screen as plain text, and the adapter trims the tail locally.
Rex has no viewport-only capture, so the visible viewport is derived from one styled read through the `format` block method (`vt` with `extra_cursor`), which returns the scrollback plus the full screen grid, blank rows included, and then the cursor position as a trailing `ESC[<row>;<col>H`.
The vt grid joins rows with CRLF, so an empty bottom row leaves the content ending in CRLF with that row implicit; the adapter restores it and takes the last `size.rows` rows as the viewport.
A full-screen program's grid is the screen alone, so the derivation holds on both screens; a resize landing between the size read and the grid read can skew it by the size difference.
The composer classifier reads that styled viewport with styling, row count, process identity, and the cursor row available, the same evidence tmux gives it: the shape holding the cursor is the composer, so furniture a harness draws below its composer cannot decide the verdict.
Where that cursor-anchored read is `unknown`, as for a harness that parks its cursor outside its composer, the cursorless read that takes the bottom-most shape decides instead.

The `process` block method reports the foreground process with its cwd, its ancestors, and the last exit.
Spawn's worktree discovery reads the foreground cwd, which follows the nested subshell `treehouse get` opens.
Agent state is recovery-grade: a verified harness anywhere in the foreground process or its ancestors reads `alive`, a shell foreground with no harness above it reads `dead`, an exited terminal child reads `dead`, anything else reads `ambiguous`, a structured not-found reads `missing`, and an unreachable server reads `unreadable`.
Passive reads never start a server.

Rex records Program Status Protocol (OSC 7501) reports per block; [worker-tool verification](verification/runtime-backends.md#worker-tools-on-rex) owns the versioned reporting coverage.
A record counts only while the process that reported it is the foreground process or one of its ancestors, because without shell integration a `working` record outlives the command that reported it.
That native state is positive busy evidence only, exactly like Herdr's, so the harness's own lifecycle stays the busy authority.

## Push events

While the watcher waits between polls, a Rex home runs one bounded `rex do` reader ([`bin/backends/rex-eventwait.lua`](../bin/backends/rex-eventwait.lua)) on the session holding its task tabs, listening only to those tasks' blocks.
The reader subscribes first and the current program status of each block is reconciled after, so a block that went `blocked` between waits is reported once and an edge during the reconcile is not lost.
A trusted `blocked` program status takes the immediate escalation path instead of waiting for the stale-pane timer; [push verification](verification/runtime-backends.md#push-events) records measured latency.
It counts only when the process that reported it passes the same foreground-chain rule as native busy state, and its wake reason carries Rex's blocked kind (`permission`, `question`, or `auth`) and the program's message, cut at 160 characters.
[`bin/fm-transition-lib.sh`](../bin/fm-transition-lib.sh) owns the shared policy and per-block escalation dedupe contract.
The watcher skips secondmate endpoints, declared waits, and captain-held work exactly as it does for Herdr's push path.

When a watched block's program exits or the block closes, the wait ends at once so the watcher's next poll reconciles that task immediately.
That never wakes the supervisor by itself, because a routine cleanup closes blocks too.

The push path only shortens latency, and polling stays the fallback.
Supervision polls when the CLI or server is below API revision 5 or unreachable (the reader never starts a server), when the reader cannot start or ends before its deadline, and after the watcher's consecutive-reader-failure threshold is reached (three by default).
Task tabs in a second Rex session stay on polling, because one reader covers one session.

## Cleanup and the absence proof

Cleanup closes only the task's block, which closes its tab, and then proves it gone: only an exact not-found after the close counts, so a close that failed or left the block alive keeps the task's records.
An already-gone block counts as closed.
A per-home session left with no tabs is then killed, but only the exact recorded session carrying this home's label, never the launcher session, and never when its view cannot be read.
An omitted `windows` field is treated as an empty session for both retirement and adoption, so a crewless secondmate can relaunch into its emptied session.
When main retires a local secondmate, it checks and retires that secondmate's session using the secondmate home's identity; sessions with tabs or renamed labels are preserved.
Spawning, reclaiming, and that retirement share one home-wide lock (`state/.rex-session.lock`), so a new tab can never land in a session between its empty check and its kill.

`bin/fm-control.sh` `exit` and `relaunch` work on Rex; [`agent-control.md`](agent-control.md#reclaiming-a-task-whose-endpoint-is-gone) owns the recorded-server absence proof, stopped-server recovery, reclaim placement, and reclaim-only shell-husk cleanup.
An ordinary spawn refuses any block carrying the task's scoped label.

## Attention marks

Opt-in: with `config/rex-status-marks` set to `on`, the captain sees which worker needs them from Rex itself.
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

Each record's title is the task's tab label, `fm-<id>`, so Rex labels it with the name Firstmate gave the tab rather than a branch or the agent's terminal title.
Each new record that needs the captain also carries an OSC 777 desktop notification titled with the tab label, because Rex sounds and notifications follow each pane's root program status, not a child record.
Firstmate never writes the root record: the harness owns it, and a second root report for the same turn makes Rex notify twice.
Firstmate's own records never count as the worker's state, for busy detection or for push escalation.
The notification fires once per change, never on a repeated sync.
Rex has no API to set a record, so the mark is one small write to the pane's terminal device; a `working` or `blocked` record is dropped when the agent's shell prints its next prompt or exits, and the next sync writes it again.
The watcher runs `fm-rex-marks.sh sync` once per poll only while `config/rex-status-marks` or `config/rex-tint` exists or a cached record remains, and cleanup clears a cached mark before closing the pane.
Every write addresses the task's recorded block id, so a mark never lands on another pane.

`config/rex-status-marks` turns the marks `on` or `off` (the default when the file is absent, so a home that never creates it sees no change); turning them off clears every mark and progress record already shown.
`state/.rex-mark-<id>` caches the last mark so a sync writes only on change.

### Validation progress

While marks are on and a ship validates through no-mistakes with no mark, its pane carries a second record, `id=fm/validate` in state `working`, whose progress is the share of pipeline steps done and whose message names the active step, for example `Validating: review 3/9, auto-fix 1/3`.
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

## Away mode

A Rex-hosted Firstmate can run away and quiet supervision: the supervisor target is discovered from `REX_SESSION` and `REX_BLOCK`, and the away daemon runs in its own dedicated Rex session, never as a tab or split in yours, which `/afk` exit kills by its exact recorded id.
Naming `rex` in `config/wedge-alarm` adds an opt-in wedge alarm on Firstmate's own pane: a blocked `id=fm-wedge` record plus a desktop notification, removed after the next delivered digest; `auto` never adds it.

## Active limits

- Rex is experimental and in beta, and the adapter refuses a CLI or server below API revision 5.
- Sessions do not survive a Rex server stop; recovery proves such tasks gone and reclaims them into fresh tabs.
- The viewport is derived, not read directly, as described above.
- Only harnesses that report OSC 7501 contribute native busy evidence; the others are classified from their own lifecycle and rendered footer.
- Command Code is refused on Rex until it is live-verified there, and Cursor Agent is not yet live-verified on Rex.
- There is no Rex CI lane; see "Regression entry points" below for real-Rex validation.

## Deferred upstream asks

These asks to Superlogical are deliberately unfiled, pending a later decision; each line names the Firstmate impact that would go away.

- **Viewport-only capture**: the viewport would be read directly instead of derived from the last `size.rows` rows of a full capture, removing the resize skew.
- **Cursor position as a JSON field**: the adapter would stop parsing the cursor out of the trailing escape sequence of the `format` read.
- **Dropping `working` and `blocked` program-status records when their owner exits**: native busy state could be trusted without cross-checking every record against the live process view.
- **A documented compatibility floor and machine-readable version output with the API revision**: the version gate would stop parsing `rex version` text.
- **A per-session or per-block opt-out for the agent hook's automatic session rename**: a harness running in a task tab could not rename the session that holds the captain's or other tasks' tabs.
- **A configurable default size for unviewed blocks**: spawn would no longer need to resize every new 80x24 task block to 200x50.
- **`rex` on `PATH` inside blocks even when shell startup files reset it**: the adapter could drop its `REX_BIN_DIR` and server-bundle fallbacks.

## Regression entry points

```sh
tests/fm-backend-rex.test.sh
tests/fm-backend-rex-smoke.test.sh
tests/fm-backend-rex-eventwait-smoke.test.sh
FM_REX_COMPOSER_LIVE=1 tests/fm-backend-rex-composer-live-e2e.test.sh
```

[`tests/rex-test-safety.sh`](../tests/rex-test-safety.sh) owns private-server isolation, cleanup, capability skips, and startup-failure handling for the real-Rex suites.
The smoke test also stops and restarts its private server to verify passive reads and session-loss reclaim behavior.
[`verification/runtime-backends.md`](verification/runtime-backends.md#rex) records the live evidence.
