#!/usr/bin/env bash
# fm-focus.sh - the one owner of the captain's opt-in project focus window and
# of the held-delivery obligations it creates.
#
# OPT-IN AND OFF BY DEFAULT. A focus window exists only after the captain sets
# one (the /focus skill runs `set`); with no record every command below behaves
# as if the feature did not exist: route always says deliver, drain-section and
# held print nothing, and status says off.
#
# WHAT IT CHANGES. Only WHEN a non-urgent captain-facing outcome from a project
# outside the focus reaches the captain, never WHETHER it does. While a window
# is set, main asks `route` before telling the captain about an outcome; route
# holds a review-ready, completion, or decision outcome whose project is known
# and outside the focus, and says deliver for everything else. The urgent
# classes - failure, security, credential, blocking - are delivered
# unconditionally, whatever the window says, and so is any outcome whose
# project cannot be established from structured records. Holding never touches
# the underlying task, decision, or PR: bin/fm-bearings-snapshot.sh still lists
# every held item's decision or work in its own section and adds the held
# obligations themselves as `focus`, so nothing is hidden from the digest or
# the board while the window is set.
#
# RECORDS (durable, under the home's state/, never chat memory):
#   state/focus-window         present only while a window is set; one
#                              `key: value` per line, written atomically:
#                                version: 1
#                                set: <UTC ISO 8601>
#                                set_epoch: <seconds>
#                                until: <UTC ISO 8601> | -
#                                until_epoch: <seconds> | -
#                                projects: <name> [<name>...]
#                              A window whose until has passed has ENDED: it
#                              holds nothing more and its obligations are due.
#                              A record that cannot be parsed reads as no window
#                              (deliver everything) and is reported, never
#                              silently obeyed.
#   state/focus-windows/       archived records, one per cleared window.
#   state/focus-held.jsonl     append-only held-delivery obligations, one JSON
#                              object per line: {"seq":N,"epoch":N,"task":"...",
#                              "project":"...","class":"...","summary":"..."}.
#                              Lines are never rewritten or deleted here.
#   state/.focus-held-delivered  the highest seq main has delivered to the
#                              captain; absent reads as 0, so an interrupted
#                              delivery is presented again (the safe direction).
#   state/.focus.lock          serializes every mutation.
#
# PROJECT. route reads the outcome's project from structured records only: the
# explicit --project (which the caller copies from a structured row such as a
# Bearings snapshot row's repo, never from prose), else the final path
# component of state/<task>.meta project=, else the task's backlog row
# `(repo: <name>)` metadata. Project names are compared exactly.
#
# DELIVERY. Obligations become due when the window is cleared or its until
# passes. The existing watcher calls `expire` each cycle to queue a durable
# wake before archiving a timed-out window. `clear` prints obligations at once,
# grouped by project; while they remain
# undelivered, every bin/fm-wake-drain.sh presentation (and so the session-start
# digest) prints the same FOCUS HELD section, so a restart or a lost reply
# cannot drop them. Main delivers them to the captain together, then runs the
# printed `delivered --through <seq>` acknowledgement.
#
# Usage:
#   fm-focus.sh set <project> [<project>...] [--until <UTC ISO 8601>|<N>m|<N>h]
#       Start or replace the window. Obligations already held stay held.
#   fm-focus.sh clear
#       End the window (archive its record) and print every undelivered
#       obligation grouped by project with the acknowledgement command.
#   fm-focus.sh expire
#       Watcher entry point: queue an expiry wake and archive an ended window.
#       Print the wake reason only when a window expired.
#   fm-focus.sh status [--json]
#       `off`, `on ...`, or `ended ...`, with the undelivered count; --json
#       prints {active,ended,projects,set,until,held:[...]} for the snapshot.
#   fm-focus.sh route --task <id> --class <class> --summary <text> [--project <name>]
#       Classes: failure|security|credential|blocking (urgent, always
#       delivered) and review-ready|completion|decision (held when outside an
#       active focus). Prints `deliver <reason>` or `held <seq> <project>`.
#       Any error exits nonzero; the caller then delivers the outcome now.
#   fm-focus.sh held
#       Print undelivered obligations grouped by project (nothing when none).
#   fm-focus.sh delivered --through <seq>
#       Record delivery of every obligation through <seq> (never backwards).
#   fm-focus.sh drain-section
#       The wake drain's section: a one-line reminder while a window is active,
#       the FOCUS HELD block once it has ended with obligations due, else
#       nothing.
#
# FM_FOCUS_NOW_EPOCH overrides the clock (tests only).
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

