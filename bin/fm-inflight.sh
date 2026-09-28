#!/usr/bin/env bash
# fm-inflight.sh - one easy view of what is in flight, from durable records.
#
# Answers at a glance: what is running, what is open, what landed recently,
# and what needs the captain. Every row comes from a durable record - live
# task metadata via bin/fm-crew-state.sh, the federated bead stores, and the
# beads-native human gates - never from conversation memory. A source that
# cannot be read is named as unavailable; it is never silently omitted.
#
# Surface choice: a plain command, not a second board. The fleet already owns
# an interactive board (bin/fm-bearings-board.sh) for Captain's Call
# reconciliation, and that machinery - lavish session, liveness proof, answer
# source arming - is the wrong price for a turn-time glance. This command also
# deliberately does NOT shell out to bin/fm-fleet-snapshot.sh: measured at
# ~47s in this fleet (2026-09-28, mostly endpoint/agent classification waits),
# which breaks a turn-time budget. The snapshot stays canonical for Bearings
# and session start; this view reads the same underlying durable records
# through their sanctioned readers (crew-state per task, store CLIs, gate
# list) and runs in seconds.
#
# Usage:
#   fm-inflight.sh [--since <date>] [--open-limit N] [--landed-limit N]
#
#   --since <date>      Recently-landed window start for --closed-after
#                       (default: 24 hours ago, RFC3339). Passed through to
#                       each store's list command.
#   --open-limit N      Open rows shown per store (default 8).
#   --landed-limit N    Landed rows shown per store (default 5).
#
# Sections:
#   LIVE WORKERS   one row per state/*.meta task: crew-state verdict plus
#                  kind and project from the metadata record.
#   OPEN BEADS     open/in-progress/blocked beads per store. The task store
#                  is scoped to the fleet label; the other stores are shared
#                  queues and read whole. Each store is asked for LIMIT+1
#                  rows so a truncated list can say so.
#   RECENTLY LANDED beads closed since --since, per store, newest first.
#   AWAITING YOU   open beads-native human gates (the durable form of held
#                  captain decisions under config/backlog-backend=beads) plus
#                  open review items. These need the captain.
#
# Read-only. Local-only: no network calls beyond the stores' own local reads.
# Every external read runs under FM_INFLIGHT_TIMEOUT (default 10 seconds); a
# missing CLI, a failed read, or a hit bound prints `unavailable` with the
# reason. Exit 0 whenever the view renders, even partially; exit 2 on usage
# errors or a missing jq.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_INFLIGHT_TIMEOUT=${FM_INFLIGHT_TIMEOUT:-10}
FM_INFLIGHT_OPEN_LIMIT=${FM_INFLIGHT_OPEN_LIMIT:-8}
FM_INFLIGHT_LANDED_LIMIT=${FM_INFLIGHT_LANDED_LIMIT:-5}
FLEET_LABEL=${FM_BEADS_FLEET_LABEL:-fleet:firstmate}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-inflight: %s\n' "$*" >&2
  exit 2
}

default_since() {
  date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT00:00:00Z
}

SINCE=$(default_since)
OPEN_LIMIT=$FM_INFLIGHT_OPEN_LIMIT
LANDED_LIMIT=$FM_INFLIGHT_LANDED_LIMIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) [ "$#" -ge 2 ] || fail "--since needs a value"; SINCE=$2; shift 2 ;;
    --open-limit) [ "$#" -ge 2 ] || fail "--open-limit needs a value"; OPEN_LIMIT=$2; shift 2 ;;
    --landed-limit) [ "$#" -ge 2 ] || fail "--landed-limit needs a value"; LANDED_LIMIT=$2; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$OPEN_LIMIT$LANDED_LIMIT$FM_INFLIGHT_TIMEOUT" in
  ''|*[!0-9]*) fail "limits and timeout must be non-negative integers" ;;
esac

command -v jq >/dev/null 2>&1 || fail "jq is required"

