#!/usr/bin/env python3
"""FirstMate's bounded Codex stdio adapter, not a general RPC transport.

run STATE TASK GEN BRIEF WORKTREE [MODEL [EFFORT]] hosts one thread and turn.
control STATE TASK GEN steer|answer|interrupt|exit [KEY] reads text from stdin.
The private Unix socket is transient transport only. Decisions remain status-log
records; callbacks exist only in this process. Worker roots exclude fleet state.
"""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import secrets
import signal
import socket
import subprocess
import sys
import threading
import time

BIN = Path(__file__).resolve().parent
from fm_codex_git import PrivateGit, PrivateGitVerificationError
REPORT_LIMIT = 262144
LIMIT = 8192
# JSON can encode each accepted input byte as a six-byte escape. Include
# bounded supervisor identity fields and framing in the transport budget.
CONTROL_LIMIT = 6 * LIMIT + 4096
PROTOCOL_LIMIT = 6 * REPORT_LIMIT + CONTROL_LIMIT
TOKEN = re.compile(r"[A-Za-z0-9._-]{1,160}\Z")
TOOL = {"type": "function", "name": "firstmate_report",
        "description": "Report to FirstMate. needs-decision waits for the supervisor's answer in this same turn. result is delivery evidence, not terminal success.",
        "inputSchema": {"type": "object", "properties": {
            "type": {"type": "string", "enum": ["progress", "needs-decision", "result"]},
            "message": {"type": "string", "minLength": 1, "maxLength": 500},
            "report": {"type": "string", "minLength": 1, "maxLength": REPORT_LIMIT}},
            "required": ["type", "message"], "additionalProperties": False}}


def payload(value):
    if (not isinstance(value, dict) or not {"type", "message"} <= set(value)
            or set(value) - {"type", "message", "report"}):
        raise ValueError("expected type, message and optional report")
    if value["type"] not in ("progress", "needs-decision", "result"):
        raise ValueError("unknown report type")
    text = value["message"]
    if not isinstance(text, str) or not 1 <= len(text.encode()) <= 500:
        raise ValueError("report size")
    if any(ord(c) < 32 or ord(c) == 127 for c in text):
        raise ValueError("report control character")
    report = value.get("report")
    if "report" in value and (value["type"] != "result" or not isinstance(report, str)
            or not 1 <= len(report.encode()) <= REPORT_LIMIT or "\x00" in report):
        raise ValueError("invalid result report")
    return value["type"], text, report


def socket_path(state, task, gen):
    nonce = hashlib.sha256((task + ":" + gen).encode()).hexdigest()[:24]
    path = state / (".appserver-" + nonce + ".sock")
    if len(os.fsencode(path)) >= 104:
        raise ValueError("app-server socket path exceeds portable Unix socket limit")
    return path


