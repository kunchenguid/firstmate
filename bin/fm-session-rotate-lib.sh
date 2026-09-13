#!/usr/bin/env bash
# bin/fm-session-rotate-lib.sh — Context Watermarks & Automated Session Rotation Library
# Tracks session context token watermarks (default 80,000 tokens threshold),
# generates structured state/<id>.handoff.md markdown summaries,
# and supports seamless agent relaunch.
set -eu

FM_SESSION_ROTATE_DEFAULT_THRESHOLD=80000

fm_estimate_tokens_from_file() { # <file_path>
  local path=$1
  [ -f "$path" ] || { echo "0"; return 0; }
  local bytes
  bytes=$(wc -c < "$path" | tr -d '[:space:]')
  # Rule of thumb: ~3.5 chars / 1 token or ceil(bytes / 3)
  local tokens=$((bytes / 3))
  [ $((bytes % 3)) -ne 0 ] && tokens=$((tokens + 1))
  echo "$tokens"
}

fm_session_estimate_task_tokens() { # <state_dir> <task_id>
  local state=$1 task=$2
  local total=0

  # Count status file
  if [ -f "$state/$task.status" ]; then
    local t
    t=$(fm_estimate_tokens_from_file "$state/$task.status")
    total=$((total + t))
  fi

  # Count inbox messages. Do not count state/tool-outputs: those files exist
  # so the live context does *not* carry the payload.
  if [ -d "$state/$task.inbox" ]; then
    for f in "$state/$task.inbox"/*.msg; do
      if [ -f "$f" ]; then
        local t
        t=$(fm_estimate_tokens_from_file "$f")
        total=$((total + t))
      fi
    done
  fi

  echo "$total"
}

fm_session_generate_handoff() { # <state_dir> <data_dir> <task_id> <worktree_path> <summary> <next_steps>
  local state=$1 data=$2 task=$3 wt=$4 summary=${5:-"Automated session rotation handoff"} next_steps=${6:-"Continue execution from brief"}
  local handoff_file="$state/$task.handoff.md"
  mkdir -p "$state" 2>/dev/null || true

  local git_summary="No git repository found"
  local git_diff="None"
  local git_log="None"
  if [ -n "$wt" ] && [ -d "$wt/.git" ]; then
    git_summary=$(git -C "$wt" status --short 2>/dev/null || echo "clean")
    git_log=$(git -C "$wt" log -n 5 --oneline 2>/dev/null || echo "no commits")
    git_diff=$(git -C "$wt" diff --stat HEAD 2>/dev/null || echo "no diff")
  fi

  local decisions_text="No decisions recorded yet."
  local dec_file="$state/$task.decisions.jsonl"
  if [ -f "$dec_file" ]; then
    decisions_text=$(python3 - "$dec_file" <<'PY'
import sys, json
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            d = json.loads(line)
            key = d.get("decision_key", "")
            choice = d.get("choice", "")
            rat = d.get("rationale", "")
            out = d.get("outcome", "")
            print(f"- **Decision [{key}]**: {choice}")
            print(f"  - *Rationale*: {rat}")
            if out:
                print(f"  - *Outcome*: {out}")
        except Exception:
            pass
PY
)
  fi

  cat > "$handoff_file" <<EOF
# Session Rotation Handoff
**Task**: $task
**Generated**: $(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

## 1. Summary of Completed Progress
$summary

## 2. Recent Commits & Working Tree State
### Recent Commits:
\`\`\`
$git_log
\`\`\`

### Status & Changes:
\`\`\`
$git_summary
\`\`\`
$git_diff

## 3. Key Decisions & Discovered Constraints
$decisions_text

## 4. Immediate Next Steps
$next_steps

---
*Instructions for replacement session: Read this handoff and data/$task/brief.md. Do not repeat already completed analysis or unroll committed changes.*
EOF

  echo "$handoff_file"
}