RECORD="$STATE/focus-window"
ARCHIVE_DIR="$STATE/focus-windows"
LEDGER="$STATE/focus-held.jsonl"
DELIVERED="$STATE/.focus-held-delivered"
LOCK="$STATE/.focus.lock"
URGENT_CLASSES="failure security credential blocking"
HOLDABLE_CLASSES="review-ready completion decision"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
  exit 2
}

die() { printf 'fm-focus: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq not found"

now_epoch() {
  case "${FM_FOCUS_NOW_EPOCH:-}" in
    ''|*[!0-9]*) date -u +%s ;;
    *) printf '%s\n' "$FM_FOCUS_NOW_EPOCH" ;;
  esac
}

iso_of() { jq -nr --argjson e "$1" '$e | todate'; }

valid_project() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 120 ]
}

# Read the record into REC_* variables; return 1 when absent, 3 when damaged.
read_record() {
  REC_SET='' REC_SET_EPOCH='' REC_UNTIL='-' REC_UNTIL_EPOCH='-' REC_PROJECTS=''
  [ -f "$RECORD" ] || return 1
  local key value version='' line
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%:*}
    value=${line#*: }
    [ "$key" != "$line" ] || return 3
    case "$key" in
      version) version=$value ;;
      set) REC_SET=$value ;;
      set_epoch) REC_SET_EPOCH=$value ;;
      until) REC_UNTIL=$value ;;
      until_epoch) REC_UNTIL_EPOCH=$value ;;
      projects) REC_PROJECTS=$value ;;
      *) return 3 ;;
    esac
  done < "$RECORD"
  [ "$version" = 1 ] || return 3
  case "$REC_SET_EPOCH" in ''|*[!0-9]*) return 3 ;; esac
  case "$REC_UNTIL_EPOCH" in -) ;; ''|*[!0-9]*) return 3 ;; esac
  [ -n "$REC_PROJECTS" ] || return 3
  local p
  for p in $REC_PROJECTS; do valid_project "$p" || return 3; done
  return 0
}

# WINDOW_STATE: off | active | ended | damaged
window_state() {
  local rc=0
  read_record || rc=$?
  case "$rc" in
    1) WINDOW_STATE=off; return 0 ;;
    3) WINDOW_STATE=damaged; return 0 ;;
  esac
  if [ "$REC_UNTIL_EPOCH" != - ] && [ "$(now_epoch)" -ge "$REC_UNTIL_EPOCH" ]; then
    WINDOW_STATE=ended
  else
    WINDOW_STATE=active
  fi
}

