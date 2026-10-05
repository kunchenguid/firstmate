#!/usr/bin/env bash
# fm-hold-status-lib.sh - status reads that honor a captain-held mirror.
#
# Source bin/fm-classify-lib.sh first, then this file. It replaces
# last_status_line, status_declared_wait_line, and status_current_line, and
# adds last_worker_status_line, status_hold_settled, and status_worker_signature.
# Only the scripts that read a hold mirror source this file, so ShellCheck does
# not analyze these helpers from every root that sources the shared classifier.
# Behavior of those readers matches the readers this file replaces.

_fm_hold_status_load() {
  local dir
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=bin/fm-classify-lib.sh
  . "$dir/fm-classify-lib.sh"
}
if ! declare -F _fm_status_unstamped >/dev/null 2>&1; then
  _fm_hold_status_load
fi
unset -f _fm_hold_status_load

# The lines bin/fm-captain-hold.sh writes on a lane's log. Its hold mirror
# declares a hold as `captain-held [key=captain-hold-<task>-<n>]` and every
# reader that treats those lines specially derives the key from the log's
# filename through _fm_hold_mirror_line_ere. `complete` transfers a still-open
# decision as `captain-held [key=<k>]: tracked by <ids>`
# (FM_HOLD_TRANSFER_ERE, capturing <k> and <ids>). Settlement retracts either
# with `resolved [key=<key>]: captain call <how> by fm-captain-hold`
# (FM_HOLD_RETRACTION_ERE).
FM_HOLD_TRANSFER_ERE='^captain-held \[key=([A-Za-z0-9._-]+)\]: tracked by ([A-Za-z0-9._,-]+)$'
FM_HOLD_RETRACTION_ERE='^resolved \[key=[A-Za-z0-9._-]+\]: captain call .+ by fm-captain-hold$'

_fm_hold_mirror_line_ere() {  # <status-file> <verb-ere>
  local task=${1##*/}
  task=${task%.status}
  printf '^(%s) \\[key=captain-hold-%s-[0-9]+\\]:' "$2" "${task//./\\.}"
}

# Every hold-command line on this lane's log: mirror, transfers, retractions.
_fm_hold_line_ere() {  # <status-file>
  printf '%s|%s|%s' "$(_fm_hold_mirror_line_ere "$1" 'captain-held|resolved')" \
    "$FM_HOLD_TRANSFER_ERE" "$FM_HOLD_RETRACTION_ERE"
}

# Match a hold-command regex against the unstamped copy of <line>. Those
# regexes describe the bytes before status_stamp_line inserts [at=<epoch>], so
# every reader of them goes through this rather than matching stamped log bytes.
# BASH_REMATCH is that of the unstamped copy.
_fm_hold_unstamped_match() {  # <line> <ere>
  local __fm_hold_u
  _fm_status_unstamped "$1" __fm_hold_u
  [[ $__fm_hold_u =~ $2 ]]
}

# Return the last recognized status event, ignoring continuation prose and blanks
# (empty if missing/blank), and with <previous-event-var> the event before it.
# The optional previous event is what this reader returned before the latest one
# was appended, so a consumer can name the head it is superseding; asking for it
# always reads the whole file, since a bounded window cannot bound two events.
# This is an event read; status_current_line below reconciles open decisions.
# A settled hold is read past (_fm_hold_settled_drop): its hold-command lines
# are bookkeeping, not worker state, so a lane that was done, paused, or failed
# before the hold, or whose transferred needs-decision was just answered, reads
# that way to the watcher, the away-mode daemon, and the return brief again,
# whatever the worker appends after the settlement. A hold or transfer still
# standing is returned raw, because those readers must see it.
last_status_line() {  # <status-file> [<previous-event-var>]
  _fm_last_status_event "$(_fm_hold_line_ere "$1")" '' "$@"
}

# last_status_line read past bin/fm-captain-hold.sh's hold mirror at all
# times. Those lines are the hold command's, not the worker's, so a reader of
# the worker's own state (crew state, the terminal-outcome ledger) must not let
# them displace the event the worker last wrote; a settled transfer is read
# past exactly as last_status_line reads it. The watcher and away-mode daemon
# read last_status_line directly, which keeps a standing hold visible to them.
last_worker_status_line() {  # <status-file> [<previous-event-var>]
  _fm_last_status_event "$(_fm_hold_line_ere "$1")" \
    "$(_fm_hold_mirror_line_ere "$1" 'captain-held|resolved')" "$@"
}

# Print the status lines on stdin without a settled hold's lines. A line
# matching <hold-line-ere> is settled when a hold-command retraction for its
# own key appears at or after it, so every retraction goes, and so does the
# mirror or transfer it retracts however many worker lines follow, while a hold
# or transfer still standing stays. An empty <hold-line-ere> drops nothing.
# Settlement is per key: a settled transfer does not drop a mirror of another
# key, including one recorded later.
_fm_hold_settled_drop() {  # <hold-line-ere>
  local hold=$1 key settled=$'\n' i=0
  local -a lines=()
  if [ -z "$hold" ]; then
    cat
    return
  fi
  while IFS= read -r 'lines[i]' || [ -n "${lines[i]}" ]; do
    i=$((i + 1))
  done
  unset 'lines[i]'
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    _fm_hold_unstamped_match "${lines[i]}" "$hold" || continue
    key=$(_fm_decision_key "${lines[i]}") || continue
    ! _fm_hold_unstamped_match "${lines[i]}" "$FM_HOLD_RETRACTION_ERE" \
      || settled="$settled$key"$'\n'
    case "$settled" in *$'\n'"$key"$'\n'*) unset 'lines[i]' ;; esac
  done
  [ "${#lines[@]}" -eq 0 ] || printf '%s\n' "${lines[@]}"
}

