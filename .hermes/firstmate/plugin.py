"""Firstmate plugin implementation for Hermes Agent.

Loaded by the stable loader in ``.hermes/plugins/firstmate/__init__.py`` from
the Firstmate checkout it resolved. Two roles, decided once at load:

  worker   ``FM_HERMES_ROLE=worker`` (set by bin/fm-spawn.sh for crewmates and
           scouts): semantic busy state and the turn-end marker only
           (fm_hermes_worker.py). No primary hook is registered.
  primary  anything else, but only inside a genuine primary home (main or
           secondmate), which the shell owners decide: session-start delivery
           (fm_hermes_sessionstart.py), plugin-owned watcher continuity
           (fm_hermes_watch.py), the turn-end guard and pre-tool seatbelts
           (fm_hermes_guard.py), the ``fm_watch_arm_hermes`` repair tool, and
           slash commands for the captain-invocable Firstmate skills.

A Firstmate root whose state directory does not exist yet (a fresh home before
its first session start) is not yet a primary scope. The plugin then waits:
AGENTS.md section 3 has the agent run ``bin/fm-session-start.sh`` by hand, and
the first turn boundary after that finds the scope and activates.
"""

from __future__ import annotations

import atexit
import logging
import os
import re
import sys
import threading
import time
from pathlib import Path
from typing import Optional

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from fm_hermes_common import Paths, lock_ownership, primary_scope, resolve_paths  # noqa: E402
import fm_hermes_delivery  # noqa: E402
import fm_hermes_guard  # noqa: E402
import fm_hermes_sessionstart  # noqa: E402
import fm_hermes_watch  # noqa: E402
import fm_hermes_worker  # noqa: E402

logger = logging.getLogger("hermes_plugins.firstmate")

CAPTAIN_SKILLS = ("afk", "ahoy", "bearings", "quiet", "stow", "updatefirstmate")
ACTIVATION_RETRY_SECONDS = 20.0


