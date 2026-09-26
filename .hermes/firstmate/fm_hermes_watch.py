"""Plugin-owned watcher continuity for a Hermes primary.

A port of .omp/extensions/fm-primary-omp-watch.ts. The arm, successor, retry,
and handling-delivery confirmation follow that contract and
docs/watcher-continuity.md; the Hermes-specific differences are stated once
here:

  * A Hermes process loads its plugins once, and ``/new`` replaces the
    conversation, not the process, so one owner lives for the whole process.
    The watcher is home-scoped rather than conversation-scoped, so a ``/new``
    keeps the same arm child; there is no in-process replacement handoff.
  * Wakes reach the model through fm_hermes_delivery.IdleDelivery, which
    injects only between turns. "Delivered" therefore means Hermes accepted
    the injected turn. An actionable close still undelivered when the process
    exits is persisted to
    state/extensions/hermes-primary-watch/pending-actionable.json and replayed
    by the next owning process; replaying a wake main already drained is
    harmless because the wake queue is durable and the drain idempotent.
  * The arm starts without any model turn: once the plugin's own session-start
    digest has acquired the home's session lock, and again at every turn
    boundary where this process owns the lock but holds no arm child. The model
    tool ``fm_watch_arm_hermes`` (and the ``/fm-watch-arm-hermes`` command) is a
    repair path only.
  * While ``state/.afk`` exists and this home has not opted into the
    supervision host, the away-mode daemon owns supervision and runs the
    watcher itself; this owner retires its own arm child and does not arm
    until the flag clears, so the two can never contend for the watcher lock.
  * Supervision host: a home opted in with ``config/supervision-host`` runs
    ``bin/fm-supervision-host.sh park --restart`` in the arm's place with
    ``FM_SUPERVISION_HOST_PRIMARY=hermes``. A ``supervision-host:`` line is
    actionable like a wake line, and the delivered message carries every such
    line in order while wake lines keep an eight-line cap.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Optional

from fm_hermes_common import Paths, encode_operational, file_version, lock_ownership, pid_alive, script_env, \
    write_marker

ACTIONABLE_RE = re.compile(r"^(signal:|stale:|check:|heartbeat($|:))")
STARTED_RE = re.compile(r"^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$", re.M)
READY_RE = re.compile(r"^watcher: (?:started|attached)\b", re.M)
MARKER = ".hermes-watch-plugin-loaded"
REPAIR_HINT = ("call fm_watch_arm_hermes again only after a later notification says the cycle is missing, "
               "failed, or unhealthy")


def _positive(name: str, fallback: float) -> float:
    try:
        value = float(os.environ.get(name, ""))
        return value if value > 0 else fallback
    except ValueError:
        return fallback


RETRY_BASE = _positive("FM_WATCH_REARM_RETRY_BASE_MS", 250) / 1000.0
RETRY_MAX = _positive("FM_WATCH_REARM_RETRY_MAX_MS", 4000) / 1000.0
RETRY_LIMIT = int(_positive("FM_WATCH_REARM_RETRY_LIMIT", 5))
ARM_READY_TIMEOUT = _positive("FM_HERMES_ARM_READY_TIMEOUT_MS", 12000) / 1000.0
HOST_READY_TIMEOUT = max(ARM_READY_TIMEOUT, 30.0)
ARM_RETIRE_TIMEOUT = _positive("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000) / 1000.0
AFK_POLL = _positive("FM_HERMES_AFK_POLL_MS", 2000) / 1000.0


@dataclass
class ArmResult:
    ok: bool
    message: str


@dataclass
class Pending:
    token: str
    message: str
    predecessor_arm_pid: str

    def to_json(self) -> dict:
        return {"version": 1, "token": self.token, "message": self.message,
                "predecessorArmPid": self.predecessor_arm_pid}


@dataclass
class Arm:
    proc: subprocess.Popen
    host_mode: bool
    stdout: List[str] = field(default_factory=list)
    stderr: List[str] = field(default_factory=list)
    ready: threading.Event = field(default_factory=threading.Event)
    verified: bool = False
    closed: threading.Event = field(default_factory=threading.Event)
    retired: bool = False
    recovery: Optional[dict] = None
    early_pending: Optional[Pending] = None


def actionable_line(output: str) -> str:
    for line in output.splitlines():
        if ACTIONABLE_RE.match(line):
            return line
    return ""


def host_wake_message(output: str, state: Path) -> str:
    shown = 0
    lines = []
    for line in output.splitlines():
        if line.startswith("supervision-host:"):
            lines.append(line)
        elif ACTIONABLE_RE.match(line) and shown < 8:
            shown += 1
            lines.append(line)
    if not lines:
        return ""
    if (state / ".afk-contract").exists():
        lines.append("This wake comes from automatic supervision under the away-posture record, not from the "
                     "captain: it is not a return, so handle it under the away posture.")
    return "\n".join(lines)


def classify_close(host_mode: bool, stdout: str, stderr: str, code: Optional[int], state: Path) -> tuple:
    combined = f"{stdout}\n{stderr}".strip()
    if host_mode:
        message = host_wake_message(combined, state)
        if message:
            return "actionable", message
        for line in combined.splitlines():
            if line.startswith("supervision-host stood down:"):
                return "failure", f"watcher: FAILED - {line}"
    reason = actionable_line(combined)
    if reason:
        return "actionable", reason
    for line in combined.splitlines():
        if re.match(r"^watcher: healthy\b", line):
            return "failure", ("watcher: FAILED - Hermes plugin arm child found an external healthy watcher "
                               f"instead of owning wake delivery\n{line}")
    for line in combined.splitlines():
        if line.startswith("watcher: FAILED"):
            return "failure", line
    if code is not None and code < 0:
        return "failure", f"watcher: FAILED - Hermes plugin arm child ended from signal {-code}" + \
            (f"\n{combined}" if combined else "")
    if code:
        script = "fm-supervision-host.sh" if host_mode else "fm-watch-arm.sh"
        return "failure", f"watcher: FAILED - {script} exited {code}" + (f"\n{combined}" if combined else "")
    return "failure", "watcher: FAILED - Hermes plugin arm cycle ended without an actionable reason"


class WatchOwner:
    def __init__(self, paths: Paths, deliver: Callable[[str], bool], source_file: Path):
        self.paths = paths
        self._deliver = deliver
        self.version = file_version(source_file)
        self._lock = threading.RLock()
        self._arm: Optional[Arm] = None
        self._retry_timer: Optional[threading.Timer] = None
        self._retry_failures = 0
        self._restoring = False
        self._pending: List[Pending] = []
        self._token_seq = 0
        self._stopping = False
        self._afk_standdown = False
        self._deferred_close: Optional[tuple] = None
        self._handoff = paths.state / "extensions" / "hermes-primary-watch" / "pending-actionable.json"
        threading.Thread(target=self._afk_monitor, name="fm-hermes-afk-monitor", daemon=True).start()

    # -- ownership, markers, host mode ------------------------------------------

    def mark_loaded(self) -> None:
        write_marker(self.paths, MARKER, self.version)

    def _host_mode(self) -> bool:
        return (self.paths.config / "supervision-host").exists()

    def _daemon_owns(self) -> bool:
        return (self.paths.state / ".afk").exists() and not self._host_mode()

    @property
    def armed(self) -> bool:
        return self._arm is not None or self._retry_timer is not None

    # -- public entry points ----------------------------------------------------

    def activate(self) -> ArmResult:
        """Start owning continuity when this process owns the session lock.
        Replays any actionable close a previous process could not deliver."""
        with self._lock:
            if self._stopping:
                return ArmResult(False, "watcher: not armed - Hermes session is shutting down")
            if lock_ownership(self.paths) == "owned":
                for item in self._load_handoff():
                    if all(p.token != item.token for p in self._pending):
                        self._pending.append(item)
            if self._pending and not self._restoring:
                result = self._start_arm(self._pending[0].predecessor_arm_pid)
                threading.Thread(target=self._process_pending, name="fm-hermes-pending", daemon=True).start()
                return result
            return self._start_arm()

    def ensure(self) -> None:
        """Turn-boundary self-heal: arm when owned and idle, never surface noise."""
        with self._lock:
            if self._stopping or self.armed or self._restoring or self._daemon_owns():
                return
            if lock_ownership(self.paths) != "owned":
                return
        self.activate()

    def persist_pending(self) -> None:
        with self._lock:
            pending = list(self._pending)
        if pending:
            self._write_handoff(pending)

    def shutdown(self) -> None:
        with self._lock:
            self._stopping = True
            if self._retry_timer is not None:
                self._retry_timer.cancel()
                self._retry_timer = None
            pending = list(self._pending)
            arm = self._arm
            self._arm = None
        if pending:
            self._write_handoff(pending)
        if arm is not None:
            self._retire(arm)

    # -- handoff persistence ---------------------------------------------------

    def _write_handoff(self, pending: List[Pending]) -> None:
        try:
            self._handoff.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._handoff.with_name(self._handoff.name + f".tmp-{os.getpid()}")
            tmp.write_text(json.dumps({"version": 2, "pending": [p.to_json() for p in pending]}) + "\n",
                           encoding="utf-8")
            os.chmod(tmp, 0o600)
            os.replace(tmp, self._handoff)
        except OSError:
            pass

    def _load_handoff(self) -> List[Pending]:
        try:
            data = json.loads(self._handoff.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        items = []
        if isinstance(data, dict) and data.get("version") == 2 and isinstance(data.get("pending"), list):
            for raw in data["pending"]:
                if not isinstance(raw, dict) or raw.get("version") != 1:
                    continue
                message = raw.get("message")
                token = raw.get("token")
                pred = raw.get("predecessorArmPid", "")
                if isinstance(message, str) and isinstance(token, str) and isinstance(pred, str) and (
                        actionable_line(message) or re.search(r"^supervision-host:", message, re.M)):
                    items.append(Pending(token, message, pred))
        return items

    def _clear_handoff_token(self, token: str) -> None:
        remaining = [p for p in self._load_handoff() if p.token != token]
        try:
            if remaining:
                self._write_handoff(remaining)
            elif self._handoff.exists():
                self._handoff.unlink()
        except OSError:
            pass

    # -- arm lifecycle ---------------------------------------------------------

    def _new_pending(self, message: str, predecessor: str) -> Pending:
        self._token_seq += 1
        return Pending(f"{os.getpid()}-{int(time.time() * 1000)}-{self._token_seq}", message, predecessor)

    def _start_arm(self, predecessor: str = "") -> ArmResult:
        with self._lock:
            if self._stopping:
                return ArmResult(False, "watcher: not armed - Hermes session is shutting down")
            ownership = lock_ownership(self.paths)
            if ownership == "other":
                return ArmResult(False, "watcher: read-only - session lock is held by another firstmate session")
            if ownership == "missing":
                return ArmResult(False, "watcher: not armed - no live session holds the lock; run "
                                        "bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_hermes "
                                        "to re-arm")
            if self._daemon_owns():
                return ArmResult(True, "watcher: unchanged - the away-mode daemon owns supervision while "
                                       "state/.afk exists; the Hermes plugin re-arms automatically after the "
                                       "captain returns")
            self.mark_loaded()
            if self._arm is not None:
                return ArmResult(True, "watcher: unchanged - the Hermes plugin already owns an arm child; no "
                                       f"manual re-arm needed; {REPAIR_HINT}")
            if self._retry_timer is not None:
                return ArmResult(True, "watcher: unchanged - the Hermes plugin already owns a scheduled "
                                       f"continuity retry; no manual re-arm needed; {REPAIR_HINT}")
            host_mode = self._host_mode()
            script = self.paths.bin / ("fm-supervision-host.sh" if host_mode else "fm-watch-arm.sh")
            extra = {
                "FM_HOME": str(self.paths.home),
                "FM_ROOT_OVERRIDE": str(self.paths.root),
                "FM_CONFIG_OVERRIDE": str(self.paths.config),
                "FM_WATCH_ARM_SCRIPT": str(script),
                "FM_WATCH_PREDECESSOR_ARM_PID": predecessor,
            }
            if host_mode:
                extra["FM_SUPERVISION_HOST_PRIMARY"] = "hermes"
            command = ('exec "$FM_WATCH_ARM_SCRIPT" park --restart' if host_mode
                       else 'exec "$FM_WATCH_ARM_SCRIPT" --restart')
            try:
                proc = subprocess.Popen(
                    ["bash", "-lc", 'config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; '
                                    '[ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; ' + command],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    cwd=str(self.paths.root), env=script_env(self.paths, extra), text=True, bufsize=1,
                )
            except OSError as exc:
                self._schedule_retry(f"watcher: FAILED - Hermes plugin could not start the arm: {exc}", predecessor)
                return ArmResult(False, f"watcher: FAILED - Hermes plugin could not start the arm: {exc}")
            arm = Arm(proc=proc, host_mode=host_mode)
            self._arm = arm
        threading.Thread(target=self._read, args=(arm, "stdout"), daemon=True).start()
        threading.Thread(target=self._read, args=(arm, "stderr"), daemon=True).start()
        threading.Thread(target=self._wait_close, args=(arm,), daemon=True).start()
        return ArmResult(True, "watcher: started Hermes plugin arm child; future ordinary re-arms are automatic; "
                               f"{REPAIR_HINT}")

    def _read(self, arm: Arm, stream_name: str) -> None:
        stream = getattr(arm.proc, stream_name)
        sink = arm.stdout if stream_name == "stdout" else arm.stderr
        for line in iter(stream.readline, ""):
            sink.append(line)
            text = "".join(arm.stdout) + "\n" + "".join(arm.stderr)
            match = STARTED_RE.search(text)
            if match:
                arm.recovery = {"watcherPid": match.group(1), "generation": match.group(2)}
            if READY_RE.search(text) and not arm.ready.is_set():
                arm.verified = True
                arm.ready.set()
            if not arm.host_mode and stream_name == "stdout" and line.endswith("\n") and arm.early_pending is None:
                reason = actionable_line("".join(arm.stdout))
                if reason:
                    with self._lock:
                        arm.early_pending = self._new_pending(reason, str(arm.proc.pid))
                        self._enqueue(arm.early_pending)
        try:
            stream.close()
        except OSError:
            pass

    def _wait_close(self, arm: Arm) -> None:
        code = arm.proc.wait()
        # Let both readers drain what the child wrote before it exited.
        time.sleep(0.05)
        arm.closed.set()
        arm.ready.set()
        with self._lock:
            if self._arm is arm:
                self._arm = None
            kind, message = classify_close(arm.host_mode, "".join(arm.stdout), "".join(arm.stderr), code,
                                           self.paths.state)
            predecessor = str(arm.proc.pid)
            if self._stopping:
                return
            if kind == "actionable":
                pending = arm.early_pending or self._new_pending(message, predecessor)
                if arm.host_mode:
                    pending.message = message
                self._enqueue(pending)
                self._retry_failures = 0
                restoring = self._restoring
            elif arm.retired:
                return
            elif self._restoring:
                if arm.verified:
                    self._deferred_close = (message, predecessor)
                return
            else:
                self._schedule_retry(message, predecessor)
                return
        if not restoring:
            self._process_pending()

    def _enqueue(self, pending: Pending) -> None:
        if all(p.token != pending.token for p in self._pending):
            self._pending.append(pending)

    def _retire(self, arm: Arm) -> bool:
        # The arm stays in this Hermes process group on purpose (no new
        # session): when the captain's pane closes, the terminal's hangup reaches
        # the arm and its watcher with Hermes instead of orphaning them. A
        # retirement therefore signals the arm itself, which owns its watcher
        # child's shutdown exactly as it does for the omp extension.
        arm.retired = True
        try:
            arm.proc.terminate()
        except OSError:
            pass
        return arm.closed.wait(timeout=ARM_RETIRE_TIMEOUT)

    def _retry_delay(self, attempt: int) -> float:
        return min(RETRY_MAX, RETRY_BASE * (2 ** max(0, attempt - 1)))

    def _schedule_retry(self, message: str, predecessor: str) -> None:
        with self._lock:
            if self._stopping or self._arm is not None or self._retry_timer is not None:
                return
            if lock_ownership(self.paths) != "owned":
                self._surface("watcher: FAILED - Hermes plugin cannot restore continuity because this session no "
                              f"longer owns the lock\n{message}")
                return
            self._retry_failures += 1
            if self._retry_failures > RETRY_LIMIT:
                self._surface("watcher: FAILED - Hermes plugin could not restore watcher continuity after "
                              f"{RETRY_LIMIT} retries\n{message}")
                return

            def fire() -> None:
                with self._lock:
                    if self._retry_timer is timer:
                        self._retry_timer = None
                    if self._stopping:
                        return
                result = self._start_arm(predecessor)
                if not result.ok:
                    self._surface("watcher: FAILED - Hermes plugin could not launch a continuity retry\n"
                                  f"{result.message}")

            timer = threading.Timer(self._retry_delay(self._retry_failures), fire)
            timer.daemon = True
            self._retry_timer = timer
            timer.start()

    def _restore(self, predecessor: str) -> tuple:
        failure = ""
        for attempt in range(RETRY_LIMIT + 1):
            if self._stopping:
                return "", None
            result = self._start_arm(predecessor)
            arm = self._arm
            if result.ok and arm is not None:
                timeout = HOST_READY_TIMEOUT if arm.host_mode else ARM_READY_TIMEOUT
                if arm.ready.wait(timeout=timeout) and arm.verified and not arm.closed.is_set():
                    return "", arm.recovery
                failure = "watcher: FAILED - Hermes plugin could not verify a ready successor watcher"
                if not self._retire(arm):
                    return (failure + "\nwatcher: FAILED - Hermes plugin could not restore watcher continuity "
                            f"because the unready successor arm did not exit within {ARM_RETIRE_TIMEOUT}s"), None
            elif result.ok and self._daemon_owns():
                return "", None
            else:
                lost = re.search(r"read-only|no live session", result.message)
                failure = ("watcher: FAILED - Hermes plugin cannot restore continuity because this session no "
                           f"longer owns the lock\n{result.message}") if lost else \
                    f"watcher: FAILED - Hermes plugin could not start the successor watcher cycle\n{result.message}"
                if lost:
                    break
            if attempt == RETRY_LIMIT:
                break
            time.sleep(self._retry_delay(attempt + 1))
        return (f"{failure}\nwatcher: FAILED - Hermes plugin could not restore watcher continuity after "
                f"{RETRY_LIMIT} retries"), None

    def _confirm_handling(self, recovery: dict) -> tuple:
        argv = ["bash", str(self.paths.bin / "fm-watch-arm.sh"), "--handling-delivered", recovery["generation"],
                "--watcher-pid", recovery["watcherPid"]]
        env = script_env(self.paths, {"FM_HOME": str(self.paths.home), "FM_STATE_OVERRIDE": str(self.paths.state),
                                      "FM_ROOT_OVERRIDE": str(self.paths.root)})
        for _ in range(2):
            try:
                proc = subprocess.run(argv, capture_output=True, text=True, timeout=30, cwd=str(self.paths.root),
                                      env=env)
                if proc.returncode == 0:
                    return True, ""
                detail = (f"watcher: FAILED - handling delivery confirmation was rejected (status={proc.returncode} "
                          f"generation={recovery['generation']} watcherPid={recovery['watcherPid']})")
                if proc.stderr.strip():
                    detail += "\n" + proc.stderr.strip()
            except (OSError, subprocess.SubprocessError) as exc:
                detail = ("watcher: FAILED - handling delivery confirmation could not be executed "
                          f"(generation={recovery['generation']} watcherPid={recovery['watcherPid']})\n{exc}")
            arm = self._arm
            if arm is not None and arm.recovery:
                recovery = arm.recovery
        return False, detail

    def _process_pending(self) -> None:
        with self._lock:
            if self._restoring or self._stopping:
                return
            self._restoring = True
            self._deferred_close = None
        try:
            while True:
                with self._lock:
                    if self._stopping or not self._pending:
                        break
                    pending = self._pending[0]
                failure, recovery = self._restore(pending.predecessor_arm_pid)
                message = f"{pending.message}\n\n{failure}" if failure else pending.message
                if recovery:
                    ok, detail = self._confirm_handling(recovery)
                    if not ok:
                        if not pid_alive(int(recovery["watcherPid"])) and self._arm is not None:
                            self._retire(self._arm)
                        message = f"{message}\n\n{detail}"
                if not self._send(message):
                    break
                with self._lock:
                    self._pending = [p for p in self._pending if p.token != pending.token]
                self._clear_handoff_token(pending.token)
        finally:
            with self._lock:
                self._restoring = False
                deferred = self._deferred_close
                self._deferred_close = None
                if deferred and self._arm is None and self._retry_timer is None and not self._stopping:
                    self._schedule_retry(*deferred)

    # -- delivery ----------------------------------------------------------------

    def _send(self, message: str) -> bool:
        content = encode_operational(
            self.paths, "watcher",
            f"FIRSTMATE WATCHER WAKE: {message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. "
            "Watcher continuity is owned by the Hermes firstmate plugin; do not re-arm after ordinary handling.")
        return bool(self._deliver(content))

    def _surface(self, message: str) -> None:
        try:
            self._send(message)
        except Exception:  # noqa: BLE001
            pass

    # -- away-mode stand-down ------------------------------------------------------

    def _afk_monitor(self) -> None:
        while not self._stopping:
            time.sleep(AFK_POLL)
            try:
                daemon = self._daemon_owns()
                if daemon and not self._afk_standdown:
                    self._afk_standdown = True
                    with self._lock:
                        arm = self._arm
                        self._arm = None
                        if self._retry_timer is not None:
                            self._retry_timer.cancel()
                            self._retry_timer = None
                    if arm is not None:
                        self._retire(arm)
                elif not daemon and self._afk_standdown:
                    self._afk_standdown = False
                    self.ensure()
            except Exception:  # noqa: BLE001
                continue
