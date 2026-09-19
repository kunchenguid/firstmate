#!/usr/bin/env bash
# Opt-in cache-aware park-not-delete compaction for crew harness traces.
#
# Usage:
#   bin/fm-jev-compaction.sh --task <id> --trace <file> [--out <file>]
#                            [--park-dir <dir>] [--threshold <n>]
#                            [--scores <file>] [--cache-busted]
#
# This file owns the helper. It is not wired into spawn or firstmate
# supervisor core. Crew harnesses invoke it explicitly.
#
# Enablement (default OFF):
#   - no-op exit 0 when FM_JEV_COMPACTION is off/0/false, or when it is
#     unset and $FM_HOME/config/jev-compaction is absent
#   - run when FM_JEV_COMPACTION is on/1/true, or when that presence-flag
#     file exists and FM_JEV_COMPACTION is not off
#
# Scoring uses a Jev Score keep_value question through bin/fm-jev-lib.sh
# unless --scores supplies a JSON object of segment id -> keep_value.
#
# Park policy: copy low keep_value segments under
# $FM_HOME/state/<id>/trace-park/ (files plus index.jsonl) and omit them
# from the live trace output. The default never drops a middle message,
# because that busts the provider KV cache; only a trailing run of
# low-value segments is parked. Pass --cache-busted only when the cache
# is already invalid (model switch or idle return) to park middle
# low-value segments as well. The first segment is always kept so the
# active prompt prefix stays stable when possible.
#
# Does not touch stow or the startup-memory budget.
#
# Environment: FM_HOME, FM_JEV_COMPACTION, FM_JEV_COMPACTION_THRESHOLD.
set -euo pipefail

_FM_JEV_COMPACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FM_JEV_COMPACTION_ROOT="$(cd "$_FM_JEV_COMPACTION_DIR/.." && pwd)"

FM_JEV_COMPACTION_THRESHOLD_DEFAULT='0.5'
FM_JEV_COMPACTION_KEEP_ANCHOR=1

fm_jev_compaction_usage() {
  cat <<'EOF'
Usage: bin/fm-jev-compaction.sh --task <id> --trace <file> [options]

Park low Jev keep_value crew-harness trace segments to disk. Default is
off. Does not delete middle messages (provider KV cache stays valid for
the kept prefix). Full live-trace rewrite of middle segments only with
--cache-busted, when the cache is already busted.

Options:
  --task <id>         Task id; park dir $FM_HOME/state/<id>/trace-park
  --trace <file>      JSONL trace (one segment object per line)
  --out <file>        Compacted trace (default: stdout)
  --park-dir <dir>    Override park directory
  --threshold <n>     Park when keep_value < n (default 0.5)
  --scores <file>     JSON object of segment id -> keep_value (skip Jev)
  --cache-busted      Allow parking middle low-value segments
  -h, --help          Show this help

EOF
}

fm_jev_compaction_opted_in() {
  local v="${FM_JEV_COMPACTION:-}"
  case "$v" in
    off|OFF|0|false|FALSE|no|NO)
      return 1
      ;;
    on|ON|1|true|TRUE|yes|YES)
      return 0
      ;;
    '')
      if [ -n "${FM_HOME:-}" ] && [ -e "$FM_HOME/config/jev-compaction" ]; then
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

fm_jev_compaction_lt() {
  jq -ne --argjson a "$1" --argjson b "$2" '$a < $b' >/dev/null
}

fm_jev_compaction_sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64
}

fm_jev_compaction_score_jev() {
  local state="$1"
  local compact questions resp score
  if ! compact="$(fm_jev_compact_state "$state")"; then
    compact="$state"
  fi
  questions='{"keep_value":{"type":"score","instructions":"Keep-value of this crew-harness trace segment for the live prompt. 1 means must keep. 0 means safe to park on disk.","min":0,"max":1}}'
  resp="$(fm_jev_decide "$compact" "$questions")" || return 1
  score="$(printf '%s' "$resp" | jq -r '.answers.keep_value.score // .answers.keep_value.value // empty')"
  if [ -z "$score" ] || [ "$score" = "null" ]; then
    printf '1\n'
    return 0
  fi
  printf '%s\n' "$score"
}

fm_jev_compaction_score_of() {
  local id="$1" line="$2"
  local score
  if [ -n "$SCORES_FILE" ]; then
    score="$(jq -r --arg id "$id" '(.[$id] // 1) | tostring' "$SCORES_FILE")"
    printf '%s\n' "$score"
    return 0
  fi
  fm_jev_compaction_score_jev "$line"
}

# --- argv ---
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  fm_jev_compaction_usage
  exit 0
fi

if ! fm_jev_compaction_opted_in; then
  exit 0
fi

TASK_ID=""
TRACE=""
OUT=""
PARK_DIR=""
SCORES_FILE=""
CACHE_BUSTED=0
THRESHOLD="${FM_JEV_COMPACTION_THRESHOLD:-$FM_JEV_COMPACTION_THRESHOLD_DEFAULT}"

