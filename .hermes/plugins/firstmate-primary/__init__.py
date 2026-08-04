"""Hermes primary-session adapter for Firstmate."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
from typing import Any


_ROOT = Path(__file__).resolve().parents[3]
_RETRY_PREFIX = "[firstmate-supervision-repair-v1]"
_MARKER_NAME = ".hermes-primary-plugin-loaded"
_DELEGATION_TOOLS = {"delegate_task"}
_pending_retries: set[str] = set()
_retry_lock = threading.Lock()


def _state_dir() -> Path:
    override = os.environ.get("FM_STATE_OVERRIDE", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    home = os.environ.get("FM_HOME", "").strip()
    return (Path(home).expanduser().resolve() if home else _ROOT) / "state"


def _persistent_cli_launch() -> bool:
    args = sys.argv[1:]
    if "-z" in args or "--oneshot" in args or any(
        arg.startswith("--oneshot=") for arg in args
    ):
        return False
    if "--cli" in args:
        return True
    profile = None
    for index, arg in enumerate(args):
        if arg in {"-p", "--profile"}:
            profile = args[index + 1] if index + 1 < len(args) else None
        elif arg.startswith("--profile="):
            profile = arg.split("=", 1)[1]
    return profile == "firstmate" and "--tui" in args


def _primary_scope_matches() -> bool:
    if not _persistent_cli_launch():
        return False
    try:
        if Path.cwd().resolve() != _ROOT:
            return False
    except OSError:
        return False
    state = _state_dir()
    scope_lib = _ROOT / "bin" / "fm-primary-scope-lib.sh"
    if not scope_lib.is_file() or not state.is_dir():
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


def _write_loaded_marker() -> None:
    marker = _state_dir() / _MARKER_NAME
    tmp = marker.with_name(f"{marker.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(f"{_marker_digest()}\n{os.getpid()}\n", encoding="utf-8")
        os.replace(tmp, marker)
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass


def _remove_loaded_marker() -> None:
    marker = _state_dir() / _MARKER_NAME
    try:
        lines = marker.read_text(encoding="utf-8").splitlines()
        if len(lines) >= 2 and lines[1] == str(os.getpid()):
            marker.unlink()
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

    _write_loaded_marker()

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

    def post_llm_call(
        session_id: str = "",
        user_message: str = "",
        platform: str = "",
        **kwargs: Any,
    ) -> None:
        del kwargs
        if not _primary_scope_matches() or platform != "cli":
            return

        sid = str(session_id or "")
        message = str(user_message or "")
        if message.startswith(_RETRY_PREFIX):
            with _retry_lock:
                _pending_retries.discard(sid)
            return

        with _retry_lock:
            if sid in _pending_retries:
                return

        result = _run_checker(
            _ROOT / "bin" / "fm-turnend-guard.sh",
            payload=json.dumps({"stop_hook_active": False}),
        )
        if result is None or result.returncode != 2:
            return

        reason = (result.stderr or "").strip()
        recovery = (
            f"{_RETRY_PREFIX}\n"
            "This is the one bounded Hermes turn-end recovery retry. "
            "Drain queued wakes first, then restore watcher supervision through "
            "Hermes terminal(background=true, notify_on_complete=true) exactly "
            "as the session-start Hermes protocol directs. Do not use shell &.\n\n"
            f"{reason[:3500]}"
        )
        with _retry_lock:
            _pending_retries.add(sid)
        if not ctx.inject_message(recovery, role="user"):
            with _retry_lock:
                _pending_retries.discard(sid)

    def on_session_finalize(**kwargs: Any) -> None:
        del kwargs
        _remove_loaded_marker()

    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_hook("post_llm_call", post_llm_call)
    ctx.register_hook("on_session_finalize", on_session_finalize)
