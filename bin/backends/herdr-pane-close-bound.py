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


def request(sock, request_id, method, params):
    message = {"id": request_id, "method": method, "params": params}
    try:
        sock.sendall((json.dumps(message, separators=(",", ":")) + "\n").encode())
    except OSError:
        return None, 3
    line = read_line(sock, time.monotonic() + RESPONSE_TIMEOUT)
    if line is None:
        return None, 3
    try:
        response = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return None, 4
    if not isinstance(response, dict) or response.get("id") != request_id:
        return None, 4
    if response.get("error") is not None:
        return None, 4
    return response.get("result"), 0


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

    process_info, status = request(
        sock,
        "fm-bound-process-info",
        "pane.process_info",
        {"pane_id": pane_id},
    )
    if status != 0 or not isinstance(process_info, dict):
        return status or 4
    if process_info.get("type") != "pane_process_info":
        return 4
    details = process_info.get("process_info")
    if not isinstance(details, dict) or details.get("pane_id") != pane_id:
        return 4
    processes = details.get("foreground_processes")
    if not isinstance(processes, list) or not any(
        isinstance(process, dict) and process.get("pid") == pid for process in processes
    ):
        return 4

    result, status = request(
        sock,
        "fm-bound-pane-close",
        "pane.close",
        {"pane_id": pane_id},
    )
    if status != 0 or not isinstance(result, dict):
        return status or 4
    return 0 if result.get("type") == "pane_closed" else 4


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
