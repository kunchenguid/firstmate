#!/usr/bin/env bash
# Non-executing migration for watcher PR checks created by older Firstmate
# versions. Legacy check files are never run, sourced, or parsed by Bash.
# Canonical polls are rebuilt from validated metadata; every other task poll is
# quarantined for private review. The X-mode shim is preserved by its fixed name.
# Usage: fm-pr-check-migrate.sh
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
WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"

if [ "$#" -ne 0 ]; then
  echo "error: invalid PR check migration request" >&2
  exit 2
fi

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

migration_marker_content_valid() {
  local file=$1 value
  exec 7< "$file" 2>/dev/null || return 1
  IFS= read -r value <&7 || { exec 7<&-; return 1; }
  if IFS= read -r _extra <&7; then
    exec 7<&-
    return 1
  fi
  exec 7<&-
  [ "$value" = "$MARKER_VALUE" ]
}

migration_complete() {
  local state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  [ -f "$MARKER" ] && [ ! -L "$MARKER" ] || return 1
  [ "$(fm_pr_file_mode "$MARKER")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$MARKER")" = "$state_device" ] || return 1
  migration_marker_content_valid "$MARKER"
}

# A valid completion marker proves this home already crossed the one-time
# boundary. When it is absent or invalid, watcher exclusion comes before every
# check scan and before any marker or diagnostic publication.
migration_complete && exit 0

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
  migration_complete && exit 0
  sleep 0.05
  i=$((i + 1))
done
if [ "$lock_held" -ne 1 ]; then
  echo "PR_CHECK_MIGRATION: watcher exclusion could not be acquired; review state/.watch.lock before rearming polls" >&2
  exit 1
fi

MIGRATION_MARKER_TMP=
MIGRATION_LOG_TMP=
MIGRATION_QUARANTINE_TMP=
migration_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$MIGRATION_QUARANTINE_TMP" ] || rm -f -- "$MIGRATION_QUARANTINE_TMP"
  [ -z "$MIGRATION_LOG_TMP" ] || rm -f -- "$MIGRATION_LOG_TMP"
  [ -z "$MIGRATION_MARKER_TMP" ] || rm -f -- "$MIGRATION_MARKER_TMP"
  [ "$lock_held" -ne 1 ] || fm_lock_release "$WATCH_LOCK"
}
trap migration_cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "PR_CHECK_MIGRATION: state directory is not a private ordinary directory; migration remains incomplete" >&2
  exit 1
fi
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ -n "$STATE_DEVICE" ] || exit 1
umask 077

