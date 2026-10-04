#!/usr/bin/env python3
"""Private native-control transport, used by fm-spawn, fm-control and the mod.

prepare STATE TASK TARGET creates a unique 0700 launch channel.
boot CHANNEL PID binds the exec'd Claude process; ready/poll/check/receipt are
mod-only operations with JSON on stdin. inspect/client bind a caller to the
task, endpoint and current Herdr foreground process supplied on stdin.
Requests expire, bind the caller PID and native module lifetime, and are
single-use. Receipts contain phases, never draft content. No terminal input.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import secrets
import stat
import sys
import tempfile
import time


VERSIONS = ("2.1.288", "2.1.292")
LIMIT = 8192


def private(path, directory=False):
    s = path.lstat()
    valid = stat.S_ISDIR(s.st_mode) if directory else stat.S_ISREG(s.st_mode)
    if not valid or s.st_uid != os.getuid() or s.st_mode & 0o077:
        raise ValueError(f"unsafe native control path: {path}")
    if not directory and (s.st_size > LIMIT or s.st_nlink != 1):
        raise ValueError("oversized or linked native control record")


def read(path):
    private(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as f:
        return json.load(f)


def write(path, data):
    if path.exists() or path.is_symlink():
        private(path)
    fd, tmp = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, separators=(",", ":"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def alive(pid):
    if type(pid) is not int or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def locked(channel):
    @contextlib.contextmanager
    def acquire():
        private(channel, True)
        path = channel / "lock"
        private(path)
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)
    return acquire()


def authorized(channel, ready, q):
    return (q.get("schema") == 1 and q.get("discard") is True
            and q.get("instance") == ready["instance"]
            and q.get("session") == ready["session"]
            and q.get("task") == ready["task"]
            and q.get("target") == ready["target"]
            and q.get("pid") == ready["pid"]
            and isinstance(q.get("nonce"), str) and len(q["nonce"]) == 32
            and type(q.get("expires")) in (int, float)
            and time.time() < q["expires"] <= time.time() + 31
            and alive(q.get("caller")) and alive(q.get("owner")) and not q.get("revoked")
            and alive(ready["pid"]))


def inspect(channel, task, target, process_info):
    private(channel, True)
    ready = read(channel / "ready.json")
    boot = read(channel / "boot.json")
    info = process_info["result"]["process_info"]
    if (ready["version"] not in VERSIONS or ready["task"] != task
            or ready["target"] != target or ready["pid"] != boot["pid"]
            or ready["launch"] != boot["launch"]
            or time.time() - ready["heartbeat"] > 3
            or ready["heartbeat"] > time.time() + 1
            or not alive(ready["pid"])
            or info["pane_id"] != target.split(":", 1)[1]
            or ready["pid"] not in [p["pid"] for p in info["foreground_processes"]]):
        raise ValueError("native capability is stale, unsupported, or belongs to another process")
    return ready


def main():
    action = sys.argv[1]
    channel = Path(sys.argv[2])
    if action == "prepare":
        # The state parent is the explicit home selected by the launch owner.
        channel = Path(tempfile.mkdtemp(prefix=f".{sys.argv[3]}.native-", dir=channel))
        (channel / "lock").touch(mode=0o600)
        write(channel / "boot.json", {"schema": 1, "task": sys.argv[3],
              "target": sys.argv[4], "launch": secrets.token_hex(16)})
        print(channel)
        return
    if action == "boot":
        with locked(channel):
            boot = read(channel / "boot.json")
            if "pid" in boot:
                raise ValueError("native launch channel already used")
            boot["pid"] = int(sys.argv[3])
            write(channel / "boot.json", boot)
        return
    data = json.loads(sys.stdin.read(LIMIT + 1))
    if action in ("inspect", "client"):
        with locked(channel):
            ready = inspect(channel, sys.argv[3], sys.argv[4], data)
            if action == "inspect":
                print(json.dumps(ready))
                return
            q = {k: ready[k] for k in ("task", "target", "session", "instance", "pid")}
            q.update(schema=1, discard=True, nonce=secrets.token_hex(16),
                     caller=os.getpid(), owner=int(sys.argv[5]), expires=time.time() + 20)
            write(channel / "request.json", q)
        last = "not-started"
        try:
            while time.time() < q["expires"]:
                with locked(channel):
                    if (channel / "receipt.json").exists():
                        r = read(channel / "receipt.json")
                        if all(r.get(k) == q[k] for k in ("nonce", "instance", "session", "pid", "task", "target")):
                            last = r.get("phase", "unknown")
                            if last == "exit-sent":
                                print(json.dumps(r))
                                return
                            if last == "refused":
                                raise ValueError(f"native discard refused: {r.get('reason')}; draft-may-be-discarded={r.get('mutated')}")
                time.sleep(0.05)
            raise ValueError(f"native discard timed out at {last}; an already issued native operation may be in flight; do not retry blindly")
        finally:
            with locked(channel):
                q["revoked"] = True
                write(channel / "request.json", q)
        return
    with locked(channel):
        boot = read(channel / "boot.json")
        if data.get("pid") != boot.get("pid") or not alive(boot["pid"]):
            raise ValueError("native module process does not match launch")
        if action == "ready":
            if data.get("version") not in VERSIONS or not isinstance(data.get("session"), str):
                raise ValueError("unsupported native engine version or session")
            ready = dict(boot, version=data["version"], session=data["session"],
                         instance=secrets.token_hex(16), heartbeat=time.time(), consumed=[])
            write(channel / "ready.json", ready)
            print(json.dumps(ready))
            return
        ready = read(channel / "ready.json")
        if data.get("instance") != ready["instance"]:
            raise ValueError("native module lifetime changed")
        if action == "poll":
            ready["heartbeat"] = time.time()
            write(channel / "ready.json", ready)
            if not (channel / "request.json").exists():
                print("null")
                return
            q = read(channel / "request.json")
            if not authorized(channel, ready, q) or q["nonce"] in ready["consumed"]:
                print("null")
                return
            ready["consumed"].append(q["nonce"])
            write(channel / "ready.json", ready)
            print(json.dumps(q))
            return
        q = read(channel / "request.json")
        valid = authorized(channel, ready, q) and data.get("nonce") == q["nonce"]
        if action == "check":
            print(json.dumps({"authorized": valid}))
        elif action == "receipt":
            # A refusal is useful after expiry as well; it never authorizes exit.
            if not valid and data.get("phase") != "refused":
                raise ValueError("request expired or was retired")
            receipt = {k: q[k] for k in ("nonce", "instance", "session", "pid", "task", "target")}
            receipt.update(phase=data["phase"], mutated=data.get("mutated", False),
                           reason=data.get("reason", ""))
            write(channel / "receipt.json", receipt)
            print("null")
        else:
            raise ValueError("unknown native transport action")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"native-control: {error}", file=sys.stderr)
        sys.exit(1)
