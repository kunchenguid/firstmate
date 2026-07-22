#!/usr/bin/env bash
# Non-executing migration for watcher PR checks created by older Firstmate
# versions. Legacy check files are never run, sourced, or parsed by Bash.
# Canonical polls are rebuilt from validated metadata, provenance-bound polls
# and registered custom checks remain armed, and every other task poll is
# quarantined for private review. A current X-mode shim is preserved by exact
# content, while the recognized older byte-static shim is refreshed in place.
# Usage: fm-pr-check-migrate.sh [--checks-safe]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TEMPLATE="$SCRIPT_DIR/fm-pr-poll.sh"
LOG="$STATE/.pr-check-migration.log"
QUARANTINE="$STATE/.pr-check-quarantine"
MARKER="$STATE/.pr-check-migration-v1"
MARKER_VALUE=fm-pr-check-migration-v1
SCAN_MARKER="$STATE/.pr-check-migration-scan-v1"
SCAN_MARKER_VALUE=fm-pr-check-migration-scan-v1
WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
NONCANONICAL_PREFIX='!noncanonical'
LEGACY_NONCANONICAL_PREFIX=_noncanonical

ALLOW_INCOMPLETE_REPAIRS=0
if [ "$#" -eq 1 ] && [ "$1" = --checks-safe ]; then
  ALLOW_INCOMPLETE_REPAIRS=1
elif [ "$#" -ne 0 ]; then
  echo "error: invalid PR check migration request" >&2
  exit 2
fi

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

umask 077
if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
  mkdir -p "$STATE" || {
    echo "PR_CHECK_MIGRATION: state directory could not be created; migration did not complete safely" >&2
    exit 1
  }
fi
if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "PR_CHECK_MIGRATION: state directory is not a private ordinary directory; migration did not complete safely" >&2
  exit 1
fi

migration_marker_content_valid() {
  local file=$1 value
  { exec 7< "$file"; } 2>/dev/null || return 1
  IFS= read -r value <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$value" = "$MARKER_VALUE" ]
}

scan_marker_content_valid() {
  local file=$1 value
  { exec 7< "$file"; } 2>/dev/null || return 1
  IFS= read -r value <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$value" = "$SCAN_MARKER_VALUE" ]
}

current_checks_authenticated() {
  local check id
  for check in "$STATE"/*.check.sh; do
    [ -e "$check" ] || [ -L "$check" ] || continue
    if [ "$(basename "$check")" = x-watch.check.sh ] \
      && fmx_poll_shim_valid "$check" "$FM_HOME" "$FM_ROOT"; then
      continue
    fi
    id=$(basename "$check" .check.sh)
    fm_custom_check_registered "$STATE" "$id" && continue
    fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE" || return 1
  done
}

private_migration_boundaries_valid() {
  local state_device=$1 artifact
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
    fm_pr_private_file_valid "$LOG" 600 "$state_device" || return 1
  fi
  if [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
    [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || return 1
    [ "$(fm_pr_file_mode "$QUARANTINE")" = 700 ] || return 1
    [ "$(fm_pr_file_device "$QUARANTINE")" = "$state_device" ] || return 1
    for artifact in "$QUARANTINE"/* "$QUARANTINE"/.[!.]* "$QUARANTINE"/..?*; do
      [ -e "$artifact" ] || [ -L "$artifact" ] || continue
      fm_pr_private_file_valid "$artifact" 600 "$state_device" || return 1
    done
  fi
}

diagnostic_file_is_one_line() {
  local file=$1 expected=$2 value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r value <&6 || { exec 6<&-; return 1; }
  if IFS= read -r _extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$value" = "$expected" ]
}

diagnostic_obligation_message() {
  local basename=$1 prefix kind suffix
  MIGRATION_DIAGNOSTIC_KIND=
  MIGRATION_DIAGNOSTIC_PREFIX=
  MIGRATION_DIAGNOSTIC_MESSAGE=
  kind=${basename##*.diagnostic.}
  suffix=".diagnostic.$kind"
  [ "$basename" != "$kind" ] || return 1
  prefix=${basename%"$suffix"}
  [ -n "$prefix" ] && [ "$prefix$suffix" = "$basename" ] || return 1
  if [ "$prefix" = "$NONCANONICAL_PREFIX" ] \
    || { [ "$prefix" = "$LEGACY_NONCANONICAL_PREFIX" ] \
      && { [ "$kind" = pending-noncanonical ] || [ "$kind" = noncanonical ]; }; }; then
    case "$kind" in
      pending-noncanonical)
        MIGRATION_DIAGNOSTIC_MESSAGE='noncanonical task artifact: migration outcome tracking started before legacy poll handling'
        ;;
      noncanonical)
        MIGRATION_DIAGNOSTIC_MESSAGE='noncanonical task artifact quarantined and unarmed'
        ;;
      *) return 1 ;;
    esac
  else
    fm_pr_task_id_valid "$prefix" || return 1
    case "$kind" in
      pending-canonical|pending-ambiguous)
        MIGRATION_DIAGNOSTIC_MESSAGE="task $prefix: migration outcome tracking started before legacy poll handling"
        ;;
      canonical)
        MIGRATION_DIAGNOSTIC_MESSAGE="task $prefix: canonical legacy poll rebuilt and armed"
        ;;
      failure-canonical)
        MIGRATION_DIAGNOSTIC_MESSAGE="task $prefix: canonical poll migration is incomplete; poll remains unarmed; repair its private artifacts, then rerun bootstrap"
        ;;
      failure-ambiguous)
        MIGRATION_DIAGNOSTIC_MESSAGE="task $prefix: ambiguous poll migration is incomplete; poll remains unarmed; repair its private artifacts, then rerun bootstrap"
        ;;
      failure-replacement)
        MIGRATION_DIAGNOSTIC_MESSAGE="task $prefix: replacement poll lacks canonical provenance or metadata binding; poll remains unarmed; republish it through fm-pr-check.sh"
        ;;
      ambiguous)
        MIGRATION_DIAGNOSTIC_MESSAGE="task $prefix: ambiguous or invalid legacy poll quarantined and unarmed"
        ;;
      validated)
        MIGRATION_DIAGNOSTIC_MESSAGE="task $prefix: validated replacement poll armed after legacy quarantine"
        ;;
      *) return 1 ;;
    esac
  fi
  MIGRATION_DIAGNOSTIC_KIND=$kind
  MIGRATION_DIAGNOSTIC_PREFIX=$prefix
}

quarantine_artifact_basename_valid() {
  local basename=$1 random stem kind prefix
  random=${basename##*.}
  [[ "$random" =~ ^[A-Za-z0-9]{6}$ ]] || return 1
  stem=${basename%.*}
  kind=${stem##*.}
  prefix=${stem%.*}
  case "$kind" in
    check|data|registration|replacement-check|replacement-data|replacement-registration) ;;
    *) return 1 ;;
  esac
  [ "$prefix" = "$NONCANONICAL_PREFIX" ] \
    || [ "$prefix" = "$LEGACY_NONCANONICAL_PREFIX" ] \
    || fm_pr_task_id_valid "$prefix"
}

diagnostic_namespace_valid() {
  local artifact basename
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  for artifact in "$QUARANTINE"/*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    basename=${artifact##*/}
    case "$basename" in
      *.diagnostic.*)
        if diagnostic_obligation_message "$basename"; then
          diagnostic_file_is_one_line "$artifact" "$MIGRATION_DIAGNOSTIC_MESSAGE" || return 1
        else
          quarantine_artifact_basename_valid "$basename" || return 1
        fi
        ;;
    esac
  done
}

