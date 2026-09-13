#!/usr/bin/env bash
# fm-bridge-snapshot.sh - read-only fleet bridge snapshot for terminal consoles.
#
# Usage:
#   fm-bridge-snapshot.sh --json [--no-network]
#   fm-bridge-snapshot.sh --help
#
# Output contract: `--json` prints one object with schema
# `fm-bridge-snapshot.v1`.
# It combines the canonical fleet snapshot, quota-axi, per-worktree
# no-mistakes status, recent Claude/Codex session logs, unrecorded harness
# processes, and an optional upstream check.
#
# Read-only boundary:
#   - Does not acquire the session lock, drain wakes, arm watchers, or write
#     firstmate data/state/config.
#   - Each external source is bounded independently and is recorded in
#     top-level `sources`; one failing source leaves the rest of the snapshot
#     usable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  fm-bridge-snapshot.sh --json [--no-network]
  fm-bridge-snapshot.sh --help

Options:
  --json        Print the fm-bridge-snapshot.v1 JSON object
  --no-network  Skip the upstream sync check
  --help        Show this help
EOF
}

json=false
no_network=false
while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      json=true
      shift
      ;;
    --no-network)
      no_network=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'fm-bridge-snapshot: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$json" != true ]; then
  usage >&2
  exit 2
fi

args=(--json)
if [ "$no_network" = true ]; then
  args+=(--no-network)
fi

exec python3 "$SCRIPT_DIR/fm_bridge_snapshot.py" "${args[@]}"
