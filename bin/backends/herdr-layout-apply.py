#!/usr/bin/env python3
"""Perform one schema-gated Herdr protocol-20 layout.apply request.

This is intentionally not a general Herdr client.
The Bash adapter validates the live session, protocol, schema, and endpoint
identity before invoking this transport.
This transport validates only its bounded request shape and that the response
is bound to its random request identifier.
"""
import json
import os
import socket
import sys


def fail(message):
    sys.stderr.write("herdr-layout-apply: %s\n" % message)
    return 2


def read_response(sock):
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            raise OSError("socket closed before response")
        data += chunk
    line, _ = data.split(b"\n", 1)
    return json.loads(line.decode("utf-8"))


def main(argv):
    if len(argv) != 8:
        return fail("usage: <socket> <workspace> <tab> <pane> <cwd> <env-json> <command-json>")
    _, socket_path, workspace, tab, pane, cwd, env_text, command_text = argv
    if not socket_path.startswith("/") or not cwd.startswith("/"):
        return fail("socket and cwd must be absolute paths")
    if not all(value and "\x00" not in value for value in (workspace, tab, pane)):
        return fail("workspace, tab, and pane identities must be non-empty")
    try:
        env = json.loads(env_text)
        command = json.loads(command_text)
    except ValueError:
        return fail("environment and command must be JSON")
    if not isinstance(env, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in env.items()):
        return fail("environment must be a string map")
    if not isinstance(command, list) or not command or not all(isinstance(value, str) and "\x00" not in value for value in command):
        return fail("command must be a non-empty string argv array")
    request_id = "fm-layout-apply-" + os.urandom(16).hex()
    request = {
        "id": request_id,
        "method": "layout.apply",
        "params": {
            "tab_id": tab,
            "root": {
                "type": "pane",
                "pane_id": pane,
                "command": command,
                "cwd": cwd,
                "env": env,
            },
        },
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(10)
            client.connect(socket_path)
            client.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
            response = read_response(client)
    except (OSError, ValueError) as error:
        return fail("%s (socket length %d)" % (error, len(socket_path)))
    if not isinstance(response, dict) or response.get("id") != request_id:
        return fail("response id did not match the request")
    if not isinstance(response.get("result"), dict):
        return fail("response did not contain a result object: %s" % json.dumps(response, separators=(",", ":")))
    sys.stdout.write(json.dumps(response["result"], separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
