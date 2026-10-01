# MCP server

`bin/fm-mcp.py` is a local stdio [MCP](https://modelcontextprotocol.io) server that lets Claude Desktop or Claude Code talk to a running firstmate.
It wraps firstmate's own scripts and published files and nothing else: no network listener, no credentials, and no direct writes to firstmate's files.
It uses only the Python standard library, so the `python3` a firstmate home already needs can run it.

## Authority boundary

The server never spawns, steers, merges, tears down, or edits backlog or state.
`firstmate_send_note` is its only write: it queues an inbox note through `fm-inbox.sh note` and wakes firstmate, and firstmate's own rules decide what happens next.
Every note it queues starts with the first line `[via firstmate MCP from <client> <version>]`, naming the client from its MCP initialize handshake (or `unknown client`), so firstmate can tell an MCP note from one the captain typed.
Claude Desktop identifies itself as `claude-ai` and Claude Code under its own name, so the two are distinguishable, but Desktop's chat, Cowork, and Code tabs share one client identity.
Each reply names the note id it answers, so a session that passes its own note id to `firstmate_note_replies` sees only the answer to its own note.
Every other tool is a read of status, readiness, receipts, the home summary, the backlog, a crew's current state, or a crew's report.
A home file is never read through a symlink or from outside `FM_HOME`, so a symlinked `data/<id>/report.md` is refused.
The script header lists each tool and the command or file it wraps.

`request_id` is required and chosen by the client, one per note, so a client retrying a failed or timed-out call with the same id still produces exactly one note.
The server stores it prefixed with a short hash of the client name, so Claude Desktop and Claude Code reusing the same id still get separate notes; the response returns the caller's own id unchanged.
Sessions of the same app share one client name, so the tool asks for a fresh UUID per note.
Replies arrive asynchronously through `fm-inbox.sh reply` and are read back with `firstmate_note_replies`; without a `note_id` or `after` cursor it asks `fm-inbox.sh receipts` for only the newest 20 replies (fewer when a re-answered note left a gap in the reply sequence), and each call's `reply_cursor` passed back as `after` returns only newer ones.

## Setup

The server reads `FM_HOME` like every other `bin/` script and defaults to its own repository root.
Desktop apps do not inherit a shell `PATH`, so pass one that reaches `tasks-axi`, `python3`, `git`, and the runtime backend's CLI.

Claude Desktop, under `mcpServers` in `claude_desktop_config.json` (`~/Library/Application Support/Claude/` on macOS), then fully quit and relaunch the app:

```json
"firstmate": {
  "command": "/usr/bin/python3",
  "args": ["/path/to/firstmate/bin/fm-mcp.py"],
  "env": {
    "FM_HOME": "/path/to/firstmate/home",
    "PATH": "/path/to/node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  }
}
```

Claude Code:

```sh
claude mcp add --scope user firstmate \
  -e FM_HOME=/path/to/firstmate/home \
  -e PATH="$PATH" \
  -- python3 /path/to/firstmate/bin/fm-mcp.py
```

Desktop logs each connection to `~/Library/Logs/Claude/mcp-server-firstmate.log`; `claude mcp list` shows whether Claude Code connected.

## Verification

`tests/fm-mcp.test.sh` drives every tool over the real stdio protocol against a temporary home and firstmate's real scripts, and asserts that the note is the only write: the read tools leave the whole home byte-identical.
