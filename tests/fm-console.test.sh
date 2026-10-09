#!/usr/bin/env bash
# End-to-end tests for the local operator console tabs and answer delivery.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

python3 - "$ROOT" "$TMP" <<'PY'
import json
import datetime
import ast
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

repo = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(sys.argv[2])
console_tree = ast.parse((repo / "bin" / "fm-console.py").read_text())
query_assignment = next(node for node in console_tree.body if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "PR_QUERY" for target in node.targets))
pr_query = ast.literal_eval(query_assignment.value)
depth = 0
for char in pr_query:
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        assert depth >= 0, "PR_QUERY contains an extra closing brace"
assert depth == 0, "PR_QUERY has an unclosed selection set"
assert all(field in pr_query for field in ("reviewDecision", "statusCheckRollup", "isDraft", "mergedAt"))
root = tmp / "fake-root"
home = tmp / "home"
(root / "bin").mkdir(parents=True)
(home / "data").mkdir(parents=True)
(home / "state").mkdir()
(home / "projects" / "alpha").mkdir(parents=True)
(tmp / "fake-bin").mkdir()
(home / "data" / "projects.md").write_text("- alpha - Example project\n")
subprocess.run(["git", "init", "-q", str(home / "projects" / "alpha")], check=True)
subprocess.run(["git", "-C", str(home / "projects" / "alpha"), "config", "remote.origin.url", "git@github.com:example/alpha.git"], check=True)
issue_url = "https://github.com/example/alpha/issues/7"
pr_url = "https://github.com/example/alpha/pull/8"
snapshot = {
    "schema": "fm-fleet-snapshot.v1",
    "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "tasks": [
        {"id": "worker", "issue": issue_url, "project": "alpha", "decision_keys": [], "endpoint": {"exists": True}, "backlog": {"repo": "alpha", "state": "in_flight", "links": [], "pr_url": pr_url}, "current_state": {"state": "working"}},
        {"id": "unlinked", "project": "alpha", "backlog": {"repo": "alpha", "state": "in_flight"}, "current_state": {"state": "working"}},
    ],
    "backlog": {"records": [
        {"id": "next", "title": "Waiting task", "repo": "alpha", "state": "queued", "blocked_by_ids": ["worker"], "unresolved_blocker_ids": ["worker"]},
        {"id": "held-call", "title": "Pick a route", "repo": "alpha", "state": "queued", "captain_actionable": True, "hold_reason": "Choose a route", "target_task_id": "worker"},
        {"id": "closed-pr", "title": "Closed pull request", "repo": "alpha", "state": "in_flight", "links": [issue_url], "pr_url": "https://github.com/example/alpha/pull/9"},
    ]},
    "main_inventory": {"valid": True, "reason": None},
    "secondmate_current": {"truncated": 0, "records": [
        {"id": "mate", "home": str(home / "projects" / "mate-home"), "remote": False, "registered": True,
         "current": {"state": "captain_decision", "reason": None}, "freshness": {"status": "fresh", "age_seconds": 0},
         "active_children": [{"id": "mate-child", "state": "working", "repo": "alpha", "issue": issue_url, "pr_url": pr_url, "decision_keys": ["mate-held"]}],
         "decisions_open": [
             {"id": "mate-child", "key": "mate-choice", "verb": "needs-decision", "summary": "Choose A", "target_task_id": "mate-child"},
             {"id": "mate-held", "key": "mate-held", "verb": "captain-hold", "summary": "Choose B", "target_task_id": "mate-child"},
             {"id": "mate-orphan-hold", "key": "mate-orphan-hold", "verb": "captain-hold", "summary": "Choose C"},
         ],
         "queued": [{"id": "mate-next", "title": "Secondmate queued", "repo": "alpha", "blocked_by_ids": ["mate-child"], "unresolved_blocker_ids": ["mate-child"]}],
         "omitted": []},
        {"id": "stale-mate", "registered": True, "current": {"state": "unknown", "reason": "structured home unavailable"},
         "freshness": {"status": "cached", "age_seconds": 100}, "omitted": [{"surface": "queued", "count": 2}]},
    ]},
}
snapshot_path = tmp / "snapshot.json"
snapshot_path.write_text(json.dumps(snapshot))
(root / "bin" / "fm-fleet-snapshot.sh").write_text('#!/bin/bash\nprintf x >> "$FM_CONSOLE_SNAPSHOT_COUNT"\ncat "$FM_CONSOLE_FIXTURE"\n')
(root / "bin" / "fm-fleet-snapshot.sh").chmod(0o755)
(root / "bin" / "fm-classify-lib.sh").write_text('scan_open_decisions() { cat "$FM_CONSOLE_DECISIONS_FILE"; }\n')
(root / "bin" / "fm-send.sh").write_text('#!/bin/bash\nprintf "%s\\t%s\\n" "$FM_HOME" "$*" >> "$FM_CONSOLE_SEND_CAPTURE"\n')
(root / "bin" / "fm-send.sh").chmod(0o755)
(root / "bin" / "fm-captain-hold.sh").write_text('#!/bin/bash\nprintf "%s\\t%s\\t" "$FM_HOME" "$*" >> "$FM_CONSOLE_HOLD_CAPTURE"\nprevious=\nfor arg in "$@"; do if [[ "$previous" == --decision-file ]]; then cat "$arg" >> "$FM_CONSOLE_HOLD_CAPTURE"; exit; fi; previous=$arg; done\ncat >> "$FM_CONSOLE_HOLD_CAPTURE"\n')
(root / "bin" / "fm-captain-hold.sh").chmod(0o755)
mate_home = home / "projects" / "mate-home"
mate_home.mkdir(parents=True)
(mate_home / "state").mkdir()
(mate_home / ".fm-secondmate-home").write_text("mate\n")
fake_gh = tmp / "fake-bin" / "gh"
fake_gh.write_text(r'''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
path = next((arg for arg in args if arg.startswith("repos/")), "")
if "/issues/7" in path:
    out = {"number": 7, "title": "Exact issue title", "state": "open", "html_url": "https://github.com/example/alpha/issues/7"}
elif "graphql" in args:
    query = next(arg.split("=", 1)[1] for arg in args if arg.startswith("query="))
    depth = 0
    for char in query:
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth < 0:
                sys.exit("invalid GraphQL query: unexpected closing brace")
    if depth:
        sys.exit("invalid GraphQL query: unclosed selection set")
    for field in ("reviewDecision", "statusCheckRollup", "isDraft", "mergedAt"):
        if field not in query:
            sys.exit("invalid GraphQL query: missing " + field)
    number = int(next(arg.split("=", 1)[1] for arg in args if arg.startswith("number=")))
    url = f"https://github.com/example/alpha/pull/{number}"
    state = "CLOSED" if number == 9 else "OPEN"
    out = {"data": {"repository": {"pullRequest": {"number": number, "url": url, "state": state,
        "isDraft": False, "merged": False, "mergedAt": None, "reviewDecision": "APPROVED",
        "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS", "contexts": {
            "totalCount": 2, "pageInfo": {"hasNextPage": False}, "nodes": [
                {"__typename": "CheckRun", "name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"},
                {"__typename": "StatusContext", "context": "review-bot", "state": "SUCCESS"},
            ]}}}}]}}}}}
else:
    out = {}
print(json.dumps(out))
''')
fake_gh.chmod(0o755)
capture = tmp / "send.txt"
decisions_path = tmp / "decisions.tsv"
decisions_path.write_text("worker\tdecision-a\tneeds-decision\tShould we ship?\n")
hold_capture = tmp / "hold-capture.txt"
env = {**os.environ, "PATH": f"{tmp / 'fake-bin'}:{os.environ['PATH']}", "FM_CONSOLE_FIXTURE": str(snapshot_path), "FM_CONSOLE_SEND_CAPTURE": str(capture), "FM_CONSOLE_HOLD_CAPTURE": str(hold_capture), "FM_CONSOLE_DECISIONS_FILE": str(decisions_path), "BROWSER": "/usr/bin/true"}
snapshot_count = tmp / "snapshot-count"
gh_log = tmp / "gh-log"
env["FM_CONSOLE_SNAPSHOT_COUNT"] = str(snapshot_count)
env["FM_GH_LOG"] = str(gh_log)
fake_gh.write_text(fake_gh.read_text().replace("args = sys.argv[1:]", "args = sys.argv[1:]\nopen(__import__('os').environ['FM_GH_LOG'], 'a').write(' '.join(args) + '\\n')"))
proc = subprocess.Popen([sys.executable, str(repo / "bin" / "fm-console.py"), "--root", str(root), "--home", str(home), "--port", "0"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
try:
    line = proc.stdout.readline().strip()
    assert line.startswith("http://127.0.0.1:"), line
    port = int(line.rsplit(":", 1)[1].rstrip("/"))
    base = line.rstrip("/")
    page = urllib.request.urlopen(base + "/", timeout=3).read().decode()
    assert all(f">{tab}<" in page for tab in ("Status", "Open decisions", "Queue"))
    data = json.load(urllib.request.urlopen(base + "/api/data", timeout=3))
    rows = data["status"]["rows"]
    assert any(row["title"] == "Exact issue title" and row["issue_state"] == "open" for row in rows), rows
    issue_row = next(row for row in rows if row["title"] == "Exact issue title")
    assert any(task["id"] == "worker" and task["stage"] == "ready" for task in issue_row["tasks"])
    assert any(pr["checks"] == "passed" and pr["review"] == "approved" for pr in issue_row["prs"])
    assert any(task["id"] == "closed-pr" and task["stage"] == "closed unmerged" for task in issue_row["tasks"])
    assert any(row["issue_missing"] and row["title"] == "No issue link recorded" and row["tasks"][0]["id"] == "unlinked" for row in rows), rows
    assert any("stale-mate" in warning and "unavailable" in warning for warning in data["warnings"]), data["warnings"]
    assert any("cached secondmate data" in warning for warning in data["warnings"]), data["warnings"]
    decisions = data["decisions"]
    assert {(item["owner"], item["task"], item["key"], item["verb"]) for item in decisions} == {
        ("main", "worker", "decision-a", "needs-decision"),
        ("main", "worker", "held-call", "captain-hold"),
        ("mate", "mate-child", "mate-choice", "needs-decision"),
        ("mate", "mate-child", "mate-held", "captain-hold"),
        ("mate", None, "mate-orphan-hold", "captain-hold"),
    }, decisions
    orphan_mate = next(item for item in decisions if item["key"] == "mate-orphan-hold")
    assert orphan_mate["answerable"] is True and orphan_mate["direct_hold"] is True
    queue = data["queue"]
    assert next(row for row in queue if row["id"] == "next")["unresolved_blocker_ids"] == ["worker"]
    assert any(row["id"] == "mate/mate-child" for row in queue)
    assert any(row["id"] == "mate/mate-next" and row["unresolved_blocker_ids"] == ["mate-child"] for row in queue)
    assert next(row for row in queue if row["id"] == "next")["admission_state"] == "unknown"
    assert "admission state " in page
    assert data["status"]["generated_epoch"] == int(datetime.datetime.fromisoformat(snapshot["generated"]).timestamp()), (data["status"]["generated_epoch"], snapshot["generated"])
    assert snapshot_count.read_text() == "x", "one refresh should use one shared fleet snapshot"
    json.load(urllib.request.urlopen(base + "/api/data", timeout=3))
    assert snapshot_count.read_text() == "x", "cached reads should not recollect a fleet snapshot"
    snapshot_path.write_text("not JSON")
    stale = json.load(urllib.request.urlopen(base + "/api/data?refresh=1", timeout=3))
    assert stale["status"]["stale"] is True and any(row["title"] == "Exact issue title" for row in stale["status"]["rows"])
    assert snapshot_count.read_text() == "xx"
    snapshot_path.write_text(json.dumps(snapshot))
    body = json.dumps({"owner": "main", "task": "worker", "key": "decision-a", "answer": "--resolve-key is answer text"}).encode()
    request = urllib.request.Request(base + "/api/answer", data=body, method="POST", headers={"Content-Type": "application/json", "Origin": base})
    try:
        urllib.request.urlopen(request, timeout=3)
        raise AssertionError("answer without page token was accepted")
    except urllib.error.HTTPError as exc:
        assert exc.code == 403
    match = re.search(r"const token=(\"[^\"]+\")", page)
    assert match, "page token was not found"
    request.add_header("X-FM-Token", json.loads(match.group(1)))
    result = json.load(urllib.request.urlopen(request, timeout=3))
    assert result["ok"] is True, result
    assert capture.read_text().strip() == f"{home.resolve()}\tworker --resolve-key decision-a -- --resolve-key is answer text"
    assert len([line for line in gh_log.read_text().splitlines() if "graphql" in line]) == 2
    mate_body = json.dumps({"owner": "mate", "task": "mate-child", "key": "mate-choice", "answer": "Choose A"}).encode()
    mate_request = urllib.request.Request(base + "/api/answer", data=mate_body, method="POST", headers={"Content-Type": "application/json", "Origin": base, "X-FM-Token": json.loads(match.group(1))})
    mate_result = json.load(urllib.request.urlopen(mate_request, timeout=3))
    assert mate_result["ok"] is True, mate_result
    assert f"{mate_home.resolve()}\tmate-child --resolve-key mate-choice -- Choose A" in capture.read_text()
    orphan_mate_body = json.dumps({"owner": "mate", "task": None, "key": "mate-orphan-hold", "answer": "Choose C"}).encode()
    orphan_mate_request = urllib.request.Request(base + "/api/answer", data=orphan_mate_body, method="POST", headers={"Content-Type": "application/json", "Origin": base, "X-FM-Token": json.loads(match.group(1))})
    orphan_mate_result = json.load(urllib.request.urlopen(orphan_mate_request, timeout=3))
    assert orphan_mate_result["ok"] is True, orphan_mate_result
    mate_hold = hold_capture.read_text()
    assert mate_hold.startswith(f"{mate_home.resolve()}\tanswer mate-orphan-hold --decision-file ") and mate_hold.endswith("\tChoose C"), mate_hold
    decisions_path.write_text("")
    try:
        urllib.request.urlopen(request, timeout=3)
        raise AssertionError("closed decision was answered a second time")
    except urllib.error.HTTPError as exc:
        assert json.load(exc)["ok"] is False
    assert len(capture.read_text().splitlines()) == 2
finally:
    proc.terminate()
    proc.wait(timeout=5)
PY

if command -v tasks-axi >/dev/null 2>&1; then
  real_home="$TMP/real-home"
  mkdir -p "$real_home/data" "$real_home/state" "$real_home/config" \
    "$real_home/projects/worker" "$real_home/data/worker" "$real_home/fakebin"
  cp "$ROOT/.tasks.toml" "$real_home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$real_home/data/backlog.md"
  (cd "$real_home" && tasks-axi add worker 'Worker task' --kind scout --repo alpha \
    --start --file data/backlog.md >/dev/null)
  printf 'window=firstmate:fm-worker\nworktree=%s/projects/worker\nproject=alpha\nharness=codex\nkind=scout\n' \
    "$real_home" > "$real_home/state/worker.meta"
  printf 'needs-decision [key=route]: choose north or south\n' > "$real_home/state/worker.status"
  printf '# Worker report\n\nTwo routes remain open.\n' > "$real_home/data/worker/report.md"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$real_home" \
    FM_STATE_OVERRIDE="$real_home/state" FM_DATA_OVERRIDE="$real_home/data" \
    FM_CONFIG_OVERRIDE="$real_home/config" "$ROOT/bin/fm-captain-hold.sh" hold \
      sample-route-call --title 'Choose a route' --reason 'route selection' \
      --repo alpha --origin worker >/dev/null
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$real_home" \
    FM_STATE_OVERRIDE="$real_home/state" FM_DATA_OVERRIDE="$real_home/data" \
    FM_CONFIG_OVERRIDE="$real_home/config" "$ROOT/bin/fm-captain-hold.sh" complete \
      worker sample-route-call >/dev/null
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$real_home" \
    FM_STATE_OVERRIDE="$real_home/state" FM_DATA_OVERRIDE="$real_home/data" \
    FM_CONFIG_OVERRIDE="$real_home/config" "$ROOT/bin/fm-captain-hold.sh" hold \
      orphan-call --title 'Standalone route choice' --reason 'no worker remains' \
      --repo alpha >/dev/null
  cat > "$real_home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$real_home/fakebin/tmux"
  env PATH="$real_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$real_home" \
    FM_STATE_OVERRIDE="$real_home/state" FM_DATA_OVERRIDE="$real_home/data" \
    FM_CONFIG_OVERRIDE="$real_home/config" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-console.py" --root "$ROOT" --home "$real_home" --port 0 \
    > "$real_home/console.url" 2> "$real_home/console.err" &
  console_pid=$!
  trap 'kill "$console_pid" 2>/dev/null || true; rm -rf -- "$TMP"' EXIT
  python3 - "$ROOT" "$real_home" "$console_pid" <<'PY'
import json
import datetime
import importlib.util
import os
import pathlib
import re
import subprocess
import sys
import time
import urllib.request

root, home, pid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
url_file = home / "console.url"
for _ in range(200):
    if url_file.exists() and url_file.read_text().strip():
        break
    if subprocess.run(["kill", "-0", str(pid)], check=False).returncode:
        raise AssertionError((home / "console.err").read_text())
    time.sleep(0.025)
base = url_file.read_text().strip().rstrip("/")
page = urllib.request.urlopen(base + "/", timeout=3).read().decode()
token = json.loads(re.search(r"const token=(\"[^\"]+\")", page).group(1))
data = json.load(urllib.request.urlopen(base + "/api/data", timeout=10))
snapshot_env = {**os.environ, "FM_HOME": str(home),
                "PATH": f"{home / 'fakebin'}:{os.environ['PATH']}"}
real_snapshot = subprocess.run([str(root / "bin" / "fm-fleet-snapshot.sh"), "--json"],
                               cwd=root, env=snapshot_env, capture_output=True, text=True, timeout=60)
assert real_snapshot.returncode == 0, real_snapshot.stderr
snapshot_output = json.loads(real_snapshot.stdout)
real_generated = datetime.datetime.fromisoformat(snapshot_output["generated"].replace("Z", "+00:00"))
assert abs(data["generated_epoch"] - int(real_generated.timestamp())) <= 5, (data["generated_epoch"], snapshot_output["generated"])
if os.environ.get("FM_CONSOLE_LIVE_GH") == "1":
    spec = importlib.util.spec_from_file_location("fm_console_live", root / "bin" / "fm-console.py")
    console = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(console)
    pr = console.fetch_pr(root, home, "https://github.com/morecoffeyplease/firstmate/pull/37")
    assert pr["number"] == 37 and pr["html_url"].endswith("/pull/37"), pr
    assert isinstance(pr["review_decision"], str) and isinstance(pr["checks"], str), pr
decision = next(item for item in data["decisions"] if item["key"] == "sample-route-call")
assert (decision["owner"], decision["task"], decision["answerable"]) == ("main", "worker", True), decision
body = json.dumps({"owner": "main", "task": "worker", "key": "sample-route-call", "answer": "take the northern route"}).encode()
request = urllib.request.Request(base + "/api/answer", data=body, method="POST", headers={
    "Content-Type": "application/json", "Origin": base, "X-FM-Token": token})
result = json.load(urllib.request.urlopen(request, timeout=10))
assert result["ok"] is True, result
inbox = home / "state" / "worker.inbox" / "001.msg"
assert inbox.is_file(), list((home / "state").iterdir())
assert "take the northern route" in inbox.read_text(), repr(inbox.read_text())
orphan = next(item for item in data["decisions"] if item["key"] == "orphan-call")
assert orphan["task"] is None and orphan["answerable"] and orphan["direct_hold"], orphan
orphan_body = json.dumps({"owner": "main", "task": None, "key": "orphan-call", "answer": "keep the southern route"}).encode()
orphan_request = urllib.request.Request(base + "/api/answer", data=orphan_body, method="POST", headers={
    "Content-Type": "application/json", "Origin": base, "X-FM-Token": token})
orphan_result = json.load(urllib.request.urlopen(orphan_request, timeout=10))
assert orphan_result["ok"] is True, orphan_result
PY
  kill "$console_pid" 2>/dev/null || true
  wait "$console_pid" 2>/dev/null || true
  show=$(cd "$real_home" && tasks-axi show sample-route-call --full --file data/backlog.md)
  printf '%s' "$show" | grep -F 'state: done' >/dev/null
  show=$(cd "$real_home" && tasks-axi show orphan-call --full --file data/backlog.md)
  printf '%s' "$show" | grep -F 'state: done' >/dev/null
  trap 'rm -rf -- "$TMP"' EXIT
else
  echo 'skip: tasks-axi unavailable for captain-hold console integration'
fi

echo "ok - console tabs render current status, decisions, queue, and deliver keyed answers"
