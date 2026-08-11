#!/usr/bin/env bash
# Provision the private recurring routine registry and authenticated watcher check.
# Usage: fm-routine-setup.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/routines.md"
CHECK="$STATE/routine-scan.check.sh"
ROUTINE_SETUP_TMP=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

routine_setup_error() {
  printf 'routine-setup: %s\n' "$*" >&2
}

routine_setup_cleanup() {
  [ -z "$ROUTINE_SETUP_TMP" ] || rm -f -- "$ROUTINE_SETUP_TMP"
}

routine_setup_dir() {
  local dir=$1 label=$2
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] \
      || { routine_setup_error "$label directory is unavailable: $dir"; return 1; }
  else
    mkdir -p -- "$dir" \
      || { routine_setup_error "could not create $label directory: $dir"; return 1; }
  fi
}

routine_setup_canonical_dir() {
  local dir=$1 label=$2
  if ! CDPATH='' cd -- "$dir" 2>/dev/null; then
    routine_setup_error "could not resolve $label directory: $dir"
    return 1
  fi
  pwd -P \
    || { routine_setup_error "could not resolve $label directory: $dir"; return 1; }
}

routine_wrapper_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_ROOT_OVERRIDE=$(printf '%q' "$FM_ROOT")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_ROUTINE_REGISTRY=$(printf '%q' "$REGISTRY")" \
    'export FM_ROUTINE_DEFER_FIRE=1' \
    "CHECK_TIMEOUT=\${FM_CHECK_TIMEOUT:-30}" \
    "case \"\$CHECK_TIMEOUT\" in ''|*[!0-9]*|0) printf '%s\\n' 'routine-check-error: invalid FM_CHECK_TIMEOUT'; exit 2 ;; esac" \
    "trap 'printf \"%s\\n\" \"routine-check-error: scanner interrupted\"; exit 124' HUP INT TERM" \
    ". $(printf '%q' "$FM_ROOT/bin/fm-timeout-lib.sh")" \
    "fm_run_timed \"\$CHECK_TIMEOUT\" $(printf '%q' "$FM_ROOT/bin/fm-routine-scan.sh") \"\$@\" 2>&1" \
    'rc=$?' \
    "if [ \"\$rc\" -ne 0 ]; then" \
    "  printf '%s\\n' \"routine-check-error: scanner exited \$rc\"" \
    'fi' \
    "exit \"\$rc\""
}

[ "$#" -eq 0 ] || { routine_setup_error 'usage: fm-routine-setup.sh'; exit 2; }
[ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] \
  || { routine_setup_error "home directory is unavailable: $FM_HOME"; exit 1; }
FM_ROOT=$(routine_setup_canonical_dir "$FM_ROOT" root) || exit 1
FM_HOME=$(routine_setup_canonical_dir "$FM_HOME" home) || exit 1
[ -f "$FM_ROOT/bin/fm-routine-scan.sh" ] && [ ! -L "$FM_ROOT/bin/fm-routine-scan.sh" ] \
  && [ -x "$FM_ROOT/bin/fm-routine-scan.sh" ] \
  || { routine_setup_error 'routine scanner is unavailable'; exit 1; }
[ -f "$FM_ROOT/bin/fm-timeout-lib.sh" ] && [ ! -L "$FM_ROOT/bin/fm-timeout-lib.sh" ] \
  || { routine_setup_error 'timeout library is unavailable'; exit 1; }

umask 077
trap routine_setup_cleanup EXIT
trap 'exit 1' HUP INT TERM
routine_setup_dir "$DATA" data || exit 1
routine_setup_dir "$STATE" state || exit 1
DATA=$(routine_setup_canonical_dir "$DATA" data) || exit 1
STATE=$(routine_setup_canonical_dir "$STATE" state) || exit 1
REGISTRY="$DATA/routines.md"
CHECK="$STATE/routine-scan.check.sh"

