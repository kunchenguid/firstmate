#!/usr/bin/env python3
"""Orca-owned Codex watcher continuation (macOS/Linux, Python 3.9+).

Usage: fm-codex-orca-continuation.py context|ensure|status --home HOME
       fm-codex-orca-continuation.py run --home HOME --generation TOKEN
       fm-codex-orca-continuation.py abandon-launch --home HOME --generation TOKEN
       [--code-root ROOT] [--seconds N]

ensure requires the current Codex ancestor to own HOME/state/.lock and an
Orca-exported ORCA_TERMINAL_HANDLE in this primary home. It captures that exact
terminal's runtime/incarnation, serializes bootstrap, creates one app-owned
terminal, and bounds bootstrap/readiness observation to 20s (plus bounded
child cleanup). An unconfirmed create is never repeated automatically.
run is that terminal's foreground command; --seconds bounds an attended test.
It replaces each closed arm BEFORE submitting one constant generation-bound
wake and observes externally appended pending generations without draining.
An external generation takes over only its own arm through fm-watch-arm.sh;
that interface preserves an attached peer watcher and verifies its successor
arm against the existing singleton. Root alone drains/ACKs.
fm-codex-orca-stop.sh owns the Stop integration
and always calls the unchanged generic guard in the original Bash ancestry.
status is read-only and reports readiness, binding and last delivery outcome.
context verifies the current primary/Orca binding without launching or writing;
it exits 3 when not applicable and 1 when an in-scope binding is unverified,
which the renderer and Stop integration both treat as fail-closed Orca mode.
abandon-launch resolves only the named pending launching generation as failed,
after proving no owner lock, owner process or owner terminal (titled with that
generation) exists in a complete terminal list that includes the primary; any
live or unknown state refuses. It retains the list as an abandon receipt.

State: .codex-orca-continuation.json binds owner PID/birth/generation, primary
PID/birth, exact target, child arm and last episode. Two kernel flock files
serialize bootstrap and lifetime on macOS/Linux. Atomic mode-0600 receipts in
.codex-orca-continuation/ retain the exact payload/request/stages and errors.
No ACK, endpoint search/adoption, session-lock mutation, scheduler or fleet
reasoning occurs here. Receipt acceptance is not turn-start proof. Silence
never authorizes a fresh resend: only a returned --retry-request ID permits
one bounded exact retry. Ambiguity survives owner restart without fresh input.
An episode is recorded only once its preconditions hold and transport begins.
A turn-started, handling-confirmed generation that later reopens as downtime
without ACK is re-presented exactly once, keeping the prior episode as
replay_prior; ensure refuses after that. Delivery re-reads the recovery marker
and never presents an acknowledged or superseded generation. A relaunch for
the same primary keeps its episode even if the CLI path or code root changed.
A run refused before it owns its lifetime marks its launching record failed.
ensure waits, within its bound, only for a live matching owner that is
re-arming; launched and reused owners pass the same delivery checks, and no
replacement launches over an unresolved prior episode; a later recovery
generation proves that episode's generation was acknowledged. Unavailable Orca or
supervision-status observation is retained, not treated as an identity change
or as supervision no longer needed, until delivery needs it. An arm is
a handling successor only after a verified predecessor arm; take-over keeps the
arm interface's own semantics.
An exited/degraded owner leaves durable wakes and explicit failure evidence.
Restart may take over only its recorded, still identity-matching arm through
fm-watch-arm.sh; it never signals a foreign watcher or another session.
"""

import argparse
import contextlib
import fcntl
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


class Refused(RuntimeError):
    pass


class Unavailable(Refused):
    pass


