#!/usr/bin/env bash
# bin/fm-secondmate-status.sh — operator read of registered secondmates.
#
# Usage:
#   fm-secondmate-status.sh [<id>]
#     no id    show every registered secondmate in $DATA/secondmates.md
#     <id>     show just that one
#
# Read-only. Prints a stable, scannable summary for the operator:
# - id, scope, summary, projects, added date (from the registry)
# - home path, home exists?, marker present?
# - orca terminal id and alive/dead (when the active home is orca)
# - in-flight crewmate count (all of the home's state/*.meta records)
# - last activity (the home's data/charter.md mtime, or the marker mtime
#   as a fallback)
#
# This is a pure read. fm-secondmate-retire.sh is the matching mutate;
# fm-home-seed.sh is the matching create.
#
# Honors FM_HOME / FM_ROOT_OVERRIDE / FM_DATA_OVERRIDE / FM_CONFIG_OVERRIDE
# / FM_STATE_OVERRIDE / XDG_CONFIG_HOME like the rest of the bin/ toolchain.
set -u

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# fm_secondmate_status_orca_id <home> <id>: derive the canonical orca
# session id for the secondmate from its home path. Mirrors the formula
# used by fm-spawn.sh so a status read matches what fm-spawn wrote:
#   fm-secondmate-<id>-<8-hex-of-sha256(realpath(home))>
fm_secondmate_status_orca_id() {  # <home> <id>
  local home=$1 id=$2
  [ -d "$home" ] || { return 1; }
  local real
  real=$(cd "$home" && pwd -P 2>/dev/null) || real=$home
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s%s-%s' "$ORCA_SESSION_PREFIX" "$id" \
      "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}')"
  else
    printf '%s%s-%s' "$ORCA_SESSION_PREFIX" "$id" \
      "$(printf '%s' "$real" | cksum | awk '{printf "%08x", $1}')"
  fi
}

# fm_secondmate_status_orca_term <expected-id>: look up $expected-id in
# fmod list and echo it (empty if absent). Extracted from print_secondmate
# so the heredoc/python is only sourced once per script invocation - the
# inline heredoc was failing to receive the env var under set -u.
fm_secondmate_status_orca_term() {  # <expected-id>
  local expected=$1
  [ -n "$FMOD_BIN" ] && [ -x "$FMOD_BIN" ] || return 1
  "$FMOD_BIN" list 2>/dev/null | python3 -c '
import json, os, sys
need = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("FM_SECONDMATE_EXPECTED_ID", "")
data = json.load(sys.stdin)
for s in data:
  if (s.get("sessionId") or s.get("id") or "") == need:
    print(need)
    sys.exit(0)
sys.exit(1)
' "$expected" 2>/dev/null || true
}
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
ORCA_SESSION_PREFIX="fm-secondmate-"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# FM_SECONDMATE_STATUS_FMOD lets the test suite stub the fmod binary
# without touching the real firstmate bin/fmod; defaults to the real one.
FMOD_BIN="${FM_SECONDMATE_STATUS_FMOD:-$SCRIPT_DIR/fmod}"

usage() {
  printf 'usage: fm-secondmate-status.sh [<id>]\n' >&2
}

ID=${1:-}
[ $# -le 1 ] || { usage; exit 64; }

# Pull all registry lines.
registry_lines() {
  if [ -f "$REG" ]; then
    grep -E "^- " "$REG" || true
  fi
}

# Parse a single registry line. Echoes TAB-separated:
#   <id> <summary> <home> <scope> <projects_csv> <added>
# Returns non-zero on a malformed line.
parse_line() {
  local line=$1
  case "$line" in
    "- "*)
      id=$(printf '%s' "$line" | sed -nE 's/^- ([^ ]+) - .*/\1/p')
      summary=$(printf '%s' "$line" | sed -nE 's/^- [^ ]+ - (.*) \(home: .*/\1/p')
      home=$(printf '%s' "$line" | sed -nE 's/^[^(]*\(home: ([^;)]*);.*/\1/p')
      scope=$(printf '%s' "$line" | sed -nE 's/^[^(]*\(home: [^;)]*; scope: ([^;)]*);.*/\1/p')
      projects_csv=$(printf '%s' "$line" | sed -nE 's/^[^(]*\(home: [^;)]*; scope: [^;)]*; projects: ([^;)]*);.*/\1/p')
      added=$(printf '%s' "$line" | sed -nE 's/.*; added ([^)]*)\).*/\1/p')
      [ -n "$id" ] && [ -n "$home" ] || return 1
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$summary" "$home" "$scope" "$projects_csv" "$added"
      ;;
    *) return 1 ;;
  esac
}

