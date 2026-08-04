#!/usr/bin/env bash
# fm-away-continuation.sh - keep independent work moving while one decision is
# blocked, and render the away stretch as a decision-oriented reentry summary.
#
# One blocked item must not stop the day. When a decision is reserved to the
# operator, only the work that genuinely depends on it pauses; everything else
# stays available. Both halves read the SAME dependency edges, so what paused
# during the away stretch and what the captain is asked about on return cannot
# disagree.
#
# It introduces no queue, no decision store and no accounting of its own. The
# durable decision is a captain hold owned by bin/fm-decision-hold.sh; the
# dependency edges are tasks-axi blocked_by edges in the existing backlog; the
# per-session evidence is the append-only away ledger (bin/fm-away-lib.sh); and
# every count in the reentry summary is DERIVED from those at read time rather
# than tallied into a second record that could drift.
#
# Semantic dependency is not guessed. `pause` takes the task ids firstmate has
# judged dependent and records those edges; `frontier` then owns only the
# mechanical transitive closure over them.
#
# Usage:
#   fm-away-continuation.sh pause --hold <hold-id> --task <id> [--task <id>...]
#                            Block each named task on the captain hold and
#                            record the pause. Idempotent.
#   fm-away-continuation.sh frontier --hold <hold-id>
#                            Print dependent= and independent= task lines for
#                            that hold.
#   fm-away-continuation.sh reentry [--session <id>]
#                            Print the decision-oriented reentry summary.
#
# Every D3 item in the reentry summary leads with the recommended ruling, then
# the strongest opposing position, what accepting and rejecting each cost, the
# reversibility and blast radius, the settled architecture at stake, and the
# exact directive firstmate needs. Items are marked batch-safe only when they are
# reversible and contained, so a materially different or destructive action can
# never hide inside an undifferentiated "approve all".
set -u

FM_AWAY_CONT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-away-lib.sh
. "$FM_AWAY_CONT_DIR/fm-away-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$FM_AWAY_CONT_DIR/fm-tasks-axi-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

fail() {
  printf 'fm-away-continuation: %s\n' "$*" >&2
  exit 2
}

tasks_axi() {
  (cd "$FM_HOME" && tasks-axi "$@")
}

require_backlog() {
  fm_tasks_axi_compatible \
    || fail 'a compatible tasks-axi is required to read dependency edges honestly'
}

# Task ids only. The id never contains a comma, so column one of a list row is
# unambiguous even when a title does.
all_task_ids() {
  tasks_axi list --limit 1000 2>/dev/null \
    | sed -n 's/^  \([^,]*\),.*/\1/p'
}

show_field() {  # <id> <field>
  tasks_axi show "$1" --full 2>/dev/null | sed -n "s/^  $2: //p" | head -1
}

# tasks-axi quotes a multi-entry blocked_by as "a,b,c"; strip the quotes so edge
# ids compare cleanly, and print one blocker id per line.
blockers_of() {  # <id>
  local raw
  raw=$(show_field "$1" blocked_by | tr -d '[:space:]')
  raw=${raw#\"}
  raw=${raw%\"}
  [ -n "$raw" ] && [ "$raw" != none ] || return 0
  printf '%s\n' "$raw" | tr ',' '\n' | sed '/^$/d'
}

# --- pause ------------------------------------------------------------------

command_pause() {
  local hold='' tasks='' task session existing
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hold) shift; hold=${1:-} ;;
      --task) shift; fm_away_valid_session_id "${1:-}" || fail "--task must be a slug: ${1:-}"
        tasks="${tasks}${tasks:+ }${1:-}" ;;
      *) fail "unknown option: $1" ;;
    esac
    shift
  done
  fm_away_valid_session_id "$hold" || fail '--hold must be a privacy-safe hold id'
  [ -n "$tasks" ] || fail 'at least one --task is required'
  require_backlog
  tasks_axi show "$hold" --full >/dev/null 2>&1 || fail "captain hold $hold does not exist"

  session=$(fm_away_session_id)
  for task in $tasks; do
    tasks_axi show "$task" --full >/dev/null 2>&1 || fail "task $task does not exist"
    if existing=$(blockers_of "$task") && printf '%s\n' "$existing" | grep -Fqx "$hold"; then
      printf 'already-paused %s\n' "$task"
      continue
    fi
    tasks_axi block "$task" --by "$hold" >/dev/null || fail "could not pause $task on $hold"
    printf 'paused %s\n' "$task"
    if [ -n "$session" ] && fm_away_valid_session_id "$session"; then
      fm_away_ledger_append "$session" continuation-pause "hold=$hold" "task=$task" || true
    fi
  done
}