legacy_noncanonical_namespace_absent() {
  local artifact
  for artifact in \
    "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.pending-noncanonical" \
    "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.noncanonical"; do
    [ ! -e "$artifact" ] && [ ! -L "$artifact" ] || return 1
  done
}

scan_complete() {
  local state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_private_file_valid "$SCAN_MARKER" 600 "$state_device" || return 1
  scan_marker_content_valid "$SCAN_MARKER" || return 1
  private_migration_boundaries_valid "$state_device" || return 1
  diagnostic_namespace_valid || return 1
  legacy_noncanonical_namespace_absent || return 1
  current_checks_authenticated
}

migration_complete() {
  local state_device obligation
  scan_complete || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  if [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
    for obligation in "$QUARANTINE"/*.diagnostic.pending-canonical \
      "$QUARANTINE"/*.diagnostic.pending-ambiguous \
      "$QUARANTINE"/*.diagnostic.pending-noncanonical \
      "$QUARANTINE"/*.diagnostic.failure-canonical \
      "$QUARANTINE"/*.diagnostic.failure-ambiguous \
      "$QUARANTINE"/*.diagnostic.failure-replacement; do
      [ -e "$obligation" ] || [ -L "$obligation" ] || continue
      return 1
    done
  fi
  fm_pr_private_file_valid "$MARKER" 600 "$state_device" || return 1
  migration_marker_content_valid "$MARKER"
}

x_shim_locked_scan_needed() {
  local shim="$STATE/x-watch.check.sh"
  [ -e "$shim" ] || [ -L "$shim" ] || return 1
  fmx_poll_shim_valid "$shim" "$FM_HOME" "$FM_ROOT" && return 1
  return 0
}

# Marker short-circuits apply only when generated artifact identities are current.
# Otherwise watcher exclusion comes before every check scan and state mutation.
if ! x_shim_locked_scan_needed; then
  migration_complete && exit 0
  [ "$ALLOW_INCOMPLETE_REPAIRS" -eq 1 ] && scan_complete && exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

stopped_watcher=0
pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
if fm_pid_alive "$pid"; then
  if ! fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$pid" "$FM_HOME"; then
    echo "PR_CHECK_MIGRATION: watcher ownership is ambiguous; review state/.watch.lock before rearming polls" >&2
    exit 1
  fi
  kill -TERM "$pid" 2>/dev/null || {
    echo "PR_CHECK_MIGRATION: watcher could not be paused; review state/.watch.lock before rearming polls" >&2
    exit 1
  }
  stopped_watcher=1
  i=0
  while [ "$i" -lt 100 ] && fm_pid_alive "$pid"; do
    sleep 0.05
    i=$((i + 1))
  done
  if fm_pid_alive "$pid"; then
    echo "PR_CHECK_MIGRATION: watcher did not pause; review state/.watch.lock before rearming polls" >&2
    exit 1
  fi
fi

lock_held=0
i=0
while [ "$i" -lt 100 ]; do
  if fm_lock_try_acquire "$WATCH_LOCK"; then
    lock_held=1
    break
  fi
  # A concurrent migration may have completed while this process waited.
  # Its validated marker proves the old watcher crossed the boundary, so this
  # process can continue to the normal watcher singleton instead of competing
  # with the newly started watcher for a second migration lock.
  if migration_complete && ! x_shim_locked_scan_needed; then
    exit 0
  fi
  sleep 0.05
  i=$((i + 1))
done
if [ "$lock_held" -ne 1 ]; then
  echo "PR_CHECK_MIGRATION: watcher exclusion could not be acquired; review state/.watch.lock before rearming polls" >&2
  exit 1
fi

MIGRATION_MARKER_TMP=
MIGRATION_SCAN_MARKER_TMP=
MIGRATION_LOG_TMP=
MIGRATION_OBLIGATION_TMP=
MIGRATION_QUARANTINE_TMP=
MIGRATION_X_SHIM_TMP=
migration_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$MIGRATION_X_SHIM_TMP" ] || rm -f -- "$MIGRATION_X_SHIM_TMP"
  [ -z "$MIGRATION_QUARANTINE_TMP" ] || rm -f -- "$MIGRATION_QUARANTINE_TMP"
  [ -z "$MIGRATION_OBLIGATION_TMP" ] || rm -f -- "$MIGRATION_OBLIGATION_TMP"
  [ -z "$MIGRATION_LOG_TMP" ] || rm -f -- "$MIGRATION_LOG_TMP"
  [ -z "$MIGRATION_MARKER_TMP" ] || rm -f -- "$MIGRATION_MARKER_TMP"
  [ -z "$MIGRATION_SCAN_MARKER_TMP" ] || rm -f -- "$MIGRATION_SCAN_MARKER_TMP"
  [ "$lock_held" -ne 1 ] || fm_lock_release "$WATCH_LOCK"
}
trap migration_cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "PR_CHECK_MIGRATION: state directory is not a private ordinary directory; migration did not complete safely" >&2
  exit 1
fi
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ -n "$STATE_DEVICE" ] || exit 1
refresh_v1_x_shim() {
  local shim="$STATE/x-watch.check.sh"
  fmx_poll_shim_v1_valid "$shim" "$FM_HOME" "$FM_ROOT" "$STATE_DEVICE" || return 0
  fm_pr_regular_destination_on_device_or_absent "$shim" "$STATE_DEVICE" || return 1
  MIGRATION_X_SHIM_TMP=$(mktemp "$STATE/.fm-x-watch.XXXXXX") || return 1
  fmx_poll_shim_content "$FM_HOME" "$FM_ROOT" > "$MIGRATION_X_SHIM_TMP" || return 1
  chmod 0700 "$MIGRATION_X_SHIM_TMP" || return 1
  fmx_poll_shim_valid "$MIGRATION_X_SHIM_TMP" "$FM_HOME" "$FM_ROOT" || return 1
  fmx_poll_shim_v1_valid "$shim" "$FM_HOME" "$FM_ROOT" "$STATE_DEVICE" || return 1
  mv -f -- "$MIGRATION_X_SHIM_TMP" "$shim" || return 1
  MIGRATION_X_SHIM_TMP=
  [ "$(fm_pr_file_device "$shim")" = "$STATE_DEVICE" ] || return 1
  [ "$(fm_pr_file_mode "$shim")" = 700 ] || return 1
  fmx_poll_shim_valid "$shim" "$FM_HOME" "$FM_ROOT"
}
if ! refresh_v1_x_shim; then
  echo "PR_CHECK_MIGRATION: authenticated X poll shim could not be refreshed; migration did not complete safely" >&2
  exit 1
fi
# A marker contradicted by a pending or failed obligation is not authoritative.
# Remove only an ordinary marker under exclusion; unsafe marker paths remain a
# hard refusal for the publication checks below.
if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
  fm_pr_private_file_valid "$MARKER" 600 "$STATE_DEVICE" || exit 1
  rm -f -- "$MARKER" || exit 1
  [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ] || exit 1
fi
if [ -e "$SCAN_MARKER" ] || [ -L "$SCAN_MARKER" ]; then
  fm_pr_private_file_valid "$SCAN_MARKER" 600 "$STATE_DEVICE" || exit 1
  rm -f -- "$SCAN_MARKER" || exit 1
  [ ! -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || exit 1
fi
migration_needed() {
  local check id
  for check in "$STATE"/*.check.sh; do
    [ -e "$check" ] || [ -L "$check" ] || continue
    if [ "$(basename "$check")" = x-watch.check.sh ] \
      && fmx_poll_shim_valid "$check" "$FM_HOME" "$FM_ROOT"; then
      continue
    fi
    id=$(basename "$check" .check.sh)
    fm_custom_check_registered "$STATE" "$id" && continue
    if ! fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE"; then
      return 0
    fi
  done
  return 1
}

unsafe_checks_absent() {
  local check id
  for check in "$STATE"/*.check.sh; do
    [ -e "$check" ] || [ -L "$check" ] || continue
    if [ "$(basename "$check")" = x-watch.check.sh ] \
      && fmx_poll_shim_valid "$check" "$FM_HOME" "$FM_ROOT"; then
      continue
    fi
    id=$(basename "$check" .check.sh)
    fm_custom_check_registered "$STATE" "$id" && continue
    fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE" || return 1
  done
}

revoke_migration_marker() {
  if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
    if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
      [ "$(fm_pr_file_link_count "$MARKER")" = 1 ] || return 1
    fi
    rm -f -- "$MARKER" || return 1
  fi
  [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ]
}

publish_migration_marker() {
  fm_pr_regular_destination_on_device_or_absent "$MARKER" "$STATE_DEVICE" || return 1
  MIGRATION_MARKER_TMP=$(mktemp "$STATE/.fm-pr-check-migration.XXXXXX") || return 1
  fm_pr_private_file_valid "$MIGRATION_MARKER_TMP" 600 "$STATE_DEVICE" || return 1
  printf '%s\n' "$MARKER_VALUE" > "$MIGRATION_MARKER_TMP" || return 1
  chmod 0600 "$MIGRATION_MARKER_TMP" || return 1
  migration_marker_content_valid "$MIGRATION_MARKER_TMP" || return 1
  fm_pr_regular_destination_on_device_or_absent "$MARKER" "$STATE_DEVICE" || return 1
  if ! mv -f -- "$MIGRATION_MARKER_TMP" "$MARKER"; then
    revoke_migration_marker || true
    return 1
  fi
  MIGRATION_MARKER_TMP=
  if ! migration_complete; then
    revoke_migration_marker || true
    return 1
  fi
}

revoke_scan_marker() {
  if [ -e "$SCAN_MARKER" ] || [ -L "$SCAN_MARKER" ]; then
    if [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ]; then
      [ "$(fm_pr_file_link_count "$SCAN_MARKER")" = 1 ] || return 1
    fi
    rm -f -- "$SCAN_MARKER" || return 1
  fi
  [ ! -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ]
}

publish_scan_marker() {
  fm_pr_regular_destination_on_device_or_absent "$SCAN_MARKER" "$STATE_DEVICE" || return 1
  MIGRATION_SCAN_MARKER_TMP=$(mktemp "$STATE/.fm-pr-check-scan.XXXXXX") || return 1
  fm_pr_private_file_valid "$MIGRATION_SCAN_MARKER_TMP" 600 "$STATE_DEVICE" || return 1
  printf '%s\n' "$SCAN_MARKER_VALUE" > "$MIGRATION_SCAN_MARKER_TMP" || return 1
  chmod 0600 "$MIGRATION_SCAN_MARKER_TMP" || return 1
  scan_marker_content_valid "$MIGRATION_SCAN_MARKER_TMP" || return 1
  fm_pr_regular_destination_on_device_or_absent "$SCAN_MARKER" "$STATE_DEVICE" || return 1
  if ! mv -f -- "$MIGRATION_SCAN_MARKER_TMP" "$SCAN_MARKER"; then
    revoke_scan_marker || true
    return 1
  fi
  MIGRATION_SCAN_MARKER_TMP=
  if ! scan_complete; then
    revoke_scan_marker || true
    return 1
  fi
}

quarantine_dir_valid() {
  [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || return 1
  [ "$(fm_pr_file_mode "$QUARANTINE")" = 700 ] || return 1
  [ "$(fm_pr_file_device "$QUARANTINE")" = "$STATE_DEVICE" ]
}

ensure_quarantine_dir() {
  if [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
    [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || return 1
    [ "$(fm_pr_file_device "$QUARANTINE")" = "$STATE_DEVICE" ] || return 1
  else
    mkdir "$QUARANTINE" || return 1
  fi
  chmod 0700 "$QUARANTINE" || return 1
  quarantine_dir_valid
}

quarantine_tree_repair_and_validate() {
  local artifact
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  ensure_quarantine_dir || return 1
  for artifact in "$QUARANTINE"/* "$QUARANTINE"/.[!.]* "$QUARANTINE"/..?*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 1
    [ "$(fm_pr_file_device "$artifact")" = "$STATE_DEVICE" ] || return 1
    [ "$(fm_pr_file_link_count "$artifact")" = 1 ] || return 1
    chmod 0600 "$artifact" || return 1
    [ "$(fm_pr_file_mode "$artifact")" = 600 ] || return 1
    [ "$(fm_pr_file_device "$artifact")" = "$STATE_DEVICE" ] || return 1
    [ "$(fm_pr_file_link_count "$artifact")" = 1 ] || return 1
  done
  quarantine_dir_valid
}

MIGRATION_PROVIDER=
MIGRATION_URL=
MIGRATION_HOST=
MIGRATION_PATH=
MIGRATION_NUMBER=
metadata_pr_is_canonical() {
  local meta=$1
  MIGRATION_PROVIDER=
  MIGRATION_URL=
  MIGRATION_HOST=
  MIGRATION_PATH=
  MIGRATION_NUMBER=
  fm_pr_metadata_identity_parse "$meta" || return 1
  MIGRATION_PROVIDER=$FM_PR_META_PROVIDER
  MIGRATION_URL=$FM_PR_META_URL
  MIGRATION_HOST=$FM_PR_META_HOST
  MIGRATION_PATH=$FM_PR_META_PATH
  MIGRATION_NUMBER=$FM_PR_META_NUMBER
}

quarantine_artifact() {
  local source=$1 prefix=$2 kind=$3 destination source_device
  [ -e "$source" ] || [ -L "$source" ] || return 0
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  quarantine_dir_valid || return 1
  source_device=$(fm_pr_file_device "$source") || return 1
  [ "$source_device" = "$STATE_DEVICE" ] || return 1
  [ "$(fm_pr_file_link_count "$source")" = 1 ] || return 1
  [ -z "$MIGRATION_QUARANTINE_TMP" ] || rm -f -- "$MIGRATION_QUARANTINE_TMP"
  MIGRATION_QUARANTINE_TMP=
  MIGRATION_QUARANTINE_TMP=$(mktemp "$QUARANTINE/$prefix.$kind.XXXXXX") || return 1
  [ -f "$MIGRATION_QUARANTINE_TMP" ] && [ ! -L "$MIGRATION_QUARANTINE_TMP" ] || return 1
  [ "$(fm_pr_file_device "$MIGRATION_QUARANTINE_TMP")" = "$STATE_DEVICE" ] || return 1
  destination=$MIGRATION_QUARANTINE_TMP
  rm -f -- "$destination" || return 1
  MIGRATION_QUARANTINE_TMP=
  quarantine_dir_valid || return 1
  mv -- "$source" "$destination" || return 1
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  [ "$(fm_pr_file_link_count "$destination")" = 1 ] || return 1
  chmod 0600 "$destination" || return 1
  [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
  [ "$(fm_pr_file_mode "$destination")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$destination")" = "$STATE_DEVICE" ] || return 1
  [ "$(fm_pr_file_link_count "$destination")" = 1 ] || return 1
  [ ! -e "$source" ] && [ ! -L "$source" ]
}

diagnostic_file_contains() {
  local file=$1 expected=$2 line
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(fm_pr_file_link_count "$file")" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "$expected" ] || return 0
  done < "$file"
  return 1
}

diagnostic_log_valid() {
  fm_pr_private_file_valid "$LOG" 600 "$STATE_DEVICE"
}

diagnostic_log_contains() {
  local expected=$1
  diagnostic_log_valid || return 1
  diagnostic_file_contains "$LOG" "$expected"
}

revoke_migration_log() {
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
    if [ -f "$LOG" ] && [ ! -L "$LOG" ]; then
      [ "$(fm_pr_file_link_count "$LOG")" = 1 ] || return 1
    fi
    rm -f -- "$LOG" || return 1
  fi
  [ ! -e "$LOG" ] && [ ! -L "$LOG" ]
}

record_diagnostic() {
  local message=$1
  diagnostic_log_contains "$message" && return 0
  fm_pr_regular_destination_on_device_or_absent "$LOG" "$STATE_DEVICE" || return 1
  [ ! -e "$LOG" ] || diagnostic_log_valid || return 1
  [ -z "$MIGRATION_LOG_TMP" ] || rm -f -- "$MIGRATION_LOG_TMP"
  MIGRATION_LOG_TMP=
  MIGRATION_LOG_TMP=$(mktemp "$STATE/.fm-pr-check-log.XXXXXX") || return 1
  [ -f "$MIGRATION_LOG_TMP" ] && [ ! -L "$MIGRATION_LOG_TMP" ] || return 1
  [ "$(fm_pr_file_device "$MIGRATION_LOG_TMP")" = "$STATE_DEVICE" ] || return 1
  if [ -f "$LOG" ]; then
    cp "$LOG" "$MIGRATION_LOG_TMP" || return 1
  fi
  printf '%s\n' "$message" >> "$MIGRATION_LOG_TMP" || return 1
  chmod 0600 "$MIGRATION_LOG_TMP" || return 1
  diagnostic_file_contains "$MIGRATION_LOG_TMP" "$message" || return 1
  fm_pr_regular_destination_on_device_or_absent "$LOG" "$STATE_DEVICE" || return 1
  if ! mv -f -- "$MIGRATION_LOG_TMP" "$LOG"; then
    return 1
  fi
  MIGRATION_LOG_TMP=
  if ! diagnostic_log_valid || ! diagnostic_log_contains "$message"; then
    revoke_migration_log || true
    return 1
  fi
}

migrate_legacy_quarantine_entry() {
  local source=$1 destination=$2
  fm_pr_private_file_valid "$source" 600 "$STATE_DEVICE" || return 1
  fm_pr_regular_destination_on_device_or_absent "$destination" "$STATE_DEVICE" || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    fm_pr_private_file_valid "$destination" 600 "$STATE_DEVICE" || return 1
    cmp -s "$source" "$destination" || return 1
    rm -f -- "$source" || return 1
  else
    mv -- "$source" "$destination" || return 1
  fi
  [ ! -e "$source" ] && [ ! -L "$source" ] \
    && fm_pr_private_file_valid "$destination" 600 "$STATE_DEVICE"
}

migrate_legacy_noncanonical_namespace() {
  local source basename suffix destination legacy_pending
  [ -e "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.pending-noncanonical" ] \
    || [ -L "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.pending-noncanonical" ] \
    || [ -e "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.noncanonical" ] \
    || [ -L "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.noncanonical" ] \
    || return 0
  quarantine_tree_repair_and_validate || return 1
  for source in "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.check."* \
    "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.data."* \
    "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.registration."*; do
    [ -e "$source" ] || [ -L "$source" ] || continue
    basename=${source##*/}
    suffix=${basename#"$LEGACY_NONCANONICAL_PREFIX"}
    destination="$QUARANTINE/$NONCANONICAL_PREFIX$suffix"
    migrate_legacy_quarantine_entry "$source" "$destination" || return 1
  done
  source="$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.noncanonical"
  destination="$QUARANTINE/$NONCANONICAL_PREFIX.diagnostic.noncanonical"
  if [ -e "$source" ] || [ -L "$source" ]; then
    migrate_legacy_quarantine_entry "$source" "$destination" || return 1
  fi
  legacy_pending="$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.pending-noncanonical"
  if [ -e "$legacy_pending" ] || [ -L "$legacy_pending" ]; then
    if diagnostic_obligation_valid "$NONCANONICAL_PREFIX" noncanonical \
      && quarantined_artifact_exists "$NONCANONICAL_PREFIX" check; then
      rm -f -- "$legacy_pending" || return 1
    else
      migrate_legacy_quarantine_entry "$legacy_pending" \
        "$QUARANTINE/$NONCANONICAL_PREFIX.diagnostic.pending-noncanonical" || return 1
    fi
  fi
  [ ! -e "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.pending-noncanonical" ] \
    && [ ! -L "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.pending-noncanonical" ] \
    && [ ! -e "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.noncanonical" ] \
    && [ ! -L "$QUARANTINE/$LEGACY_NONCANONICAL_PREFIX.diagnostic.noncanonical" ]
}

ensure_diagnostic_obligation() {
  local prefix=$1 kind=$2 message=$3 destination
  case "$kind" in
    pending-canonical|pending-ambiguous|pending-noncanonical|canonical|failure-canonical|failure-ambiguous|failure-replacement|ambiguous|validated|noncanonical) ;;
    *) return 1 ;;
  esac
  [ "$prefix" = "$NONCANONICAL_PREFIX" ] || fm_pr_task_id_valid "$prefix" || return 1
  ensure_quarantine_dir || return 1
  destination="$QUARANTINE/$prefix.diagnostic.$kind"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    fm_pr_private_file_valid "$destination" 600 "$STATE_DEVICE" || return 1
    diagnostic_file_is_one_line "$destination" "$message"
    return
  fi
  [ -z "$MIGRATION_OBLIGATION_TMP" ] || rm -f -- "$MIGRATION_OBLIGATION_TMP"
  MIGRATION_OBLIGATION_TMP=
  MIGRATION_OBLIGATION_TMP=$(mktemp "$QUARANTINE/.fm-pr-check-obligation.XXXXXX") || return 1
  printf '%s\n' "$message" > "$MIGRATION_OBLIGATION_TMP" || return 1
  chmod 0600 "$MIGRATION_OBLIGATION_TMP" || return 1
  diagnostic_file_is_one_line "$MIGRATION_OBLIGATION_TMP" "$message" || return 1
  fm_pr_regular_destination_on_device_or_absent "$destination" "$STATE_DEVICE" || return 1
  if ! mv -f -- "$MIGRATION_OBLIGATION_TMP" "$destination"; then
    return 1
  fi
  MIGRATION_OBLIGATION_TMP=
  if ! fm_pr_private_file_valid "$destination" 600 "$STATE_DEVICE" \
    || ! diagnostic_file_is_one_line "$destination" "$message"; then
    rm -f -- "$destination" || true
    return 1
  fi
}