def _safe(fn):
    def wrapper(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except Exception:  # noqa: BLE001 - a supervisor hook must never break the session
            logger.warning("firstmate: %s hook failed", getattr(fn, "__name__", "?"), exc_info=True)
            return None
    wrapper.__name__ = getattr(fn, "__name__", "firstmate_hook")
    return wrapper


def _register_worker(ctx, paths: Paths) -> None:
    worker = fm_hermes_worker.Worker(paths)
    if not worker.active:
        return

    @_safe
    def pre_llm_call(**kwargs):
        worker.turn_started()
        return None

    @_safe
    def post_tool_call(**kwargs):
        worker.progress()
        return None

    @_safe
    def on_session_end(**kwargs):
        worker.turn_ended(interrupted=bool(kwargs.get("interrupted")))
        return None

    @_safe
    def agent_loop_stopped(**kwargs):
        worker.stopped()
        return None

    ctx.register_hook("pre_llm_call", pre_llm_call)
    ctx.register_hook("post_tool_call", post_tool_call)
    ctx.register_hook("on_session_end", on_session_end)
    ctx.register_hook("agent_loop_stopped", agent_loop_stopped)


def _skill_description(path: Path) -> str:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    match = re.search(r"^description:\s*(?:>-?\s*\n)?(.+?)(?:\n\S|\n---)", text, re.S | re.M)
    if not match:
        return ""
    return " ".join(match.group(1).split())[:300]


class Primary:
    def __init__(self, ctx, paths: Paths):
        self.ctx = ctx
        self.paths = paths
        self.active = False
        self._activate_lock = threading.Lock()
        self._last_probe: Optional[float] = None
        self.delivery = fm_hermes_delivery.IdleDelivery(ctx)
        self.watch = fm_hermes_watch.WatchOwner(paths, self.delivery.deliver, Path(fm_hermes_watch.__file__))
        self.guard = fm_hermes_guard.Guard(paths, self.delivery, self.watch, Path(fm_hermes_guard.__file__))
        self.sessionstart = fm_hermes_sessionstart.SessionStart(
            paths, self.delivery.deliver, fm_hermes_sessionstart.wait_budget())

    def activate(self, run_digest: bool) -> bool:
        with self._activate_lock:
            if self.active:
                return True
            # A later attempt only matters for a fresh home whose state directory
            # is about to be created by a manual session start; throttle the
            # scope probe so an out-of-scope session pays for it rarely.
            now = time.monotonic()
            if not run_digest and self._last_probe is not None and now - self._last_probe < ACTIVATION_RETRY_SECONDS:
                return False
            self._last_probe = now
            if not primary_scope(self.paths):
                return False
            self.active = True
        self.guard.mark_loaded()
        self.watch.mark_loaded()
        if run_digest:
            source = fm_hermes_sessionstart.launch_resume_source() or "startup"
            generation = self.sessionstart.start(source)
            threading.Thread(target=self._arm_after_digest, args=(generation,), daemon=True,
                             name="fm-hermes-arm-after-digest").start()
        else:
            self.watch.ensure()
        return True

    def _arm_after_digest(self, generation) -> None:
        generation.done.wait()
        if generation.kind in ("ready", "empty", "ineligible") and lock_ownership(self.paths) == "owned":
            self.guard.mark_loaded()
            self.watch.activate()

    def shutdown(self) -> None:
        self.sessionstart.shutdown()
        self.watch.shutdown()
        self.delivery.stop()


def _register_primary(ctx, paths: Paths) -> None:
    primary = Primary(ctx, paths)
    primary.activate(run_digest=True)

    @_safe
    def pre_llm_call(session_id=None, user_message=None, conversation_history=None, **kwargs):
        primary.delivery.turn_started(session_id or "")
        if not primary.active:
            primary.activate(run_digest=False)
            return None
        primary.guard.turn_started(user_message)
        parts = []
        digest = primary.sessionstart.pre_llm_call(session_id or "", conversation_history)
        if digest:
            parts.append(digest)
        fallback = primary.delivery.take_fallback()
        if fallback:
            parts.append(fallback)
        return {"context": "\n\n".join(parts)} if parts else None

    @_safe
    def on_session_end(session_id=None, interrupted=False, **kwargs):
        try:
            if not primary.active:
                primary.activate(run_digest=False)
            if primary.active:
                primary.guard.on_session_end(interrupted=bool(interrupted))
        finally:
            primary.delivery.turn_ended(session_id or "")
        return None

    @_safe
    def on_session_start(session_id=None, **kwargs):
        primary.delivery.note_session(session_id or "")
        return None

    @_safe
    def on_session_reset(session_id=None, **kwargs):
        primary.delivery.note_session(session_id or "")
        if primary.active:
            primary.sessionstart.on_session_reset()
        return None

    @_safe
    def on_session_finalize(reason=None, **kwargs):
        # The CLI finalizes the outgoing conversation on /new ("session_boundary")
        # and on exit ("shutdown"). The watcher is home-scoped, so only a real
        # shutdown stops it; either way an undelivered actionable close is
        # persisted so a later process can replay it.
        if not primary.active:
            return None
        if reason == "shutdown":
            primary.watch.shutdown()
        else:
            primary.watch.persist_pending()
        return None

    @_safe
    def pre_verify(attempt=0, **kwargs):
        if not primary.active:
            return None
        try:
            attempt_number = int(attempt or 0)
        except (TypeError, ValueError):
            attempt_number = 0
        return primary.guard.pre_verify(attempt=attempt_number)

    def pre_tool_call(tool_name=None, args=None, **kwargs):
        # Deliberately NOT wrapped in _safe's swallow: Hermes treats a raising
        # pre_tool_call as a block, and a checker that cannot run is fail-open
        # inside fm_hermes_common.run, so only a genuine bug reaches Hermes.
        if not primary.active:
            return None
        return primary.guard.pre_tool_call(tool_name or "", args)

    ctx.register_hook("pre_llm_call", pre_llm_call)
    ctx.register_hook("on_session_end", on_session_end)
    ctx.register_hook("on_session_start", on_session_start)
    ctx.register_hook("on_session_reset", on_session_reset)
    ctx.register_hook("on_session_finalize", on_session_finalize)
    ctx.register_hook("pre_verify", pre_verify)
    ctx.register_hook("pre_tool_call", pre_tool_call)

    def arm_tool(args=None, **kwargs):
        if not primary.active and not primary.activate(run_digest=False):
            return ("watcher: not armed - this Hermes session is not running in a Firstmate primary home "
                    "(or its state directory does not exist yet; run bin/fm-session-start.sh first)")
        return primary.watch.activate().message

    try:
        ctx.register_tool(
            name="fm_watch_arm_hermes",
            toolset="firstmate",
            schema={
                "name": "fm_watch_arm_hermes",
                "description": (
                    "Start the first required Firstmate watcher cycle, or repair one only after a notification "
                    "says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or "
                    "ordinary notifications; the Hermes firstmate plugin re-arms automatically. Never run "
                    "bin/fm-watch-arm.sh through the terminal tool."),
                "parameters": {"type": "object", "properties": {}, "additionalProperties": False},
            },
            handler=lambda args, **kw: arm_tool(args, **kw),
            description="Arm or repair Firstmate watcher supervision (plugin-owned).",
        )
    except Exception:  # noqa: BLE001
        logger.warning("firstmate: could not register fm_watch_arm_hermes", exc_info=True)

    def arm_command(raw_args: str = ""):
        return arm_tool({})

    try:
        ctx.register_command("fm-watch-arm-hermes", arm_command,
                             description="Arm or repair Firstmate watcher supervision (plugin-owned).")
    except Exception:  # noqa: BLE001
        pass

    skills_dir = paths.root / ".agents" / "skills"
    for name in CAPTAIN_SKILLS:
        skill = skills_dir / name / "SKILL.md"
        if not skill.is_file():
            continue

        def make_handler(skill_name: str, skill_path: Path):
            def handler(raw_args: str = ""):
                args_text = (raw_args or "").strip()
                message = (f"/{skill_name}{(' ' + args_text) if args_text else ''}\n\n"
                           f"The captain invoked the Firstmate `{skill_name}` skill. Read `{skill_path}` in full "
                           "and follow it now" + (f", with the captain's arguments: {args_text}" if args_text
                                                   else "") + ".")
                if primary.ctx.inject_message(message):
                    return None
                return f"Could not queue the {skill_name} skill; ask for it in plain words instead."
            return handler

        try:
            ctx.register_command(name, make_handler(name, skill),
                                 description=f"Firstmate: {_skill_description(skill) or name}"[:200],
                                 args_hint="[words]")
        except Exception:  # noqa: BLE001
            pass

    atexit.register(primary.shutdown)


def register(ctx, root: Path, loader_version: int = 0) -> None:
    paths = resolve_paths(Path(root))
    if os.environ.get("FM_HERMES_ROLE", "") == "worker":
        _register_worker(ctx, paths)
        return
    if not (paths.root / "AGENTS.md").is_file():
        return
    _register_primary(ctx, paths)
