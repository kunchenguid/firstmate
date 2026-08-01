#!/usr/bin/env bash
# Reconcile terminal producer reports with structured backlog rows, then write a
# durable inventory receipt for every metadata/backlog mismatch without deleting
# any row, metadata, status, report, worktree, or commit that proves what happened.
#
# Usage: fm-record-reconcile.sh
#
# A `done:` producer or a producer declaring the complete-only
# `awaiting-captain:` state while still In flight moves to Done with --no-prune
# and an explicit retained-lifecycle note. Its endpoint metadata and worktree
# remain; teardown separately refuses unlanded work. Scout rows move only after
# the report exists and the decision-hold completion gate verifies. Missing
# metadata and orphan metadata are accounted in the receipt and preserved.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
RECEIPT_DIR="$DATA/record-reconciliation"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-custody-lib.sh
. "$SCRIPT_DIR/fm-custody-lib.sh"

[ -f "$BACKLOG" ] || exit 0
events=

append_event() {  # <class> <id> <detail>
  events="${events}${1}"$'\t'"${2}"$'\t'"${3}"$'\n'
}

in_flight_ids() {
  awk '
    /^## In flight/ { inside=1; next }
    /^## / { inside=0 }
    inside && /^- \[ \] / { sub(/^- \[ \] /, ""); sub(/ -.*/, ""); print }
  ' "$BACKLOG"
}

task_state() {  # <id>
  (cd "$FM_HOME" && tasks-axi show "$1" --full 2>/dev/null) \
    | sed -n 's/^  state: //p' | head -1
}

TERMINAL_WORKTREE=
TERMINAL_HEAD=
terminal_tree_is_clean() {  # <meta>
  local meta=$1 count status
  TERMINAL_WORKTREE=
  TERMINAL_HEAD=
  count=$(grep -c '^worktree=' "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  TERMINAL_WORKTREE=$(sed -n 's/^worktree=//p' "$meta")
  [ -d "$TERMINAL_WORKTREE" ] \
    && git -C "$TERMINAL_WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || return 1
  TERMINAL_HEAD=$(git -C "$TERMINAL_WORKTREE" rev-parse HEAD 2>/dev/null) || return 1
  status=$(git -C "$TERMINAL_WORKTREE" status --porcelain --untracked-files=normal 2>/dev/null) \
    || return 1
  [ -z "$status" ]
}

if fm_tasks_axi_compatible; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    meta="$STATE/$id.meta"
    [ -f "$meta" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    [ "$kind" != secondmate ] || continue
    last=$(last_status_line "$STATE/$id.status")
    status_is_done "$last" || status_is_awaiting_captain "$last" || continue
    if ! terminal_tree_is_clean "$meta"; then
      append_event terminal-unreconciled "$id" 'terminal status retained in flight because worktree identity or clean-tree evidence is unavailable'
      continue
    fi
    if [ "$kind" = scout ]; then
      if [ ! -f "$DATA/$id/report.md" ] || [ -L "$DATA/$id/report.md" ]; then
        append_event terminal-unreconciled "$id" 'scout report missing or unsafe; row preserved'
        continue
      fi
      if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        "$SCRIPT_DIR/fm-decision-hold.sh" verify "$id" >/dev/null 2>&1; then
        append_event terminal-unreconciled "$id" 'decision inventory not cleanup-authoritative; row preserved'
        continue
      fi
    fi
    (cd "$FM_HOME" && tasks-axi 'done' "$id" --no-prune \
      --note "producer terminal status reconciled at $TERMINAL_HEAD; endpoint metadata and worktree retained pending landing, independent gate, or captain answer") >/dev/null \
      || { append_event terminal-unreconciled "$id" 'tasks-axi transition failed; row preserved'; continue; }
    append_event terminal-retained "$id" "moved from In flight to Done at head=$TERMINAL_HEAD with tree=clean; metadata and worktree retained"
  done < <(in_flight_ids)
fi

# Inventory the post-transition state. These are explanations, not cleanup
# authority: every mismatched object remains at its original path.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  [ -f "$STATE/$id.meta" ] || append_event missing-meta "$id" 'live in-flight row preserved without metadata'
done < <(in_flight_ids)

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  state=$(task_state "$id" || true)
  [ -n "$state" ] || append_event orphan-meta "$id" 'metadata preserved without one live backlog row'
done

for status_file in "$STATE"/*.status; do
  [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
  id=${status_file##*/}
  id=${id%.status}
  [ -f "$STATE/$id.meta" ] \
    || append_event orphan-status "$id" 'append-only status evidence preserved without endpoint metadata'
done

in_flight_count=$(in_flight_ids | awk 'NF { count++ } END { print count + 0 }')
metadata_count=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  metadata_count=$((metadata_count + 1))
done
metadata_delta=$((metadata_count - in_flight_count))

mkdir -p "$RECEIPT_DIR"
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
stamp=$(date -u '+%Y%m%dT%H%M%SZ')
backlog_sha=$(fm_custody_sha256 "$BACKLOG")
attempt=0
while [ "$attempt" -lt 100 ]; do
  receipt="$RECEIPT_DIR/reconcile.$stamp.${BASHPID:-$$}.$attempt.receipt"
  if (set -C; umask 077; {
    printf 'schema=fm-record-reconciliation.v1\n'
    printf 'timestamp_utc=%s\n' "$timestamp"
    printf 'backlog_path=%s\n' "$BACKLOG"
    printf 'backlog_sha256=%s\n' "$backlog_sha"
    printf 'in_flight_count=%s\n' "$in_flight_count"
    printf 'metadata_count=%s\n' "$metadata_count"
    printf 'metadata_minus_in_flight=%s\n' "$metadata_delta"
    printf 'events_begin\n'
    printf '%s' "$events"
    printf 'events_end\n'
  } > "$receipt") 2>/dev/null; then
    printf '%s\n' "$receipt"
    exit 0
  fi
  attempt=$((attempt + 1))
done
printf 'fm-record-reconcile: could not allocate a create-exclusive receipt\n' >&2
exit 1
