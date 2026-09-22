#!/usr/bin/env bash
# Public-CLI regression coverage for bin/fm-graphify-embed.py.
#
# A local HTTP server stands in for an OpenAI-compatible embeddings provider.
# The test proves structured fingerprints and deterministic clusters.
# It also proves bounded semantic edges, region-plan handoff data, input preservation, and credential-safe diagnostics.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=${ROOT:?}
TOOL="$ROOT/bin/fm-graphify-embed.py"
TMP_ROOT=$(fm_test_tmproot fm-graphify-embed)
INPUT="$TMP_ROOT/graph.json"
INPUT_COPY="$TMP_ROOT/graph-copy.json"
OUTPUT_ONE="$TMP_ROOT/output-one.json"
OUTPUT_TWO="$TMP_ROOT/output-two.json"
REGIONS_ONE="$TMP_ROOT/regions-one.json"
REGIONS_TWO="$TMP_ROOT/regions-two.json"
PORT_FILE="$TMP_ROOT/port"
REQUEST_LOG="$TMP_ROOT/requests.jsonl"
SERVER_SCRIPT="$TMP_ROOT/server.py"
STDOUT_FILE="$TMP_ROOT/stdout"
STDERR_FILE="$TMP_ROOT/stderr"
NO_PROVIDER_ERR="$TMP_ROOT/no-provider.stderr"
LOCAL_MODULES="$TMP_ROOT/local-modules"
NO_CUDA_MODULES="$TMP_ROOT/no-cuda-modules"
LOCAL_OUTPUT="$TMP_ROOT/local-output.json"
LOCAL_REGIONS="$TMP_ROOT/local-regions.json"
STRUCTURAL_OUTPUT="$TMP_ROOT/structural-output.json"
STRUCTURAL_REGIONS="$TMP_ROOT/structural-regions.json"
GPU_ERR="$TMP_ROOT/gpu-refusal.stderr"
KEY='graphify-test-key-never-printed'
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
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 131' QUIT

cat > "$INPUT" <<'JSON'
{
  "nodes": [
    {"id": "user", "label": "User", "source_path": "src/user.py"},
    {"id": "account", "label": "Account", "source_path": "src/account.py"},
    {"id": "invoice", "label": "Invoice", "source_path": "src/invoice.py"}
  ],
  "edges": [
    {"source": "user", "target": "account", "type": "declares"},
    {"source": "account", "target": "invoice", "type": "references"},
    {"source": "claude_mods_firstmate_calm_hooks_register", "target": "user", "type": "references"},
    {"source": "account", "target": "ref_claude_code", "type": "references"}
  ],
  "metadata": {"authoritative": true}
}
JSON
cp "$INPUT" "$INPUT_COPY"
mkdir -p "$LOCAL_MODULES" "$NO_CUDA_MODULES"
cat > "$LOCAL_MODULES/torch.py" <<'PY'
class cuda:
    @staticmethod
    def is_available():
        return True
PY
cat > "$NO_CUDA_MODULES/torch.py" <<'PY'
class cuda:
    @staticmethod
    def is_available():
        return False
PY
cat > "$LOCAL_MODULES/sentence_transformers.py" <<'PY'
class SentenceTransformer:
    def __init__(self, model, device=None):
        if model != "test-local-model" or device != "cuda":
            raise RuntimeError("unexpected local model configuration")
        self.device = device

    def encode(self, fingerprints, convert_to_numpy=True, show_progress_bar=False):
        if not convert_to_numpy or show_progress_bar:
            raise RuntimeError("unexpected encode configuration")
        return [
            [1.0, 0.0],
            [0.9, 0.435889894],
            [0.0, 1.0],
        ][: len(fingerprints)]
PY
cp "$LOCAL_MODULES/sentence_transformers.py" "$NO_CUDA_MODULES/sentence_transformers.py"

cat > "$SERVER_SCRIPT" <<'PY'
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port_path, request_path = sys.argv[1:]
expected_key = os.environ["GRAPHIFY_TEST_KEY"]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        with open(request_path, "ab") as stream:
            stream.write(body + b"\n")
        if self.headers.get("Authorization") != "Bearer " + expected_key:
            self.send_response(401)
            self.end_headers()
            return
        try:
            request = json.loads(body.decode("utf-8"))
            count = len(request["input"])
        except (ValueError, KeyError, TypeError):
            self.send_response(400)
            self.end_headers()
            return
        vectors = [
            [1.0, 0.0],
            [0.9, 0.435889894],
            [0.0, 1.0],
        ][:count]
        response = {"data": [{"index": i, "embedding": vector} for i, vector in enumerate(vectors)]}
        encoded = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, _format, *_args):
        return


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_path, "w", encoding="utf-8") as stream:
    stream.write(str(server.server_port))
server.serve_forever()
PY

GRAPHIFY_TEST_KEY="$KEY" python3 "$SERVER_SCRIPT" "$PORT_FILE" "$REQUEST_LOG" &
SERVER_PID=$!
for _ in $(seq 1 100); do
  [ -s "$PORT_FILE" ] && break
  sleep 0.01
