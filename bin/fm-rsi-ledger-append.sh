#!/usr/bin/env bash
# Append one firstmate-observed RSI event to FM_HOME/data/rsi-events.jsonl.
#
# Usage: fm-rsi-ledger-append.sh <job> <project> <candidate-sha|-> <kind>
#        <ok|fail|pending|n/a> <evidence-locator> [short-note]
#
# Firstmate is the sole policy-authorized writer. Workers report claims through
# their status files and never invoke this helper. The helper appends exactly
# one JSON object and never edits or removes an existing ledger row.
set -euo pipefail

usage() {
  sed -n '2,10{s/^# \{0,1\}//;p;}' "$0"
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi

[ "$#" -ge 6 ] && [ "$#" -le 7 ] || {
  printf 'usage: %s <job> <project> <candidate-sha|-> <kind> <result> <evidence-locator> [short-note]\n' "${0##*/}" >&2
  exit 2
}

job=$1
project=$2
candidate_sha=$3
kind=$4
result=$5
evidence=$6
note=${7:-}

case "$candidate_sha" in
  -) candidate_sha= ;;
  *)
    case "$candidate_sha" in
      *[!0123456789abcdef]*) printf 'fm-rsi-ledger-append: candidate SHA must be lowercase hexadecimal or -\n' >&2; exit 2 ;;
    esac
    [ "${#candidate_sha}" -ge 40 ] && [ "${#candidate_sha}" -le 64 ] || {
      printf 'fm-rsi-ledger-append: candidate SHA must be 40 to 64 characters or -\n' >&2
      exit 2
    }
    ;;
esac
case "$kind" in
  spawned|claimed_impl|validation_started|validation_gate|merged|prod_probe|prod_verified|merged_not_verified|rollback|failed|note) ;;
  *) printf 'fm-rsi-ledger-append: unsupported event kind: %s\n' "$kind" >&2; exit 2 ;;
esac
case "$result" in
  ok|fail|pending|n/a) ;;
  *) printf 'fm-rsi-ledger-append: unsupported result: %s\n' "$result" >&2; exit 2 ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fm_root=$(cd "$script_dir/.." && pwd)
fm_home=${FM_HOME:-$fm_root}
case "$fm_home" in
  /*) ;;
  *) fm_home=$(CDPATH='' cd -- "$fm_home" && pwd -P) ;;
esac
ledger=${FM_RSI_LEDGER_PATH:-$fm_home/data/rsi-events.jsonl}
mkdir -p "$(dirname "$ledger")"

event=$(jq -cn \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg job "$job" \
  --arg project "$project" \
  --arg candidate_sha "$candidate_sha" \
  --arg kind "$kind" \
  --arg result "$result" \
  --arg evidence "$evidence" \
  --arg observer firstmate \
  --arg note "$note" \
  '{ts: $ts, job: $job, project: $project, candidate_sha: $candidate_sha, kind: $kind, result: $result, evidence: $evidence, observer: $observer, note: $note}')
printf '%s\n' "$event" >> "$ledger"
printf '%s\n' "$event"
