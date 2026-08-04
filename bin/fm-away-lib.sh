#!/usr/bin/env bash
# Shared away-session identity, durable record, and append-only ledger helpers.
#
# Away mode's durable transition is already owned by bin/fm-afk-launch.sh
# (state/.afk, the daemon terminal record, rollback) and its return gate by
# bin/fm-afk-return.sh. This library adds only what those two cannot express: a
# stable IDENTITY for one away stretch, so a ruling request, a decision
# classification, and a reentry summary can all be bound to the same session
# across a restart. It never writes state/.afk and never launches or stops a
# daemon; bin/fm-away-session.sh composes this with those existing owners.
#
# Two artifacts, both under the home's state dir:
#
#   state/.away-session           the CURRENT session record. Tab-separated
#                                 "<key>\t<value>" lines, written atomically
#                                 through a pending file. Absent means no away
#                                 session has been opened in this home.
#   state/away/<session>/ledger   that session's APPEND-ONLY evidence log, one
#                                 "<epoch>\t<kind>\t<k>=<v>..." line per event.
#   state/away/<session>/ruling/  that session's durable ruling requests
#                                 (bin/fm-ruling-request.sh owns their layout).
#
# The ledger is deliberately append-only evidence, never a mutable queue: the
# durable actionable queue remains state/.wake-queue and its owner
# bin/fm-wake-lib.sh. Nothing in this library reorders, rewrites, or removes a
# ledger line, so a reader can always reconstruct what the session did.
#
# Session ids are privacy-safe slugs ("away-<epoch>", disambiguated with a
# "-<n>" suffix when two sessions open in the same second) so they are legal
# tasks-axi and bin/fm-decision-hold.sh identifiers.
#
# Sourced by bin/fm-away-session.sh, bin/fm-away-intent.sh,
# bin/fm-decision-class.sh, bin/fm-ruling-request.sh and
# bin/fm-away-continuation.sh. Pure helpers: every function takes what it needs
# or reads the resolved FM_AWAY_* paths, and none of them enable errexit.

FM_AWAY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$FM_AWAY_LIB_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AWAY_STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_AWAY_RECORD="$FM_AWAY_STATE/.away-session"
FM_AWAY_DIR="$FM_AWAY_STATE/away"
# shellcheck disable=SC2034 # Public source-library constant used by bin/fm-away-session.sh.
FM_AWAY_SCHEMA=fm-away-session.v1

# Every field written into a record or ledger line passes through this: tabs,
# carriage returns and newlines become spaces so one logical field can never
# forge a second field or a second line, and other control bytes are dropped.
fm_away_clean_field() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -d '[:cntrl:]'
}

fm_away_record_exists() {
  [ -f "$FM_AWAY_RECORD" ]
}

# Print one field of the current session record, empty when absent.
fm_away_field() {  # <key>
  local key=$1
  [ -f "$FM_AWAY_RECORD" ] || return 0
  awk -F '\t' -v k="$key" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }' \
    "$FM_AWAY_RECORD" 2>/dev/null
}

fm_away_session_id() {
  fm_away_field session
}

fm_away_session_dir() {  # <session>
  printf '%s/%s' "$FM_AWAY_DIR" "$1"
}

fm_away_ledger_path() {  # <session>
  printf '%s/%s/ledger' "$FM_AWAY_DIR" "$1"
}

fm_away_valid_session_id() {  # <session>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Allocate an unused session id for <epoch>. Never reuses an id that already has
# a session directory, so a second away stretch inside the same second cannot
# append to the previous session's evidence.
fm_away_new_session_id() {  # <epoch>
  local epoch=$1 candidate suffix=0
  candidate="away-$epoch"
  while [ -e "$(fm_away_session_dir "$candidate")" ]; do
    suffix=$((suffix + 1))
    [ "$suffix" -lt 1000 ] || return 1
    candidate="away-$epoch-$suffix"
  done
  printf '%s' "$candidate"
}

# Write the session record atomically from "<key>\t<value>" lines on stdin.
fm_away_record_write() {
  local pending
  mkdir -p "$FM_AWAY_STATE" || return 1
  pending=$(mktemp "$FM_AWAY_STATE/.away-session.pending.XXXXXX") || return 1
  cat > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_AWAY_RECORD" || { rm -f "$pending"; return 1; }
}

fm_away_record_clear() {
  rm -f "$FM_AWAY_RECORD"
}

# Append one evidence line. Each call writes a single line with one >> redirect,
# so concurrent appends interleave whole lines rather than corrupting one.
fm_away_ledger_append() {  # <session> <kind> [<k>=<v> ...]
  local session=$1 kind=$2 path line field
  shift 2
  fm_away_valid_session_id "$session" || return 1
  mkdir -p "$(fm_away_session_dir "$session")" || return 1
  path=$(fm_away_ledger_path "$session")
  line=$(printf '%s\t%s' "$(date +%s)" "$(fm_away_clean_field "$kind")")
  for field in "$@"; do
    line="$line$(printf '\t%s' "$(fm_away_clean_field "$field")")"
  done
  printf '%s\n' "$line" >> "$path"
}

# Print every ledger line of <session> whose kind is <kind> (all kinds when the
# kind is "-" or omitted). Missing ledger prints nothing and succeeds.
fm_away_ledger_read() {  # <session> [<kind>]
  local session=$1 kind=${2:--} path
  fm_away_valid_session_id "$session" || return 1
  path=$(fm_away_ledger_path "$session")
  [ -f "$path" ] || return 0
  if [ "$kind" = - ]; then
    cat "$path"
    return 0
  fi
  awk -F '\t' -v k="$kind" '$2 == k' "$path"
}

fm_away_ledger_count() {  # <session> <kind>
  fm_away_ledger_read "$1" "$2" | grep -c . || true
}

# Print the value of <k>=<v> field <name> from one ledger line, empty if absent.
fm_away_ledger_value() {  # <line> <name>
  printf '%s' "$1" | awk -F '\t' -v n="$2" '
    {
      for (i = 3; i <= NF; i++) {
        eq = index($i, "=")
        if (eq > 0 && substr($i, 1, eq - 1) == n) {
          print substr($i, eq + 1)
          exit
        }
      }
    }'
}

# The repository baseline a ruling request is bound to: "<repo-name>@<commit>".
# Read from a real checkout, so a response bound to a superseded commit can be
# rejected without trusting any typed claim.
fm_away_baseline() {  # <repo-dir>
  local dir=$1 commit name
  [ -d "$dir" ] || return 1
  commit=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1
  [ -n "$commit" ] || return 1
  name=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  printf '%s@%s' "${name##*/}" "$commit"
}
