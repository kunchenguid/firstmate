#!/usr/bin/env python3
"""Capture-only stand-in for the Claude API: record each /v1/messages request body, answer 529.

usage: fm-claude-request-capture.py <port-file> <capture-file>

Binds an ephemeral loopback port, writes it to <port-file>, appends one JSON request body per
line to <capture-file>, and never contacts a model, so a run costs no tokens.
"""
import http.server
import sys

port_file, capture_file = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        if "/v1/messages" in self.path and "count_tokens" not in self.path:
            with open(capture_file, "ab") as out:
                out.write(body.replace(b"\n", b" ") + b"\n")
        reply = b'{"type":"error","error":{"type":"overloaded_error","message":"capture only"}}'
        self.send_response(529)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    do_GET = do_POST


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as out:
    out.write(str(server.server_address[1]))
server.serve_forever()