ensure_outcome_obligation() {
  local prefix=$1 kind=$2 basename
  basename="$prefix.diagnostic.$kind"
  diagnostic_obligation_message "$basename" || return 1
  ensure_diagnostic_obligation "$prefix" "$kind" "$MIGRATION_DIAGNOSTIC_MESSAGE"
}

quarantined_artifact_exists() {
  local prefix=$1 kind=$2 artifact
  for artifact in "$QUARANTINE/$prefix.$kind."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    fm_pr_private_file_valid "$artifact" 600 "$STATE_DEVICE" || return 1
    return 0
  done
  return 1
}

diagnostic_obligation_valid() {
  local prefix=$1 kind=$2 path basename
  path="$QUARANTINE/$prefix.diagnostic.$kind"
  [ -e "$path" ] || [ -L "$path" ] || return 1
  fm_pr_private_file_valid "$path" 600 "$STATE_DEVICE" || return 1
  basename=${path##*/}
  diagnostic_obligation_message "$basename" || return 1
  diagnostic_file_is_one_line "$path" "$MIGRATION_DIAGNOSTIC_MESSAGE"
}

remove_diagnostic_obligation() {
  local prefix=$1 kind=$2 path
  path="$QUARANTINE/$prefix.diagnostic.$kind"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  diagnostic_obligation_valid "$prefix" "$kind" || return 1
  rm -f -- "$path" || return 1
  [ ! -e "$path" ] && [ ! -L "$path" ]
}

canonical_terminal_success() {
  local id=$1
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE" \
    && quarantined_artifact_exists "$id" check
}

ambiguous_terminal_success() {
  local id=$1 check data registration
  check="$STATE/$id.check.sh"
  data="$STATE/$id.pr-poll"
  registration="$STATE/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] \
    && [ ! -e "$data" ] && [ ! -L "$data" ] \
    && [ ! -e "$registration" ] && [ ! -L "$registration" ] \
    && quarantined_artifact_exists "$id" check
}

complete_canonical_outcome() {
  local id=$1
  canonical_terminal_success "$id" || return 1
  remove_diagnostic_obligation "$id" failure-canonical || return 1
  ensure_outcome_obligation "$id" canonical || return 1
  remove_diagnostic_obligation "$id" pending-canonical
}

complete_ambiguous_outcome() {
  local id=$1
  ambiguous_terminal_success "$id" || return 1
  remove_diagnostic_obligation "$id" failure-ambiguous || return 1
  ensure_outcome_obligation "$id" ambiguous || return 1
  remove_diagnostic_obligation "$id" pending-ambiguous
}

complete_validated_outcome() {
  local id=$1
  canonical_terminal_success "$id" || return 1
  remove_diagnostic_obligation "$id" failure-ambiguous || return 1
  remove_diagnostic_obligation "$id" failure-replacement || return 1
  remove_diagnostic_obligation "$id" ambiguous || return 1
  ensure_outcome_obligation "$id" validated || return 1
  remove_diagnostic_obligation "$id" pending-ambiguous
}

complete_noncanonical_outcome() {
  local prefix=${1:-$NONCANONICAL_PREFIX}
  quarantined_artifact_exists "$prefix" check || return 1
  ensure_outcome_obligation "$prefix" noncanonical || return 1
  remove_diagnostic_obligation "$prefix" pending-noncanonical
}

record_canonical_failure() {
  local id=$1
  remove_diagnostic_obligation "$id" canonical || return 1
  ensure_outcome_obligation "$id" failure-canonical
}

record_ambiguous_failure() {
  local id=$1
  remove_diagnostic_obligation "$id" ambiguous || return 1
  ensure_outcome_obligation "$id" failure-ambiguous
}

canonical_repair_from_pending() {
  local id=$1 meta data registration provider url host path number check
  meta="$STATE/$id.meta"
  data="$STATE/$id.pr-poll"
  registration="$STATE/$id.pr-poll-registration"
  check="$STATE/$id.check.sh"
  [ ! -e "$check" ] && [ ! -L "$check" ] || return 1
  quarantined_artifact_exists "$id" check || return 1
  metadata_pr_is_canonical "$meta" || return 1
  provider=$MIGRATION_PROVIDER
  url=$MIGRATION_URL
  host=$MIGRATION_HOST
  path=$MIGRATION_PATH
  number=$MIGRATION_NUMBER
  quarantine_artifact "$data" "$id" data || return 1
  quarantine_artifact "$registration" "$id" registration || return 1
  [ ! -e "$data" ] && [ ! -L "$data" ] || return 1
  [ ! -e "$registration" ] && [ ! -L "$registration" ] || return 1
  fm_pr_poll_prepare "$STATE" "$id" "$provider" "$url" "$host" "$path" "$number" "$TEMPLATE" || return 1
  fm_pr_poll_publish_prepared || return 1
  canonical_terminal_success "$id"
}

ambiguous_repair_from_pending() {
  local id=$1 check data registration
  check="$STATE/$id.check.sh"
  data="$STATE/$id.pr-poll"
  registration="$STATE/$id.pr-poll-registration"
  [ ! -e "$check" ] && [ ! -L "$check" ] || return 1
  quarantined_artifact_exists "$id" check || return 1
  quarantine_artifact "$data" "$id" data || return 1
  quarantine_artifact "$registration" "$id" registration || return 1
  ambiguous_terminal_success "$id"
}

live_check_matches_quarantined() {
  local id=$1 live artifact
  live="$STATE/$id.check.sh"
  [ -f "$live" ] && [ ! -L "$live" ] || return 1
  for artifact in "$QUARANTINE/$id.check."*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    fm_pr_private_file_valid "$artifact" 600 "$STATE_DEVICE" || return 1
    cmp -s "$live" "$artifact" && return 0
  done
  return 1
}

replacement_artifacts_present() {
  local id=$1 path
  for path in "$STATE/$id.check.sh" "$STATE/$id.pr-poll" "$STATE/$id.pr-poll-registration"; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    return 0
  done
  return 1
}

quarantine_untrusted_replacement() {
  local id=$1
  ensure_outcome_obligation "$id" failure-replacement || return 1
  quarantine_artifact "$STATE/$id.check.sh" "$id" replacement-check || return 1
  quarantine_artifact "$STATE/$id.pr-poll" "$id" replacement-data || return 1
  quarantine_artifact "$STATE/$id.pr-poll-registration" "$id" replacement-registration || return 1
}

recover_pending_outcomes() {
  local obligation basename prefix kind success failure replacement_failure check
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  quarantine_tree_repair_and_validate || return 1
  for obligation in "$QUARANTINE"/*.diagnostic.pending-canonical \
    "$QUARANTINE"/*.diagnostic.pending-ambiguous \
    "$QUARANTINE"/*.diagnostic.pending-noncanonical; do
    [ -e "$obligation" ] || [ -L "$obligation" ] || continue
    basename=${obligation##*/}
    diagnostic_obligation_message "$basename" || return 1
    prefix=$MIGRATION_DIAGNOSTIC_PREFIX
    kind=$MIGRATION_DIAGNOSTIC_KIND
    case "$kind" in
      pending-canonical)
        success="$QUARANTINE/$prefix.diagnostic.canonical"
        failure="$QUARANTINE/$prefix.diagnostic.failure-canonical"
        if canonical_terminal_success "$prefix"; then
          complete_canonical_outcome "$prefix" || return 1
          continue
        fi
        if [ -e "$success" ] || [ -L "$success" ]; then
          remove_diagnostic_obligation "$prefix" canonical || return 1
        fi
        check="$STATE/$prefix.check.sh"
        if [ ! -e "$check" ] && [ ! -L "$check" ]; then
          if quarantined_artifact_exists "$prefix" check; then
            ensure_outcome_obligation "$prefix" failure-canonical || return 1
            if canonical_repair_from_pending "$prefix"; then
              complete_canonical_outcome "$prefix" || return 1
            else
              migration_failed=1
            fi
          elif [ -e "$failure" ] || [ -L "$failure" ]; then
            migration_failed=1
          fi
        fi
        ;;
      pending-ambiguous)
        success="$QUARANTINE/$prefix.diagnostic.ambiguous"
        failure="$QUARANTINE/$prefix.diagnostic.failure-ambiguous"
        replacement_failure="$QUARANTINE/$prefix.diagnostic.failure-replacement"
        if canonical_terminal_success "$prefix"; then
          complete_validated_outcome "$prefix" || return 1
          continue
        fi
        if [ -e "$replacement_failure" ] || [ -L "$replacement_failure" ]; then
          if replacement_artifacts_present "$prefix"; then
            quarantine_untrusted_replacement "$prefix" || return 1
          fi
          migration_failed=1
          continue
        fi
        if quarantined_artifact_exists "$prefix" check \
          && { [ -e "$STATE/$prefix.check.sh" ] || [ -L "$STATE/$prefix.check.sh" ]; } \
          && ! live_check_matches_quarantined "$prefix"; then
          quarantine_untrusted_replacement "$prefix" || return 1
          migration_failed=1
          continue
        fi
        if ambiguous_terminal_success "$prefix"; then
          complete_ambiguous_outcome "$prefix" || return 1
          continue
        fi
        if [ -e "$success" ] || [ -L "$success" ]; then
          remove_diagnostic_obligation "$prefix" ambiguous || return 1
        fi
        check="$STATE/$prefix.check.sh"
        if [ ! -e "$check" ] && [ ! -L "$check" ]; then
          if quarantined_artifact_exists "$prefix" check; then
            ensure_outcome_obligation "$prefix" failure-ambiguous || return 1
            if ambiguous_repair_from_pending "$prefix"; then
              complete_ambiguous_outcome "$prefix" || return 1
            else
              migration_failed=1
            fi
          elif [ -e "$failure" ] || [ -L "$failure" ]; then
            migration_failed=1
          fi
        fi
        ;;
      pending-noncanonical)
        if quarantined_artifact_exists "$prefix" check; then
          complete_noncanonical_outcome "$prefix" || return 1
        fi
        ;;
    esac
  done
}

