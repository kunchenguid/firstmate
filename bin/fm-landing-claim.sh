#!/usr/bin/env bash
# Record a worker's done: claim, with the proof command that will show it
# landed, as one row in the landing police's claims file.
# Deterministic and model-free: it only parses the status line and appends.
# The worker-side contract (what proof:, expect:, told:, and told-expect: mean
# and what counts as landed per kind) is owned by docs/landing-proof.md; the
# field grammar is owned by status_line_landing_fields_core in
# bin/fm-classify-lib.sh, and this script never re-parses a line itself.
# Firstmate calls `from-status` for a ship task whose newest status line is
# done:, and this home's landing police reads the claims file it produces, so a
# claim is recorded and an unproven one is caught with no model in the loop.
#
# Usage:
#   fm-landing-claim.sh parse <status-line>
#       Print the parsed fields as key=value lines (claim, kind,
#       customer_facing, proof, expect, told, told_expect, lesson).
#   fm-landing-claim.sh append [--epoch <n>] <task-id> <status-line>
#       Parse a done: line and append its claims row.
#   fm-landing-claim.sh from-status [--epoch <n>] <task-id>
#       Same, using the newest done: line in state/<task-id>.status.
#
# The claims file is FM_LANDING_CLAIMS, defaulting to
# data/landing-police/claims.tsv under FM_HOME (FM_DATA_OVERRIDE and
# FM_STATE_OVERRIDE relocate data/ and state/ as for the other scripts).
# It is tab-separated with '#' comments, one row per claim:
#   task  claimed_epoch  kind  customer_facing(y|n)  claim  proof_cmd  expect_regex  told_cmd  told_regex
# A missing file is created with that header line.
# customer_facing is y exactly when the line carries a told: clause.
# An identical task/kind/claim/proof/expect/told row is not appended twice, so a
# re-run after an interrupted wake is harmless; it reports "unchanged".
#
# Exit codes:
#   0  parsed (parse) or row appended or already present (append, from-status)
#   2  usage error, a non-done: line, or no done: line in the status log
#   3  UNPROVEN: the done: line carries no proof: clause; a line starting
#      "UNPROVEN:" is printed and nothing is appended, and firstmate reports
#      the claim as unproven and sends the task back to in progress
#   4  MALFORMED: the proof clauses are incomplete or invalid; the reason is
#      printed after "MALFORMED:" and nothing is appended
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  echo "fm-landing-claim.sh: $*" >&2
  exit 2
}

FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME=${FM_HOME:-$FM_ROOT}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CLAIMS=${FM_LANDING_CLAIMS:-$DATA/landing-police/claims.tsv}
CLAIMS_HEADER=$'# task\tclaimed_epoch\tkind\tcustomer_facing\tclaim\tproof_cmd\texpect_regex\ttold_cmd\ttold_regex'

# Parse <line>; on success the _FM_LANDING_* globals hold the fields.
# Prints the UNPROVEN or MALFORMED line and exits 3 or 4 otherwise.
parse_or_exit() {  # <task-label> <line>
  local who=$1 line=$2 rc=0
  status_line_landing_fields_core "$line" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) echo "UNPROVEN: ${who}done: line carries no proof: command - report it unproven and send the task back to in progress"; exit 3 ;;
    *) echo "MALFORMED: ${who}$_FM_LANDING_ERROR"; exit 4 ;;
  esac
}

valid_task() {  # <task-id>
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) die_usage "invalid task id '$1'" ;;
  esac
}

customer_facing() {
  if [ -n "$_FM_LANDING_TOLD" ]; then printf 'y'; else printf 'n'; fi
}

append_row() {  # <task> <epoch> <line>
  local task=$1 epoch=$2 line=$3 cf row key
  valid_task "$task"
  status_line_verb_core "$line"
  [ "$_FM_STATUS_VERB" = "done" ] || die_usage "not a done: line (verb '$_FM_STATUS_VERB')"
  parse_or_exit "$task: " "$line"
  cf=$(customer_facing)
  key="$task"$'\t'"$_FM_LANDING_KIND"$'\t'"$cf"$'\t'"$_FM_LANDING_CLAIM"$'\t'"$_FM_LANDING_PROOF"$'\t'"$_FM_LANDING_EXPECT"$'\t'"$_FM_LANDING_TOLD"$'\t'"$_FM_LANDING_TOLD_EXPECT"
  row="$task"$'\t'"$epoch"$'\t'"$_FM_LANDING_KIND"$'\t'"$cf"$'\t'"$_FM_LANDING_CLAIM"$'\t'"$_FM_LANDING_PROOF"$'\t'"$_FM_LANDING_EXPECT"$'\t'"$_FM_LANDING_TOLD"$'\t'"$_FM_LANDING_TOLD_EXPECT"
  mkdir -p "$(dirname "$CLAIMS")"
  [ -s "$CLAIMS" ] || printf '%s\n' "$CLAIMS_HEADER" >> "$CLAIMS"
  # Compare every field except the epoch so a replayed claim stays one row.
  if awk -F '\t' -v key="$key" '
      /^#/ { next }
      { k = $1; for (i = 3; i <= 9; i++) k = k "\t" $i; if (k == key) { found = 1; exit } }
      END { exit found ? 0 : 1 }
    ' "$CLAIMS"; then
    echo "unchanged: $task claim already recorded in $CLAIMS"
    return 0
  fi
  printf '%s\n' "$row" >> "$CLAIMS"
  echo "recorded: $task ($_FM_LANDING_KIND, customer_facing=$cf) in $CLAIMS"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
cmd=$1
shift
case "$cmd" in
  -h|--help) usage; exit 0 ;;
esac

EPOCH=
case "$cmd" in
  append|from-status)
    if [ "${1:-}" = --epoch ]; then
      [ "$#" -ge 2 ] || die_usage "--epoch needs a value"
      case "$2" in ''|*[!0-9]*) die_usage "--epoch must be a whole number of seconds" ;; esac
      EPOCH=$2
      shift 2
    fi
    [ -n "$EPOCH" ] || EPOCH=$(date +%s)
    ;;
esac

case "$cmd" in
  parse)
    [ "$#" -eq 1 ] || die_usage "parse takes exactly one status line"
    parse_or_exit "" "$1"
    printf 'claim=%s\nkind=%s\ncustomer_facing=%s\nproof=%s\nexpect=%s\ntold=%s\ntold_expect=%s\nlesson=%s\n' \
      "$_FM_LANDING_CLAIM" "$_FM_LANDING_KIND" "$(customer_facing)" "$_FM_LANDING_PROOF" \
      "$_FM_LANDING_EXPECT" "$_FM_LANDING_TOLD" "$_FM_LANDING_TOLD_EXPECT" "$_FM_LANDING_LESSON"
    ;;
  append)
    [ "$#" -eq 2 ] || die_usage "append takes <task-id> <status-line>"
    append_row "$1" "$EPOCH" "$2"
    ;;
  from-status)
    [ "$#" -eq 1 ] || die_usage "from-status takes <task-id>"
    task=$1
    valid_task "$task"
    log="$STATE/$task.status"
    [ -f "$log" ] || die_usage "no status log for $task at $log"
    newest=
    while IFS= read -r l || [ -n "$l" ]; do
      status_line_verb_core "$l"
      [ "$_FM_STATUS_VERB" = "done" ] && newest=$l
    done < "$log"
    [ -n "$newest" ] || die_usage "no done: line in $log"
    append_row "$task" "$EPOCH" "$newest"
    ;;
  *)
    die_usage "unknown command '$cmd' (parse, append, from-status)"
    ;;
esac
