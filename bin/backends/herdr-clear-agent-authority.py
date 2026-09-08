#!/usr/bin/env python3
"""Clear only Herdr's exact official Pi lifecycle authority on one pane.

Herdr 0.8.2 exposes ``pane.clear_agent_authority`` in its protocol schema but
not as a CLI subcommand. Its generic ``pane release-agent`` command deliberately
ignores official ``herdr:pi`` authority while still returning success, so the
narrow Firstmate recovery for a proven exited Pi needs this fixed-method socket
boundary. The caller owns all stale-process, task, endpoint, worktree, source,
and postcondition proofs; this transport accepts only one pane id, one strictly
positive sequence, and the hard-coded ``herdr:pi`` source.

Usage: herdr-clear-agent-authority.py <socket-path> <pane-id> <seq>

Exit status:
  0  a matching protocol-level ``ok`` response was returned;
  2  arguments or the socket path were invalid;
  3  the request could not be sent or its response could not be read;
  4  the response was malformed, mismatched, or reported an error.

Protocol success is not mutation proof. The caller must verify that the session
reference and full-lifecycle authority disappeared before any replacement.

The measured 0.8.2 evidence behind every claim above lives in
docs/verification/runtime-backends.md, under "Stale Pi authority and its
release".
"""

import json
import os
import re
import socket
import stat
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_U64 = (1 << 64) - 1
PANE_RE = re.compile(r"^[A-Za-z0-9._@%+-]+:[A-Za-z0-9._@%+-]+$")
REQUEST_ID = "fm-clear-stale-herdr-pi-authority"


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
    if len(argv) != 4:
        return 2
    socket_path, pane_id, raw_seq = argv[1:]
    if not socket_path.startswith("/") or not PANE_RE.fullmatch(pane_id):
        return 2
    try:
        socket_stat = os.stat(socket_path, follow_symlinks=False)
    except OSError:
        return 2
    if not stat.S_ISSOCK(socket_stat.st_mode) or socket_stat.st_uid != os.getuid():
        return 2
    try:
        seq = int(raw_seq)
    except ValueError:
        return 2
    if seq <= 0 or seq > MAX_U64 or str(seq) != raw_seq:
        return 2

    request = {
        "id": REQUEST_ID,
        "method": "pane.clear_agent_authority",
        "params": {"pane_id": pane_id, "source": "herdr:pi", "seq": seq},
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(CONNECT_TIMEOUT)
            sock.connect(socket_path)
            sock.sendall(
                (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
            )
            line = _read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    except OSError:
        return 3

    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    result = response.get("result") if isinstance(response, dict) else None
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
