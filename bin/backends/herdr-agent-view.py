#!/usr/bin/env python3
"""Install Firstmate's static "Pinned" agent view on one Herdr socket.

This helper is the wire transport for bin/fm-herdr-pins.sh. It sends only the
one fixed request below - no caller-supplied filter, sort, source, or method -
so it can never be used to send anything else to a Herdr server. Re-sending it
replaces the same source's view with identical content, which makes it
idempotent.

Wire protocol from the bundled schema of Herdr 0.9.1, protocol 22
(``herdr api schema --json``: AgentViewSetParams, ResponseResult agent_view):

  request:  {"id":"fm-herdr-pins","method":"agent.view.set",
             "params":{"source":"firstmate:pins","label":"Pinned",
                       "filter":{"op":"exists","field":{"token":"pin_rank"}},
                       "sort":[{"field":{"token":"pin_rank"},"order":"asc"}]}}\n
  response: {"id":"fm-herdr-pins","result":
             {"type":"agent_view","active":true,...}}\n

Usage: herdr-agent-view.py <socket_path>

Exit status:
  0  the server confirmed the view is active;
  2  arguments or socket connection were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error (for
     example a Herdr build without agent views).
"""

import json
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 1024 * 1024
REQUEST_ID = "fm-herdr-pins"
VIEW_SOURCE = "firstmate:pins"
REQUEST = {
    "id": REQUEST_ID,
    "method": "agent.view.set",
    "params": {
        "source": VIEW_SOURCE,
        "label": "Pinned",
        "filter": {"op": "exists", "field": {"token": "pin_rank"}},
        "sort": [{"field": {"token": "pin_rank"}, "order": "asc"}],
    },
}


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
    if len(argv) != 2 or not argv[1].startswith("/"):
        return 2
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(argv[1])
    except OSError:
        return 2
    try:
        sock.sendall(
            (json.dumps(REQUEST, separators=(",", ":")) + "\n").encode("utf-8")
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
        or result.get("type") != "agent_view"
        or result.get("active") is not True
    ):
        return 4
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
