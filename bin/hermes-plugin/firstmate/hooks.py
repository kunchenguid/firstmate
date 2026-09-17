"""Firstmate hook implementations.

All hooks are wrapped in try/except and fail open — a broken hook must never
crash the agent session. Each returns the Hermes-expected contract or None.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

_FM_HOME = Path(os.environ.get("FM_HOME", "/home/m7r/kun-agent-workspace"))
_STATE_DIR = _FM_HOME / "state"
_SESSION_START_SCRIPT = _FM_HOME / "bin" / "fm-session-start.sh"

# Cache files
_CACHE_FILE = _STATE_DIR / ".firstmate-session-start-cache"
_WAKE_QUEUE_FILE = _STATE_DIR / ".wake-queue"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run_session_start() -> str:
    """Run fm-session-start.sh and return its stdout (or "" on failure)."""
    try:
        result = subprocess.run(
            [str(_SESSION_START_SCRIPT)],
            capture_output=True,
            text=True,
            timeout=60,
            cwd=str(_FM_HOME),
        )
        return result.stdout.strip()
    except Exception:
        return ""


def _write_cache(text: str) -> None:
    """Write digest text to the session-start cache file."""
    try:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        _CACHE_FILE.write_text(text)
    except Exception:
        pass


def _read_cache() -> str:
    """Read the cached session-start digest (or "" if missing)."""
    try:
        return _CACHE_FILE.read_text().strip()
    except Exception:
        return ""


def _injection_marker(session_id: str) -> Path:
    """Return the per-session injection marker path."""
    return _STATE_DIR / f".firstmate-digest-injected-{session_id}"


def _is_injected(session_id: str) -> bool:
    """True if the digest was already injected this session."""
    try:
        return _injection_marker(session_id).exists()
    except Exception:
        return False


def _mark_injected(session_id: str) -> None:
    """Mark the digest as injected for this session."""
    try:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        _injection_marker(session_id).touch()
    except Exception:
        pass


def _wake_queue_active() -> bool:
    """True if the wake queue exists and has content."""
    try:
        if not _WAKE_QUEUE_FILE.exists():
            return False
        content = _WAKE_QUEUE_FILE.read_text().strip()
        return bool(content)
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------


def on_session_start(**kwargs) -> None:
    """Run fm-session-start.sh on session start and cache its output."""
    try:
        digest = _run_session_start()
        _write_cache(digest)
    except Exception:
        pass
    return None


def on_session_reset(**kwargs) -> None:
    """Run fm-session-start.sh on session reset and cache its output."""
    try:
        digest = _run_session_start()
        _write_cache(digest)
    except Exception:
        pass
    return None


def pre_llm_call(session_id: str | None = None, **kwargs):
    """Inject the cached session-start digest into the first LLM call.

    Returns {"context": <cached_text>} on the first call of a session, then
    None on all subsequent calls (tracked via a per-session marker file).
    """
    try:
        if not session_id:
            return None

        if _is_injected(session_id):
            return None

        cached = _read_cache()
        if not cached:
            return None

        _mark_injected(session_id)
        return {"context": cached}
    except Exception:
        return None


def pre_verify(**kwargs):
    """Prevent blind stops while fleet work is active.

    If the wake queue has pending items, force the turn to continue so the
    agent can process fleet events instead of stopping.
    """
    try:
        if _wake_queue_active():
            return {
                "action": "continue",
                "message": "Firstmate: fleet wake pending.",
            }
        return None
    except Exception:
        return None
