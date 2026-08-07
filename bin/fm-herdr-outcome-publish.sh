#!/usr/bin/env bash
# Publish a real work outcome firstmate has just learned (a PR merged, a
# validation failed, a task landed) into herdr, so the fleet sidebar can show
# it. Herdr cannot derive outcomes itself - every event it sees on its own is
# mechanical (a pane appeared, a process exited); only firstmate talks to
# GitHub with identity and intent, so only firstmate knows a PR merged or CI
# went red. See data/herdr-event-channel-research/report.md sections C and D
# for the design this follows; nothing here re-derives that reasoning.
#
# Two herdr CLI calls, matching report.md section D's "two calls, not one
# fused method" recommendation so the momentary and durable channels keep
# their deliberately different retention rules decoupled:
#   1. `herdr workspace report-signal`  - momentary, fire-and-forget, exactly
#      the four existing WorkspaceSignalKind values (transfer/completed/
#      failed/idle). Never widen this vocabulary here - map the caller's own
#      outcome onto one of the four; widening the herdr-side enum is a
#      separate, out-of-scope design decision (report.md section C.1).
#   2. `herdr workspace report-metadata` - durable, per-workspace token
#      ledger, written as outcome=<outcome> and (when given) summary=<summary>.
#
# The workspace targeted is resolved ONLY from the task's own
# state/<task-id>.meta (herdr_session=, herdr_workspace_id=, written by
# fm-spawn.sh when backend=herdr) - never a second identity scheme.
#
# This is a decoration, never a blocker: every unresolvable target (no task
# meta, a non-herdr task, no recorded herdr session/workspace, the herdr or
# jq tools missing, the CLI call itself failing) is a silent no-op that exits
# 0. A dropped report costs nothing - herdr's own report-signal and
# report-metadata already answer success on an unknown workspace or a stale
# sequence (report.md section C.1 live evidence). Callers may still append
# `|| true` for defense in depth, but this script never needs it to stay
# non-blocking on its own.
#
# A malformed call (wrong argument count, an outcome kind outside the four
# WorkspaceSignalKind values) is the one case treated as a caller bug: it
# prints a usage error and exits 2, so a broken call site is caught in
# testing rather than silently swallowed forever.
#
# Usage: fm-herdr-outcome-publish.sh <task-id> <signal-kind> <outcome> [summary]
#   <signal-kind>  one of: transfer completed failed idle
#   <outcome>      short durable token value, e.g. pr_merged, landed, failed
#   <summary>      optional short human-readable context
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# FM_HOME resolution, including the refusal on an ambiently inherited home,
# has one owner: bin/fm-home-anchor-lib.sh.
# shellcheck source=bin/fm-home-anchor-lib.sh
. "$SCRIPT_DIR/fm-home-anchor-lib.sh"
fm_home_anchor_resolve "$FM_ROOT" >/dev/null 2>&1 || exit 0
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: fm-herdr-outcome-publish.sh <task-id> <transfer|completed|failed|idle> <outcome> [summary]" >&2
  exit 2
fi
ID=$1
KIND=$2
OUTCOME=$3
SUMMARY=${4:-}

case "$KIND" in
  transfer|completed|failed|idle) ;;
  *)
    echo "usage: fm-herdr-outcome-publish.sh <task-id> <transfer|completed|failed|idle> <outcome> [summary]" >&2
    exit 2
    ;;
esac
if ! fm_task_id_path_safe "$ID" || [ -z "$OUTCOME" ]; then
  echo "usage: fm-herdr-outcome-publish.sh <task-id> <transfer|completed|failed|idle> <outcome> [summary]" >&2
  exit 2
fi

# Everything below is target resolution and the CLI calls themselves: any
# failure here is a decoration dropped, never a caller-visible error.
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

[ "$(grep -c '^backend=' "$META" 2>/dev/null || true)" = 1 ] || exit 0
BACKEND=$(fm_backend_meta_exact_value "$META" backend) || exit 0
[ "$BACKEND" = herdr ] || exit 0

SESSION=$(fm_backend_meta_exact_value "$META" herdr_session) || exit 0
WORKSPACE=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || exit 0

fm_backend_source herdr >/dev/null 2>&1 || exit 0
fm_backend_herdr_tool_check >/dev/null 2>&1 || exit 0

# transfer lands on the receiver (--to); completed/failed/idle leave from the
# reporter (--from) - report.md section C.1.
DIRECTION_FLAG=--from
[ "$KIND" != transfer ] || DIRECTION_FLAG=--to

fm_backend_herdr_cli "$SESSION" workspace report-signal \
  --source firstmate --kind "$KIND" "$DIRECTION_FLAG" "$WORKSPACE" \
  >/dev/null 2>&1 || true

TOKENS=(--token "outcome=$OUTCOME")
[ -z "$SUMMARY" ] || TOKENS+=(--token "summary=$SUMMARY")
fm_backend_herdr_cli "$SESSION" workspace report-metadata \
  --source firstmate "${TOKENS[@]}" "$WORKSPACE" \
  >/dev/null 2>&1 || true

exit 0
