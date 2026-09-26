"""Run-tier session-start delivery for a Hermes primary.

docs/sessionstart-nudge.md owns the tier contract; bin/fm-sessionstart-run.sh
owns source routing, eligibility, and the digest itself. This module is only
the Hermes transport, and it differs from the Pi/omp shape in exactly the ways
the Hermes hook surface forces:

  * Hermes fires ``on_session_start`` lazily on the first turn and never for a
    resumed session, so the digest instead starts when the plugin loads, which
    is process start, before the captain can type. The first ``pre_llm_call``
    of each session awaits it and returns it as ``{"context": ...}``, which
    Hermes appends to that user message before the first provider call.
  * Hermes bounds ``pre_llm_call`` by ``plugins.hook_callback_timeout``
    (default 30s) and abandons a callback that overruns. The wait here stays
    below that bound; a digest still running when it expires leaves an
    operational notice instead, and the finished digest rides the next turn's
    ``pre_llm_call`` or, when the session is idle, an injected message.
  * ``/new`` (``on_session_reset``) is an in-process replacement: the lock is
    still ours and only the context is gone, so it maps to ``clear``.
  * Hermes has no compaction hook. Instead the first ``pre_llm_call`` of every
    later turn checks whether the delivered digest still survives in the
    conversation it is handed; once compaction has summarised it away the
    source is ``compact``, whose wrapper contract re-emits the digest only for
    a lock owner that completed a full startup.
  * Context over ``hooks.output_spill.max_chars`` is spilled to a file with a
    head/tail preview. The encoded digest starts with the operational marker,
    so the preview stays classifiable, and AGENTS.md section 3 already directs
    the agent to read a persisted digest file in full.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from typing import Callable, Optional

from fm_hermes_common import OPERATIONAL_PREFIX, Paths, encode_operational, script_env

DELIVERY_BYTES = 512 * 1024
INELIGIBLE_EXIT = 3
MANUAL_FALLBACK = "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions."
TRUNCATED_MARKER = (
    "\n\nHERMES SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. "
    "Treat omitted context as unread and inspect the named files directly before acting on it."
)
PENDING_NOTICE = (
    "Firstmate session start is still running inside the Hermes plugin and has not finished yet. "
    "Its digest will be delivered automatically as soon as it completes. "
    "Do not run `bin/fm-session-start.sh` yourself, and stay read-only for fleet work until the digest arrives."
)
# The delivered digest's own operational header; its presence anywhere in the
# conversation Hermes hands pre_llm_call proves the digest is still in context.
DIGEST_NEEDLE = OPERATIONAL_PREFIX + "v1 session-start:"


def launch_resume_source(argv: Optional[list] = None) -> Optional[str]:
    """``resume`` when the Hermes launch line restored a prior session."""
    for arg in (argv if argv is not None else sys.argv[1:]):
        if arg in ("-c", "--continue", "-r", "--resume") or arg.startswith("--resume=") \
                or arg.startswith("--continue="):
            return "resume"
    return None


@dataclass
class Generation:
    id: int
    source: str
    done: threading.Event = field(default_factory=threading.Event)
    kind: str = "pending"  # ready | empty | failed | ineligible | cancelled
    raw: str = ""
    delivered: bool = False
    stopping: bool = False
    # Set once a bounded pre_llm_call wait expired: the finished digest is then
    # handed to idle delivery instead of waiting for the next turn.
    late: bool = False
    proc: Optional[subprocess.Popen] = None
    claim_lock: threading.Lock = field(default_factory=threading.Lock)


class SessionStart:
    def __init__(self, paths: Paths, deliver_idle: Callable[[str], bool], wait_seconds: float):
        self.paths = paths
        self.deliver_idle = deliver_idle
        self.wait_seconds = wait_seconds
        self._lock = threading.Lock()
        self._next_id = 0
        self._active: Optional[Generation] = None
        # Session ids whose context received a digest this process, so a later
        # turn can tell "compacted away" from "never delivered here".
        self._delivered_sessions: set = set()
        self._first_turn_seen: set = set()

    # -- generation lifecycle ------------------------------------------------

    def start(self, source: str) -> Generation:
        with self._lock:
            previous = self._active
            self._next_id += 1
            generation = Generation(id=self._next_id, source=source)
            self._active = generation
        if previous is not None:
            self._stop(previous)
        threading.Thread(target=self._run, args=(generation,), name=f"fm-sessionstart-{generation.id}",
                         daemon=True).start()
        return generation

    def _live(self, generation: Generation) -> bool:
        return self._active is generation and not generation.stopping

    def _stop(self, generation: Generation) -> None:
        generation.stopping = True
        proc = generation.proc
        if proc is None or proc.poll() is not None:
            return
        for sig, wait in ((signal.SIGTERM, 1.0), (signal.SIGKILL, 1.0)):
            try:
                os.killpg(proc.pid, sig)
            except (OSError, AttributeError):
                try:
                    proc.send_signal(sig)
                except OSError:
                    pass
            try:
                proc.wait(timeout=wait)
                return
            except subprocess.TimeoutExpired:
                continue

    def shutdown(self) -> None:
        generation = self._active
        if generation is not None:
            self._stop(generation)

    def _run(self, generation: Generation) -> None:
        runner = str(self.paths.bin / "fm-sessionstart-run.sh")
        try:
            # Its own session and process group, so replacement and shutdown can
            # retire the whole digest tree, while the parent pid stays this
            # Hermes process: bin/fm-lock.sh finds the session owner by ancestry.
            proc = subprocess.Popen(
                [runner, "--source", generation.source, "--pi-prerequisite"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                cwd=str(self.paths.root), env=script_env(self.paths), start_new_session=True,
            )
        except OSError:
            self._settle(generation, "cancelled" if generation.stopping else "failed")
            return
        generation.proc = proc
        chunks = []
        retained = 0
        truncated = False
        assert proc.stdout is not None
        while True:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            if retained >= DELIVERY_BYTES:
                truncated = True
                continue
            keep = chunk[: DELIVERY_BYTES - retained]
            if len(keep) != len(chunk):
                truncated = True
            chunks.append(keep)
            retained += len(keep)
        code = proc.wait()
        if generation.stopping:
            self._settle(generation, "cancelled")
            return
        if code == INELIGIBLE_EXIT:
            self._settle(generation, "ineligible")
            return
        if code != 0:
            self._settle(generation, "failed")
            return
        raw = b"".join(chunks).decode("utf-8", "replace").strip()
        if not raw:
            self._settle(generation, "empty")
            return
        self._settle(generation, "ready", raw + (TRUNCATED_MARKER if truncated else ""))

    def _settle(self, generation: Generation, kind: str, raw: str = "") -> None:
        generation.kind = kind
        generation.raw = raw
        generation.done.set()
        # A digest that finished after the first turn's bounded wait is
        # delivered as soon as the session is idle, never mid-turn.
        if not generation.late or not self._live(generation):
            return
        with generation.claim_lock:
            if generation.delivered:
                return
            message = self.message(generation)
            if message and self.deliver_idle(message):
                generation.delivered = True

    # -- delivery -------------------------------------------------------------

    def message(self, generation: Generation) -> str:
        raw = generation.raw if generation.kind == "ready" else ""
        if not raw and generation.kind == "failed":
            raw = MANUAL_FALLBACK
        elif not raw and generation.kind == "empty" and generation.source in ("startup", "clear", "compact"):
            raw = MANUAL_FALLBACK
        if not raw:
            return ""
        # The wrapper already returns an encoded nudge on a context-preserving
        # open, so only an unencoded digest or fallback needs the marker added.
        if raw.lstrip().startswith(OPERATIONAL_PREFIX):
            return raw
        return encode_operational(self.paths, "session-start", raw)

    def _claim(self, generation: Generation, wait: float) -> Optional[str]:
        """The message for this generation, waiting at most ``wait`` seconds.
        None means still pending; "" means nothing to deliver."""
        if not generation.done.wait(timeout=max(0.0, wait)):
            return None
        with generation.claim_lock:
            if not self._live(generation) or generation.delivered:
                return ""
            generation.delivered = True
            return self.message(generation)

    def pre_llm_call(self, session_id: str, conversation_history) -> Optional[str]:
        generation = self._active
        if generation is None:
            return None
        if not generation.delivered:
            message = self._claim(generation, self.wait_seconds)
            if message is None:
                generation.late = True
                return encode_operational(self.paths, "session-start", PENDING_NOTICE)
            if message:
                if session_id:
                    self._delivered_sessions.add(session_id)
                return message
            return None
        # Already delivered: re-emit only when compaction removed the digest from
        # the context of a session that received it here.
        if session_id and session_id in self._delivered_sessions and not history_has_digest(conversation_history):
            generation = self.start("compact")
            message = self._claim(generation, self.wait_seconds)
            if message is None:
                generation.late = True
                return None
            return message or None
        return None

    def on_session_reset(self) -> None:
        self.start("clear")


def _message_text(message) -> str:
    if not isinstance(message, dict):
        return ""
    parts = []
    for key in ("api_content", "content"):
        value = message.get(key)
        if isinstance(value, str):
            parts.append(value)
        elif isinstance(value, list):
            for part in value:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    parts.append(part["text"])
    return "\n".join(parts)


def history_has_digest(conversation_history) -> bool:
    if not isinstance(conversation_history, list):
        return True  # unreadable history: never re-run speculatively
    for message in conversation_history:
        if DIGEST_NEEDLE in _message_text(message):
            return True
    return False


def wait_budget() -> float:
    """Stay under Hermes's own hook timeout so the wait is never abandoned."""
    configured = os.environ.get("FM_HERMES_SESSIONSTART_WAIT_SECS", "").strip()
    timeout = 30.0
    try:
        from hermes_cli.plugins import _resolve_hook_callback_timeout  # type: ignore

        timeout = float(_resolve_hook_callback_timeout())
    except Exception:  # noqa: BLE001
        pass
    budget = timeout - 5.0 if timeout > 0 else 110.0
    if configured:
        try:
            budget = min(float(configured), budget)
        except ValueError:
            pass
    return max(1.0, budget)
