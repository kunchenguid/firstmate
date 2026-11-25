#!/usr/bin/env python3
"""Send one narrowly scoped pane.clear_agent_authority request to a Herdr socket.

This helper is the wire transport for Firstmate's documented clear-registration
path (bin/fm-control.sh's `clear-registration` verb, whose guard lives in
bin/backends/herdr.sh's fm_backend_herdr_clear_agent_registration). It accepts
only an exact pane id, sends only the non-destructive
``pane.clear_agent_authority`` method, and prints the verified JSON response.

The method exists because Herdr's CLI never grew a subcommand for it while
``pane release-agent`` is dropped for an official agent source, so a
registration left behind after its process exits has no other sanctioned
repair. The caller - never this transport - owns the agent-less-shell proof:
this script must not be pointed at a pane by hand while an agent is running,
because clearing the authority strips a live agent's status binding.

Wire protocol shape (schema verified against the bundled `herdr api schema`
of the installed 0.9.x client, protocol 22, ``pane.clear_agent_authority``
params ``{"pane_id": string}``):

  request:  {"id":"fm-clear-agent-authority","method":"pane.clear_agent_authority",
             "params":{"pane_id":P}}\n
  response: {"id":"fm-clear-agent-authority","result":{"type":"ok"}}\n

Usage: herdr-clear-agent-authority.py <socket_path> <pane_id>

Exit status:
  0  the server returned the matching ok response;
  2  arguments or socket connection were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.
"""

import json
import re
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
REQUEST_ID = "fm-clear-agent-authority"
PANE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9:_-]*$")


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
    socket_path, pane_id = argv[1:]
    if not socket_path.startswith("/"):
        return 2
    if not PANE_ID_RE.match(pane_id):
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        return 2

    request = {
        "id": REQUEST_ID,
        "method": "pane.clear_agent_authority",
        "params": {"pane_id": pane_id},
    }
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
        or result.get("type") != "ok"
    ):
        return 4
    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
