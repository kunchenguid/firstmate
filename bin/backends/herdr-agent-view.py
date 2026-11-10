#!/usr/bin/env python3
"""Set or clear Firstmate's project-group agent view on a Herdr control socket.

This helper is the wire transport for Firstmate's opt-in Herdr project groups
(docs/herdr-backend.md "Project groups"). It sends only ``agent.view.set``
with one fixed, display-only sort, or ``agent.view.clear`` for the same fixed
source, and prints the verified JSON response. Herdr exposes no CLI
subcommand for either method.

Wire protocol from the bundled Herdr 0.9.3 schema, protocol 22:

  request:  {"id":"fm-agent-view","method":"agent.view.set",
             "params":{"source":"firstmate","label":"projects",
                       "sort":[{"field":{"token":"fm_sort"}},
                               {"field":"workspace_order"}]}}\n
  request:  {"id":"fm-agent-view","method":"agent.view.clear",
             "params":{"source":"firstmate"}}\n
  response: {"id":"fm-agent-view","result":{"type":"agent_view",...}}\n
            or {"id":"fm-agent-view","result":{"type":"ok"}}\n

Usage: herdr-agent-view.py <socket_path> set|clear

Exit status:
  0  the server returned a matching success response;
  2  arguments or socket connection were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.
"""

import json
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 1024 * 1024
REQUEST_ID = "fm-agent-view"
SOURCE = "firstmate"
LABEL = "projects"
SORT = [{"field": {"token": "fm_sort"}}, {"field": "workspace_order"}]


def _read_line(sock, deadline):
    buffer = b""
    while b"\n" not in buffer:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except (OSError, socket.timeout):
            return None
        if not chunk:
            return None
        buffer += chunk
        if len(buffer) > MAX_RESPONSE_BYTES:
            return None
    return buffer.split(b"\n", 1)[0]


def main(argv):
    if len(argv) != 3:
        return 2
    socket_path, action = argv[1:]
    if not socket_path.startswith("/"):
        return 2
    if action == "set":
        request = {
            "id": REQUEST_ID,
            "method": "agent.view.set",
            "params": {"source": SOURCE, "label": LABEL, "sort": SORT},
        }
    elif action == "clear":
        request = {
            "id": REQUEST_ID,
            "method": "agent.view.clear",
            "params": {"source": SOURCE},
        }
    else:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        return 2

    try:
        sock.sendall(
            (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
        )
    except OSError:
        return 3

    line = _read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    if not isinstance(response, dict):
        return 4
    result = response.get("result")
    if (
        response.get("id") != REQUEST_ID
        or response.get("error") is not None
        or not isinstance(result, dict)
        or result.get("type") not in ("agent_view", "ok")
    ):
        return 4
    if action == "set" and result.get("type") == "agent_view":
        if result.get("active") is not True:
            return 4
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
