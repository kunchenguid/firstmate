#!/usr/bin/env python3
"""Kernel-backed gate lock implementation for fm-gate-lock.sh."""
import base64
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import time


def die(message, code=2):
    print(f"fm-gate-lock: {message}", file=sys.stderr)
    raise SystemExit(code)


def main():
    mode, encoded = sys.argv[1:3]
    args = json.loads(base64.b64decode(encoded))
    if mode == "remote":
        mode = args.pop("mode")
        args["host"] = "local"
    host, name = args["host"], args["name"]
    if not name or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in name):
        die("lock name must contain only letters, digits, dot, underscore, or dash")
    if host != "local":
        source = pathlib.Path(__file__).read_bytes()
        remote = base64.b64encode(source).decode()
        args["mode"] = mode
        payload = base64.b64encode(json.dumps(args).encode()).decode()
        code = f"import base64;exec(compile(base64.b64decode('{remote}'),'<fm-gate-lock>','exec'))"
        return subprocess.run(["ssh", "--", host, "python3", "-c", code, "remote", payload], check=False).returncode

    root = pathlib.Path(os.environ.get("XDG_RUNTIME_DIR") or pathlib.Path.home() / ".cache") / "fm-gate-lock"
    root.mkdir(parents=True, exist_ok=True)
    lock = root / f"{name}.lock"
    info = root / f"{name}.holder"
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    if mode == "status":
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            try:
                holder = info.read_text().strip()
            except OSError:
                holder = "holder unavailable"
            try:
                held_since = float(holder.rsplit(" ", 1)[-1])
                age = max(0, int(time.time() - held_since))
                identity = holder.rsplit(" ", 1)[0]
                print(f"held: {identity} for {age}s")
            except (ValueError, OSError):
                print(f"held: {holder}")
            return 0
        fcntl.flock(fd, fcntl.LOCK_UN)
        print("free")
        return 1

    timeout = args["timeout"]
    start = time.monotonic()
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            try:
                holder = info.read_text().strip()
            except OSError:
                holder = "holder unavailable"
            since = ""
            try:
                since = f" since {time.strftime('%Y-%m-%d %H:%M:%S %Z', time.localtime(float(holder.rsplit(' ', 1)[-1])))}"
            except (ValueError, OSError):
                pass
            print(f"waiting: {holder}{since}", file=sys.stderr, flush=True)
            if time.monotonic() - start >= timeout:
                die(f"timed out after {timeout}s waiting for {name} on {host}", 75)
            time.sleep(min(1, max(0.05, timeout - (time.monotonic() - start))))
    holder = args["holder"] or f"pid-{os.getpid()}"
    stamp = time.time()
    temp = info.with_name(info.name + f".{os.getpid()}.tmp")
    try:
        temp.write_text(f"{holder} {stamp}\n")
        os.replace(temp, info)
    except OSError:
        pass  # Visibility is advisory; the kernel lock alone controls access.
    command = args["command"]
    cwd = args["cwd"]
    try:
        return subprocess.run(command, cwd=cwd, check=False, pass_fds=(fd,)).returncode
    finally:
        try:
            info.unlink()
        except OSError:
            pass
        fcntl.flock(fd, fcntl.LOCK_UN)


if __name__ == "__main__":
    raise SystemExit(main())
