#!/usr/bin/env bash
# fm-branch-classifier-score.sh - retrospective score of the supervision-branch
# pre-branch classifier on either host (docs/claude-supervision-branch.md
# "Classifier"; docs/pi-supervision-branch.md for the Pi extension).
#
# Reads state/branch-mod-classifications.jsonl, the durable log the Claude
# Code mod and the Pi extension append one record to per classifier call, and
# labels every record from the status lines the classifier was shown: the
# evidence byte ranges recorded per task are re-read from state/<task>.status
# and a record is labelled captain when any line in those ranges satisfies
# status_is_captain_relevant, the same test main applies when it decides
# whether a status event needs the captain. A record labelled captain whose
# verdict was routine is a captain miss: the branch was granted a wake main
# later had to act on. The table mirrors the spike replay scorer so numbers
# stay comparable across models.
#
# Usage:
#   bin/fm-branch-classifier-score.sh [-v] [<log-file>]
#
# The log defaults to $STATE/branch-mod-classifications.jsonl. -v lists every
# record whose label and verdict disagree. Records whose evidence ranges no
# longer resolve (the task's status log was torn down) count as unscorable
# and are excluded from the label columns. Exit 0 always; the table is the
# result, and an absent log prints an empty table.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
_fm_wake_require_classify

VERBOSE=0
LOG=""
for arg in "$@"; do
  case "$arg" in
    -v) VERBOSE=1 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) LOG=$arg ;;
  esac
done
[ -n "$LOG" ] || LOG="$STATE/branch-mod-classifications.jsonl"
command -v jq >/dev/null 2>&1 || { echo "fm-branch-classifier-score: jq is required" >&2; exit 2; }

# label <task> <from> <to>: prints captain, routine, or unscorable for one
# evidence range of one task.
label_range() {
  local task=$1 from=$2 to=$3 f line
  f="$STATE/$task.status"
  [ -f "$f" ] && [ "$from" -ge 0 ] && [ "$to" -ge "$from" ] || { echo unscorable; return; }
  [ "$(wc -c < "$f")" -ge "$to" ] || { echo unscorable; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    if status_is_captain_relevant "$line"; then echo captain; return; fi
  done < <(tail -c +"$((from + 1))" "$f" | head -c "$((to - from))")
  echo routine
}

printf '| model | records | verdict routine / captain / uncertain | captain misses (label captain, verdict routine) | captain caught (captain or uncertain) | spurious escalations (label routine, verdict not routine) | routine granted correctly | unscorable |\n'
printf '|---|---|---|---|---|---|---|---|\n'
[ -f "$LOG" ] || exit 0

MISMATCHES=""
declare -A n vr vc vu miss caught spurious granted unsc
while IFS=$'\t' read -r idx model verdict ev; do
  [ -n "$model" ] || model=unknown
  n[$model]=$(( ${n[$model]:-0} + 1 ))
  case "$verdict" in
    routine) vr[$model]=$(( ${vr[$model]:-0} + 1 )) ;;
    captain) vc[$model]=$(( ${vc[$model]:-0} + 1 )) ;;
    *) verdict=uncertain; vu[$model]=$(( ${vu[$model]:-0} + 1 )) ;;
  esac
  label=routine
  scorable=0
  for triple in $ev; do
    IFS=, read -r task from to <<< "$triple"
    case "$(label_range "$task" "$from" "$to")" in
      captain) label=captain; scorable=1 ;;
      routine) scorable=1 ;;
    esac
  done
  if [ "$scorable" -eq 0 ]; then
    unsc[$model]=$(( ${unsc[$model]:-0} + 1 ))
    continue
  fi
  is_miss=0
  if [ "$label" = captain ] && [ "$verdict" = routine ]; then
    is_miss=1; miss[$model]=$(( ${miss[$model]:-0} + 1 ))
  elif [ "$label" = captain ]; then
    caught[$model]=$(( ${caught[$model]:-0} + 1 ))
  elif [ "$verdict" = routine ]; then
    granted[$model]=$(( ${granted[$model]:-0} + 1 ))
  else
    spurious[$model]=$(( ${spurious[$model]:-0} + 1 ))
  fi
  if [ "$label" != "$verdict" ]; then
    tag=""
    [ "$is_miss" -eq 0 ] || tag=" CAPTAIN MISS"
    MISMATCHES+="- record $idx ($model): label $label, verdict $verdict$tag: ${ev// /;}"$'\n'
  fi
done < <(jq -R -r 'fromjson? | select(type == "object") | [input_line_number, (.model // "unknown"), (.verdict // "uncertain"), ((.evidence // []) | map("\(.task),\(.from // -1),\(.to // -1)") | join(" "))] | @tsv' "$LOG" 2>/dev/null)

for model in "${!n[@]}"; do
  printf '| %s | %d | %d / %d / %d | %d | %d | %d | %d | %d |\n' "$model" "${n[$model]}" \
    "${vr[$model]:-0}" "${vc[$model]:-0}" "${vu[$model]:-0}" "${miss[$model]:-0}" \
    "${caught[$model]:-0}" "${spurious[$model]:-0}" "${granted[$model]:-0}" "${unsc[$model]:-0}"
done | sort

if [ "$VERBOSE" -eq 1 ] && [ -n "$MISMATCHES" ]; then
  printf '\n### label != verdict\n%s' "$MISMATCHES"
fi
