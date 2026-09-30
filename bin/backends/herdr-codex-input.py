#!/usr/bin/env python3
"""Insert program text into a verified foreground Codex without submitting it.

Usage: herdr-codex-input.py <session> <pane> (UTF-8 text on stdin)
Only pane.send_input with an empty keys array is writable. Herdr's native
encoder checks this pane's live bracketed-paste mode before adding framing;
Firstmate never infers mode enablement from a version, title, or registration.
The caller retains its ordinary single external Enter and composer guard.
The socket comes from the exact named-session status, not an ambient endpoint.
Exit 10 means not applicable (no verified Codex); other errors must not fall
back to raw text after a request might have been written.
"""

import json
import os
import socket
import subprocess
import sys
import time


NOT_APPLICABLE = 10
TIMEOUT = 5.0
MAX_RESPONSE = 4 * 1024 * 1024


def cli(session, *args):
    binary = "herdr"
    if os.environ.get("FM_BACKEND_HERDR_CLIENT_SESSION") == session:
        binary = os.environ.get("FM_BACKEND_HERDR_BIN", "herdr")
    result = subprocess.run(
        [binary, *args, "--session", session], capture_output=True, timeout=TIMEOUT
    )
    if result.returncode:
        raise ValueError("Herdr probe failed")
    return json.loads(result.stdout)


def codex_process(process):
    argv = process.get("argv")
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        return False
    # Noninteractive Codex subcommands do not own a composer.
    if any(a in ("exec", "app-server", "mcp-server", "completion", "login", "logout") for a in argv[1:]):
        return False
    name = os.path.basename(process.get("name", ""))
    argv0 = os.path.basename(argv[0])
    identity = name == "codex" or argv0 == "codex" or "codex" in argv[0].split("/")
    pid = process.get("pid")
    return identity and isinstance(pid, int) and not isinstance(pid, bool) and pid > 1


def supported(schema):
    request = schema.get("schemas", {}).get("request", {})
    params = request.get("$defs", {}).get("PaneSendInputParams", {})
    properties = params.get("properties", {})
    return (
        any(item.get("properties", {}).get("method", {}).get("const") == "pane.send_input"
            and item.get("properties", {}).get("params", {}).get("$ref") == "#/schemas/request/$defs/PaneSendInputParams"
            for item in request.get("oneOf", []))
        and "pane_id" in params.get("required", [])
        and set(params.get("required", [])) <= {"pane_id", "text", "keys"}
        and properties.get("pane_id", {}).get("type") == "string"
        and properties.get("text", {}).get("type") == "string"
        and properties.get("keys", {}).get("type") == "array"
        and properties.get("keys", {}).get("items", {}).get("type") == "string"
    )


def insert(socket_path, pane, text):
    request = {"id": "fm-codex-input", "method": "pane.send_input",
               "params": {"pane_id": pane, "text": text, "keys": []}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(TIMEOUT)
        sock.connect(socket_path)
        sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
        deadline = time.monotonic() + TIMEOUT
        data = b""
        while b"\n" not in data:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or len(data) > MAX_RESPONSE:
                raise ValueError("Herdr input response exceeded its bound")
            sock.settimeout(remaining)
            chunk = sock.recv(65536)
            if not chunk:
                raise ValueError("Herdr input response ended early")
            data += chunk
            if len(data) > MAX_RESPONSE:
                raise ValueError("Herdr input response exceeded its bound")
        response = json.loads(data.split(b"\n", 1)[0])
        if (not isinstance(response, dict) or response.get("id") != request["id"] or response.get("error") is not None
                or response.get("result", {}).get("type") != "ok"):
            raise ValueError("Herdr input response was not confirmed")


def main():
    if len(sys.argv) != 3:
        return 2
    session, pane = sys.argv[1:]
    if not session or not pane or any(c in session + pane for c in "\r\n\t"):
        return 2
    status = cli(session, "status", "--json")
    server = status.get("server", {})
    # Older transports without a named socket cannot establish applicability.
    if not server.get("socket"):
        return NOT_APPLICABLE
    if (server.get("session") != session or server.get("running") is not True
            or not isinstance(server["socket"], str) or not os.path.isabs(server["socket"])):
        raise ValueError("Herdr named-session socket identity is ambiguous")
    info = cli(session, "pane", "process-info", "--pane", pane).get("result", {})
    processes = info.get("process_info", {})
    if info.get("type") != "pane_process_info" or processes.get("pane_id") != pane:
        raise ValueError("Herdr foreground process identity is ambiguous")
    foreground = processes.get("foreground_processes")
    if not isinstance(foreground, list):
        raise ValueError("Herdr foreground process list is unavailable")
    if not any(codex_process(p) for p in foreground):
        return NOT_APPLICABLE
    if not supported(cli(session, "api", "schema", "--json")):
        raise ValueError("Herdr lacks capability-gated Codex input")
    text = sys.stdin.read()
    # A literal terminator would escape the native paste boundary.
    if "\x1b[201~" in text or "\x1b[200~" in text:
        raise ValueError("program input contains a bracketed-paste delimiter")
    insert(server["socket"], pane, text)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Herdr Codex input refused: {error}", file=sys.stderr)
        sys.exit(1)