DATA_DEVICE=$(fm_pr_file_device "$DATA") || exit 1
if [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
  fm_pr_regular_destination_on_device_or_absent "$REGISTRY" "$DATA_DEVICE" \
    || { routine_setup_error "registry is unavailable: $REGISTRY"; exit 1; }
  chmod 0600 "$REGISTRY" \
    || { routine_setup_error 'could not protect routine registry'; exit 1; }
else
  ROUTINE_SETUP_TMP=$(mktemp "$DATA/.routines.XXXXXX") \
    || { routine_setup_error 'could not create routine registry'; exit 1; }
  if ! cat > "$ROUTINE_SETUP_TMP" <<'EOF'
# Recurring routine registry.
# The bin/fm-routine-scan.sh header owns the format and cadence reference.
# Examples:
# - example-daily-check | daily | captain | check today's priorities | do
# - example-weekly-review | weekly:mon | captain | review the week | do
EOF
  then
    routine_setup_error 'could not write routine registry'
    exit 1
  fi
  chmod 0600 "$ROUTINE_SETUP_TMP" \
    || { routine_setup_error 'could not protect routine registry'; exit 1; }
  fm_pr_regular_destination_on_device_or_absent "$REGISTRY" "$DATA_DEVICE" \
    || { routine_setup_error "registry path is unavailable: $REGISTRY"; exit 1; }
  if ln "$ROUTINE_SETUP_TMP" "$REGISTRY" 2>/dev/null; then
    rm -f -- "$ROUTINE_SETUP_TMP" \
      || { routine_setup_error 'could not publish routine registry'; exit 1; }
    ROUTINE_SETUP_TMP=
  else
    rm -f -- "$ROUTINE_SETUP_TMP" \
      || { routine_setup_error 'could not discard routine registry seed'; exit 1; }
    ROUTINE_SETUP_TMP=
    [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ] \
      || { routine_setup_error "could not publish routine registry: $REGISTRY"; exit 1; }
    fm_pr_regular_destination_on_device_or_absent "$REGISTRY" "$DATA_DEVICE" \
      || { routine_setup_error "registry path is unavailable: $REGISTRY"; exit 1; }
    chmod 0600 "$REGISTRY" \
      || { routine_setup_error 'could not protect routine registry'; exit 1; }
  fi
fi
fm_pr_private_file_valid "$REGISTRY" 600 "$DATA_DEVICE" \
  || { routine_setup_error "routine registry is unsafe: $REGISTRY"; exit 1; }

STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
if ! fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || ! cmp -s "$CHECK" <(routine_wrapper_content); then
  fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" \
    || { routine_setup_error "check path is unavailable: $CHECK"; exit 1; }
  ROUTINE_SETUP_TMP=$(mktemp "$STATE/.routine-scan-check.XXXXXX") \
    || { routine_setup_error 'could not create routine check'; exit 1; }
  routine_wrapper_content > "$ROUTINE_SETUP_TMP" \
    || { routine_setup_error 'could not write routine check'; exit 1; }
  chmod 0700 "$ROUTINE_SETUP_TMP" \
    || { routine_setup_error 'could not protect routine check'; exit 1; }
  fm_pr_private_file_valid "$ROUTINE_SETUP_TMP" 700 "$STATE_DEVICE" \
    || { routine_setup_error 'routine check is unsafe'; exit 1; }
  fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" \
    || { routine_setup_error "check path is unavailable: $CHECK"; exit 1; }
  mv -f -- "$ROUTINE_SETUP_TMP" "$CHECK" \
    || { routine_setup_error 'could not publish routine check'; exit 1; }
  ROUTINE_SETUP_TMP=
fi
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { routine_setup_error 'routine check is unsafe'; exit 1; }

if ! fm_custom_check_registered "$STATE" routine-scan; then
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-check-register.sh" routine-scan >/dev/null \
    || { routine_setup_error 'could not register routine check'; exit 1; }
fi
