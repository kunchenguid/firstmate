"""Idle-aware message delivery into a Hermes primary session.

``PluginContext.inject_message`` is the only way a plugin can start a turn,
and its classic-CLI path has one hazard this module exists to contain: while
the agent is running, the text goes onto the CLI's interrupt queue and
INTERRUPTS the current turn (hermes_cli/plugins.py inject_message, verified
v0.21.5). A watcher wake must never cut into a turn the captain started, so a
message is held until the session is idle and only then injected, where it is
queued as the next user turn. The Ink TUI and desktop hosts instead queue an
injection for a busy session without interrupting, so there a message is
handed over at once, keyed by the live session id.

Idle is read from the CLI's own ``_agent_running`` flag when the CLI host is
attached, and otherwise from this plugin's turn bracket (``pre_llm_call``
opens a turn, ``on_session_end`` closes it). The bracket also covers the short
window after ``on_session_end`` returns and before the CLI clears its flag.

A message the host refuses (a TUI without
``plugins.entries.firstmate.allow_gateway_injection``) is kept and handed to
the next ``pre_llm_call`` as context instead, so an undeliverable wake still
reaches the model at the captain's next turn rather than vanishing; the
refusal itself is reported once so the setup gap is visible.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections import deque
from typing import Callable, Deque, List, Optional

logger = logging.getLogger("hermes_plugins.firstmate")

POLL_SECONDS = 0.2
# After a turn closes, wait this long before treating the session as idle, so
# the CLI's own post-turn bookkeeping (and its _agent_running reset) finishes.
SETTLE_SECONDS = 0.5


class IdleDelivery:
    def __init__(self, ctx, on_delivered: Optional[Callable[[str], None]] = None):
        self._ctx = ctx
        self._on_delivered = on_delivered
        self._lock = threading.Lock()
        self._queue: Deque[str] = deque()
        self._fallback: List[str] = []
        self._busy = False
        self._closed_at = -SETTLE_SECONDS
        self._session_id = ""
        self._refusal_reported = False
        self._wake = threading.Event()
        self._stopped = False
        self._thread = threading.Thread(target=self._loop, name="fm-hermes-delivery", daemon=True)
        self._thread.start()

    # -- turn bracket ---------------------------------------------------------

    def turn_started(self, session_id: str = "") -> None:
        with self._lock:
            self._busy = True
            if session_id:
                self._session_id = session_id

    def turn_ended(self, session_id: str = "") -> None:
        with self._lock:
            self._busy = False
            self._closed_at = time.monotonic()
            if session_id:
                self._session_id = session_id
        self._wake.set()

    def note_session(self, session_id: str) -> None:
        if session_id:
            with self._lock:
                self._session_id = session_id

    @property
    def busy(self) -> bool:
        return self._busy or self._cli_running()

    # -- public API -----------------------------------------------------------

    def deliver(self, content: str) -> bool:
        """Queue content for the next idle moment. Always accepts."""
        if not content:
            return False
        with self._lock:
            self._queue.append(content)
        self._wake.set()
        return True

    def take_fallback(self) -> str:
        """Messages the host refused, for the next pre_llm_call context."""
        with self._lock:
            items, self._fallback = self._fallback, []
        return "\n\n".join(items)

    def stop(self) -> None:
        self._stopped = True
        self._wake.set()

    # -- internals ------------------------------------------------------------

    def _cli(self):
        manager = getattr(self._ctx, "_manager", None)
        return getattr(manager, "_cli_ref", None) if manager is not None else None

    def _cli_running(self) -> bool:
        cli = self._cli()
        return bool(cli is not None and getattr(cli, "_agent_running", False))

    def _idle(self) -> bool:
        with self._lock:
            if self._busy:
                return False
            if time.monotonic() - self._closed_at < SETTLE_SECONDS:
                return False
        return not self._cli_running()

    def _loop(self) -> None:
        while not self._stopped:
            self._wake.wait(timeout=POLL_SECONDS)
            self._wake.clear()
            while not self._stopped:
                with self._lock:
                    if not self._queue:
                        break
                    content = self._queue[0]
                cli_attached = self._cli() is not None
                if cli_attached and not self._idle():
                    time.sleep(POLL_SECONDS)
                    continue
                accepted = self._inject(content, cli_attached)
                with self._lock:
                    if self._queue and self._queue[0] is content:
                        self._queue.popleft()
                    if not accepted:
                        self._fallback.append(content)
                if accepted and self._on_delivered is not None:
                    try:
                        self._on_delivered(content)
                    except Exception:  # noqa: BLE001
                        pass

    def _inject(self, content: str, cli_attached: bool) -> bool:
        try:
            if cli_attached:
                return bool(self._ctx.inject_message(content))
            with self._lock:
                session_id = self._session_id
            # Hermes publishes the live session id into its own environment
            # (gateway/session_context.py set_current_session_id), which covers a
            # wake that arrives before the first turn told this plugin the id.
            session_id = session_id or os.environ.get("HERMES_SESSION_ID", "")
            if not session_id:
                return False
            accepted = bool(self._ctx.inject_message(content, session_key=session_id))
            if not accepted and not self._refusal_reported:
                self._refusal_reported = True
                logger.warning(
                    "firstmate: Hermes refused a background injection; run `hermes config set "
                    "plugins.entries.firstmate.allow_gateway_injection true` (bin/fm-hermes-plugin.sh "
                    "install does this) or use the classic CLI (`hermes --cli`). Refused wakes ride the "
                    "next turn's context instead.")
            return accepted
        except Exception:  # noqa: BLE001
            logger.warning("firstmate: inject_message failed", exc_info=True)
            return False
