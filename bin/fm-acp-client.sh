#!/usr/bin/env bash
# ACPX lifecycle client for the opt-in Claude and Codex worker transport.
#
# Usage: fm-acp-client.sh <ensure|run|send|status|cancel> <claude|codex>
#        <worktree> <session-id> [brief-or-message] [model] [effort]
#
# The full ACP transport wire contract lives here so spawn, status, and send
# share one exact package pin and one session identity.  `session-id` is the
# stable ACPX named-session selector stored in state/<id>.meta.  `ensure`
# creates (or reconnects to) that record, `run` starts/resumes the worker's
# initial brief and keeps its queue owner alive, `send` queues a follow-up,
# `status` prints ACPX's JSON snapshot, and `cancel` sends ACP session/cancel.
#
# ACPX 0.13.2 was the POC-proven client.  Its built-in adapter ranges are not
# used because ranges could silently change worker behavior; each command
# instead supplies the POC-proven exact adapter package for its harness.
set -eu

ACPX_VERSION=0.13.2
CLAUDE_ADAPTER=@agentclientprotocol/claude-agent-acp@0.75.1
CODEX_ADAPTER=@agentclientprotocol/codex-acp@1.10.0

usage() {
  echo "usage: fm-acp-client.sh <ensure|run|send|status|cancel> <claude|codex> <worktree> <session-id> [brief-or-message] [model] [effort]" >&2
  exit 2
}

action=${1:-}
harness=${2:-}
worktree=${3:-}
session_id=${4:-}
payload=${5:-}
model=${6:-}
effort=${7:-}
[ -n "$action" ] && [ -n "$harness" ] && [ -n "$worktree" ] && [ -n "$session_id" ] || usage

case "$harness" in
  claude) adapter=$CLAUDE_ADAPTER ;;
  codex) adapter=$CODEX_ADAPTER ;;
  *) echo "error: ACP transport supports only claude or codex (got '$harness')" >&2; exit 2 ;;
esac
[ -d "$worktree" ] || { echo "error: ACP worktree is missing: $worktree" >&2; exit 1; }
command -v acpx >/dev/null 2>&1 || { echo "error: ACP transport requires acpx@$ACPX_VERSION on PATH" >&2; exit 1; }
installed=$(acpx --version 2>/dev/null || true)
[ "$installed" = "$ACPX_VERSION" ] || {
  echo "error: ACP transport requires acpx@$ACPX_VERSION, found ${installed:-missing}" >&2
  exit 1
}

# `--agent` pins the exact adapter rather than ACPX's mutable built-in range.
base=(acpx --agent "npx -y $adapter" --cwd "$worktree" --approve-all \
  --non-interactive-permissions fail --format json)
[ -z "$model" ] || [ "$model" = default ] || base+=(--model "$model")

case "$action" in
  ensure)
    exec "${base[@]}" sessions ensure --name "$session_id"
    ;;
  run)
    [ -n "$payload" ] || usage
    # A zero TTL leaves the queue owner available while the worker is idle,
    # which makes ACPX status and later resume/send calls use the same session.
    if [ -n "$effort" ] && [ "$effort" != default ]; then
      "${base[@]}" sessions ensure --name "$session_id" >/dev/null
      "${base[@]}" set reasoning_effort "$effort" -s "$session_id" >/dev/null
    fi
    exec "${base[@]}" --ttl 0 prompt -s "$session_id" --file "$payload"
    ;;
  send)
    [ -n "$payload" ] || usage
    # ACP can queue a follow-up at a turn boundary, but cannot inject raw keys
    # into an in-flight generation.  --no-wait returns once an active owner
    # durably accepts the queued request.
    printf '%s' "$payload" | "${base[@]}" prompt -s "$session_id" --no-wait --file -
    ;;
  status)
    exec "${base[@]}" status -s "$session_id"
    ;;
  cancel)
    exec "${base[@]}" cancel -s "$session_id"
    ;;
  *) usage ;;
esac
