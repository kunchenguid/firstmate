#!/usr/bin/env bash
# Exercise the public codebase-search command through its CLI contract.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codebase-search.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/src" "$TMP_ROOT/node_modules" "$TMP_ROOT/build" "$TMP_ROOT/.git"
printf 'needle one\nneedle two\nother\n' > "$TMP_ROOT/src/app.txt"
printf 'needle vendor\n' > "$TMP_ROOT/node_modules/dependency.txt"
printf 'needle build\n' > "$TMP_ROOT/build/generated.txt"
printf 'password=needle\n' > "$TMP_ROOT/.env.local"
printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'needle' > "$TMP_ROOT/signing.pem"

help=$("$ROOT/bin/codebase-search" --help)
[[ "$help" == *"files"* && "$help" == *"search"* && "$help" == *"context"* && "$help" == *"metrics"* ]] \
  || { echo "help does not list all subcommands" >&2; exit 1; }

invalid=$("$ROOT/bin/codebase-search" unknown 2>/dev/null || true)
INVALID_JSON=$invalid python3 - <<'PY'
import json, os
data = json.loads(os.environ["INVALID_JSON"])
assert data["status"] == "error"
assert data["error"] == "invalid_command"
PY

mkdir "$TMP_ROOT/no-tools"
missing_rg=$(PATH="$TMP_ROOT/no-tools" /usr/bin/python3 "$ROOT/bin/codebase-search" files --root "$TMP_ROOT" 2>/dev/null || true)
MISSING_RG_JSON=$missing_rg python3 - <<'PY'
import json, os
data = json.loads(os.environ["MISSING_RG_JSON"])
assert data["status"] == "error"
assert data["error"] == "ripgrep_unavailable"
PY

bounded=$("$ROOT/bin/codebase-search" search needle --root "$TMP_ROOT" --max-results 1)
BOUND_JSON=$bounded python3 - <<'PY'
import json, os
data = json.loads(os.environ["BOUND_JSON"])
assert data["status"] == "ok"
assert data["bounded"] is True
assert len(data["matches"]) == 1
assert data["matches"][0]["path"] == "src/app.txt"
assert data["matches"][0]["line"] == 1
PY

empty=$("$ROOT/bin/codebase-search" search absent --root "$TMP_ROOT")
EMPTY_JSON=$empty python3 - <<'PY'
import json, os
data = json.loads(os.environ["EMPTY_JSON"])
assert data == {"status": "ok", "command": "search", "matches": [], "count": 0, "bounded": True}
PY

if "$ROOT/bin/codebase-search" search needle --root "$TMP_ROOT/missing" >/dev/null 2>&1; then
  echo "missing root unexpectedly succeeded" >&2
  exit 1
fi
error=$(
  "$ROOT/bin/codebase-search" search needle --root "$TMP_ROOT/missing" 2>/dev/null || true
)
ERROR_JSON=$error python3 - <<'PY'
import json, os
data = json.loads(os.environ["ERROR_JSON"])
assert data["status"] == "error"
assert data["error"] == "invalid_root"
PY

safe=$("$ROOT/bin/codebase-search" search needle --root "$TMP_ROOT" --all)
SAFE_JSON=$safe python3 - <<'PY'
import json, os
data = json.loads(os.environ["SAFE_JSON"])
paths = {item["path"] for item in data["matches"]}
assert "src/app.txt" in paths
assert "node_modules/dependency.txt" in paths
assert "build/generated.txt" in paths
assert ".env.local" in paths
assert "signing.pem" in paths
PY

context=$("$ROOT/bin/codebase-search" context needle --root "$TMP_ROOT" --before 1 --after 1)
CONTEXT_JSON=$context python3 - <<'PY'
import json, os
data = json.loads(os.environ["CONTEXT_JSON"])
assert data["status"] == "ok"
assert data["matches"][0]["before"] == []
assert data["matches"][0]["after"] == ["needle two"]
PY

files=$("$ROOT/bin/codebase-search" files --root "$TMP_ROOT")
FILES_JSON=$files python3 - <<'PY'
import json, os
data = json.loads(os.environ["FILES_JSON"])
assert data["status"] == "ok"
assert "src/app.txt" in data["files"]
assert "node_modules/dependency.txt" not in data["files"]
PY

metrics=$("$ROOT/bin/codebase-search" metrics --root "$TMP_ROOT")
METRICS_JSON=$metrics python3 - <<'PY'
import json, os
data = json.loads(os.environ["METRICS_JSON"])
assert data["status"] == "ok"
assert data["files"] >= 1
assert data["bytes"] > 0
assert data["lines"] >= 1
PY

echo "ok - codebase-search public CLI"
