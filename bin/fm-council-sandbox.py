#!/usr/bin/env python3
"""Launch one council participant under a Linux Landlock policy.

This helper is intentionally not a general sandbox.  Landlock denies filesystem
reads, writes, and executable launches by default, admits read-only system
paths, grants execute only on the exact allowlisted binaries, and grants writes
only below explicit participant-owned directories.  A seccomp filter also
denies new Unix-domain sockets so terminal-control sockets cannot be reached by
path guessing.  Both policies are inherited by every child before exec.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
from pathlib import Path
import stat
import sys


SYS_LANDLOCK_CREATE_RULESET = 444
SYS_LANDLOCK_ADD_RULE = 445
SYS_LANDLOCK_RESTRICT_SELF = 446
LANDLOCK_CREATE_RULESET_VERSION = 1
LANDLOCK_RULE_PATH_BENEATH = 1
PR_SET_NO_NEW_PRIVS = 38
PR_SET_SECCOMP = 22
SECCOMP_MODE_FILTER = 2
SECCOMP_RET_ALLOW = 0x7FFF0000
SECCOMP_RET_ERRNO = 0x00050000
BPF_LD_W_ABS = 0x20
BPF_JMP_JEQ_K = 0x15
BPF_JMP_JGE_K = 0x35
BPF_RET_K = 0x06
SYS_SOCKET_X86_64 = 41
AF_UNIX = 1
AUDIT_ARCH_X86_64 = 0xC000003E
X32_SYSCALL_BIT = 0x40000000

EXECUTE = 1 << 0
WRITE_FILE = 1 << 1
READ_FILE = 1 << 2
READ_DIR = 1 << 3
REMOVE_DIR = 1 << 4
REMOVE_FILE = 1 << 5
MAKE_CHAR = 1 << 6
MAKE_DIR = 1 << 7
MAKE_REG = 1 << 8
MAKE_SOCK = 1 << 9
MAKE_FIFO = 1 << 10
MAKE_BLOCK = 1 << 11
MAKE_SYM = 1 << 12
REFER = 1 << 13
TRUNCATE = 1 << 14

READ_ACCESS = READ_FILE | READ_DIR
WRITE_ACCESS = (
    WRITE_FILE
    | REMOVE_DIR
    | REMOVE_FILE
    | MAKE_CHAR
    | MAKE_DIR
    | MAKE_REG
    | MAKE_SOCK
    | MAKE_FIFO
    | MAKE_BLOCK
    | MAKE_SYM
    | REFER
    | TRUNCATE
)
HANDLED_ACCESS = EXECUTE | READ_ACCESS | WRITE_ACCESS
FILE_ACCESS = EXECUTE | READ_FILE | WRITE_FILE | TRUNCATE


class RulesetAttr(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class PathBeneathAttr(ctypes.Structure):
    _fields_ = [
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
        ("reserved", ctypes.c_uint32),
    ]


class SockFilter(ctypes.Structure):
    _fields_ = [
        ("code", ctypes.c_ushort),
        ("jt", ctypes.c_ubyte),
        ("jf", ctypes.c_ubyte),
        ("k", ctypes.c_uint32),
    ]


class SockFprog(ctypes.Structure):
    _fields_ = [("length", ctypes.c_ushort), ("filter", ctypes.POINTER(SockFilter))]


LIBC = ctypes.CDLL(None, use_errno=True)


def syscall(number: int, *args: object) -> int:
    result = LIBC.syscall(number, *args)
    if result < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return int(result)


def canonical_existing(path: str) -> Path:
    resolved = Path(path).expanduser().resolve(strict=True)
    return resolved


def add_path_rule(ruleset_fd: int, path: Path, access: int) -> None:
    flags = os.O_PATH | os.O_CLOEXEC
    path_fd = os.open(path, flags)
    try:
        mode = os.fstat(path_fd).st_mode
        allowed = access if stat.S_ISDIR(mode) else access & FILE_ACCESS
        if stat.S_ISDIR(mode) and allowed & EXECUTE:
            allowed |= READ_DIR
        attribute = PathBeneathAttr(allowed, path_fd, 0)
        syscall(
            SYS_LANDLOCK_ADD_RULE,
            ruleset_fd,
            LANDLOCK_RULE_PATH_BENEATH,
            ctypes.byref(attribute),
            0,
        )
    finally:
        os.close(path_fd)


def deny_new_unix_sockets() -> None:
    if os.uname().machine != "x86_64":
        raise RuntimeError("the council Unix-socket filter is verified only on Linux x86_64")
    filters = (SockFilter * 9)(
        SockFilter(BPF_LD_W_ABS, 0, 0, 4),
        SockFilter(BPF_JMP_JEQ_K, 0, 5, AUDIT_ARCH_X86_64),
        SockFilter(BPF_LD_W_ABS, 0, 0, 0),
        SockFilter(BPF_JMP_JGE_K, 3, 0, X32_SYSCALL_BIT),
        SockFilter(BPF_JMP_JEQ_K, 0, 3, SYS_SOCKET_X86_64),
        SockFilter(BPF_LD_W_ABS, 0, 0, 16),
        SockFilter(BPF_JMP_JEQ_K, 0, 1, AF_UNIX),
        SockFilter(BPF_RET_K, 0, 0, SECCOMP_RET_ERRNO | errno.EACCES),
        SockFilter(BPF_RET_K, 0, 0, SECCOMP_RET_ALLOW),
    )
    program = SockFprog(len(filters), ctypes.cast(filters, ctypes.POINTER(SockFilter)))
    if LIBC.prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ctypes.byref(program), 0, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


def install_policy(readable: list[Path], writable: list[Path], executables: list[Path]) -> int:
    try:
        abi = syscall(
            SYS_LANDLOCK_CREATE_RULESET,
            0,
            0,
            LANDLOCK_CREATE_RULESET_VERSION,
        )
    except OSError as error:
        if error.errno in (errno.ENOSYS, errno.EOPNOTSUPP):
            raise RuntimeError("Linux Landlock is unavailable; refusing an unconfined council participant") from error
        raise
    if abi < 4:
        raise RuntimeError(f"Linux Landlock ABI {abi} is below the verified council minimum 4")

    attribute = RulesetAttr(HANDLED_ACCESS)
    ruleset_fd = syscall(
        SYS_LANDLOCK_CREATE_RULESET,
        ctypes.byref(attribute),
        ctypes.sizeof(attribute),
        0,
    )
    try:
        for path in readable:
            add_path_rule(ruleset_fd, path, READ_ACCESS)
        for path in writable:
            add_path_rule(ruleset_fd, path, READ_ACCESS | WRITE_ACCESS)
        for path in executables:
            add_path_rule(ruleset_fd, path, READ_FILE | EXECUTE)

        if LIBC.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        syscall(SYS_LANDLOCK_RESTRICT_SELF, ruleset_fd, 0)
        deny_new_unix_sockets()
    finally:
        os.close(ruleset_fd)
    return abi


PROVIDER_KEYS = {
    "claude": ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"),
    "codex": ("OPENAI_API_KEY",),
}


def safe_environment(home: Path, harness: str | None) -> dict[str, str]:
    keep = {
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TERM",
        "COLORTERM",
        "LANG",
        "LC_ALL",
        "TZ",
    }
    keep.update(PROVIDER_KEYS.get(harness or "", ()))
    environment = {key: value for key, value in os.environ.items() if key in keep}
    environment.update(
        {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(home / ".config"),
            "XDG_CACHE_HOME": str(home / ".cache"),
            "XDG_DATA_HOME": str(home / ".local" / "share"),
            "TMPDIR": str(home / "tmp"),
            "CODEX_HOME": str(home / ".codex"),
            "CLAUDE_CONFIG_DIR": str(home / ".claude"),
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "FM_COUNCIL_SANDBOX": "landlock-v1",
        }
    )
    return environment


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a command in the verified Linux council read-only filesystem lane."
    )
    parser.add_argument("--home", required=True, help="participant-owned HOME and writable root")
    parser.add_argument("--readable", action="append", default=[], help="additional readable path")
    parser.add_argument("--writable", action="append", default=[], help="additional writable path")
    parser.add_argument("--allow-exec", action="append", default=[], help="exact executable path")
    parser.add_argument("--harness", choices=("claude", "codex"), help="harness whose own provider credentials pass through")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.command and arguments.command[0] == "--":
        arguments.command = arguments.command[1:]
    if not arguments.command:
        parser.error("a command is required after --")
    return arguments


def main() -> int:
    arguments = parse_args()
    if sys.platform != "linux":
        print("fm-council-sandbox: only verified on Linux; refusing this platform", file=sys.stderr)
        return 1

    home = canonical_existing(arguments.home)
    if not home.is_dir():
        print("fm-council-sandbox: --home must be a directory", file=sys.stderr)
        return 2
    for child in (".config", ".cache", ".local/share", "tmp", ".codex", ".claude"):
        path = home / child
        path.mkdir(parents=True, exist_ok=True, mode=0o700)

    system_readables = [
        path
        for candidate in (
            "/usr",
            "/bin",
            "/lib",
            "/lib64",
            "/proc/self",
            "/sys",
            "/dev/null",
            "/dev/zero",
            "/dev/random",
            "/dev/urandom",
            "/dev/tty",
            "/etc/ssl",
            "/etc/pki",
            "/etc/ca-certificates",
            "/etc/resolv.conf",
            "/etc/hosts",
            "/etc/nsswitch.conf",
            "/etc/passwd",
            "/etc/group",
            "/etc/localtime",
            "/etc/ld.so.cache",
        )
        if (path := Path(candidate).resolve()).exists()
    ]
    readable = system_readables + [canonical_existing(path) for path in arguments.readable]
    device_writables = [path for candidate in ("/dev/null", "/dev/tty") if (path := Path(candidate).resolve()).exists()]
    writable = [home, *device_writables] + [canonical_existing(path) for path in arguments.writable]
    command_path = canonical_existing(arguments.command[0])
    usr = Path("/usr").resolve()
    try:
        command_path.relative_to(usr)
    except ValueError as error:
        raise RuntimeError(f"council command must resolve below the verified system executable tree {usr}: {command_path}") from error
    executables = [command_path]
    loader = Path("/lib64/ld-linux-x86-64.so.2")
    if loader.exists():
        executables.append(loader.resolve())
    for requested in arguments.allow_exec:
        executable = canonical_existing(requested)
        try:
            executable.relative_to(usr)
        except ValueError as error:
            raise RuntimeError(f"allowed executable is outside {usr}: {executable}") from error
        if executable not in executables:
            executables.append(executable)

    try:
        install_policy(readable, writable, executables)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"fm-council-sandbox: {error}", file=sys.stderr)
        return 1

    environment = safe_environment(home, arguments.harness)
    os.chdir(home)
    os.execve(command_path, [arguments.command[0], *arguments.command[1:]], environment)
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
