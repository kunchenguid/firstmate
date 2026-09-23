#!/usr/bin/env bash
# fm-jev-act-first.sh - advisory Jev ranking of what to act on first at startup.
#
# Usage:
#   fm-jev-act-first.sh --drain-file <path> [--status-dir <dir>] [--local]
#
# Two production callers, both fed the wake-drain output of one locked session
# start. bin/fm-session-start.sh runs --local, which never calls Jev or the
# network: it prints the items below in their fixed priority order as the
# digest's ACT FIRST section right after the wake queue. The deferred startup
# network stage (bin/fm-startup-network.sh) runs the Jev ranking off the
# digest's blocking path and reports it with its other deferred checks. It is
# advisory only: it never acknowledges a wake, answers a decision, steers,
# dispatches, or edits any record, and every item it ranks is already part of
# this digest.
#
# Items (no model call), in this order, at most 12, each capped to 160
# characters:
#   decision   every line of the drain's OPEN DECISIONS section
#   outcome    every item of STATUS OUTCOME BACKSTOP
#   divergence every item of RECORD DIVERGENCE
#   execution  every task/owner/next-action row of UNFINISHED EXECUTION
#   unread     every line of the drain's UNREAD STATUS section
#   status     the newest line of each state/<id>.status in --status-dir whose
#              task still has state/<id>.meta, when that line is failed: or
#              blocked:
#   wake       every raw wake record (epoch, seq, kind, key, payload)
# One task in one state is one item: a blocker that appears as an open
# decision, a status line, and a status wake is kept once, as its
# highest-priority form. Task-level status pointers, including coalesced path
# lists, are omitted when that task has a detailed decision, outcome, unread
# status item, or live failed/blocked status tail.
# Distinct open-decision keys remain
# separate actions.
# Fewer than two items makes no call: there is nothing to rank.
#
# What Jev sees (one Choice call through bin/fm-jev-lib.sh): the items above,
# each sanitized by fm_jev_compact_state, as criteria keyed i1..iN. The Choice
# probabilities are the ranking; malformed probabilities fall back to the
# single pick. No status log body, brief, report, or backlog body is sent.
#
# Output (stdout): at most five lines. --local prints `<rank>. <item>` in the
# priority order above whenever there are at least two items. Otherwise, only
# on a usable Jev answer, `<rank>. <item> (p=<probability>)`, and nothing at all
# when Jev is off (no key), the call fails, or the answer is malformed. Fewer
# than two items prints nothing in either mode, so a caller can print a section
# only when this helper printed something. The caller owns the time bound;
# JEV_TIMEOUT is used as given. Exit 0 except usage (exit 2).
#
# Log: one JSONL object per attempted call appended to
# ${FM_STATE_OVERRIDE:-$FM_HOME/state}/jev-act-first.jsonl with
# purpose=act-first, advisory=true, item_count, offered item kinds, choice,
# confidence, ranked item keys, route, http, latency_ms, decide_code, ts.
# Secrets follow fm_jev_log_call redaction.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, plus the Jev library keys and
# JEV_* settings documented in bin/fm-jev-lib.sh. This script does not roll
# its own HTTP.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'jev-act-first: %s\n' "$1" >&2
  exit 2
}

DRAIN_FILE=
STATUS_DIR=
LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --drain-file) [ $# -ge 2 ] || die "--drain-file needs a path"; DRAIN_FILE=$2; shift 2 ;;
    --status-dir) [ $# -ge 2 ] || die "--status-dir needs a path"; STATUS_DIR=$2; shift 2 ;;
    --local) LOCAL=1; shift ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[ -n "$DRAIN_FILE" ] || die "usage: fm-jev-act-first.sh --drain-file <path> [--status-dir <dir>]"
[ -r "$DRAIN_FILE" ] || die "drain file is not readable: $DRAIN_FILE"

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG_PATH="$STATE_DIR/jev-act-first.jsonl"
ITEM_MAX=12
ITEM_CHARS=160
SHOW_MAX=5

command -v jq >/dev/null 2>&1 || exit 0

