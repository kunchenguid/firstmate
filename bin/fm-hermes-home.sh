#!/usr/bin/env bash
# Build a Firstmate-owned isolated Hermes home without modifying ~/.hermes.
# Usage: fm-hermes-home.sh task <target-home> <turn-ended-file>
#        fm-hermes-home.sh primary <target-home> [<firstmate-root>]
#
# task registers one on_session_end hook that touches the task's turn-ended file.
# primary registers the session-start nudge, passive turn-end guard, and terminal
# pre_tool_call watcher-arm seatbelt from the named Firstmate root.
# Existing session data under <target-home> is preserved for Hermes resume.
# config.yaml and Firstmate's hook script are replaced idempotently.
# A readable auth.json from HERMES_SOURCE_HOME, ambient HERMES_HOME, or
# $HOME/.hermes (in that order) is copied with mode 0600 when present; absence
# is allowed because providers may use ambient credentials.
# The source Hermes home is never changed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=${1:-}
TARGET=${2:-}
ARG3=${3:-}

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

case "$MODE" in
  task|primary) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
[ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$TARGET" in /*) ;; *) echo "error: Hermes target home must be absolute: $TARGET" >&2; exit 2 ;; esac
[ ! -L "$TARGET" ] || { echo "error: Hermes target home cannot be a symlink: $TARGET" >&2; exit 1; }
mkdir -p "$TARGET"
TARGET=$(cd "$TARGET" && pwd -P)
SOURCE=${HERMES_SOURCE_HOME:-${HERMES_HOME:-$HOME/.hermes}}
if [ -d "$SOURCE" ]; then
  SOURCE=$(cd "$SOURCE" && pwd -P)
  [ "$TARGET" != "$SOURCE" ] || { echo "error: refusing to use the captain's Hermes home as Firstmate integration state" >&2; exit 1; }
  if [ -f "$SOURCE/auth.json" ]; then
    install -m 600 "$SOURCE/auth.json" "$TARGET/auth.json"
  fi
fi

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\''/g"
  printf "'"
}

yaml_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/''/g"
  printf "'"
}

if [ "$MODE" = task ]; then
  TURNEND=$ARG3
  case "$TURNEND" in /*.turn-ended) ;; *) echo "error: task mode requires an absolute .turn-ended path" >&2; exit 2 ;; esac
  turnend_q=$(shell_quote "$TURNEND")
  cat > "$TARGET/fm-on-session-end.sh" <<EOF
#!/usr/bin/env bash
set -u
touch $turnend_q 2>/dev/null || true
exit 0
EOF
  chmod 700 "$TARGET/fm-on-session-end.sh"
  hook_q=$(yaml_quote "$TARGET/fm-on-session-end.sh")
  cat > "$TARGET/config.yaml" <<EOF
hooks:
  on_session_end:
    - command: $hook_q
      timeout: 10
hooks_auto_accept: true
EOF
else
  ROOT=${ARG3:-$(cd "$SCRIPT_DIR/.." && pwd)}
  case "$ROOT" in /*) ;; *) echo "error: Firstmate root must be absolute: $ROOT" >&2; exit 2 ;; esac
  ROOT=$(cd "$ROOT" && pwd -P)
  [ -x "$ROOT/bin/fm-sessionstart-nudge.sh" ] || { echo "error: not a Firstmate root: $ROOT" >&2; exit 1; }
  start_q=$(yaml_quote "$ROOT/bin/fm-sessionstart-nudge.sh")
  end_q=$(yaml_quote "$ROOT/bin/fm-turnend-guard-hermes.sh")
  arm_q=$(yaml_quote "$ROOT/bin/fm-arm-pretool-check.sh --hermes")
  cat > "$TARGET/config.yaml" <<EOF
hooks:
  on_session_start:
    - command: $start_q
      timeout: 10
  on_session_end:
    - command: $end_q
      timeout: 300
  pre_tool_call:
    - matcher: terminal
      command: $arm_q
      timeout: 10
hooks_auto_accept: true
EOF
fi
chmod 600 "$TARGET/config.yaml"
printf '%s\n' "$TARGET"
