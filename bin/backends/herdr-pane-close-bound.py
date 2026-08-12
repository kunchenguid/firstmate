#!/usr/bin/env python3
import sys


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
    return 4


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(3)
