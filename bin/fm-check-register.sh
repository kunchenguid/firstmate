#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes, or retire a
# validated custom check or canonical PR poll without touching task metadata.
# Usage:
#   fm-check-register.sh <id>
#   fm-check-register.sh retire <id>
# New callers may use fm-check-unregister.sh <id> to remove only a custom check.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
invalid() { printf 'error: invalid custom check %s\n' "$1" >&2; exit 2; }

cmd_register() {
  local id=${1-} check trust state_device hash tmp
  if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$id"; then
    invalid registration
  fi

  check="$STATE/$id.check.sh"
  trust="$STATE/$id.check-trust"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  [ -f "$check" ] && [ ! -L "$check" ] || die "custom check is unavailable"
  state_device=$(fm_pr_file_device "$STATE") || exit 1
  fm_pr_private_file_valid "$check" 700 "$state_device" \
    || die "custom check is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$trust" "$state_device" \
    || die "custom check trust path is unavailable"
  hash=$(fm_custom_check_sha256 "$check") || die "custom check hash is unavailable"
  umask 077
  tmp=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
  trap '[ -z "${tmp:-}" ] || rm -f -- "$tmp"' EXIT HUP INT TERM
  printf '%s\n%s\n' fm-custom-check-v1 "$hash" > "$tmp" || exit 1
  chmod 0600 "$tmp" || exit 1
  fm_pr_regular_destination_on_device_or_absent "$trust" "$state_device" || exit 1
  mv -f -- "$tmp" "$trust" || exit 1
  tmp=
  fm_custom_check_registered "$STATE" "$id" || { rm -f -- "$trust"; exit 1; }
  printf 'registered: state/%s.check.sh\n' "$id"
}

artifact_present() { [ -e "$1" ] || [ -L "$1" ]; }

cmd_retire() {
  local id=${1-} check trust data registration receipt
  if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$id"; then
    invalid retirement
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"

  check="$STATE/$id.check.sh"
  trust="$STATE/$id.check-trust"
  data="$STATE/$id.pr-poll"
  registration="$STATE/$id.pr-poll-registration"
  receipt="$STATE/$id.pr-poll-retirement"

  if artifact_present "$trust"; then
    if artifact_present "$data" || artifact_present "$registration" \
      || artifact_present "$receipt"; then
      die "custom check has conflicting PR-poll sidecars: $id"
    fi
    fm_custom_check_registered "$STATE" "$id" \
      || die "custom check is not safely bound: $id"
    rm -f -- "$check" "$trust" || die "could not retire custom check: $id"
  elif artifact_present "$receipt"; then
    fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
      || die "PR poll retirement state is invalid: $id"
  elif artifact_present "$data" || artifact_present "$registration"; then
    fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
      || die "PR poll is not safely bound: $id"
    rm -f -- "$check" "$data" "$registration" \
      || die "could not retire PR poll: $id"
  elif artifact_present "$check"; then
    die "custom check is not safely bound: $id"
  fi

  if artifact_present "$check" || artifact_present "$trust" \
    || artifact_present "$data" || artifact_present "$registration" \
    || artifact_present "$receipt"; then
    die "check retirement is incomplete: $id"
  fi
  printf 'retired: %s\n' "$id"
}

case "${1-}" in
  retire) shift; cmd_retire "$@" ;;
  *) cmd_register "$@" ;;
esac
