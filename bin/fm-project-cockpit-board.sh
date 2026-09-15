#!/usr/bin/env bash
# fm-project-cockpit-board.sh - build or serve the observational Project Cockpit.
#
# Usage:
#   fm-project-cockpit-board.sh build <fm-project-cockpit.v1.json>
#   fm-project-cockpit-board.sh refresh
#   fm-project-cockpit-board.sh serve <fm-project-cockpit.v1.json>
#
# build validates one bounded fm-project-cockpit.v1 payload, injects it into the
# shipped template, verifies the embedded JSON round trip, and atomically writes
# $FM_HOME/.lavish/project-cockpit.html.
# refresh collects exactly one canonical fleet snapshot through
# fm-project-cockpit-snapshot.sh and builds it without starting a service.
# serve performs the same build and establishes only a Lavish presentation
# session.
# It never binds an answer source, registers a process event, starts a watcher,
# invokes task control, or exposes any write/control action.
#
# FM_PROJECT_COCKPIT_TEMPLATE overrides the shipped template path for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
TEMPLATE="${FM_PROJECT_COCKPIT_TEMPLATE:-$SCRIPT_DIR/../assets/project-cockpit-template.html}"
PLACEHOLDER='__FM_PROJECT_COCKPIT_DATA__'
BOARD_SCHEMA=fm-project-cockpit.v1
MAX_BYTES=${FM_PROJECT_COCKPIT_MAX_BYTES:-1048576}

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fm-project-cockpit-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/project-cockpit.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def text($n): type == "string" and length <= $n;
    def nullable_text($n): . == null or text($n);
    def stamp: type == "string" and (try fromdateiso8601 catch null) != null;
    def nonnegative_integer: type == "number" and . >= 0 and floor == .;
    def https: . == null or (text(500) and test("^https://[^[:space:]<>]+$"));
    def task:
      type == "object"
      and (.id | text(128))
      and (.spawn_gen | nullable_text(128))
      and (.name | text(160))
      and (.project_id | text(128))
      and (.lane == "running" or .lane == "waiting" or .lane == "queued" or .lane == "recently_completed")
      and (.state | text(40))
      and (.state_source | text(40))
      and (.observed_at == null or (.observed_at | stamp))
      and (.crew | type == "object")
      and (.crew.summary | text(40))
      and (.decisions | type == "array" and all(.[]; text(240)))
      and (.attention | type == "boolean")
      and (.hold == null or (.hold | type == "object"))
      and (.blockers | type == "array" and length <= 20 and all(.[]; text(128)))
      and (.gate | type == "object")
      and (.gate.status | text(40))
      and (.gate.label | text(240))
      and (.artifacts | type == "object")
      and (.artifacts.pr_url | https)
      and (.artifacts.report | type == "object")
      and (.artifacts.report.path | nullable_text(500))
      and (.runtime_evidence | type == "object")
      and (.events.status == "unavailable" or .events.status == "available")
      and (.terminal.status == "unavailable");
    type == "object"
    and .schema == $schema
    and (.generated | stamp)
    and (.observed_at | stamp)
    and (.age_seconds | nonnegative_integer)
    and (.stale_after_seconds | nonnegative_integer)
    and (.freshness == "fresh" or .freshness == "stale" or .freshness == "unavailable")
    and (.inventory.status == "valid" or .inventory.status == "partial" or .inventory.status == "invalid" or .inventory.status == "empty" or .inventory.status == "unavailable")
    and (.inventory.partial_reasons | type == "array" and length <= 20 and all(.[]; text(240)))
    and (.inventory.truncated | type == "boolean")
    and (.counts | type == "object")
    and ([.counts.running,.counts.waiting,.counts.blocked,.counts.attention] | all(.[]; nonnegative_integer))
    and (.projects | type == "array" and length <= 80)
    and ([(.projects[] | .tasks[])] | length <= 500)
    and all(.projects[];
      (.id | text(128))
      and (.label | text(128))
      and (.rank | nonnegative_integer)
      and (.tasks | type == "array" and length <= 160 and all(.[]; task)))
    and (.terminal.status == "unavailable")
  ' "$1" >/dev/null
}

command_build() {  # <payload>
  local data=$1 board tmp compact extracted canonical_source canonical_embedded bytes
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] && [ ! -L "$data" ] || fail "cockpit data must be a regular non-symlink file: $data"
  bytes=$(wc -c < "$data" | tr -d '[:space:]')
  [ "$bytes" -le "$MAX_BYTES" ] || fail "cockpit data exceeds the $MAX_BYTES-byte bound"
  jq empty "$data" >/dev/null 2>&1 || fail "cockpit data is not valid JSON: $data"
  validate_payload "$data" || fail "cockpit data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "cockpit template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "cockpit template does not carry exactly one data slot: $TEMPLATE"

  compact=$(jq -c . "$data") || fail "cannot compact cockpit data"
  compact=${compact//</\\u003c}
  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.project-cockpit.XXXXXX") \
    || fail "cannot stage the cockpit artifact"
  if ! COCKPIT_JSON="$compact" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{COCKPIT_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject cockpit data"
  fi
  if grep -qxF "$PLACEHOLDER" "$tmp"; then
    rm -f -- "$tmp"
    fail "the cockpit data slot survived injection"
  fi
  extracted=$(sed -n '/<script id="cockpit-data" type="application\/json">/,/<\/script>/p' "$tmp" | sed '1d;$d')
  canonical_source=$(printf '%s\n' "$compact" | jq -S -c . 2>/dev/null) || {
    rm -f -- "$tmp"
    fail "cannot canonicalize source cockpit data"
  }
  canonical_embedded=$(printf '%s\n' "$extracted" | jq -S -c . 2>/dev/null) || {
    rm -f -- "$tmp"
    fail "the built cockpit does not carry readable $BOARD_SCHEMA data"
  }
  if [ "$canonical_source" != "$canonical_embedded" ]; then
    rm -f -- "$tmp"
    fail "the embedded cockpit data did not round trip"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the cockpit artifact"
  fi
  printf 'board: %s\n' "$board"
}

command_refresh() {
  local staged
  staged=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-project-cockpit.XXXXXX") \
    || fail "cannot stage cockpit projection"
  if ! "$SCRIPT_DIR/fm-project-cockpit-snapshot.sh" > "$staged"; then
    rm -f -- "$staged"
    fail "cannot project the fleet snapshot"
  fi
  command_build "$staged"
  rm -f -- "$staged"
}

lavish_session_open() {  # <canonical-board>
  lavish-axi 2>/dev/null | awk -v path="$1" '
    { line=$0; sub(/^[[:space:]]+/, "", line) }
    index(line, path ",") == 1 {
      rest=substr(line, length(path) + 2); split(rest, field, ",")
      if (field[1] == "open") found=1
    }
    END { exit found ? 0 : 1 }
  '
}

command_serve() {  # <payload>
  local board real out
  command_build "$1"
  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  board=$(board_path)
  real=$(perl -MCwd=realpath -e '$p=realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$board") \
    || fail "cannot resolve the cockpit artifact path"
  out=$(lavish-axi "$board") || fail "cannot establish the cockpit Lavish session"
  printf '%s\n' "$out"
  lavish_session_open "$real" || fail "the cockpit Lavish session is not listed open"
  printf 'served: %s\n' "$board"
}

case "${1-}" in
  build)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    command_build "$2"
    ;;
  refresh)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    command_refresh
    ;;
  serve)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    command_serve "$2"
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
