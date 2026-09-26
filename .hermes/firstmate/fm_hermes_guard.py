"""Turn-end guard and pre-tool seatbelts for a Hermes primary.

docs/turnend-guard.md owns the "no turn ends blind" contract and
bin/fm-turnend-guard.sh owns the predicate; docs/arm-pretool-check.md,
docs/cd-guard.md, and docs/subagent-guard.md own the seatbelt policies. This
module only adapts Hermes's hook surface to those owners:

  * Hermes has no general stop hook. ``on_session_end`` fires at the end of
    EVERY turn (agent/turn_finalizer.py) but cannot veto it, so this is a
    passive adapter like Pi's: at each turn end it first lets the watcher owner
    self-heal (arm when this process owns the lock but holds no arm child),
    then asks the shared guard, and when the guard still returns 2 it schedules
    exactly one bounded ``turn-end-guard`` follow-up turn through idle
    delivery. The latch holds until that follow-up's own turn ends, whose stop
    is then reported to the guard with ``stop_hook_active`` true, so one
    unhealthy boundary can never become a loop.
  * ``pre_verify`` is Hermes's one continuation hook, and it fires only for a
    turn that landed a file edit. When it fires it compels the continuation
    inside the same turn (``{"action": "continue", ...}``), bounded by Hermes's
    own ``agent.max_verify_nudges`` and by ``stop_hook_active`` on the retry,
    and it consumes that turn's follow-up latch so the two paths never both
    nudge one boundary.
  * An interrupted turn is deliberately unguarded, exactly as omp's
    ``session_stop`` is: ``bin/fm-control.sh`` owns that postcondition.
  * ``pre_tool_call`` blocks by returning ``{"action": "block", "message":
    ...}``; the message becomes the tool result the model sees. The terminal
    tool's ``command`` is forwarded to the cd and watcher-arm checkers with
    ``--command`` (and the compatibility-only ``--background`` flag), and every
    tool name is forwarded to the delegation checker with ``--tool``.
"""

from __future__ import annotations

import threading
from pathlib import Path
from typing import Optional

from fm_hermes_common import Paths, encode_operational, file_version, run, write_marker

MARKER = ".hermes-turnend-plugin-loaded"
GUARD_HEADLINE = ("TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. "
                  "Follow the harness recovery instruction below before ending the turn.\n\n")
SHELL_TOOLS = {"terminal"}
# Wait this long at a turn boundary for a just-started arm to confirm, so the
# guard judges the cycle the self-heal brought up rather than the gap before it.
ARM_SETTLE_SECONDS = 10.0


class Guard:
    def __init__(self, paths: Paths, delivery, watch, source_file: Path):
        self.paths = paths
        self.delivery = delivery
        self.watch = watch
        self.version = file_version(source_file)
        self._lock = threading.Lock()
        # True from the moment a follow-up is scheduled until its own turn ends.
        self._followup_pending = False
        self._followup_turn = False
        self._verify_nudged = False
        self._subagent_cache: dict = {}

    def mark_loaded(self) -> None:
        write_marker(self.paths, MARKER, self.version)

    # -- turn bracket ------------------------------------------------------------

    def turn_started(self, user_message) -> None:
        text = user_message if isinstance(user_message, str) else ""
        with self._lock:
            self._verify_nudged = False
            self._followup_turn = self._followup_pending and "v1 turn-end-guard:" in text[:96]

    def _run_guard(self, stop_hook_active: bool):
        import json

        return run([str(self.paths.bin / "fm-turnend-guard.sh")], self.paths,
                   stdin=json.dumps({"stop_hook_active": stop_hook_active}), timeout=25)

    def _guard_text(self, stderr: str) -> str:
        return encode_operational(self.paths, "turn-end-guard", GUARD_HEADLINE + stderr)

    def on_session_end(self, interrupted: bool = False) -> None:
        with self._lock:
            followup_turn = self._followup_turn
            nudged = self._verify_nudged
            self._followup_turn = False
            if followup_turn:
                self._followup_pending = False
        if interrupted:
            return
        self.watch.ensure()
        arm = getattr(self.watch, "_arm", None)
        if arm is not None:
            arm.ready.wait(timeout=ARM_SETTLE_SECONDS)
        result = self._run_guard(stop_hook_active=followup_turn or nudged)
        # The follow-up's own stop is the bound: whatever the guard answers, it
        # never schedules another follow-up, exactly as a true stop_hook_active
        # lets Claude's and Codex's second stop finish.
        if result.code != 2 or followup_turn:
            return
        with self._lock:
            if self._followup_pending:
                return
            self._followup_pending = True
        if not self.delivery.deliver(self._guard_text(result.stderr)):
            with self._lock:
                self._followup_pending = False

    def pre_verify(self, attempt: int = 0) -> Optional[dict]:
        with self._lock:
            already = self._verify_nudged or self._followup_turn
        result = self._run_guard(stop_hook_active=already or attempt > 0)
        if result.code != 2:
            return None
        with self._lock:
            self._verify_nudged = True
        return {"action": "continue", "message": self._guard_text(result.stderr)}

    # -- pre-tool seatbelts --------------------------------------------------------

    def _deny(self, stderr: str, fallback: str) -> dict:
        return {"action": "block", "message": stderr.strip() or fallback}

    def pre_tool_call(self, tool_name: str, args) -> Optional[dict]:
        name = tool_name if isinstance(tool_name, str) else ""
        if not name:
            return None
        verdict = self._subagent_cache.get(name)
        if verdict is None:
            result = run([str(self.paths.bin / "fm-subagent-pretool-check.sh"), "--tool", name], self.paths,
                         timeout=15)
            verdict = result.stderr if result.code == 2 else ""
            self._subagent_cache[name] = verdict
        if verdict:
            return self._deny(verdict, "denied by the delegation PreToolUse seatbelt")
        if name not in SHELL_TOOLS or not isinstance(args, dict):
            return None
        command = args.get("command")
        if not isinstance(command, str) or not command:
            return None
        cd = run([str(self.paths.bin / "fm-cd-pretool-check.sh"), "--command", command], self.paths, timeout=15)
        if cd.code == 2:
            return self._deny(cd.stderr, "denied by the cd-guard PreToolUse seatbelt")
        argv = [str(self.paths.bin / "fm-arm-pretool-check.sh"), "--command", command]
        if args.get("background"):
            argv.append("--background")
        arm = run(argv, self.paths, timeout=15)
        if arm.code == 2:
            return self._deny(arm.stderr, "denied by the watcher-arm PreToolUse seatbelt")
        return None
