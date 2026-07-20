#!/usr/bin/env python3
"""Run a command behind a broker-owned PTY and bridge stdio.

The broker uses this instead of shelling through `script` because BSD `script`
requires a terminal-shaped stdin and refuses the daemon's socket/pipe bridge.
No credentials are accepted as arguments by this runner; it only receives the
installed lndev command and the approved session id.
"""

import os
import pty
import select
import signal
import subprocess
import sys


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["--"]:
        args = args[1:]
    if not args:
        print("pty_runner.py: missing command", file=sys.stderr)
        return 64

    master_fd, slave_fd = pty.openpty()
    child = subprocess.Popen(
        args,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=slave_fd,
        close_fds=True,
        env=os.environ.copy(),
    )
    os.close(slave_fd)

    def terminate(_signum, _frame):
        try:
            child.terminate()
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)

    stdin_open = True
    while True:
        fds = [master_fd]
        if stdin_open:
            fds.append(sys.stdin.fileno())
        readable, _, _ = select.select(fds, [], [], 0.05)
        if master_fd in readable:
            try:
                data = os.read(master_fd, 8192)
            except OSError:
                data = b""
            if data:
                os.write(sys.stdout.fileno(), data)
            else:
                break
        if stdin_open and sys.stdin.fileno() in readable:
            data = os.read(sys.stdin.fileno(), 8192)
            if data:
                os.write(master_fd, data)
            else:
                stdin_open = False
        if child.poll() is not None:
            while True:
                try:
                    data = os.read(master_fd, 8192)
                except OSError:
                    data = b""
                if not data:
                    break
                os.write(sys.stdout.fileno(), data)
            break

    try:
        os.close(master_fd)
    except OSError:
        pass
    return child.wait()


if __name__ == "__main__":
    raise SystemExit(main())
