#!/usr/bin/env python3
"""Local OpenAI-compatible streaming endpoint for the real-Pi Telegram guard.

Answers every request with the same slow, uniquely numbered reply so the guard
can drive Pi's run collapsing without a credential, a vendor quota, or any
network call. Usage: fake-model.py <port> [chunk-delay-seconds]
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
DELAY = float(sys.argv[2]) if len(sys.argv) > 2 else 0.35
COUNTER = iter(range(1, 10_000))
LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        record = os.environ.get("FM_FAKE_MODEL_PAYLOADS")
        if record:
            with open(record, "a", encoding="utf-8") as handle:
                handle.write(body.decode("utf-8", "replace") + "\n")
        with LOCK:
            index = next(COUNTER)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        base = {"id": f"chatcmpl-{index}", "object": "chat.completion.chunk",
                "created": int(time.time()), "model": "slow-fake"}

        def emit(payload):
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        try:
            emit({**base, "choices": [{"index": 0, "delta": {"role": "assistant"},
                                       "finish_reason": None}]})
            for chunk in ("MIRROR_LIVE_REPLY", f" {index}", " done."):
                time.sleep(DELAY)
                emit({**base, "choices": [{"index": 0, "delta": {"content": chunk},
                                           "finish_reason": None}]})
            emit({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                  "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
