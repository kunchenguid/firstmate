#!/usr/bin/env bash
# fm-secondmate-reconcile.sh - ask a secondmate to reconcile its own books once
# per inventory-mismatch episode.
#
# Usage:
#   fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
#   fm-secondmate-reconcile.sh episode <mate-id>
#
# A backlog-vs-metadata inventory mismatch inside a secondmate home
# (orphan_in_flight, unowned_current, terminal_in_flight) no longer makes that
# home unreadable: bin/fm-fleet-snapshot.sh keeps its decisions, queued, landed,
# and live work and carries the mismatch in `invalidity`. The books are still
# wrong, and only the home that owns them may fix them, so the parent sends one
# reconcile instruction and stops there.
#
# What this script owns:
#   - reading the mismatch from an already-produced fleet snapshot, so nothing
#     here re-parses another home's state or runs a second child summary;
#   - the once-per-episode contract. An episode identity is
#     "<invalidity-kind>:<sorted mismatch ids>". A persistent mismatch keeps the
#     same identity and is never re-sent, so a recap or digest loop cannot nag.
#     A changed identity is a NEW episode and earns exactly one more send. A
#     home whose mismatch clears drops its record, so a recurrence notifies
#     again;
#   - sending through bin/fm-send.sh, the existing steering transport, which
#     records the instruction durably for local and remote mates alike.
#
# What this script must never do:
#   - edit the mate's backlog, metadata, or queue from the parent. The mate owns
#     its own cleanup; the parent only asks.
#   - block a snapshot or digest. Callers run it after their output is produced,
#     and a send failure is reported, never fatal to the caller's own work.
#
# Exit status: 0 when every due home was either notified, deduped, or cleared;
# 1 when at least one due send failed (the episode is NOT recorded for a failed
# send, so the next run retries it).
#
# Output, one line per home considered:
#   sent: <mate-id> <episode>       one reconcile instruction was recorded
#   dedupe: <mate-id> <episode>     same episode already notified; nothing sent
#   cleared: <mate-id>              the mismatch is gone; the record was dropped
#   failed: <mate-id> <episode>     the steer could not be recorded
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  cat <<'EOF'
usage: fm-secondmate-reconcile.sh notify [--snapshot <file>|-]
       fm-secondmate-reconcile.sh episode <mate-id>

notify   ask every secondmate home with a NEW inventory-mismatch episode to
         reconcile its own backlog against its own task metadata, exactly once
         per episode. Reads a fleet snapshot from --snapshot (or runs
         fm-fleet-snapshot.sh --json when omitted).
episode  print the episode identity already notified for <mate-id>, if any.
EOF
}

fail() { echo "fm-secondmate-reconcile: $*" >&2; exit 2; }

episode_path() {  # <mate-id>
  printf '%s/%s.reconcile-episode\n' "$STATE" "$1"
}

cmd_episode() {
  local id path
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  id=$1
  case "$id" in ''|*/*|.*) fail "not a task id: $id" ;; esac
  path=$(episode_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  cat "$path"
}

# The instruction is deliberately plain: it names what disagrees and leaves the
# repair entirely to the mate, which is the only home allowed to change it.
reconcile_text() {  # <kind> <ids-csv>
  local kind=$1 ids=$2 what
  case "$kind" in
    orphan_in_flight)
      what="these in-flight backlog items have no task metadata in your home, so no worker is running them: $ids" ;;
    unowned_current)
      what="these live task records in your home have no in-flight backlog item: $ids" ;;
    terminal_in_flight)
      what="these in-flight backlog items already have a finished worker: $ids" ;;
    *) what="your backlog and task metadata disagree about: $ids" ;;
  esac
  cat <<EOF
Your home's backlog and its task metadata disagree, and only you can settle it: $what

Please reconcile your own books: move each row to the section that matches reality, or clean up the leftover record. Nothing outside your home has been changed, and this is the only time you will be asked about this particular disagreement.
EOF
}

cmd_notify() {
  local snapshot_src="" snapshot rows rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot) [ "$#" -ge 2 ] || fail "--snapshot needs a value"; snapshot_src=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || fail "jq is required"

  if [ -z "$snapshot_src" ]; then
    snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || fail "cannot read the fleet snapshot"
  elif [ "$snapshot_src" = - ]; then
    snapshot=$(cat)
  else
    [ -f "$snapshot_src" ] || fail "snapshot does not exist: $snapshot_src"
    snapshot=$(cat "$snapshot_src")
  fi
  printf '%s' "$snapshot" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1 \
    || fail "input is not an fm-fleet-snapshot.v1 document"

  # Only a readable structured home can be asked to reconcile: a home the parent
  # could not read has a different problem, and its record carries no invalidity.
  rows=$(printf '%s' "$snapshot" | jq -r '
    (.secondmate_current.records // [])[]
    | select(.provenance.selected == "structured-home")
    | select((.id | type) == "string" and (.id | test("^[A-Za-z0-9._-]+$")))
    | (.invalidity.kind // "") as $kind
    | (if ["orphan_in_flight","unowned_current","terminal_in_flight"] | index($kind)
       then ((.invalidity.ids // []) | map(select(type == "string")) | sort | join(","))
       else "" end) as $ids
    | [.id, (if $ids == "" then "" else $kind end), $ids] | @tsv')

  local id kind ids episode path prior
  while IFS=$'\t' read -r id kind ids; do
    [ -n "${id:-}" ] || continue
    path=$(episode_path "$id")
    if [ -z "$kind" ]; then
      if [ -f "$path" ] && [ ! -L "$path" ]; then
        rm -f -- "$path" && printf 'cleared: %s\n' "$id"
      fi
      continue
    fi
    episode="$kind:$ids"
    prior=
    if [ -f "$path" ] && [ ! -L "$path" ]; then prior=$(cat "$path" 2>/dev/null || true); fi
    if [ "$prior" = "$episode" ]; then
      printf 'dedupe: %s %s\n' "$id" "$episode"
      continue
    fi
    if ! "$SCRIPT_DIR/fm-send.sh" "$id" "$(reconcile_text "$kind" "$ids")" >/dev/null 2>&1; then
      printf 'failed: %s %s\n' "$id" "$episode"
      rc=1
      continue
    fi
    # Record the episode only after the instruction is durably recorded, so a
    # failed send is retried rather than silently deduped away.
    if (umask 077; printf '%s\n' "$episode" > "$path.tmp") && mv -f -- "$path.tmp" "$path"; then
      printf 'sent: %s %s\n' "$id" "$episode"
    else
      rm -f -- "$path.tmp"
      # The mate has the instruction; only this home's dedupe record is missing,
      # so say so rather than letting the next run repeat the ask in silence.
      printf 'sent-unrecorded: %s %s\n' "$id" "$episode"
      rc=1
    fi
  done <<EOF
$rows
EOF
  return "$rc"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1; shift
case "$cmd" in
  notify) cmd_notify "$@" ;;
  episode) cmd_episode "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
