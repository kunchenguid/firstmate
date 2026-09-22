#!/usr/bin/env bash
# Public-CLI and HTTP regression coverage for the Graphify navigation server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:?}
TOOL="$ROOT/bin/fm-graphify-viewer.py"
TMP_ROOT=$(fm_test_tmproot fm-graphify-viewer)
GRAPH="$TMP_ROOT/graph.json"
SOURCE_ROOT="$TMP_ROOT/source"
LOG="$TMP_ROOT/server.log"
SERVER_PID=''

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

mkdir -p "$SOURCE_ROOT/src" "$SOURCE_ROOT/lib" "$SOURCE_ROOT/docs"
cat > "$GRAPH" <<'JSON'
{
  "nodes": [
    {"id": "alpha", "label": "Alpha", "source_file": "src/a.py", "region_id": "region-a"},
    {"id": "beta", "label": "Beta", "source_file": "src/b.py", "region_id": "region-a"},
    {"id": "gamma", "label": "Gamma", "source_file": "lib/c.py", "region_id": "region-b"},
    {"id": "delta", "label": "Delta", "source_file": "docs/d.py", "region_id": "region-c"}
  ],
  "edges": [
    {"source": "alpha", "target": "beta", "type": "calls"},
    {"source": "beta", "target": "gamma", "type": "calls"},
    {"source": "gamma", "target": "delta", "type": "calls"}
  ]
}
JSON
printf 'print("alpha")\n' > "$SOURCE_ROOT/src/a.py"
printf 'print("beta")\n' > "$SOURCE_ROOT/src/b.py"
printf 'print("gamma")\n' > "$SOURCE_ROOT/lib/c.py"
printf 'print("delta")\n' > "$SOURCE_ROOT/docs/d.py"

python3 "$TOOL" \
  --graph "$GRAPH" \
  --source-root "$SOURCE_ROOT" \
  --port 0 \
  --max-visible 20 \
  > "$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 100); do
  [ -s "$LOG" ] && break
  sleep 0.01
done
[ -s "$LOG" ] || fail "graph viewer did not start"
PORT=$(python3 - "$LOG" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r":(\d+)/\s*$", text)
if not match:
    raise SystemExit("missing listening port")
print(match.group(1))
PY
) || fail "could not read graph viewer port"

python3 - "http://127.0.0.1:$PORT" "$GRAPH" <<'PY' || fail "graph viewer API assertions failed"
import json
import pathlib
import sys
import time
import urllib.parse
import urllib.request

base, graph_path = sys.argv[1:]

def get(path):
    with urllib.request.urlopen(base + path, timeout=5) as response:
        return response.status, response.headers, response.read()

status, headers, body = get("/")
assert status == 200
assert b"type=\"module\"" in body
assert b"assets/" in body

status, _, body = get("/api/health")
health = json.loads(body)
assert status == 200 and health["generation"] == 1

status, _, body = get("/api/subgraph?level=region&limit=2")
region = json.loads(body)
assert status == 200 and region["level"] == "region"
assert len(region["nodes"]) == 2 and region["truncated"]
assert {node["role"] for node in region["nodes"]} == {"structural_region"}
assert region["edges"]

status, _, body = get("/api/subgraph?level=file&limit=3")
files = json.loads(body)
assert status == 200 and files["level"] == "file"
assert {node["role"] for node in files["nodes"]} == {"file_module"}
assert {node["label"] for node in files["nodes"]} == {"docs/d.py", "lib/c.py", "src/a.py"}
assert files["edges"][0]["label"] == "calls"

status, _, body = get("/api/subgraph?level=function&limit=10")
functions = json.loads(body)
assert {node["role"] for node in functions["nodes"]} == {"function"}
assert status == 200 and functions["level"] == "function"
assert functions["edges"][0]["label"] == "calls"

status, _, body = get("/api/scene?limit=20")
scene = json.loads(body)
assert status == 200 and scene["schema"] == "graphify-scene/v2"
assert {node["level"] for node in scene["nodes"]} == {
    "cluster",
    "region",
    "file",
    "function",
}
assert len(scene["nodes"]) == 14 and not scene["truncated"]
by_id = {node["id"]: node for node in scene["nodes"]}
assert by_id["file:src/a.py"]["parent_id"] in by_id
assert by_id["file:src/a.py"]["parent_id"].startswith("region-")
assert by_id["function:alpha"]["parent_id"] == "file:src/a.py"
assert all(
    node["parent_id"].startswith("cluster:")
    for node in scene["nodes"]
    if node["level"] == "region"
)
assert all(
    node["cluster_id"].startswith("cluster:")
    for node in scene["nodes"]
    if node["level"] == "function"
)
assert {edge["kind"] for edge in scene["edges"]} == {"call", "contains"}
assert sum(node["level"] == "cluster" for node in scene["nodes"]) == 3
status, _, body = get("/api/scene?limit=8")
bounded_scene = json.loads(body)
assert status == 200 and len(bounded_scene["nodes"]) <= 8 and bounded_scene["truncated"]

status, _, body = get("/api/search?q=beta&limit=10")
search = json.loads(body)
assert status == 200 and search[0]["id"] == "beta"
assert search[0]["role"] == "file_module"

status, _, body = get("/api/source?path=" + urllib.parse.quote("src/b.py"))
source = json.loads(body)
assert status == 200 and 'print("beta")' in source["content"]

path = pathlib.Path(graph_path)
graph = json.loads(path.read_text(encoding="utf-8"))
graph["nodes"].append({"id": "epsilon", "label": "Epsilon", "source_path": "src/e.py", "region_id": "region-c"})
path.write_text(json.dumps(graph) + "\n", encoding="utf-8")
time.sleep(0.03)
status, _, body = get("/api/health")
health = json.loads(body)
assert status == 200 and health["generation"] == 2 and health["nodes"] == 5
PY

pass "Graphify viewer serves bounded hierarchy, calls, search, source inspection, and mtime reload"