# 0 when the log's latest event is a hold-command retraction - the settled
# bookkeeping last_status_line reads through - and no worker event sits between
# it and the declaration it retracts, so a caller can tell a lane whose only
# lifted wait was the hold from a worker that moved on, even when the
# retraction landed after the worker's newer line.
status_hold_settled() {  # <status-file>
  local hold line key='' legacy_re
  hold=$(_fm_hold_line_ere "$1")
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  while IFS= read -r line; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_status_line_is_event "$line" "$legacy_re" || continue
    _fm_hold_unstamped_match "$line" "$hold" || return 1
    if _fm_hold_unstamped_match "$line" "$FM_HOLD_RETRACTION_ERE"; then
      [ -n "$key" ] || key=$(_fm_decision_key "$line") || return 1
    elif [ -z "$key" ]; then
      return 1
    elif [ "$(_fm_decision_key "$line")" = "$key" ]; then
      return 0
    fi
  done < <(tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$1" 2>/dev/null \
    | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }')
  return 1
}

# status_observed_signature of the log as its worker left it: the hold
# command's own lines at the end of the log are left out of its size, so a
# throttle bound to the worker's declaration survives firstmate recording or
# settling a hold on it, while any worker append still changes it.
status_worker_signature() {  # <status-file>
  local f=$1 size hold line
  local LC_ALL=C
  size=$(_fm_status_file_size "$f") || size=''
  case "$size" in ''|*[!0-9]*) status_observed_signature "$f"; return ;; esac
  hold=$(_fm_hold_line_ere "$f")
  while IFS= read -r line; do
    _fm_hold_unstamped_match "$line" "$hold" || break
    size=$((size - ${#line} - 1))
  done < <(tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$f" 2>/dev/null \
    | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }')
  status_observed_signature "$f" "$size"
}

_fm_last_status_event() {  # <hold-line-ere> <skip-ere> <status-file> [<previous-event-var>]
  local hold=$1 skip=$2 f=$3 scan=''
  [ -f "$f" ] && [ -r "$f" ] || return 0
  if [ "$#" -gt 3 ]; then
    scan=$(_fm_hold_settled_drop "$hold" < "$f" | _fm_status_event_scan "$skip") || :
  elif ! scan=$(tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$f" 2>/dev/null \
      | _fm_hold_settled_drop "$hold" | _fm_status_event_scan "$skip"); then
    scan=$(_fm_hold_settled_drop "$hold" < "$f" | _fm_status_event_scan "$skip") || :
  fi
  [ "$#" -lt 4 ] || printf -v "$4" '%s' "${scan%%$'\n'*}"
  printf '%s\n' "${scan##*$'\n'}"
}

_fm_status_event_scan() {  # [<skip-ere>]
  local skip=${1:-} line last='' prev='' fallback='' legacy_re
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$skip" ] || ! _fm_hold_unstamped_match "$line" "$skip" || continue
    case "$line" in *[![:space:]]*) fallback=$line ;; *) continue ;; esac
    _fm_status_line_is_event "$line" "$legacy_re" && { prev=$last; last=$line; }
  done
  printf '%s\n%s\n' "$prev" "${last:-$fallback}"
  [ -n "$last" ]
}

# The status line that holds a crew in a declared wait, or nothing when it is in
# none. Supervisors decide the wait from this line, never from the raw latest
# event: a resolved line is also how firstmate answers a decision (fm-send
# --resolve-key), and one that lands after a pause for a different phase key -
# including the stated default key a keyless decision shares - does not end the
# pause. Only a resolved line for the pause's own phase key (the keyed
# activity fold's key, where a keyless line is its own phase) retracts it, as
# does any other later event. A hold mirror bin/fm-captain-hold.sh wrote with
# no retraction of its own key after it holds the same way: resolved lines for
# other keys on top of it do not end it, and any other later event does. Any
# other captain-held line, such as a complete transfer, counts only while it is
# the latest event. Bounded like last_status_line, and like it reads past a settled
# hold: only a tail window made wholly of resolved events widens the read to the
# whole file.
status_declared_wait_line() {  # <status-file>
  local f=$1 last verb resolve
  last=$(last_status_line "$f")
  if status_is_paused_or_captain_held "$last"; then
    printf '%s\n' "$last"
    return 0
  fi
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  status_line_verb "$last" verb
  [ "$verb" = "$resolve" ] || return 0
  _fm_status_wait_scan_file "$f" "$(_fm_hold_mirror_line_ere "$f" 'captain-held')"
}

# _fm_status_declared_wait_scan over the settled-drop read of <status-file>,
# bounded like last_status_line: a tail window made wholly of resolved events
# widens the read to the whole file.
_fm_status_wait_scan_file() {  # <status-file> <mirror-ere> [<skip-ere>]
  local f=$1 resolve legacy_re hold
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  legacy_re="^[[:space:]]*(${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT})"
  hold=$(_fm_hold_line_ere "$f")
  tail -n "$FM_CLASSIFY_EVENT_WINDOW_LINES" "$f" 2>/dev/null | _fm_hold_settled_drop "$hold" \
    | _fm_status_declared_wait_scan "$resolve" "$legacy_re" "$2" "${3-}" \
    || _fm_hold_settled_drop "$hold" < "$f" \
    | _fm_status_declared_wait_scan "$resolve" "$legacy_re" "$2" "${3-}" || :
}

# Walk the status lines on stdin back from the newest event past resolved lines
# to the first other event, and print it when it is a hold mirror (matching
# <mirror-ere>) or a pause none of those resolved lines share a phase key with.
# Lines matching <skip-ere> are read past, and with one given any other event
# it stops at is printed too, which is the worker's own view under a hold;
# a decision one of those resolved lines answered is not.
# Returns 1 when every event is a resolved line, so a caller reading a bounded
# window knows to widen it.
_fm_status_declared_wait_scan() {  # <resolve-verb> <legacy-captain-re> <mirror-ere> [<skip-ere>]
  local resolve=$1 legacy_re=$2 mirror=$3 skip=${4-} line verb key keys=$'\n' i=0
  local -a lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    lines[i]=$line
    i=$((i + 1))
  done
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    line=${lines[i]}
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_status_line_is_event "$line" "$legacy_re" || continue
    [ -z "$skip" ] || ! _fm_hold_unstamped_match "$line" "$skip" || continue
    if [ -n "$mirror" ] && _fm_hold_unstamped_match "$line" "$mirror"; then
      printf '%s\n' "$line"
      return 0
    fi
    status_line_verb "$line" verb
    case "$verb" in
      "$resolve") ;;
      "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
      needs-decision|blocked)
        [ -n "$skip" ] || return 0
        key=$(_fm_decision_key "$line") || key=
        case "${keys//"$_FM_CLASSIFY_KEYLESS_PHASE"/default}" in
          *$'\n'"$key"$'\n'*) return 0 ;;
        esac
        printf '%s\n' "$line"
        return 0
        ;;
      *)
        [ -z "$skip" ] || printf '%s\n' "$line"
        return 0
        ;;
    esac
    key=$(_fm_decision_key "$line" "$_FM_CLASSIFY_KEYLESS_PHASE") || key=
    if [ "$verb" = "$resolve" ]; then
      keys="$keys$key"$'\n'
      continue
    fi
    case "$keys" in *$'\n'"$key"$'\n'*) return 0 ;; esac
    printf '%s\n' "$line"
    return 0
  done
  return 1
}