# One bounded store read. Prints raw JSON on stdout; on any failure prints an
# `unavailable` line and returns 0 so one dead store never kills the view.
store_json() {  # <store> <args...>
  local store=$1 out rc=0
  shift
  command -v "$store" >/dev/null 2>&1 \
    || { printf 'unavailable: %s CLI not installed\n' "$store"; return 0; }
  out=$(fm_run_timed "$FM_INFLIGHT_TIMEOUT" "$store" list --json "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'unavailable: read hit the %ss bound\n' "$FM_INFLIGHT_TIMEOUT"
  elif [ "$rc" -ne 0 ]; then
    printf 'unavailable: %s\n' "$(printf '%s' "$out" | head -1)"
  else
    printf '%s\n' "$out"
  fi
}

# Render at most LIMIT rows from a JSON array on stdin, then disclose overflow.
render_rows() {  # <limit> <jq-row-filter> <store-name>
  local limit=$1 filter=$2 name=$3 json count
  json=$(cat)
  case "$json" in
    unavailable:*) printf '  %s\n' "$json"; return 0 ;;
  esac
  count=$(printf '%s' "$json" | jq 'length' 2>/dev/null) || {
    printf '  unavailable: unreadable store output\n'
    return 0
  }
  printf '%s' "$json" | jq -r --argjson limit "$limit" \
    ".[:\$limit][] | ($filter)" 2>/dev/null \
    || printf '  unavailable: unreadable store output\n'
  if [ "${count:-0}" -gt "$limit" ]; then
    printf '  (+%d more - run %s list for the rest)\n' "$((count - limit))" "$name"
  elif [ "${count:-0}" -eq 0 ]; then
    printf '  (none)\n'
  fi
}

OPEN_ROW='"  " + .id + " [" + .status + "] " + .title'
GATE_ROW='"  " + .id + " " + ((.description // "") | split("\n")[0])'

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" | head -1
}

printf 'In flight (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Sources: live task metadata + stores [task review robots projects workflows inbox]\n\n'

printf '## Live workers\n'
WORKERS=0
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  verdict=$(fm_run_timed 5 env FM_HOME="$FM_HOME" \
    FM_CREW_STATE_META_OVERRIDE="$meta" \
    "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1)
  [ -n "$verdict" ] || verdict="state: unknown"
  verdict=$(printf '%s' "$verdict" | cut -c1-200)
  printf '  %s [%s] %s on %s\n' "$id" "$verdict" \
    "$(meta_value "$meta" kind)" "$(meta_value "$meta" project)"
  WORKERS=$((WORKERS + 1))
done
[ "$WORKERS" -gt 0 ] || printf '  (none)\n'

printf '\n## Open beads\n'
for STORE in task review robots projects workflows inbox; do
  if [ "$STORE" = task ]; then
    OUT=$(store_json "$STORE" --status open,in_progress,blocked \
      --label "$FLEET_LABEL" -n $((OPEN_LIMIT + 1)))
    printf 'task (fleet label):\n'
  else
    OUT=$(store_json "$STORE" --status open,in_progress,blocked -n $((OPEN_LIMIT + 1)))
    printf '%s:\n' "$STORE"
  fi
  printf '%s' "$OUT" | render_rows "$OPEN_LIMIT" "$OPEN_ROW" "$STORE"
done

printf '\n## Recently landed (closed since %s)\n' "$SINCE"
for STORE in task review robots projects workflows; do
  OUT=$(store_json "$STORE" --status closed --closed-after "$SINCE" -n $((LANDED_LIMIT + 1)))
  printf '%s:\n' "$STORE"
  case "$OUT" in
    unavailable:*) printf '  %s\n' "$OUT" ;;
    *) printf '%s' "$OUT" | jq -r --argjson limit "$LANDED_LIMIT" '
        (sort_by(.closed_at) | reverse) as $rows
        | if ($rows | length) == 0 then "  (none)"
          else ($rows[:$limit][] |
              "  " + .id + " " + .title
              + " (closed " + (.closed_at // "?") + ")"),
            (if ($rows | length) > $limit then
              "  (+\((($rows | length) - $limit)) more)"
             else empty end) end' 2>/dev/null \
        || printf '  unavailable: unreadable store output\n' ;;
  esac
done

printf '\n## Awaiting you\n'
GATES=$(fm_run_timed "$FM_INFLIGHT_TIMEOUT" task gate list --json \
  -n $((OPEN_LIMIT + 1)) 2>/dev/null) || GATES="unavailable: gate read failed"
printf 'held decisions (open human gates):\n'
  printf '%s' "$GATES" | render_rows "$OPEN_LIMIT" "$GATE_ROW" "task gate"
OUT=$(store_json review --status open,in_progress,blocked -n $((OPEN_LIMIT + 1)))
printf 'review items:\n'
printf '%s' "$OUT" | render_rows "$OPEN_LIMIT" "$OPEN_ROW" review | sed 's/^/  /'