# --- frontier ---------------------------------------------------------------

# Transitive closure over blocked_by: a task blocked by the hold is dependent,
# and so is a task blocked by anything already dependent.
command_frontier() {
  local hold='' id state kind dependent='' independent='' added=1 blocker
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hold) shift; hold=${1:-} ;;
      *) fail "unknown option: $1" ;;
    esac
    shift
  done
  fm_away_valid_session_id "$hold" || fail '--hold must be a privacy-safe hold id'
  require_backlog

  while [ "$added" -eq 1 ]; do
    added=0
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [ "$id" != "$hold" ] || continue
      case " $dependent " in *" $id "*) continue ;; esac
      state=$(show_field "$id" state)
      case "$state" in done) continue ;; esac
      while IFS= read -r blocker; do
        [ -n "$blocker" ] || continue
        if [ "$blocker" = "$hold" ]; then
          dependent="${dependent}${dependent:+ }$id"
          added=1
          break
        fi
        case " $dependent " in
          *" $blocker "*)
            dependent="${dependent}${dependent:+ }$id"
            added=1
            break
            ;;
        esac
      done <<EOF
$(blockers_of "$id")
EOF
    done <<EOF
$(all_task_ids)
EOF
  done

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$id" != "$hold" ] || continue
    case " $dependent " in *" $id "*) continue ;; esac
    state=$(show_field "$id" state)
    case "$state" in done) continue ;; esac
    kind=$(show_field "$id" kind)
    [ "$kind" != captain ] || continue
    independent="${independent}${independent:+ }$id"
  done <<EOF
$(all_task_ids)
EOF

  printf 'hold=%s\n' "$hold"
  printf 'dependent=%s\n' "$dependent"
  printf 'independent=%s\n' "$independent"
}

# --- reentry summary --------------------------------------------------------

ruling_dir() {  # <session> <request-id>
  printf '%s/ruling/%s' "$(fm_away_session_dir "$1")" "$2"
}

ruling_field() {  # <file> <key>
  [ -f "$1" ] || return 0
  awk -F '\t' -v k="$2" '$1 == k { sub(/^[^\t]*\t/, ""); print }' "$1"
}

# Join a repeated request field into one readable list. `paste -sd` takes only a
# single delimiter character, so the separator is applied here instead.
ruling_field_joined() {  # <file> <key>
  ruling_field "$1" "$2" | awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { print "" }'
}

ruling_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ruling_event_exists() {  # <ledger> <kind> <request-id> [digest]
  awk -F '\t' -v kind="$2" -v request="request=$3" -v digest="${4:+digest=$4}" '
    $2 == kind {
      has_request=0
      has_digest=(digest == "")
      for (i = 3; i <= NF; i++) {
        if ($i == request) has_request=1
        if ($i == digest) has_digest=1
      }
      if (has_request && has_digest) found=1
    }
    END { exit !found }
  ' "$1" 2>/dev/null
}

ruling_request_complete() {  # <session> <request-id>
  local dir ledger
  dir=$(ruling_dir "$1" "$2")
  ledger=$(fm_away_ledger_path "$1")
  [ -f "$dir/request" ] && [ -f "$dir/evidence" ] \
    && ruling_event_exists "$ledger" ruling-request "$2"
}

ruling_response_complete() {  # <session> <request-id>
  local dir ledger digest actual
  dir=$(ruling_dir "$1" "$2")
  ledger=$(fm_away_ledger_path "$1")
  [ -f "$dir/response" ] && [ -f "$dir/accepted" ] || return 1
  digest=$(ruling_field "$dir/accepted" digest | head -1)
  [ -n "$digest" ] || return 1
  actual=$(ruling_sha256 "$dir/response") || return 1
  [ "$actual" = "$digest" ] \
    && ruling_event_exists "$ledger" ruling-response "$2" "$digest"
}