# Resolve the log's current declaration at one boundary for crew-state consumers.
# Any decision the fold still holds open wins over unrelated events, and the
# fold's most recently opened record supplies it; a standing declared wait, then
# the worker's own latest event (last_worker_status_line), stands when nothing is open.
# A standing hold mirror gives way to the worker's own view read past the mirror
# and resolved lines: its standing pause or latest other event, never a resolved line.
# Actual run/pane evidence is still reconciled by fm-crew-state.sh.
status_current_line() {  # <status-file> <kind>
  local open key verb note current='' worker mirror
  open=$(status_open_decisions "$1" "$2")
  while IFS=$'\t' read -r key verb note; do
    case "$verb" in ?*) current="$verb [key=$key]: $note" ;; esac
  done <<EOF
$open
EOF
  [ -n "$current" ] || current=$(status_declared_wait_line "$1")
  if [ -n "$current" ]; then
    mirror=$(_fm_hold_mirror_line_ere "$1" 'captain-held')
    if status_is_captain_held "$current" \
      && _fm_hold_unstamped_match "$current" "$mirror"; then
      worker=$(_fm_status_wait_scan_file "$1" '' \
        "$(_fm_hold_mirror_line_ere "$1" 'captain-held|resolved')")
      [ -z "$worker" ] || current=$worker
    fi
  fi
  [ -n "$current" ] || current=$(last_worker_status_line "$1")
  printf '%s\n' "$current"
}
