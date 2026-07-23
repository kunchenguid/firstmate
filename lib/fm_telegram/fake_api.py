"""Deterministic fake Telegram endpoint and transport fault foundation."""

from __future__ import annotations

import json
import threading
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Deque, Dict, List, Mapping, Optional, Union

from .telegram_api import (
    BotToken,
    TelegramTransport,
    TransportFailure,
    TransportResponse,
    WriteState,
)


@dataclass(frozen=True)
class FakeReply:
    status_code: int = 200
    payload: Optional[Any] = None
    raw_body: Optional[bytes] = None
    delay_seconds: float = 0.0
    disconnect_after_read: bool = False

    def body(self) -> bytes:
        if self.raw_body is not None:
            return self.raw_body
        return json.dumps(
            self.payload, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")


@dataclass(frozen=True, repr=False)
class RecordedRequest:
    method: str
    payload: Mapping[str, Any]

    def __repr__(self) -> str:
        return f"RecordedRequest(method={self.method!r}, payload=<redacted>)"


class FakeTelegramServer:
    """A loopback HTTP server with one FIFO response script per Bot API method."""

    def __init__(self, *, chat_id: str = "424242") -> None:
        self.chat_id = chat_id
        self._scripts: Dict[str, Deque[FakeReply]] = defaultdict(deque)
        self._requests: List[RecordedRequest] = []
        self._lock = threading.Lock()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                method = self.path.rsplit("/", 1)[-1]
                try:
                    payload = json.loads(raw.decode("utf-8"))
                except (UnicodeError, json.JSONDecodeError):
                    payload = {}
                with owner._lock:
                    owner._requests.append(RecordedRequest(method, payload))
                    script = owner._scripts[method]
                    reply = script.popleft() if script else owner._default(method)
                if reply.disconnect_after_read:
                    self.close_connection = True
                    return
                if reply.delay_seconds:
                    time.sleep(reply.delay_seconds)
                body = reply.body()
                try:
                    self.send_response(reply.status_code)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, _format: str, *_args: Any) -> None:
                pass

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            name="fake-telegram-api",
            daemon=True,
        )

    @property
    def api_root(self) -> str:
        host, port = self._server.server_address
        return f"http://{host}:{port}"

    def start(self) -> "FakeTelegramServer":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)

    def __enter__(self) -> "FakeTelegramServer":
        return self.start()

    def __exit__(self, *_args: Any) -> None:
        self.stop()

    def enqueue(self, method: str, reply: FakeReply) -> None:
        with self._lock:
            self._scripts[method].append(reply)

    def requests(self) -> List[RecordedRequest]:
        with self._lock:
            return list(self._requests)

    def _default(self, method: str) -> FakeReply:
        if method == "getUpdates":
            return FakeReply(payload={"ok": True, "result": []})
        if method == "getWebhookInfo":
            return FakeReply(payload={"ok": True, "result": {"url": ""}})
        if method in ("deleteMessage", "answerCallbackQuery"):
            return FakeReply(payload={"ok": True, "result": True})
        return FakeReply(
            payload={
                "ok": True,
                "result": {"message_id": len(self._requests), "chat": {"id": int(self.chat_id)}},
            }
        )


ScriptItem = Union[TransportResponse, TransportFailure]


class DeterministicTransport(TelegramTransport):
    """In-memory transport for exact pre-write and post-write fault injection."""

    def __init__(self, script: List[ScriptItem]) -> None:
        self._script: Deque[ScriptItem] = deque(script)
        self.requests: List[RecordedRequest] = []

    def post(
        self,
        api_root: str,
        token: BotToken,
        method: str,
        payload: Mapping[str, Any],
        timeout_seconds: float,
    ) -> TransportResponse:
        del api_root, token, timeout_seconds
        if not self._script:
            raise AssertionError("deterministic Telegram transport script exhausted")
        item = self._script.popleft()
        if isinstance(item, TransportFailure):
            if item.write_state == WriteState.AFTER_WRITE:
                self.requests.append(RecordedRequest(method, dict(payload)))
            raise item
        self.requests.append(RecordedRequest(method, dict(payload)))
        return item


def json_response(status_code: int, payload: Any) -> TransportResponse:
    return TransportResponse(
        status_code=status_code,
        body=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
    )
