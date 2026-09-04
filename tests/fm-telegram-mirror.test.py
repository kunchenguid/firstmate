#!/usr/bin/env python3
"""Focused acceptance tests for bin/fm-telegram.py, the WSL Telegram mirror bot.

Each test drives the real bot process end to end: a fake Telegram Bot API over
loopback HTTP, a fake Pi extension over the bot's own Unix socket, and a fake
local Parakeet command. Nothing here inspects the bot's source.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import platform
import plistlib
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "bin" / "fm-telegram.py"
TOKEN = "123:test-token"
USER_ID = 4242
CHAT_ID = 9797
VOICE_BYTES = b"OggS-fake-voice"
DEADLINE = 10.0


def parse_systemd_unit(unit: str) -> dict[str, dict[str, list[str]]]:
    """Parse the generated unit into its section/key/value model."""
    sections: dict[str, dict[str, list[str]]] = {}
    section: Optional[dict[str, list[str]]] = None
    for line in unit.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = sections.setdefault(line[1:-1], {})
            continue
        if section is None or "=" not in line:
            raise ValueError(f"invalid systemd unit line: {line}")
        key, value = line.split("=", 1)
        section.setdefault(key, []).append(value)
    return sections


def parse_multipart(body: bytes, boundary: str) -> tuple[dict[str, str],
                                                         list[tuple[str, str, bytes]]]:
    """Minimal reader for exactly the shape the bot uploads."""
    fields: dict[str, str] = {}
    files: list[tuple[str, str, bytes]] = []
    marker = f"--{boundary}".encode()
    for section in body.split(marker):
        if not section.strip() or section.startswith(b"--"):
            continue
        head, _, payload = section.partition(b"\r\n\r\n")
        headers = head.decode("utf-8", "replace")
        name = headers.split('name="', 1)[1].split('"', 1)[0]
        payload = payload[:-2] if payload.endswith(b"\r\n") else payload
        if 'filename="' in headers:
            filename = headers.split('filename="', 1)[1].split('"', 1)[0]
            files.append((name, filename, payload))
        else:
            fields[name] = payload.decode("utf-8", "replace")
    return fields, files


class ParseModeRejected(Exception):
    """The fake API's stand-in for Telegram's 400 on unparsable markup."""


class FakeTelegram:
    """Minimal Bot API surface: getUpdates, sendMessage, edits, callbacks, files."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.pending: list[dict[str, Any]] = []
        self.sent: list[dict[str, Any]] = []
        self.edits: list[dict[str, Any]] = []
        self.deleted: list[int] = []
        self.callback_answers: list[dict[str, Any]] = []
        self.calls: list[tuple[str, dict[str, Any]]] = []
        # Uploads the bot made: (method, fields, [(field, filename, bytes)]).
        self.uploads: list[tuple[str, dict[str, str], list[tuple[str, str, bytes]]]] = []
        self.reject_uploads = False
        # Telegram refuses markup it cannot parse; the bot must recover.
        self.reject_parse_mode = False
        self.format_rejection = "can't parse entities: unsupported start tag"
        self.reject_next_edit = False
        self.next_message_id = 1000
        self.next_update_id = 1
        self.files: dict[str, bytes] = {}
        # Offset semantics like the real API: an update stays available until a
        # poll acknowledges past it. A destructive queue silently lost updates
        # to a dying bot's in-flight poll across a restart.
        self.confirmed_through = 0
        harness = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                pass

            def _json(self, payload: Any) -> None:
                body = json.dumps({"ok": True, "result": payload}).encode("utf-8")
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def _error(self, status: int, detail: str) -> None:
                body = json.dumps({
                    "ok": False,
                    "error_code": status,
                    "description": f"Bad Request: {detail}",
                }).encode()
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                name = self.path.rsplit("/", 1)[-1]
                data = harness.files.get(name, VOICE_BYTES)
                try:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length)
                method = self.path.rsplit("/", 1)[-1]
                content_type = self.headers.get("Content-Type") or ""
                if content_type.startswith("multipart/form-data"):
                    boundary = content_type.split("boundary=", 1)[1].strip()
                    fields, files = parse_multipart(raw, boundary)
                    with harness.lock:
                        harness.uploads.append((method, fields, files))
                    if harness.reject_uploads:
                        self._error(400, "IMAGE_PROCESS_FAILED")
                        return
                    self._json({"message_id": 4242})
                    return
                params = json.loads(raw or b"{}")
                try:
                    self._json(harness.dispatch(method, params))
                except ParseModeRejected as exc:
                    self._error(400, str(exc))

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.handle_error = lambda *_args: None  # a killed bot is expected
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def dispatch(self, method: str, params: dict[str, Any]) -> Any:
        if method != "getUpdates":
            with self.lock:
                self.calls.append((method, params))
        if method == "getUpdates":
            offset = params.get("offset")
            with self.lock:
                if isinstance(offset, int):
                    self.confirmed_through = max(self.confirmed_through, offset)
                    self.pending = [u for u in self.pending
                                    if u["update_id"] >= self.confirmed_through]
            deadline = time.time() + 0.2
            while time.time() < deadline:
                with self.lock:
                    ready = [u for u in self.pending
                             if u["update_id"] >= self.confirmed_through]
                    if ready:
                        return ready
                time.sleep(0.01)
            return []
        if method == "sendMessage":
            if self.reject_parse_mode and "parse_mode" in params:
                raise ParseModeRejected(self.format_rejection)
            with self.lock:
                self.next_message_id += 1
                message = dict(params)
                message["message_id"] = self.next_message_id
                self.sent.append(message)
                return message
        if method == "editMessageText":
            with self.lock:
                if self.reject_next_edit:
                    self.reject_next_edit = False
                    raise ParseModeRejected("message can't be edited")
                self.edits.append(dict(params))
                return dict(params)
        if method == "deleteMessage":
            with self.lock:
                self.deleted.append(int(params.get("message_id")))
                return True
        if method == "answerCallbackQuery":
            with self.lock:
                self.callback_answers.append(dict(params))
                return True
        if method == "getFile":
            return {"file_path": f"files/{params.get('file_id')}"}
        return True

    # --- update injection ---

    def push(self, update: dict[str, Any]) -> None:
        with self.lock:
            update["update_id"] = self.next_update_id
            self.next_update_id += 1
            self.pending.append(update)

    def push_text(self, text: str, message_id: int, user: int = USER_ID,
                  chat: int = CHAT_ID, reply_to: Optional[int] = None) -> int:
        message: dict[str, Any] = {
            "message_id": message_id,
            "from": {"id": user},
            "chat": {"id": chat, "type": "private"},
            "text": text,
        }
        if reply_to is not None:
            message["reply_to_message"] = {"message_id": reply_to}
        self.push({"message": message})
        return message_id

    def push_voice(self, message_id: int) -> int:
        self.push({"message": {
            "message_id": message_id,
            "from": {"id": USER_ID},
            "chat": {"id": CHAT_ID, "type": "private"},
            "voice": {"file_id": f"file-{message_id}", "duration": 3},
        }})
        return message_id

    def push_photo(self, message_id: int, renditions: list[dict[str, Any]],
                   caption: Optional[str] = None) -> None:
        message: dict[str, Any] = {
            "message_id": message_id,
            "from": {"id": USER_ID},
            "chat": {"id": CHAT_ID, "type": "private"},
            "photo": renditions,
        }
        if caption is not None:
            message["caption"] = caption
        self.push({"message": message})

    def push_document(self, message_id: int, file_id: str, mime: str,
                      size: int = 64, caption: Optional[str] = None) -> None:
        message: dict[str, Any] = {
            "message_id": message_id,
            "from": {"id": USER_ID},
            "chat": {"id": CHAT_ID, "type": "private"},
            "document": {"file_id": file_id, "mime_type": mime, "file_size": size},
        }
        if caption is not None:
            message["caption"] = caption
        self.push({"message": message})

    def push_callback(self, data: str, card_id: int, callback_id: str = "cb") -> None:
        self.push({"callback_query": {
            "id": callback_id,
            "from": {"id": USER_ID},
            "data": data,
            "message": {"message_id": card_id, "chat": {"id": CHAT_ID, "type": "private"}},
        }})

    # --- assertions ---

    def wait_sent(self, predicate, timeout: float = DEADLINE,
                  after: int = 0) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for message in self.sent[after:]:
                    if predicate(message):
                        return message
            time.sleep(0.02)
        raise AssertionError(f"no sent message matched; saw {self.sent_texts()}")

    def wait_edit(self, predicate, timeout: float = DEADLINE,
                  after: int = 0) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for edit in self.edits[after:]:
                    if predicate(edit):
                        return edit
            time.sleep(0.02)
        raise AssertionError(f"no edit matched; saw {[e.get('text') for e in self.edits]}")

    def wait_deleted(self, message_id: int, timeout: float = DEADLINE) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if message_id in self.deleted:
                    return
            time.sleep(0.02)
        raise AssertionError(f"message {message_id} was never deleted; saw {self.deleted}")

    def edit_count(self) -> int:
        with self.lock:
            return len(self.edits)

    def wait_call(self, method: str, timeout: float = DEADLINE) -> dict[str, Any]:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                for name, params in self.calls:
                    if name == method:
                        return params
            time.sleep(0.02)
        raise AssertionError(f"the bot never called {method}; saw {[c[0] for c in self.calls]}")

    def sent_texts(self) -> list[str]:
        with self.lock:
            return [str(message.get("text")) for message in self.sent]


