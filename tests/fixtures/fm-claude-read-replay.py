#!/usr/bin/env python3
"""Scripted stand-in for the Claude API: ask for one Read, then end the turn.

usage: fm-claude-read-replay.py <port-file> <capture-file> <read-path>

Binds an ephemeral loopback port, writes it to <port-file>, and appends one JSON request body
per line to <capture-file>. A main-agent request (one that offers the Read tool) whose last
message carries no tool result is answered with a tool_use asking Read for <read-path>; every
other request is answered with a short end_turn text. No model is contacted, so a run costs no
tokens, and the request that carries the Read result shows what Claude Code added to the
conversation because of that read.
"""
import http.server
import json
import sys

port_file, capture_file, read_path = sys.argv[1], sys.argv[2], sys.argv[3]


def asks_for_read(body):
    if not any(t.get("name") == "Read" for t in body.get("tools", [])):
        return False
    messages = body.get("messages") or [{}]
    content = messages[-1].get("content")
    if isinstance(content, list):
        return not any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return True


def message(blocks, stop_reason):
    return {
        "id": "msg_replay",
        "type": "message",
        "role": "assistant",
        "model": "replay",
        "content": blocks,
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 1},
    }


def events(blocks, stop_reason):
    start = message([], None)
    yield "message_start", {"type": "message_start", "message": start}
    for index, block in enumerate(blocks):
        if block["type"] == "tool_use":
            opened = dict(block, input={})
            delta = {"type": "input_json_delta", "partial_json": json.dumps(block["input"])}
        else:
            opened = {"type": "text", "text": ""}
            delta = {"type": "text_delta", "text": block["text"]}
        yield "content_block_start", {"type": "content_block_start", "index": index, "content_block": opened}
        yield "content_block_delta", {"type": "content_block_delta", "index": index, "delta": delta}
        yield "content_block_stop", {"type": "content_block_stop", "index": index}
    yield "message_delta", {
        "type": "message_delta",
        "delta": {"stop_reason": stop_reason, "stop_sequence": None},
        "usage": {"output_tokens": 1},
    }
    yield "message_stop", {"type": "message_stop"}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, content_type, payload):
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        if "/v1/messages" not in self.path or "count_tokens" in self.path:
            self.reply(200, "application/json", b'{"input_tokens":1}')
            return
        with open(capture_file, "ab") as out:
            out.write(raw.replace(b"\n", b" ") + b"\n")
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        if asks_for_read(body):
            blocks = [{"type": "tool_use", "id": "toolu_replay", "name": "Read", "input": {"file_path": read_path}}]
            stop_reason = "tool_use"
        else:
            blocks = [{"type": "text", "text": "done"}]
            stop_reason = "end_turn"
        if body.get("stream"):
            stream = "".join(
                "event: %s\ndata: %s\n\n" % (name, json.dumps(data)) for name, data in events(blocks, stop_reason)
            )
            self.reply(200, "text/event-stream", stream.encode())
        else:
            self.reply(200, "application/json", json.dumps(message(blocks, stop_reason)).encode())

    def do_GET(self):
        self.reply(200, "application/json", b"{}")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as out:
    out.write(str(server.server_address[1]))
server.serve_forever()
