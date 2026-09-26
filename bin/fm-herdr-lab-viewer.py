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

An optional capture file turns the viewer into a recording outer terminal.
Herdr streams pane graphics only to a client whose cell size in pixels is
known, so a capturing viewer also reports a fixed pixel geometry on the same
pre-fork window size, and every byte Herdr writes to the viewer is appended to
that file, up to ``CAPTURE_LIMIT_BYTES``. The file must be an absolute path
that does not exist yet; it is created private to the caller and never
followed through a symbolic link.

Usage: fm-herdr-lab-viewer.py <session> <pidfile> [<capture-file>]

Exit status:
  0  the viewer ran and exited;
  2  the session, pidfile, or capture file was invalid;
  3  the pty or the viewer process could not be created.
"""

import errno
import fcntl
import os
import re
import signal
import struct
import subprocess
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
ROWS = 40
COLS = 120
CELL_WIDTH_PX = 10
CELL_HEIGHT_PX = 20
CAPTURE_LIMIT_BYTES = 64 * 1024 * 1024
TERMINATION_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


def _child(slave, master, session):
    signal.pthread_sigmask(signal.SIG_UNBLOCK, TERMINATION_SIGNALS)
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


def _process_start(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart="],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "LC_ALL": "C"},
    )
    value = result.stdout.strip()
    if not value:
        raise RuntimeError("process start time unavailable")
    return value


def _write_pidfile(path, launcher_pid, viewer_pid):
    launcher_start = _process_start(launcher_pid)
    viewer_start = _process_start(viewer_pid)
    temporary = "%s.%d.tmp" % (path, launcher_pid)
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("launcher_pid=%d\n" % launcher_pid)
        handle.write("launcher_start=%s\n" % launcher_start)
        handle.write("viewer_pid=%d\n" % viewer_pid)
        handle.write("viewer_start=%s\n" % viewer_start)
    os.rename(temporary, path)


def _drain(master, capture):
    captured = 0
    while True:
        try:
            chunk = os.read(master, READ_CHUNK)
        except OSError as error:
            if error.errno == errno.EINTR:
                continue
            return
        if not chunk:
            return
        if capture is not None and captured < CAPTURE_LIMIT_BYTES:
            kept = chunk[: CAPTURE_LIMIT_BYTES - captured]
            try:
                os.write(capture, kept)
                captured += len(kept)
            except OSError:
                captured = CAPTURE_LIMIT_BYTES


def _open_capture(path):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    return os.open(path, flags, 0o600)


def main(argv):
    if len(argv) not in (3, 4):
        sys.stderr.write("fm-herdr-lab-viewer: usage: <session> <pidfile> [<capture-file>]\n")
        return 2
    session, pidfile = argv[1:3]
    capture_path = argv[3] if len(argv) == 4 else None
    if session == "default" or not SESSION_PATTERN.match(session):
        sys.stderr.write("fm-herdr-lab-viewer: refusing session %r\n" % session)
        return 2
    if not os.path.isabs(pidfile):
        sys.stderr.write("fm-herdr-lab-viewer: pidfile must be an absolute path\n")
        return 2
    capture = None
    if capture_path is not None:
        if not os.path.isabs(capture_path):
            sys.stderr.write("fm-herdr-lab-viewer: capture file must be an absolute path\n")
            return 2
        try:
            capture = _open_capture(capture_path)
        except OSError as error:
            sys.stderr.write("fm-herdr-lab-viewer: refusing capture file %r: %s\n" % (capture_path, error))
            return 2

    try:
        master, slave = os.openpty()
    except OSError as error:
        sys.stderr.write("fm-herdr-lab-viewer: could not create a pty: %s\n" % error)
        return 3
    # Before the fork, so the TUI's first grid read already sees a real size.
    pixels = (COLS * CELL_WIDTH_PX, ROWS * CELL_HEIGHT_PX) if capture is not None else (0, 0)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, *pixels))

    signal.pthread_sigmask(signal.SIG_BLOCK, TERMINATION_SIGNALS)
    try:
        viewer_pid = os.fork()
    except OSError as error:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, TERMINATION_SIGNALS)
        sys.stderr.write("fm-herdr-lab-viewer: could not fork the viewer: %s\n" % error)
        return 3
    if viewer_pid == 0:
        _child(slave, master, session)

    def _cancel_before_record(signum, _frame):
        try:
            os.kill(viewer_pid, signal.SIGKILL)
        except OSError:
            pass
        os._exit(128 + signum)

    signal.signal(signal.SIGTERM, _cancel_before_record)
    signal.signal(signal.SIGINT, _cancel_before_record)
    signal.signal(signal.SIGHUP, _cancel_before_record)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, TERMINATION_SIGNALS)

    os.close(slave)
    try:
        _write_pidfile(pidfile, os.getpid(), viewer_pid)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        sys.stderr.write("fm-herdr-lab-viewer: could not record process identity: %s\n" % error)
        try:
            os.kill(viewer_pid, signal.SIGKILL)
        except OSError:
            pass
        os.close(master)
        try:
            os.waitpid(viewer_pid, 0)
        except OSError:
            pass
        return 3

    def _signal_viewer(number):
        # The viewer may already be gone; that is the outcome we wanted anyway.
        try:
            os.kill(viewer_pid, number)
        except OSError:
            pass

    def _terminate(_signum, _frame):
        _signal_viewer(signal.SIGTERM)
        signal.setitimer(signal.ITIMER_REAL, TERMINATE_GRACE_SECONDS)

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    signal.signal(signal.SIGHUP, _terminate)
    signal.signal(signal.SIGALRM, lambda _s, _f: _signal_viewer(signal.SIGKILL))

    _drain(master, capture)
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