done
[ -s "$PORT_FILE" ] || fail "fake embedding endpoint did not start"
PORT=$(cat "$PORT_FILE")
ENDPOINT="http://127.0.0.1:$PORT/v1/embeddings"

run_tool() {
  local output=$1
  local region_plan=$2
  OPENAI_API_KEY="$KEY" "$TOOL" \
    --input "$INPUT" \
    --endpoint "$ENDPOINT" \
    --model test-embedding-model \
    --threshold 0.8 \
    --top-k 1 \
    --output "$output" \
    --region-plan-output "$region_plan" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE"
}

run_local_tool() {
  local output=$1
  local region_plan=$2
  env -u OPENAI_API_KEY -u GRAPHIFY_EMBEDDINGS_ENDPOINT -u GRAPHIFY_EMBEDDINGS_MODEL \
    PYTHONPATH="$LOCAL_MODULES${PYTHONPATH:+:$PYTHONPATH}" "$TOOL" \
    --backend local \
    --model test-local-model \
    --device cuda \
    --input "$INPUT" \
    --threshold 0.8 \
    --top-k 1 \
    --output "$output" \
    --region-plan-output "$region_plan" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE"
}

run_structural_tool() {
  env -u OPENAI_API_KEY -u GRAPHIFY_EMBEDDINGS_ENDPOINT -u GRAPHIFY_EMBEDDINGS_MODEL \
    "$TOOL" \
    --backend structural \
    --input "$INPUT" \
    --threshold 0.8 \
    --top-k 1 \
    --output "$STRUCTURAL_OUTPUT" \
    --region-plan-output "$STRUCTURAL_REGIONS" \
    > "$STDOUT_FILE" 2> "$STDERR_FILE"
}

run_tool "$OUTPUT_ONE" "$REGIONS_ONE"
code=$?
expect_code 0 "$code" "embedding CLI succeeds with fake provider"
assert_contains "$(cat "$STDOUT_FILE")" 'graphify embedding complete: 3 nodes, 2 semantic edges' "CLI reports output counts"
assert_equals '' "$(cat "$STDERR_FILE")" "successful CLI is quiet on stderr"

run_tool "$OUTPUT_TWO" "$REGIONS_TWO"
code=$?
expect_code 0 "$code" "repeated embedding CLI run succeeds"
assert_equals 0 "$(cmp -s "$REGIONS_ONE" "$REGIONS_TWO"; printf '%s' "$?")" "identical inputs produce identical region plan"
assert_equals 0 "$(cmp -s "$OUTPUT_ONE" "$OUTPUT_TWO"; printf '%s' "$?")" "identical inputs produce identical output"
assert_equals 0 "$(cmp -s "$INPUT" "$INPUT_COPY"; printf '%s' "$?")" "input graph remains unchanged"
run_local_tool "$LOCAL_OUTPUT" "$LOCAL_REGIONS"
code=$?
expect_code 0 "$code" "local embedding backend succeeds with fake CUDA provider"
assert_contains "$(cat "$STDOUT_FILE")" 'graphify embedding complete: 3 nodes, 2 semantic edges' "local backend reports output counts"
assert_equals '' "$(cat "$STDERR_FILE")" "local backend is quiet on stderr"
run_structural_tool
code=$?
expect_code 0 "$code" "structural region backend succeeds without provider"
assert_contains "$(cat "$STDOUT_FILE")" "graphify structural region plan complete: 3 nodes, 1 regions" "structural backend reports region count"
assert_equals '' "$(cat "$STDERR_FILE")" "structural backend is quiet on stderr"

set +e
env -u OPENAI_API_KEY -u GRAPHIFY_EMBEDDINGS_ENDPOINT -u GRAPHIFY_EMBEDDINGS_MODEL \
  PYTHONPATH="$NO_CUDA_MODULES${PYTHONPATH:+:$PYTHONPATH}" "$TOOL" \
  --backend local \
  --model test-local-model \
  --device cuda \
  --input "$INPUT" \
  --threshold 0.8 \
  --top-k 1 \
  --output "$TMP_ROOT/gpu-refusal.json" \
  --region-plan-output "$TMP_ROOT/gpu-refusal.regions.json" \
  > /dev/null 2> "$GPU_ERR"
code=$?
set -u
expect_code 2 "$code" "CUDA refusal is an actionable error"
assert_contains "$(cat "$GPU_ERR")" "CUDA device requested but CUDA is unavailable" "CUDA refusal explains missing GPU"

python3 - "$OUTPUT_ONE" "$REGIONS_ONE" "$REQUEST_LOG" "$LOCAL_OUTPUT" "$LOCAL_REGIONS" "$STRUCTURAL_OUTPUT" "$STRUCTURAL_REGIONS" <<'PY' || fail "region plan assertions failed"
import json
import sys

output_path, region_path, request_path, local_output_path, local_region_path, structural_output_path, structural_region_path = sys.argv[1:]
with open(output_path, encoding="utf-8") as stream:
    graph = json.load(stream)
with open(region_path, encoding="utf-8") as stream:
    region_plan = json.load(stream)
with open(local_output_path, encoding="utf-8") as stream:
    local_graph = json.load(stream)
