#!/usr/bin/env python3
"""Scripted stand-in for the Claude API: answer with fixed Bash tool calls, record their results.

usage: fm-claude-scripted-tools.py <port-file> <results-file> <step>...

Binds an ephemeral loopback port and writes it to <port-file>. Every streamed /v1/messages
request that offers the Bash tool is the main conversation: the reply to the Nth such request
is a tool call for the Nth <step>, and once every step has run the reply is a
plain end_turn text. Each tool_result the client sends back is appended to <results-file> as
one JSON line {"command": ..., "is_error": ..., "content": ...}. A <step> is a Bash command,
or "tool:" followed by a JSON object {"name": ..., "input": {...}} for any other tool, such as
the Write tool. Any other request (titles,
summaries, token counts) gets a short text answer. No model is contacted, so a run costs no
tokens, and the tool results are whatever the real client and its sandbox produced.
"""
import http.server
import json
import sys

port_file, results_file, commands = sys.argv[1], sys.argv[2], sys.argv[3:]


def flatten(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def tool_results(messages):
    """Every tool_result in the conversation, oldest first, keyed by tool_use id."""
    found = []
    for message in messages:
        if message.get("role") != "user" or not isinstance(message.get("content"), list):
            continue
        for block in message["content"]:
            if isinstance(block, dict) and block.get("type") == "tool_result":
                found.append(block)
    return found


def events(blocks, stop_reason):
    yield "message_start", {"type": "message_start", "message": {
        "id": "msg_scripted", "type": "message", "role": "assistant", "model": "scripted",
        "content": [], "stop_reason": None, "stop_sequence": None,
        "usage": {"input_tokens": 1, "output_tokens": 1}}}
    for index, block in enumerate(blocks):
        if block["type"] == "text":
            yield "content_block_start", {"type": "content_block_start", "index": index,
                                          "content_block": {"type": "text", "text": ""}}
            yield "content_block_delta", {"type": "content_block_delta", "index": index,
                                          "delta": {"type": "text_delta", "text": block["text"]}}
        else:
            yield "content_block_start", {"type": "content_block_start", "index": index,
                                          "content_block": {"type": "tool_use", "id": block["id"],
                                                            "name": block["name"], "input": {}}}
            yield "content_block_delta", {"type": "content_block_delta", "index": index,
                                          "delta": {"type": "input_json_delta",
                                                    "partial_json": json.dumps(block["input"])}}
        yield "content_block_stop", {"type": "content_block_stop", "index": index}
    yield "message_delta", {"type": "message_delta",
                            "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                            "usage": {"output_tokens": 1}}
    yield "message_stop", {"type": "message_stop"}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply_json(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        if "count_tokens" in self.path:
            self.reply_json({"input_tokens": 1})
            return
        try:
            request = json.loads(raw or b"{}")
        except ValueError:
            request = {}
        tools = [t.get("name") for t in request.get("tools", []) if isinstance(t, dict)]
        blocks, stop = [{"type": "text", "text": "ok"}], "end_turn"
        if "Bash" in tools:
            results = tool_results(request.get("messages", []))
            if results:
                last = results[-1]
                with open(results_file, "a") as out:
                    out.write(json.dumps({
                        "command": commands[len(results) - 1] if len(results) <= len(commands) else None,
                        "is_error": bool(last.get("is_error")),
                        "content": flatten(last.get("content")),
                    }) + "\n")
            step = len(results)
            if step < len(commands):
                if commands[step].startswith("tool:"):
                    call = json.loads(commands[step][len("tool:"):])
                    name, tool_input = call["name"], call["input"]
                else:
                    name = "Bash"
                    tool_input = {"command": commands[step], "description": "scripted step %d" % step}
                blocks = [{"type": "tool_use", "id": "toolu_scripted_%d" % step, "name": name,
                           "input": tool_input}]
                stop = "tool_use"
            else:
                blocks = [{"type": "text", "text": "scripted run complete"}]
        if not request.get("stream"):
            content = [b if b["type"] == "text" else {k: b[k] for k in ("type", "id", "name", "input")}
                       for b in blocks]
            self.reply_json({"id": "msg_scripted", "type": "message", "role": "assistant",
                             "model": "scripted", "content": content, "stop_reason": stop,
                             "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 1}})
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        for name, data in events(blocks, stop):
            self.wfile.write(("event: %s\ndata: %s\n\n" % (name, json.dumps(data))).encode())
            self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        self.reply_json({})


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as out:
    out.write(str(server.server_address[1]))
server.serve_forever()
