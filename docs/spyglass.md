# Spyglass

Spyglass is Firstmate's read-only live fleet view for Claude Code.
This page is for operators who turn Spyglass on and need to know what it shows, where its data comes from, and what it never does.

## Harness support and default

Spyglass is a Claude Code mod, available behind that harness's default-off early-access function-hooks flag.
No other harness has it.
Spyglass never changes anything: it reads the fleet and shows it.

## Enabling function hooks

Claude Code's early-access function-hooks surface is off by default.
Claude Code can load modules through its rollout flag, or per session with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`.
The mod independently requires that environment variable to equal `1` before doing anything.
Firstmate never sets that flag in any project or user settings.
Enabling it is each captain's own explicit opt-in.

Without that exact value, the mod is a complete no-op, even if Claude Code's rollout flag loads the module:

- There is no `/fleet` command and no pane.
- The mod runs no process, reads no file, and starts no timer.
- No status line, toast, or update check appears.

The mod also stays silent outside a Firstmate home.
It looks for `bin/fm-fleet-snapshot.sh` under the Firstmate checkout it ships in and for the effective Firstmate home, and does nothing when either is missing.

## Which home it shows

Spyglass resolves the checkout and home the way the `bin/` scripts and [Calm](calm.md) do.
The checkout is `FM_ROOT_OVERRIDE`, else the checkout the mod folder sits in, and it supplies the scripts.
The home is `FM_HOME`, else `FM_ROOT_OVERRIDE`, else that checkout, and it supplies the fleet and each worker's state directory (`FM_STATE_OVERRIDE` overrides the state directory).
Every script runs with `FM_HOME` set to that home, so a second mate's home shows that home's own fleet.

## What it shows

### Status line

While the mod is on, the status line summarizes the fleet in one row, for example `⚓ 3 under way · 1 signal · 2 PRs ready · ⬆ update`.
Each part appears only when it is nonzero: workers under way, decisions waiting on the captain, PRs ready, and a Firstmate update available.
A PR counts as ready only once its worker reports done; a PR link from a worker still under way is not a signal.
The row is cleared when there is nothing to say, and reads `⚓ fleet unreadable` when the snapshot fails.
The fleet refreshes every 15 seconds and after every turn.

### The /fleet pane

Spyglass opens its pane at session start, and `/fleet` reopens it with focus and refreshes it.
The pane uses a navy theme.
Its banner shows the ship's watch (by local hour) and when the fleet last changed.
Below it are three numbered, separated sections:

| Section | Contents |
| --- | --- |
| Signals for the Captain | Ready PRs with a link, then captain holds with their reasons. |
| Under Way | Each worker with its kind, project, and state, its model and effort when its task record names them, and a View session button. |
| At Anchor | Queued work that is not waiting on the captain. |

The pane writes only when the fleet actually changed, because every write redraws the pane and a press that lands mid-redraw is lost.

### Worker session pane

View session opens a second pane with the live tail of that worker's terminal, checked every 3 seconds.
The pane shows only the newest lines of the 80-line capture that fit the terminal, so the live end stays on screen.
Its buttons:

- Refresh captures the tail now.
- Open in terminal opens the worker's tmux window in Ghostty when it is installed, else in Terminal.app on macOS.
- Copy attach command copies `tmux attach -t <target>`.
- Close closes the pane.

Both attach buttons appear only for a local tmux worker; a worker on another backend or a remote secondmate shows Refresh and Close alone.

On the desktop app, a click on View session in an unfocused fleet pane only moves the keyboard there.
Spyglass treats the keyboard landing on View session from outside the fleet pane (from the session pane, not from the chat box) as the press and opens that worker's session.
A click that arrives from the chat box cannot be attributed, so it still needs a second click.

Open in terminal refuses a worker target that is not a plain tmux target, so a hostile name cannot reach the launcher.
The capture is cleaned before display: terminal escape sequences and control characters are dropped, and the newest 10000 characters stay.

### Toasts

A toast announces new signals for the captain, meaning a PR or captain hold that was not in the previous read.
The first read of a session announces nothing.

### Firstmate update flag

Spyglass compares this checkout with origin's default branch, the branch the update fast-forwards, without fetching into it, once at session start, every 10 minutes, on `/fleet`, and after a turn while an update is running.
Only one check runs at a time, and the status line follows its result as soon as it finishes.
A checkout on any other branch, or on a detached HEAD, shows no flag, because the update would skip it.
The flag appears only when origin is ahead, and then shows:

- how many commits behind the checkout is;
- a warning when a locally edited tracked file is also changed by the incoming commits, which would block a fast-forward, or a plain note naming local edits the update does not touch;
- an Update Firstmate button, which shows queued, then updating, then done states.
  If the first mate's update turn ends with the checkout still behind, the button comes back so the captain can retry.

While origin is not ahead the banner shows a small up-to-date line and a Check for updates control.
The flag clears as soon as the local checkout reaches the commit it was behind.

The upstream repository comes from the checkout's `origin` remote when that remote is on GitHub, so a fork compares against itself.
Spyglass skips the update flag and its control entirely when `origin` is not a GitHub remote, or when `gh` is not installed.

## Data sources

| Data | Source |
| --- | --- |
| Workers, ready PRs, captain holds, queued work | `bin/fm-fleet-snapshot.sh --json` |
| A worker's model and effort | `model=` and `effort=` lines of `state/<id>.meta` |
| A worker's live terminal tail | `bin/fm-peek.sh <id> 80` |
| Commits behind and incoming files | `git ls-remote --symref origin HEAD`, `git symbolic-ref HEAD`, `git rev-parse HEAD`, `git diff --name-only -z HEAD`, and the GitHub compare API through `gh api` |

## Read-only boundary

Spyglass never runs a mutating `fm-*` script, never writes a file, and never sends text to a worker.
The scripts it runs are `bin/fm-fleet-snapshot.sh` and `bin/fm-peek.sh`, plus read-only git and `gh api` calls and, only on request, a terminal launcher that attaches to a worker's tmux window.
The one action that reaches the first mate is the Update Firstmate button.
It submits the captain's own words, `update firstmate`, as the user, so the first mate runs its normal update when it is next free.
That prompt waits for the first mate to be idle, which can take minutes, so the button reports queued at once.
The button stays pressable while queued, so a queued prompt that was lost, for example pulled back by an interrupt, can be sent again.

## Claude Code support bounds

- The function-hooks surface is early access and default-off.
  Claude Code states that its API may change between releases without notice.
- The terminal launcher is macOS-specific: it uses `open` for Ghostty and `osascript` for Terminal.app, and reports a toast when neither works.
- The mod only reads the fleet through the snapshot, so a home whose snapshot fails shows the failure instead of stale data.

## Files

- `.claude/mods/firstmate-spyglass/hooks/register.tsx` owns the engine glue, the panes, and the timers.
- `.claude/mods/firstmate-spyglass/lib/fm-spyglass.ts` owns the pure policy: home resolution, snapshot trimming, the summary, the update comparison, and the capture sanitizer.
- `.claude/mods/firstmate-spyglass/lib/fm-spyglass-types.d.ts` owns the plugin state contract Claude Code validates.
- `.agents/skills/firstmate-spyglass` is the symlink through which Claude Code adopts the mod, as for Calm.

## Claude Code regression entry points

```sh
tests/fm-spyglass-claude-mod.test.sh
tests/fm-spyglass-claude-mod-plugin.test.sh
```
