#!/usr/bin/env bash
# bin/fm-decision-lib.sh — 4-Layer Memory & Decision Logging Engine Library
# Manages structured decision journals in state/<id>.decisions.jsonl preserving:
#   - timestamp
#   - task_id
#   - decision_key
#   - choice
#   - rationale
#   - rejected_options: array of { option, reason }
#   - discovered_constraints: array of strings
#   - outcome
set -eu

fm_decision_file() { # <state_dir> <task_id>
  local state=$1 task=$2
  printf '%s/%s.decisions.jsonl' "$state" "$task"
}

# Append a structured decision record to state/<id>.decisions.jsonl
fm_decision_log() { # <state_dir> <task_id> <choice> <rationale> <rejected_json> <constraints_json> <outcome> [<decision_key>]
  local state=$1 task=$2 choice=$3 rationale=$4 rejected_json=${5:-"[]"} constraints_json=${6:-"[]"} outcome=${7:-""} key=${8:-""}
  local file
  file=$(fm_decision_file "$state" "$task")
  mkdir -p "$state" 2>/dev/null || true

  if [ -z "$key" ]; then
    key="dec-$(date +%s%N 2>/dev/null || date +%s)"
  fi

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Generate clean JSON using python3 or node
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$state" "$task" "$choice" "$rationale" "$rejected_json" "$constraints_json" "$outcome" "$key" "$ts" "$file" <<'PY'
import sys, json
state, task, choice, rationale, rejected_raw, constr_raw, outcome, key, ts, outfile = sys.argv[1:]
try:
    rejected = json.loads(rejected_raw)
except Exception:
    rejected = [{"option": rejected_raw, "reason": "Alternative rejected"}]
try:
    constraints = json.loads(constr_raw)
except Exception:
    constraints = [constr_raw] if constr_raw else []

record = {
    "timestamp": ts,
    "task_id": task,
    "decision_key": key,
    "choice": choice,
    "rationale": rationale,
    "rejected_options": rejected,
    "discovered_constraints": constraints,
    "outcome": outcome
}
with open(outfile, "a", encoding="utf-8") as f:
    f.write(json.dumps(record) + "\n")
PY
  else
    # Minimal fallback
    printf '{"timestamp":"%s","task_id":"%s","decision_key":"%s","choice":"%s","rationale":"%s","rejected_options":%s,"discovered_constraints":%s,"outcome":"%s"}\n' \
      "$ts" "$task" "$key" "$choice" "$rationale" "$rejected_json" "$constraints_json" "$outcome" >> "$file"
  fi
}

# List all decisions recorded for a task
fm_decision_list() { # <state_dir> <task_id>
  local state=$1 task=$2 file
  file=$(fm_decision_file "$state" "$task")
  [ -f "$file" ] || return 0

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import sys, json
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            ts = d.get("timestamp", "")
            key = d.get("decision_key", "")
            choice = d.get("choice", "")
            print(f"[{ts}] Key: {key} | Choice: {choice}")
        except Exception:
            pass
PY
  else
    cat "$file"
  fi
}

# Show specific decision key details
fm_decision_get() { # <state_dir> <task_id> <decision_key>
  local state=$1 task=$2 key=$3 file
  file=$(fm_decision_file "$state" "$task")
  [ -f "$file" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY'
import sys, json
target_key = sys.argv[2]
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            if d.get("decision_key") == target_key:
                print(json.dumps(d, indent=2))
                sys.exit(0)
        except Exception:
            pass
sys.exit(1)
PY
  else
    grep "\"decision_key\":\"$key\"" "$file" || grep "\"decision_key\": \"$key\"" "$file"
  fi
}
