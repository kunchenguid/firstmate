#!/usr/bin/env python3
"""Attach one real foreground Herdr viewer to a named lab session over a pty.

bin/fm-herdr-lab.sh's ``viewer start`` is the only supported caller; run this
through that guard rather than directly, so the lab's ownership tripwire and
refuse-default checks still apply.

Herdr registers a foreground client only when the attaching terminal reports a
usable window grid. A pty created by ``script`` or a bare ``pty.fork()`` from a
non-tty parent starts at 0x0, which makes Herdr report a zero-sized grid and
keeps ``client.window_title.clear`` answering ``no_foreground_client``. That is
why firstmate could not drive the attached-viewer teardown cases live before
this helper existed. The fix is ordering as much as sizing: the window size is
set on the master fd BEFORE the fork, so the TUI cannot read the grid until it
is already non-zero.

The child also drops the inherited ``HERDR_*`` variables listed in
``SCRUBBED_ENV`` below. Herdr refuses to launch a nested viewer inside one of
its own panes, and this helper normally runs from exactly there.

Usage: fm-herdr-lab-viewer.py <session> <rows> <cols> <pidfile>

Exit status:
  0  the viewer ran and exited;
  2  arguments were invalid;
  3  the pty or the viewer process could not be created.
"""

import errno
import fcntl
import os
import re
import signal
import struct
import sys
import termios

# Herdr inherits these from the pane this helper runs in, and a nested viewer
# is refused outright. HERDR_SESSION is scrubbed with them so the explicit
# --session argument stays the viewer's only session source.
SCRUBBED_ENV = (
    "HERDR_ENV",
    "HERDR_PANE_ID",
    "HERDR_TAB_ID",
    "HERDR_WORKSPACE_ID",
    "HERDR_SOCKET_PATH",
    "HERDR_BIN_PATH",
    "HERDR_SESSION",
)

SESSION_PATTERN = re.compile(r"\Afm-lab-[A-Za-z0-9][A-Za-z0-9_-]*\Z")
TERMINATE_GRACE_SECONDS = 5.0
READ_CHUNK = 65536


def _positive_int(raw):
    try:
        value = int(raw, 10)
    except ValueError:
        return None
    return value if value > 0 else None


def _child(slave, master, session):
    os.setsid()
    try:
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    except OSError:
        pass
    for target in (0, 1, 2):
        os.dup2(slave, target)
    if slave > 2:
        os.close(slave)
    os.close(master)
    env = {key: value for key, value in os.environ.items() if key not in SCRUBBED_ENV}
    env.setdefault("TERM", "xterm-256color")
    try:
        os.execvpe("herdr", ["herdr", "--session", session], env)
    except OSError:
        pass
    os._exit(127)


def _write_pidfile(path, launcher_pid, viewer_pid):
    temporary = "%s.%d.tmp" % (path, launcher_pid)
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("launcher=%d\nviewer=%d\n" % (launcher_pid, viewer_pid))
    os.rename(temporary, path)


def _drain(master):
    while True:
        try:
            if not os.read(master, READ_CHUNK):
                return
        except OSError as error:
            if error.errno == errno.EINTR:
                continue
            return


def main(argv):
    if len(argv) != 5:
        sys.stderr.write("fm-herdr-lab-viewer: usage: <session> <rows> <cols> <pidfile>\n")
        return 2
    session, raw_rows, raw_cols, pidfile = argv[1:]
    if session == "default" or not SESSION_PATTERN.match(session):
        sys.stderr.write("fm-herdr-lab-viewer: refusing session %r\n" % session)
        return 2
    rows = _positive_int(raw_rows)
    cols = _positive_int(raw_cols)
    if rows is None or cols is None:
        sys.stderr.write("fm-herdr-lab-viewer: rows and cols must be positive integers\n")
        return 2
    if not os.path.isabs(pidfile):
        sys.stderr.write("fm-herdr-lab-viewer: pidfile must be an absolute path\n")
        return 2

    try:
        master, slave = os.openpty()
    except OSError as error:
        sys.stderr.write("fm-herdr-lab-viewer: could not create a pty: %s\n" % error)
        return 3
    # Before the fork, so the TUI's first grid read already sees a real size.
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    try:
        viewer_pid = os.fork()
    except OSError as error:
        sys.stderr.write("fm-herdr-lab-viewer: could not fork the viewer: %s\n" % error)
        return 3
    if viewer_pid == 0:
        _child(slave, master, session)

    os.close(slave)
    _write_pidfile(pidfile, os.getpid(), viewer_pid)

    def _signal_viewer(number):
        # The viewer may already be gone; that is the outcome we wanted anyway.
        try:
            os.kill(viewer_pid, number)
        except OSError:
            pass

    def _terminate(_signum, _frame):
        _signal_viewer(signal.SIGTERM)

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    signal.signal(signal.SIGHUP, _terminate)
    signal.signal(signal.SIGALRM, lambda _s, _f: _signal_viewer(signal.SIGKILL))

    _drain(master)
    _terminate(None, None)
    signal.setitimer(signal.ITIMER_REAL, TERMINATE_GRACE_SECONDS)
    try:
        _, status = os.waitpid(viewer_pid, 0)
    except OSError:
        status = 0
    signal.setitimer(signal.ITIMER_REAL, 0)
    return 0 if os.WIFSIGNALED(status) else os.WEXITSTATUS(status)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