while [ $# -gt 0 ]; do
  case "$1" in
    --task)
      TASK_ID="${2:-}"
      shift 2
      ;;
    --trace)
      TRACE="${2:-}"
      shift 2
      ;;
    --out)
      OUT="${2:-}"
      shift 2
      ;;
    --park-dir)
      PARK_DIR="${2:-}"
      shift 2
      ;;
    --threshold)
      THRESHOLD="${2:-}"
      shift 2
      ;;
    --scores)
      SCORES_FILE="${2:-}"
      shift 2
      ;;
    --cache-busted)
      CACHE_BUSTED=1
      shift
      ;;
    -h|--help)
      fm_jev_compaction_usage
      exit 0
      ;;
    *)
      printf 'fm-jev-compaction.sh: unknown argument: %s\n' "$1" >&2
      fm_jev_compaction_usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$TRACE" ]; then
  printf 'fm-jev-compaction.sh: --trace is required when compaction is on\n' >&2
  exit 2
fi
if [ ! -f "$TRACE" ]; then
  printf 'fm-jev-compaction.sh: trace not found: %s\n' "$TRACE" >&2
  exit 2
fi
if [ -z "$PARK_DIR" ]; then
  if [ -z "$TASK_ID" ] || [ -z "${FM_HOME:-}" ]; then
    printf 'fm-jev-compaction.sh: --task and FM_HOME, or --park-dir, required\n' >&2
    exit 2
  fi
  PARK_DIR="$FM_HOME/state/$TASK_ID/trace-park"
fi
if ! jq -ne --argjson t "$THRESHOLD" '$t | type == "number"' >/dev/null 2>&1; then
  printf 'fm-jev-compaction.sh: threshold must be a number\n' >&2
  exit 2
fi
if [ -n "$SCORES_FILE" ] && [ ! -f "$SCORES_FILE" ]; then
  printf 'fm-jev-compaction.sh: scores file not found: %s\n' "$SCORES_FILE" >&2
  exit 2
fi

if [ -z "$SCORES_FILE" ]; then
  # shellcheck source=bin/fm-jev-lib.sh
  . "$_FM_JEV_COMPACTION_DIR/fm-jev-lib.sh"
fi

lines=()
ids=()
scores=()
idx=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  if ! printf '%s\n' "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'fm-jev-compaction.sh: trace line %s is not a JSON object\n' "$idx" >&2
    exit 2
  fi
  id="$(printf '%s\n' "$line" | jq -r '.id // empty')"
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    id="seg-$idx"
  fi
  score="$(fm_jev_compaction_score_of "$id" "$line")" || {
    printf 'fm-jev-compaction.sh: failed to score segment %s\n' "$id" >&2
    exit 1
  }
  if ! jq -ne --argjson s "$score" '$s | type == "number"' >/dev/null 2>&1; then
    printf 'fm-jev-compaction.sh: keep_value for %s is not a number\n' "$id" >&2
    exit 1
  fi
  lines+=("$line")
  ids+=("$id")
  scores+=("$score")
  idx=$((idx + 1))
done < "$TRACE"

n=${#lines[@]}
park_flags=()
i=0
while [ "$i" -lt "$n" ]; do
  park_flags+=("0")
  i=$((i + 1))
done

if [ "$n" -gt 0 ]; then
  if [ "$CACHE_BUSTED" -eq 1 ]; then
    i=$FM_JEV_COMPACTION_KEEP_ANCHOR
    while [ "$i" -lt "$n" ]; do
      if fm_jev_compaction_lt "${scores[$i]}" "$THRESHOLD"; then
        park_flags[i]=1
      fi
      i=$((i + 1))
    done
  else
    i=$((n - 1))
    while [ "$i" -ge "$FM_JEV_COMPACTION_KEEP_ANCHOR" ]; do
      if fm_jev_compaction_lt "${scores[$i]}" "$THRESHOLD"; then
        park_flags[i]=1
        i=$((i - 1))
        continue
      fi
      break
    done
  fi
fi

parked=0
seq=0
kept_out=""
if [ -n "$OUT" ]; then
  kept_out="$(mktemp "${TMPDIR:-/tmp}/fm-jev-compaction.XXXXXX")"
  trap 'rm -f "$kept_out"' EXIT
fi

emit_kept() {
  if [ -n "$OUT" ]; then
    printf '%s\n' "$1" >> "$kept_out"
  else
    printf '%s\n' "$1"
  fi
}

i=0
while [ "$i" -lt "$n" ]; do
  if [ "${park_flags[$i]}" -eq 1 ]; then
    if [ "$parked" -eq 0 ]; then
      mkdir -p "$PARK_DIR"
    fi
    seq=$((seq + 1))
    parked=$((parked + 1))
    safe="$(fm_jev_compaction_sanitize_id "${ids[$i]}")"
    fname="$(printf '%04d-%s.json' "$seq" "$safe")"
    printf '%s\n' "${lines[$i]}" > "$PARK_DIR/$fname"
    mode="suffix"
    if [ "$CACHE_BUSTED" -eq 1 ]; then
      mode="cache-busted"
    fi
    jq -nc \
      --argjson seq "$seq" \
      --arg id "${ids[$i]}" \
      --argjson keep_value "${scores[$i]}" \
      --arg file "$fname" \
      --arg mode "$mode" \
      '{seq:$seq,id:$id,keep_value:$keep_value,file:$file,mode:$mode}' \
      >> "$PARK_DIR/index.jsonl"
  else
    emit_kept "${lines[$i]}"
  fi
  i=$((i + 1))
done

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  cat "$kept_out" > "$OUT"
  rm -f "$kept_out"
  trap - EXIT
fi

exit 0
