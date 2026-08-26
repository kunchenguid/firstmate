"""Hermes primary-session adapter for Firstmate."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from typing import Any


_ROOT = Path(__file__).resolve().parents[3]
_MARKER_NAME = ".hermes-primary-plugin-loaded"
_DELEGATION_TOOLS = {"delegate_task"}
_pending_retries: set[str] = set()
_retry_lock = threading.Lock()


def _state_dir() -> Path:
    override = os.environ.get("FM_STATE_OVERRIDE", "").strip()
    if override:
        return Path(os.path.abspath(os.path.expanduser(override)))
    home = os.environ.get("FM_HOME", "").strip()
    base = Path(os.path.abspath(os.path.expanduser(home))) if home else _ROOT
    return base / "state"


def _ensure_state_dir(state: Path) -> bool:
    try:
        if state.is_symlink():
            return False
        state.mkdir(parents=True, exist_ok=True)
        return state.is_dir() and not state.is_symlink()
    except OSError:
        return False


def _persistent_cli_launch() -> bool:
    args = sys.argv[1:]
    cli = False
    rooted = False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-m", "--model", "--provider", "--reasoning", "-r", "--resume", "-s", "--skills"}:
            index += 1
            if index >= len(args) or not args[index]:
                return False
        elif arg.startswith(("--model=", "--provider=", "--reasoning=", "--resume=", "--skills=")):
            if not arg.partition("=")[2]:
                return False
        elif arg in {"-c", "--continue"}:
            if index + 1 < len(args) and not args[index + 1].startswith("-"):
                index += 1
        elif arg.startswith("--continue="):
            if not arg.partition("=")[2]:
                return False
        elif arg == "--cli":
            cli = True
        elif arg == "--no-restore-cwd":
            rooted = True
        elif arg not in {"--accept-hooks", "--yolo", "--pass-session-id"}:
            return False
        index += 1
    return (
        cli
        and rooted
        and os.environ.get("FM_HERMES_PRIMARY_POLICY") == "pi-herdr-v1"
        and os.environ.get("FM_HERMES_PRIMARY_PID") == str(os.getpid())
    )


def _primary_scope_matches() -> bool:
    if not _persistent_cli_launch():
        return False
    try:
        if Path.cwd().resolve() != _ROOT:
            return False
    except OSError:
        return False
    state = _state_dir()
    canonical_state = _ROOT / "state"
    scope_lib = _ROOT / "bin" / "fm-primary-scope-lib.sh"
    if (
        not scope_lib.is_file()
        or not _ensure_state_dir(state)
        or not _ensure_state_dir(canonical_state)
    ):
        return False
    try:
        result = subprocess.run(
            [
                "bash",
                "-c",
                '. "$1"; fm_primary_scope_matches "$2" "$3"',
                "firstmate-hermes-scope",
                str(scope_lib),
                str(_ROOT),
                str(state),
            ],
            cwd=str(_ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def _marker_digest() -> str:
    return "sha256:" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def _process_identity() -> str | None:
    identity_lib = _ROOT / "bin" / "fm-process-identity-lib.sh"
    try:
        result = subprocess.run(
            [
                "bash",
                "-c",
                '. "$1"; fm_pid_identity "$2"',
                "firstmate-hermes-identity",
                str(identity_lib),
                str(os.getpid()),
            ],
            cwd=str(_ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    identity = result.stdout.rstrip("\n")
    if result.returncode != 0 or not identity or "\n" in identity:
        return None
    return identity


def _live_marker_owner(state: Path) -> int | None:
    process_lib = _ROOT / "bin" / "fm-harness-process-lib.sh"
    try:
        result = subprocess.run(
            [
                "bash",
                "-c",
                '. "$1"; pid=$(fm_hermes_marker_pid "$2" "$3") && '
                'fm_process_is_hermes_primary_pid "$pid" "$2" "$3" && printf "%s" "$pid"',
                "firstmate-hermes-marker-owner",
                str(process_lib),
                str(state),
                str(_ROOT),
            ],
            cwd=str(_ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return int(result.stdout) if result.returncode == 0 else None
    except ValueError:
        return None


def _write_loaded_marker() -> None:
    identity = _process_identity()
    if identity is None:
        return
    payload = f"{_marker_digest()}\n{os.getpid()}\n{_ROOT}\n{identity}\n"
    canonical_state = _ROOT / "state"
    lock_path = canonical_state / ".hermes-primary-marker.lock"
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        lock_fd = os.open(lock_path, flags, 0o600)
    except OSError:
        return
    with os.fdopen(lock_fd, "r+") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        owner = _live_marker_owner(canonical_state)
        if owner is not None and owner != os.getpid():
            return
        for state in {_state_dir(), canonical_state}:
            marker = state / _MARKER_NAME
            tmp = marker.with_name(f"{marker.name}.{os.getpid()}.tmp")
            try:
                tmp.write_text(payload, encoding="utf-8")
                os.replace(tmp, marker)
            except OSError:
                try:
                    tmp.unlink()
                except OSError:
                    pass


def _run_checker(path: Path, *args: str, payload: str | None = None) -> subprocess.CompletedProcess[str] | None:
    if not path.is_file():
        return None
    env = os.environ.copy()
    env["FM_ROOT_OVERRIDE"] = str(_ROOT)
    env.setdefault("FM_HOME", str(_ROOT))
    try:
        return subprocess.run(
            [str(path), *args],
            cwd=str(_ROOT),
            env=env,
            input=payload,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def register(ctx: Any) -> None:
    """Register hooks only in the real Firstmate primary CLI."""
    if not _primary_scope_matches():
        return

    def pre_tool_call(tool_name: str, args: dict[str, Any], **kwargs: Any) -> dict[str, str] | None:
        del kwargs
        if not _primary_scope_matches():
            return None
        if tool_name in _DELEGATION_TOOLS:
            return {
                "action": "block",
                "message": (
                    "Hermes built-in delegation is disabled in the Firstmate primary. "
                    "Use Firstmate's bin/fm-spawn.sh path to dispatch a visible crewmate."
                ),
            }
        if tool_name != "terminal" or not isinstance(args, dict):
            return None
        command = args.get("command")
        if not isinstance(command, str) or not command:
            return None
        if "fm-watch-arm.sh" in command and (
            args.get("background") is not True
            or args.get("notify_on_complete") is not True
        ):
            return {
                "action": "block",
                "message": (
                    "Hermes watcher supervision requires terminal(background=true, "
                    "notify_on_complete=true); use the managed terminal registry."
                ),
            }
        result = _run_checker(
            _ROOT / "bin" / "fm-arm-pretool-check.sh",
            "--command",
            command,
            "--background",
            str(bool(args.get("background", False))).lower(),
        )
        if result is None or result.returncode != 2:
            return None
        reason = (result.stderr or result.stdout or "unsafe watcher command shape").strip()
        return {"action": "block", "message": reason[:2000]}

    def on_session_end(
        session_id: str = "",
        platform: str = "",
        **kwargs: Any,
    ) -> None:
        del kwargs
        if not _primary_scope_matches() or platform != "cli":
            return

        sid = str(session_id or "")
        with _retry_lock:
            if sid in _pending_retries:
                _pending_retries.discard(sid)
                return

        result = _run_checker(
            _ROOT / "bin" / "fm-turnend-guard.sh",
            payload=json.dumps({"stop_hook_active": False}),
        )
        if result is None or result.returncode != 2:
            return

        reason = (result.stderr or "").strip()
        body = (
            "This is the one bounded Hermes turn-end recovery retry. "
            "Drain queued wakes first, then restore watcher supervision through "
            "Hermes terminal(background=true, notify_on_complete=true) exactly "
            "as the session-start Hermes protocol directs. Do not use shell &.\n\n"
            f"{reason[:3500]}"
        )
        encoded = _run_checker(
            _ROOT / "bin" / "fm-operational-input.sh",
            "encode",
            "turn-end-guard",
            payload=body,
        )
        if encoded is None or encoded.returncode != 0 or not encoded.stdout:
            return
        with _retry_lock:
            _pending_retries.add(sid)
        if not ctx.inject_message(encoded.stdout, role="user"):
            with _retry_lock:
                _pending_retries.discard(sid)

    def on_session_finalize(session_id: str = "", **kwargs: Any) -> None:
        del kwargs
        with _retry_lock:
            _pending_retries.discard(str(session_id or ""))

    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("on_session_end", on_session_end)
    ctx.register_hook("on_session_finalize", on_session_finalize)
    _write_loaded_marker()
