#!/usr/bin/env bash
# fm-graph-board.sh - build the static task-flow graph board.
#
# Usage:
#   fm-graph-board.sh build <board.json>
#   fm-graph-board.sh path
#
# build validates one fm-pipeline-board.v1 snapshot, injects it into the
# shipped graph template, and atomically publishes $FM_HOME/.lavish/graph-board.html.
# The input may be an ordinary JSON file or a readable stream such as process substitution.
# path prints the stable board path for this home.
#
# The builder has no sensor, forge, server, watcher, or answer-source side effects.
# FM_GRAPH_BOARD_TEMPLATE overrides the shipped template path for tests only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
TEMPLATE="${FM_GRAPH_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/graph-board/assets/graph-board-template.html}"
PLACEHOLDER='__FM_GRAPH_BOARD_DATA__'
BOARD_SCHEMA='fm-pipeline-board.v1'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-graph-board: %s\n' "$*" >&2
  exit 1
}

board_path() {
  printf '%s/.lavish/graph-board.html\n' "$FM_HOME"
}

validate_and_compact() {
  local data=$1
  jq -c -s --arg schema "$BOARD_SCHEMA" '
    def text: type == "string";
    def nonempty_text: text and length > 0;
    def nullable_text: . == null or text;
    def valid_steps:
      type == "object"
      and (.nodes | type == "array")
      and all(.nodes[]; nonempty_text)
      and (.edges | type == "array")
      and all(.edges[];
        type == "object"
        and (.from | nonempty_text)
        and (.to | nonempty_text));
    def valid_task:
      type == "object"
      and (.id | nonempty_text)
      and (.kind | nonempty_text)
      and (.gen | nonempty_text)
      and (.steps | valid_steps)
      and ((has("step") | not) or (.step | nullable_text))
      and ((has("step_rev") | not) or (.step_rev == null or (.step_rev | type == "number" and floor == .)))
      and ((has("step_ts") | not) or (.step_ts | nullable_text))
      and ((has("step_evidence") | not) or (.step_evidence | nullable_text))
      and (.crew_state | type == "object")
      and ((.crew_state | has("verb") | not) or (.crew_state.verb | text))
      and ((.crew_state | has("source") | not) or (.crew_state.source | text))
      and ((.crew_state | has("ts") | not) or (.crew_state.ts | text))
      and (.waits | type == "array")
      and ((.probe_last == null) or (.probe_last | type == "object"))
      and ((.probe_last == null) or ((.probe_last | has("verdict") | not) or (.probe_last.verdict | text)))
      and ((.probe_last == null) or ((.probe_last | has("ts") | not) or (.probe_last.ts | text)))
      and ((.probe_last == null) or ((.probe_last | has("evidence") | not) or (.probe_last.evidence | text)))
      and (.initialized | type == "boolean")
      and (.step_proven | type == "boolean")
      and (.record_state | nonempty_text);
    def valid_payload:
      type == "object"
      and (.schema == $schema)
      and (.tasks | type == "array")
      and all(.tasks[]; valid_task);
    if length == 1 and (.[0] | valid_payload) then .[0] else error("invalid board payload") end
  ' "$data"
}

command_build() {
  local data=${1-} board json tmp extracted
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || fail 'jq is required'
  command -v perl >/dev/null 2>&1 || fail 'perl is required'
  [ -r "$data" ] || fail "board data is not readable: $data"
  json=$(validate_and_compact "$data" 2>/dev/null) \
    || fail "board data does not satisfy $BOARD_SCHEMA: $data"
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] \
    || fail "board template is missing: $TEMPLATE"
  [ "$(awk -v slot="$PLACEHOLDER" '$0 == slot { count += 1 } END { print count + 0 }' "$TEMPLATE")" -eq 1 ] \
    || fail "board template does not carry exactly one data slot: $TEMPLATE"

  json=${json//</\\u003c}
  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  [ ! -d "$board" ] || fail "board destination is a directory: $board"
  tmp=$(umask 077; mktemp "${board%/*}/.graph-board.XXXXXX") \
    || fail 'cannot stage the graph board'
  trap 'rm -f -- "${tmp:-}"' EXIT
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    fail 'cannot inject the graph board data'
  fi
  if [ "$(awk -v slot="$PLACEHOLDER" '$0 == slot { count += 1 } END { print count + 0 }' "$tmp")" -ne 0 ]; then
    fail 'the graph board data slot survived injection'
  fi
  extracted=$(awk '
    /<script id="graph-board-data" type="application\/json">/ { inside = 1; next }
    /<\/script>/ { if (inside) exit; }
    inside { print }
  ' "$tmp") || fail 'cannot read the injected graph board data'
  printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1 \
    || fail "the built board does not carry a readable $BOARD_SCHEMA payload"

  chmod 0600 "$tmp" || fail 'cannot protect the staged graph board'
  mv -f -- "$tmp" "$board" || fail 'cannot publish the graph board'
  tmp=
  trap - EXIT
  printf 'board: %s\n' "$board"
}

case "${1-}" in
  build) shift; command_build "$@" ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
