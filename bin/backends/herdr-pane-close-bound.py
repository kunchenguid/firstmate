#!/usr/bin/env python3
import json
import socket
import sys
import time


CONNECT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 5.0
RECV_CHUNK = 65536
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


def read_line(sock, deadline):
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


def close_bound(sock, pane_id, pid):
    request_id = "fm-bound-pane-close"
    request = {
        "id": request_id,
        "method": "pane.close_bound",
        "params": {"pane_id": pane_id, "expected_pid": pid},
    }
    try:
        sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
    except OSError:
        return 3
    line = read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 4
    if not isinstance(response, dict) or response.get("id") != request_id:
        return 4
    if response.get("error") is not None:
        return 4
    result = response.get("result")
    if not isinstance(result, dict):
        return 4
    if (
        result.get("type") != "pane_closed_bound"
        or result.get("pane_id") != pane_id
        or result.get("expected_pid") != pid
        or result.get("atomic") is not True
    ):
        return 4
    return 0


def main(argv):
    if len(argv) != 4:
        return 2
    socket_path, pane_id, raw_pid = argv[1:]
    if not socket_path.startswith("/") or not pane_id:
        return 2
    if any(char in pane_id for char in "\t\r\n"):
        return 2
    try:
        pid = int(raw_pid)
    except ValueError:
        return 2
    if pid <= 1 or str(pid) != raw_pid:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        return 3
    with sock:
        return close_bound(sock, pane_id, pid)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
