#!/usr/bin/env bash
set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$TEST_ROOT/.no-mistakes/jev-safety-tests"
TMPDIR="$TEST_ROOT/.no-mistakes/jev-safety-tests"
export TMPDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-safety-gate)

GUARD="$ROOT/.claude/jev-safety/check.py"
PROJECT="$ROOT/.claude/jev-safety"
UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/secret.json"
{"content":"test token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
JSON
if ! grep -q '"reason":"secret"' "$TMP_ROOT/secret.json"; then
  fail "detect-secrets did not block a synthetic GitHub token"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/path.json"
{"paths":["data/captain.md"],"content":"plain non-secret fixture text"}
JSON
if ! grep -q '"reason":"sensitive_path"' "$TMP_ROOT/path.json"; then
  fail "sensitive path was not blocked independently of the secret scanner"
fi

# Allocate dynamic port for test isolation
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')
export JEV_SAFETY_PORT="$PORT"

# Launch server directly with direct python binary and track its PID
"$PROJECT/.venv/bin/python" "$ROOT/.claude/jev-safety/server.py" --serve &
SRV_PID=$!
cleanup() {
  if [ -n "${SRV_PID:-}" ]; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Test server readiness and health endpoint
ready=0
for _ in $(seq 1 50); do
  health_resp=$(curl -s "http://127.0.0.1:$JEV_SAFETY_PORT/health" || true)
  if echo "$health_resp" | grep -q '"service":"firstmate-jev-safety"'; then
    ready=1
    break
  fi
  sleep 0.05
done
if [ "$ready" -ne 1 ]; then
  fail "safety server health check did not return expected service signature on port $JEV_SAFETY_PORT"
fi

# Test ensure() idempotency when server is already healthy
"$PROJECT/.venv/bin/python" "$ROOT/.claude/jev-safety/server.py"

# Test oversized payload rejection
large_file="$TMP_ROOT/large.txt"
python3 -c "print('a' * 4000001, end='')" > "$large_file"
oversized_resp=$(curl -s -X POST "http://127.0.0.1:$JEV_SAFETY_PORT/check" --data-binary @"$large_file" -H "Content-Type: application/json" || true)
if ! echo "$oversized_resp" | grep -q '"reason":"payload_too_large"'; then
  fail "safety server did not reject payload exceeding 4MB limit"
fi

# Verify clean server shutdown
kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
if kill -0 "$SRV_PID" 2>/dev/null; then
  fail "server process $SRV_PID did not terminate after shutdown"
fi
SRV_PID=""

# Test missing venv fail-closed behavior
empty_dir="$TMP_ROOT/novenv"
mkdir -p "$empty_dir/.claude/jev-safety"
cp "$ROOT/.claude/jev-safety/server.py" "$empty_dir/.claude/jev-safety/"
if python3 "$empty_dir/.claude/jev-safety/server.py" 2>/dev/null; then
  fail "server.py did not fail closed when .venv was missing"
fi

pass "jev outbound gate blocks synthetic secrets, excluded paths, and oversized bodies with isolated port and verified cleanup"
node --experimental-strip-types --test "$ROOT/tests/fm-jev-hook-guards.test.mjs"