# Print a single secondmate's status block.
print_secondmate() {
  local id=$1 summary=$2 home=$3 scope=$4 projects=$5 added=$6
  local marker home_exists in_flight_count orca_term orca_alive charter_mtime last_activity

  marker=""
  if [ -f "$home/$SUB_HOME_MARKER" ]; then
    marker=$(cat "$home/$SUB_HOME_MARKER" 2>/dev/null || true)
  fi
  if [ -d "$home" ]; then
    home_exists="yes"
  else
    home_exists="no"
  fi

  # In-flight crewmate meta files in the secondmate home's own state/ dir.
  in_flight_count=0
  if [ -d "$home/state" ]; then
    in_flight_count=$(find "$home/state" -maxdepth 1 -name "*.meta" 2>/dev/null | wc -l)
  fi

  # Orca terminal: query fmod list for this secondmate's exact session id.
  # The session id format is `fm-secondmate-<id>-<8-hex-of-sha256(home)>`; a
  # plain prefix match would false-positive on nested ids (e.g. `qa` and
  # `qa-prod`), so compute the expected id from the home and exact-match on it.
  orca_term=""
  orca_alive="n/a"
  if [ -n "$FMOD_BIN" ] && [ -x "$FMOD_BIN" ]; then
    orca_expected_id=$(fm_secondmate_status_orca_id "$home" "$id" 2>/dev/null || true)
    if [ -n "$orca_expected_id" ]; then
      orca_term=$(fm_secondmate_status_orca_term "$orca_expected_id" 2>/dev/null || true)
    fi
    if [ -n "$orca_term" ]; then
      orca_alive="alive"
    elif [ -n "$orca_expected_id" ]; then
      orca_alive="none"
    fi
  fi

  # Last activity: prefer the home's data/charter.md, fall back to the
  # marker file's mtime.
  charter_mtime=""
  if [ -f "$home/data/charter.md" ]; then
    charter_mtime=$(stat -c %Y "$home/data/charter.md" 2>/dev/null || stat -f %m "$home/data/charter.md" 2>/dev/null || echo 0)
  elif [ -f "$home/$SUB_HOME_MARKER" ]; then
    charter_mtime=$(stat -c %Y "$home/$SUB_HOME_MARKER" 2>/dev/null || stat -f %m "$home/$SUB_HOME_MARKER" 2>/dev/null || echo 0)
  fi
  if [ -n "$charter_mtime" ] && [ "$charter_mtime" -gt 0 ] 2>/dev/null; then
    last_activity=$(date -u -d "@$charter_mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -r "$charter_mtime" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || echo "epoch=$charter_mtime")
  else
    last_activity="unknown"
  fi

  printf -- '- %s\n' "$id"
  printf '    summary:    %s\n' "${summary:-(none)}"
  printf '    home:       %s (%s)\n' "$home" "$home_exists"
  printf '    marker:     %s\n' "${marker:-absent}"
  if [ -n "$marker" ] && [ "$marker" != "$id" ]; then
    printf '    WARNING:    marker id (%s) does not match registry id (%s)\n' "$marker" "$id"
  fi
  printf '    scope:      %s\n' "${scope:-(none)}"
  printf '    projects:   %s\n' "${projects:-none}"
  printf '    added:      %s\n' "${added:-unknown}"
  printf '    in-flight:  %s crewmate(s) in %s/state/\n' "$in_flight_count" "$home"
  if [ -n "$orca_term" ]; then
    printf '    orca term:  %s (%s)\n' "$orca_term" "$orca_alive"
  else
    printf '    orca term:  none\n'
  fi
  printf '    last seen:  %s\n' "$last_activity"
  printf '\n'
}

# Main dispatch.
if [ -n "$ID" ]; then
  found=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if parsed=$(parse_line "$line") && printf '%s\n' "$parsed" | cut -f1 | grep -qxF "$ID"; then
      printf '%s\n' "$parsed" | while IFS="$(printf '\t')" read -r id summary home scope projects added; do
        print_secondmate "$id" "$summary" "$home" "$scope" "$projects" "$added"
      done
      found=1
    fi
  done < <(registry_lines)
  if [ "$found" -eq 0 ]; then
    printf 'error: secondmate %s is not registered in %s\n' "$ID" "$REG" >&2
    exit 1
  fi
  exit 0
fi

# No id: print all secondmates.
count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if parsed=$(parse_line "$line"); then
    printf '%s\n' "$parsed" | while IFS="$(printf '\t')" read -r id summary home scope projects added; do
      print_secondmate "$id" "$summary" "$home" "$scope" "$projects" "$added"
    done
    count=$((count + 1))
  fi
done < <(registry_lines)

if [ "$count" -eq 0 ]; then
  printf 'no secondmates registered in %s\n' "$REG"
fi
