"""Shared paths, process helpers, and operational-input encoding for the
Firstmate Hermes plugin.

Every helper here fails open: a supervisor helper that raises inside a Hermes
hook would break the captain's session, so errors collapse to a conservative
value and the shell owners in ``bin/`` stay the single source of every
decision (scope, locks, guards, busy state, encoding).
"""

from __future__ import annotations

import hashlib
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence

# U+2063 INVISIBLE SEPARATOR + stable label. bin/fm-operational-input.sh owns
# the wire form; this constant is only the fallback used when that owner
# cannot run, and it must stay byte-identical to FM_OPERATIONAL_HEADER_PREFIX.
OPERATIONAL_PREFIX = "⁣FIRSTMATE_OP: "
OPERATIONAL_VERSION = "v1"


@dataclass(frozen=True)
class Paths:
    root: Path
    home: Path
    state: Path
    config: Path

    @property
    def bin(self) -> Path:
        return self.root / "bin"


def resolve_paths(root: Path) -> Paths:
    home = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or root)
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or home / "state")
    config = Path(os.environ.get("FM_CONFIG_OVERRIDE") or home / "config")
    return Paths(root=root, home=home, state=state, config=config)


def script_env(paths: Paths, extra: Optional[dict] = None) -> dict:
    env = dict(os.environ)
    env.setdefault("FM_HOME", str(paths.home))
    if extra:
        env.update({k: v for k, v in extra.items() if v is not None})
    return env


@dataclass
class RunResult:
    code: int
    stdout: str
    stderr: str


def run(argv: Sequence[str], paths: Paths, *, stdin: Optional[str] = None, timeout: float = 20.0,
        env: Optional[dict] = None) -> RunResult:
    """Run one owner script. A spawn failure or timeout reports code 0 and no
    output, the fail-open reading every hook adapter in this repository uses."""
    try:
        proc = subprocess.run(
            list(argv),
            input=stdin,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=str(paths.root),
            env=env or script_env(paths),
        )
        return RunResult(proc.returncode, proc.stdout or "", proc.stderr or "")
    except (OSError, subprocess.SubprocessError, ValueError):
        return RunResult(0, "", "")


def file_version(path: Path) -> str:
    """The loaded-build digest, byte-identical to fm_pi_extension_version in
    bin/fm-wake-lib.sh (sha256 of the file contents)."""
    try:
        return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return ""


def encode_operational(paths: Paths, kind: str, body: str) -> str:
    result = run([str(paths.bin / "fm-operational-input.sh"), "encode", kind], paths, stdin=body, timeout=10)
    if result.code == 0 and result.stdout:
        return result.stdout.rstrip("\n")
    return f"{OPERATIONAL_PREFIX}{OPERATIONAL_VERSION} {kind}: {body}"


def operational_kind(paths: Paths, text: str) -> str:
    """The current operational kind of text, or "" for captain-authored text."""
    if not isinstance(text, str) or OPERATIONAL_PREFIX not in text[:64]:
        return ""
    head = text.lstrip()
    if not head.startswith(OPERATIONAL_PREFIX):
        return ""
    rest = head[len(OPERATIONAL_PREFIX):]
    if rest.startswith(OPERATIONAL_VERSION + " "):
        kind = rest[len(OPERATIONAL_VERSION) + 1:].split(":", 1)[0].strip()
        if kind and " " not in kind:
            return kind
    return ""


def _parent_pid(pid: int) -> int:
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=5).stdout.strip()
        return int(out) if out.isdigit() else 0
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0


def pid_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


def lock_owner_pid(paths: Paths) -> int:
    """The recorded lock pid when it is this process or one of its ancestors,
    else this process's own pid. The Ink TUI runs the plugin in a gateway child
    of the process a looser ancestry walk could record, so markers bind to the
    recorded owner rather than assuming it is os.getpid()."""
    try:
        text = (paths.state / ".lock").read_text(encoding="utf-8").strip().splitlines()[0]
    except (OSError, IndexError):
        return os.getpid()
    if not text.isdigit():
        return os.getpid()
    lock_pid, pid = int(text), os.getpid()
    for _ in range(8):
        if pid == lock_pid:
            return lock_pid
        pid = _parent_pid(pid)
        if pid <= 1:
            break
    return os.getpid()


def lock_ownership(paths: Paths) -> str:
    """owned | missing | other - the same eight-parent reading the Pi and omp
    extensions use. The Hermes process itself is the recorded lock owner
    (bin/fm-session-lock-lib.sh identifies it through bin/fm-hermes-lib.sh)."""
    try:
        lock_pid_text = (paths.state / ".lock").read_text(encoding="utf-8").strip().splitlines()[0]
    except (OSError, IndexError):
        return "missing"
    if not lock_pid_text.isdigit() or lock_pid_text == "1":
        return "other"
    lock_pid = int(lock_pid_text)
    pid = os.getpid()
    for _ in range(8):
        if pid == lock_pid:
            return "owned"
        pid = _parent_pid(pid)
        if pid <= 1:
            break
    return "other" if pid_alive(lock_pid) else "missing"


def write_marker(paths: Paths, name: str, version: str, extra: Optional[str] = None) -> None:
    """Record which build this process loaded, unless another live session owns
    the home (bin/fm-wake-lib.sh fm_extension_pair_owns_supervision reads it)."""
    try:
        if not paths.state.is_dir() or lock_ownership(paths) == "other":
            return
        lines = [version, str(lock_owner_pid(paths))]
        if extra:
            lines.append(extra)
        tmp = paths.state / f".{name}.tmp-{os.getpid()}"
        tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.replace(tmp, paths.state / name)
    except OSError:
        pass


def primary_scope(paths: Paths) -> bool:
    """True only in a genuine primary home (main or secondmate), never in a
    task worktree, a no-mistakes gate checkout, or a non-Firstmate repo. The
    shell owners decide; this only asks them."""
    script = (
        '. "$1/bin/fm-gate-refuse-lib.sh" && . "$1/bin/fm-primary-scope-lib.sh" || exit 1; '
        'fm_is_gate_agent "$1" && exit 3; fm_primary_scope_matches "$1" "$2"'
    )
    try:
        proc = subprocess.run(["bash", "-c", script, "fm-hermes-scope", str(paths.root), str(paths.state)],
                              capture_output=True, text=True, timeout=15, cwd=str(paths.root),
                              env=script_env(paths))
        return proc.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False
