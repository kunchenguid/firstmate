# Claude Code status-line fleet readout

`bin/fm-statusline.sh` renders a compact, color-coded one-line summary of a firstmate home's live tasks, built for embedding in a Claude Code status line.
Its `--help` output owns the exact flags, environment knobs, and wiring snippet; this note covers what the readout shows and the contract it keeps.

## What it shows

The line leads with a summary such as `⚓ 3 crew · 1 needs you`, or `⚓ fleet idle` when nothing is live, with an `· afk` marker while away mode is on.
Each live task then gets one short segment: a symbol, the task's short id (leading `fm-` stripped), a state word, and a hard-truncated note from its newest status event.
Needs-attention segments sort first so they are visible even when the bar truncates.
Idle secondmates are omitted because a quiet persistent secondmate is healthy; a secondmate surfaces only when it finishes work or needs a decision.

## Color legend

- Red bold (`!`): needs-decision, blocked, or failed - something needs the captain.
- Cyan (`✔`): done - finished work awaiting cleanup.
- Yellow (`~`): paused or held - a deliberate external wait.
- Dim green (`·`): working - healthy, deliberately quiet.

Setting `NO_COLOR` drops all ANSI styling.

## Wiring

Claude Code's `statusLine` setting in `~/.claude/settings.json` runs a command that receives session JSON on stdin and prints the bar text:

```json
{
  "statusLine": {
    "type": "command",
    "command": "FM_HOME=$HOME/firstmate $HOME/firstmate/bin/fm-statusline.sh"
  }
}
```

The script drains and ignores stdin, so it works both piped by Claude Code and run bare in a terminal.
To keep an existing status line, compose the two commands and print the fleet segment second; `--help` carries the exact composition recipe.
The script never edits `~/.claude/settings.json` itself - that wiring is user-local configuration.

## Refresh cadence

Claude Code re-runs the configured status-line command itself as the session updates, at most every few hundred milliseconds during activity.
The script therefore does not poll, daemonize, or cache; every invocation is one fresh bounded read.

## Fast and read-only contract

The readout reads durable state only: `state/*.meta` for the task set, a bounded read of each `state/<id>.status`, and the `state/.afk` flag, honoring `FM_HOME` like every other `bin/` script.
Needs-the-captain classification uses `bin/fm-classify-lib.sh`'s keyed open-decision fold, so a later unrelated event never masks a still-open decision; oversized status logs skip the fold and classify from the newest event only.
It makes no network calls, takes no locks, runs no deep current-state reads, and writes nothing anywhere, so a status line can invoke it freely; it targets well under 200ms per run with a typical fleet.
Absent or unreadable state degrades to `⚓ fleet idle` rather than an error, and status text is sanitized to printable characters before display.

## Maintaining this file

Keep this note limited to what the readout shows and the contracts it keeps.
Exact flags, environment knobs, and the wiring recipe live in the script's header and `--help`; update those first and keep this note pointing at them.
