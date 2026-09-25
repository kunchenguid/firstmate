#!/usr/bin/env bash
set -u

TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$TEST_ROOT/.no-mistakes/jev-safety-tests"
TMPDIR="$TEST_ROOT/.no-mistakes/jev-safety-tests"
export TMPDIR
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-safety-gate)

assert_verdict() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as verdict_file:
    verdict = json.load(verdict_file)
expected = sys.argv[2]
assert verdict["allowed"] is (expected == "clean"), verdict
assert verdict["reason"] == expected, verdict
PY
}

GUARD="$ROOT/.claude/jev-safety/check.py"
PROJECT="$ROOT/.claude/jev-safety"
python3 - "$ROOT/.claude/settings.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as settings_file:
    settings = json.load(settings_file)
assert "jev" in settings.get("disabledMcpjsonServers", []), settings
assert settings.get("enabledPlugins", {}).get("jev-safe@firstmate-jev") is False, settings
PY
UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/secret.json"
{"content":"test token ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
JSON
if ! assert_verdict "$TMP_ROOT/secret.json" secret; then
  fail "detect-secrets did not block a synthetic GitHub token"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/path.json"
{"paths":["data/captain.md"],"content":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/path.json" sensitive_path; then
  fail "sensitive path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/learnings.json"
{"paths":["data/learnings.md"],"content":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/learnings.json" sensitive_path; then
  fail "home-local learnings path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/backlog.json"
{"paths":["data/backlog.md"],"content":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/backlog.json" sensitive_path; then
  fail "backlog path was not blocked independently of the secret scanner"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-cwd.json"
{"tool_name":"Bash","tool_input":{"command":"cat pipelines/health/patient.txt > /tmp/result.txt"},"tool_response":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/bash-cwd.json" sensitive_path; then
  fail "sensitive Bash path and redirection target were not blocked"
fi

for path in data/captain.md .env state/private.txt config/private.txt pipelines/health/patient.txt; do
  python3 - "$path" > "$TMP_ROOT/bash-embedded.json" <<'PY'
import json
import sys

path = sys.argv[1]
command = f"python -c 'print(open({json.dumps(path)}).read())'"
print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": command},
    "tool_response": "plain non-secret fixture text",
}))
PY
  UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" \
    < "$TMP_ROOT/bash-embedded.json" > "$TMP_ROOT/bash-embedded-verdict.json"
  if ! assert_verdict "$TMP_ROOT/bash-embedded-verdict.json" sensitive_path; then
    fail "embedded Bash read of $path was not blocked"
  fi
done

python3 - > "$TMP_ROOT/bash-split-path.json" <<'PY'
import json

print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {
        "command": "python -c 'print(open(\"data/\" + \"captain.md\").read())'"
    },
    "tool_response": "plain private fixture text",
}))
PY
UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" \
  < "$TMP_ROOT/bash-split-path.json" > "$TMP_ROOT/bash-split-path-verdict.json"
if ! assert_verdict "$TMP_ROOT/bash-split-path-verdict.json" sensitive_path; then
  fail "Bash path assembled from separate literals was not blocked"
fi

python3 - > "$TMP_ROOT/bash-fragmented-path.json" <<'PY'
import json

print(json.dumps({
    "tool_name": "Bash",
    "tool_input": {
        "command": "python -c 'print(open(\"data/cap\" + \"tain.md\").read())'"
    },
    "tool_response": "plain private fixture text",
}))
PY
UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" \
  < "$TMP_ROOT/bash-fragmented-path.json" > "$TMP_ROOT/bash-fragmented-path-verdict.json"
if ! assert_verdict "$TMP_ROOT/bash-fragmented-path-verdict.json" sensitive_path; then
  fail "Bash path assembled from partial basename literals was not blocked"
fi

for directory in state config; do
  UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<JSON > "$TMP_ROOT/bash-$directory.json"
{"tool_name":"Bash","tool_input":{"command":"ls $directory"},"tool_response":"plain non-secret fixture text"}
JSON
  if ! assert_verdict "$TMP_ROOT/bash-$directory.json" sensitive_path; then
    fail "direct Bash argument for $directory was not blocked"
  fi
