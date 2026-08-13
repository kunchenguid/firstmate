#!/usr/bin/env bash
# Read-only accepted-work continuation check for primary turn-end hooks.
#
# Exit 0 when a normal turn may settle: no dispatchable queued work exists and
# every ordinary In flight backlog item has a matching worker whose canonical
# current state is `working`.
# Exit 2 when Firstmate must reconcile work before settling. Output is one
# parseable line:
#
#   continuation-required: ready=<count> [ids=<csv>] orphan=<count> [ids=<csv>] inactive=<count> [ids=<csv>]
#
# `tasks-axi ready` remains the one owner of dependency, structured hold, date,
# load, external-resource, and Captain-decision eligibility. This script never
# launches work, changes the backlog, clears a hold, or interprets hold prose.
# Program In flight records do not require worker metadata. Missing or
# incompatible tasks-axi is a silent exit 0 because bootstrap owns that blocker
# and a turn-end hook must not wedge a session when its read-only dependency is
# unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"
CREW_TIMEOUT=${FM_CONTINUATION_CREW_TIMEOUT:-3}
case "$CREW_TIMEOUT" in ''|*[!0-9]*|0) CREW_TIMEOUT=3 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

case "${1:-}" in
  "") ;;
  -h|--help)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "usage: $(basename "$0")" >&2
    exit 2
    ;;
esac

[ -f "$BACKLOG" ] || exit 0
command -v tasks-axi >/dev/null 2>&1 || exit 0

# Ordinary dispatchable rows are the indented lines under the tool's own
# `ready[N]{...}` header. `tasks-axi ready` prints delivery-ready
# public-followup obligations in a separate `ready_public_followups` group and
# documents them as never dispatchable, and its `count:` line excludes them, so
# anchoring here keeps the id list and the count drawn from the same set. This
# mirrors print_ready_queued_bounded in bin/fm-session-start.sh, the repo's
# existing owner of this output.
table_ids() {
  awk '
    /^ready\[/ { rows = 1; next }
    rows && /^  [A-Za-z0-9][A-Za-z0-9._-]*,/ {
      row=$0
      sub(/^  /, "", row)
      sub(/,.*/, "", row)
      print row
      next
    }
    /^[^[:space:]]/ { rows = 0 }
  '
}

csv_join() {
  awk 'NF { if (out != "") out=out ","; out=out $0 } END { print out }'
}

ready_out=$(tasks-axi ready --file "$BACKLOG" 2>/dev/null) || exit 0
ready_count=$(printf '%s\n' "$ready_out" | sed -n 's/^count: \([0-9][0-9]*\)$/\1/p' | head -1)
case "$ready_count" in ''|*[!0-9]*) exit 0 ;; esac
ready_ids=$(printf '%s\n' "$ready_out" | table_ids | csv_join)

in_flight_out=$(tasks-axi list --state in_flight --file "$BACKLOG" 2>/dev/null) || exit 0

ownership_rows=$(
  printf '%s\n' "$in_flight_out" | awk -F, '
    /^  [A-Za-z0-9][A-Za-z0-9._-]*,/ {
      sub(/^  /, "", $1)
      print $1 "\t" $3
    }
  ' | while IFS=$'\t' read -r id kind; do
    [ -n "$id" ] || continue
    [ "$kind" != program ] || continue
    if [ ! -f "$STATE/$id.meta" ]; then
      printf 'orphan\t%s\n' "$id"
      continue
    fi
    state_line=$(fm_run_timed "$CREW_TIMEOUT" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_CREW_STATE_NM_TIMEOUT=2 "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true)
    if ! printf '%s\n' "$state_line" | grep -q '^state: working '; then
      printf 'inactive\t%s\n' "$id"
    fi
  done
)
orphan_ids=$(printf '%s\n' "$ownership_rows" | awk -F'\t' '$1 == "orphan" { print $2 }' | csv_join)
inactive_ids=$(printf '%s\n' "$ownership_rows" | awk -F'\t' '$1 == "inactive" { print $2 }' | csv_join)
if [ -n "$orphan_ids" ]; then
  orphan_count=$(printf '%s' "$orphan_ids" | awk -F, '{print NF}')
else
  orphan_count=0
fi
if [ -n "$inactive_ids" ]; then
  inactive_count=$(printf '%s' "$inactive_ids" | awk -F, '{print NF}')
else
  inactive_count=0
fi

if [ "$ready_count" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$inactive_count" -eq 0 ]; then
  exit 0
fi

printf 'continuation-required: ready=%s' "$ready_count"
[ -z "$ready_ids" ] || printf ' ids=%s' "$ready_ids"
printf ' orphan=%s' "$orphan_count"
[ -z "$orphan_ids" ] || printf ' ids=%s' "$orphan_ids"
printf ' inactive=%s' "$inactive_count"
[ -z "$inactive_ids" ] || printf ' ids=%s' "$inactive_ids"
printf '\n'
exit 2
