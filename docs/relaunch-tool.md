# On-demand session resume (`bin/fm-relaunch.sh`)

Firstmate's own supervision session is normally reachable only by manually opening a terminal and running `claude`.
`bin/fm-relaunch.sh` gives a captain a one-command way to resume it later, without any risk of that resume happening on its own.

## Why a launchd LaunchAgent with no trigger

The tool registers a macOS `launchd` `LaunchAgent` job whose plist declares no `RunAtLoad`, `StartInterval`, `StartCalendarInterval`, or watch-path key.
A `launchd` agent with none of those keys never starts itself; it only runs when something explicitly asks `launchd` to start it (`launchctl kickstart`/`launchctl start`).
That is the tool's entire safety property: the job exists and can be fired on demand, but nothing - not a timer, not a login event, not a file change - can fire it without an explicit human or human-triggered call.
`bin/fm-relaunch.sh install` never writes those keys under any code path, and `bin/fm-relaunch.sh status` re-checks the installed plist for them on every call as a standing self-check, not just at install time.
`tests/fm-relaunch.test.sh` asserts the generated plist never contains them - a regression there would silently turn this into an auto-scheduler.

## Label and multi-home isolation

The job label is `dev.firstmate.relaunch` for the default (unoverridden) primary home, so a fresh `install` cleanly supersedes a hand-built prototype job of the same name.
A home launched with an explicit `FM_HOME` (for example a secondmate home) gets a distinct label, `dev.firstmate.relaunch.<slug>`, where `<slug>` is a short SHA-256 hash of that `FM_HOME` path.
This keeps multiple firstmate homes on one machine from colliding on a single `launchd` label while still deriving the label deterministically from state the tool already has, with no separate registry to keep in sync.

## What `run` actually does

`bin/fm-relaunch.sh run` calls `launchctl kickstart` on the installed job.
The job's `ProgramArguments` point back at the same script with the internal `fire` action, which is where the actual resume happens:

1. Opens a new Terminal.app window running `claude` in the target home (`cd "$FM_HOME" && exec claude`).
2. Waits briefly for `claude` to boot, then sends a `Return` keystroke via `System Events`. This is a no-op against an empty prompt, but dismisses the one-time "Yes, I trust this folder" dialog `claude` can show in a not-yet-trusted directory - without it, the composer is not usable yet.
3. Sends a short kickoff message ("hi") and `Return`.

Step 3 exists because opening `claude` alone does not trigger its `SessionStart` hook: that only fires once a real first message reaches the composer.
Once that message lands, firstmate's own session-start/recovery flow (`AGENTS.md` section 5, `stuck-crewmate-recovery`) takes over and reconciles any dead or stopped crewmate workers on its own - this tool does not duplicate that logic, it only gets a real session started so that flow can run.

`fire` is invoked only as the launchd job's program, not documented as a normal subcommand a captain runs directly - use `run` (or `install` followed by a manual `launchctl kickstart` if the tool is unavailable) to trigger it through the safety-checked path.

## Terminal support

Only Terminal.app is driven today, via `osascript`/`System Events`, matching the original hand-built prototype.
iTerm2 is not detected or driven; a captain who primarily uses iTerm2 can still use this tool, but the resumed session opens in a new Terminal.app window regardless of which terminal app was frontmost.

## Idempotency

`install` compares the freshly generated plist bytes against what is already on disk and skips the reload when they match and the job is already loaded, so running it repeatedly converges to one installed, loaded job with no duplicate plists and no `launchd` errors.
When the plist needs to change (for example after an `FM_HOME` change) or the job was not loaded, `install` unloads the previous copy (if any) before installing the new one.

## Superseding the hand-built prototype

An earlier prototype was built directly on the captain's machine outside this repo: a `~/Library/LaunchAgents/dev.firstmate.relaunch.plist` loaded into `launchd` with no auto-trigger key, plus a private payload script.
Neither file is tracked here - the LaunchAgent lives outside any repo and the payload script lived under a firstmate home's gitignored `config/`.
Because this tool's default label is the same `dev.firstmate.relaunch`, running `bin/fm-relaunch.sh install` on that machine detects the existing loaded job under that label, unloads it, and installs this tool's plist in its place - no manual removal step is required first.
The prototype's private payload script itself is left in place on disk (this tool does not touch files it did not create) and becomes dead weight once superseded; a captain who wants it gone can remove it by hand.

## Commands

See `bin/fm-relaunch.sh --help` for the exact subcommand list and flags; that header is the mechanics' one owner.
