#!/usr/bin/env python3
"""Perform one schema-gated Herdr protocol-20 layout.apply request.

This is intentionally not a general Herdr client.
The Bash adapter validates the live session, protocol, schema, and endpoint
identity before invoking this transport.
The request payload is read from stdin so launch environment and command values
never appear in this helper's process arguments.
"""
import json
import os
import socket
import sys


def fail(message, status=2):
    sys.stderr.write("herdr-layout-apply: %s\n" % message)
    return status


def read_response(sock):
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            raise OSError("socket closed before response")
        data += chunk
    line, _ = data.split(b"\n", 1)
    return json.loads(line.decode("utf-8"))


def timeout_seconds():
    text = os.environ.get("FM_HERDR_LAYOUT_APPLY_TIMEOUT_SECS", "10")
    try:
        value = float(text)
    except ValueError:
        raise ValueError("invalid response timeout")
    if value <= 0 or value > 10:
        raise ValueError("response timeout must be greater than zero and at most 10 seconds")
    return value


def main(argv):
    if len(argv) != 8:
        return fail("usage: <socket> <workspace> <tab> <pane> <attempt-id> <label> < input")
    _, socket_path, workspace, tab, pane, attempt_id, label, _reserved = argv
    if _reserved != "--stdin-v1":
        return fail("unsupported input contract")
    if not socket_path.startswith("/"):
        return fail("socket must be an absolute path")
    if not all(value and "\x00" not in value for value in (workspace, tab, pane, label)):
        return fail("workspace, tab, pane, and label identities must be non-empty")
    if len(attempt_id) != 32 or any(character not in "0123456789abcdef" for character in attempt_id):
        return fail("attempt identity must be 128-bit lowercase hex")
    if label not in ("fm-launch-" + attempt_id, "fm-restore-" + attempt_id):
        return fail("label must carry the complete attempt identity")
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        return fail("stdin payload must be JSON")
    if not isinstance(payload, dict) or set(payload) != {"cwd", "env", "command"}:
        return fail("stdin payload must contain only cwd, env, and command")
    cwd = payload["cwd"]
    env = payload["env"]
    command = payload["command"]
    if not isinstance(cwd, str) or not cwd.startswith("/") or "\x00" in cwd:
        return fail("cwd must be an absolute path")
    if not isinstance(env, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
        return fail("environment must be a string map")
    if not isinstance(command, list) or not command or not all(isinstance(value, str) and "\x00" not in value for value in command):
        return fail("command must be a non-empty string argv array")
    try:
        timeout = timeout_seconds()
    except ValueError as error:
        return fail(str(error))
    request_id = "fm-layout-apply-" + attempt_id
    request = {
        "id": request_id,
        "method": "layout.apply",
        "params": {
            "tab_id": tab,
            "root": {
                "type": "pane",
                "pane_id": pane,
                "label": label,
                "command": command,
                "cwd": cwd,
                "env": env,
            },
        },
    }
    sent = False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(timeout)
            client.connect(socket_path)
            sent = True
            client.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
            response = read_response(client)
    except (OSError, ValueError) as error:
        return fail("%s (socket length %d)" % (error, len(socket_path)), 3 if sent else 2)
    if not isinstance(response, dict) or response.get("id") != request_id:
        return fail("response id did not match the request", 3)
    if not isinstance(response.get("result"), dict):
        return fail("response did not contain a result object", 3)
    sys.stdout.write(json.dumps(response["result"], separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
