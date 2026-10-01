#!/usr/bin/env python3
"""fm-mcp.py - a local stdio MCP server that lets an MCP client talk to firstmate.

Claude Desktop (chat, Cowork, and Code) and Claude Code launch this as a local
stdio server. It wraps firstmate's own scripts and published files and nothing
else: no network listener, no credentials, and no direct writes to firstmate's
files. It never spawns, steers, merges, tears down, or edits backlog or state.
Every action request becomes an inbox note (fm-inbox.sh note), and firstmate's
own rules decide what happens next. Each such note's body starts with the line
"[via firstmate MCP from <client> <version>]", naming the client from its
initialize handshake (or "unknown client"), so firstmate can tell it from a note
the captain typed and tell Claude Desktop from Claude Code. The client's
request_id is stored prefixed with a short hash of the client name (not its
version), so two clients reusing one request_id get separate notes; the caller
sees its own id, from both firstmate_send_note and firstmate_note_replies.

Usage:
  fm-mcp.py            serve MCP over stdin/stdout (newline-delimited JSON-RPC)

Tools:
  firstmate_send_note      fm-inbox.sh note --request-id <client-hash>-<id> --json -  (the only write)
  firstmate_note_replies   fm-inbox.sh receipts [--after <cursor>]
  firstmate_status         fm-inbox.sh status + fm-inbox.sh ready
  firstmate_home_summary   state/home-summary.json
  firstmate_backlog_list   fm-tasks-axi.sh list
  firstmate_backlog_show   fm-tasks-axi.sh show <id> --full
  firstmate_crew_state     fm-crew-state.sh <id>
  firstmate_crew_report    data/<id>/report.md (never through a symlink)

Environment:
  FM_HOME  firstmate's operational home (default: this script's repo root,
           the same default every bin/ script uses). Scripts always come from
           this script's own bin/ directory.
  PATH     must reach what those scripts need (tasks-axi, python3, git, and the
           runtime backend's CLI); a desktop app does not inherit a shell PATH.

Only the standard library is used, so any python3 a firstmate home already
needs can run it. docs/mcp.md owns client setup.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).resolve().parent
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
REQUEST_ID = re.compile(r"[A-Za-z0-9._:-]{1,119}")
TIMEOUT = 60
MARKER = "[via firstmate MCP from {client}]"
# The client named in initialize's clientInfo, so firstmate can tell Claude Desktop
# ("claude-ai") from Claude Code. Client-supplied, so it is flattened and capped.
CLIENT = "unknown client"
PREFIX = hashlib.sha256(b"").hexdigest()[:8] + "-"
REPLIES = 20

INSTRUCTIONS = (
    "Talk to firstmate, the supervising agent that runs the captain's fleet of coding agents."
    " firstmate_send_note is the only way to ask for work or action; it wakes firstmate, whose"
    " own rules decide what to do. Replies arrive asynchronously: check them with"
    " firstmate_note_replies. Every other tool is a read-only view of fleet state."
)
NOTE_ONLY = (
    "\n\nRead-only: this tool never spawns, steers, merges, tears down, or edits backlog or state;"
    " to ask for any of that, send firstmate a note with firstmate_send_note."
)


class ToolError(Exception):
    pass


class InvalidParams(Exception):
    pass


def home():
    path = Path(os.environ.get("FM_HOME") or BIN.parent).expanduser()
    if not path.is_dir():
        raise ToolError(f"FM_HOME is not a directory: {path}")
    return path


def run(script, *args, stdin=None):
    fm_home = home()
    try:
        proc = subprocess.run(
            [str(BIN / script), *args],
            input=stdin,
            capture_output=True,
            text=True,
            cwd=fm_home,
            env={**os.environ, "FM_HOME": str(fm_home)},
            timeout=TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ToolError(f"{script} did not run: {exc}") from exc
    if proc.returncode != 0:
        raise ToolError(f"{script} {args[0] if args else ''} exited {proc.returncode}\n{proc.stdout}{proc.stderr}".strip())
    return proc.stdout


def valid_id(value):
    if not TASK_ID.fullmatch(value) or ".." in value:
        raise ToolError(f"invalid task id: {value!r}")
    return value


def send_note(message, request_id):
    if not message.strip():
        raise ToolError("message is empty")
    if not REQUEST_ID.fullmatch(request_id):
        raise ToolError(f"invalid request_id: {request_id!r} (1-119 of A-Za-z0-9._:-)")
    note = json.loads(run("fm-inbox.sh", "note", "--request-id", PREFIX + request_id, "--json", "-",
                          stdin=MARKER.format(client=CLIENT) + "\n" + message))
    note["request_id"] = request_id
    return json.dumps(note)


def note_replies(note_id=None, after=None):
    if note_id is None:
        # No cursor: start REPLIES below the durable reply sequence, so the
        # script serializes only the newest page instead of the whole history.
        # ponytail: a note replied to twice leaves a sequence gap, so this page
        # can hold fewer than REPLIES; the older ones stay reachable by note_id.
        cursor = after or newest_page_cursor()
        receipts = json.loads(run("fm-inbox.sh", "receipts", *(["--after", cursor] if cursor else [])))
        for entry in receipts["omitted"]:
            if entry["reveal"] == "pass --all-replies":
                entry["reveal"] = "call again with after set to reply_cursor"
            elif entry["reveal"].startswith("pass --all-"):
                entry["reveal"] = "pass note_id to read one note"
        if cursor and not after:
            receipts["omitted"].append({"surface": "older replies omitted",
                                        "reveal": "pass note_id to read one note's reply"})
        return json.dumps(own_request_ids(receipts))
    receipts = own_request_ids(json.loads(run("fm-inbox.sh", "receipts", "--all-pending", "--all-handled")))
    for note in receipts["pending"] + receipts["handled"]:
        if note["id"] == note_id:
            return json.dumps(note)
    raise ToolError(f"no note with id {note_id!r}")


def own_request_ids(receipts):
    for note in receipts["pending"] + receipts["handled"]:
        if (note.get("request_id") or "").startswith(PREFIX):
            note["request_id"] = note["request_id"][len(PREFIX):]
    return receipts


def newest_page_cursor():
    try:
        seq = int((home() / "state" / "inbox" / ".replies" / ".seq").read_text().strip())
    except (OSError, ValueError):
        return None
    return "%012d" % (seq - REPLIES) if seq > REPLIES else None


STALE_LOCK = "firstmate's liveness cannot be proven right now; notes still queue and wake firstmate."


def status():
    ready = run("fm-inbox.sh", "ready")
    try:
        stale = json.loads(ready)["lock"]["state"] == "stale"
    except (ValueError, KeyError, TypeError):
        stale = False
    # A stale lock only means the recorded owner process is gone (for example a
    # resumed session that has not re-taken it), not that firstmate is down.
    return run("fm-inbox.sh", "status") + "\n--- firstmate readiness ---\n" + ready + (STALE_LOCK + "\n" if stale else "")


def home_file(*parts, missing):
    root = home()
    path = root.joinpath(*parts)
    links = [root.joinpath(*parts[:i]) for i in range(1, len(parts) + 1)]
    if any(p.is_symlink() for p in links) or not path.resolve().is_relative_to(root.resolve()):
        raise ToolError(f"refusing a symlinked or out-of-home path: {'/'.join(parts)}")
    if not path.is_file():
        raise ToolError(missing)
    return path.read_text()


def home_summary():
    return home_file("state", "home-summary.json", missing="no home summary published at state/home-summary.json")


def backlog_list():
    return run("fm-tasks-axi.sh", "list")


def backlog_show(task_id):
    return run("fm-tasks-axi.sh", "show", valid_id(task_id), "--full")


def crew_state(task_id):
    return run("fm-crew-state.sh", valid_id(task_id))


def crew_report(task_id):
    return home_file("data", valid_id(task_id), "report.md", missing=f"no report yet for {task_id}")


def param(description):
    return {"type": "string", "description": description}


TASK_PARAM = {"task_id": param("Backlog task / crew id")}

# name -> (handler, description, properties, required, annotations)
TOOLS = {
    "firstmate_send_note": (
        send_note,
        "Send firstmate a message and wake it (fm-inbox.sh note).\n\n"
        f"The queued note's body always starts with the line \"{MARKER.format(client='<client> <version>')}\","
        " naming the MCP client from its initialize handshake, so firstmate can tell it came through"
        " this server, and from which app, rather than from the captain directly.\n"
        "Use this for everything you want firstmate to do or know: questions, new work,"
        " approvals, steering a crew, merges, cancellations. The note is only a request;"
        " this tool itself never spawns, steers, merges, tears down, or edits backlog or state -"
        " firstmate reads the note and its own rules decide what happens.\n"
        "Returns JSON with the note id and request_id. Use a fresh UUID as the request_id for each new"
        " note (other sessions of the same app share this client's request_id space);"
        " if a call fails or times out, retry with the SAME request_id: a repeat returns the"
        " original note instead of a duplicate."
        " Check for firstmate's answer later with firstmate_note_replies(note_id).",
        {"message": param("The note for firstmate"),
         "request_id": param("Idempotency key: a fresh UUID per note (1-119 of A-Za-z0-9._:-); reuse it when retrying the same note")},
        ["message", "request_id"],
        {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True, "openWorldHint": False},
    ),
    "firstmate_note_replies": (
        note_replies,
        "Read firstmate's replies to notes and whether each note is still pending (fm-inbox.sh receipts).\n\n"
        "With note_id: returns that note with acknowledged (firstmate has taken it) and"
        " reply (firstmate's answer, or null while none is recorded yet), so a session"
        " that passes its own note ids sees only the answers to its own notes."
        " Without: returns recent pending and handled notes plus the newest replies (oldest"
        " first); pass the previous reply_cursor as `after` to see only newer replies, paged"
        " oldest first. Each reply names the note id it answers." + NOTE_ONLY,
        {"note_id": param("Note id returned by firstmate_send_note"),
         "after": param("reply_cursor from a previous call")},
        [],
        None,
    ),
    "firstmate_status": (
        status,
        "What is happening now: notes waiting, in-flight backlog items, each crew's last event"
        " (fm-inbox.sh status), and whether firstmate itself is live to receive notes (fm-inbox.sh ready)."
        " A stale lock is reported as liveness that cannot be proven, not as firstmate being down:"
        " notes still queue and wake firstmate."
        " Sends no wake and never interrupts firstmate." + NOTE_ONLY,
        {}, [], None,
    ),
    "firstmate_home_summary": (
        home_summary,
        "firstmate's structured fleet summary (state/home-summary.json): active crews, open"
        " decisions, holds, queue, and whether the summary is currently valid." + NOTE_ONLY,
        {}, [], None,
    ),
    "firstmate_backlog_list": (
        backlog_list,
        "List firstmate's backlog tasks with id, state, kind, repo, and title (fm-tasks-axi.sh list)." + NOTE_ONLY,
        {}, [], None,
    ),
    "firstmate_backlog_show": (
        backlog_show,
        "Show one backlog task in full, including its notes (fm-tasks-axi.sh show <id> --full)." + NOTE_ONLY,
        TASK_PARAM, ["task_id"], None,
    ),
    "firstmate_crew_state": (
        crew_state,
        "A crew's CURRENT state, reconciled from its pipeline run, pane, and status log"
        " (fm-crew-state.sh <id>): working, parked, done, blocked, paused, failed, or unknown." + NOTE_ONLY,
        TASK_PARAM, ["task_id"], None,
    ),
    "firstmate_crew_report": (
        crew_report,
        "A crew's written report (data/<id>/report.md), usually present once the task is done." + NOTE_ONLY,
        TASK_PARAM, ["task_id"], None,
    ),
}
READ_ONLY = {"readOnlyHint": True, "openWorldHint": False}


def tool_list():
    return [
        {
            "name": name,
            "description": desc,
            "inputSchema": {"type": "object", "properties": props, "required": required, "additionalProperties": False},
            "annotations": ann or READ_ONLY,
        }
        for name, (_, desc, props, required, ann) in TOOLS.items()
    ]


def call_tool(params):
    name, args = params.get("name"), params.get("arguments") or {}
    if name not in TOOLS:
        raise InvalidParams(f"unknown tool: {name!r}")
    handler, _, props, required, _ = TOOLS[name]
    try:
        if not isinstance(args, dict) or set(args) - set(props):
            raise ToolError(f"arguments must be an object with only: {', '.join(props) or 'none'}")
        if any(k not in args for k in required) or not all(isinstance(v, str) for v in args.values()):
            raise ToolError(f"required string arguments: {', '.join(required) or 'none'}")
        text, is_error = handler(**args), False
    except ToolError as exc:
        text, is_error = str(exc), True
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def handle(msg):
    global CLIENT, PREFIX
    method, params = msg.get("method"), msg.get("params") or {}
    if method == "initialize":
        info = params.get("clientInfo") if isinstance(params.get("clientInfo"), dict) else {}
        label = " ".join(str(info[k]) for k in ("name", "version") if info.get(k))
        CLIENT = re.sub(r"[^\w .:@/+-]", "", label)[:80].strip() or "unknown client"
        PREFIX = hashlib.sha256(str(info.get("name") or "").encode()).hexdigest()[:8] + "-"
        asked = params.get("protocolVersion")
        return {
            "protocolVersion": asked if asked in PROTOCOLS else PROTOCOLS[0],
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "firstmate", "version": "1"},
            "instructions": INSTRUCTIONS,
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": tool_list()}
    if method == "tools/call":
        return call_tool(params)
    raise NotImplementedError(f"method not found: {method}")


def reply(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        if not isinstance(msg, dict) or "id" not in msg:
            continue  # notifications (initialized, cancelled) need no answer
        out = {"jsonrpc": "2.0", "id": msg["id"]}
        try:
            out["result"] = handle(msg)
        except NotImplementedError as exc:
            out["error"] = {"code": -32601, "message": str(exc)}
        except InvalidParams as exc:
            out["error"] = {"code": -32602, "message": str(exc)}
        except Exception as exc:  # keep serving; one bad request must not drop the session
            out["error"] = {"code": -32603, "message": f"{type(exc).__name__}: {exc}"}
        reply(out)


if __name__ == "__main__":
    main()
