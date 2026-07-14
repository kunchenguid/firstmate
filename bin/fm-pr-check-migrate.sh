#!/usr/bin/env bash
# Non-executing migration for watcher PR checks created by older Firstmate
# versions. Legacy check files are never run, sourced, or parsed by Bash.
# Canonical polls are rebuilt from validated metadata; every other task poll is
# quarantined for private review. The X-mode shim is preserved by exact content.
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
NONCANONICAL_PREFIX=_noncanonical

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

scan_complete() {
  local state_device
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 1
  [ "$(fm_pr_file_mode "$SCAN_MARKER")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$SCAN_MARKER")" = "$state_device" ] || return 1
  scan_marker_content_valid "$SCAN_MARKER"
}

migration_complete() {
  local state_device obligation
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_device=$(fm_pr_file_device "$STATE") || return 1
  if [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ]; then
    [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || return 1
    for obligation in "$QUARANTINE"/*.diagnostic.pending-* "$QUARANTINE"/*.diagnostic.failure-*; do
      [ -e "$obligation" ] || [ -L "$obligation" ] || continue
      return 1
    done
  fi
  [ -f "$MARKER" ] && [ ! -L "$MARKER" ] || return 1
  [ "$(fm_pr_file_mode "$MARKER")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$MARKER")" = "$state_device" ] || return 1
  migration_marker_content_valid "$MARKER"
}

# A valid completion marker proves this home already crossed the one-time
# boundary. When it is absent or invalid, watcher exclusion comes before every
# check scan and before any marker or diagnostic publication.
migration_complete && exit 0
[ "$ALLOW_INCOMPLETE_REPAIRS" -eq 1 ] && scan_complete && exit 0

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
MIGRATION_SCAN_MARKER_TMP=
MIGRATION_LOG_TMP=
MIGRATION_OBLIGATION_TMP=
MIGRATION_QUARANTINE_TMP=
migration_cleanup() {
  fm_pr_poll_cleanup
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
# A marker contradicted by a pending or failed obligation is not authoritative.
# Remove only an ordinary marker under exclusion; unsafe marker paths remain a
# hard refusal for the publication checks below.
if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
  rm -f -- "$MARKER" || exit 1
  [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ] || exit 1
fi
if [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ]; then
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
    rm -f -- "$MARKER" || return 1
  fi
  [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ]
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
    rm -f -- "$SCAN_MARKER" || return 1
  fi
  [ ! -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ]
}

publish_scan_marker() {
  fm_pr_regular_destination_on_device_or_absent "$SCAN_MARKER" "$STATE_DEVICE" || return 1
  MIGRATION_SCAN_MARKER_TMP=$(mktemp "$STATE/.fm-pr-check-scan.XXXXXX") || return 1
  [ -f "$MIGRATION_SCAN_MARKER_TMP" ] && [ ! -L "$MIGRATION_SCAN_MARKER_TMP" ] || return 1
  [ "$(fm_pr_file_device "$MIGRATION_SCAN_MARKER_TMP")" = "$STATE_DEVICE" ] || return 1
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
      x_request=*|x_request_ts=*|x_followups=*|x_platform=*|x_reply_max_chars=*)
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

diagnostic_file_is_one_line() {
  local file=$1 expected=$2 value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 6< "$file" || return 1
  IFS= read -r value <&6 || { exec 6<&-; return 1; }
  if IFS= read -r _extra <&6; then
    exec 6<&-
    return 1
  fi
  exec 6<&-
  [ "$value" = "$expected" ]
}

diagnostic_file_contains() {
  local file=$1 expected=$2 line
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "$expected" ] || return 0
  done < "$file"
  return 1
}

diagnostic_log_valid() {
  [ -f "$LOG" ] && [ ! -L "$LOG" ] || return 1
  [ "$(fm_pr_file_mode "$LOG")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$LOG")" = "$STATE_DEVICE" ]
}

diagnostic_log_contains() {
  local expected=$1
  diagnostic_log_valid || return 1
  diagnostic_file_contains "$LOG" "$expected"
}

revoke_migration_log() {
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
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

diagnostic_obligation_message() {
  local basename=$1 prefix kind
  MIGRATION_DIAGNOSTIC_KIND=
  MIGRATION_DIAGNOSTIC_PREFIX=
  MIGRATION_DIAGNOSTIC_MESSAGE=
  prefix=${basename%%.diagnostic.*}
  kind=${basename##*.diagnostic.}
  if [ "$prefix" = "$NONCANONICAL_PREFIX" ]; then
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

ensure_diagnostic_obligation() {
  local prefix=$1 kind=$2 message=$3 destination
  case "$kind" in
    pending-canonical|pending-ambiguous|pending-noncanonical|canonical|failure-canonical|failure-ambiguous|ambiguous|validated|noncanonical) ;;
    *) return 1 ;;
  esac
  [ "$prefix" = "$NONCANONICAL_PREFIX" ] || fm_pr_task_id_valid "$prefix" || return 1
  ensure_quarantine_dir || return 1
  destination="$QUARANTINE/$prefix.diagnostic.$kind"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
    [ "$(fm_pr_file_mode "$destination")" = 600 ] || return 1
    [ "$(fm_pr_file_device "$destination")" = "$STATE_DEVICE" ] || return 1
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
  if ! [ -f "$destination" ] || [ -L "$destination" ] \
    || [ "$(fm_pr_file_mode "$destination")" != 600 ] \
    || [ "$(fm_pr_file_device "$destination")" != "$STATE_DEVICE" ] \
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
    [ -f "$artifact" ] && [ ! -L "$artifact" ] || return 1
    return 0
  done
  return 1
}

diagnostic_obligation_valid() {
  local prefix=$1 kind=$2 path basename
  path="$QUARANTINE/$prefix.diagnostic.$kind"
  [ -e "$path" ] || [ -L "$path" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_pr_file_mode "$path")" = 600 ] || return 1
  [ "$(fm_pr_file_device "$path")" = "$STATE_DEVICE" ] || return 1
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
  local id=$1 check data
  check="$STATE/$id.check.sh"
  data="$STATE/$id.pr-poll"
  [ ! -e "$check" ] && [ ! -L "$check" ] \
    && [ ! -e "$data" ] && [ ! -L "$data" ] \
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
  remove_diagnostic_obligation "$id" ambiguous || return 1
  ensure_outcome_obligation "$id" validated || return 1
  remove_diagnostic_obligation "$id" pending-ambiguous
}

complete_noncanonical_outcome() {
  quarantined_artifact_exists "$NONCANONICAL_PREFIX" check || return 1
  ensure_outcome_obligation "$NONCANONICAL_PREFIX" noncanonical || return 1
  remove_diagnostic_obligation "$NONCANONICAL_PREFIX" pending-noncanonical
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
  local id=$1 meta data url owner repo number check
  meta="$STATE/$id.meta"
  data="$STATE/$id.pr-poll"
  check="$STATE/$id.check.sh"
  [ ! -e "$check" ] && [ ! -L "$check" ] || return 1
  quarantined_artifact_exists "$id" check || return 1
  metadata_pr_is_canonical "$meta" || return 1
  url=$MIGRATION_URL
  owner=$MIGRATION_OWNER
  repo=$MIGRATION_REPO
  number=$MIGRATION_NUMBER
  quarantine_artifact "$data" "$id" data || return 1
  [ ! -e "$data" ] && [ ! -L "$data" ] || return 1
  fm_pr_poll_prepare "$STATE" "$id" "$url" "$owner" "$repo" "$number" "$TEMPLATE" || return 1
  fm_pr_poll_publish_prepared || return 1
  canonical_terminal_success "$id"
}

ambiguous_repair_from_pending() {
  local id=$1 check data
  check="$STATE/$id.check.sh"
  data="$STATE/$id.pr-poll"
  [ ! -e "$check" ] && [ ! -L "$check" ] || return 1
  quarantined_artifact_exists "$id" check || return 1
  quarantine_artifact "$data" "$id" data || return 1
  ambiguous_terminal_success "$id"
}

recover_pending_outcomes() {
  local obligation basename prefix kind success failure check
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  quarantine_tree_repair_and_validate || return 1
  for obligation in "$QUARANTINE"/*.diagnostic.pending-*; do
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
        if canonical_terminal_success "$prefix"; then
          complete_validated_outcome "$prefix" || return 1
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
        if quarantined_artifact_exists "$NONCANONICAL_PREFIX" check; then
          complete_noncanonical_outcome || return 1
        fi
        ;;
    esac
  done
}

failure_obligations_absent() {
  local failure
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  for failure in "$QUARANTINE"/*.diagnostic.failure-*; do
    [ -e "$failure" ] || [ -L "$failure" ] || continue
    return 1
  done
}

pending_outcomes_complete() {
  local pending
  [ -e "$QUARANTINE" ] || [ -L "$QUARANTINE" ] || return 0
  for pending in "$QUARANTINE"/*.diagnostic.pending-*; do
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
  for obligation in "$QUARANTINE"/*.diagnostic.*; do
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
  for obligation in "$QUARANTINE"/*.diagnostic.*; do
    [ -e "$obligation" ] || [ -L "$obligation" ] || continue
    basename=${obligation##*/}
    diagnostic_obligation_message "$basename" || return 1
    diagnostic_log_contains "$MIGRATION_DIAGNOSTIC_MESSAGE" || return 1
  done
}

diagnostics_failed=0
migration_failed=0
if ! quarantine_tree_repair_and_validate \
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
      if metadata_pr_is_canonical "$meta"; then
        url=$MIGRATION_URL
        owner=$MIGRATION_OWNER
        repo=$MIGRATION_REPO
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
          && fm_pr_poll_prepare "$STATE" "$id" "$url" "$owner" "$repo" "$number" "$TEMPLATE" \
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
        && complete_noncanonical_outcome; then
        :
      else
        migration_failed=1
      fi
    fi
  done
fi

if ! quarantine_tree_repair_and_validate \
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
