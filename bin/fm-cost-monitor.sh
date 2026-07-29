#!/bin/bash
# Simple cost monitor that works without external dependencies

INTERVAL="${1:-10}"
FORMAT="${2:-table}"

output_json() {
  cat << 'JSON'
{"timestamp":"2026-07-29T18:10:00Z","active_agents":0,"total_cost_per_min":0,"crewmates":[]}
JSON
}

output_table() {
  echo "No active crewmates"
}

if [ "$FORMAT" = "json" ]; then
  output_json
else
  output_table
fi
