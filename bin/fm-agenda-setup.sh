#!/usr/bin/env bash
# Provision the private business agenda registry and authenticated watcher check.
# Usage: fm-agenda-setup.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$DATA/business-agenda.md"
CHECK="$STATE/agenda-scan.check.sh"
AGENDA_SETUP_TMP=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

agenda_setup_error() {
  printf 'agenda-setup: %s\n' "$*" >&2
}

agenda_setup_cleanup() {
  [ -z "$AGENDA_SETUP_TMP" ] || rm -f -- "$AGENDA_SETUP_TMP"
}

agenda_setup_dir() {
  local dir=$1 label=$2
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] \
      || { agenda_setup_error "$label directory is unavailable: $dir"; return 1; }
  else
    mkdir -p -- "$dir" \
      || { agenda_setup_error "could not create $label directory: $dir"; return 1; }
  fi
}

agenda_setup_canonical_dir() {
  local dir=$1 label=$2
  CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P \
    || { agenda_setup_error "could not resolve $label directory: $dir"; return 1; }
}

agenda_wrapper_content() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_ROOT_OVERRIDE=$(printf '%q' "$FM_ROOT")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_AGENDA_REGISTRY=$(printf '%q' "$REGISTRY")" \
    'CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}' \
    "case \"\$CHECK_TIMEOUT\" in ''|*[!0-9]*|0) printf '%s\\n' 'agenda-check-error: invalid FM_CHECK_TIMEOUT'; exit 2 ;; esac" \
    "trap 'printf \"%s\\n\" \"agenda-check-error: scanner interrupted\"; exit 124' HUP INT TERM" \
    ". $(printf '%q' "$FM_ROOT/bin/fm-timeout-lib.sh")" \
    "fm_run_timed \"\$CHECK_TIMEOUT\" $(printf '%q' "$FM_ROOT/bin/fm-agenda-scan.sh")" \
    'rc=$?' \
    'if [ "$rc" -ne 0 ]; then' \
    "  printf '%s\\n' \"agenda-check-error: scanner exited \$rc\"" \
    'fi' \
    'exit "$rc"'
}

[ "$#" -eq 0 ] || { agenda_setup_error 'usage: fm-agenda-setup.sh'; exit 2; }
[ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] \
  || { agenda_setup_error "home directory is unavailable: $FM_HOME"; exit 1; }
FM_ROOT=$(agenda_setup_canonical_dir "$FM_ROOT" root) || exit 1
FM_HOME=$(agenda_setup_canonical_dir "$FM_HOME" home) || exit 1
[ -f "$FM_ROOT/bin/fm-agenda-scan.sh" ] && [ ! -L "$FM_ROOT/bin/fm-agenda-scan.sh" ] \
  && [ -x "$FM_ROOT/bin/fm-agenda-scan.sh" ] \
  || { agenda_setup_error 'agenda scanner is unavailable'; exit 1; }
[ -f "$FM_ROOT/bin/fm-timeout-lib.sh" ] && [ ! -L "$FM_ROOT/bin/fm-timeout-lib.sh" ] \
  || { agenda_setup_error 'timeout library is unavailable'; exit 1; }

umask 077
trap agenda_setup_cleanup EXIT
trap 'exit 1' HUP INT TERM
agenda_setup_dir "$DATA" data || exit 1
agenda_setup_dir "$STATE" state || exit 1
DATA=$(agenda_setup_canonical_dir "$DATA" data) || exit 1
STATE=$(agenda_setup_canonical_dir "$STATE" state) || exit 1
REGISTRY="$DATA/business-agenda.md"
CHECK="$STATE/agenda-scan.check.sh"

DATA_DEVICE=$(fm_pr_file_device "$DATA") || exit 1
if [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
  fm_pr_regular_destination_on_device_or_absent "$REGISTRY" "$DATA_DEVICE" \
    || { agenda_setup_error "registry is unavailable: $REGISTRY"; exit 1; }
  chmod 0600 "$REGISTRY" \
    || { agenda_setup_error 'could not protect agenda registry'; exit 1; }
else
  AGENDA_SETUP_TMP=$(mktemp "$DATA/.business-agenda.XXXXXX") \
    || { agenda_setup_error 'could not create agenda registry'; exit 1; }
  cat > "$AGENDA_SETUP_TMP" <<'EOF'
# Business agenda registry.
# The bin/fm-agenda-scan.sh header owns the format and cadence reference.
- seller-outreach-followup | daily | seller-outreach | draft the daily follow-up | notify
- operations-monitoring | daily | monitoring | check active operational monitors | notify
- business-processes-update | weekly:mon | business-processes | draft the weekly update | notify
- captain-priorities-review | weekly:mon | captain | review weekly business priorities | do
# TODO: - financial-review | weekly:fri | captain | review weekly financials | do
# TODO: - content-plan | weekly:mon | captain | draft the weekly content plan | do
EOF
  chmod 0600 "$AGENDA_SETUP_TMP" \
    || { agenda_setup_error 'could not protect agenda registry'; exit 1; }
  fm_pr_regular_destination_on_device_or_absent "$REGISTRY" "$DATA_DEVICE" \
    || { agenda_setup_error "registry path is unavailable: $REGISTRY"; exit 1; }
  mv -f -- "$AGENDA_SETUP_TMP" "$REGISTRY" \
    || { agenda_setup_error 'could not publish agenda registry'; exit 1; }
  AGENDA_SETUP_TMP=
fi

STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
if ! fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || ! cmp -s "$CHECK" <(agenda_wrapper_content); then
  fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" \
    || { agenda_setup_error "check path is unavailable: $CHECK"; exit 1; }
  AGENDA_SETUP_TMP=$(mktemp "$STATE/.agenda-scan-check.XXXXXX") \
    || { agenda_setup_error 'could not create agenda check'; exit 1; }
  agenda_wrapper_content > "$AGENDA_SETUP_TMP" \
    || { agenda_setup_error 'could not write agenda check'; exit 1; }
  chmod 0700 "$AGENDA_SETUP_TMP" \
    || { agenda_setup_error 'could not protect agenda check'; exit 1; }
  fm_pr_private_file_valid "$AGENDA_SETUP_TMP" 700 "$STATE_DEVICE" \
    || { agenda_setup_error 'agenda check is unsafe'; exit 1; }
  fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" \
    || { agenda_setup_error "check path is unavailable: $CHECK"; exit 1; }
  mv -f -- "$AGENDA_SETUP_TMP" "$CHECK" \
    || { agenda_setup_error 'could not publish agenda check'; exit 1; }
  AGENDA_SETUP_TMP=
fi
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { agenda_setup_error 'agenda check is unsafe'; exit 1; }

if ! fm_custom_check_registered "$STATE" agenda-scan; then
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-check-register.sh" agenda-scan >/dev/null \
    || { agenda_setup_error 'could not register agenda check'; exit 1; }
fi
