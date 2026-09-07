#!/usr/bin/env bash
# fm-graph-board.sh - build the static task-flow graph board.
#
# Usage:
#   fm-graph-board.sh build <board.json>
#   fm-graph-board.sh path
#   fm-graph-board.sh arm [--force]
#   fm-graph-board.sh disarm
#
# build validates one fm-pipeline-board.v1 snapshot, injects it into the
# shipped graph template, and atomically publishes $FM_HOME/.lavish/graph-board.html.
# The input may be an ordinary JSON file or a readable stream such as process substitution.
# path prints the stable board path for this home.
# arm registers a quiet check that rebuilds the board from fm-pipeline.sh board-json.
# disarm records a durable disable marker before retiring that registered check.
#
# The builder has no sensor, forge, server, watcher, or answer-source side effects.
# FM_GRAPH_BOARD_TEMPLATE overrides the shipped template path for tests only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TEMPLATE="${FM_GRAPH_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/graph-board/assets/graph-board-template.html}"
PLACEHOLDER='__FM_GRAPH_BOARD_DATA__'
BOARD_SCHEMA='fm-pipeline-board.v1'
CHECK_ID='graph-board'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
CHECK_DISABLED="$STATE/$CHECK_ID.disabled"
ARM_LOCK="$STATE/$CHECK_ID.lock"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

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

