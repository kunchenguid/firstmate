#!/usr/bin/env python3
import os
import re
import signal
import stat
import subprocess
import sys
from pathlib import Path


def main(argv):
    private, host, task, writer = argv[:4]
    if argv[4] != "--" or not re.fullmatch(r"[A-Za-z0-9._-]+", task):
        raise ValueError("invalid benchmark lifecycle binding")
    host = Path(host)
    descriptor = os.open(private, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def private_file(suffix):
        try:
            fd = os.open(f"{task}.{suffix}", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        except OSError:
            return None, None
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                return None, None
            return os.read(fd, 1024).decode("utf-8"), (info.st_ino, info.st_mtime_ns)
        finally:
            os.close(fd)

    def host_generation():
        try:
            return (host / f"{task}.busy-gen").read_text().strip()
        except FileNotFoundError:
            return ""

    def incarnation():
        try:
            return next((line for line in (host / f"{task}.meta").read_text().splitlines()
                         if line.startswith("spawn_gen=")), "")
        except FileNotFoundError:
            return ""

    generation, owner = host_generation(), incarnation()
    prior, _ = private_file("busy-state")
    _, marker = private_file("turn-ended")
    child = subprocess.Popen(argv[5:])
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda sig, _frame: child.send_signal(sig) if child.poll() is None else None)

    def reconcile():
        nonlocal prior, marker
        if host_generation() != generation or incarnation() != owner:
            return
        current, _ = private_file("busy-state")
        if generation and current and current != prior:
            match = re.fullmatch(r"v1 gen=([A-Za-z0-9._-]+) seq=([0-9]+) state=(busy|idle|unknown) source=([A-Za-z0-9._-]+) event=([A-Za-z0-9._-]+) ts=([0-9]+)\n?", current)
            if match and match[1] == generation:
                subprocess.run([writer, "apply", str(host), task, match[3], "--gen", generation,
                                "--source", match[4], "--event", match[5]], check=True, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL)
            prior = current
        _, stamp = private_file("turn-ended")
        if stamp is not None and stamp != marker:
            (host / f"{task}.turn-ended").touch()
            marker = stamp

    try:
        while True:
            reconcile()
            try:
                result = child.wait(timeout=0.1)
                reconcile()
                return result if result >= 0 else 128 - result
            except subprocess.TimeoutExpired:
                pass
    finally:
        os.close(descriptor)
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
