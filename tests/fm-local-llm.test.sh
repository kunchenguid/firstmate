#!/usr/bin/env bash
# Exercise the optional local text helper through its command line and a stub API.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 - "$ROOT/bin/fm-local-llm.py" <<'PY'
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import tempfile
from threading import Thread

helper = sys.argv[1]
requests = []
reply = {"choices": [{"message": {"content": "feat(local): add log helper\n\nDraft routine text."}}]}

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        requests.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))) )
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory() as temp:
        config = Path(temp) / "config"
        config.mkdir()
        env = {**os.environ, "FM_CONFIG_OVERRIDE": str(config)}
        def run(*args, input="", env=env):
            return subprocess.run([sys.executable, helper, *args], input=input,
                                  text=True, capture_output=True, env=env)

        missing = run("commit-msg", input="diff")
        assert missing.returncode != 0 and missing.stdout == ""
        assert "config/local-llm.json" in missing.stderr

        path = config / "local-llm.json"
        path.write_text(json.dumps({"base_url": f"http://127.0.0.1:{server.server_port}/v1",
                                    "model": "test-model"}))
        commit = run("commit-msg", input="diff --git a/a b/a\n+one line")
        assert commit.returncode == 0, commit.stderr
        assert commit.stdout == "feat(local): add log helper\n\nDraft routine text.\n"
        assert requests[-1][0] == "/v1/chat/completions"
        assert requests[-1][1]["chat_template_kwargs"] == {"enable_thinking": False}
        assert requests[-1][1]["model"] == "test-model"

        repo = Path(temp) / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "a").write_text("changed\n")
        subprocess.run(["git", "-C", str(repo), "add", "a"], check=True)
        staged = run("commit-msg", "--repo", str(repo))
        assert staged.returncode == 0, staged.stderr
        assert "changed" in requests[-1][1]["messages"][1]["content"]

        huge = run("commit-msg", input="a" * 150000 + "TAIL")
        assert huge.returncode == 0, huge.stderr
        sent = requests[-1][1]["messages"][1]["content"]
        assert len(sent) <= 100000 and "[INPUT TRIMMED" in sent and sent.endswith("TAIL")

        reply["choices"][0]["message"]["content"] = "- Nothing failed."
        log_file = Path(temp) / "test.log"
        log_file.write_text("PASS all tests\n")
        summary = run("summarise-log", str(log_file))
        assert summary.returncode == 0 and summary.stdout == "- Nothing failed.\n", summary.stderr
        for model_bullet in ("*   Nothing failed.", "• Nothing failed."):
            reply["choices"][0]["message"]["content"] = model_bullet
            summary = run("summarise-log", str(log_file))
            assert summary.returncode == 0 and summary.stdout == "- Nothing failed.\n", summary.stderr
        reply["choices"][0]["message"]["content"] = "- Nothing failed."
        long_log = run("summarise-log", input="old\n" * 40000 + "FAIL test_one\n")
        assert long_log.returncode == 0, long_log.stderr
        sent = requests[-1][1]["messages"][1]["content"]
        assert len(sent) <= 100000 and sent.endswith("FAIL test_one\n")

        path.write_text(json.dumps({"base_url": "http://127.0.0.1:1/v1", "model": "test-model"}))
        unreachable = run("summarise-log", input="FAIL test_one\n")
        assert unreachable.returncode != 0 and unreachable.stdout == ""
        assert "endpoint unavailable" in unreachable.stderr

        path.write_text(json.dumps({"base_url": f"http://127.0.0.1:{server.server_port}/v1",
                                    "model": "test-model"}))
        reply["choices"][0]["message"]["content"] = ""
        empty = run("commit-msg", input="diff")
        assert empty.returncode != 0 and empty.stdout == ""
finally:
    server.shutdown()
    server.server_close()
print("ok - local LLM helper")
PY
