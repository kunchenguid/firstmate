#!/usr/bin/env bash
# Check completed multi-task programs for a durable standing source-of-truth pointer.
#
# Usage: fm-sot-pointer-check.sh [--strict] [--registry <path>]
#
# Registry lookup, in precedence order when --registry is absent:
#   $FM_HOME/data/sot-programs.tsv
#   $FM_HOME/config/sot-programs.tsv
#
# Each non-comment row is tab-separated:
#   program_id <TAB> needle_regex <TAB> source_task_id,source_task_id,...
#
# A row is enforced only after every source task has a checked Done row in
# data/done-archive.md or data/backlog.md. The ERE needle is matched against the
# concatenated contents of data/captain.md and regular files directly under
# data/decisions/. A missing pointer prints one SOT_GAP line.
#
# The default mode always exits 0 so bootstrap can surface gaps without blocking
# session start. --strict exits 1 when at least one gap is found. Argument misuse
# exits 2. An absent or empty registry is silent success.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

strict=0
registry=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)
      strict=1
      shift
      ;;
    --registry)
      [ "$#" -ge 2 ] || {
        echo "error: --registry requires a path" >&2
        exit 2
      }
      registry=$2
      shift 2
      ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$registry" ]; then
  if [ -f "$DATA/sot-programs.tsv" ]; then
    registry="$DATA/sot-programs.tsv"
  elif [ -f "$CONFIG/sot-programs.tsv" ]; then
    registry="$CONFIG/sot-programs.tsv"
  else
    exit 0
  fi
fi

[ -f "$registry" ] && [ -s "$registry" ] || exit 0

trim_space() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

task_is_done() {
  local task_id=$1 task_file
  for task_file in "$DATA/done-archive.md" "$DATA/backlog.md"; do
    [ -f "$task_file" ] || continue
    if awk -v task_id="$task_id" \
      '$1 == "-" && $2 == "[x]" && $3 == task_id { found = 1; exit }
       END { exit !found }' "$task_file"; then
      return 0
    fi
  done
  return 1
}

all_sources_done() {
  local source_csv=$1 source_id
  local -a source_ids
  IFS=, read -r -a source_ids <<< "$source_csv"
  [ "${#source_ids[@]}" -gt 0 ] || return 1
  for source_id in "${source_ids[@]}"; do
    source_id=$(trim_space "$source_id")
    [ -n "$source_id" ] || return 1
    task_is_done "$source_id" || return 1
  done
}

pointer_blob=$(
  [ -f "$DATA/captain.md" ] && cat "$DATA/captain.md"
  if [ -d "$DATA/decisions" ]; then
    for decision_file in "$DATA/decisions"/*; do
      [ -f "$decision_file" ] || continue
      cat "$decision_file"
    done
  fi
)

gaps=0
while IFS= read -r row || [ -n "$row" ]; do
  trimmed_row=$(trim_space "$row")
  case "$trimmed_row" in
    ''|\#*) continue ;;
  esac

  program_id=${row%%$'\t'*}
  remainder=${row#*$'\t'}
  [ "$remainder" != "$row" ] || continue
  needle_regex=${remainder%%$'\t'*}
  source_task_ids=${remainder#*$'\t'}
  [ "$source_task_ids" != "$remainder" ] || continue
  case "$source_task_ids" in
    *$'\t'*) continue ;;
  esac

  program_id=$(trim_space "$program_id")
  source_task_ids=$(trim_space "$source_task_ids")
  [ -n "$program_id" ] && [ -n "$needle_regex" ] && [ -n "$source_task_ids" ] || continue
  all_sources_done "$source_task_ids" || continue

  if grep -E -q -- "$needle_regex" <<< "$pointer_blob" 2>/dev/null; then
    continue
  fi

  printf 'SOT_GAP: %s - sources Done but no standing pointer matching /%s/ in captain.md|decisions/\n' \
    "$program_id" "$needle_regex"
  gaps=$((gaps + 1))
done < "$registry"

if [ "$strict" -eq 1 ] && [ "$gaps" -gt 0 ]; then
  exit 1
fi
exit 0
