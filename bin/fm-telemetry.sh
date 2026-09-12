#!/usr/bin/env bash
# fm-telemetry.sh - inspect private lifecycle telemetry.
#
# Usage:
#   fm-telemetry.sh tail <lifecycle|checks|liveness> [n]
#   fm-telemetry.sh stats <lifecycle|checks|liveness> --since 24h
#   fm-telemetry.sh scorecard
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
# shellcheck source=bin/fm-telemetry-lib.sh
. "$SCRIPT_DIR/fm-telemetry-lib.sh"

usage() { sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

stream_path() {
  fm_telemetry_stream_valid "$1" || return 1
  printf '%s/%s.jsonl\n' "$(fm_telemetry_data_dir)" "$1"
}

cmd_tail() {
  local stream=$1 n=${2:-20} file
  case "$n" in ''|*[!0-9]*) echo 'error: tail count must be a non-negative integer' >&2; return 2 ;; esac
  file=$(stream_path "$stream") || { echo 'error: invalid telemetry stream' >&2; return 2; }
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  tail -n "$n" "$file"
}

cmd_stats() {
  local stream=$1 since=$2 file now cutoff
  local -a files=()
  [ "$since" = --since ] && [ "${3:-}" = 24h ] || {
    echo 'error: stats requires --since 24h' >&2
    return 2
  }
  file=$(stream_path "$stream") || { echo 'error: invalid telemetry stream' >&2; return 2; }
  for file in "$file" "$file.1" "$file.2"; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  now=$(fm_telemetry_now_ms)
  cutoff=$((now - 86400000))
  # p90 uses nearest-rank, the conservative percentile for small operational samples.
  jq -s --argjson cutoff "$cutoff" '
    map(select(type=="object" and (.ts|type=="number") and .ts >= $cutoff))
    | map(select((.elapsedMs // .durationMs // .totalMs // .wallMs // .elapsed) | type == "number"))
    | group_by(.op) | map(sort_by(.elapsedMs // .durationMs // .totalMs // .wallMs // .elapsed)
      | . as $rows | ($rows | map(.elapsedMs // .durationMs // .totalMs // .wallMs // .elapsed)) as $v
      | ($v|length) as $n
      | {op:($rows[0].op // "unknown"),count:$n,
         median:(if $n % 2 == 1 then $v[($n/2)|floor] else (($v[($n/2)-1]+$v[$n/2])/2) end),
         p90:$v[((($n*90)+99)/100-1)|floor]})
  ' "${files[@]}"
}

scorecard_stream() {
  case "$1" in
    K1|K2|K3|K4|K5|K6|K12) printf lifecycle ;;
    K7|K10) printf checks ;;
    K8|K9|K13) printf liveness ;;
    *) printf lifecycle ;;
  esac
}

scorecard_status() { # <key> <stream-path>
  if [ "$1" = K2 ]; then
    jq -e 'select(.op == "wake-drain" and .actor == "present" and (.mode == "main" or .mode == "branch") and (.foldMs | type == "number" and . > 0))' "$2" >/dev/null 2>&1 \
      && printf measured || printf unmeasured
  elif [ -s "$2" ] && [ ! -L "$2" ]; then
    printf measured
  else
    printf unmeasured
  fi
}

cmd_scorecard() {
  local scorecard="$DATA/stability-scorecard-2026-09-11.md" line key stream file status
  if [ -f "$scorecard" ] && [ ! -L "$scorecard" ]; then
    while IFS= read -r line; do
      key=$(printf '%s\n' "$line" | sed -n 's/^\(K[0-9][0-9]*\)\([^:]*\):.*/\1/p')
      case "$key" in K1|K2|K3|K4|K5|K6|K7|K8|K9|K10|K12|K13) ;; *) continue ;; esac
      stream=$(scorecard_stream "$key")
      file=$(stream_path "$stream")
      status=$(scorecard_status "$key" "$file")
      printf '%s%s | telemetry=%s\n' "$key" "${line#"$key"}" "$status"
    done < "$scorecard"
  else
    for key in K1 K2 K3 K4 K5 K6 K7 K8 K9 K10 K12 K13; do
      stream=$(scorecard_stream "$key")
      file=$(stream_path "$stream")
      status=$(scorecard_status "$key" "$file")
      printf '%s: %s\n' "$key" "$status"
    done
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage; exit 0 ;;
  tail) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }; cmd_tail "$2" "${3:-20}" ;;
  stats) [ "$#" -eq 4 ] || { usage >&2; exit 2; }; cmd_stats "$2" "$3" "$4" ;;
  scorecard) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; cmd_scorecard ;;
  *) echo "error: unknown telemetry command: $1" >&2; usage >&2; exit 2 ;;
esac