class Adapter:
    def __init__(self, state, task, gen, data):
        self.state, self.task, self.gen, self.data = state.resolve(), task, gen, data.resolve()
        if not TOKEN.fullmatch(task) or not TOKEN.fullmatch(gen):
            raise ValueError("invalid supervisor binding")
        self.thread = self.turn = None
        self.active = False
        self.result = None
        self.scout_report = None
        self.pending = None
        self.calls = set()
        self.requests = set()
        self.sequence = 0
        self.responses = {}
        self.events = queue.Queue(maxsize=1024)
        self.proc = None
        self.stopping = False
        self.terminal = None
        self.private_git = None
        self.private_root = None
        self.path = socket_path(self.state, task, gen)
        self.check()

    def check(self):
        if (self.state / (self.task + ".busy-gen")).read_text().strip() != self.gen:
            raise ValueError("stale generation")
        meta = dict(line.split("=", 1) for line in
                    (self.state / (self.task + ".meta")).read_text().splitlines() if "=" in line)
        if meta.get("busy_gen") != self.gen or meta.get("codex_transport") != "appserver":
            raise ValueError("metadata generation/transport mismatch")

    @contextlib.contextmanager
    def bound(self):
        lock = self.state / (self.task + ".busy-state.lock")
        deadline = time.monotonic() + 2
        while True:
            try:
                lock.mkdir()
                break
            except FileExistsError:
                if time.monotonic() >= deadline:
                    raise ValueError("generation lock timeout")
                time.sleep(.02)
        try:
            self.check()
            yield
        finally:
            lock.rmdir()

    def busy(self, state, event):
        subprocess.run(["bash", str(BIN / "fm-busy-event.sh"), "apply", str(self.state),
                        self.task, state, "--gen", self.gen, "--source", "codex-appserver",
                        "--event", event], check=True, stdout=subprocess.DEVNULL)

    def report(self, text):
        subprocess.run(["bash", str(BIN / "fm-busy-event.sh"), "report", str(self.state),
                        self.task, "--gen", self.gen], input=text, text=True, check=True)

    def retire_pending(self):
        if self.pending:
            key = self.pending["key"]
            self.pending = None
            self.report("resolved [key=" + key + "]: callback retired because its turn stopped")

    def write(self, message):
        with self.bound():
            self.proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
            self.proc.stdin.flush()

    def reader(self):
        try:
            while True:
                line = self.proc.stdout.readline(PROTOCOL_LIMIT + 1)
                if not line:
                    break
                if len(line) > PROTOCOL_LIMIT or not line.endswith("\n"):
                    self.events.put(ValueError("oversized protocol message"))
                    if self.proc is not None and self.proc.poll() is None:
                        with contextlib.suppress(ProcessLookupError):
                            os.killpg(self.proc.pid, signal.SIGKILL)
                    break
                try:
                    self.events.put(json.loads(line))
                except ValueError:
                    self.events.put(ValueError("malformed protocol message"))
                    break
        finally:
            self.events.put(EOFError("app-server stdout closed"))

    def rpc(self, method, params, timeout=30):
        self.sequence += 1
        ident = "fm-" + str(self.sequence)
        self.write({"id": ident, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while ident not in self.responses:
            self.pump(max(.01, deadline - time.monotonic()))
            if time.monotonic() >= deadline:
                raise TimeoutError(method)
        reply = self.responses.pop(ident)
        if "error" in reply:
            raise ValueError(str(reply["error"]))
        return reply["result"]

    def tool_reply(self, ident, text, success=True):
        self.write({"id": ident, "result": {"contentItems": [
            {"type": "inputText", "text": text}], "success": success}})

    def correlate(self, params):
        self.check()
        if params.get("threadId") != self.thread or params.get("turnId") != self.turn or not self.active:
            raise ValueError("wrong or retired thread/turn")

    def tool(self, msg):
        p = msg["params"]
        ident = msg["id"]
        # Never answer a repeated request id: it could prematurely resolve the
        # original pending decision. Treat broken server correlation as fatal.
        if type(ident) not in (int, str) or ident in self.requests:
            raise ValueError("duplicate or malformed request identity")
        try:
            self.correlate(p)
            if self.stopping:
                raise ValueError("worker is stopping")
            if p.get("tool") != "firstmate_report" or p.get("namespace") not in (None, ""):
                raise ValueError("unknown tool")
            call = p.get("callId")
            if (not isinstance(call, str) or not 1 <= len(call) <= 160
                    or call in self.calls or len(self.calls) >= 4096):
                raise ValueError("duplicate or malformed call")
            kind, text, report = payload(p.get("arguments"))
            self.calls.add(call)
            self.requests.add(ident)
            if self.pending:
                raise ValueError("a decision already owns the pending response")
            if kind == "needs-decision":
                key = "codex-" + self.gen + "-" + str(len(self.calls))
                self.report("needs-decision [key=" + key + "]: " + text)
                self.pending = {"id": msg["id"], "key": key, "answer": None}
                return
            if kind == "result":
                if self.result is not None:
                    raise ValueError("result already reported")
                with self.bound():
                    meta = dict(line.split("=", 1) for line in
                                (self.state / (self.task + ".meta")).read_text().splitlines() if "=" in line)
                    if meta.get("kind") == "scout":
                        if report is None:
                            raise ValueError("scout result requires report content")
                        self.scout_report = report
                    elif report is not None:
                        raise ValueError("report content is only accepted for scouts")
                    self.result = text
            else:
                self.report("working: " + text)
            self.tool_reply(msg["id"], "accepted " + kind)
        except ValueError as exc:
            self.tool_reply(msg["id"], str(exc), False)

    def pump(self, timeout=.1):
        try:
            msg = self.events.get(timeout=min(timeout, 30))
        except queue.Empty:
            return
        if isinstance(msg, Exception):
            raise msg
        if not isinstance(msg, dict):
            raise ValueError("protocol object required")
        method = msg.get("method")
        if method is None and "id" in msg:
            if not isinstance(msg["id"], str) or msg["id"] != "fm-" + str(self.sequence):
                raise ValueError("unexpected response identity")
            self.responses[msg["id"]] = msg
            return
        if not isinstance(method, str):
            raise ValueError("protocol method required")
        p = msg.get("params", {})
        if not isinstance(p, dict):
            raise ValueError("notification params must be an object")
        if "id" in msg:
            if method == "item/tool/call":
                self.tool(msg)
            elif method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
                self.write({"id": msg["id"], "result": {"decision": "decline"}})
            else:
                self.write({"id": msg["id"], "error": {"code": -32601, "message": "unsupported worker request"}})
            return
        if method in ("turn/started", "turn/completed") and not isinstance(p.get("turn"), dict):
            raise ValueError("notification turn must be an object")
        if method.startswith("item/") and "item" in p and not isinstance(p["item"], dict):
            raise ValueError("notification item must be an object")
        if method in ("turn/started", "turn/completed") or (
                method == "item/completed" and p.get("item", {}).get("type") == "commandExecution"):
            print(json.dumps({"method": method, "params": p}), flush=True)
        if method == "turn/started":
            turn = p.get("turn", {})
            if p.get("threadId") != self.thread or turn.get("status") != "inProgress" or not isinstance(turn.get("id"), str):
                raise ValueError("invalid turn start")
            if self.turn is not None and self.turn != turn["id"]:
                raise ValueError("unexpected replacement turn")
            self.turn, self.active = turn["id"], True
            self.busy("busy", "turn-started")
        elif method == "turn/completed":
            turn = p.get("turn", {})
            self.correlate({"threadId": p.get("threadId"), "turnId": turn.get("id")})
            status = turn.get("status")
            if status not in ("completed", "failed", "interrupted"):
                raise ValueError("invalid terminal status")
            self.active = False
            self.retire_pending()
            self.terminal = status
            if status == "completed" and self.result is not None:
                if self.scout_report is not None:
                    try:
                        with self.bound():
                            self.publish_scout_report(self.scout_report)
                    except (OSError, ValueError):
                        self.result = None
                        self.scout_report = None
                        self.terminal = "failed"
                        self.report("failed: supervisor refused scout report publication")
                        self.busy("idle", "turn-failed")
                        return
                if self.private_git is not None:
                    try:
                        oid = self.private_git.publish(self.private_root.parent)
                    except PrivateGitVerificationError:
                        self.result = None
                        self.terminal = "failed"
                        self.report("failed: supervisor verification refused private Git publication "
                                    "[private-git-verification-refused]")
                        self.busy("idle", "turn-failed")
                        self.stopping = True
                        return
                    self.result += " (task commit " + oid[:12] + ")"
                self.report("done: " + self.result)
            elif status != "completed":
                self.result = None
                self.scout_report = None
                self.report("failed: app-server turn " + status)
            event = "turn-completed-result" if status == "completed" and self.result is not None else "turn-" + status
            self.busy("idle", event)
        elif method == "item/agentMessage/delta":
            print(p.get("delta", ""), end="", flush=True)

    def publish_scout_report(self, report):
        data = self.data
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        data_fd = os.open(data, directory_flags)
        task_fd = None
        temporary = ".report." + self.gen + "." + secrets.token_hex(8) + ".tmp"
        fd = None
        try:
            try:
                task_fd = os.open(self.task, directory_flags, dir_fd=data_fd)
            except FileNotFoundError:
                os.mkdir(self.task, 0o700, dir_fd=data_fd)
                task_fd = os.open(self.task, directory_flags, dir_fd=data_fd)
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         os.O_NOFOLLOW, 0o600, dir_fd=task_fd)
            body = report.encode("utf-8")
            view = memoryview(body)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
            os.close(fd)
            fd = None
            # link() creates the final name atomically and refuses to replace an
            # existing report, including a symlink left by another generation.
            try:
                os.link(temporary, "report.md", src_dir_fd=task_fd,
                        dst_dir_fd=task_fd, follow_symlinks=False)
            except FileExistsError as exc:
                raise ValueError("scout report already exists") from exc
            os.fsync(task_fd)
        finally:
            if fd is not None:
                os.close(fd)
            if task_fd is not None:
                try:
                    os.unlink(temporary, dir_fd=task_fd)
                except FileNotFoundError:
                    pass
                os.close(task_fd)
            os.close(data_fd)

    def decisions(self):
        return subprocess.check_output(["bash", "-c",
            'source "$1/fm-classify-lib.sh"; status_open_decisions "$2"',
            "bash", str(BIN), str(self.state / (self.task + ".status"))], text=True)

    def answer_ready(self):
        if self.pending and self.pending["answer"] is not None:
            keys = [row.split("\t")[0] for row in self.decisions().splitlines()]
            if self.pending["key"] not in keys:
                # A transfer closes the status key before its captain call is
                # answered. Ask the canonical owner about both supported ids;
                # an unreadable backlog must never release the callback.
                hold_script = ["bash", str(BIN / "fm-captain-hold.sh")]
                hold_env = dict(os.environ, FM_STATE_OVERRIDE=str(self.state),
                                FM_DATA_OVERRIDE=str(self.data))
                bound = subprocess.run(hold_script + ["binding", self.task],
                    capture_output=True, text=True, env=hold_env)
                if bound.returncode not in (0, 1):
                    return
                held_ids = [self.pending["key"], self.task + "-decision-" + self.pending["key"]]
                if bound.returncode == 0:
                    identity = bound.stdout.strip()
                    if not TOKEN.fullmatch(identity):
                        return
                    held_ids.insert(0, identity)
                for held in dict.fromkeys(held_ids):
                    result = subprocess.run(hold_script + [
                        "open", held, "--distinguish-absent"], env=hold_env,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    if result.returncode not in (1, 3):
                        return
                self.tool_reply(self.pending["id"], self.pending["answer"])
                self.pending = None

    def command(self, data):
        if not isinstance(data, dict) or set(data) != {"generation", "operation", "key", "text"}:
            raise ValueError("malformed control")
        if data["generation"] != self.gen:
            raise ValueError("stale generation")
        self.check()
        op, text = data["operation"], data["text"]
        if not isinstance(text, str) or len(text.encode()) > LIMIT:
            raise ValueError("control text too large")
        if op == "status":
            if self.proc.poll() is not None:
                raise ValueError("app-server process exited")
            return "alive " + str(self.thread) + " " + str(self.turn)
        if op == "answer":
            if not self.active or not self.pending or self.pending["key"] != data["key"]:
                raise ValueError("no matching pending decision")
            if self.pending["answer"] not in (None, text) or not text.strip():
                raise ValueError("duplicate or empty answer")
            self.pending["answer"] = text
            return "answer accepted; waiting for canonical decision closure"
        if data["key"]:
            raise ValueError("key only valid for answer")
        if op == "steer":
            if not text.strip() or not self.active or self.pending or self.decisions().strip():
                raise ValueError("steer requires active turn without an open decision")
            reply = self.rpc("turn/steer", {"threadId": self.thread, "expectedTurnId": self.turn,
                "input": [{"type": "text", "text": text, "text_elements": []}]})
            if reply.get("turnId") != self.turn:
                raise ValueError("steer turn mismatch")
            return "steered " + self.turn
        if op in ("interrupt", "exit"):
            self.stopping = True
            try:
                # Retire callback ownership before pumping further protocol
                # events, and prevent a racing completion from using a result.
                self.result = None
                self.retire_pending()
                if self.active:
                    self.rpc("turn/interrupt", {"threadId": self.thread, "turnId": self.turn})
                    deadline = time.monotonic() + 15
                    while self.active and time.monotonic() < deadline:
                        self.pump(.1)
                    if self.active:
                        raise TimeoutError("interrupt terminal event missing")
            except (ValueError, OSError, EOFError, TimeoutError, subprocess.SubprocessError):
                self.active = False
                self.result = None
                try:
                    self.report("failed: app-server cancellation was not verified")
                finally:
                    self.busy("unknown", "interrupt-unverified")
                raise
            finally:
                self.pending = None
                self.shutdown()
            return "stopped app-server pid=" + str(self.proc.pid) + " exit=" + str(self.proc.returncode)
        raise ValueError("unknown control operation")

    def serve_control(self, listener):
        try:
            conn, _ = listener.accept()
        except BlockingIOError:
            return
        with conn:
            conn.settimeout(2)
            try:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(CONTROL_LIMIT + 1 - len(data))
                    if not chunk:
                        raise ValueError("invalid control framing")
                    data += chunk
                    if len(data) > CONTROL_LIMIT:
                        raise ValueError("invalid control framing")
                result = {"ok": True, "message": self.command(json.loads(data))}
            except (ValueError, TimeoutError, OSError, EOFError, subprocess.SubprocessError) as exc:
                result = {"ok": False, "message": str(exc)}
            try:
                conn.sendall(json.dumps(result).encode() + b"\n")
            except BrokenPipeError:
                pass

    def shutdown(self):
        self.pending = None
        if self.proc is None:
            return
        if self.proc.stdin and not self.proc.stdin.closed:
            with contextlib.suppress(OSError):
                self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait()

    def run(self, brief, worktree, model, effort):
        worktree = worktree.resolve()
        if self.state == worktree or worktree in self.state.parents:
            raise ValueError("worker workspace would grant fleet state")
        listener = socket.socket(socket.AF_UNIX)
        meta = dict(line.split("=", 1) for line in
                    (self.state / (self.task + ".meta")).read_text().splitlines() if "=" in line)
        writable_roots = []
        if meta.get("kind") == "ship":
            if not meta.get("branch"):
                raise ValueError("app-server ship has no supervisor-selected branch")
            parent = Path("/dev/shm/firstmate-appserver")
            parent.mkdir(mode=0o700, exist_ok=True)
            if (parent.is_symlink() or not parent.is_dir()
                    or parent.stat().st_uid != os.getuid()):
                raise ValueError("private Git parent is not a supervisor-owned directory")
            if parent.stat().st_mode & 0o077:
                os.chmod(parent, 0o700)
            task_dir = parent / self.task
            task_dir.mkdir(mode=0o700, exist_ok=True)
            if task_dir.is_symlink() or not task_dir.is_dir() or task_dir.stat().st_uid != os.getuid():
                raise ValueError("private Git task directory is unsafe")
            if task_dir.stat().st_mode & 0o077:
                os.chmod(task_dir, 0o700)
            self.private_root = task_dir / self.gen
            self.private_git = PrivateGit(worktree, self.private_root, meta["branch"],
                                         self.task, self.gen)
            writable_roots.append(str(self.private_root))
        # bind is exclusive for this generation. A competing launch must not
        # overwrite lifecycle evidence or remove the existing owner's socket.
        try:
            listener.bind(str(self.path))
        except BaseException:
            listener.close()
            if self.private_git is not None:
                self.private_git.cleanup()
            raise
        try:
            os.chmod(self.path, 0o600)
            listener.listen(4)
            listener.setblocking(False)
            self.proc = subprocess.Popen(["codex", "app-server", "--stdio", "--disable", "hooks",
                "-c", 'approval_policy="never"', "-c", 'sandbox_mode="workspace-write"'],
                cwd=worktree, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                start_new_session=True)
            print("app-server started pid=" + str(self.proc.pid), flush=True)
            threading.Thread(target=self.reader, daemon=True).start()
            self.rpc("initialize", {"clientInfo": {"name": "firstmate", "version": "1"},
                "capabilities": {"experimentalApi": True}})
            self.write({"method": "initialized", "params": {}})
            params = {"cwd": str(worktree), "ephemeral": True, "sandbox": "workspace-write",
                "approvalPolicy": "never", "dynamicTools": [TOOL], "config": {
                    "features.hooks": False, "sandbox_workspace_write.writable_roots": writable_roots,
                    "sandbox_workspace_write.network_access": False,
                    "sandbox_workspace_write.exclude_slash_tmp": True,
                    "sandbox_workspace_write.exclude_tmpdir_env_var": True}}
            if model:
                params["model"] = model
            reply = self.rpc("thread/start", params)
            sandbox = reply.get("sandbox", {})
            expected_extra = {Path(root).resolve() for root in writable_roots}
            actual_roots = {Path(root).resolve() for root in sandbox.get("writableRoots", [])}
            permitted_roots = {worktree} | expected_extra
            if (reply.get("approvalPolicy") != "never" or reply.get("cwd") != str(worktree)
                    or reply.get("runtimeWorkspaceRoots") != [str(worktree)] + writable_roots
                    or sandbox.get("type") != "workspaceWrite"
                    or sandbox.get("networkAccess") is not False
                    or sandbox.get("excludeSlashTmp") is not True
                    or sandbox.get("excludeTmpdirEnvVar") is not True
                    or not expected_extra.issubset(actual_roots)
                    or not actual_roots.issubset(permitted_roots)):
                raise ValueError("server did not establish the required worker sandbox")
            self.thread = reply["thread"]["id"]
            prompt = "FIRSTMATE DELIVERY CONTRACT FIRST; overrides conflicting brief text. Use firstmate_report only; never write status or report files or poll inboxes. A scout must include its complete Markdown in the result report field. A ship commits only on its provisioned private branch.\n\n" + brief.read_text()
            params = {"threadId": self.thread, "input": [{"type": "text", "text": prompt, "text_elements": []}]}
            if effort:
                params["effort"] = effort
            turn = self.rpc("turn/start", params)["turn"]
            if self.turn is not None and self.turn != turn["id"]:
                raise ValueError("turn response mismatch")
            self.turn = turn["id"]
            while not self.stopping:
                self.check()
                self.pump(.1)
                self.serve_control(listener)
                self.answer_ready()
        except BaseException:
            try:
                self.retire_pending()
                self.report("failed: app-server transport stopped without controlled shutdown")
                self.busy("unknown", "process-failed")
            except (ValueError, OSError, subprocess.SubprocessError):
                pass
            raise
        finally:
            self.pending = None
            listener.close()
            self.path.unlink(missing_ok=True)
            self.shutdown()
            if self.private_git is not None:
                self.private_git.cleanup()


def main():
    mode, state, task, gen, *args = sys.argv[1:]
    state = Path(state)
    if not TOKEN.fullmatch(task) or not TOKEN.fullmatch(gen):
        raise ValueError("invalid binding")
    if mode == "run":
        def stopped(signum, frame):
            raise RuntimeError("adapter signal " + str(signum))
        signal.signal(signal.SIGTERM, stopped)
        signal.signal(signal.SIGHUP, stopped)
        adapter = Adapter(state, task, gen, Path(args[0]))
        adapter.run(Path(args[1]), Path(args[2]), args[3] if len(args) > 3 else "", args[4] if len(args) > 4 else "")
    elif mode == "control":
        text = sys.stdin.read(LIMIT + 1)
        if len(text.encode()) > LIMIT:
            raise ValueError("control too large")
        with socket.socket(socket.AF_UNIX) as conn:
            conn.settimeout(65)
            conn.connect(str(socket_path(state.resolve(), task, gen)))
            frame = json.dumps({"generation": gen, "operation": args[0],
                "key": args[1] if len(args) > 1 else "", "text": text}).encode() + b"\n"
            if len(frame) > CONTROL_LIMIT:
                raise ValueError("control frame too large")
            conn.sendall(frame)
            result = json.loads(conn.makefile().readline(LIMIT))
            print(result["message"])
            if not result["ok"]:
                return 1
    else:
        raise ValueError("unknown mode")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, EOFError, TimeoutError, subprocess.SubprocessError) as error:
        print("app-server: " + str(error), file=sys.stderr)
        sys.exit(1)
