#!/usr/bin/env python3
"""Inspect a Unix-domain socket peer from the server side."""

import json
import os
import platform
import re
import socket
import struct
import subprocess
import sys


LOCAL_PEERPID = 0x002
SOL_LOCAL = 0


def main() -> int:
    try:
        peer = inspect_peer(3)
        print(json.dumps({"ok": True, "peer": peer}, sort_keys=True))
        return 0
    except Exception as exc:  # noqa: BLE001 - command-line helper returns JSON errors.
        print(json.dumps({"ok": False, "error": str(exc)}, sort_keys=True))
        return 1


def inspect_peer(fd: int) -> dict:
    sock = socket.socket(fileno=fd)
    pid = peer_pid(sock)
    if pid <= 0:
        raise RuntimeError("peer pid unavailable")
    env_text, env_markers = peer_env(pid)
    cwd = peer_cwd(pid)
    ppid = ps_field(pid, "ppid")
    exe = peer_exe(pid)
    tty = ps_field(pid, "tty")
    return {
        "pid": pid,
        "ppid": int(ppid) if ppid.strip().isdigit() else None,
        "exe": exe,
        "cwd": cwd,
        "tty": tty.strip() or "unknown",
        "envMarkers": env_markers,
        "envReadable": bool(env_text),
        "cwdReadable": bool(cwd),
        "source": "server-peercred",
    }


def peer_pid(sock: socket.socket) -> int:
    system = platform.system()
    if system == "Darwin":
        data = sock.getsockopt(SOL_LOCAL, LOCAL_PEERPID, 4)
        return struct.unpack("i", data[:4])[0]
    if system == "Linux":
        data = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        pid, _uid, _gid = struct.unpack("3i", data)
        return pid
    raise RuntimeError(f"unsupported peer credential platform {system}")


def peer_env(pid: int) -> tuple[str, list[str]]:
    system = platform.system()
    if system == "Darwin":
        text = run(["ps", "eww", "-p", str(pid), "-o", "command="])
    elif system == "Linux":
        with open(f"/proc/{pid}/environ", "rb") as fh:
            text = fh.read().replace(b"\0", b"\n").decode("utf-8", "replace")
    else:
        raise RuntimeError(f"unsupported env inspection platform {system}")
    if not text:
        raise RuntimeError("peer env unreadable")
    markers = []
    if re.search(r"(^|\s)LINDY_SESSION_TYPE=eng-agent(\s|$)", text):
        markers.append("LINDY_SESSION_TYPE=eng-agent")
    for match in re.finditer(r"(^|\s)(LINDY_AGENT_[A-Za-z0-9_]+)=", text):
        markers.append(match.group(2))
    for key in ["LINDY_BOOT_TOKEN", "LINDY_SHELL_API_URL"]:
        if re.search(rf"(^|\s){re.escape(key)}=", text):
            markers.append(key)
    return text, sorted(set(markers))


def peer_cwd(pid: int) -> str:
    system = platform.system()
    if system == "Darwin":
        output = run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"])
        for line in output.splitlines():
            if line.startswith("n"):
                return realpath_or_value(line[1:])
        raise RuntimeError("peer cwd missing from lsof")
    if system == "Linux":
        return realpath_or_value(os.readlink(f"/proc/{pid}/cwd"))
    raise RuntimeError(f"unsupported cwd inspection platform {system}")


def peer_exe(pid: int) -> str:
    if platform.system() == "Linux":
        try:
            return os.readlink(f"/proc/{pid}/exe")
        except OSError:
            pass
    return ps_field(pid, "comm").strip() or "unknown"


def ps_field(pid: int, field: str) -> str:
    return run(["ps", "-p", str(pid), "-o", f"{field}="]).strip()


def run(args: list[str]) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
    return result.stdout


def realpath_or_value(path: str) -> str:
    try:
        return os.path.realpath(path)
    except OSError:
        return path


if __name__ == "__main__":
    raise SystemExit(main())
