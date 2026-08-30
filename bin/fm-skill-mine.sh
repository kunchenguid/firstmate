#!/usr/bin/env bash
# fm-skill-mine.sh - read-only fleet pattern miner for gnhf skill mining nights.
#
# Reads FM_HOME_DIR fleet records and writes .bench/mined.md plus compact stdout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME_DIR="${FM_HOME_DIR:-/Users/pedromuller/dev/firstmate}"
OUT_MD="${FM_SKILL_MINE_OUT:-$ROOT/.bench/mined.md}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

usage() {
  printf '%s\n' 'usage: fm-skill-mine.sh' >&2
}

json_field() {
  local line=$1 field=$2
  printf '%s' "$line" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || true
}

mine_each_jsonl() {
  local harness=$1
  shift
  local f line
  for f; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\t%s\n' "$harness" "$line"
    done <"$f"
  done
}

collect_jsonl_files() {
  local kind=$1
  case "$kind" in
    claude)
      find "$HOME/.claude/projects" -name '*.jsonl' 2>/dev/null || true
      ;;
    codex)
      find "$CODEX_HOME/sessions" -name '*.jsonl' 2>/dev/null || true
      ;;
    cursor)
      find "$HOME/.cursor/projects" -path '*/agent-transcripts/*.jsonl' 2>/dev/null || true
      ;;
  esac
}

mine_p1_raw_gh() {
  local count=0
  local -a examples=()
  local harness f sid line
  for harness in claude codex cursor; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      sid=$(basename "$f" .jsonl)
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *gh-axi*) continue ;; esac
        if printf '%s' "$line" | grep -Eq '"gh |"gh"|(^|[^-])gh '; then
          count=$((count + 1))
          [ "${#examples[@]}" -lt 3 ] && examples+=("$sid")
        fi
      done <"$f"
    done < <(collect_jsonl_files "$harness")
  done
  printf 'P1 raw-gh count=%s sessions=%s harness=claude:%s codex:%s cursor:%s scriptable=yes examples=%s\n' \
    "$count" "$count" "?" "?" "?" "$(IFS=,; printf '%s' "${examples[*]}")"
}

mine_p2_session_start() {
  local count=0
  local -a examples=()
  local f line first_cmd id
  for f in "$FM_HOME_DIR"/state/*.meta; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .meta)
    case "$id" in
      fm-*|secondmate-*) continue ;;
    esac
    first_cmd=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        cmd:*) first_cmd=${line#cmd:}; break ;;
      esac
    done <"$f"
    [ -n "$first_cmd" ] || continue
    case "$first_cmd" in
      *fm-session-start.sh*) continue ;;
    esac
    count=$((count + 1))
    [ "${#examples[@]}" -lt 3 ] && examples+=("$id")
  done
  printf 'P2 session-start-not-first count=%s sessions=%s harness=firstmate scriptable=yes examples=%s\n' \
    "$count" "$count" "$(IFS=,; printf '%s' "${examples[*]}")"
}

mine_p3_silent_exit() {
  local count=0
  local -a examples=()
  local meta status task last
  for meta in "$FM_HOME_DIR"/state/*.meta; do
    [ -f "$meta" ] || continue
    task=$(basename "$meta" .meta)
    grep -q 'telemetry_attempt.*incomplete' "$meta" 2>/dev/null || continue
    status="$FM_HOME_DIR/state/$task.status"
    if [ -f "$status" ]; then
      last=$(tail -1 "$status" 2>/dev/null || true)
      case "$last" in
        done:*|blocked:*|failed:*|paused:*) continue ;;
      esac
    fi
    count=$((count + 1))
    [ "${#examples[@]}" -lt 3 ] && examples+=("$task")
  done
  printf 'P3 silent-exit count=%s sessions=%s harness=mixed scriptable=yes examples=%s\n' \
    "$count" "$count" "$(IFS=,; printf '%s' "${examples[*]}")"
}

mine_p4_rule_negatives() {
  local summary=$FM_HOME_DIR/.backpass/evidence-summary.json
  local count=0
  local -a examples=()
  if [ ! -f "$summary" ]; then
    printf 'P4 rule-negatives count=0 sessions=0 harness=n/a scriptable=yes examples=\n'
    return
  fi
  local row id pos neg title
  while IFS= read -r row; do
    id=$(printf '%s' "$row" | jq -r '.id // empty')
    pos=$(printf '%s' "$row" | jq -r '.positives // 0')
    neg=$(printf '%s' "$row" | jq -r '.negatives // 0')
    title=$(printf '%s' "$row" | jq -r '.title // empty')
    [ -n "$id" ] || continue
    [ "$neg" -ge $((pos * 2)) ] || continue
    count=$((count + 1))
    [ "${#examples[@]}" -lt 3 ] && examples+=("$id:$title")
  done < <(jq -c '.instructions[]?' "$summary" 2>/dev/null || true)
  printf 'P4 rule-negatives count=%s sessions=%s harness=n/a scriptable=yes examples=%s\n' \
    "$count" "$count" "$(IFS=,; printf '%s' "${examples[*]}")"
}

mine_p5_skill_loads() {
  local total=0
  local harness f line skill
  for harness in codex claude cursor; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *SKILL.md*)
            skill=$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_-]+/SKILL\.md' | head -1 | sed 's|/SKILL.md||' || true)
            [ -n "$skill" ] && total=$((total + 1))
            ;;
        esac
      done <"$f"
    done < <(collect_jsonl_files "$harness")
  done
  printf 'P5 skill-loads count=%s sessions=%s harness=split scriptable=no examples=\n' "$total" "$total"
}

mine_p6_accept_by_class() {
  local ledger=$FM_HOME_DIR/data/routing-outcomes.jsonl count=0
  if [ ! -f "$ledger" ]; then
    printf 'P6 accept-by-class count=0 sessions=0 harness=split scriptable=no examples=\n'
    return
  fi
  local cutoff line d
  cutoff=$(date -u -v-14d +%Y-%m-%d 2>/dev/null || date -u -d '14 days ago' +%Y-%m-%d 2>/dev/null || printf '1970-01-01\n')
  while IFS= read -r line || [ -n "$line" ]; do
    d=$(json_field "$line" date)
    [ -n "$d" ] && [ "$d" \< "$cutoff" ] && continue
    count=$((count + 1))
  done <"$ledger"
  printf 'P6 accept-by-class count=%s sessions=%s harness=split scriptable=no examples=\n' "$count" "$count"
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    '') ;;
    *) usage; exit 2 ;;
  esac

  mkdir -p "$(dirname "$OUT_MD")"
  local p1 p2 p3 p4 p5 p6
  p1=$(mine_p1_raw_gh)
  p2=$(mine_p2_session_start)
  p3=$(mine_p3_silent_exit)
  p4=$(mine_p4_rule_negatives)
  p5=$(mine_p5_skill_loads)
  p6=$(mine_p6_accept_by_class)
  {
    printf '# Mined fleet patterns\n\n'
    printf '%s\n' "$p1" "$p2" "$p3" "$p4" "$p5" "$p6"
  } >"$OUT_MD"
  printf '%s\n' "$p1" "$p2" "$p3" "$p4" "$p5" "$p6" | head -30
}

main "$@"