with open(local_region_path, encoding="utf-8") as stream:
    local_region_plan = json.load(stream)
with open(structural_output_path, encoding="utf-8") as stream:
    structural_graph = json.load(stream)
with open(structural_region_path, encoding="utf-8") as stream:
    structural_region_plan = json.load(stream)
with open(request_path, encoding="utf-8") as stream:
    requests = [json.loads(line) for line in stream if line.strip()]
assert len(requests) == 2, requests
for request in requests:
    assert request["model"] == "test-embedding-model"
    assert len(request["input"]) == 3
    fingerprints = [json.loads(value) for value in request["input"]]
    assert fingerprints[0]["label"] == "User"
    assert fingerprints[0]["source_path"] == "src/user.py"
    assert fingerprints[0]["relation_types"] == ["declares"]
    assert fingerprints[0]["neighbor_labels"] == [
        {"direction": "out", "label": "Account", "relation": "declares"}
    ]

semantic = [edge for edge in graph["edges"] if edge.get("type") == "semantically_similar_to"]
assert len(semantic) == 2, semantic
assert all(edge["relation"] == "semantically_similar_to" for edge in semantic)
assert all(edge["similarity"] >= 0.8 for edge in semantic)
assert all(sum(edge["source"] == node_id for edge in semantic) <= 1 for node_id in ("user", "account", "invoice"))
assert any(edge == {"source": "user", "target": "account", "type": "declares"} for edge in graph["edges"])
assert any(
    edge
    == {
        "source": "claude_mods_firstmate_calm_hooks_register",
        "target": "user",
        "type": "references",
    }
    for edge in graph["edges"]
)
assert any(
    edge
    == {"source": "account", "target": "ref_claude_code", "type": "references"}
    for edge in graph["edges"]
)
cluster_ids = {node["semantic_cluster_id"] for node in graph["nodes"]}
assert len(cluster_ids) == 2, cluster_ids
assert graph["nodes"][0]["semantic_cluster_id"] == graph["nodes"][1]["semantic_cluster_id"]
assert graph["nodes"][0]["semantic_cluster_id"] != graph["nodes"][2]["semantic_cluster_id"]
assert region_plan["schema"] == "graphify-region-plan/v1"
clusters = {tuple(cluster["node_ids"]): cluster for cluster in region_plan["clusters"]}
assert set(clusters) == {("account", "user"), ("invoice",)}
assert clusters[("account", "user")]["source_paths"] == [
    "src/account.py",
    "src/user.py",
]
assert clusters[("account", "user")]["relation_summary"] == [
    {"relation": "declares", "edge_count": 1},
    {"relation": "references", "edge_count": 1},
]
assert clusters[("invoice",)]["relation_summary"] == [
    {"relation": "references", "edge_count": 1}
]
representatives = clusters[("account", "user")]["representative_nodes"]
assert [node["node_id"] for node in representatives] == ["account", "user"]
assert all(len(node["neighbors"]) <= 12 for node in representatives)
assert region_plan["cross_region_links"] == [
    {
        "source_cluster_id": clusters[("account", "user")]["cluster_id"],
        "target_cluster_id": clusters[("invoice",)]["cluster_id"],
        "relation": "references",
        "edge_count": 1,
        "examples": [{"source_node_id": "account", "target_node_id": "invoice"}],
    }
]
local_semantic = [
    edge for edge in local_graph["edges"] if edge.get("type") == "semantically_similar_to"
]
assert len(local_semantic) == 2, local_semantic
assert local_region_plan["schema"] == "graphify-region-plan/v1"
assert not [
    edge for edge in structural_graph["edges"]
    if edge.get("type") == "semantically_similar_to"
]
assert all("structural_region_id" in node for node in structural_graph["nodes"])
assert structural_region_plan["strategy"] == "structural_ast"
assert len(structural_region_plan["clusters"]) == 1
assert structural_region_plan["clusters"][0]["node_ids"] == [
    "account",
    "invoice",
    "user",
]
assert any(
    edge["source"] == "claude_mods_firstmate_calm_hooks_register"
    for edge in structural_graph["edges"]
)
PY
combined_output=$(cat "$STDOUT_FILE" "$STDERR_FILE" "$REQUEST_LOG")
case "$combined_output" in
  *"$KEY"*) fail "credential is absent from CLI output and request body" ;;
esac


pass "fake OpenAI, local CUDA, and structural AST backends preserve graph regions and secrets"

set +e
env -u OPENAI_API_KEY -u GRAPHIFY_EMBEDDINGS_ENDPOINT -u GRAPHIFY_EMBEDDINGS_MODEL \
  "$TOOL" --input "$INPUT" --output "$TMP_ROOT/no-provider.json" \
  --threshold 0.8 --top-k 1 > /dev/null 2> "$NO_PROVIDER_ERR"
code=$?
set -u
expect_code 2 "$code" "missing provider is rejected"
assert_contains "$(cat "$NO_PROVIDER_ERR")" 'no embedding provider configured' "missing provider explains configuration"
assert_contains "$(cat "$NO_PROVIDER_ERR")" '--endpoint' "missing provider names the endpoint option"
pass "missing provider reports an actionable error"
