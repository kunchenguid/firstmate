#!/usr/bin/env bash
# Resolve and invoke an existing local Holusight CLI for worker startup evidence.
#
# Usage: fm-holusight.sh <project-root> <project-name> <launch-brief>
#        fm-holusight.sh benchmark <project-root> <project-name>
# Configuration is private FM_HOME/config/holusight.json.  It is default-on;
# projects may set enabled=false or enabled=true without touching application
# repositories.  This helper never installs, indexes, enables egress, or writes
# inside the project root.  Holusight owns its local usage-event schema.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-$FM_ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}

usage() {
  printf 'usage: %s <project-root> <project-name> <launch-brief>\n' "$0" >&2
  printf '       %s benchmark <project-root> <project-name>\n' "$0" >&2
}

if [ "${1:-}" = benchmark ]; then
  BENCHMARK=1
  shift
else
  BENCHMARK=0
fi
PROJECT_ROOT=${1:-}
PROJECT_NAME=${2:-}
BRIEF=${3:-}
[ -n "$PROJECT_ROOT" ] && [ -n "$PROJECT_NAME" ] || { usage; exit 2; }
if [ "$BENCHMARK" -eq 0 ] && [ -z "$BRIEF" ]; then usage; exit 2; fi

settings=$(python3 - "$CONFIG/holusight.json" "$PROJECT_NAME" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
name = sys.argv[2]
default = {
    "enabled": True,
    "question": "where is the requested behavior implemented?",
    "timeout_seconds": 2,
}
try:
    raw = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
except (OSError, ValueError):
    raw = {}
if not isinstance(raw, dict):
    raw = {}
project = raw.get("projects", {}).get(name, {})
if not isinstance(project, dict):
    project = {}
merged = dict(default)
if isinstance(raw.get("default"), dict):
    merged.update(raw["default"])
merged.update(project)
if not isinstance(merged.get("enabled"), bool):
    merged["enabled"] = True
question = merged.get("question", default["question"])
if not isinstance(question, str) or not question.strip() or any(c in question for c in "\r\n"):
    question = default["question"]
timeout = merged.get("timeout_seconds", default["timeout_seconds"])
try:
    timeout = max(0.1, min(float(timeout), 5.0))
except (TypeError, ValueError):
    timeout = default["timeout_seconds"]
print("enabled=" + ("1" if merged["enabled"] else "0"))
print("question=" + question)
print("timeout=" + str(timeout))
PY
) || settings=$'enabled=1\nquestion=where is the requested behavior implemented?\ntimeout=2'
enabled=$(printf '%s\n' "$settings" | sed -n 's/^enabled=//p' | head -n1)
question=$(printf '%s\n' "$settings" | sed -n 's/^question=//p' | head -n1)
timeout=$(printf '%s\n' "$settings" | sed -n 's/^timeout=//p' | head -n1)

if [ "$enabled" != 1 ]; then
  if [ "$BENCHMARK" -eq 1 ]; then
    printf '%s\n' '{"schema":"firstmate.holusight-benchmark.v1","enabled":false,"disabled_result":"not_used","enabled_result":"not_used","token_delta":"unknown","usability":"not_used"}'
  else
    printf '%s\n' '### Holusight startup evidence' 'not-used: disabled for this project; no application-repository writes'
  fi
  exit 0
fi

resolve_holus() {
  if [ -n "${HOLUS_EXECUTABLE:-}" ] && [ -x "$HOLUS_EXECUTABLE" ]; then
    printf '%s\n' "$HOLUS_EXECUTABLE"
  elif [ -x "$HOME/.local/bin/holus" ]; then
    printf '%s\n' "$HOME/.local/bin/holus"
  else
    command -v holus 2>/dev/null || true
  fi
}
HOLUS=$(resolve_holus)
if [ -z "$HOLUS" ]; then
  if [ "$BENCHMARK" -eq 1 ]; then
    printf '%s\n' '{"schema":"firstmate.holusight-benchmark.v1","enabled":true,"disabled_result":"not_used","enabled_result":"unavailable","token_delta":"unknown","usability":"unknown"}'
  else
    printf '%s\n' '### Holusight startup evidence' 'not-used: existing local holus executable not discoverable; no install or indexing attempted'
  fi
  exit 0
fi

started_ns=$(python3 - <<'PY'
import time
print(time.monotonic_ns())
PY
)
set +e
output=$(HOLUS_EGRESS=0 HOLUSIGHT_EGRESS=0 FLEET_HOLUSIGHT_EGRESS=0 \
  python3 - "$HOLUS" "$question" "$timeout" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "evidence", sys.argv[2], "--mode", "auto", "--fields",
         "evidence.source,evidence.location,coverage,providers_checked,egress",
         "--format", "toon"],
        capture_output=True, text=True, timeout=float(sys.argv[3]), check=False,
    )
except (OSError, subprocess.SubprocessError, ValueError):
    raise SystemExit(1)
print(result.stdout, end="")
raise SystemExit(result.returncode)
PY
)
code=$?
set -e
# Keep the launch overlay bounded even when a provider returns verbose metadata.
output=${output:0:8000}
finished_ns=$(python3 - <<'PY'
import time
print(time.monotonic_ns())
PY
)
elapsed_ms=$(( (finished_ns - started_ns) / 1000000 ))

if [ "$BENCHMARK" -eq 1 ]; then
  if [ "$code" -eq 0 ]; then result=used; else result=unavailable; fi
  printf '{"schema":"firstmate.holusight-benchmark.v1","enabled":true,"disabled_result":"not_used","enabled_result":"%s","enabled_elapsed_ms":%s,"token_delta":"unknown","usability":"unknown","egress":"not_allowed_by_firstmate"}\n' "$result" "$elapsed_ms"
  exit 0
fi
if [ "$code" -ne 0 ] || [ -z "$output" ]; then
  printf '%s\n' '### Holusight startup evidence' 'not-used: local Holusight invocation unavailable; no application-repository writes'
  exit 0
fi
printf '%s\n' '### Holusight startup evidence' 'used: local evidence lookup completed; egress=denied; usage trace owned by Holusight' \
  "elapsed_ms=$elapsed_ms"
printf '%s\n' "$output"
exit 0