class Adapter:
    def __init__(self, args):
        self.args = args
        self.home = pathlib.Path(args.home).resolve()
        self.code = pathlib.Path(args.code_root or __file__).resolve()
        if not args.code_root:
            self.code = self.code.parent.parent
        self.state = self.home / "state"
        self.record_path = self.state / ".codex-orca-continuation.json"
        self.receipts = self.state / ".codex-orca-continuation"
        self.env = dict(os.environ, FM_HOME=str(self.home),
                        FM_ROOT_OVERRIDE=str(self.code), FM_STATE_OVERRIDE=str(self.state),
                        FM_CONFIG_OVERRIDE=str(self.home / "config"),
                        FM_DATA_OVERRIDE=str(self.home / "data"), LC_ALL="C")
        self.children = []
        self.arms = set()
        self.arm_files = []
        self.record = {}
        self.arm = None
        self.arm_file = None
        self.deadline = time.monotonic() + args.seconds if args.seconds else None
        self.operation_deadline = time.monotonic() + (20 if args.mode == "ensure" else 10) if args.mode != "run" else None
        self.stopping = False
        self.owns_lifetime = False

    def command(self, argv, timeout=5, input_text=None, owned_transport=False):
        if self.operation_deadline is not None:
            timeout = min(timeout, self.operation_deadline - time.monotonic())
            if timeout <= 0:
                raise Refused("bounded adapter observation deadline reached")
        p = subprocess.Popen(argv, env=self.env, stdin=subprocess.PIPE if input_text is not None
                             else subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.children.append(p)
        try:
            if owned_transport:
                self.publish(transport={"pid": p.pid, "identity": self.identity(p.pid)})
            out, err = p.communicate(input_text, timeout=timeout)
            return p.returncode, out, err
        except subprocess.TimeoutExpired:
            self.reap(p)
            out, err = p.communicate(timeout=1)
            return 124, out, err + "\ncommand observation timed out; delivery may be unknown"
        finally:
            self.children.remove(p)
            if owned_transport:
                self.publish(transport=None)

    def shell(self, body, *values, timeout=5, owned_transport=False):
        return self.command(["bash", "-c", body, "continuation", str(self.code), *map(str, values)],
                            timeout=timeout, owned_transport=owned_transport)

    def identity(self, pid):
        rc, out, _ = self.shell('. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"', pid)
        return out.strip() if rc == 0 else ""

    def scope(self, caller=False):
        if caller:
            # The interpreter's helper filename is not harness evidence. Prove
            # kernel ancestry to the recorded session, then classify that PID.
            try:
                owner = int((self.state / ".lock").read_text().strip())
            except (ValueError, OSError):
                return False
            pid = os.getpid()
            for _ in range(32):
                if pid == owner:
                    break
                rc, out, _ = self.command(["ps", "-p", str(pid), "-o", "ppid="])
                if rc or not out.strip().isdigit() or int(out) <= 1:
                    return False
                pid = int(out)
            else:
                return False
        body = '. "$1/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$FM_HOME" "$FM_STATE_OVERRIDE" || exit 1; '
        body += '. "$1/bin/fm-session-lock-lib.sh"; '
        if caller:
            body += 'pid=$(cat "$FM_STATE_OVERRIDE/.lock") || exit 1; comm=$(ps -p "$pid" -o comm=) || exit 1; '
            body += 'args=$(ps -p "$pid" -o args=) || exit 1; '
            body += '[ "$(fm_harness_path_name "$comm" || fm_harness_path_name "${args%% *}" || true)" = codex ] || exit 1; '
        body += '[ ! -e "$FM_STATE_OVERRIDE/.afk" ] && [ ! -e "$FM_STATE_OVERRIDE/.afk-contract" ] || exit 1; '
        body += '. "$1/bin/fm-supervision-engine-lib.sh"; ! fm_supervision_host_enabled "$FM_CONFIG_OVERRIDE" codex || exit 1; '
        rc, _, _ = self.shell(body)
        return rc == 0

    def healthy(self):
        rc, out, _ = self.shell('. "$1/bin/fm-wake-lib.sh"; '
                                'fm_watcher_healthy "$STATE" "$1/bin/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" || exit 1; '
                                'printf "%s\\t%s\\n" "$FM_WATCHER_HEALTHY_PID" "$FM_WATCHER_HEALTHY_IDENTITY"')
        return out.rstrip("\n").split("\t", 1) if rc == 0 else None

    def needed(self):
        rc, _, err = self.shell('. "$1/bin/fm-wake-lib.sh" || exit 2; . "$1/bin/fm-supervision-lib.sh" || exit 2; '
                                'fm_supervision_status "$STATE" || exit 2; [ "$FM_SUP_NEEDED" = true ]', timeout=8)
        if rc not in (0, 1):
            raise Unavailable("supervision status unavailable: " + err.strip())
        return rc == 0

    def recovery(self):
        rc, out, err = self.shell('. "$1/bin/fm-wake-lib.sh"; '
                                  'fm_recovery_marker_snapshot "$STATE/.watcher-down" || exit 1; '
                                  'printf "%s\\n" "$FM_RECOVERY_MARKER_TOKEN"')
        if rc:
            raise Refused("cannot inspect recovery generation: " + err.strip())
        return out.strip()

    @staticmethod
    def read(path):
        if path.is_symlink():
            raise Refused("refusing symlinked adapter state")
        try:
            value = json.loads(path.read_text())
            if not isinstance(value, dict):
                raise ValueError("expected an object")
            return value
        except FileNotFoundError:
            return {}
        except (ValueError, OSError) as e:
            raise Refused("cannot read adapter state: " + str(e)) from e

    @staticmethod
    def atomic(path, data):
        if path.is_symlink():
            raise Refused("refusing symlinked adapter state")
        fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(data, f, indent=2)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

    @contextlib.contextmanager
    def lock(self, name, wait=0):
        path = self.state / (".codex-orca-" + name + ".lock")
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        end = time.monotonic() + wait
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= end:
                        raise Refused("another Orca/Codex " + name + " owns this home")
                    time.sleep(0.1)
            yield
        finally:
            os.close(fd)

    def publish(self, **fields):
        if self.owns_lifetime:
            self.still_owned()
        self.record.update(fields, updated_at=time.time())
        self.atomic(self.record_path, self.record)

    def publish_if_current(self, **fields):
        if self.read(self.record_path).get("generation") == self.record.get("generation"):
            self.publish(**fields)

    def cli(self):
        selected = os.environ.get("ORCA_CLI_COMMAND")
        if not selected:
            selected = "orca-dev" if os.environ.get("ORCA_DEV_REPO_ROOT") else (
                "orca-ide" if sys.platform.startswith("linux") and not os.environ.get("ORCA_TERMINAL_HANDLE") else "orca")
        path = shutil.which(selected)
        if not path:
            raise Refused("selected Orca CLI is unavailable: " + selected)
        return path

    def terminal(self, cli, handle):
        rc, raw, err = self.command([cli, "terminal", "show", "--terminal", handle, "--json"])
        if rc:
            raise Unavailable("exact terminal identity unavailable: " + err.strip())
        try:
            value = json.loads(raw)
            t = value["result"]["terminal"]
            if value.get("ok") is not True or any(t.get(k) is not v for k, v in
                                                  [("connected", True), ("writable", True), ("orphaned", False)]):
                raise ValueError("terminal is not connected/writable")
            result = {k: t[k] for k in ("handle", "incarnationId", "worktreeId", "agentIdentity")}
            result["runtimeId"] = value["_meta"]["runtimeId"]
            if result["handle"] != handle or result["agentIdentity"] != "codex" or not all(result.values()):
                raise ValueError("terminal is not the exact live Codex endpoint")
            if result["worktreeId"].split("::", 1)[1] != str(self.home):
                raise ValueError("terminal worktree is not this primary home")
            return result
        except (ValueError, KeyError, TypeError, IndexError) as e:
            raise Refused("refusing unverified Orca terminal: " + str(e)) from e

    def target_valid(self):
        b = self.record["binding"]
        try:
            if (self.state / ".lock").read_text().strip() != str(b["session_pid"]):
                raise Refused("primary session-lock owner changed")
        except OSError as e:
            raise Refused("primary session lock unavailable") from e
        if self.identity(b["session_pid"]) != b["session_identity"]:
            raise Refused("primary process birth identity changed or died")
        if not self.scope() or self.terminal(b["cli"], b["target"]["handle"]) != b["target"]:
            raise Refused("primary home/runtime/incarnation changed; no rebinding")

    def ready(self, record):
        pid = record.get("owner_pid")
        if not pid or self.identity(pid) != record.get("owner_identity"):
            return False
        health = self.healthy()
        return record.get("phase") == "ready" and health is not None and health == record.get("watcher")

    def ensure(self):
        binding = self.context()
        if not binding:
            return {"applicable": False}
        if not self.needed():
            return {"applicable": True, "needed": False}
        cli = binding["cli"]
        target = binding["target"]
        end = self.operation_deadline
        with self.lock("bootstrap", wait=2):
            return self.bootstrap(binding, cli, target, end)

    def context(self):
        handle = os.environ.get("ORCA_TERMINAL_HANDLE")
        if not handle or not self.scope(caller=True):
            return None
        cli = self.cli()
        target = self.terminal(cli, handle)
        session_pid = int((self.state / ".lock").read_text().strip())
        binding = {"session_pid": session_pid, "session_identity": self.identity(session_pid),
                   "cli": cli, "target": target, "code_root": str(self.code)}
        if not binding["session_identity"]:
            raise Refused("primary identity unavailable")
        return binding

    def bootstrap(self, binding, cli, target, end):
        old = self.read(self.record_path)
        alive = old.get("owner_pid") and self.identity(old["owner_pid"]) == old.get("owner_identity")
        if alive:
            if old.get("binding") != binding:
                raise Refused("live owner has another primary/runtime binding; no adoption")
            while not self.ready(old):
                if old.get("phase") not in ("arming", "ready") or time.monotonic() >= end - 2:
                    raise Refused("existing owner is not ready; inspect its failure/receipt before retrying")
                time.sleep(0.2)
                old = self.read(self.record_path)
            return self.confirmed(old)
        if old.get("phase") == "launching":
            raise Refused("bootstrap generation " + str(old.get("generation")) + " is already pending; inspect status, "
                          "then use abandon-launch for that generation only once its owner is gone")
        same_primary = all((old.get("binding") or {}).get(k) == binding[k]
                           for k in ("session_pid", "session_identity", "target"))
        if same_primary:
            self.confirmed(old)
        generation = uuid.uuid4().hex
        self.record = dict(old, binding=binding, generation=generation, owner_pid=None,
                           owner_identity=None, phase="launching", previous_arm=old.get("arm"))
        if not same_primary:
            self.record.pop("episode", None)
        if old.get("binding") != binding:
            self.record["previous_arm"] = None
        self.publish()
        command = shlex.join(["env", "FM_HOME=" + str(self.home), "NO_COLOR=1", "CLICOLOR=0",
                              "CLICOLOR_FORCE=0", "GH_FORCE_TTY=0", sys.executable,
                              str(self.code / "bin/fm-codex-orca-continuation.py"), "run",
                              "--home", str(self.home), "--code-root", str(self.code),
                              "--generation", generation] + (["--seconds", str(self.args.seconds)] if self.args.seconds else []))
        rc, raw, err = self.command([cli, "terminal", "create", "--worktree", "id:" + target["worktreeId"],
                                    "--title", "Firstmate Codex continuation " + generation, "--command", command,
                                    "--json"], timeout=5)
        self.receipts.mkdir(mode=0o700, exist_ok=True)
        receipt = {"generation": generation, "exit": rc, "stdout": raw, "stderr": err}
        self.atomic(self.receipts / (generation + ".bootstrap.json"), receipt)
        # Do not overwrite run's newer publication when create returns.
        if rc:
            raise Refused("owner terminal creation unconfirmed; no automatic repeat: " + err.strip())
        try:
            created = json.loads(raw)
            if created.get("ok") is not True or not created["result"]["terminal"]["handle"]:
                raise ValueError("missing exact owner terminal receipt")
            receipt["owner_terminal"] = created["result"]["terminal"]["handle"]
            self.atomic(self.receipts / (generation + ".bootstrap.json"), receipt)
        except (ValueError, KeyError, TypeError) as e:
            raise Refused("owner terminal receipt unconfirmed; inspect before repeating") from e
        while time.monotonic() < end:
            current = self.read(self.record_path)
            if current.get("generation") != generation:
                raise Refused("owner generation superseded during bootstrap")
            if self.ready(current):
                return self.confirmed(current)
            if current.get("phase") in ("failed", "stopped"):
                raise Refused("owner did not become ready: " + current.get("error", "stopped"))
            time.sleep(0.1)
        raise Refused("owner readiness unconfirmed at bounded bootstrap deadline")

    def confirmed(self, record):
        episode = record.get("episode", {})
        generation = episode.get("generation", "")
        token = self.recovery()
        if episode.get("phase") in ("sending", "delivery-unknown", "delivery-rejected"):
            if token.split(":")[-1] == generation and not token.startswith("acked:"):
                raise Refused("delivery is unconfirmed; inspect exact receipt and drain durable work, no fresh resend")
        if self.reopened(episode, token) and not self.replayable(episode, token):
            raise Refused("presented generation reopened without ACK and is not re-presentable; drain and acknowledge it")
        return self.with_bootstrap(record)

    def abandon_launch(self):
        current = self.context()
        if not current:
            raise Refused("abandon-launch requires the verified lock-owning Orca/Codex primary")
        with self.lock("bootstrap", wait=2), self.lock("owner"):
            record = self.read(self.record_path)
            generation = self.args.generation
            if not generation or record.get("phase") != "launching" or record.get("generation") != generation:
                raise Refused("abandon-launch requires the exact pending launching generation")
            rc, out, _ = self.command(["ps", "-axo", "pid=,args="])
            if rc or any(" run " in line and "--generation " + generation in line
                         for line in out.splitlines() if line.split(None, 1)[0] != str(os.getpid())):
                raise Refused("owner process for this generation may be live; no abandonment")
            rc, raw, err = self.command([current["cli"], "terminal", "list", "--json"])
            try:
                terminals = json.loads(raw)["result"]["terminals"] if rc == 0 else None
                handles = {t["handle"] for t in terminals}
                titles = [t.get("title") or "" for t in terminals]
            except (ValueError, KeyError, TypeError) as e:
                raise Refused("owner terminal absence unproven: terminal list unreadable") from e
            if current["target"]["handle"] not in handles:
                raise Refused("owner terminal absence unproven: terminal list is incomplete")
            owner_terminal = self.read(self.receipts / (generation + ".bootstrap.json")).get("owner_terminal")
            if owner_terminal in handles or any(generation in title for title in titles):
                raise Refused("owner terminal for this generation is live; close or inspect it, no abandonment")
            self.receipts.mkdir(mode=0o700, exist_ok=True)
            self.atomic(self.receipts / (generation + ".abandon.json"),
                        {"generation": generation, "terminals": raw, "at": time.time()})
            self.record = record
            self.publish(phase="failed", error="launch abandoned after proven owner absence")
        return self.with_bootstrap(self.record)

    def with_bootstrap(self, record):
        result = dict(record)
        generation = result.get("generation", "")
        if re.fullmatch(r"[A-Za-z0-9._-]+", generation):
            result["bootstrap"] = self.read(self.receipts / (generation + ".bootstrap.json"))
        return result

    def reap(self, p):
        if p.poll() is None:
            # The arm forwards TERM only after watcher cleanup is ready. A
            # group TERM here would also kill its lock-publication helpers.
            if p in self.arms:
                p.send_signal(signal.SIGTERM)
            else:
                os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15 if p in self.arms else 3)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait(timeout=3)

    def recover_transport(self):
        old = self.record.get("transport") or {}
        pid, identity = old.get("pid"), old.get("identity")
        if pid and identity and self.identity(pid) == identity:
            if os.getpgid(pid) != pid:
                raise Refused("recorded transport process group changed; no signalling")
            os.killpg(pid, signal.SIGTERM)
            end = time.monotonic() + 3
            while self.identity(pid) == identity and time.monotonic() < end:
                time.sleep(0.1)
            if self.identity(pid) == identity:
                os.killpg(pid, signal.SIGKILL)
                end = time.monotonic() + 3
                while self.identity(pid) == identity and time.monotonic() < end:
                    time.sleep(0.1)
                if self.identity(pid) == identity:
                    raise Refused("recorded transport did not stop at recovery deadline")
        self.publish(transport=None)

    def start_arm(self, predecessor=None, takeover=None):
        env = dict(self.env)
        env.pop("FM_WATCH_HANDLING_SUCCESSOR", None)
        env.pop("FM_WATCH_PREDECESSOR_ARM_PID", None)
        if predecessor:
            env["FM_WATCH_PREDECESSOR_ARM_PID"] = str(predecessor)
        self.arm_file = tempfile.TemporaryFile(mode="w+t")
        self.arm_files.append(self.arm_file)
        argv = ["bash", "-c", '[ ! -f "$FM_CONFIG_OVERRIDE/x-mode.env" ] || . "$FM_CONFIG_OVERRIDE/x-mode.env"; exec bash "$@"',
                "continuation-arm", str(self.code / "bin/fm-watch-arm.sh")]
        if takeover:
            argv += ["--take-over", str(takeover)]
        self.arm = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=self.arm_file,
                                    stderr=subprocess.STDOUT, text=True, start_new_session=True)
        self.children.append(self.arm)
        self.arms.add(self.arm)
        self.publish(phase="arming", arm={"pid": self.arm.pid, "identity": self.identity(self.arm.pid)})
        end = time.monotonic() + 15
        while time.monotonic() < end:
            health = self.healthy()
            if self.arm.poll() is None and health:
                self.arm_file.seek(0)
                raw = self.arm_file.read()
                if re.search(r"^watcher: (?:started|attached) pid=" + health[0] + r"\b", raw, re.M):
                    self.publish(phase="ready", watcher=health)
                    return True
            if self.arm.poll() is not None:
                self.arm_file.seek(0)
                raw = self.arm_file.read()
                if self.arm.returncode == 0 and re.search(r"^(signal:|stale:|check:|heartbeat(?:$|:))", raw, re.M):
                    return False
                break
            time.sleep(0.1)
        raise Refused("arm failed to establish a verified singleton successor")

    def retire_arm(self, p, output):
        self.reap(p)
        if p in self.children:
            self.children.remove(p)
        self.arms.discard(p)
        if not output.closed:
            output.close()
        self.arm_files.remove(output)

    def protected_arm(self, predecessor=None, takeover=None):
        # A take-over can race a real actionable close and return that reason
        # instead of starting a watcher. Preserve its queue, then establish the
        # successor before any input; never notify against that closing arm.
        for _ in range(3):
            if self.start_arm(predecessor=predecessor, takeover=takeover):
                return
            predecessor = self.arm.pid
            self.retire_arm(self.arm, self.arm_file)
            takeover = None
        raise Refused("successors repeatedly closed before readiness; wake remains durable")

    def observe_external_queue(self):
        token = self.recovery()
        if not token.startswith("pending:downtime:"):
            return
        generation = token.split(":")[-1]
        episode = self.record.get("episode", {})
        if generation == episode.get("generation") and not self.replayable(episode, token):
            return
        self.target_valid()
        self.still_owned()
        health = self.healthy()
        old, output = self.arm, self.arm_file
        if old.poll() is not None or not health or health != self.record.get("watcher"):
            return  # Ordinary actionable-close path establishes the successor.
        if self.identity(old.pid) != self.record["arm"]["identity"]:
            raise Refused("current arm birth identity changed before queued-wake takeover")
        # The public take-over stops only this arm's own child. For an attached
        # peer it protects a new attached arm without signalling that watcher.
        self.protected_arm(predecessor=old.pid, takeover=old.pid)
        self.retire_arm(old, output)
        token = self.recovery()
        if token.startswith(("pending:", "announced:")):
            self.deliver(token.split(":")[-1])

    def still_owned(self):
        current = self.read(self.record_path)
        if current.get("generation") != self.record["generation"]:
            raise Refused("owner generation superseded")

    @staticmethod
    def reopened(episode, token):
        generation = episode.get("generation", "")
        return bool(episode.get("handling_confirmed")) and token in ("pending:downtime:" + generation,
                                                                     "announced:downtime:" + generation)

    def replayable(self, episode, token):
        # Only a confirmed turn start whose handling generation reopened as
        # downtime without ACK is presented once more; never an ambiguous one.
        return self.reopened(episode, token) and episode.get("phase") == "turn-started" and not episode.get("replay_of")

    def deliver(self, generation):
        token = self.recovery()
        if not token.startswith(("pending:", "announced:")) or token.split(":")[-1] != generation:
            return
        prior = self.record.get("episode", {})
        if prior.get("generation") == generation:
            # Sending/unknown persists across death: never invent a new request.
            if not self.replayable(prior, token):
                return
        else:
            prior = None
        payload = "watcher: Orca/Codex wake generation=" + generation + ". Drain queued wakes, handle them, and acknowledge the exact presented generation. The continuation owner protects the successor."
        episode = {"generation": generation, "payload": payload, "phase": "sending", "attempts": [],
                   "owner_generation": self.record["generation"], "owner_pid": self.record["owner_pid"],
                   "owner_identity": self.record["owner_identity"], "binding": self.record["binding"]}
        if prior:
            episode.update(replay_of=prior.get("request_id"), replay_prior=prior)
        b = self.record["binding"]
        retry = None
        for attempt in range(2):
            self.target_valid()
            self.still_owned()
            if not self.ready(self.record):
                if attempt == 0:
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        self.arm.wait(timeout=3)
                        return
                raise Refused("identity-bound successor lost before notification")
            health = self.record["watcher"]
            if attempt == 0:
                self.publish(episode=episode)
            submitted_at = time.time()
            rc, out, err = self.shell('. "$1/bin/backends/orca.sh"; '
                                      'fm_backend_orca_primary_send "$2" "$3" "$4" "$5" "${6:-}"',
                                      b["cli"], b["target"]["handle"], payload, "10", retry or "", timeout=15,
                                      owned_transport=True)
            row = {"exit": rc, "stdout": out, "stderr": err, "retry_request": retry,
                   "successor": health, "submitted_at": submitted_at, "at": time.time()}
            episode["attempts"].append(row)
            episode["phase"] = "delivery-unknown"
            try:
                v = json.loads(out)
                send = v.get("result", {}).get("send", {})
                prompt = send.get("prompt", {})
                if (rc == 0 and v.get("ok") is True and send.get("accepted") is True
                        and send.get("handle") == b["target"]["handle"]
                        and v.get("_meta", {}).get("runtimeId") == b["target"]["runtimeId"]
                        and prompt.get("processIncarnation") == b["target"]["incarnationId"]
                        and prompt.get("provider") == "codex" and isinstance(prompt.get("requestId"), str)
                        and prompt["requestId"] and (not retry or prompt["requestId"] == retry)
                        and isinstance(prompt.get("stages"), list)
                        and "input_accepted" in prompt.get("stages", [])):
                    episode.update(request_id=prompt["requestId"], stages=prompt["stages"],
                                   phase="turn-started" if "turn_started" in prompt["stages"] else "input-accepted-unproven")
                    break
                if v.get("ok") is False:
                    episode["phase"] = "delivery-rejected"
            except (ValueError, TypeError):
                pass
            # The installed CLI's reported exact retry command is the authority.
            match = re.search(r"--retry-request[ =]+([A-Za-z0-9_-]+)", out + "\n" + err)
            if attempt == 0 and match:
                retry = match.group(1)
                episode["permitted_retry"] = retry
                self.publish(episode=episode)
                continue
            break
        self.receipts.mkdir(mode=0o700, exist_ok=True)
        self.atomic(self.receipts / (generation + ".json"), episode)
        retained = sorted((p for p in self.receipts.glob("*.json") if not p.is_symlink()
                           and not p.name.endswith((".bootstrap.json", ".cleanup.json", ".abandon.json"))
                           and re.fullmatch(r"[A-Za-z0-9._-]+\.json", p.name)), key=lambda p: p.stat().st_mtime)
        for p in retained[:-64]:
            p.unlink()
        self.publish(episode=episode)
        if episode["phase"] in ("turn-started", "input-accepted-unproven"):
            health = self.healthy()
            if not health or health != self.record.get("watcher"):
                raise Refused("successor lost after delivery; wake remains durable")
            rc, _, _ = self.command(["bash", str(self.code / "bin/fm-watch-arm.sh"),
                                      "--handling-delivered", generation, "--watcher-pid", health[0]])
            if rc == 3:
                # Root can ACK this episode and receive a new append before
                # the transport receipt returns. The public typed refusal says
                # its generation moved; it does not invalidate the exact input
                # receipt or authorize acknowledging/rebinding the new one.
                token = self.recovery()
                if (token.startswith(("pending:", "announced:", "acked:"))
                        and token.split(":")[-1] != generation and self.healthy() == health):
                    self.target_valid()
                    self.still_owned()
                    episode["confirmation_superseded_by"] = token
                    self.atomic(self.receipts / (generation + ".json"), episode)
                    self.publish(episode=episode)
                    return
            if rc:
                raise Refused("generation-bound handling delivery confirmation failed")
            episode["handling_confirmed"] = True
            self.atomic(self.receipts / (generation + ".json"), episode)
            self.publish(episode=episode)
        else:
            print("continuation: " + episode["phase"] + "; wake durable, successor protected, no fresh resend", flush=True)

    def run(self):
        self.record = self.read(self.record_path)
        if not self.args.generation or self.record.get("generation") != self.args.generation:
            raise Refused("run requires the current verified bootstrap generation")
        with contextlib.ExitStack() as lifetime:
            try:
                self.target_valid()
                lifetime.enter_context(self.lock("owner"))
                self.owns_lifetime = True
                self.publish(owner_pid=os.getpid(), owner_identity=self.identity(os.getpid()), phase="arming")
            except Exception as e:
                # No owner ever published: resolve the confirmed create as failed
                # so ensure does not wait on it forever. A live owner is untouched.
                current = self.read(self.record_path)
                if current.get("generation") == self.args.generation and current.get("phase") == "launching":
                    self.record = current
                    self.publish(phase="failed", error="owner did not start: " + str(e))
                raise
            previous = self.record.get("previous_arm") or {}
            takeover = previous.get("pid") if previous.get("identity") and self.identity(previous.get("pid")) == previous["identity"] else None
            try:
                self.recover_transport()
                self.protected_arm(takeover=takeover)
                token = self.recovery()
                if token.startswith(("pending:", "announced:")):
                    self.deliver(token.split(":")[-1])
                last_identity_check = time.monotonic()
                while not self.stopping:
                    if self.deadline and time.monotonic() >= self.deadline:
                        break
                    self.still_owned()
                    if time.monotonic() - last_identity_check >= 2:
                        try:
                            self.target_valid()
                            if not self.needed():
                                break
                        except Unavailable as e:
                            print("continuation: observation unavailable; watcher retained: " + str(e), flush=True)
                        else:
                            self.observe_external_queue()
                        last_identity_check = time.monotonic()
                    if self.arm.poll() is not None:
                        rc = self.arm.wait()
                        self.arm_file.seek(0)
                        raw = self.arm_file.read()
                        if rc or not re.search(r"^(signal:|stale:|check:|heartbeat(?:$|:))", raw, re.M):
                            raise Refused("arm closed without an actionable wake: " + raw[-1500:])
                        predecessor = self.arm.pid
                        self.retire_arm(self.arm, self.arm_file)
                        self.protected_arm(predecessor=predecessor)
                        token = self.recovery()
                        if token.startswith(("pending:", "announced:")):
                            self.deliver(token.split(":")[-1])
                    time.sleep(0.2)
                self.publish(phase="stopped", error="bounded test ended" if self.deadline else "supervision no longer needed")
            except Exception as e:
                self.publish_if_current(phase="failed", error=str(e))
                raise
            finally:
                for p in self.children:
                    self.reap(p)
                cleanup = {"children": [{"pid": p.pid, "exit": p.returncode} for p in self.children],
                           "watcher_healthy": self.healthy() is not None,
                           "watcher_lock_remaining": (self.state / ".watch.lock/pid").exists()}
                self.receipts.mkdir(mode=0o700, exist_ok=True)
                self.atomic(self.receipts / (self.record["generation"] + ".cleanup.json"), cleanup)
                self.publish_if_current(cleanup=cleanup)
                for output in self.arm_files:
                    if not output.closed:
                        output.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=("context", "ensure", "run", "status", "abandon-launch"))
    parser.add_argument("--home", required=True)
    parser.add_argument("--code-root")
    parser.add_argument("--generation")
    parser.add_argument("--seconds", type=float)
    args = parser.parse_args()
    if args.seconds is not None and args.seconds <= 0:
        parser.error("--seconds must be positive")
    os.umask(0o077)
    adapter = Adapter(args)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda _s, _f: setattr(adapter, "stopping", True))
    error = None
    result = None
    try:
        if args.mode == "run":
            adapter.run()
        elif args.mode == "context":
            result = adapter.context()
            if result is None:
                return 3
        elif args.mode == "status":
            result = adapter.with_bootstrap(adapter.read(adapter.record_path))
            result["ready"] = adapter.ready(result) if result else False
        elif args.mode == "abandon-launch":
            result = adapter.abandon_launch()
        else:
            result = adapter.ensure()
    except (Refused, OSError, ValueError, KeyError) as e:
        error = str(e)
        print("continuation: " + error, file=sys.stderr)
    if result is not None:
        print(json.dumps(result, indent=2))
    return 1 if error else 0


if __name__ == "__main__":
    sys.exit(main())