failure_obligations_absent() {
  local failure
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  for failure in "$QUARANTINE"/*.diagnostic.failure-canonical \
    "$QUARANTINE"/*.diagnostic.failure-ambiguous \
    "$QUARANTINE"/*.diagnostic.failure-replacement; do
    [ -e "$failure" ] || [ -L "$failure" ] || continue
    return 1
  done
}

pending_outcomes_complete() {
  local pending
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  for pending in "$QUARANTINE"/*.diagnostic.pending-canonical \
    "$QUARANTINE"/*.diagnostic.pending-ambiguous \
    "$QUARANTINE"/*.diagnostic.pending-noncanonical; do
    [ -e "$pending" ] || [ -L "$pending" ] || continue
    return 1
  done
}

canonical_rebuilt=0
validated_rearmed=0
quarantined_unarmed=0
process_diagnostic_obligations() {
  local obligation basename message
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  quarantine_tree_repair_and_validate || return 1
  diagnostic_namespace_valid || return 1
  for obligation in "$QUARANTINE"/*.diagnostic.pending-canonical \
    "$QUARANTINE"/*.diagnostic.pending-ambiguous \
    "$QUARANTINE"/*.diagnostic.pending-noncanonical \
    "$QUARANTINE"/*.diagnostic.canonical \
    "$QUARANTINE"/*.diagnostic.failure-canonical \
    "$QUARANTINE"/*.diagnostic.failure-ambiguous \
    "$QUARANTINE"/*.diagnostic.failure-replacement \
    "$QUARANTINE"/*.diagnostic.ambiguous \
    "$QUARANTINE"/*.diagnostic.validated \
    "$QUARANTINE"/*.diagnostic.noncanonical; do
    [ -e "$obligation" ] || [ -L "$obligation" ] || continue
    basename=${obligation##*/}
    diagnostic_obligation_message "$basename" || return 1
    message=$MIGRATION_DIAGNOSTIC_MESSAGE
    diagnostic_file_is_one_line "$obligation" "$message" || return 1
    record_diagnostic "$message" || return 1
    case "$MIGRATION_DIAGNOSTIC_KIND" in
      canonical) canonical_rebuilt=1 ;;
      validated) validated_rearmed=1 ;;
      ambiguous|noncanonical) quarantined_unarmed=1 ;;
    esac
  done
  for obligation in "$QUARANTINE"/*.diagnostic.pending-canonical \
    "$QUARANTINE"/*.diagnostic.pending-ambiguous \
    "$QUARANTINE"/*.diagnostic.pending-noncanonical \
    "$QUARANTINE"/*.diagnostic.canonical \
    "$QUARANTINE"/*.diagnostic.failure-canonical \
    "$QUARANTINE"/*.diagnostic.failure-ambiguous \
    "$QUARANTINE"/*.diagnostic.failure-replacement \
    "$QUARANTINE"/*.diagnostic.ambiguous \
    "$QUARANTINE"/*.diagnostic.validated \
    "$QUARANTINE"/*.diagnostic.noncanonical; do
    [ -e "$obligation" ] || [ -L "$obligation" ] || continue
    basename=${obligation##*/}
    diagnostic_obligation_message "$basename" || return 1
    diagnostic_log_contains "$MIGRATION_DIAGNOSTIC_MESSAGE" || return 1
  done
}

