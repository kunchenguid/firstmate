#!/usr/bin/env bash
# tests/fm-console.test.sh - loopback console auth, owner integration, and cache.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import base64
from concurrent.futures import ThreadPoolExecutor
import http.client
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
import sys
from http.server import ThreadingHTTPServer

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("fm_console", root / "bin/fm-console.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory(prefix="fm-console-test-", dir=root) as temp:
    home = Path(temp) / "home"
    (home / "config").mkdir(parents=True)
    (home / "state").mkdir()
    secret_file = home / "config/console-operator-secret"
    try:
        module.read_secret(home)
        raise AssertionError("absent secret must fail closed")
    except ValueError:
        pass
    secret_file.write_text("a" * 40 + "\n")
    secret_file.chmod(0o600)
    secret = module.read_secret(home)
    secret_file.chmod(0o644)
    try:
        module.read_secret(home)
        raise AssertionError("readable secret must fail closed")
    except ValueError:
        pass
    secret_file.chmod(0o600)
    fixture = {
        "schema": "fm-bearings.v1", "generated": "2026-09-21T12:00:00Z",
        "in_flight": [{"id": "task-1", "name": "Build UI", "state": "working", "repo": "firstmate", "doing": "Editing /secret/file"}],
        "decisions_open": [{"id": "decision-1", "summary": "Approve direction", "owner": "(main)"}],
        "gates": [], "landed": [], "secondmates": [{"id": "remote", "state": "unknown", "freshness": "stale", "reason": "unreadable"}],
        "omitted": [{"surface": "in_flight showing 20 of 25", "reveal": "inspect /secret/file"}],
        "actions": [{"watch": "rm -rf /secret"}], "paths": [{"worktree": "/secret/file"}],
    }
    (home / "fixture.json").write_text(json.dumps(fixture))
    snapshot = Path(temp) / "snapshot.sh"
    snapshot.write_text('#!/usr/bin/env bash\nprintf "x\\n" >> "$FM_HOME/calls"\nsleep 0.25\ncat "$FM_HOME/fixture.json"\n')
    snapshot.chmod(0o700)
    ready = json.dumps({"schema": "fm-primary-ready.v1", "observed_at": "2026-09-21T12:00:00Z",
                        "lock": {"state": "unknown", "pid": None}, "wake_consumer": {"state": "unknown"},
                        "posture": {"state": "present"}, "can_receive": "unknown"})
    inbox = Path(temp) / "inbox.sh"
    inbox.write_text('#!/usr/bin/env bash\nif [ "$1" = ready ]; then\n  printf \'%s\\n\' ' + "'" + ready + "'" + '\nelse\n  exec ' + str(root / "bin/fm-inbox.sh") + ' "$@"\nfi\n')
    inbox.chmod(0o700)
    service = module.ConsoleService(home, secret, snapshot_bin=snapshot, inbox_bin=inbox)
    server = ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
    server.daemon_threads = True
    server.service = service
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_port
    auth = "Basic " + base64.b64encode(("operator:" + secret).encode()).decode()

    def request(method, path, payload=None, authorized=True, extras=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        headers = {"Host": f"127.0.0.1:{port}"}
        if authorized: headers["Authorization"] = auth
        if extras: headers.update(extras)
        conn.request(method, path, body=payload, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        result = (response.status, json.loads(raw) if response.getheader("Content-Type", "").startswith("application/json") and raw else raw)
        conn.close()
        return result

    try:
        for path in ("/", "/app.css", "/app.js", "/api/session", "/api/fleet", "/api/ready", "/api/receipts", "/api/events", "/unknown"):
            assert request("GET", path, authorized=False)[0] == 401, path
        assert request("POST", "/api/order", "{}", authorized=False)[0] == 401
        assert request("HEAD", "/", authorized=False)[0] == 401
        assert request("OPTIONS", "/api/order", authorized=False)[0] == 401
        bad_auth = "Basic " + base64.b64encode("operator:pässword".encode()).decode()
        assert request("GET", "/", extras={"Authorization": bad_auth})[0] == 401
        assert request("GET", "/api/session", extras={"Origin": "https://evil.example"})[0] == 403
        assert request("GET", "/api/session", extras={"Host": "evil.example"})[0] == 403
        assert request("GET", "/api/ready")[1]["can_receive"] == "unknown"
        csrf = request("GET", "/api/session")[1]["csrf"]
        order = json.dumps({"request_id": "browser-1", "text": "line one\nline two"})
        post_headers = {"Origin": f"http://127.0.0.1:{port}", "Content-Type": "application/json", "X-Console-CSRF": csrf}
        assert request("POST", "/api/order", order, extras={"Origin": post_headers["Origin"], "Content-Type": "application/json"})[0] == 403
        assert request("POST", "/api/order", order, extras={**post_headers, "Origin": "https://evil.example"})[0] == 403
        assert request("POST", "/api/order", json.dumps({"request_id": ".unsafe", "text": "hi"}), extras=post_headers)[0] == 400
        first_status, first = request("POST", "/api/order", order, extras=post_headers)
        retry_status, retry = request("POST", "/api/order", order, extras=post_headers)
        assert first_status == retry_status == 202
        assert first["outcome"] == "created" and retry["outcome"] == "replay"
        assert first["id"] == retry["id"] and first["saved"] and first["pending"]
        assert first["readiness"]["can_receive"] == "unknown"
        notes = list((home / "state/inbox").glob("*.note"))
        assert len(notes) == 1 and "line one\nline two" in notes[0].read_text()
        assert (home / "state/.wake-queue").read_text().count("inbox:") == 1
        receipts = request("GET", "/api/receipts?after=")[1]
        assert len(receipts["pending"]) == 1 and receipts["pending"][0]["announced"] is True
        assert "path" not in json.dumps(receipts)
        assert request("GET", "/api/receipts?after=bad")[0] == 400
        answer = "Answer from primary: https://github.com/kunchenguid/firstmate/pull/5103 edits /etc/caddy/Caddyfile"
        module.subprocess.run([str(root / "bin/fm-inbox.sh"), "reply", first["id"], answer],
                              env=service.env(), check=True, capture_output=True)
        receipts = request("GET", "/api/receipts?after=")[1]
        assert receipts["replies"][0]["body"] == answer
        assert request("GET", "/api/receipts?after=" + receipts["reply_cursor"])[1]["replies"] == []
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: request("GET", "/api/fleet"), range(8)))
        assert all(status == 200 for status, _ in results)
        assert (home / "calls").read_text().count("x") == 1, "concurrent polls must share one collector"
        time.sleep(0.35)
        _, fleet = request("GET", "/api/fleet")
        assert fleet["snapshot"]["omitted"] == ["in_flight showing 20 of 25"]
        assert fleet["snapshot"]["secondmates"][0]["freshness"] == "stale"
        assert fleet["observed_at"] == "2026-09-21T12:00:00Z"
        assert "actions" not in json.dumps(fleet) and "/secret" not in json.dumps(fleet)
        assert (home / "calls").read_text().count("x") == 1, "cache hits must not start another observation"
        time.sleep(0.35)
        assert (home / "calls").read_text().count("x") == 1, "no viewers means no new collection"
        assert "Quick ask" in request("GET", "/")[1].decode()
        print("pass: auth, CSRF, unknown readiness, request replay, replies, omissions, serialized collection")
    finally:
        server.shutdown()
        server.server_close()
PY
node --check "$ROOT/web/console/app.js"
node - "$ROOT/web/console/app.js" <<'JS'
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const elements = new Map();
const document = {
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, {textContent: "", hidden: true});
    return elements.get(id);
  },
};
const context = vm.createContext({
  document,
  fetch: () => Promise.reject(new Error("fixture offline")),
});
vm.runInContext(fs.readFileSync(process.argv[2], "utf8"), context);
vm.runInContext('renderReady({can_receive:"unknown",observed_at:"2026-09-21T12:00:00Z",lock:"unknown",wake_consumer:"unknown",posture:"present"})', context);
assert.match(elements.get("readiness").textContent, /readiness unknown/i);
assert.match(elements.get("order-readiness").textContent, /may remain pending/i);
assert.doesNotMatch(elements.get("order-readiness").textContent, /refus/i);
console.log("pass: browser rendering keeps readiness unknown distinct from refusal");
JS
