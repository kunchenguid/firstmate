#!/bin/bash
# fm-backlog-with-costs.sh - Display backlog items with task costs
# Wraps backlog display to inject cost per agent from fm-format-task-cost.sh

set -euo pipefail

BACKLOG_FILE="${1:-data/backlog.md}"
STATE_DIR="${2:-state}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$BACKLOG_FILE" ]; then
  echo "Backlog not found: $BACKLOG_FILE"
  exit 1
fi

# Read and format backlog with costs
awk -v state_dir="$STATE_DIR" -v script_dir="$SCRIPT_DIR" '
  /^##[[:space:]]+/ {
    print $0
    next
  }
  /^[-*][[:space:]]+/ {
    line = $0
    # Extract taskid (fm-xxx-xxx pattern)
    if (match(line, /fm-[a-z0-9-]+/)) {
      taskid = substr(line, RSTART, RLENGTH)
      metafile = state_dir "/" taskid ".meta"
      
      # Try to get cost
      cmd = script_dir "/fm-format-task-cost.sh " taskid
      if ((cmd | getline cost) > 0) {
        # Append cost to end of line (before any trailing whitespace)
        sub(/[[:space:]]*$/, "", line)
        line = line " " cost
      }
      close(cmd)
    }
    print line
    next
  }
  {
    print $0
  }
' "$BACKLOG_FILE"
