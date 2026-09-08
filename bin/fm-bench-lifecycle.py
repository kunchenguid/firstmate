#!/usr/bin/env python3
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def main(argv):
    private, host, task, writer = argv[:4]
    report = None
    if argv[4] == "--report":
        report = Path(argv[5])
        argv = argv[:4] + argv[6:]
    if argv[4] != "--" or not re.fullmatch(r"[A-Za-z0-9._-]+", task):
        raise ValueError("invalid benchmark lifecycle binding")
    host = Path(host)
    descriptor = os.open(private, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)

    def private_file(suffix, limit=1024):
        try:
            fd = os.open(f"{task}.{suffix}", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        except OSError:
            return None, None
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
                return None, None
            return os.read(fd, limit).decode("utf-8"), (info.st_ino, info.st_mtime_ns)
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

    for name, parent in ((f"{task}.inbox", descriptor),):
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent)
        except FileExistsError:
            pass
    inbox_fd = os.open(f"{task}.inbox", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
    try:
        os.mkdir("handled", mode=0o700, dir_fd=inbox_fd)
    except FileExistsError:
        pass
    handled_fd = os.open("handled", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=inbox_fd)
    delivered = {}

    def read_message(directory, name):
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        except OSError:
            return None
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
                return None
            return os.read(fd, 1024 * 1024)
        finally:
            os.close(fd)

    def reconcile_inbox():
        directory = host / f"{task}.inbox"
        try:
            host_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError:
            return
        try:
            for name in os.listdir(host_fd):
                if not re.fullmatch(r"[0-9]+\.msg", name):
                    continue
                content = read_message(host_fd, name)
                if content is None:
                    continue
                if name not in delivered:
                    try:
                        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                     0o600, dir_fd=inbox_fd)
                    except FileExistsError:
                        continue
                    with os.fdopen(fd, "wb") as stream:
                        stream.write(content)
                    delivered[name] = content
                if content == delivered[name] and read_message(handled_fd, name) == content:
                    try:
                        os.mkdir("handled", mode=0o700, dir_fd=host_fd)
                    except FileExistsError:
                        pass
                    destination = os.open("handled", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=host_fd)
                    try:
                        os.rename(name, name, src_dir_fd=host_fd, dst_dir_fd=destination)
                    finally:
                        os.close(destination)
        finally:
            os.close(host_fd)

    generation, owner = host_generation(), incarnation()
    prior, _ = private_file("busy-state")
    _, marker = private_file("turn-ended")
    status_sent = ""
    report_seen = None
    child = subprocess.Popen(argv[5:])
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda sig, _frame: child.send_signal(sig) if child.poll() is None else None)

    def reconcile():
        nonlocal prior, marker, status_sent, report_seen
        if host_generation() != generation or incarnation() != owner:
            return
        reconcile_inbox()
        status_text, _ = private_file("status", 16 * 1024 * 1024)
        if status_text is not None:
            complete = status_text[:status_text.rfind("\n") + 1]
            if complete.startswith(status_sent):
                pending = complete[len(status_sent):]
                if pending:
                    with (host / f"{task}.status").open("a") as stream:
                        stream.write(pending)
                    status_sent = complete
        if report is not None:
            report_text, report_stamp = private_file("report.md", 16 * 1024 * 1024)
            if report_text is not None and report_stamp != report_seen:
                fd, name = tempfile.mkstemp(prefix=".bench-report-", dir=report.parent)
                try:
                    with os.fdopen(fd, "w") as stream:
                        stream.write(report_text)
                    os.replace(name, report)
                finally:
                    Path(name).unlink(missing_ok=True)
                report_seen = report_stamp
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
        os.close(handled_fd)
        os.close(inbox_fd)
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