delivered_through() {
  local value
  [ -f "$DELIVERED" ] || { printf '0\n'; return 0; }
  value=$(cat "$DELIVERED" 2>/dev/null) || return 1
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

# Undelivered obligations as a JSON array; fails on a damaged ledger.
pending_json() {
  local through
  through=$(delivered_through) || { echo "fm-focus: the delivered marker is unreadable" >&2; return 1; }
  if [ ! -s "$LEDGER" ]; then printf '[]\n'; return 0; fi
  jq -sc --argjson through "$through" '
    if all(.[]; (type == "object") and (.seq | type == "number") and (.task | type == "string")
                 and (.project | type == "string") and (.class | type == "string")
                 and (.summary | type == "string"))
    then [ .[] | select(.seq > $through) ]
    else error("malformed held obligation") end' "$LEDGER" 2>/dev/null \
    || { echo "fm-focus: the held ledger $LEDGER is unreadable" >&2; return 1; }
}

last_seq() {
  [ -s "$LEDGER" ] || { printf '0\n'; return 0; }
  jq -s '[.[].seq] | max // 0' "$LEDGER" 2>/dev/null
}

# Print obligations grouped by project: groups in order of their first
# obligation, obligations oldest first inside each group.
print_grouped() {  # <json-array>
  printf '%s' "$1" | jq -r '
    . as $rows
    | (reduce ($rows[] | .project) as $p ([]; if any(.[]; . == $p) then . else . + [$p] end)) as $order
    | $order[] as $p
    | ([$rows[] | select(.project == $p)]) as $group
    | "  \($p) (\($group | length)):",
      ($group[] | "    - [\(.class)] \(.task): \(.summary)")'
}

print_held_block() {  # <json-array> <heading>
  local rows=$1 heading=$2 through
  [ "$(printf '%s' "$rows" | jq 'length')" -gt 0 ] || return 0
  through=$(printf '%s' "$rows" | jq '[.[].seq] | max')
  printf '%s\n' "$heading"
  print_grouped "$rows"
  printf 'FOCUS HELD: after telling the captain, run bin/fm-focus.sh delivered --through %s; until then every drain presents them again\n' "$through"
}

projects_csv() { printf '%s' "$REC_PROJECTS" | tr ' ' '\n' | paste -sd, - | sed 's/,/, /g'; }

cmd_set() {
  local until_arg='' projects='' p until_epoch=- until_iso=- now tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --until) shift; until_arg=${1:-}; [ -n "$until_arg" ] || usage ;;
      --until=*) until_arg=${1#--until=} ;;
      -*) usage ;;
      *) valid_project "$1" || die "invalid project name: $1"
         case " $projects " in *" $1 "*) ;; *) projects="${projects:+$projects }$1" ;; esac ;;
    esac
    shift
  done
  [ -n "$projects" ] || usage
  now=$(now_epoch)
  if [ -n "$until_arg" ]; then
    case "$until_arg" in
      *[0-9]m) p=${until_arg%m}; case "$p" in ''|*[!0-9]*) die "invalid --until: $until_arg" ;; esac
               until_epoch=$((now + p * 60)) ;;
      *[0-9]h) p=${until_arg%h}; case "$p" in ''|*[!0-9]*) die "invalid --until: $until_arg" ;; esac
               until_epoch=$((now + p * 3600)) ;;
      *) until_epoch=$(jq -nr --arg t "$until_arg" '
             $t | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z") else . end
             | fromdateiso8601' 2>/dev/null) || die "invalid --until (UTC ISO 8601, <N>m, or <N>h): $until_arg" ;;
    esac
    [ "$until_epoch" -gt "$now" ] || die "--until must be in the future: $until_arg"
    until_iso=$(iso_of "$until_epoch")
  fi
  fm_lock_acquire_wait "$LOCK"
  tmp=$(mktemp "$STATE/.focus-window.XXXXXX") || { fm_lock_release "$LOCK"; die "cannot write the focus record"; }
  if ! printf 'version: 1\nset: %s\nset_epoch: %s\nuntil: %s\nuntil_epoch: %s\nprojects: %s\n' \
      "$(iso_of "$now")" "$now" "$until_iso" "$until_epoch" "$projects" > "$tmp" \
    || ! mv -f "$tmp" "$RECORD"; then
    rm -f "$tmp"; fm_lock_release "$LOCK"; die "cannot write the focus record"
  fi
  fm_lock_release "$LOCK"
  read_record || true
  printf 'focus: on for %s' "$(projects_csv)"
  [ "$until_iso" = - ] || printf ' until %s' "$until_iso"
  printf '\n'
}

cmd_expire() {
  local reason="check: focus-window-ended" now
  fm_lock_acquire_wait "$LOCK"
  window_state
  if [ "$WINDOW_STATE" != ended ]; then
    fm_lock_release "$LOCK"
    return 0
  fi
  fm_wake_append check focus-window-ended "$reason" || {
    fm_lock_release "$LOCK"; die "cannot queue the focus expiry"
  }
  now=$(now_epoch)
  if ! { mkdir -p "$ARCHIVE_DIR" && mv -f "$RECORD" "$ARCHIVE_DIR/window-$now"; }; then
    fm_lock_release "$LOCK"; die "cannot archive the focus record"
  fi
  fm_lock_release "$LOCK"
  printf '%s\n' "$reason"
}

