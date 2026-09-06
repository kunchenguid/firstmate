#!/usr/bin/env bash
# Probe the effective model for a task from runtime/session metadata only.
# Prints: model=<id-or-empty> source=<probe-source>
# Exits 0 when a candidate was read (even if not exact); 1 when nothing found.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-model-lib.sh
. "$SCRIPT_DIR/fm-model-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-model-probe.sh <state-dir> <task-id> [herdr-pane-id]
EOF
  exit 2
}

STATE=${1:-}
ID=${2:-}
PANE=${3:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for $ID" >&2; exit 1; }

HARNESS=$(fm_model_meta_get "$META" harness)
[ -z "$PANE" ] && PANE=$(fm_model_meta_get "$META" herdr_pane_id)

probe_claude_jsonl() {  # <session-id>
  local sid=$1 file model
  [ -n "$sid" ] || return 1
  file=$(find "${HOME:-/home/vsole}/.claude/projects" -name "${sid}.jsonl" 2>/dev/null | head -1)
  [ -n "$file" ] && [ -f "$file" ] || return 1
  model=$(python3 - "$file" <<'PY'
import json, sys
path = sys.argv[1]
last = ""
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = obj.get("message")
        if isinstance(msg, dict) and msg.get("role") == "assistant":
            m = msg.get("model")
            if isinstance(m, str) and m:
                last = m
        elif obj.get("type") == "assistant":
            msg = obj.get("message") or obj
            if isinstance(msg, dict):
                m = msg.get("model")
                if isinstance(m, str) and m:
                    last = m
print(last)
PY
) || return 1
  [ -n "$model" ] || return 1
  printf 'model=%s\nsource=claude-transcript\n' "$model"
  return 0
}

probe_pi_jsonl() {  # <session-path>
  local path=$1 model
  [ -n "$path" ] && [ -f "$path" ] || return 1
  model=$(python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
last = ""
provider = ""
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = obj.get("message")
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        m = msg.get("model")
        p = msg.get("provider")
        if isinstance(p, str) and p:
            provider = p
        if isinstance(m, str) and m:
            if "/" in m:
                last = m
            elif provider and "/" not in m and "-" not in m:
                last = f"{provider}/{m}"
            else:
                last = m
print(last)
PY
) || return 1
  [ -n "$model" ] || return 1
  printf 'model=%s\nsource=pi-transcript\n' "$model"
  return 0
}

probe_herdr_agent_session() {
  local pane_json kind value
  [ -n "$PANE" ] || return 1
  command -v herdr >/dev/null 2>&1 || return 1
  pane_json=$(herdr pane get "$PANE" 2>/dev/null) || return 1
  kind=$(printf '%s' "$pane_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('result',{}).get('pane',{}) or {}).get('agent_session',{}).get('kind',''))" 2>/dev/null) || return 1
  value=$(printf '%s' "$pane_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print((d.get('result',{}).get('pane',{}) or {}).get('agent_session',{}).get('value',''))" 2>/dev/null) || return 1
  [ -n "$value" ] || return 1
  case "$kind" in
    id) probe_claude_jsonl "$value" ;;
    path) probe_pi_jsonl "$value" ;;
    *) return 1 ;;
  esac
}

if probe_herdr_agent_session; then
  exit 0
fi

exit 1