ruling_dynamic_state() {  # <request-file> <accepted-file>
  local request=$1 accepted=$2 repo live expires checker
  FM_RULING_DYNAMIC_DETAIL='repository context is missing from the request'
  FM_RULING_LAST_VERIFIED=$(ruling_field "$accepted" verified | head -1)
  [ -n "$FM_RULING_LAST_VERIFIED" ] \
    || FM_RULING_LAST_VERIFIED=$(ruling_field "$accepted" accepted | head -1)
  [ -n "$FM_RULING_LAST_VERIFIED" ] || FM_RULING_LAST_VERIFIED=never
  repo=$(ruling_field "$request" repo | head -1)
  [ -n "$repo" ] || return 1
  live=$(fm_away_baseline "$repo") || {
    FM_RULING_DYNAMIC_DETAIL="repository context is unavailable: $repo"
    return 1
  }
  if [ "$(ruling_field "$request" baseline | head -1)" != "$live" ]; then
    FM_RULING_DYNAMIC_DETAIL='request baseline is no longer current'
    return 1
  fi
  expires=$(ruling_field "$request" expires | head -1)
  if ! [ "$(date +%s)" -le "$expires" ] 2>/dev/null; then
    FM_RULING_DYNAMIC_DETAIL='request expiry has passed or is indeterminate'
    return 1
  fi
  while IFS= read -r checker; do
    [ -n "$checker" ] || continue
    if ! fm_away_precondition_satisfied "$request" "$repo" "$checker"; then
      FM_RULING_DYNAMIC_DETAIL="precondition is false or indeterminate: $checker"
      return 1
    fi
  done <<EOF
$(ruling_field "$request" verifiable-precondition)
EOF
  FM_RULING_DYNAMIC_DETAIL='all dynamic gates currently hold'
  return 0
}

# A D3 item is safe to approve in a batch only when the advice it carries is
# reversible and contained. Anything else must be inspected on its own.
batch_safe() {  # <request-file>
  local reversibility blast
  reversibility=$(ruling_field "$1" reversibility | head -1)
  blast=$(ruling_field "$1" blast-radius | head -1)
  [ "$reversibility" = reversible ] || return 1
  case "$blast" in contained) : ;; *) return 1 ;; esac
  return 0
}

print_d3_item() {  # <session> <hold-id> <task> <key>
  local session=$1 hold=$2 request response accepted id request_ok=0 response_ok=0 current=0
  id="rr-$3-$4"
  request="$(ruling_dir "$session" "$id")/request"
  response="$(ruling_dir "$session" "$id")/response"
  accepted="$(ruling_dir "$session" "$id")/accepted"

  printf '\n  decision: %s\n' "$hold"
  if ruling_request_complete "$session" "$id"; then
    request_ok=1
    printf '    exact decision: %s\n' "$(ruling_field "$request" question | head -1)"
    printf '    why operator-owned: %s\n' "$(ruling_field "$request" why | head -1)"
  else
    printf '    ruling status: STALE - request publication is incomplete; no request fields are trusted\n'
    printf '    last verified: never\n'
  fi
  if [ "$request_ok" -eq 1 ]; then
    ruling_dynamic_state "$request" "$accepted" && current=1
    if [ "$current" -eq 0 ]; then
      printf '    ruling status: STALE - %s\n' "$FM_RULING_DYNAMIC_DETAIL"
      printf '    last verified: %s\n' "$FM_RULING_LAST_VERIFIED"
    fi
  fi
  if ruling_response_complete "$session" "$id"; then
    response_ok=1
  fi
  if [ "$response_ok" -eq 1 ] && [ "$current" -eq 1 ]; then
    printf '    ruling status: current\n'
    printf '    last verified: %s\n' "$FM_RULING_LAST_VERIFIED"
    printf '    recommended ruling: %s\n' "$(ruling_field "$response" disposition | head -1)"
    printf '    strongest opposing position: %s\n' "$(ruling_field "$response" opposing | head -1)"
    printf '    if accepted: %s\n' "$(ruling_field "$response" action | head -1)"
  elif [ "$response_ok" -eq 1 ]; then
    printf '    stale recommendation (not currently valid): %s\n' \
      "$(ruling_field "$response" disposition | head -1)"
    printf '    strongest opposing position: %s\n' "$(ruling_field "$response" opposing | head -1)"
  else
    printf '    recommended ruling: none recorded - no validated advice was accepted\n'
    [ "$request_ok" -eq 0 ] \
      || printf '    strongest opposing position: %s\n' "$(ruling_field "$request" counterargument | head -1)"
  fi
  if [ "$request_ok" -eq 1 ]; then
    printf '    if rejected: %s\n' "$(ruling_field "$request" dependency-impact | head -1)"
    printf '    reversibility: %s\n' "$(ruling_field "$request" reversibility | head -1)"
    printf '    blast radius: %s\n' "$(ruling_field "$request" blast-radius | head -1)"
    printf '    settled architecture at stake: %s\n' \
      "$(ruling_field_joined "$request" invariant)"
    printf '    exact directive needed: choose one of: %s\n' \
      "$(ruling_field_joined "$request" authorized-action)"
    if [ "$response_ok" -eq 1 ] && [ "$current" -eq 1 ] && batch_safe "$request"; then
      printf '    batch-safe: yes\n'
    else
      printf '    batch-safe: no - inspect this one on its own\n'
    fi
  else
    printf '    batch-safe: no - no complete ruling request was recorded for this decision\n'
  fi
  printf '    resolve with: bin/fm-decision-hold.sh resolve %s %s --decision-file <file> --routed-to <task>\n' "$3" "$4"
}

