#!/usr/bin/env bash
# fm-workstream-board.sh - build and arm the /workstreams lavish board.
#
# The board is the captain-facing interactive surface of /workstreams: the
# shipped template (.agents/skills/workstreams/assets/board-template.html) plus
# one injected fm-workstream-board.v1 JSON payload. This script owns the
# mechanics so the invoking agent's per-run work stays "compose the JSON, run
# build" - the agent never authors board UI at invocation time. It is a
# SIBLING of bin/fm-bearings-board.sh: both delegate the shared build sequence
# (injection, round-trip check, serve-then-bind-then-arm) to
# bin/fm-board-lib.sh, and each owns only its schema, template, and path.
#
# Usage:
#   fm-workstream-board.sh build <data.json>
#   fm-workstream-board.sh path
#
# build      Validate the payload and inject it into a fresh copy of the shipped
#            template at the stable board path. Establish or resume the Lavish
#            session on that board BEFORE binding and arming its answer source.
#            Bind to the keyed-answer intake (bin/fm-captain-hold.sh) ALWAYS
#            precedes arm (captain-hold-lifecycle's ordering rule, enforced by
#            the shared lib). Output starts with `board: <path>`, then includes
#            lavish-axi's session output and the remaining status:
#              served: <path>
#              bound: <source-id>
#              armed: <source-id>            (first registration)
#              already-armed: <source-id>    (registration already present)
# path       Print the stable board path for this home.
#
# Validation is fail-closed: the payload must be valid JSON with
# schema=fm-workstream-board.v1 and every renderer-consumed field must satisfy
# the types and item invariants below. Every waiting item's key is a
# captain-held TASK ID, so the bound keyed-answer intake can close or release
# that task at answer time. A workstream's `counts` object carries that lane's
# whole-lane state tallies, so the progress bar reports the lane and not
# whatever subset of rows the row cap left visible; it is REQUIRED whenever
# `more_tasks` is above zero, must carry all six state keys, and must total
# EXACTLY the lane - the rows it ships plus `more_tasks`. Anything else refuses
# before the existing board is touched.
#
# The board path is stable - $FM_HOME/.lavish/workstreams.html - so a
# re-invocation rebuilds the same file in place, keeping the same Lavish
# session URL and the same canonical process-event source id. The path is
# deliberately NOT .lavish/workstream-board.html: that name is the captain's
# hand-reviewed mockup (data/workstream-board/mockup.html) and its own Lavish
# session, which this board must never clobber.
#
# FM_WORKSTREAM_BOARD_TEMPLATE overrides the shipped template path (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

TEMPLATE="${FM_WORKSTREAM_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/workstreams/assets/board-template.html}"
PLACEHOLDER='__FM_WORKSTREAM_BOARD_DATA__'
BOARD_SCHEMA=fm-workstream-board.v1

FM_BOARD_FAIL_PREFIX=fm-workstream-board
# shellcheck source=bin/fm-board-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-board-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() { fm_board_fail "$@"; }

board_path() { printf '%s/.lavish/workstreams.html\n' "$FM_HOME"; }

validate_payload() {  # <data.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def nonempty_string: type == "string" and length > 0;
    def slug($max): type == "string" and test("^[A-Za-z0-9._-]{1," + ($max | tostring) + "}$");
    def optional_string($name): (has($name) | not) or (.[$name] | type == "string");
    def optional_https_url($name):
      (has($name) | not)
      or (.[$name]
        | type == "string"
          and test("^https://[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::[0-9]{1,5})?(?:[/?#][^[:space:]]*)?$"));
    def tone: . == "working" or . == "paused" or . == "decision";
    def whole_number: type == "number" and . >= 0 and (floor == .);
    def lane_counts($total):
      type == "object"
      and ((keys - ["active", "decision", "done", "held", "queued", "review"]) | length) == 0
      and ([.done, .review, .active, .held, .decision, .queued] | all(whole_number))
      and (([.done, .review, .active, .held, .decision, .queued] | add) == $total);
    def task_item:
      type == "object"
      and (.id | slug(128))
      and (.title | nonempty_string)
      and (.state == "done" or .state == "review" or .state == "active"
           or .state == "held" or .state == "decision" or .state == "queued")
      and optional_string("doing")
      and optional_string("contract")
      and ((has("agent") | not) or ((.agent | nonempty_string) and (.agent_tone | tone)))
      and ((has("agent_tone") | not) or (.agent_tone | tone))
      and optional_https_url("pr_url");
    def ws_item:
      type == "object"
      and (.id | slug(128))
      and (.name | nonempty_string)
      and optional_string("outcome")
      and (.tasks | type == "array")
      and ([.tasks[] | task_item] | all)
      and ((has("more_tasks") | not) or (.more_tasks | whole_number))
      and (((.tasks | length) + (.more_tasks // 0)) as $total
        | if has("counts") then (.counts | lane_counts($total))
          else (.more_tasks // 0) == 0 end);
    def edge_item:
      type == "object" and (.from | slug(128)) and (.to | slug(128));
    def wait_item:
      type == "object"
      and (.key | slug(128))
      and (.title | nonempty_string)
      and optional_string("question")
      and (.options | type == "array")
      and ((.options | length) > 0 or .allow_freeform == true)
      and ([.options[]
        | type == "object"
          and (.value | slug(128))
          and (.label | nonempty_string)
          and optional_string("hint")] | all)
      and ((has("allow_freeform") | not) or (.allow_freeform | type == "boolean"))
      and optional_string("freeform_hint")
      and ((has("recommend_value") | not)
        or ((.recommend_value | slug(128))
          and (.recommend_value as $recommend | [.options[].value] | index($recommend) != null)))
      and ((has("close") | not) or (.close == "done" or .close == "release"));
    def agent_item:
      type == "object" and (.id | nonempty_string)
      and (.tone | tone) and optional_string("doing");
    def divergence_item:
      type == "object" and (.id | nonempty_string) and (.note | nonempty_string);
    type == "object"
    and (.schema == $schema)
    and (.home | nonempty_string)
    and (.generated | nonempty_string)
    and (.workstreams | type == "array")
    and (.edges | type == "array")
    and (.waiting | type == "array")
    and (.agents | type == "array")
    and (.divergence | type == "array")
    and ([.workstreams[] | ws_item] | all)
    and ([.edges[] | edge_item] | all)
    and ([.waiting[] | wait_item] | all)
    and ([.agents[] | agent_item] | all)
    and ([.divergence[] | divergence_item] | all)
  ' "$1" >/dev/null
}

command_build() {
  local data=${1-} board
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -f "$data" ] || fail "board data does not exist: $data"
  jq empty "$data" 2>/dev/null || fail "board data is not valid JSON: $data"
  validate_payload "$data" || fail "board data does not satisfy $BOARD_SCHEMA: $data"

  board=$(board_path)
  fm_board_publish "$data" "$TEMPLATE" "$PLACEHOLDER" "$BOARD_SCHEMA" "$board" "workstream-data"
  fm_board_serve_bind_arm "$board"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
