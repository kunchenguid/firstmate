"""Semantic busy state and turn-end signal for a Hermes task worker.

bin/fm-busy-lib.sh owns the busy-state record and its classification;
bin/fm-busy-event.sh is its only writer. This module is the Hermes adapter,
source ``hermes-plugin``, active only when bin/fm-spawn.sh launched this Hermes
process as a worker (``FM_HERMES_ROLE=worker``) and handed it the armed
incarnation through the environment:

  FM_HERMES_STATE     the supervising home's state directory
  FM_HERMES_TASK      the task id
  FM_HERMES_BUSY_GEN  the incarnation gen minted by ``fm-busy-event.sh arm``
  FM_HERMES_TURNEND   the task's state/<id>.turn-ended marker

Hermes lifecycle mapping (agent/turn_context.py, agent/turn_finalizer.py,
tui_gateway/session_lifecycle.py; verified v0.21.5):

  pre_llm_call        once per user turn, before the first provider call -> busy
  post_tool_call      each tool completion inside a turn -> progress (throttled)
  on_session_end      the end of EVERY turn, interrupted or not -> idle, and the
                      turn-ended marker the watcher treats as a turn boundary
  agent_loop_stopped  a TUI user stop -> idle

A stale gen, a missing sidecar, or any writer refusal is fail-closed inside the
writer and ignored here, so a hook that outlives its incarnation can never
corrupt a replacement's record.
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

from fm_hermes_common import Paths

SOURCE = "hermes-plugin"
PROGRESS_INTERVAL = 5.0


class Worker:
    def __init__(self, paths: Paths):
        self.paths = paths
        self.state = os.environ.get("FM_HERMES_STATE", "")
        self.task = os.environ.get("FM_HERMES_TASK", "")
        self.gen = os.environ.get("FM_HERMES_BUSY_GEN", "")
        self.turnend = os.environ.get("FM_HERMES_TURNEND", "")
        self._lock = threading.Lock()
        self._last_progress: Optional[float] = None

    @property
    def active(self) -> bool:
        return bool(self.state and self.task and self.gen)

    def _event(self, *args: str) -> None:
        argv = [str(self.paths.bin / "fm-busy-event.sh"), *args]
        try:
            subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=10, cwd=str(self.paths.root))
        except (OSError, subprocess.SubprocessError):
            pass

    def _apply(self, new_state: str, event: str) -> None:
        if not self.active:
            return
        with self._lock:
            self._event("apply", self.state, self.task, new_state, "--gen", self.gen, "--source", SOURCE,
                        "--event", event)

    def turn_started(self) -> None:
        self._apply("busy", "turn-start")

    def progress(self) -> None:
        if not self.active:
            return
        now = time.monotonic()
        with self._lock:
            if self._last_progress is not None and now - self._last_progress < PROGRESS_INTERVAL:
                return
            self._last_progress = now
            self._event("progress", self.state, self.task, "--gen", self.gen)

    def turn_ended(self, interrupted: bool = False) -> None:
        self._apply("idle", "turn-abort" if interrupted else "turn-end")
        if self.turnend:
            try:
                Path(self.turnend).touch()
            except OSError:
                pass

    def stopped(self) -> None:
        self._apply("idle", "user-stop")