# Drain items as kind<TAB>identity<TAB>text, grouped decision, recovery,
# execution, wake. The identity is task|state where the line names both, so one
# task in one state collapses to its first (highest-priority) item; otherwise
# it is the text.
drain_items() {
  awk -F '\t' '
    /^OPEN DECISIONS \(/ { sec = "decision"; next }
    /^OPEN DECISIONS:/ { sec = ""; next }
    /^STATUS OUTCOME BACKSTOP \(/ { sec = "outcome"; next }
    /^UNREAD STATUS \(/ { sec = "unread"; next }
    /^RECORD DIVERGENCE \(/ { sec = "divergence"; next }
    /^UNFINISHED EXECUTION \(/ { sec = "execution"; next }
    /^[A-Z][A-Z ]+[ (:]/ && $0 !~ /\t/ { sec = ""; next }
    function corr_token(s) { return length(s) == 21 && s ~ /^corr=[A-Fa-f0-9]+$/ }
    function strip_corr_tokens(s, words, count, i, normalized) {
      if (s !~ /corr=/) return s
      count = split(s, words, /[[:space:]]+/)
      normalized = words[1]
      for (i = 2; i <= count; i++) if (!corr_token(words[i])) normalized = normalized " " words[i]
      return normalized
    }
    function verb(s) {
      sub(/^\[[^]]*\][[:space:]]*/, "", s)
      sub(/[[:space:]]*(\[|:).*$/, "", s)
      return strip_corr_tokens(s)
    }
    function status_event(s, prefix) {
      prefix = s
      if (!sub(/:.*/, "", prefix)) return 0
      prefix = strip_corr_tokens(prefix)
      return prefix ~ /^[a-z-]+( \[[^]]*\])?$/
    }
    function event_key(s, prefix, note, key) {
      prefix = s
      sub(/:.*/, "", prefix)
      if (index(prefix, "[key=") > 0) {
        if (match(prefix, /\[key=[^]]+\]/)) {
          key = substr(prefix, RSTART, RLENGTH)
          sub(/^\[key=/, "", key)
          sub(/\]$/, "", key)
          if (key ~ /^[A-Za-z0-9._-]+$/) return key
        }
        return "default"
      }
      note = s
      if (sub(/^[^:]*:[[:space:]]*/, "", note) && match(note, /^\[key=[^]]+\]/)) {
        key = substr(note, RSTART, RLENGTH)
        sub(/^\[key=/, "", key)
        sub(/\]$/, "", key)
        if (key ~ /^[A-Za-z0-9._-]+$/) return key
      }
      return "default"
    }
    function event_identity(task, s) { return task "|" event_key(s) "|" verb(s) }
    function status_task(path) { sub(/^.*\//, "", path); sub(/\.status$/, "", path); return path }
    FILENAME == "-" && $1 == "status" && NF >= 3 {
      status_items[++ns] = $0
      detail_task = $2
      sub(/\|.*/, "", detail_task)
      detailed_task[detail_task] = 1
      next
    }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && NF >= 5 {
      p = $5
      for (i = 6; i <= NF; i++) p = p " " $i
      wake[++nw] = "wake " $3 " " $4 (p == "" ? "" : ": " p)
      wid[nw] = wake[nw]
      if ($3 == "signal" && $4 ~ /\.status$/ && p ~ /^(signal|needs-decision):/) {
        pointer_paths = p
        sub(/^[^:]+:[[:space:]]*/, "", pointer_paths)
        pointer_count = split(pointer_paths, pointer_path_list, /[[:space:]]+/)
        pointer_valid = pointer_count > 0
        pointer_contains_wake = 0
        wake_task = status_task($4)
        for (j = 1; j <= pointer_count; j++) {
          if (pointer_path_list[j] !~ /\.status$/) pointer_valid = 0
          if (status_task(pointer_path_list[j]) == wake_task) pointer_contains_wake = 1
        }
        if (pointer_valid && pointer_contains_wake) {
          wid[nw] = event_identity(wake_task, p)
          wake_is_pointer[nw] = 1
          wake_pointer_task[nw] = wake_task
        }
      }
      if (!wake_is_pointer[nw] && $3 == "signal" && $4 ~ /\.status$/ && status_event(p)) {
        t = status_task($4)
        wid[nw] = event_identity(t, p)
      }
      next
    }
    sec == "decision" && NF == 1 && $0 != "" {
      dec[++nd] = "decision " $0
      rest = $0
      sub(/^[^ ]+ /, "", rest)
      decision_task = $0
      sub(/ .*/, "", decision_task)
      did[nd] = event_identity(decision_task, rest)
      detailed_task[decision_task] = 1
      next
    }
    sec == "outcome" && NF == 1 && $0 != "" {
      outcome[++no] = "status outcome " $0
      outcome_task = $0
      sub(/ .*/, "", outcome_task)
      outcome_event = $0
      sub(/^[^ ]+ /, "", outcome_event)
      oid[no] = event_identity(outcome_task, outcome_event)
      detailed_task[outcome_task] = 1
      next
    }
    sec == "divergence" && NF == 1 && $0 != "" {
      divergence[++nv] = "record divergence " $0
      vid[nv] = "divergence|" $0
      next
    }
    sec == "execution" && NF == 3 { exe[++ne] = "execution " $1 " owner=" $2 " next=" $3; eid[ne] = exe[ne]; next }
    sec == "unread" && $0 != "" {
      unread[++nu] = "unread status " $0
      uid[nu] = "unread|" $0
      unread_task = $0
      sub(/[[:space:]].*$/, "", unread_task)
      if (unread_task != "") detailed_task[unread_task] = 1
      next
    }
    END {
      for (i = 1; i <= nd; i++) print "decision\t" did[i] "\t" dec[i]
      for (i = 1; i <= no; i++) print "outcome\t" oid[i] "\t" outcome[i]
      for (i = 1; i <= nv; i++) print "divergence\t" vid[i] "\t" divergence[i]
      for (i = 1; i <= ne; i++) print "execution\t" eid[i] "\t" exe[i]
      for (i = 1; i <= nu; i++) print "unread\t" uid[i] "\t" unread[i]
      for (i = 1; i <= ns; i++) print status_items[i]
      for (i = 1; i <= nw; i++) {
        if (wake_is_pointer[i] && detailed_task[wake_pointer_task[i]]) continue
        print "wake\t" wid[i] "\t" wake[i]
      }
    }
  ' "$DRAIN_FILE" - < <(status_items)
}

# Newest failed:/blocked: line of each live task's status log.
status_item_key() {
  local line=$1 prefix note key=default
  prefix=${line%%:*}
  case "$prefix" in
    *'[key='*) key=${prefix#*'[key='}; key=${key%%]*} ;;
    *)
      case "$line" in
        *:*) note=${line#*:}; note=${note#"${note%%[![:space:]]*}"} ;;
        *) note= ;;
      esac
      case "$note" in
        '[key='*) key=${note#'[key='}; key=${key%%]*} ;;
      esac
      ;;
  esac
  case "$key" in ''|*[!A-Za-z0-9._-]*) key=default ;; esac
  printf '%s' "$key"
}

status_items() {
  local status task meta last key
  [ -n "$STATUS_DIR" ] && [ -d "$STATUS_DIR" ] || return 0
  for status in "$STATUS_DIR"/*.status; do
    [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ] || continue
    task=${status##*/}
    task=${task%.status}
    meta=$STATUS_DIR/$task.meta
    [ -f "$meta" ] && [ -r "$meta" ] && [ ! -L "$meta" ] || continue
    last=$(tail -n 1 "$status" 2>/dev/null | tr '\t' ' ')
    key=$(status_item_key "$last")
    case "$last" in
      failed:*|failed\ \[*) printf 'status\t%s|%s|failed\tstatus %s %s\n' "$task" "$key" "$task" "$last" ;;
      blocked:*|blocked\ \[*) printf 'status\t%s|%s|blocked\tstatus %s %s\n' "$task" "$key" "$task" "$last" ;;
    esac
  done
}

items='[]'
n=0
seen_ids=$'\n'
while IFS=$(printf '\t') read -r kind identity text; do
  [ -n "$text" ] || continue
  case "$seen_ids" in
    *$'\n'"$identity"$'\n'*) continue ;;
  esac
  seen_ids="$seen_ids$identity"$'\n'
  if [ "$LOCAL" -eq 0 ]; then
    text=$(fm_jev_compact_state "$text") || continue
  fi
  text=${text:0:$ITEM_CHARS}
  if jq -e --arg t "$text" 'any(.[]; .text == $t)' <<<"$items" >/dev/null 2>&1; then
    continue
  fi
  n=$((n + 1))
  items=$(jq -c --arg k "i$n" --arg kind "$kind" --arg t "$text" '. + [{key: $k, kind: $kind, text: $t}]' <<<"$items") || exit 0
  [ "$n" -lt "$ITEM_MAX" ] || break