done

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-cwd-residual.json"
{"tool_name":"Bash","tool_input":{"command":"cd state && cat private.txt"},"tool_response":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/bash-cwd-residual.json" sensitive_path; then
  fail "unresolved Bash directory context was not blocked"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/bash-harmless-prose.json"
{"tool_name":"Bash","tool_input":{"command":"printf 'state and config'"},"tool_response":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/bash-harmless-prose.json" clean; then
  fail "harmless Bash output mentioning sensitive directory names was blocked"
fi

for directory in state config pipelines/health pipelines/health-manager pipelines/health-connect-sync pipelines/finance; do
  UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<JSON > "$TMP_ROOT/bash-cd.json"
{"tool_name":"Bash","tool_input":{"command":"cd $directory && cat private.txt"},"tool_response":"plain non-secret fixture text"}
JSON
  if ! assert_verdict "$TMP_ROOT/bash-cd.json" sensitive_path; then
    fail "Bash directory change into $directory was not blocked"
  fi
done

# shellcheck disable=SC2016 # These literal commands intentionally preserve shell expansion syntax for the guard.
# shellcheck disable=SC2016
for command in 'cd $TARGET && cat README.md' 'cd $(pwd) && cat README.md' 'cd .. && cat README.md' 'cd - && cat README.md'; do
  COMMAND="$command"
  UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<JSON > "$TMP_ROOT/bash-cd-unresolved.json"
{"tool_name":"Bash","tool_input":{"command":"$COMMAND"},"tool_response":"plain non-secret fixture text"}
JSON
  if ! assert_verdict "$TMP_ROOT/bash-cd-unresolved.json" sensitive_path; then
    fail "unresolved Bash directory target was not blocked: $command"
  fi
done

COMMAND='cd docs && cat README.md'
UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<JSON > "$TMP_ROOT/bash-cd-safe.json"
{"tool_name":"Bash","tool_input":{"command":"$COMMAND"},"tool_response":"plain non-secret fixture text"}
JSON
if ! assert_verdict "$TMP_ROOT/bash-cd-safe.json" clean; then
  fail "safe literal Bash directory target was blocked"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/result-path.json"
{"tool_response":{"content":"Read from /workspace/state/private.txt: clean fixture data"}}
JSON
if ! assert_verdict "$TMP_ROOT/result-path.json" sensitive_path; then
  fail "sensitive source path in the post-execution result was not blocked"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/prose.json"
{"content":"The state and config contain health settings."}
JSON
if ! assert_verdict "$TMP_ROOT/prose.json" clean; then
  fail "ordinary prose was blocked as a sensitive basename"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/record.json.json"
{"content":"record.json is an ordinary artifact name."}
JSON
if ! assert_verdict "$TMP_ROOT/record.json.json" clean; then
  fail "ordinary record.json filename was blocked"
fi

UV_CACHE_DIR="$PROJECT/.uv-cache" uv run --project "$PROJECT" --quiet python "$GUARD" <<'JSON' > "$TMP_ROOT/health.json"
{"messages":[{"role":"user","content":"I have diabetes and use insulin."}]}
JSON
if ! assert_verdict "$TMP_ROOT/health.json" health_data; then
  fail "common health data was not blocked independently of secret scanning"
fi

if CLAUDE_PROJECT_DIR="$TMP_ROOT/uninitialized" bash "$ROOT/bin/fm-jev-sessionstart.sh" \
  > "$TMP_ROOT/sessionstart-missing-winnow.txt" 2>&1; then
  fail "session start accepted a missing Winnow submodule"
fi
if ! grep -Fq 'git submodule update --init .claude/upstreams/winnow' \
  "$TMP_ROOT/sessionstart-missing-winnow.txt"; then
  fail "session start did not explain how to initialize Winnow"
fi
node --experimental-strip-types --test "$ROOT/tests/fm-jev-hook-guards.test.mjs"
pass "jev outbound gate blocks secrets, private paths, and health text"