cmd_clear() {
  local now rows
  fm_lock_acquire_wait "$LOCK"
  if [ -e "$RECORD" ]; then
    now=$(now_epoch)
    if ! { mkdir -p "$ARCHIVE_DIR" && mv -f "$RECORD" "$ARCHIVE_DIR/window-$now"; }; then
      fm_lock_release "$LOCK"; die "cannot archive the focus record"
    fi
    printf 'focus: off\n'
  else
    printf 'focus: off (no window was set)\n'
  fi
  fm_lock_release "$LOCK"
  rows=$(pending_json) || exit 1
  print_held_block "$rows" "FOCUS HELD (the focus window ended; tell the captain these now, together, grouped by project):"
}

cmd_status() {
  local json=0 rows
  [ "${1:-}" = --json ] && json=1
  window_state
  rows=$(pending_json) || exit 1
  if [ "$json" = 1 ]; then
    jq -nc --arg state "$WINDOW_STATE" --arg projects "$REC_PROJECTS" --arg set "$REC_SET" \
      --arg until "$REC_UNTIL" --argjson held "$rows" '
      {active:($state == "active"), ended:($state == "ended"), damaged:($state == "damaged"),
       projects:(if $state == "active" or $state == "ended" then ($projects | split(" ")) else [] end),
       set:(if $set == "" then null else $set end),
       until:(if $until == "-" or $until == "" then null else $until end),
       held:$held}'
    return 0
  fi
  case "$WINDOW_STATE" in
    off) printf 'off' ;;
    damaged) printf 'damaged (record unreadable; outcomes are delivered as if no window were set; run bin/fm-focus.sh clear)' ;;
    active) printf 'on for %s' "$(projects_csv)"; [ "$REC_UNTIL" = - ] || printf ' until %s' "$REC_UNTIL" ;;
    ended) printf 'ended (for %s, until %s passed)' "$(projects_csv)" "$REC_UNTIL" ;;
  esac
  printf '; held undelivered: %s\n' "$(printf '%s' "$rows" | jq 'length')"
}

resolve_project() {  # <task>
  local task=$1 meta project line
  meta="$STATE/$task.meta"
  if [ -f "$meta" ]; then
    project=$(sed -n 's/^project=//p' "$meta" | head -1)
    project=${project%/}
    project=${project##*/}
    if valid_project "$project"; then printf '%s\n' "$project"; return 0; fi
  fi
  [ -f "$DATA/backlog.md" ] || return 1
  line=$(awk -v id="$task" '
    $0 ~ /^[-*][[:space:]]+\[[ xX]\][[:space:]]+/ {
      rest = $0; sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", rest)
      split(rest, w, /[[:space:]]/)
      if (w[1] == id) { print; exit }
    }' "$DATA/backlog.md")
  project=$(printf '%s' "$line" | sed -n 's/.*(repo:[[:space:]]*\([^)[:space:]]*\)[[:space:]]*).*/\1/p' | head -1)
  valid_project "$project" || return 1
  printf '%s\n' "$project"
}

cmd_route() {
  local task='' class='' summary='' project='' seq now
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) shift; task=${1:-} ;;
      --class) shift; class=${1:-} ;;
      --summary) shift; summary=${1:-} ;;
      --project) shift; project=${1:-} ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$task" ] && [ -n "$class" ] && [ -n "$summary" ] || usage
  case " $URGENT_CLASSES " in
    *" $class "*) printf 'deliver urgent:%s\n' "$class"; return 0 ;;
  esac
  case " $HOLDABLE_CLASSES " in
    *" $class "*) ;;
    *) die "unknown class '$class' (urgent: $URGENT_CLASSES; holdable: $HOLDABLE_CLASSES); deliver it now" ;;
  esac
  window_state
  case "$WINDOW_STATE" in
    off) printf 'deliver no-focus-window\n'; return 0 ;;
    ended) printf 'deliver focus-window-ended\n'; return 0 ;;
    damaged) printf 'deliver focus-record-unreadable\n'
             echo "fm-focus: the focus record is unreadable; run bin/fm-focus.sh clear" >&2; return 0 ;;
  esac
  if [ -n "$project" ]; then
    valid_project "$project" || die "invalid --project: $project; deliver it now"
  else
    project=$(resolve_project "$task") || project=''
  fi
  if [ -z "$project" ]; then printf 'deliver unknown-project\n'; return 0; fi
  case " $REC_PROJECTS " in
    *" $project "*) printf 'deliver in-focus\n'; return 0 ;;
  esac
  fm_lock_acquire_wait "$LOCK"
  seq=$(last_seq) || { fm_lock_release "$LOCK"; die "the held ledger is unreadable; deliver it now"; }
  seq=$((seq + 1))
  now=$(now_epoch)
  if ! jq -nc --argjson seq "$seq" --argjson epoch "$now" --arg task "$task" --arg project "$project" \
      --arg class "$class" --arg summary "$summary" \
      '{seq:$seq,epoch:$epoch,task:$task,project:$project,class:$class,summary:$summary}' >> "$LEDGER"; then
    fm_lock_release "$LOCK"; die "cannot record the held obligation; deliver it now"
  fi
  fm_lock_release "$LOCK"
  printf 'held %s %s\n' "$seq" "$project"
}