class FakePi:
    """The Pi extension's side of the bot socket."""

    def __init__(self, path: Path) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(DEADLINE)
        self.sock.connect(str(path))
        self.buffer = b""
        self.states: list[dict[str, Any]] = []
        # The real bridge announces what it can render; these fixtures stand in
        # for a current one unless a test deliberately connects an older shape.
        self.send({"t": "hello", "features": ["image"]})

    def send(self, frame: dict[str, Any]) -> None:
        self.sock.sendall((json.dumps(frame) + "\n").encode("utf-8"))
    def read_frame(self, timeout: float = DEADLINE) -> dict[str, Any]:
        """Next frame of any kind, including the bot's state broadcasts."""
        deadline = time.time() + timeout
        while b"\n" not in self.buffer:
            self.sock.settimeout(max(0.05, deadline - time.time()))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise AssertionError("bot closed the socket")
            self.buffer += chunk
        line, _, self.buffer = self.buffer.partition(b"\n")
        return json.loads(line.decode("utf-8"))

    def read(self, timeout: float = DEADLINE) -> dict[str, Any]:
        """Next frame that is not a state broadcast; states are recorded."""
        deadline = time.time() + timeout
        while True:
            frame = self.read_frame(max(0.05, deadline - time.time()))
            if frame.get("t") == "state":
                self.states.append(frame)
                continue
            return frame

    def expect_nothing(self, seconds: float = 0.5) -> None:
        """No work frame arrives; a state broadcast is not work."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                frame = self.read_frame(max(0.05, deadline - time.time()))
            except (socket.timeout, TimeoutError):
                return
            if frame.get("t") == "state":
                self.states.append(frame)
                continue
            raise AssertionError(f"unexpected frame from bot: {frame}")

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


class MirrorTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.telegram = FakeTelegram()
        self.addCleanup(self.telegram.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir(parents=True)
        self.firstmate_home = Path(self.tmp.name) / "firstmate"
        (self.firstmate_home / "state").mkdir(parents=True)
        (self.firstmate_home / "state" / ".lock").write_text(
            f"{os.getpid()}\n", encoding="utf-8"
        )
        lock_checker = Path(self.tmp.name) / "session-lock-check"
        lock_checker.write_text(
            "#!/bin/sh\n"
            "[ -f \"$1/.lock\" ] && [ ! -L \"$1/.lock\" ] || exit 1\n"
            "[ \"$(cat \"$1/.lock\")\" = \"$FM_TEST_PRIMARY_PID\" ] || exit 1\n"
            "[ \"$2\" = \"$FM_TEST_PRIMARY_PID\" ]\n",
            encoding="utf-8",
        )
        lock_checker.chmod(0o755)
        (self.home / "env").write_text(f"TELEGRAM_BOT_TOKEN={TOKEN}\n", encoding="utf-8")
        transcript_script = Path(self.tmp.name) / "fake-parakeet"
        transcript_script.write_text(
            "#!/bin/sh\n"
            "[ -s \"$1\" ] || { echo 'no audio file was downloaded' >&2; exit 3; }\n"
            "printf '%s\\n' \"$(cat \"$FM_TEST_TRANSCRIPT\")\"\n",
            encoding="utf-8",
        )
        transcript_script.chmod(0o755)
        self.transcript_file = Path(self.tmp.name) / "transcript.txt"
        self.transcript_file.write_text("please rebase the branch", encoding="utf-8")
        (self.home / "config.json").write_text(json.dumps({
            "user_id": USER_ID,
            "chat_id": CHAT_ID,
            "transcribe_command": str(transcript_script),
        }), encoding="utf-8")

        environment = dict(os.environ)
        environment.update({
            "FM_TELEGRAM_DIR": str(self.home),
            "FM_HOME": str(self.firstmate_home),
            "FM_TELEGRAM_API_BASE": self.telegram.base,
            "FM_TELEGRAM_TESTING": "1",
            "FM_TELEGRAM_SESSION_LOCK_CHECK": str(lock_checker),
            "FM_TEST_PRIMARY_PID": str(os.getpid()),
            "FM_TEST_TRANSCRIPT": str(self.transcript_file),
        })
        self.environment = environment
        self.socket_path = self.home / "bot.sock"
        self.start_bot()

    def start_bot(self) -> None:
        self.bot = subprocess.Popen(
            [sys.executable, str(BOT), "run"], env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(self.stop_bot)
        deadline = time.time() + DEADLINE
        while not self.socket_path.exists() and time.time() < deadline:
            if self.bot.poll() is not None:
                raise AssertionError(f"bot exited: {self.bot.communicate()[1]}")
            time.sleep(0.02)
        self.assertTrue(self.socket_path.exists(), "bot never opened its socket")

    def stop_bot(self) -> None:
        if self.bot.poll() is None:
            self.bot.terminate()
            try:
                self.bot.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.bot.kill()
                self.bot.wait(timeout=5)
        for stream in (self.bot.stdout, self.bot.stderr):
            if stream is not None:
                stream.close()

    def connect_pi(self) -> FakePi:
        pi = FakePi(self.socket_path)
        self.addCleanup(pi.close)
        return pi

    def enable_mirror(self, pi: FakePi) -> None:
        pi.send({"t": "command", "id": 1, "command": "on"})
        frame = pi.read()
        self.assertEqual(frame["t"], "command_result")
        self.assertIn("Mirror is on", frame["text"])

    def disable_mirror(self, pi: FakePi) -> None:
        """Every process starts mirroring, so off coverage switches it off first."""
        pi.send({"t": "command", "id": 900, "command": "off"})
        frame = pi.read()
        self.assertEqual(frame["t"], "command_result")
        self.assertIn("Mirror is off", frame["text"])

    def card_id_for(self, text: str) -> int:
        """The transcript card is the edited placeholder, never a second message."""
        edit = self.telegram.wait_edit(
            lambda e: e.get("text") == text
            and (e.get("reply_markup") or {}).get("inline_keyboard")
        )
        return int(edit["message_id"])

    def placeholder_id_for(self, voice_id: int) -> int:
        placeholder = self.telegram.wait_sent(
            lambda m: m.get("text") == "Transcribing…"
            and m.get("reply_parameters", {}).get("message_id") == voice_id
        )
        return int(placeholder["message_id"])

    def voice_messages(self, voice_id: int) -> list[str]:
        """Every bot message threaded to one voice note, in order."""
        with self.telegram.lock:
            return [str(message.get("text")) for message in self.telegram.sent
                    if message.get("reply_parameters", {}).get("message_id") == voice_id]

    # --- scenarios ---

    def test_mirror_off_refuses_ordinary_text(self) -> None:
        pi = self.connect_pi()
        self.disable_mirror(pi)
        self.telegram.push_text("do the thing", 11)
        reply = self.telegram.wait_sent(
            lambda m: m.get("text") == "Telegram mirror is off. Send /telegram_on to enable it."
        )
        self.assertEqual(reply["reply_parameters"]["message_id"], 11)
        pi.expect_nothing()

    def test_commands_work_from_telegram_and_from_pi(self) -> None:
        pi = self.connect_pi()
        self.telegram.push_text("/telegram status", 12)
        first = self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is on"))
        self.assertIn("Firstmate is connected", first["text"])
        self.telegram.push_text("/telegram off", 13)
        self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is off"))
        pi.send({"t": "command", "id": 7, "command": "status"})
        frame = pi.read()
        self.assertEqual(frame, {"t": "command_result", "id": 7,
                                 "text": "Mirror is off. Firstmate is connected. Confirmations are on."})
        pi.send({"t": "command", "id": 8, "command": "on"})
        self.assertIn("Mirror is on", pi.read()["text"])

    def processes_matching(self, needle: str) -> list[int]:
        result = subprocess.run(
            ["ps", "-axo", "pid=,command="],
            capture_output=True, text=True, check=False,
        )
        found = []
        for line in result.stdout.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[0].isdigit() and needle in fields[1]:
                found.append(int(fields[0]))
        return found

    def reap_by_cmdline(self, needle: str) -> None:
        """Kill fixture leftovers so a regression fails loudly instead of hanging."""
        for pid in self.processes_matching(needle):
            try:
                os.kill(pid, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass

    def test_stop_is_bounded_while_a_transcription_is_running(self) -> None:
        # The field failure: a local speech model was still running when the
        # service was restarted, the stop never completed, and systemd killed
        # the bot after its stop timeout.
        slow = Path(self.tmp.name) / "slow-parakeet"
        slow.write_text(
            "#!/bin/sh\n"
            # A wrapper driving a heavier child, exactly like the real command:
            # signalling only this shell leaves that child holding the pipe.
            'python3 -c "import sys, time; sys.argv[0]; time.sleep(300)" ' + str(slow) + " &\n"
            "wait\n",
            encoding="utf-8",
        )
        slow.chmod(0o755)
        self.addCleanup(self.reap_by_cmdline, str(slow))
        config = json.loads((self.home / "config.json").read_text())
        config["transcribe_command"] = str(slow)
        (self.home / "config.json").write_text(json.dumps(config), encoding="utf-8")
        self.stop_bot()
        self.start_bot()

        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(401)
        self.telegram.wait_sent(lambda m: m.get("text") == "Transcribing…")
        deadline = time.time() + DEADLINE
        while time.time() < deadline and not (self.home / "audio" / "401.ogg").exists():
            time.sleep(0.05)
        time.sleep(1.0)

        started = time.time()
        self.bot.terminate()
        try:
            self.bot.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.bot.kill()
            self.bot.wait(timeout=10)
            self.reap_by_cmdline(str(slow))
            self.fail("the bot did not stop within 20s while a transcription was running")
        elapsed = time.time() - started
        self.assertLess(elapsed, 15, f"the stop took {elapsed:.1f}s while transcribing")
        # A stop that merely walks away would leave the transcription running:
        # the real command is a wrapper whose heavy child outlives it.
        time.sleep(1.0)
        survivors = self.processes_matching(str(slow))
        self.reap_by_cmdline(str(slow))
        self.assertEqual(
            survivors, [], f"the stop orphaned {len(survivors)} transcription process(es)"
        )
        self.assertFalse(self.socket_path.exists(), "the stopped bot left its socket behind")
        self.assertFalse(
            (self.home / "audio" / "401.ogg").exists(),
            "the stopped bot left its temporary voice audio behind",
        )

    def test_stop_is_bounded_while_a_long_poll_is_open(self) -> None:
        # The ordinary state: parked in a long poll with nothing to do. That
        # wait must not delay the stop either.
        pi = self.connect_pi()
        self.enable_mirror(pi)
        time.sleep(1.0)
        started = time.time()
        self.bot.terminate()
        try:
            self.bot.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.bot.kill()
            self.fail("the bot did not stop within 20s while parked in a long poll")
        elapsed = time.time() - started
        self.assertLess(elapsed, 5, f"the stop took {elapsed:.1f}s while polling")

    def test_only_one_voice_note_transcribes_at_a_time(self) -> None:
        gate = Path(self.tmp.name) / "transcription-gate"
        starts = Path(self.tmp.name) / "transcription-starts"
        slow = Path(self.tmp.name) / "gated-parakeet"
        slow.write_text(
            "#!/bin/sh\n"
            f"printf 'start\\n' >> {shlex.quote(str(starts))}\n"
            f"while [ ! -e {shlex.quote(str(gate))} ]; do sleep 0.05; done\n"
            "printf 'finished transcript\\n'\n",
            encoding="utf-8",
        )
        slow.chmod(0o755)
        config = json.loads((self.home / "config.json").read_text())
        config["transcribe_command"] = str(slow)
        (self.home / "config.json").write_text(json.dumps(config), encoding="utf-8")
        self.stop_bot()
        self.start_bot()

        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(450)
        self.telegram.wait_sent(
            lambda m: m.get("text") == "Transcribing…"
            and m.get("reply_parameters", {}).get("message_id") == 450
        )
        deadline = time.time() + DEADLINE
        while time.time() < deadline and not starts.exists():
            time.sleep(0.05)
        self.assertTrue(starts.exists(), "the first transcription never started")
        self.telegram.push_voice(451)
        refused = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 451
        )
        self.assertEqual(
            refused["text"],
            "Another voice note is already being transcribed. Try again shortly.",
        )
        self.assertEqual(starts.read_text().splitlines(), ["start"])
        gate.touch()
        self.telegram.wait_edit(
            lambda e: e.get("text") == "finished transcript"
            and (e.get("reply_markup") or {}).get("inline_keyboard")
        )

    def test_abandoned_transcripts_do_not_accumulate(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        # Cards nobody taps must not retain their text and audio forever.
        oldest_placeholder = 0
        for index in range(40):
            message_id = 500 + index
            self.telegram.push_voice(message_id)
            placeholder = self.placeholder_id_for(message_id)
            if index == 0:
                oldest_placeholder = placeholder
            self.telegram.wait_edit(
                lambda e, expected=placeholder:
                int(e.get("message_id", 0)) == expected
                and (e.get("reply_markup") or {}).get("inline_keyboard")
            )
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            if len(list((self.home / "audio").glob("*.ogg"))) <= 32:
                break
            time.sleep(0.1)
        retained = sorted(path.stem for path in (self.home / "audio").glob("*.ogg"))
        self.assertLessEqual(len(retained), 32, f"retained {len(retained)} voice files")
        self.assertIn("539", retained, "the newest transcript was dropped instead of the oldest")
        self.assertNotIn("500", retained, "the oldest transcript was never retired")
        retired = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == oldest_placeholder
            and e.get("text") == "This transcript is no longer active."
        )
        self.assertEqual(retired["reply_markup"], {"inline_keyboard": []})

    def test_replies_are_formatted_as_telegram_html(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.send({"t": "reply", "text": (
            "Captain, the fix is in.\n\n"
            "**What broke:** the bridge kept one `finalReply`.\n\n"
            "```sh\ngrep -c 'reply' frames.log\n```\n\n"
            "Compare a < b && c > d, and see [the PR](https://example.com/pull/12)."
        )})
        sent = self.telegram.wait_sent(lambda m: "What broke" in str(m.get("text")))
        self.assertEqual(sent["parse_mode"], "HTML")
        body = sent["text"]
        self.assertIn("<b>What broke:</b>", body)
        self.assertIn("<code>finalReply</code>", body)
        self.assertIn('<pre><code class="language-sh">', body)
        self.assertIn('<a href="https://example.com/pull/12">the PR</a>', body)
        # Only <, > and & need escaping, and they must never reach Telegram raw.
        self.assertIn("a &lt; b &amp;&amp; c &gt; d", body)
        self.assertNotIn("a < b", body)

    def test_transport_statuses_stay_plain(self) -> None:
        pi = self.connect_pi()
        self.disable_mirror(pi)
        self.telegram.push_text("anything", 601)
        refusal = self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Telegram mirror is off")
        )
        self.assertNotIn("parse_mode", refusal)
        self.enable_mirror(pi)
        self.telegram.push_text("do the thing", 602)
        frame = pi.read()
        pi.send({"t": "accepted", "id": frame["id"]})
        receipt = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertNotIn("parse_mode", receipt)
        pi.send({"t": "terminal", "text": "echoed **verbatim**"})
        echo = self.telegram.wait_sent(lambda m: "echoed" in str(m.get("text")))
        self.assertEqual(echo["text"], "You · Terminal\nechoed **verbatim**")
        self.assertNotIn("parse_mode", echo)

    def test_a_long_reply_is_split_before_conversion(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        code = "\n".join(f"line_{index} = {index}" for index in range(700))
        pi.send({"t": "reply", "text": f"Here it is:\n\n```python\n{code}\n```"})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            formatted = [m for m in self.telegram.sent if m.get("parse_mode") == "HTML"]
            if formatted and sum(m["text"].count("line_") for m in formatted) >= 700:
                break
            time.sleep(0.05)
        formatted = [m for m in self.telegram.sent if m.get("parse_mode") == "HTML"]
        self.assertGreater(len(formatted), 1, "the long reply was not split")
        for message in formatted:
            self.assertLessEqual(len(message["text"]), 4096)
            # A chunk cut out of converted HTML would leave a half-open tag and
            # Telegram would reject the whole message.
            self.assertEqual(message["text"].count("<pre"), message["text"].count("</pre>"))
            self.assertEqual(message["text"].count("<code"), message["text"].count("</code>"))
        self.assertEqual(
            sum(message["text"].count("line_") for message in formatted), 700,
            "splitting lost or duplicated code lines",
        )

    def test_long_indivisible_markdown_preserves_every_character(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        code = "z" * 8000
        pi.send({"t": "reply", "text": f"```text\n{code}\n```"})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            formatted = [m for m in self.telegram.sent if m.get("parse_mode") == "HTML"]
            if sum(m["text"].count("z") for m in formatted) >= len(code):
                break
            time.sleep(0.05)
        formatted = [m for m in self.telegram.sent if m.get("parse_mode") == "HTML"]
        self.assertGreater(len(formatted), 1)
        self.assertEqual(sum(m["text"].count("z") for m in formatted), len(code))
        for message in formatted:
            self.assertEqual(message["text"].count("<pre"), message["text"].count("</pre>"))

        inline = "**" + "q" * 8000 + "**"
        before = len(self.telegram.sent)
        pi.send({"t": "reply", "text": inline})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            delivered = self.telegram.sent[before:]
            if sum(len(str(m.get("text", ""))) for m in delivered) >= len(inline):
                break
            time.sleep(0.05)
        delivered = self.telegram.sent[before:]
        self.assertEqual("".join(str(m["text"]) for m in delivered), inline)
        self.assertTrue(all("parse_mode" not in message for message in delivered))

    def test_oversized_fence_opener_falls_back_without_duplication(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        source = f"```{'x' * 4000}\npayload\n```"
        before = len(self.telegram.sent)
        pi.send({"t": "reply", "text": source})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            delivered = self.telegram.sent[before:]
            if "".join(str(message.get("text", "")) for message in delivered) == source:
                break
            time.sleep(0.05)
        delivered = self.telegram.sent[before:]
        self.assertEqual("".join(str(message.get("text", "")) for message in delivered), source)
        self.assertTrue(all("parse_mode" not in message for message in delivered))

    def test_many_inline_constructs_split_at_formatting_boundaries(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        source = " ".join(f"**item{index}**" for index in range(500))
        before = len(self.telegram.sent)
        pi.send({"t": "reply", "text": source})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            delivered = self.telegram.sent[before:]
            if sum(str(message.get("text", "")).count("<b>item") for message in delivered) == 500:
                break
            time.sleep(0.05)
        delivered = self.telegram.sent[before:]
        self.assertGreater(len(delivered), 1)
        self.assertTrue(all(message.get("parse_mode") == "HTML" for message in delivered))
        self.assertEqual(sum(message["text"].count("<b>item") for message in delivered), 500)

    def test_rejected_formatting_falls_back_to_plain_text_once(self) -> None:
        self.telegram.reject_parse_mode = True
        self.telegram.format_rejection = "wrong HTTP URL specified"
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.send({"t": "reply", "text": "**bold** and `code`"})
        plain = self.telegram.wait_sent(
            lambda m: m.get("text") == "**bold** and `code`" and "parse_mode" not in m
        )
        self.assertTrue(plain)
        time.sleep(0.6)
        delivered = [m for m in self.telegram.sent if "bold" in str(m.get("text"))
                     and "parse_mode" not in m]
        self.assertEqual(len(delivered), 1, "the fallback duplicated the reply")

    def test_rejected_split_fence_falls_back_to_owned_source(self) -> None:
        self.telegram.reject_parse_mode = True
        pi = self.connect_pi()
        self.enable_mirror(pi)
        code = "".join(f"line {index}: {'x' * 40}\n" for index in range(300))
        source = f"Before\n\n```python\n{code}```\n\nAfter"
        before = len(self.telegram.sent)
        pi.send({"t": "reply", "text": source})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            delivered = self.telegram.sent[before:]
            if "".join(str(message.get("text", "")) for message in delivered) == source:
                break
            time.sleep(0.05)
        delivered = self.telegram.sent[before:]
        self.assertGreater(len(delivered), 1, "the fenced reply was not split")
        self.assertEqual(
            "".join(str(message.get("text", "")) for message in delivered), source,
        )
        self.assertTrue(all("parse_mode" not in message for message in delivered))

    def test_without_the_markdown_parser_replies_are_sent_plain(self) -> None:
        # The parser is an installed package; a home without it must still
        # mirror, unformatted, rather than dropping replies.
        shim = Path(self.tmp.name) / "noparser"
        shim.mkdir(exist_ok=True)
        (shim / "mistune.py").write_text(
            "raise ImportError('no mistune in this fixture')\n", encoding="utf-8"
        )
        self.stop_bot()
        self.environment["PYTHONPATH"] = str(shim)
        self.start_bot()
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.send({"t": "reply", "text": "**bold** stays literal"})
        sent = self.telegram.wait_sent(lambda m: "bold" in str(m.get("text")))
        self.assertEqual(sent["text"], "**bold** stays literal")
        self.assertNotIn("parse_mode", sent)

    def test_an_unverified_first_client_is_refused(self) -> None:
        sleeper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        self.addCleanup(lambda: sleeper.poll() is None and sleeper.kill())
        lock = self.firstmate_home / "state" / ".lock"
        lock.write_text(f"{sleeper.pid}\n", encoding="utf-8")

        intruder = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        intruder.settimeout(2)
        intruder.connect(str(self.socket_path))
        self.addCleanup(intruder.close)
        intruder.sendall(b'{"t":"command","id":91,"command":"on"}\n')
        try:
            self.assertEqual(intruder.recv(65536), b"")
        except (ConnectionResetError, OSError):
            pass

        lock.write_text(f"{os.getpid()}\n", encoding="utf-8")
        sleeper.kill()
        sleeper.wait(timeout=2)
        primary = self.connect_pi()
        primary.send({"t": "command", "id": 92, "command": "status"})
        self.assertIn("Firstmate is connected", primary.read()["text"])

    def test_a_second_session_cannot_take_over_or_leak_into_the_chat(self) -> None:
        primary = self.connect_pi()
        self.enable_mirror(primary)

        # A crewmate or scout that reaches this socket must be refused outright,
        # never promoted over the session the captain is talking to.
        worker = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        worker.settimeout(DEADLINE)
        worker.connect(str(self.socket_path))
        self.addCleanup(worker.close)
        worker_leak = (
            "# Task\nImplement the captain-approved scout brief.\n\n"
            "# Definition of done\nAppend done: PR {url} and stop."
        )
        for frame in (
            {"t": "hello"},
            {"t": "terminal", "text": worker_leak},
            {"t": "reply", "text": "Confirmed, captain. Starting the investigation."},
            {"t": "reply", "text": "Worker-only internal reply."},
            {"t": "command", "id": 99, "command": "off"},
        ):
            try:
                worker.sendall((json.dumps(frame) + "\n").encode("utf-8"))
            except (BrokenPipeError, ConnectionResetError, OSError):
                break
        time.sleep(1.5)

        # The refused session is closed, and nothing it said reached Telegram.
        worker.settimeout(2)
        try:
            self.assertEqual(worker.recv(65536), b"", "the bot kept the second session open")
        except (socket.timeout, TimeoutError, ConnectionResetError, OSError):
            pass
        chat = " ".join(self.telegram.sent_texts())
        for leaked in ("Definition of done", "scout brief", "Confirmed, captain",
                       "Worker-only internal reply.", "Implement the captain-approved"):
            self.assertNotIn(leaked, chat, f"a worker session leaked {leaked!r} into the chat")

        # The captain's own session still owns the mirror, unchanged.
        primary.send({"t": "command", "id": 4, "command": "status"})
        self.assertIn("Mirror is on", primary.read()["text"])
        primary.send({"t": "reply", "text": "Everything is green."})
        mirrored = self.telegram.wait_sent(lambda m: "Everything is green." in str(m.get("text")))
        self.assertTrue(mirrored)

        # And once the captain's session ends, a fresh one may take over.
        primary.close()
        time.sleep(0.5)
        replacement = self.connect_pi()
        replacement.send({"t": "command", "id": 5, "command": "status"})
        self.assertIn("Firstmate is connected", replacement.read()["text"])

    def test_mirror_off_names_a_real_telegram_command(self) -> None:
        pi = self.connect_pi()
        self.disable_mirror(pi)
        published = self.telegram.wait_call("setMyCommands")
        names = [entry["command"] for entry in published["commands"]]
        self.telegram.push_text("do the thing", 801)
        refusal = self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Telegram mirror is off")
        )
        # The guidance must name a command the captain can actually tap.
        self.assertEqual(
            refusal["text"], "Telegram mirror is off. Send /telegram_on to enable it."
        )
        self.assertIn("telegram_on", names)
        pi.expect_nothing()
        # And that command works exactly as the message promises.
        self.telegram.push_text("/telegram_on", 802)
        self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is on"))
        self.telegram.push_text("now it flows", 803)
        self.assertEqual(pi.read()["text"], "now it flows")

    def test_lists_and_prose_render_as_telegram_html(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.send({"t": "reply", "text": (
            "Captain, three things:\n\n"
            "1. The bridge mirrors every reply, using `finalVisibleReply`.\n"
            "2. The stop is bounded.\n"
            "3. Screenshots arrive as pasted images.\n\n"
            "Then the loose ends:\n\n"
            "- first with `code`\n"
            "- second\n\n"
            "Closing paragraph."
        )})
        body = self.telegram.wait_sent(lambda m: "three things" in str(m.get("text")))["text"]
        self.assertIn("1. The bridge mirrors every reply, using <code>finalVisibleReply</code>.", body)
        self.assertIn("2. The stop is bounded.", body)
        self.assertIn("3. Screenshots arrive as pasted images.", body)
        self.assertIn("- first with <code>code</code>", body)
        self.assertIn("- second", body)
        # Compact: numbered items sit on their own lines with no blank line
        # between them, and never collapse into one another.
        self.assertNotIn("1. The bridge mirrors every reply, using <code>finalVisibleReply</code>.\n\n2.", body)
        self.assertIn("three things:\n\n1.", body)
        self.assertIn("Closing paragraph.", body)
        self.assertNotIn("<ol>", body)
        self.assertNotIn("<li>", body)

    def test_a_nested_list_keeps_its_items_apart(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.send({"t": "reply", "text": "1. outer one\n   - inner a\n   - inner b\n2. outer two"})
        body = self.telegram.wait_sent(lambda m: "outer one" in str(m.get("text")))["text"]
        self.assertIn("1. outer one", body)
        self.assertIn("2. outer two", body)
        self.assertIn("- inner a", body)
        self.assertNotIn("outer one- inner a", body)

    def test_a_long_reply_ending_in_a_list_chunks_cleanly(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        filler = "\n\n".join(f"Paragraph {index} of the audit." for index in range(180))
        items = "\n".join(f"{index}. finding {index}" for index in range(1, 41))
        pi.send({"t": "reply", "text": f"{filler}\n\n{items}"})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            formatted = [m for m in self.telegram.sent if m.get("parse_mode") == "HTML"]
            if sum(m["text"].count("finding ") for m in formatted) >= 40:
                break
            time.sleep(0.05)
        formatted = [m for m in self.telegram.sent if m.get("parse_mode") == "HTML"]
        self.assertGreater(len(formatted), 1, "the long reply was not split")
        for message in formatted:
            self.assertLessEqual(len(message["text"]), 4096)
        joined = "\n".join(m["text"] for m in formatted)
        for index in (1, 20, 40):
            self.assertIn(f"{index}. finding {index}", joined)

    PNG = b"\x89PNG\r\n\x1a\n" + b"pixels" * 4
    JPEG = b"\xff\xd8\xff" + b"jpegbytes" * 4

    def test_a_screenshot_reaches_pi_as_an_image_with_its_caption(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.files["photo-big"] = self.PNG
        self.telegram.files["photo-small"] = b"tiny"
        self.telegram.push_photo(901, [
            {"file_id": "photo-small", "width": 90, "height": 60, "file_size": 4},
            {"file_id": "photo-big", "width": 1280, "height": 800, "file_size": len(self.PNG)},
        ], caption="  look at this failure  ")
        frame = pi.read()
        self.assertEqual(frame["t"], "deliver")
        # The captain sent one screenshot: the sharpest rendition is the one.
        self.assertEqual(base64.b64decode(frame["image"]["data"]), self.PNG)
        self.assertEqual(frame["image"]["mime"], "image/png")
        self.assertEqual(frame["text"], "  look at this failure  ")
        pi.send({"t": "accepted", "id": frame["id"]})
        receipt = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(receipt["reply_parameters"]["message_id"], 901)
        # The image is not echoed back into the chat it came from.
        self.assertNotIn("You · Terminal", " ".join(self.telegram.sent_texts()))
        # Nothing is retained once it has been accepted.
        self.assertEqual(list((self.home / "audio").glob("*")), [])

    def test_an_image_document_is_accepted_and_other_documents_are_refused(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.files["doc-jpeg"] = self.JPEG
        self.telegram.push_document(911, "doc-jpeg", "image/jpeg", size=len(self.JPEG))
        frame = pi.read()
        self.assertEqual(base64.b64decode(frame["image"]["data"]), self.JPEG)
        self.assertEqual(frame["image"]["mime"], "image/jpeg")
        self.assertEqual(frame["text"], "")
        pi.send({"t": "accepted", "id": frame["id"]})

        self.telegram.push_document(912, "doc-zip", "application/zip", size=10)
        refusal = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 912
        )
        self.assertIn("not supported", refusal["text"])
        # A refused file is never fetched.
        self.assertNotIn("getFile", [name for name, params in self.telegram.calls
                                     if params.get("file_id") == "doc-zip"])
        pi.expect_nothing()

    def test_an_image_document_with_mismatched_bytes_is_refused(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.files["lying-png"] = self.JPEG
        self.telegram.push_document(913, "lying-png", "image/png", size=len(self.JPEG))
        refusal = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 913
        )
        self.assertIn("not supported", refusal["text"])
        pi.expect_nothing()

    def test_an_oversized_image_is_refused_without_downloading(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_photo(921, [
            {"file_id": "huge", "width": 8000, "height": 6000,
             "file_size": 40 * 1024 * 1024},
        ], caption="way too big")
        refusal = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 921
        )
        self.assertIn("too large", refusal["text"])
        self.assertEqual([params for name, params in self.telegram.calls
                          if name == "getFile" and params.get("file_id") == "huge"], [])
        pi.expect_nothing()

    def test_images_keep_their_place_in_the_queue(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.files["shot"] = self.PNG
        self.telegram.push_text("before the screenshot", 931)
        self.telegram.push_photo(932, [
            {"file_id": "shot", "width": 800, "height": 600, "file_size": len(self.PNG)},
        ], caption="the screenshot")
        self.telegram.push_text("after the screenshot", 933)
        seen = []
        for _ in range(3):
            frame = pi.read()
            seen.append((frame["text"], "image" in frame))
            pi.send({"t": "accepted", "id": frame["id"]})
        self.assertEqual(seen, [
            ("before the screenshot", False),
            ("the screenshot", True),
            ("after the screenshot", False),
        ])

    def test_a_screenshot_while_firstmate_is_away_waits_in_memory(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.close()
        time.sleep(0.3)
        self.telegram.files["queued-shot"] = self.PNG
        self.telegram.push_photo(941, [
            {"file_id": "queued-shot", "width": 800, "height": 600, "file_size": len(self.PNG)},
        ])
        self.telegram.wait_sent(
            lambda m: m.get("text") == "Firstmate is not running. Your message is queued until it starts."
        )
        # Held in memory only: never written beside the voice notes.
        self.assertEqual(list((self.home / "audio").glob("*")), [])
        later = self.connect_pi()
        frame = later.read()
        self.assertEqual(base64.b64decode(frame["image"]["data"]), self.PNG)

    def test_queued_image_limit_counts_decoded_bytes_and_incoming_image(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.close()
        time.sleep(0.3)
        ten_megabytes = self.PNG[:8] + b"a" * (10 * 1024 * 1024 - 8)
        for index in range(3):
            file_id = f"queued-large-{index}"
            self.telegram.files[file_id] = ten_megabytes
            message_id = 960 + index
            self.telegram.push_photo(message_id, [{
                "file_id": file_id,
                "width": 1000,
                "height": 1000,
                "file_size": len(ten_megabytes),
            }])
            self.telegram.wait_sent(
                lambda message, expected=message_id:
                message.get("reply_parameters", {}).get("message_id") == expected
                and "queued" in str(message.get("text", ""))
            )
        three_megabytes = self.PNG[:8] + b"b" * (3 * 1024 * 1024 - 8)
        self.telegram.files["over-raw-cap"] = three_megabytes
        self.telegram.push_photo(963, [{
            "file_id": "over-raw-cap",
            "width": 1000,
            "height": 1000,
            "file_size": len(three_megabytes),
        }])
        refusal = self.telegram.wait_sent(
            lambda message: message.get("reply_parameters", {}).get("message_id") == 963
        )
        self.assertIn("too large", refusal["text"])
        later = self.connect_pi()
        delivered = [later.read() for _ in range(3)]
        self.assertEqual([len(base64.b64decode(frame["image"]["data"])) for frame in delivered],
                         [len(ten_megabytes)] * 3)
        later.expect_nothing()

    def test_an_image_is_refused_when_the_session_cannot_render_one(self) -> None:
        # The live failure: a bot newer than the connected bridge delivered an
        # image the bridge ignored, so a captioned screenshot reached Firstmate
        # as text only and a captionless one as an empty message, with nothing
        # anywhere saying an image had been dropped.
        legacy = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        legacy.settimeout(DEADLINE)
        legacy.connect(str(self.socket_path))
        self.addCleanup(legacy.close)
        legacy.sendall(b'{"t":"hello"}\n')          # no features: the old bridge
        legacy.sendall(json.dumps({"t": "command", "id": 1, "command": "on"}).encode() + b"\n")
        deadline = time.time() + DEADLINE
        buffer = b""
        while time.time() < deadline and b"Mirror is on" not in buffer:
            buffer += legacy.recv(65536)

        self.telegram.files["legacy-shot"] = self.PNG
        self.telegram.push_photo(951, [
            {"file_id": "legacy-shot", "width": 800, "height": 600,
             "file_size": len(self.PNG)},
        ], caption="Okay what is this image")
        refusal = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 951
        )
        self.assertIn("cannot receive images yet", refusal["text"])

        self.telegram.push_photo(952, [
            {"file_id": "legacy-shot", "width": 800, "height": 600,
             "file_size": len(self.PNG)},
        ])
        self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 952
        )

        # Neither screenshot may be handed over as a text-only or empty turn.
        legacy.settimeout(1.5)
        delivered = b""
        try:
            while True:
                chunk = legacy.recv(65536)
                if not chunk:
                    break
                delivered += chunk
        except (socket.timeout, TimeoutError, OSError):
            pass
        for line in delivered.decode("utf-8", "replace").splitlines():
            if not line.strip():
                continue
            frame = json.loads(line)
            self.assertNotEqual(
                frame.get("t"), "deliver",
                f"an image was handed to a session that cannot render one: {frame}",
            )

    def test_a_terminal_image_is_mirrored_as_real_media(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        # Text plus one image: one submission, one album entry, the terminal
        # text as its caption.
        pi.send({"t": "terminal", "text": "what do you make of this",
                 "images": [{"data": base64.b64encode(self.PNG).decode(), "mime": "image/png"}]})
        deadline = time.time() + DEADLINE
        while time.time() < deadline and not self.telegram.uploads:
            time.sleep(0.05)
        self.assertTrue(self.telegram.uploads, "the terminal image was never uploaded")
        method, fields, files = self.telegram.uploads[0]
        self.assertEqual(method, "sendPhoto")
        self.assertEqual(fields["caption"], "You · Terminal\nwhat do you make of this")
        self.assertEqual(len(files), 1)
        # Real bytes, not a path and not base64 text.
        self.assertEqual(files[0][2], self.PNG)
        self.assertNotIn("/tmp/", json.dumps(fields))

    def test_unicode_terminal_caption_uses_telegram_utf16_units(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        text = "😀" * 510
        pi.send({"t": "terminal", "text": text,
                 "images": [{"data": base64.b64encode(self.PNG).decode(), "mime": "image/png"}]})
        mirrored = self.telegram.wait_sent(lambda m: m.get("text") == f"You · Terminal\n{text}")
        self.assertTrue(mirrored)
        deadline = time.time() + DEADLINE
        while time.time() < deadline and not self.telegram.uploads:
            time.sleep(0.05)
        self.assertTrue(self.telegram.uploads)
        _method, fields, _files = self.telegram.uploads[0]
        self.assertNotIn("caption", fields)

    def test_a_terminal_image_without_text_still_reaches_telegram(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.send({"t": "terminal", "text": "",
                 "images": [{"data": base64.b64encode(self.PNG).decode(), "mime": "image/png"}]})
        deadline = time.time() + DEADLINE
        while time.time() < deadline and not self.telegram.uploads:
            time.sleep(0.05)
        self.assertTrue(self.telegram.uploads, "an image-only submission was dropped")
        _method, fields, files = self.telegram.uploads[0]
        self.assertEqual(fields["caption"], "You · Terminal")
        self.assertEqual(files[0][2], self.PNG)

    def test_several_terminal_images_keep_their_order_in_one_album(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        blobs = [self.PNG + bytes([index]) for index in range(3)]
        pi.send({"t": "terminal", "text": "three shots", "images": [
            {"data": base64.b64encode(blob).decode(), "mime": "image/png"} for blob in blobs
        ]})
        deadline = time.time() + DEADLINE
        while time.time() < deadline and not self.telegram.uploads:
            time.sleep(0.05)
        self.assertTrue(self.telegram.uploads, "the album was never uploaded")
        method, fields, files = self.telegram.uploads[0]
        self.assertEqual(method, "sendMediaGroup")
        media = json.loads(fields["media"])
        self.assertEqual([entry["media"] for entry in media],
                         [f"attach://{name}" for name, _filename, _blob in files])
        self.assertEqual([blob for _name, _filename, blob in files], blobs)
        self.assertEqual(media[0]["caption"], "You · Terminal\nthree shots")
        self.assertNotIn("caption", media[1])

    def test_full_aggregate_terminal_images_fit_the_wire_frame(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        blobs = [self.PNG[:8] + bytes([index]) * (9 * 1024 * 1024 - 8) for index in range(3)]
        pi.send({"t": "terminal", "text": "large album", "images": [
            {"data": base64.b64encode(blob).decode(), "mime": "image/png"} for blob in blobs
        ]})
        deadline = time.time() + 20
        while time.time() < deadline and not self.telegram.uploads:
            time.sleep(0.05)
        self.assertTrue(self.telegram.uploads, "a valid aggregate image frame was dropped")
        method, _fields, files = self.telegram.uploads[0]
        self.assertEqual(method, "sendMediaGroup")
        self.assertEqual([len(blob) for _name, _filename, blob in files],
                         [len(blob) for blob in blobs])

    def test_terminal_images_respect_the_size_and_type_bounds(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.send({"t": "terminal", "text": "mixed bag", "images": [
            {"data": base64.b64encode(self.PNG).decode(), "mime": "image/png"},
            {"data": base64.b64encode(b"not an image at all").decode(), "mime": "image/png"},
            {"data": base64.b64encode(self.PNG).decode(), "mime": "application/zip"},
            {"data": base64.b64encode(b"\\x89PNG\\r\\n\\x1a\\n" + b"x" * (11 * 1024 * 1024)).decode(),
             "mime": "image/png"},
        ]})
        deadline = time.time() + DEADLINE
        while time.time() < deadline and not self.telegram.uploads:
            time.sleep(0.05)
        self.assertTrue(self.telegram.uploads)
        _method, _fields, files = self.telegram.uploads[0]
        self.assertEqual([blob for _n, _f, blob in files], [self.PNG])
        refusal = self.telegram.wait_sent(lambda m: "were not mirrored" in str(m.get("text")))
        self.assertIn("3 image(s)", refusal["text"])

    def test_a_rejected_terminal_image_reports_without_duplicating(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.reject_uploads = True
        pi.send({"t": "terminal", "text": "this one fails",
                 "images": [{"data": base64.b64encode(self.PNG).decode(), "mime": "image/png"}]})
        failure = self.telegram.wait_sent(lambda m: "could not be" in str(m.get("text")))
        self.assertIn("1 image(s) could not be sent", failure["text"])
        time.sleep(0.8)
        # One attempt only: a failed album is never re-sent.
        self.assertEqual(len(self.telegram.uploads), 1)

    def test_terminal_images_are_not_mirrored_while_the_mirror_is_off(self) -> None:
        pi = self.connect_pi()
        self.disable_mirror(pi)
        pi.send({"t": "terminal", "text": "while off",
                 "images": [{"data": base64.b64encode(self.PNG).decode(), "mime": "image/png"}]})
        time.sleep(0.8)
        self.assertEqual(self.telegram.uploads, [])
        self.assertEqual(self.telegram.sent_texts(), [])

    def test_menu_aliases_are_published_and_switch_the_mirror(self) -> None:
        pi = self.connect_pi()
        published = self.telegram.wait_call("setMyCommands")
        names = [entry["command"] for entry in published["commands"]]
        for expected in ("telegram_on", "telegram_off", "telegram_status"):
            self.assertIn(expected, names)
        self.assertTrue(all(entry.get("description") for entry in published["commands"]))
        self.assertEqual(published["scope"], {"type": "chat", "chat_id": CHAT_ID})

        self.telegram.push_text("/telegram_on", 71)
        started = self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is on"))
        self.assertEqual(started["reply_parameters"]["message_id"], 71)

        # An alias is transport, so it is never forwarded to Firstmate.
        pi.expect_nothing()

        self.telegram.push_text("/telegram_status@FirstmateMirrorBot", 72)
        status = self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Mirror is on")
            and m.get("reply_parameters", {}).get("message_id") == 72
        )
        self.assertIn("Firstmate is connected", status["text"])

        self.telegram.push_text("/telegram_off", 73)
        self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Mirror is off")
            and m.get("reply_parameters", {}).get("message_id") == 73
        )

        # Both spellings stay live: the spaced form still switches it back on.
        self.telegram.push_text("/telegram on", 74)
        self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Mirror is on")
            and m.get("reply_parameters", {}).get("message_id") == 74
        )
        self.telegram.push_text("an ordinary message", 75)
        self.assertEqual(pi.read()["text"], "an ordinary message")

    def test_confirmation_commands_switch_the_setting_for_both_surfaces(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        published = self.telegram.wait_call("setMyCommands")
        self.assertEqual(
            [entry["command"] for entry in published["commands"]],
            ["telegram_on", "telegram_off", "telegram_status",
             "telegram_confirmations_on", "telegram_confirmations_off"],
        )

        self.telegram.push_text("/telegram_status", 201)
        card = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 201
        )
        self.assertIn("Confirmations are on.", card["text"])
        # The setting moved to its own commands; no button rides along any more.
        self.assertNotIn("reply_markup", card)

        self.telegram.push_text("before the switch", 202)
        frame = pi.read()
        pi.send({"t": "accepted", "id": frame["id"]})
        receipt = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(receipt["reply_parameters"]["message_id"], 202)

        self.telegram.push_text("/telegram_confirmations_off", 203)
        off = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 203
        )
        self.assertIn("Confirmations are off.", off["text"])
        self.assertNotIn("reply_markup", off)
        self.assertIs(json.loads((self.home / "config.json").read_text())["confirmations"], False)
        # Pi is told, so its settings and footer show the same value.
        deadline = time.time() + DEADLINE
        published_off = False
        while time.time() < deadline and not published_off:
            try:
                frame = pi.read_frame(timeout=1)
            except (socket.timeout, TimeoutError):
                continue
            published_off = frame.get("t") == "state" and frame.get("confirmations") is False
        self.assertTrue(published_off, "Pi was never told the new confirmations value")

        # With confirmations off the receipt is gone, but the message must still
        # leave pending state so a reconnect cannot deliver it twice.
        receipts_before = len([m for m in self.telegram.sent
                               if m.get("text") == "Pi · Sent to Firstmate."])
        self.telegram.push_text("after the switch", 204)
        second = pi.read()
        self.assertEqual(second["text"], "after the switch")
        pi.send({"t": "accepted", "id": second["id"]})
        time.sleep(0.6)
        self.assertEqual(
            len([m for m in self.telegram.sent if m.get("text") == "Pi · Sent to Firstmate."]),
            receipts_before,
        )
        pi.close()
        time.sleep(0.3)
        later = self.connect_pi()
        later.expect_nothing(1.0)

        # The choice survives a restart, and Pi's own settings still write it.
        self.stop_bot()
        deadline = time.time() + DEADLINE
        while self.socket_path.exists() and time.time() < deadline:
            time.sleep(0.02)
        self.start_bot()
        restarted = self.connect_pi()
        # Confirmations are a persisted setting; mirror mode is not, so the new
        # process starts mirroring again.
        restarted.send({"t": "command", "id": 3, "command": "status"})
        self.assertEqual(
            restarted.read()["text"],
            "Mirror is on. Firstmate is connected. Confirmations are off.",
        )
        restarted.send({"t": "set", "id": 4, "setting": "confirmations", "value": True})
        self.assertIn("Confirmations are on", restarted.read()["text"])
        self.telegram.push_text("/telegram_status", 205)
        after_pi = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 205
        )
        self.assertIn("Confirmations are on.", after_pi["text"])

    def test_telegram_text_reaches_pi_unchanged_and_is_confirmed(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("look at the failing test", 21)
        frame = pi.read()
        self.assertEqual(frame["t"], "deliver")
        self.assertEqual(frame["text"], "look at the failing test")
        self.assertEqual(set(frame), {"t", "id", "text"})
        pi.send({"t": "accepted", "id": frame["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 21)

    def test_back_to_back_messages_keep_arrival_order(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        for index, text in enumerate(["first", "second", "third"]):
            self.telegram.push_text(text, 30 + index)
        seen = []
        for _ in range(3):
            frame = pi.read()
            seen.append(frame["text"])
            pi.send({"t": "accepted", "id": frame["id"]})
        self.assertEqual(seen, ["first", "second", "third"])

    def test_other_senders_and_chats_are_ignored(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("stranger", 41, user=1)
        self.telegram.push_text("wrong chat", 42, chat=1)
        self.telegram.push_text("paired", 43)
        frame = pi.read()
        self.assertEqual(frame["text"], "paired")
        self.assertNotIn("stranger", " ".join(self.telegram.sent_texts()))
        self.assertNotIn("wrong chat", " ".join(self.telegram.sent_texts()))

    def test_offline_messages_queue_in_memory_and_drain_on_connect(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        pi.close()
        time.sleep(0.3)
        self.telegram.push_text("queued one", 51)
        offline = self.telegram.wait_sent(
            lambda m: m.get("text") == "Firstmate is not running. Your message is queued until it starts."
        )
        self.assertEqual(offline["reply_parameters"]["message_id"], 51)
        self.telegram.push_text("queued two", 52)
        time.sleep(0.3)
        later = self.connect_pi()
        first = later.read()
        second = later.read()
        self.assertEqual([first["text"], second["text"]], ["queued one", "queued two"])
        later.send({"t": "accepted", "id": first["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 51)

    def test_terminal_and_reply_mirroring_follows_mirror_mode(self) -> None:
        pi = self.connect_pi()
        self.disable_mirror(pi)
        pi.send({"t": "terminal", "text": "typed while off"})
        pi.send({"t": "reply", "text": "answered while off"})
        time.sleep(0.4)
        self.assertEqual(self.telegram.sent_texts(), [])
        self.enable_mirror(pi)
        pi.send({"t": "terminal", "text": "check the logs"})
        mirrored = self.telegram.wait_sent(lambda m: "check the logs" in str(m.get("text")))
        self.assertEqual(mirrored["text"], "You · Terminal\ncheck the logs")
        pi.send({"t": "reply", "text": "The logs are clean."})
        reply = self.telegram.wait_sent(lambda m: m.get("text") == "The logs are clean.")
        self.assertNotIn("reply_parameters", reply)

    def test_firstmate_replies_are_never_threaded_while_statuses_are(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_text("what is the status", 61)
        frame = pi.read()
        pi.send({"t": "accepted", "id": frame["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 61)
        pi.send({"t": "reply", "text": "Everything is green."})
        reply = self.telegram.wait_sent(lambda m: m.get("text") == "Everything is green.")
        self.assertNotIn("reply_parameters", reply)

    def test_a_burst_never_threads_replies_but_keeps_every_status_attached(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        # Pi answers a back-to-back burst inside one run, so no reply belongs to
        # any single source message.
        for index, text in enumerate(["burst one", "burst two", "burst three"]):
            self.telegram.push_text(text, 101 + index)
        sources = []
        for _ in range(3):
            frame = pi.read()
            sources.append(frame["text"])
            pi.send({"t": "accepted", "id": frame["id"]})
        self.assertEqual(sources, ["burst one", "burst two", "burst three"])
        for text in ["Reply 1", "Reply 2", "Reply 3", "Reply 4", "Reply 5"]:
            pi.send({"t": "reply", "text": text})
            mirrored = self.telegram.wait_sent(lambda m, want=text: m.get("text") == want)
            self.assertNotIn("reply_parameters", mirrored)
        pi.send({"t": "terminal", "text": "typed while bursting"})
        echoed = self.telegram.wait_sent(lambda m: "typed while bursting" in str(m.get("text")))
        self.assertNotIn("reply_parameters", echoed)

        # Every transport status still names the exact message it describes.
        confirmations = [
            message["reply_parameters"]["message_id"]
            for message in self.telegram.sent
            if message.get("text") == "Pi · Sent to Firstmate."
        ]
        self.assertEqual(sorted(confirmations), [101, 102, 103])
        pi.send({"t": "command", "id": 9, "command": "off"})
        self.assertIn("Mirror is off", pi.read()["text"])
        self.telegram.push_text("after the burst", 110)
        refusal = self.telegram.wait_sent(
            lambda m: m.get("text") == "Telegram mirror is off. Send /telegram_on to enable it."
        )
        self.assertEqual(refusal["reply_parameters"]["message_id"], 110)

    def test_voice_note_edit_then_send(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(71)
        progress = self.telegram.wait_sent(lambda m: m.get("text") == "Transcribing…")
        self.assertEqual(progress["reply_parameters"]["message_id"], 71)
        card_id = int(progress["message_id"])
        card = self.telegram.wait_edit(
            lambda e: e.get("text") == "please rebase the branch"
            and int(e.get("message_id", 0)) == card_id
        )
        buttons = [button["text"] for row in card["reply_markup"]["inline_keyboard"] for button in row]
        self.assertEqual(buttons, ["Send to Firstmate", "Edit", "Cancel"])
        pi.expect_nothing()

        before_edit_view = self.telegram.edit_count()
        self.telegram.push_callback("v:71:1:edit", card_id, "cb-edit")
        edit_view = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == card_id, after=before_edit_view
        )
        edit_buttons = [b["text"] for row in edit_view["reply_markup"]["inline_keyboard"] for b in row]
        self.assertEqual(edit_buttons, ["Copy text", "Back"])
        prompt = self.telegram.wait_sent(
            lambda m: m.get("text") == "Reply to this message with the corrected text."
        )
        self.assertTrue(prompt["reply_markup"]["force_reply"])

        self.telegram.push_text("please rebase the release branch", 72,
                                reply_to=int(prompt["message_id"]))
        corrected = self.telegram.wait_edit(
            lambda e: e.get("text") == "please rebase the release branch"
        )
        restored = [b["text"] for row in corrected["reply_markup"]["inline_keyboard"] for b in row]
        self.assertEqual(restored, ["Send to Firstmate", "Edit", "Cancel"])
        pi.expect_nothing()

        self.telegram.push_callback("v:71:1:send", card_id, "cb-stale")
        stale = [answer for answer in self.telegram.callback_answers if answer.get("text")]
        deadline = time.time() + DEADLINE
        while not stale and time.time() < deadline:
            time.sleep(0.02)
            stale = [answer for answer in self.telegram.callback_answers if answer.get("text")]
        self.assertIn("moved on", stale[0]["text"])
        pi.expect_nothing()

        self.telegram.push_callback("v:71:3:send", card_id, "cb-send")
        sent_card = self.telegram.wait_edit(lambda e: str(e.get("text", "")).endswith("Sent to Firstmate"))
        self.assertEqual(sent_card["reply_markup"], {"inline_keyboard": []})
        frame = pi.read()
        self.assertEqual(frame["text"], "please rebase the release branch")
        pi.send({"t": "accepted", "id": frame["id"]})
        confirmation = self.telegram.wait_sent(lambda m: m.get("text") == "Pi · Sent to Firstmate.")
        self.assertEqual(confirmation["reply_parameters"]["message_id"], 71)
        self.assertFalse((self.home / "audio" / "71.ogg").exists())

        self.telegram.push_callback("v:71:3:send", card_id, "cb-repeat")
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            texts = [a.get("text", "") for a in self.telegram.callback_answers]
            if any("no longer active" in text for text in texts):
                break
            time.sleep(0.02)
        else:
            raise AssertionError("a repeated tap was not refused")
        pi.expect_nothing()

    def test_edit_then_back_retires_the_reply_prompt(self) -> None:
        """Back must leave no live instruction message a reply could still feed."""
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(81)
        card_id = self.card_id_for("please rebase the branch")

        # Edit publishes exactly one instruction message as the correction target.
        before_first_prompt = len(self.telegram.sent)
        self.telegram.push_callback("v:81:1:edit", card_id, "cb-edit-1")
        first_prompt = self.telegram.wait_sent(
            lambda m: m.get("text") == "Reply to this message with the corrected text.",
            after=before_first_prompt,
        )
        first_prompt_id = int(first_prompt["message_id"])
        self.assertTrue(first_prompt["reply_markup"]["force_reply"])

        # Back retires that message in Telegram, not only in the bot's memory.
        before_back_view = self.telegram.edit_count()
        self.telegram.push_callback("v:81:2:back", card_id, "cb-back")
        self.telegram.wait_deleted(first_prompt_id)
        restored = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == card_id, after=before_back_view
        )
        restored_buttons = [b["text"] for row in restored["reply_markup"]["inline_keyboard"]
                            for b in row]
        self.assertEqual(restored_buttons, ["Send to Firstmate", "Edit", "Cancel"])

        # A reply aimed at the retired prompt is ordinary text, never a correction.
        self.telegram.push_text("stray reply to a dead prompt", 82,
                                reply_to=first_prompt_id)
        stray = pi.read()
        self.assertEqual(stray["text"], "stray reply to a dead prompt")
        pi.send({"t": "accepted", "id": stray["id"]})
        with self.telegram.lock:
            self.assertTrue(all(e.get("text") != "stray reply to a dead prompt"
                                for e in self.telegram.edits))

        # Edit again publishes a fresh prompt that still accepts a correction.
        before_second_prompt = len(self.telegram.sent)
        self.telegram.push_callback("v:81:3:edit", card_id, "cb-edit-2")
        second_prompt = self.telegram.wait_sent(
            lambda m: m.get("text") == "Reply to this message with the corrected text.",
            after=before_second_prompt,
        )
        second_prompt_id = int(second_prompt["message_id"])
        self.assertNotEqual(second_prompt_id, first_prompt_id)
        self.assertTrue(second_prompt["reply_markup"]["force_reply"])

        self.telegram.push_text("please rebase the release branch", 83,
                                reply_to=second_prompt_id)
        corrected = self.telegram.wait_edit(
            lambda e: e.get("text") == "please rebase the release branch"
            and int(e.get("message_id", 0)) == card_id
        )
        corrected_buttons = [b["text"] for row in corrected["reply_markup"]["inline_keyboard"]
                             for b in row]
        self.assertEqual(corrected_buttons, ["Send to Firstmate", "Edit", "Cancel"])
        pi.expect_nothing()

        # Exactly one delete: the retired prompt, and no id was retired twice.
        with self.telegram.lock:
            self.assertEqual(self.telegram.deleted, [first_prompt_id])

    def test_voice_send_waits_for_mirroring_to_be_enabled(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(78)
        card_id = self.card_id_for("please rebase the branch")

        self.telegram.push_text("/telegram_off", 780)
        self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is off"))
        edits_before = len(self.telegram.edits)
        self.telegram.push_callback("v:78:1:send", card_id, "cb-off")
        refusal = self.telegram.wait_sent(
            lambda m: m.get("text") == "Telegram mirror is off. Send /telegram_on to enable it."
            and m.get("reply_parameters", {}).get("message_id") == 78
        )
        self.assertTrue(refusal)
        self.assertEqual(len(self.telegram.edits), edits_before)
        pi.expect_nothing()

        self.telegram.push_text("/telegram_on", 781)
        self.telegram.wait_sent(lambda m: str(m.get("text", "")).startswith("Mirror is on"))
        self.telegram.push_callback("v:78:1:send", card_id, "cb-on")
        self.assertEqual(pi.read()["text"], "please rebase the branch")
        self.telegram.wait_edit(lambda e: str(e.get("text", "")).endswith("Sent to Firstmate"))

    def test_unicode_limits_use_telegram_utf16_units(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        reply = "😀" * 3000
        before = len(self.telegram.sent)
        pi.send({"t": "reply", "text": reply})
        deadline = time.time() + DEADLINE
        while time.time() < deadline:
            delivered = self.telegram.sent[before:]
            if "".join(str(message.get("text", "")) for message in delivered) == reply:
                break
            time.sleep(0.05)
        delivered = self.telegram.sent[before:]
        self.assertEqual("".join(str(message.get("text", "")) for message in delivered), reply)
        self.assertTrue(all(len(message["text"].encode("utf-16-le")) // 2 <= 3900
                            for message in delivered))

        self.transcript_file.write_text("😀" * 1901, encoding="utf-8")
        self.telegram.push_voice(791)
        placeholder = self.placeholder_id_for(791)
        refusal = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == placeholder
            and "3,800 characters" in str(e.get("text", ""))
        )
        self.assertEqual(refusal["reply_markup"], {"inline_keyboard": []})
        pi.expect_nothing()

        self.transcript_file.write_text("😀" * 128, encoding="utf-8")
        self.telegram.push_voice(792)
        card_id = self.card_id_for("😀" * 128)
        before_edit_view = self.telegram.edit_count()
        self.telegram.push_callback("v:792:1:edit", card_id, "cb-copy-limit")
        edit_view = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == card_id, after=before_edit_view
        )
        buttons = [button["text"] for row in edit_view["reply_markup"]["inline_keyboard"]
                   for button in row]
        self.assertEqual(buttons, ["Copy text", "Back"])
        prompt = self.telegram.wait_sent(
            lambda m: m.get("text") == "Reply to this message with the corrected text."
        )
        self.telegram.push_text("😀" * 1901, 793, reply_to=int(prompt["message_id"]))
        edit_refusal = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 793
            and "3,800 characters or fewer" in str(m.get("text", ""))
        )
        self.assertTrue(edit_refusal)

        self.transcript_file.write_text("😀" * 129, encoding="utf-8")
        self.telegram.push_voice(794)
        second_card_id = self.card_id_for("😀" * 129)
        before_second_view = self.telegram.edit_count()
        self.telegram.push_callback("v:794:1:edit", second_card_id, "cb-copy-over")
        second_edit = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == second_card_id, after=before_second_view
        )
        second_buttons = [
            button["text"] for row in second_edit["reply_markup"]["inline_keyboard"]
            for button in row
        ]
        self.assertEqual(second_buttons, ["Back"])

    def test_long_transcripts_never_create_multi_message_cards(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.transcript_file.write_text("v" * 3801, encoding="utf-8")
        self.telegram.push_voice(79)
        placeholder = self.placeholder_id_for(79)
        refusal = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == placeholder
            and "3,800 characters" in str(e.get("text", ""))
        )
        self.assertEqual(refusal["reply_markup"], {"inline_keyboard": []})
        self.assertFalse(any(m.get("reply_markup") for m in self.telegram.sent
                             if m.get("reply_parameters", {}).get("message_id") == 79))
        deadline = time.time() + DEADLINE
        while time.time() < deadline and (self.home / "audio" / "79.ogg").exists():
            time.sleep(0.05)
        self.assertFalse((self.home / "audio" / "79.ogg").exists())
        pi.expect_nothing()

    def test_voice_note_cancel_sends_nothing(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(81)
        placeholder = self.placeholder_id_for(81)
        card_id = self.card_id_for("please rebase the branch")
        self.assertEqual(card_id, placeholder)
        self.telegram.push_callback("v:81:1:cancel", card_id, "cb-cancel")
        cancelled = self.telegram.wait_edit(lambda e: str(e.get("text", "")).endswith("Cancelled"))
        self.assertEqual(int(cancelled["message_id"]), placeholder)
        self.assertEqual(cancelled["reply_markup"], {"inline_keyboard": []})
        # The cancelled note owns exactly one bot message, so no "Transcribing…"
        # is left standing beside the outcome.
        self.assertEqual(self.voice_messages(81), ["Transcribing…"])
        self.assertFalse((self.home / "audio" / "81.ogg").exists())
        pi.expect_nothing()

    def test_a_failed_terminal_edit_falls_back_to_a_plain_message(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(82)
        card_id = self.card_id_for("please rebase the branch")
        self.telegram.reject_next_edit = True
        self.telegram.push_callback("v:82:1:send", card_id, "cb-rejected-terminal-edit")
        fallback = self.telegram.wait_sent(
            lambda m: m.get("text") == "please rebase the branch\n\nSent to Firstmate"
            and m.get("reply_parameters", {}).get("message_id") == 82
        )
        self.assertNotIn("reply_markup", fallback)
        self.assertEqual(pi.read()["text"], "please rebase the branch")

    def test_a_voice_note_uses_one_message_from_placeholder_to_card(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.telegram.push_voice(73)
        placeholder = self.placeholder_id_for(73)
        card = self.telegram.wait_edit(
            lambda e: e.get("text") == "please rebase the branch"
            and int(e.get("message_id", 0)) == placeholder
        )
        # The placeholder became the card: same message, transcript actions intact.
        buttons = [button["text"] for row in card["reply_markup"]["inline_keyboard"]
                   for button in row]
        self.assertEqual(buttons, ["Send to Firstmate", "Edit", "Cancel"])
        self.assertEqual(self.voice_messages(73), ["Transcribing…"])
        with self.telegram.lock:
            transcripts = [message for message in self.telegram.sent
                           if message.get("text") == "please rebase the branch"]
        self.assertEqual(transcripts, [], "the transcript arrived as a second message")
        pi.expect_nothing()

        # The buttons address that same message, so the whole flow stays on it.
        self.telegram.push_callback("v:73:1:send", placeholder, "cb-one-message")
        sent_card = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == placeholder
            and str(e.get("text", "")).endswith("Sent to Firstmate")
        )
        self.assertEqual(sent_card["reply_markup"], {"inline_keyboard": []})
        self.assertEqual(pi.read()["text"], "please rebase the branch")

    def test_a_failed_transcription_replaces_its_own_placeholder(self) -> None:
        pi = self.connect_pi()
        self.enable_mirror(pi)
        self.transcript_file.write_text("", encoding="utf-8")
        self.telegram.push_voice(74)
        placeholder = self.placeholder_id_for(74)
        failure = self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == placeholder
            and e.get("text") == "Transcription failed. Nothing was sent to Firstmate."
        )
        self.assertEqual(failure["reply_markup"], {"inline_keyboard": []})
        self.assertEqual(self.voice_messages(74), ["Transcribing…"])
        deadline = time.time() + DEADLINE
        while time.time() < deadline and (self.home / "audio" / "74.ogg").exists():
            time.sleep(0.05)
        self.assertFalse((self.home / "audio" / "74.ogg").exists())
        pi.expect_nothing()

        # A failed note never blocks the next one, and that one is its own
        # single message too.
        self.transcript_file.write_text("try again please", encoding="utf-8")
        self.telegram.push_voice(75)
        second = self.placeholder_id_for(75)
        self.telegram.wait_edit(
            lambda e: int(e.get("message_id", 0)) == second
            and e.get("text") == "try again please"
        )
        self.assertEqual(self.voice_messages(75), ["Transcribing…"])

    def test_a_restart_loses_the_in_memory_queue_and_returns_to_mirroring(self) -> None:
        pi = self.connect_pi()
        pi.close()
        time.sleep(0.3)
        self.telegram.push_text("waiting for firstmate", 91)
        self.telegram.wait_sent(
            lambda m: m.get("text") == "Firstmate is not running. Your message is queued until it starts."
        )
        # Off applies for the rest of this process, from either surface.
        self.telegram.push_text("/telegram_off", 92)
        self.telegram.wait_sent(
            lambda m: str(m.get("text", "")).startswith("Mirror is off")
            and m.get("reply_parameters", {}).get("message_id") == 92
        )
        self.telegram.push_text("ignored while off", 93)
        refusal = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 93
        )
        self.assertEqual(refusal["text"],
                         "Telegram mirror is off. Send /telegram_on to enable it.")

        self.stop_bot()
        deadline = time.time() + DEADLINE
        while self.socket_path.exists() and time.time() < deadline:
            time.sleep(0.02)
        self.assertFalse(self.socket_path.exists(), "the stopped bot left its socket behind")

        # Mirror mode is process memory only, so the next process starts on even
        # though /telegram_off disabled the last one, and the queue is gone.
        self.start_bot()
        later = self.connect_pi()
        self.assertEqual(later.read_frame(), {"t": "state", "mirror": True, "confirmations": True})
        later.expect_nothing(1.0)
        later.send({"t": "command", "id": 1, "command": "status"})
        self.assertEqual(later.read()["text"],
                         "Mirror is on. Firstmate is connected. Confirmations are on.")
        self.telegram.push_text("/telegram_status", 94)
        status = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 94
        )
        self.assertEqual(status["text"],
                         "Mirror is on. Firstmate is connected. Confirmations are on.")

    def test_a_fresh_start_mirrors_without_being_switched_on(self) -> None:
        pi = self.connect_pi()
        # The first state frame a connecting session sees is the live mode.
        self.assertEqual(pi.read_frame(), {"t": "state", "mirror": True, "confirmations": True})
        self.telegram.push_text("do the thing", 301)
        delivered = pi.read()
        self.assertEqual(delivered["text"], "do the thing")
        pi.send({"t": "accepted", "id": delivered["id"]})
        self.telegram.wait_sent(lambda m: m.get("text") == "Pi \u00b7 Sent to Firstmate.")
        pi.send({"t": "terminal", "text": "check the logs"})
        mirrored = self.telegram.wait_sent(lambda m: "check the logs" in str(m.get("text")))
        self.assertEqual(mirrored["text"], "You \u00b7 Terminal\ncheck the logs")
        # Both surfaces report the same untouched mode.
        pi.send({"t": "command", "id": 5, "command": "status"})
        self.assertEqual(pi.read()["text"],
                         "Mirror is on. Firstmate is connected. Confirmations are on.")
        self.telegram.push_text("/telegram_status", 302)
        status = self.telegram.wait_sent(
            lambda m: m.get("reply_parameters", {}).get("message_id") == 302
        )
        self.assertEqual(status["text"],
                         "Mirror is on. Firstmate is connected. Confirmations are on.")

    def test_a_fresh_start_still_refuses_unpaired_traffic(self) -> None:
        """Starting on is not a pairing bypass: only the paired sender is heard."""
        pi = self.connect_pi()
        self.telegram.push_text("stranger", 311, user=1)
        self.telegram.push_text("wrong chat", 312, chat=1)
        self.telegram.push_text("paired", 313)
        self.assertEqual(pi.read()["text"], "paired")
        pi.expect_nothing()
        joined = " ".join(self.telegram.sent_texts())
        self.assertNotIn("stranger", joined)
        self.assertNotIn("wrong chat", joined)


class PeerIdentityTestCase(unittest.TestCase):
    def test_darwin_peer_identity_uses_kernel_pid_and_getpeereid(self) -> None:
        spec = importlib.util.spec_from_file_location("fm_telegram_peer", BOT)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)

        class PeerSocket:
            def fileno(self) -> int:
                return 81

            def getsockopt(self, level: int, option: int, size: int) -> bytes:
                self_level_option = (level, option, size)
                self.observed = self_level_option
                return (4321).to_bytes(4, byteorder=sys.byteorder, signed=True)

        peer_socket = PeerSocket()
        writer = mock.Mock()
        writer.get_extra_info.return_value = peer_socket
        libc = mock.Mock()
        libc.getpeereid.return_value = 0

        def fill_uid(_fd: int, uid: Any, gid: Any) -> int:
            uid._obj.value = 4242
            gid._obj.value = 4242
            return 0

        libc.getpeereid.side_effect = fill_uid
        with mock.patch.object(module.platform, "system", return_value="Darwin"), \
             mock.patch.object(module.ctypes, "CDLL", return_value=libc):
            self.assertEqual(module.peer_credentials(writer), (4321, 4242))
        self.assertEqual(peer_socket.observed, (0, 2, 4))


class ServiceUnitTestCase(unittest.TestCase):
    def test_macos_unit_and_lifecycle_carry_no_secret(self) -> None:
        spec = importlib.util.spec_from_file_location("fm_telegram", BOT)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "com.firstmate.telegram.plist"
            calls: list[tuple[str, ...]] = []
            completed = subprocess.CompletedProcess([], 0, "")
            with mock.patch.object(module, "on_macos", return_value=True), \
                 mock.patch.object(module, "unit_path", return_value=target), \
                 mock.patch.object(module, "launchctl", side_effect=lambda *args: calls.append(args) or completed), \
                 mock.patch.object(module.os, "getuid", return_value=4242):
                module.install_service(Path(tmp) / "telegram")
                payload = target.read_bytes()
                self.assertNotIn(TOKEN.encode(), payload)
                module.uninstall_service()
            self.assertEqual(calls, [
                ("bootstrap", "gui/4242", str(target)),
                ("kickstart", "-k", "gui/4242/com.firstmate.telegram"),
                ("bootout", "gui/4242/com.firstmate.telegram"),
            ])
            self.assertFalse(target.exists())

    def test_unit_starts_the_bot_and_carries_no_secret(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            environment = dict(os.environ)
            firstmate_home = str(Path(tmp) / "firstmate")
            environment.update({
                "FM_TELEGRAM_DIR": tmp,
                "FM_HOME": firstmate_home,
                "TELEGRAM_BOT_TOKEN": TOKEN,
            })
            unit = subprocess.run(
                [sys.executable, str(BOT), "service-unit"], env=environment,
                stdout=subprocess.PIPE, text=True, check=True,
            ).stdout
        if platform.system() == "Darwin":
            payload = plistlib.loads(unit.encode("utf-8"))
            self.assertEqual(payload["Label"], "com.firstmate.telegram")
            self.assertEqual(payload["ProgramArguments"], [sys.executable, str(BOT), "run"])
            self.assertEqual(payload["EnvironmentVariables"], {
                "FM_TELEGRAM_DIR": tmp,
                "FM_HOME": str(Path(firstmate_home).resolve()),
            })
            self.assertTrue(payload["RunAtLoad"])
            self.assertTrue(payload["KeepAlive"])
            self.assertEqual(payload["ProcessType"], "Interactive")
        else:
            sections = parse_systemd_unit(unit)
            self.assertEqual(sections["Install"]["WantedBy"], ["default.target"])
            service = sections["Service"]
            self.assertEqual(service["Type"], ["simple"])
            self.assertEqual(service["ExecStart"], [
                f"{sys.executable} {shlex.quote(str(BOT))} run",
            ])
            self.assertEqual(
                {entry.split("=", 1)[0]: entry.split("=", 1)[1]
                 for entry in service["Environment"]},
                {"FM_TELEGRAM_DIR": tmp, "FM_HOME": firstmate_home},
            )
            self.assertEqual(service["Restart"], ["always"])
            self.assertEqual(service["RestartSec"], ["5"])
            # The bot's own stop is bounded; the unit must not fall back to the 90s
            # default that killed it in the field.
            self.assertEqual(service["TimeoutStopSec"], ["20"])
        self.assertNotIn(TOKEN, unit)

    def test_service_install_refuses_outside_wsl(self) -> None:
        if platform.system() == "Darwin":
            self.skipTest("macOS has a supported LaunchAgent service")
        with tempfile.TemporaryDirectory() as tmp:
            environment = dict(os.environ)
            environment.update({"FM_TELEGRAM_DIR": tmp, "TELEGRAM_BOT_TOKEN": TOKEN})
            environment.pop("WSL_DISTRO_NAME", None)
            environment["FM_TELEGRAM_ASSUME_WSL"] = "0"
            environment["HOME"] = tmp
            result = subprocess.run(
                [sys.executable, str(BOT), "install-service"], env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires WSL or macOS", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
