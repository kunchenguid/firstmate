#!/usr/bin/env bash
# fm-idea.sh - capture and review ideas without interrupting the current task.
#
# Usage:
#   fm-idea.sh add "<text>"
#   fm-idea.sh list [raw|cased|queued|bet|dropped]
#   fm-idea.sh triage
#   fm-idea.sh merge <triage-file> <critic-file> [<critic-file>...]
#   fm-idea.sh rule <id> bet|queue|drop [--until YYYY-MM-DD] [--why "<text>"]
#   fm-idea.sh --help
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FM_HOME=${FM_HOME:-$ROOT}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
IDEAS=$DATA/ideas.md
ARCHIVE=$DATA/ideas-archive.md

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
today() { date -u +%F; }

valid_date() { case ${1:-} in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
valid_text() {
  [ -n "$1" ] || fail 'idea text cannot be empty'
  case $1 in *$'\n'*|*$'\r'*) fail 'idea text must be one line' ;; esac
}
ensure_data() { mkdir -p "$DATA" || fail "cannot create $DATA"; }

find_line() {
  [ -f "$IDEAS" ] || return 1
  awk -v want="$1" 'BEGIN { found=0 } $2 == "[" want "]" { print; found=1; exit } END { exit !found }' "$IDEAS"
}
parse_line() {
  IDEA_DATE=${1#*] }
  IDEA_DATE=${IDEA_DATE%% *}
  IDEA_REST=${1#*] }
  IDEA_REST=${IDEA_REST#* }
  IDEA_STATE=${IDEA_REST%%:*}
  IDEA_TEXT=${IDEA_REST#*: }
}
replace_line() {
  local old=$1 new=$2 tmp
  tmp=$(mktemp "${IDEAS}.XXXXXX") || fail "cannot stage $IDEAS"
  while IFS= read -r line; do
    if [ "$line" = "$old" ]; then printf '%s\n' "$new"; else printf '%s\n' "$line"; fi
  done < "$IDEAS" > "$tmp" || { rm -f "$tmp"; fail "cannot write $IDEAS"; }
  mv "$tmp" "$IDEAS" || fail "cannot replace $IDEAS"
}
mark_state() {
  local id=$1 state=$2 line
  line=$(find_line "$id") || fail "idea $id was not found"
  parse_line "$line"
  replace_line "$line" "- [$id] $IDEA_DATE $state: $IDEA_TEXT"
}

add_idea() {
  local text=${1:-} day id
  valid_text "$text"
  ensure_data
  day=$(today)
  while :; do
    id=$(printf '%s-%s' "$day" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')")
    if ! find_line "$id" >/dev/null 2>&1; then break; fi
  done
  printf '%s\n' "- [$id] $day raw: $text" >> "$IDEAS" || fail "cannot append $IDEAS"
  printf '%s\n' "$id"
}

list_ideas() {
  local filter=${1:-}
  case "$filter" in
    '') [ -f "$IDEAS" ] && cat "$IDEAS" || true ;;
    raw|cased|queued|bet)
      [ -f "$IDEAS" ] && awk -v state="$filter" '$0 ~ " " state ": " { print }' "$IDEAS" || true ;;
    dropped)
      [ -f "$ARCHIVE" ] && awk '/ dropped: / { print }' "$ARCHIVE" || true ;;
    *) fail "unknown list filter: $filter" ;;
  esac
}

triage_ideas() {
  local day tmp_report tmp_ideas
  ensure_data
  day=$(today)
  tmp_report=$(mktemp "$DATA/.triage.XXXXXX") || fail "cannot stage triage report"
  if [ -f "$IDEAS" ]; then
    awk -v day="$day" '
    BEGIN { print "# Idea triage " day "\n" }
    $2 ~ /^\[/ && $0 ~ / raw: / {
      id=$2; sub(/^\[/, "", id); sub(/\]$/, "", id)
      text=substr($0, index($0, " raw: ") + 6)
      print "## [" id "] " text
      print "For:"
      print "Against:"
      print "Cost in minutes:"
      print "Proposal: bet|queue|drop"
      print "Reason:\n"
    }
    ' "$IDEAS" 2>/dev/null > "$tmp_report" || { rm -f "$tmp_report"; fail "cannot write triage report"; }
  else
    printf '# Idea triage %s\n\n' "$day" > "$tmp_report"
  fi
  tmp_ideas=$(mktemp "$IDEAS.XXXXXX") || { rm -f "$tmp_report"; fail "cannot stage $IDEAS"; }
  if [ -f "$IDEAS" ]; then
    awk '{ if ($0 ~ / raw: /) sub(/ raw: /, " cased: "); print }' "$IDEAS" > "$tmp_ideas" \
      || { rm -f "$tmp_report" "$tmp_ideas"; fail "cannot write $IDEAS"; }
  else
    : > "$tmp_ideas"
  fi
  mv "$tmp_report" "$DATA/ideas/triage-$day.md" 2>/dev/null || {
    mkdir -p "$DATA/ideas" || fail "cannot create $DATA/ideas"
    mv "$tmp_report" "$DATA/ideas/triage-$day.md" || fail "cannot publish triage report"
  }
  mv "$tmp_ideas" "$IDEAS" || fail "cannot publish cased ideas"
  printf '%s\n' "$DATA/ideas/triage-$day.md"
}

merge_ideas() {
  local day output records file tmp
  [ "$#" -ge 2 ] || fail 'merge requires a triage file and at least one critic file'
  for file; do [ -f "$file" ] || fail "critic file not found: $file"; done
  ensure_data
  day=$(today)
  records=$(mktemp "$DATA/.merge.XXXXXX") || fail 'cannot stage merge records'
  for file; do
    awk '
      function emit() { if (id != "" && proposal != "") print id "\t" idea "\t" proposal "\t" reason }
      /^## \[/ {
        if (id != "") emit()
        id=$0; sub(/^## \[/, "", id); sub(/\].*$/, "", id)
        idea=$0; sub(/^## \[[^]]+\] /, "", idea)
        proposal=""; reason=""
      }
      /^Proposal:/ { proposal=$0; sub(/^Proposal:[[:space:]]*/, "", proposal); proposal=tolower(proposal); sub(/[[:space:]].*$/, "", proposal); if (proposal == "bet|queue|drop") proposal=""; if (proposal == "kill") proposal="drop" }
      /^Reason:/ { reason=$0; sub(/^Reason:[[:space:]]*/, "", reason) }
      END { if (id != "") emit() }
    ' "$file" >> "$records" || { rm -f "$records"; fail "cannot read $file"; }
  done
  [ -s "$records" ] || { rm -f "$records"; fail 'critic files contain no completed proposals'; }
  awk -F '\t' '$3 !~ /^(bet|queue|drop)$/ { exit 1 }' "$records" \
    || { rm -f "$records"; fail 'critic proposal must be bet, queue, drop, or kill'; }
  output="$DATA/ideas/merge-$day.md"
  mkdir -p "$DATA/ideas" || fail "cannot create $DATA/ideas"
  tmp=$(mktemp "$output.XXXXXX") || { rm -f "$records"; fail 'cannot stage merged report'; }
  awk -F '\t' -v day="$day" '
    { if (!( $1 in seen)) { seen[$1]=1; order[++n]=$1; idea[$1]=$2 }
      p[$1, ++count[$1]]=$3; r[$1, count[$1]]=$4 }
    END {
      print "# Idea verdicts " day "\n"
      print "| ID | Idea | Proposal | Reason |"
      print "| --- | --- | --- | --- |"
      for (i=1; i<=n; i++) {
        id=order[i]; result=p[id,1]; unanimous=1
        for (j=2; j<=count[id]; j++) if (p[id,j] != result) unanimous=0
        if (!unanimous) { result="queue"; why="disagreement: " p[id,1]; for (j=2; j<=count[id]; j++) why=why " vs " p[id,j] }
        else why="unanimous " result
        gsub(/\|/, "\\|", idea[id]); gsub(/\|/, "\\|", why)
        print "| " id " | " idea[id] " | " result " | " why " |"
      }
    }
  ' "$records" > "$tmp" || { rm -f "$records" "$tmp"; fail 'cannot write merged report'; }
  rm -f "$records"
  mv "$tmp" "$output" || fail 'cannot publish merged report'
  printf '%s\n' "$output"
}

rule_idea() {
  local id=${1:-} decision=${2:-} until='' why='owner decision' line archive_tmp ideas_tmp
  shift 2 || true
  [ -n "$id" ] && [ -n "$decision" ] || fail 'rule requires <id> and bet, queue, or drop'
  case "$decision" in bet|queue|drop) ;; *) fail 'decision must be bet, queue, or drop' ;; esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --until) [ "$#" -ge 2 ] || fail '--until requires a date'; until=$2; shift 2 ;;
      --why) [ "$#" -ge 2 ] || fail '--why requires text'; why=$2; shift 2 ;;
      *) fail "unknown rule flag: $1" ;;
    esac
  done
  valid_date "$until" || [ -z "$until" ] || fail '--until must be a YYYY-MM-DD date'
  valid_text "$why"
  line=$(find_line "$id") || fail "idea $id was not found"
  parse_line "$line"
  case "$IDEA_STATE" in raw|cased) ;; *) fail "idea $id is already $IDEA_STATE" ;; esac
  ensure_data
  if [ "$decision" = drop ]; then
    archive_tmp=$(mktemp "$ARCHIVE.XXXXXX") || fail 'cannot stage archive'
    [ -f "$ARCHIVE" ] && cat "$ARCHIVE" > "$archive_tmp"
    printf '%s\n' "- [$id] $(today) dropped: $IDEA_TEXT - reason: $why" >> "$archive_tmp"
    ideas_tmp=$(mktemp "$IDEAS.XXXXXX") || { rm -f "$archive_tmp"; fail 'cannot stage ideas'; }
    while IFS= read -r current; do [ "$current" = "$line" ] || printf '%s\n' "$current"; done < "$IDEAS" > "$ideas_tmp"
    mv "$archive_tmp" "$ARCHIVE" || fail 'cannot publish archive'
    mv "$ideas_tmp" "$IDEAS" || fail 'cannot remove dropped idea'
    return 0
  fi
  (cd "$FM_HOME" && tasks-axi add "$id" "$IDEA_TEXT" --kind ship --repo firstmate >/dev/null) \
    || fail "could not add idea $id to the backlog"
  if [ "$decision" = queue ]; then
    if [ -n "$until" ]; then
      "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason 'queued idea' --until "$until" >/dev/null \
        || fail "could not queue idea $id"
    else
      "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason 'queued idea' >/dev/null \
        || fail "could not queue idea $id"
    fi
  fi
  [ "$decision" != queue ] || decision=queued
  mark_state "$id" "$decision"
}

