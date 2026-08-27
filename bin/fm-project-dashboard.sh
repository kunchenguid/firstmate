#!/usr/bin/env bash
# fm-project-dashboard.sh - build and serve the read-only fleet project dashboard.
#
# Usage:
#   fm-project-dashboard.sh [refresh] [--select <project>]
#   fm-project-dashboard.sh build <data.json>
#   fm-project-dashboard.sh path
#
# refresh is the default command.
# It takes a fresh fm-project-dashboard.v1 snapshot, replaces the stable board
# at $FM_HOME/.lavish/project-dashboard.html, and opens or resumes its Lavish
# session.
# build validates and publishes a supplied snapshot before serving it.
# path prints the stable home-scoped board path.
#
# The board's recently-resolved captain decisions cover main-home work only.
# The canonical secondmate home summary omits a secondmate's completed
# captain-held rows, and this board does not widen that contract, so the board
# states that limitation once, globally.
#
# This board is read-only.
# It never binds captain answers, registers a process-event source, polls
# Lavish, merges, dispatches, archives, or mutates fleet records.
# Re-run refresh whenever current data is wanted.
#
# FM_PROJECT_DASHBOARD_TEMPLATE overrides the shipped template in tests only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
TEMPLATE="${FM_PROJECT_DASHBOARD_TEMPLATE:-$SCRIPT_DIR/../assets/project-dashboard-template.html}"
PLACEHOLDER='__FM_PROJECT_DASHBOARD_DATA__'
BOARD_SCHEMA=fm-project-dashboard.v1
STAGED_SNAPSHOT=

cleanup() {
  [ -z "$STAGED_SNAPSHOT" ] || rm -f -- "$STAGED_SNAPSHOT"
}
trap cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-project-dashboard: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/project-dashboard.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def optional_string: . == null or type == "string";
    def optional_https_url:
      . == null or
      (type == "string" and
       test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def owner_item:
      type == "object" and (.id | nonempty_string) and (.owner | nonempty_string);
    def project:
      type == "object"
      and (.name | nonempty_string)
      and (.description | type == "string")
      and (.status == "active" or .status == "needs_attention" or
           .status == "waiting" or .status == "idle_queued")
      and (.status_label | nonempty_string)
      and (.stale_risk | type == "boolean")
      and (.next_step | type == "string")
      and (.active_work | type == "array")
      and (.decisions | type == "array")
      and (.failures | type == "array")
      and (.unreadable | type == "array")
      and (.finished | type == "array")
      and (.waiting | type == "array")
      and (.queued | type == "array")
      and (.landed | type == "array")
      and (.resolved_decisions | type == "array")
      and ([.resolved_decisions[]
            | (.linkable | type == "boolean")
              and (.linkable == false or .url == null or (.url | optional_https_url))] | all)
      and (.prs | type == "array")
      and (.unattributed | type == "array")
      and (.deferred_decisions | type == "array")
      and (.secondmates | type == "array")
      and (.counts | type == "object")
      and (.last_activity == null or
           ((.last_activity.at | nonempty_string) and
            (.last_activity.age_days | type == "number") and
            (.last_activity.age_seconds | type == "number")))
      and ([.active_work[],.decisions[],.failures[],.unreadable[],.finished[],
            .waiting[],.queued[],.landed[],.resolved_decisions[],
            .unattributed[],.deferred_decisions[] | owner_item] | all)
      and ([.finished[]
            | (.linkable | type == "boolean")
              and (.linkable == false or .url == null or (.url | optional_https_url))] | all)
      and ([.prs[]
            | type == "object" and (.url | nonempty_string) and (.linkable | type == "boolean")
              and (.linkable == false or (.url | optional_https_url))] | all)
      and ([.secondmates[]
            | type == "object" and (.id | nonempty_string)
              and (.unavailable | type == "boolean") and (.in_clone_list | type == "boolean")] | all);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.stale_after_days | type == "number" and . >= 0 and floor == .)
    and (.selected_project | optional_string)
    and (.projects | type == "array")
    and (.disclosures | type == "array")
    and ([.disclosures[]
          | type == "object" and (.surface | nonempty_string) and (.reveal | nonempty_string)] | all)
    and ([.projects[] | project] | all)
    and (([.projects[].name] | unique | length) == (.projects | length))
    and (.selected_project as $selected
         | $selected == null or ([.projects[].name] | index($selected) != null))
    and (.summary | type == "object")
  ' "$1" >/dev/null
}

command_build() {  # <data.json>
  local data=${1-} board json tmp extracted
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "dashboard data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "dashboard data is not valid JSON: $data"
  validate_payload "$data" || fail "dashboard data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "dashboard template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "dashboard template does not carry exactly one data slot: $TEMPLATE"

  json=$(jq -c . "$data") || fail "cannot compact dashboard data"
  json=${json//</\\u003c}
  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.project-dashboard.XXXXXX") || fail "cannot stage dashboard"
  if ! DASHBOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{DASHBOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject dashboard data"
  fi
  extracted=$(sed -n '/<script id="project-dashboard-data" type="application\/json">/,/<\/script>/p' "$tmp" | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "built dashboard does not carry readable $BOARD_SCHEMA data"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish dashboard"
  fi
  printf 'board: %s\n' "$board"

  command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi is not installed"
  lavish-axi "$board" || fail "cannot establish dashboard Lavish session"
  printf 'served: %s\n' "$board"
}

command_refresh() {
  local selected=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --select)
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        selected=$2
        shift 2
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  STAGED_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-project-dashboard-snapshot.XXXXXX") \
    || fail "cannot stage dashboard snapshot"
  if [ -n "$selected" ]; then
    if ! "$SCRIPT_DIR/fm-project-dashboard-snapshot.sh" --json --select "$selected" > "$STAGED_SNAPSHOT"; then
      fail "cannot create dashboard snapshot"
    fi
  elif ! "$SCRIPT_DIR/fm-project-dashboard-snapshot.sh" --json > "$STAGED_SNAPSHOT"; then
    fail "cannot create dashboard snapshot"
  fi
  command_build "$STAGED_SNAPSHOT"
  rm -f -- "$STAGED_SNAPSHOT"
  STAGED_SNAPSHOT=
}

case "${1-}" in
  '') command_refresh ;;
  refresh) shift; command_refresh "$@" ;;
  build) shift; command_build "$@" ;;
  path) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