done < <(drain_items)
[ "$n" -ge 2 ] || exit 0
if [ "$LOCAL" -eq 1 ]; then
  jq -r --argjson max "$SHOW_MAX" '.[:$max] | to_entries[] | "\(.key + 1). \(.value.text)"' <<<"$items"
  exit 0
fi
fm_jev_key_configured || exit 0

state=$(fm_jev_compact_state "$(jq -r '"Actionable items a Firstmate supervisor sees at session start:", (.[] | "\(.key): \(.text)")' <<<"$items")") || exit 0
questions=$(jq -nc --argjson c "$(jq -c 'map({key: .key, value: .text}) | from_entries' <<<"$items")" '{
  first: {
    type: "choice",
    instructions: "Which item should the supervisor act on first? Rank by urgency and by how much other work waits on it: an open captain decision, a failure, or a blocker before routine progress and heartbeat wakes.",
    criteria: $c
  }
}') || exit 0

decide_code=0
mkdir -p "$STATE_DIR" 2>/dev/null || true
response=
if response_file=$(mktemp "$STATE_DIR/.jev-act-first-response.XXXXXX" 2>/dev/null); then
  fm_jev_decide "$state" "$questions" > "$response_file" || decide_code=$?
  response=$(cat "$response_file" 2>/dev/null)
  rm -f "$response_file"