command_reentry() {
  local session='' started ledger d0 d1 d2 d3 line hold task key
  local held='' id state blocked_ids='' shown=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session) shift; session=${1:-} ;;
      *) fail "unknown option: $1" ;;
    esac
    shift
  done
  [ -n "$session" ] || session=$(fm_away_session_id)
  if [ -z "$session" ] || ! fm_away_valid_session_id "$session"; then
    fail 'no away session to report on'
  fi
  ledger=$(fm_away_ledger_path "$session")
  [ -f "$ledger" ] || fail "no ledger for away session $session"

  started=$(awk -F '\t' 'NR == 1 { print $1; exit }' "$ledger")

  d0=$(awk -F '\t' '$2 == "classification"' "$ledger" | grep -c 'tier=D0' || true)
  d1=$(awk -F '\t' '$2 == "classification"' "$ledger" | grep -c 'tier=D1' || true)
  d2=$(awk -F '\t' '$2 == "classification"' "$ledger" | grep -c 'tier=D2' || true)
  d3=$(awk -F '\t' '$2 == "classification"' "$ledger" | grep -c 'tier=D3' || true)

  printf 'away session %s\n' "$session"
  printf 'started: %s\n' "$(date -d "@$started" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'epoch %s' "$started")"
  printf 'decisions handled without you: D0=%s D1=%s (assisted: D2=%s)\n' "$d0" "$d1" "$d2"
  printf 'decisions reserved to you: D3=%s\n' "$d3"

  printf '\nadvice validated and accepted this session:\n'
  if fm_away_ledger_read "$session" ruling-response | grep -q .; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id=$(fm_away_ledger_value "$line" request)
      ruling_request_complete "$session" "$id" || continue
      ruling_response_complete "$session" "$id" || continue
      if ruling_dynamic_state "$(ruling_dir "$session" "$id")/request" \
        "$(ruling_dir "$session" "$id")/accepted"; then
        printf '  %s -> %s (authority: %s; last verified: %s)\n' \
          "$id" "$(fm_away_ledger_value "$line" action)" \
          "$(fm_away_ledger_value "$line" authority)" "$FM_RULING_LAST_VERIFIED"
        shown=1
      else
        printf '  %s -> STALE (last verified: %s; %s)\n' \
          "$id" "$FM_RULING_LAST_VERIFIED" "$FM_RULING_DYNAMIC_DETAIL"
        shown=1
      fi
    done <<EOF
$(fm_away_ledger_read "$session" ruling-response)
EOF
    [ "$shown" -eq 1 ] || printf '  (none)\n'
  else
    printf '  (none)\n'
  fi

  if fm_away_ledger_read "$session" ruling-rejected | grep -q .; then
    printf '\nadvice refused before it could act:\n'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '  %s: %s\n' \
        "$(fm_away_ledger_value "$line" request)" \
        "$(fm_away_ledger_value "$line" code)"
    done <<EOF
$(fm_away_ledger_read "$session" ruling-rejected)
EOF
  fi

  if ! fm_tasks_axi_compatible; then
    printf '\nbacklog state: UNAVAILABLE - tasks-axi is not usable here, so work and\n'
    printf 'blocked-path lines are omitted rather than guessed.\n'
    return 0
  fi

  printf '\nwork still executing:\n'
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    state=$(show_field "$id" state)
    [ "$state" = in_flight ] || continue
    printf '  %s\n' "$id"
  done <<EOF
$(all_task_ids)
EOF

  printf '\ndecisions still waiting on you:\n'
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(show_field "$id" kind)" = captain ] || continue
    [ "$(show_field "$id" state)" != "done" ] || continue
    held="${held}${held:+ }$id"
  done <<EOF
$(all_task_ids)
EOF
  if [ -z "$held" ]; then
    printf '  (none - no genuine ruling is waiting)\n'
    return 0
  fi
  for hold in $held; do
    # A hold id is "<origin>-decision-<key>", the identity bin/fm-decision-hold.sh
    # creates, so the matching ruling request is recoverable without a second
    # index.
    task=${hold%%-decision-*}
    key=${hold#*-decision-}
    print_d3_item "$session" "$hold" "$task" "$key"
    blocked_ids=$(command_frontier --hold "$hold" | sed -n 's/^dependent=//p')
    printf '    work paused by this: %s\n' "${blocked_ids:-none}"
  done
}

case "${1:-}" in
  pause) shift; command_pause "$@" ;;
  frontier) shift; command_frontier "$@" ;;
  reentry) shift; command_reentry "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
