#!/usr/bin/env python3
"""fm-procinfo.py - ps-free process facts for bin/fm-session-lock-lib.sh.

Prints one line: <ppid>TAB<comm>TAB<args> for the pid given as argv[1],
using only sysctl(3) - the same kernel state `ps` reads, just without
executing /bin/ps. It exists because an EDR-style policy can deny the
ps binary's exec outright (even `ps -V`), and a session lock whose
identity walk needs ps can then never be acquired at all.

Identity keeps ps's exact shape on macOS: comm is argv[0] and args is
the full argv joined with spaces, both taken from the kernel's per-
process argv region - the same region ps itself reports. That is a
correctness requirement, not a preference: the session lock compares a
process's identity across routes, and any process ps calls a verified
harness while this route calls it a non-harness turns a foreign
owner's fail-closed refusal into a lock takeover. A resolved exec path
(libproc proc_pidpath) is deliberately NOT reported - it is a
different fact that disagrees with ps for renamed, symlinked, or
argv[0]-wrapping harnesses, which is precisely the population the
denied-ps hosts are expected to run.

Fail-closed by design: every read is verified against the requested pid
before anything is printed, and an argv that cannot be read to exactly
its declared length yields no identity rather than a partial one. No
pid, no verification, no output - exit 1.

Usage: fm-procinfo.py <pid>
"""
import ctypes
import ctypes.util
import os
import struct
import sys

CTL_KERN = 1
KERN_PROC = 14        # CTL_KERN, KERN_PROC, KERN_PROC_PID: one kinfo_proc
KERN_PROC_PID = 1
KERN_PROCARGS2 = 49   # CTL_KERN, KERN_PROCARGS2, pid: exec path + argv + env

# kinfo_proc LP64 offsets: p_pid lives in kp_proc, the real parent pid in
# kp_eproc.e_ppid. These are assumptions, so _self_kinfo() proves them
# against this very process (os.getpid() / os.getppid()) before they are
# ever used on a requested pid, and a mismatch ends the run instead of
# reporting a guess.
P_PID_OFF = 40
E_PPID_OFF = 560


def _libc():
    return ctypes.CDLL(ctypes.util.find_library("c") or "libc.dylib",
                       use_errno=True)


_libc_cache = None


def libc():
    global _libc_cache
    if _libc_cache is None:
        _libc_cache = _libc()
    return _libc_cache


def _sysctl(mib):
    """Run a sysctl(3) mib, return the raw buffer, or None if it fails."""
    mib_arr = (ctypes.c_int * len(mib))(*mib)
    size = ctypes.c_size_t(0)
    ret = libc().sysctl(mib_arr, len(mib), None, ctypes.byref(size), None, 0)
    if ret != 0 or size.value == 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    ret = libc().sysctl(mib_arr, len(mib), buf, ctypes.byref(size), None, 0)
    if ret != 0:
        return None
    return buf.raw[: size.value]


def _self_kinfo():
    """Return this process's own kinfo_proc, only if both offsets verify.

    The buffer read for os.getpid() must carry os.getpid() at P_PID_OFF and
    os.getppid() at E_PPID_OFF. If either read disagrees, the layout
    assumption is wrong on this system and every ppid_of() call that uses
    these offsets returns None instead.
    """
    buf = _sysctl((CTL_KERN, KERN_PROC, KERN_PROC_PID, os.getpid()))
    if buf is None or len(buf) < E_PPID_OFF + 4:
        return None
    if struct.unpack_from("<i", buf, P_PID_OFF)[0] != os.getpid():
        return None
    if struct.unpack_from("<i", buf, E_PPID_OFF)[0] != os.getppid():
        return None
    return buf


def ppid_of(pid, offsets_verified):
    """Return the pid's parent pid, or None.

    offsets_verified is the self-kinfo proof that P_PID_OFF/E_PPID_OFF are
    right here; the target buffer must additionally describe exactly the
    pid asked for, so a mismatched or truncated read never reports a guess.
    """
    if offsets_verified is None:
        return None
    buf = _sysctl((CTL_KERN, KERN_PROC, KERN_PROC_PID, pid))
    if buf is None or len(buf) < E_PPID_OFF + 4:
        return None
    if struct.unpack_from("<i", buf, P_PID_OFF)[0] != pid:
        return None
    return struct.unpack_from("<i", buf, E_PPID_OFF)[0]


def _procargs(pid):
    """Return this pid's full argv via KERN_PROCARGS2, or None.

    Layout: int32 argc, exec path (NUL), NUL padding, argc NUL-terminated
    argv strings (argv[0] is the invoked name - the same fact
    `ps -o comm=` reports), then NUL padding, then env strings we do not
    need. Strings are collected positionally: an empty argv element is
    data, not padding, so the only skips allowed are the padding runs
    before argv[0]. Anything that stops short of exactly argc strings is
    an incomplete identity and returns None rather than a shifted or
    env-leaking guess.
    """
    buf = _sysctl((CTL_KERN, KERN_PROCARGS2, pid))
    if buf is None or len(buf) < 4:
        return None
    argc = struct.unpack_from("<i", buf, 0)[0]
    if argc <= 0 or argc > 4096:
        return None
    strings = buf[4:].split(b"\0")
    if not strings or not strings[0]:
        return None
    argv = []
    collecting = False
    for raw in strings[1:]:
        if not collecting:
            if not raw:
                continue  # padding between the exec path and argv[0]
            collecting = True
        if raw:
            try:
                argv.append(raw.decode("utf-8"))
            except UnicodeDecodeError:
                argv.append("?")
        else:
            # An empty element inside argv is real data - ps reports it
            # too - so it is collected as "", never treated as padding.
            argv.append("")
        if len(argv) == argc:
            return argv
    return None


def _flat(s):
    """Collapse field and record delimiters so one read is one line."""
    for ch in ("\t", "\r", "\n"):
        s = s.replace(ch, " ")
    return s


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        print("usage: fm-procinfo.py <pid>", file=sys.stderr)
        return 2
    pid = int(sys.argv[1])
    verified = _self_kinfo()
    ppid = ppid_of(pid, verified)
    if ppid is None:
        return 1
    argv = _procargs(pid)
    if not argv or not argv[0]:
        # No argv means no identity. ps gets its comm/args from this
        # same region, so a process unreadable here is unreadable
        # there - substituting a resolved path from elsewhere would
        # hand the two routes different facts about one process.
        return 1
    comm = _flat(argv[0])
    args = _flat(" ".join(argv))
    sys.stdout.write("%d\t%s\t%s\n" % (ppid, comm, args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