diagnostics_failed=0
migration_failed=0
if ! quarantine_tree_repair_and_validate \
  || ! diagnostic_namespace_valid \
  || ! migrate_legacy_noncanonical_namespace \
  || ! diagnostic_namespace_valid \
  || ! recover_pending_outcomes \
  || ! process_diagnostic_obligations; then
  diagnostics_failed=1
  migration_failed=1
fi

if migration_needed; then
  if ! ensure_quarantine_dir; then
    echo "PR_CHECK_MIGRATION: private quarantine is unavailable; migration did not complete safely" >&2
    exit 1
  fi

  for check in "$STATE"/*.check.sh; do
    [ -e "$check" ] || [ -L "$check" ] || continue
    if [ "$(basename "$check")" = x-watch.check.sh ] \
      && fmx_poll_shim_valid "$check" "$FM_HOME" "$FM_ROOT"; then
      continue
    fi
    id=$(basename "$check" .check.sh)
    fm_custom_check_registered "$STATE" "$id" && continue
    fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE" && continue

    if fm_pr_task_id_valid "$id"; then
      prefix=$id
      meta="$STATE/$id.meta"
      data="$STATE/$id.pr-poll"
      registration="$STATE/$id.pr-poll-registration"
      if metadata_pr_is_canonical "$meta"; then
        provider=$MIGRATION_PROVIDER
        url=$MIGRATION_URL
        host=$MIGRATION_HOST
        path=$MIGRATION_PATH
        number=$MIGRATION_NUMBER
        message="task $id: migration outcome tracking started before legacy poll handling"
        if ! ensure_diagnostic_obligation "$prefix" pending-canonical "$message" \
          || ! process_diagnostic_obligations; then
          diagnostics_failed=1
          migration_failed=1
          continue
        fi
        if quarantine_artifact "$check" "$prefix" check \
          && quarantine_artifact "$data" "$prefix" data \
          && quarantine_artifact "$registration" "$prefix" registration \
          && fm_pr_poll_prepare "$STATE" "$id" "$provider" "$url" "$host" "$path" "$number" "$TEMPLATE" \
          && fm_pr_poll_publish_prepared \
          && complete_canonical_outcome "$id"; then
          :
        else
          migration_failed=1
          record_canonical_failure "$id" || diagnostics_failed=1
        fi
      else
        message="task $id: migration outcome tracking started before legacy poll handling"
        if ! ensure_diagnostic_obligation "$prefix" pending-ambiguous "$message" \
          || ! process_diagnostic_obligations; then
          diagnostics_failed=1
          migration_failed=1
          continue
        fi
        if quarantine_artifact "$check" "$prefix" check \
          && quarantine_artifact "$data" "$prefix" data \
          && quarantine_artifact "$registration" "$prefix" registration \
          && complete_ambiguous_outcome "$id"; then
          :
        else
          migration_failed=1
          record_ambiguous_failure "$id" || diagnostics_failed=1
        fi
      fi
    else
      message='noncanonical task artifact: migration outcome tracking started before legacy poll handling'
      if ! ensure_diagnostic_obligation "$NONCANONICAL_PREFIX" pending-noncanonical "$message" \
        || ! process_diagnostic_obligations; then
        diagnostics_failed=1
        migration_failed=1
        continue
      fi
      if quarantine_artifact "$check" "$NONCANONICAL_PREFIX" check \
        && quarantine_artifact "$STATE/$id.pr-poll" "$NONCANONICAL_PREFIX" data \
        && quarantine_artifact "$STATE/$id.pr-poll-registration" "$NONCANONICAL_PREFIX" registration \
        && complete_noncanonical_outcome; then
        :
      else
        migration_failed=1
      fi
    fi
  done
fi

if ! quarantine_tree_repair_and_validate \
  || ! diagnostic_namespace_valid \
  || ! process_diagnostic_obligations; then
  diagnostics_failed=1
  migration_failed=1
fi
if ! pending_outcomes_complete || ! failure_obligations_absent; then
  migration_failed=1
fi

scan_safe=0
if [ "$diagnostics_failed" -eq 0 ] && unsafe_checks_absent && publish_scan_marker; then
  scan_safe=1
else
  revoke_scan_marker || true
  migration_failed=1
fi

if [ "$migration_failed" -eq 0 ] && [ "$scan_safe" -eq 1 ]; then
  publish_migration_marker || migration_failed=1
fi

if [ "$migration_failed" -ne 0 ]; then
  if [ "$ALLOW_INCOMPLETE_REPAIRS" -eq 1 ] && [ "$scan_safe" -eq 1 ]; then
    exit 0
  fi
  if [ "$diagnostics_failed" -eq 1 ]; then
    echo "PR_CHECK_MIGRATION: private diagnostics are unavailable; migration did not complete safely" >&2
  else
    echo "PR_CHECK_MIGRATION: migration did not complete safely; inspect private state before rearming polls" >&2
  fi
  exit 1
fi

if [ "$canonical_rebuilt" -eq 1 ]; then
  echo "PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home"
fi
if [ "$validated_rearmed" -eq 1 ]; then
  echo "PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home"
fi
if [ "$quarantined_unarmed" -eq 1 ]; then
  echo "PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming"
fi
if [ "$canonical_rebuilt" -eq 0 ] && [ "$validated_rearmed" -eq 0 ] \
  && [ "$quarantined_unarmed" -eq 0 ] \
  && [ "$stopped_watcher" -eq 1 ]; then
  echo "PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home"
fi