load_arm_helpers() {
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-check-lib.sh
  . "$SCRIPT_DIR/fm-check-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

check_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

check_content() {  # <home> <state>
  local home=$1 state=$2 pipeline board scratch
  pipeline="$SCRIPT_DIR/fm-pipeline.sh"
  board="$SCRIPT_DIR/fm-graph-board.sh"
  scratch="$state/.fm-graph-board-refresh.XXXXXX"
  # shellcheck disable=SC2016 # These are literal lines for the generated check script.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$state")" \
    'unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE TMPDIR FM_GRAPH_BOARD_TEMPLATE' \
    'tmp=' \
    '# shellcheck disable=SC2329 # Invoked by the success, error, and signal traps below.' \
    'cleanup() {' \
    '  local rc=$?' \
    '  trap - EXIT HUP INT TERM' \
    '  [ -z "${tmp:-}" ] || rm -f -- "$tmp" 2>/dev/null || true' \
    '  tmp=' \
    '  exit "$rc"' \
    '}' \
    'trap cleanup EXIT HUP INT TERM' \
    "tmp=\$(umask 077; mktemp $(printf '%q' "$scratch")) || exit 1" \
    'chmod 0600 "$tmp" || exit 1' \
    "if $(printf '%q' "$pipeline") board-json > \"\$tmp\"; then" \
    "  $(printf '%q' "$board") build \"\$tmp\" >/dev/null" \
    'else' \
    '  rc=$?' \
    '  exit "$rc"' \
    'fi'
}

CHECK_WRITE_TMP=
CHECK_WROTE=0

check_write() {  # <body>
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-graph-board-check.XXXXXX" 2>/dev/null) || return 1
  CHECK_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    CHECK_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    CHECK_WRITE_TMP=
    return 1
  fi
  CHECK_WRITE_TMP=
  CHECK_WROTE=1
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

check_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-graph-board-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

trust_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-graph-board-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_TRUST" > "$tmp" 2>/dev/null \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=
ARM_TRUST_BACKUP=
ARM_TRUST_WROTE=0
DISABLED_MARKER_STATE=absent
DISABLED_MARKER_WHAT=

arm_collision_free() {
  local want=$1 path
  if check_artifact_present "$CHECK_SHIM"; then
    [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
      && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
      && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] || return 1
  else
    check_artifact_present "$CHECK_TRUST" && return 1
  fi
  for path in \
    "$STATE/$CHECK_ID.pr-poll" \
    "$STATE/$CHECK_ID.pr-poll-registration" \
    "$STATE/$CHECK_ID.pr-poll-retirement" \
    "$STATE/$CHECK_ID.pr-poll-merge-notified"; do
    check_artifact_present "$path" && return 1
  done
  if check_artifact_present "$CHECK_TRUST" \
    && ! fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    return 1
  fi
}

arm_rollback() {
  [ -z "$CHECK_WRITE_TMP" ] || rm -f -- "$CHECK_WRITE_TMP"
  CHECK_WRITE_TMP=
  if [ -n "$ARM_TRUST_BACKUP" ]; then
    if mv -f -- "$ARM_TRUST_BACKUP" "$CHECK_TRUST" 2>/dev/null; then
      ARM_TRUST_BACKUP=
    else
      rm -f -- "$ARM_TRUST_BACKUP"
      ARM_TRUST_BACKUP=
    fi
  elif [ "$ARM_TRUST_WROTE" -eq 1 ]; then
    rm -f -- "$CHECK_TRUST"
  fi
  if [ -n "$ARM_BACKUP" ]; then
    if mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null; then
      ARM_BACKUP=
    else
      rm -f -- "$ARM_BACKUP"
      ARM_BACKUP=
    fi
  elif [ "$CHECK_WROTE" -eq 1 ]; then
    rm -f -- "$CHECK_SHIM"
  fi
  ARM_TRUST_WROTE=0
  CHECK_WROTE=0
}

arm_interrupted() {
  arm_rollback
  printf 'fm-graph-board.sh: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

arm_lock_release() {
  fm_lock_release "$ARM_LOCK" 2>/dev/null || true
}

arm_lock_acquire() {
  if fm_lock_try_acquire "$ARM_LOCK"; then
    trap arm_lock_release EXIT
    return 0
  fi
  if [ "${FM_LOCK_FAILURE:-}" = owner-create ]; then
    fail "could not create state/$CHECK_ID.lock (owner directory): no lock present after the attempt (allocation or filesystem error, or a stale-lock reclaim in flight); retry, and inspect the state directory if it repeats"
  fi
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    fail "another arm or disarm holds state/$CHECK_ID.lock (pid $FM_LOCK_HELD_PID); retry"
  fi
  fail "state/$CHECK_ID.lock is held or being reclaimed (holder unknown); retry"
}

marker_check() {
  local device
  DISABLED_MARKER_STATE=absent
  DISABLED_MARKER_WHAT=
  if [ -L "$CHECK_DISABLED" ]; then
    DISABLED_MARKER_STATE=invalid
    DISABLED_MARKER_WHAT=symlink
    return 0
  fi
  [ -e "$CHECK_DISABLED" ] || return 0
  if [ -d "$CHECK_DISABLED" ]; then
    DISABLED_MARKER_STATE=invalid
    DISABLED_MARKER_WHAT=directory
    return 0
  fi
  device=$(fm_pr_file_device "$STATE") || {
    DISABLED_MARKER_STATE=invalid
    DISABLED_MARKER_WHAT=unreadable
    return 0
  }
  if fm_pr_private_file_valid "$CHECK_DISABLED" 600 "$device"; then
    DISABLED_MARKER_STATE=valid
  else
    DISABLED_MARKER_STATE=invalid
    DISABLED_MARKER_WHAT='not a private regular file'
  fi
}

marker_write() {
  local device tmp
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-graph-board-disabled.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'disabled\n' > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_DISABLED" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_DISABLED"; then
    rm -f -- "$tmp"
    return 1
  fi
}

arm() {
  local force=${1:-0} want home state
  load_arm_helpers
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  arm_lock_acquire
  marker_check
  case "$DISABLED_MARKER_STATE" in
    valid)
      if [ "$force" -eq 1 ]; then
        rm -f -- "$CHECK_DISABLED" || return 1
        printf 'cleared: state/%s.disabled\n' "$CHECK_ID"
      else
        fail "graph-board is disabled by state/$CHECK_ID.disabled; run arm --force to clear it"
      fi
      ;;
    invalid)
      fail "state/$CHECK_ID.disabled marker is not a private regular file: $DISABLED_MARKER_WHAT; inspect and remove or repair it by hand, then arm"
      ;;
  esac
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  case "$STATE" in
    /*) state=$STATE ;;
    *) state=$(CDPATH='' cd -- "$STATE" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  want=$(check_content "$home" "$state")
  arm_collision_free "$want" || return 1
  ARM_BACKUP=
  ARM_TRUST_BACKUP=
  ARM_TRUST_WROTE=0
  CHECK_WROTE=0
  if check_artifact_present "$CHECK_TRUST"; then
    ARM_TRUST_BACKUP=$(trust_backup) || return 1
  fi
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(check_backup) || {
      [ -z "$ARM_TRUST_BACKUP" ] || rm -f -- "$ARM_TRUST_BACKUP"
      ARM_TRUST_BACKUP=
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! check_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    return 1
  fi
  ARM_TRUST_WROTE=1
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  [ -z "$ARM_TRUST_BACKUP" ] || rm -f -- "$ARM_TRUST_BACKUP"
  ARM_BACKUP=
  ARM_TRUST_BACKUP=
  ARM_TRUST_WROTE=0
  CHECK_WROTE=0
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  local retire_out
  load_arm_helpers
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  arm_lock_acquire
  # The marker is durable disable intent, not a receipt that a running check
  # stopped; write it first so a failed retire never loses that intent. A
  # check already running from its private snapshot is not cancelled by retire.
  marker_write || return 1
  retire_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" retire "$CHECK_ID" 2>&1) && {
    printf '%s\n' "$retire_out"
    return 0
  }
  fail "disable policy recorded at state/$CHECK_ID.disabled; the registered check was NOT retired ($retire_out); retry disarm, or retire it by hand with fm-check-register.sh retire $CHECK_ID"
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
  path) [ "$#" -eq 1 ] || { usage >&2; exit 2; }; board_path ;;
  arm)
    shift
    force=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --force) force=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown arm option: $1" ;;
      esac
    done
    arm "$force" || fail 'could not arm graph-board watcher check'
    ;;
  disarm)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    disarm || fail 'could not disarm graph-board watcher check'
    ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