help_text() {
  cat <<'EOF'
Usage: fm-idea.sh <verb> [arguments]
  add "<text>"                         Capture one idea and print its id. Example: fm-idea.sh add "Try a new cache."
  list [raw|cased|queued|bet|dropped]  List ideas, optionally filtered by state. Example: fm-idea.sh list raw
  triage                               Create a blank case report and mark raw ideas cased. Example: fm-idea.sh triage
  merge <triage> <critic> [<critic>]   Merge critic proposals into one table. Example: fm-idea.sh merge data/ideas/triage-2026-09-11.md critic-a.md critic-b.md
  rule <id> bet|queue|drop             Record a decision; use --until DATE and --why "TEXT" as needed. Example: fm-idea.sh rule 2026-09-11-ab12 queue --until 2026-10-01
  -h, --help                           Show this help.
Flags: --until YYYY-MM-DD sets a queue resurface date; --why "TEXT" records a drop reason.
EOF
}

case ${1:-} in
  -h|--help) help_text ;;
  add) shift; [ "$#" -eq 1 ] || fail 'add requires exactly one text argument'; add_idea "$1" ;;
  list) shift; [ "$#" -le 1 ] || fail 'list accepts at most one filter'; list_ideas "${1:-}" ;;
  triage) shift; [ "$#" -eq 0 ] || fail 'triage takes no arguments'; triage_ideas ;;
  merge) shift; merge_ideas "$@" ;;
  rule) shift; rule_idea "$@" ;;
  '') help_text; exit 1 ;;
  *) fail "unknown verb: $1" ;;
esac