else
  decide_code=2
fi

choice=
confidence=
ranked='[]'
if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  choice=$(jq -r '.answers.first.choice // empty' <<<"$response" 2>/dev/null)
  confidence=$(jq -r '.answers.first.confidence | select(type == "number") // empty' <<<"$response" 2>/dev/null)
  if [ -n "$choice" ] && jq -e --arg c "$choice" 'any(.[]; .key == $c)' <<<"$items" >/dev/null 2>&1; then
    probs=$(jq -c '.answers.first.probabilities // empty' <<<"$response" 2>/dev/null)
    if [ -n "$probs" ] && fm_jev_probabilities_sum_ok "$probs" \
      && jq -en --argjson p "$probs" --argjson items "$items" \
        'all($p | keys[]; . as $key | any($items[]; .key == $key))' >/dev/null 2>&1; then
      ranked=$(jq -c --argjson p "$probs" '
        map(. + {p: ($p[.key] // 0)}) | map(select(.p > 0)) | sort_by(-.p)
      ' <<<"$items")
    elif [ -n "$confidence" ] && fm_jev_choice_confidence_ok "$confidence" 0; then
      ranked=$(jq -c --arg c "$choice" --arg conf "$confidence" \
        'map(select(.key == $c) | . + {p: ($conf | tonumber)})' <<<"$items")
    fi
  fi
fi

payload=$(jq -nc \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)" \
  --arg choice "$choice" \
  --arg confidence "$confidence" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg http "${FM_JEV_LAST_HTTP:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  --argjson kinds "$(jq -c '[.[].kind]' <<<"$items")" \
  --argjson ranked "$(jq -c '[.[:5][].key]' <<<"$ranked")" \
  --argjson decide_code "$decide_code" \
  '{
    purpose: "act-first",
    advisory: true,
    item_count: ($kinds | length),
    item_kinds: $kinds,
    choice: (if $choice == "" then null else $choice end),
    confidence: (try ($confidence | tonumber) catch null),
    ranked_keys: $ranked,
    route: $route,
    http: $http,
    latency_ms: (try ($latency | tonumber) catch null),
    decide_code: $decide_code,
    ts: $ts
  }' 2>/dev/null) && fm_jev_log_call "$payload" "$LOG_PATH" || true

jq -r --argjson max "$SHOW_MAX" '
  .[:$max] | to_entries[] | "\(.key + 1). \(.value.text) (p=\(.value.p))"
' <<<"$ranked"
exit 0
