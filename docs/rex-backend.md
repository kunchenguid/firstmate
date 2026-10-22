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
Rex has no viewport-only capture, so the visible viewport is derived from the styled `--format=vt` capture, which always ends with the full screen grid, blank rows included.
The vt format joins rows with CRLF and adds a final newline only when the output does not already end in one, so an empty bottom row leaves the output ending in CRLF with that row implicit; the adapter restores it and takes the last `size.rows` rows as the viewport.
A full-screen program's capture is the screen alone, so the derivation holds on both screens; a resize landing between the size read and the capture can skew it by the size difference.
The composer classifier reads that styled viewport with styling, row count, and process identity available, and without a cursor position.

The `process` block method reports the foreground process with its cwd, its ancestors, and the last exit.
Spawn's worktree discovery reads the foreground cwd, which follows the nested subshell `treehouse get` opens.
Agent state is recovery-grade: a verified harness anywhere in the foreground process or its ancestors reads `alive`, a shell foreground with no harness above it reads `dead`, an exited terminal child reads `dead`, anything else reads `ambiguous`, a structured not-found reads `missing`, and an unreachable server reads `unreadable`.
Passive reads never start a server.

Rex records Program Status Protocol (OSC 7501) reports per block, and Claude Code and Grok report `working`, `idle`, and `done` there today.
A record counts only while the process that reported it is the foreground process or one of its ancestors, because without shell integration a `working` record outlives the command that reported it.
That native state is positive busy evidence only, exactly like Herdr's, so the harness's own lifecycle stays the busy authority.

## Cleanup and the absence proof

Cleanup closes only the task's block, which closes its tab, and then proves it gone: only an exact not-found after the close counts, so a close that failed or left the block alive keeps the task's records.
An already-gone block counts as closed.
A per-home session left with no tabs is then killed, but only a session carrying this home's label, never Firstmate's own launcher session, and never when its view cannot be read.
Spawning, reclaiming, and that retirement share one home-wide lock (`state/.rex-session.lock`), so a new tab can never land in a session between its empty check and its kill.

`bin/fm-control.sh` `exit` and `relaunch` work on Rex; [`agent-control.md`](agent-control.md#reclaiming-a-task-whose-endpoint-is-gone) owns the recorded-server absence proof, stopped-server recovery, reclaim placement, and reclaim-only shell-husk cleanup.
An ordinary spawn refuses any block carrying the task's scoped label.

## Away mode

A Rex-hosted Firstmate can run away and quiet supervision: the supervisor target is discovered from `REX_SESSION` and `REX_BLOCK`, and the away daemon runs in its own dedicated Rex session, never as a tab or split in yours, which `/afk` exit kills by its exact recorded id.

## Active limits

- Rex is experimental and in beta, and the adapter refuses a CLI or server below API revision 5.
- Sessions do not survive a Rex server stop; recovery proves such tasks gone and reclaims them into fresh tabs.
- The viewport is derived, not read directly, as described above.
- Only harnesses that report OSC 7501 contribute native busy evidence; the others are classified from their own lifecycle and rendered footer.
- Command Code is refused on Rex until it is live-verified there.
- Push events are not wired yet, so supervision polls Rex like a backend without a push stream.
- There is no Rex CI lane; the real-server tests run where a Rex server is already up.

## Deferred upstream asks

These asks to Superlogical are deliberately unfiled, pending a later decision; each line names the Firstmate impact that would go away.

- **Viewport-only capture**: the viewport would be read directly instead of derived from the last `size.rows` rows of a full capture, removing the resize skew.
- **Cursor position as a JSON field**: the composer classifier would gain the cursor evidence it currently runs without.
- **Dropping `working` and `blocked` program-status records when their owner exits**: native busy state could be trusted without cross-checking every record against the live process view.
- **A documented compatibility floor and machine-readable version output with the API revision**: the version gate would stop parsing `rex version` text.
- **A per-session or per-block opt-out for the agent hook's automatic session rename**: a harness running in a task tab could not rename the session that holds the captain's or other tasks' tabs.
- **A configurable default size for unviewed blocks**: spawn would no longer need to resize every new 80x24 task block to 200x50.
- **`rex` on `PATH` inside blocks even when shell startup files reset it**: the adapter could drop its `REX_BIN_DIR` and server-bundle fallbacks.

## Regression entry points

```sh
tests/fm-backend-rex.test.sh
tests/fm-backend-rex-smoke.test.sh
```

The smoke test runs only against an already-running server, works only in an `fm-test-` session it creates and kills by exact id, refuses through a forwarding guard any state-changing call outside that session, and checks that every other session is byte-identical before and after.
[`verification/runtime-backends.md`](verification/runtime-backends.md#rex) records the live evidence.
