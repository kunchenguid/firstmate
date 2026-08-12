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


def close_pane_bound(sock, pane_id, pid, start_time):
    request_id = "fm-bound-pane-close"
    request = {
        "id": request_id,
        "method": "pane.close_bound",
        "params": {
            "pane_id": pane_id,
            "expected_pid": pid,
            "expected_start_time": start_time,
        },
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
        or result.get("expected_start_time") != start_time
        or result.get("identity_verified") is not True
        or result.get("atomic") is not True
    ):
        return 4
    return 0


def close_tab_bound(sock, workspace_id, tab_id, pane_id):
    request_id = "fm-bound-tab-close"
    request = {
        "id": request_id,
        "method": "tab.close_bound",
        "params": {
            "workspace_id": workspace_id,
            "tab_id": tab_id,
            "pane_id": pane_id,
        },
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
        result.get("type") != "tab_closed_bound"
        or result.get("workspace_id") != workspace_id
        or result.get("tab_id") != tab_id
        or result.get("pane_id") != pane_id
        or result.get("identity_verified") is not True
        or result.get("atomic") is not True
    ):
        return 4
    return 0


def main(argv):
    if len(argv) != 6:
        return 2
    socket_path = argv[1]
    if not socket_path.startswith("/"):
        return 2
    if argv[2] == "--tab":
        workspace_id, tab_id, pane_id = argv[3:]
        if not workspace_id or not tab_id or not pane_id:
            return 2
        if any("\t" in value or "\r" in value or "\n" in value for value in (workspace_id, tab_id, pane_id)):
            return 2
        operation = "tab"
    elif argv[2] == "--pane":
        pane_id = argv[3]
        raw_pid = argv[4]
        start_time = argv[5]
        if not pane_id or not start_time:
            return 2
        if any(char in pane_id for char in "\t\r\n") or any(
            char in start_time for char in "\t\r\n"
        ):
            return 2
        try:
            pid = int(raw_pid)
        except ValueError:
            return 2
        if pid <= 1 or str(pid) != raw_pid:
            return 2
        operation = "pane"
    else:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(socket_path)
    except OSError:
        return 3
    with sock:
        if operation == "tab":
            return close_tab_bound(sock, workspace_id, tab_id, pane_id)
        return close_pane_bound(sock, pane_id, pid, start_time)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