cmd_held() {
  local rows
  rows=$(pending_json) || exit 1
  [ "$(printf '%s' "$rows" | jq 'length')" -gt 0 ] || return 0
  print_grouped "$rows"
}

cmd_delivered() {
  local through='' current top
  [ "${1:-}" = --through ] || usage
  through=${2:-}
  case "$through" in ''|*[!0-9]*) usage ;; esac
  fm_lock_acquire_wait "$LOCK"
  current=$(delivered_through) || { fm_lock_release "$LOCK"; die "the delivered marker is unreadable"; }
  top=$(last_seq) || { fm_lock_release "$LOCK"; die "the held ledger is unreadable"; }
  if [ "$through" -gt "$top" ]; then fm_lock_release "$LOCK"; die "no held obligation $through exists (latest is $top)"; fi
  if [ "$through" -gt "$current" ]; then
    if ! { printf '%s\n' "$through" > "$DELIVERED.tmp" && mv -f "$DELIVERED.tmp" "$DELIVERED"; }; then
      fm_lock_release "$LOCK"; die "cannot record delivery"
    fi
  fi
  fm_lock_release "$LOCK"
  printf 'focus: delivered through %s\n' "$(delivered_through)"
}

cmd_drain_section() {
  local rows count
  window_state
  if ! rows=$(pending_json 2>/dev/null); then
    printf 'FOCUS HELD: the held-outcome ledger or its delivered marker is unreadable, so held outcomes may be waiting; inspect %s and %s\n' "$LEDGER" "$DELIVERED"
    return 0
  fi
  count=$(printf '%s' "$rows" | jq 'length')
  case "$WINDOW_STATE" in
    active)
      printf 'FOCUS WINDOW: on for %s' "$(projects_csv)"
      [ "$REC_UNTIL" = - ] || printf ' until %s' "$REC_UNTIL"
      printf ' (%s outcome(s) held); before telling the captain about any outcome, run bin/fm-focus.sh route --task <id> --class <class> --summary <text> and report it now only when it prints deliver - failures, security-sensitive items, credential needs, and anything blocking all work always come through\n' "$count"
      ;;
    damaged)
      printf 'FOCUS WINDOW: the record is unreadable, so outcomes are delivered as if no window were set; run bin/fm-focus.sh clear\n'
      print_held_block "$rows" "FOCUS HELD (tell the captain these now, together, grouped by project):"
      ;;
    *)
      print_held_block "$rows" "FOCUS HELD (the focus window ended; tell the captain these now, together, grouped by project):"
      ;;
  esac
}

sub=${1:-}
[ $# -gt 0 ] && shift
case "$sub" in
  set) cmd_set "$@" ;;
  clear) cmd_clear ;;
  expire) cmd_expire ;;
  status) cmd_status "$@" ;;
  route) cmd_route "$@" ;;
  held) cmd_held ;;
  delivered) cmd_delivered "$@" ;;
  drain-section) cmd_drain_section ;;
  -h|--help|help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
  *) usage ;;
esac
