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
. "$SCRIPT_DIR/fm-project-cockpit-contract.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
TEMPLATE="${FM_PROJECT_COCKPIT_TEMPLATE:-$SCRIPT_DIR/../assets/project-cockpit-template.html}"
PLACEHOLDER='__FM_PROJECT_COCKPIT_DATA__'
BOARD_SCHEMA=fm-project-cockpit.v1
MAX_BYTES=$FM_PROJECT_COCKPIT_MODEL_MAX_BYTES

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fm-project-cockpit-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/project-cockpit.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e \
    --arg schema "$BOARD_SCHEMA" \
    --argjson max_projects "$FM_PROJECT_COCKPIT_MAX_PROJECTS" \
    --argjson max_tasks_per_project "$FM_PROJECT_COCKPIT_MAX_TASKS_PER_PROJECT" \
    --argjson max_total_tasks "$FM_PROJECT_COCKPIT_MAX_TOTAL_TASKS" \
    --argjson max_decisions "$FM_PROJECT_COCKPIT_MAX_DECISIONS" \
    --argjson max_blockers "$FM_PROJECT_COCKPIT_MAX_BLOCKERS" \
    --argjson max_partial_reasons "$FM_PROJECT_COCKPIT_MAX_PARTIAL_REASONS" \
    --argjson max_string "$FM_PROJECT_COCKPIT_MAX_STRING" '
    def text($n): type == "string" and length <= $n;
    def nullable_text($n): . == null or text($n);
    def stamp: type == "string" and (try fromdateiso8601 catch null) != null;
    def date_or_stamp: type == "string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") or (try fromdateiso8601 catch null) != null);
    def nonnegative_integer: type == "number" and . >= 0 and floor == .;
    def https: . == null or (text(500) and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]<>]*)?$"));
    def task:
      type == "object"
      and (.id | text(128))
      and (.spawn_gen | nullable_text(128))
      and (.name | text(160))
      and (.project_id | text(128))
      and (.lane == "running" or .lane == "waiting" or .lane == "queued" or .lane == "recently_completed")
      and (.state | text(40))
      and (.state_source | text(40))
      and has("state_detail")
      and (.state_detail == null)
      and has("state_detail_status")
      and (.state_detail_status == "unavailable")
      and (.observed_at == null or (.observed_at | stamp))
      and ((has("completed_at") | not) or .completed_at == null or (.completed_at | date_or_stamp))
      and (.started_at == null or (.started_at | stamp))
      and (.elapsed_seconds == null or (.elapsed_seconds | nonnegative_integer))
      and (.crew | type == "object")
      and (.crew.liveness | text(40))
      and (.crew.summary | text(40))
      and (.crew.kind | text(40))
      and (.crew.harness | nullable_text(40))
      and (.crew.backend | nullable_text(40))
      and (.decisions | type == "array" and length <= $max_decisions and all(.[]; text(240)))
      and (.attention | type == "boolean")
      and (.hold == null or (.hold |
        type == "object"
        and (.classification | text(40))
        and (.actionable | type == "boolean")
        and (.question | nullable_text(240))
        and (.age_days == null or (.age_days | nonnegative_integer))
        and (.until == null or (.until | text(40)))
        and (.evidence | text(40))))
      and (.blockers | type == "array" and length <= $max_blockers and all(.[]; text(128)))
      and (.gate | type == "object")
      and (.gate.status | text(40))
      and (.gate.label | text(240))
      and (.artifacts | type == "object")
      and (.artifacts.pr_url | https)
      and (.artifacts.report | type == "object")
      and (.artifacts.report.status == "available" or .artifacts.report.status == "missing")
      and (.artifacts.report.path | nullable_text(500))
      and (.runtime_evidence | type == "object")
      and (.runtime_evidence.endpoint_status | text(40))
      and (.runtime_evidence.target | nullable_text(240))
      and (.runtime_evidence.worktree | nullable_text(500))
      and (.runtime_evidence.home | nullable_text(500))
      and (.events.status == "unavailable" or .events.status == "available")
      and (.events.items | type == "array" and length == 0)
      and (.events.reason | nullable_text(240))
      and (.terminal.status == "unavailable")
      and (.terminal.reason | nullable_text(240));
    type == "object"
    and .schema == $schema
    and (.generated | stamp)
    and (.observed_at | stamp)
    and (.age_seconds | nonnegative_integer)
    and (.stale_after_seconds | nonnegative_integer)
    and (.freshness == "fresh" or .freshness == "stale" or .freshness == "unavailable")
    and (.inventory | type == "object")
    and (.inventory | has("reason"))
    and (.inventory.status == "valid" or .inventory.status == "partial" or .inventory.status == "invalid" or .inventory.status == "empty" or .inventory.status == "unavailable")
    and (.inventory.reason | nullable_text(240))
    and (.inventory.partial_reasons | type == "array" and length <= $max_partial_reasons and all(.[]; text(240)))
    and (.inventory.truncated | type == "boolean")
    and (.counts | type == "object")
    and ([.counts.running,.counts.waiting,.counts.blocked,.counts.attention] | all(.[]; nonnegative_integer))
    and (.projects | type == "array" and length <= $max_projects)
    and ([(.projects[] | .tasks[])] | length <= $max_total_tasks)
    and all(.projects[];
      type == "object"
      and (.id | text(128))
      and (.label | text(128))
      and (.rank | nonnegative_integer)
      and (.attention_count | nonnegative_integer)
      and (.active_count | nonnegative_integer)
      and (.blocker_count | nonnegative_integer)
      and (.latest_phase | text(40))
      and has("last_observed_at")
      and (.last_observed_at == null or (.last_observed_at | stamp))
      and has("oldest_active_seconds")
      and (.oldest_active_seconds == null or (.oldest_active_seconds | nonnegative_integer))
      and (.total_task_count | nonnegative_integer)
      and has("truncated")
      and (.truncated | type == "boolean")
      and (.tasks | type == "array" and length <= $max_tasks_per_project and all(.[]; task)))
    and (.terminal.status == "unavailable")
    and (.terminal.reason | nullable_text(240))
    and (.limits == {projects:$max_projects,tasks_per_project:$max_tasks_per_project,total_tasks:$max_total_tasks,strings:$max_string})
  ' "$1" >/dev/null
}

command_build() {  # <payload>
  local data=$1 board tmp compact extracted canonical_source canonical_embedded bytes line
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
  if ! while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$PLACEHOLDER" ]; then
      printf '%s\n' "$compact"
    else
      printf '%s\n' "$line"
    fi
  done < "$TEMPLATE" > "$tmp"; then
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
