#!/usr/bin/env bash
# Backend-neutral Firstmate task executor dispatch.
#
# Usage:
#   fm-task-dispatch.sh local-agent <task-id> [fm-spawn arguments...]
#   fm-task-dispatch.sh cloud-worker/aime <task-id> --instructions <private-file> [--document]
#
# This is the narrow executor seam above local harness/runtime semantics.
# `local-agent` delegates byte-for-byte argument ownership to fm-spawn.sh, which
# retains its existing isolated-worktree guarantee and all harness/backend
# validation.
# `cloud-worker/aime` delegates to the AIME task record and never creates a
# worktree, terminal endpoint, harness, or runtime-backend record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

executor=${1-}
id=${2-}
[ -n "$executor" ] && [ -n "$id" ] || usage
shift 2

case "$executor" in
  local-agent)
    exec "$SCRIPT_DIR/fm-spawn.sh" "$id" "$@"
    ;;
  cloud-worker/aime)
    exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" dispatch "$id" "$@"
    ;;
  *)
    printf 'error: unsupported task executor: %s\n' "$executor" >&2
    exit 1
    ;;
esac