migration_needed() {
  local check id
  for check in "$STATE"/*.check.sh; do
    [ -e "$check" ] || [ -L "$check" ] || continue
    [ "$(basename "$check")" = x-watch.check.sh ] && continue
    id=$(basename "$check" .check.sh)
    if ! fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE"; then
      return 0
    fi
  done
  return 1
}

publish_migration_marker() {
  fm_pr_regular_destination_on_device_or_absent "$MARKER" "$STATE_DEVICE" || return 1
  MIGRATION_MARKER_TMP=$(mktemp "$STATE/.fm-pr-check-migration.XXXXXX") || return 1
  [ -f "$MIGRATION_MARKER_TMP" ] && [ ! -L "$MIGRATION_MARKER_TMP" ] || return 1
  [ "$(fm_pr_file_device "$MIGRATION_MARKER_TMP")" = "$STATE_DEVICE" ] || return 1
  printf '%s\n' "$MARKER_VALUE" > "$MIGRATION_MARKER_TMP" || return 1
  chmod 0600 "$MIGRATION_MARKER_TMP" || return 1
  migration_marker_content_valid "$MIGRATION_MARKER_TMP" || return 1
  fm_pr_regular_destination_on_device_or_absent "$MARKER" "$STATE_DEVICE" || return 1
  mv -f -- "$MIGRATION_MARKER_TMP" "$MARKER" || return 1
  migration_complete || return 1
  MIGRATION_MARKER_TMP=
}

quarantine_dir_valid() {
  [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || return 1
  [ "$(fm_pr_file_device "$QUARANTINE")" = "$STATE_DEVICE" ]
}

ensure_quarantine_dir() {
  if [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
    [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || return 1
  else
    mkdir "$QUARANTINE" || return 1
  fi
  quarantine_dir_valid || return 1
  chmod 0700 "$QUARANTINE" || return 1
  quarantine_dir_valid
}

MIGRATION_URL=
MIGRATION_OWNER=
MIGRATION_REPO=
MIGRATION_NUMBER=
metadata_pr_is_canonical() {
  local meta=$1 line value pr_count=0 seen_pr=0 post_pr_invalid=0
  MIGRATION_URL=
  MIGRATION_OWNER=
  MIGRATION_REPO=
  MIGRATION_NUMBER=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || continue
        value=${line#pr=}
        if fm_pr_url_parse "$value"; then
          MIGRATION_URL=$FM_PR_URL
          MIGRATION_OWNER=$FM_PR_OWNER
          MIGRATION_REPO=$FM_PR_REPO
          MIGRATION_NUMBER=$FM_PR_NUMBER
        fi
        seen_pr=1
        ;;
      pr_head=*)
        if [ "$seen_pr" -eq 1 ]; then
          value=${line#pr_head=}
          fm_pr_head_valid "$value" || post_pr_invalid=1
        fi
        ;;
      *)
        [ "$seen_pr" -eq 0 ] || post_pr_invalid=1
        ;;
    esac
  done < "$meta"
  [ "$pr_count" -eq 1 ] || return 1
  [ "$post_pr_invalid" -eq 0 ] || return 1
  [ -n "$MIGRATION_URL" ]
}

quarantine_artifact() {
  local source=$1 prefix=$2 kind=$3 destination source_device
  [ -e "$source" ] || [ -L "$source" ] || return 0
  [ ! -d "$source" ] || return 1
  quarantine_dir_valid || return 1
  source_device=$(fm_pr_file_device "$source") || return 1
  [ "$source_device" = "$STATE_DEVICE" ] || return 1
  MIGRATION_QUARANTINE_TMP=$(mktemp "$QUARANTINE/$prefix.$kind.XXXXXX") || return 1
  [ -f "$MIGRATION_QUARANTINE_TMP" ] && [ ! -L "$MIGRATION_QUARANTINE_TMP" ] || return 1
  [ "$(fm_pr_file_device "$MIGRATION_QUARANTINE_TMP")" = "$STATE_DEVICE" ] || return 1
  destination=$MIGRATION_QUARANTINE_TMP
  rm -f -- "$destination" || return 1
  MIGRATION_QUARANTINE_TMP=
  quarantine_dir_valid || return 1
  mv -- "$source" "$destination" || return 1
  [ "$(fm_pr_file_device "$destination")" = "$STATE_DEVICE" ] || return 1
  [ -L "$destination" ] || chmod 0600 "$destination" || return 1
}

diagnostic_last_line_is() {
  local file=$1 expected=$2 line last='' found=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    last=$line
    found=1
  done < "$file"
  [ "$found" -eq 1 ] && [ "$last" = "$expected" ]
}

record_diagnostic() {
  local message=$1
  fm_pr_regular_destination_on_device_or_absent "$LOG" "$STATE_DEVICE" || return 1
  MIGRATION_LOG_TMP=$(mktemp "$STATE/.fm-pr-check-log.XXXXXX") || return 1
  [ -f "$MIGRATION_LOG_TMP" ] && [ ! -L "$MIGRATION_LOG_TMP" ] || return 1
  [ "$(fm_pr_file_device "$MIGRATION_LOG_TMP")" = "$STATE_DEVICE" ] || return 1
  if [ -f "$LOG" ]; then
    cp "$LOG" "$MIGRATION_LOG_TMP" || return 1
  fi
  printf '%s\n' "$message" >> "$MIGRATION_LOG_TMP" || return 1
  chmod 0600 "$MIGRATION_LOG_TMP" || return 1
  diagnostic_last_line_is "$MIGRATION_LOG_TMP" "$message" || return 1
  fm_pr_regular_destination_on_device_or_absent "$LOG" "$STATE_DEVICE" || return 1
  mv -f -- "$MIGRATION_LOG_TMP" "$LOG" || return 1
  [ -f "$LOG" ] && [ ! -L "$LOG" ] || return 1
  [ "$(fm_pr_file_mode "$LOG")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$LOG")" = "$STATE_DEVICE" ] || return 1
  diagnostic_last_line_is "$LOG" "$message" || return 1
  MIGRATION_LOG_TMP=
}

diagnostics_added=0
diagnostics_failed=0
migration_failed=0
add_diagnostic() {
  local message=$1
  if record_diagnostic "$message"; then
    diagnostics_added=1
  else
    diagnostics_failed=1
    migration_failed=1
  fi
}

if migration_needed; then
  if ! ensure_quarantine_dir; then
    echo "PR_CHECK_MIGRATION: private quarantine is unavailable; migration remains incomplete" >&2
    exit 1
  fi

  for check in "$STATE"/*.check.sh; do
    [ -e "$check" ] || [ -L "$check" ] || continue
    [ "$(basename "$check")" = x-watch.check.sh ] && continue
    id=$(basename "$check" .check.sh)
    fm_pr_poll_artifacts_valid "$STATE" "$id" "$TEMPLATE" && continue

    if fm_pr_task_id_valid "$id"; then
      prefix=$id
      meta="$STATE/$id.meta"
      data="$STATE/$id.pr-poll"
      if metadata_pr_is_canonical "$meta"; then
        url=$MIGRATION_URL
        owner=$MIGRATION_OWNER
        repo=$MIGRATION_REPO
        number=$MIGRATION_NUMBER
        if ! quarantine_artifact "$check" "$prefix" check \
          || ! quarantine_artifact "$data" "$prefix" data \
          || ! fm_pr_poll_prepare "$STATE" "$id" "$url" "$owner" "$repo" "$number" "$TEMPLATE" \
          || ! fm_pr_poll_publish_prepared; then
          migration_failed=1
          add_diagnostic "task $id: migration was interrupted; poll remains unarmed pending private review"
        fi
      else
        if quarantine_artifact "$check" "$prefix" check \
          && quarantine_artifact "$data" "$prefix" data; then
          add_diagnostic "task $id: poll metadata is ambiguous or invalid; poll remains unarmed pending private review"
        else
          migration_failed=1
          add_diagnostic "task $id: quarantine was interrupted; inspect state artifacts before rearming"
        fi
      fi
    else
      if quarantine_artifact "$check" invalid check; then
        add_diagnostic "noncanonical task artifact: poll remains unarmed pending private review"
      else
        migration_failed=1
        add_diagnostic "noncanonical task artifact: quarantine was interrupted; inspect state artifacts before rearming"
      fi
    fi
  done
fi

if [ "$migration_failed" -eq 0 ]; then
  publish_migration_marker || migration_failed=1
fi

if [ "$migration_failed" -ne 0 ]; then
  if [ "$diagnostics_failed" -eq 1 ]; then
    echo "PR_CHECK_MIGRATION: private diagnostics could not be published; migration remains incomplete" >&2
  else
    echo "PR_CHECK_MIGRATION: migration remains incomplete; inspect private state before rearming polls" >&2
  fi
  exit 1
fi

if [ "$diagnostics_added" -eq 1 ]; then
  echo "PR_CHECK_MIGRATION: review state/.pr-check-migration.log before rearming polls"
elif [ "$stopped_watcher" -eq 1 ]; then
  echo "PR_CHECK_MIGRATION: canonical polls rebuilt; resume supervision for this home"
fi
