#!/usr/bin/env bash
# Shared record-retirement marker contract.
#
# A successful state-only retirement leaves one fixed-path marker at
# state/.record-retired-<task-id> so a still-live, deliberately untouched agent
# cannot recreate supervision by writing its old status or turn-end path.
# The marker is not task metadata and does not authorize endpoint, process,
# branch, project, or working-copy access.
#
# Format (exactly four lines):
#   schema=fm-record-retired.v1
#   task_id=<privacy-safe task id>
#   window=<recorded runtime target>
#   meta_sha256=<lowercase sha256 of the retired metadata bytes>
#
# Consumers suppress only after canonical metadata is absent and an id-keyed
# signal or check wake has a regular, non-symlink marker with this exact shape
# and task binding.
# Slot-keyed stale wakes are never marker-muted because they carry no task id.
# An invalid marker is inert, so corruption fails toward surfacing work.

FM_RECORD_RETIRED_SCHEMA=fm-record-retired.v1

fm_record_retire_id_valid() {
  local id=${1:-}
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_record_retire_marker_path() {  # <state-dir> <task-id>
  printf '%s/.record-retired-%s\n' "$1" "$2"
}

fm_record_retire_sha256_file() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

fm_record_retire_marker_valid() {  # <state-dir> <task-id>
  local state=$1 id=$2 marker schema task window digest lines
  fm_record_retire_id_valid "$id" || return 1
  marker=$(fm_record_retire_marker_path "$state" "$id")
  [ -f "$marker" ] && [ -r "$marker" ] && [ ! -L "$marker" ] || return 1
  lines=$(LC_ALL=C wc -l < "$marker" 2>/dev/null) || return 1
  lines=${lines//[[:space:]]/}
  [ "$lines" = 4 ] || return 1
  schema=$(sed -n '1s/^schema=//p' "$marker")
  task=$(sed -n '2s/^task_id=//p' "$marker")
  window=$(sed -n '3s/^window=//p' "$marker")
  digest=$(sed -n '4s/^meta_sha256=//p' "$marker")
  [ "$schema" = "$FM_RECORD_RETIRED_SCHEMA" ] || return 1
  [ "$task" = "$id" ] || return 1
  [ -n "$window" ] || return 1
  case "$window" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
}

fm_record_retire_marker_window() {  # <state-dir> <task-id>
  local marker
  fm_record_retire_marker_valid "$1" "$2" || return 1
  marker=$(fm_record_retire_marker_path "$1" "$2")
  sed -n '3s/^window=//p' "$marker"
}

fm_record_retire_marker_active() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta
  fm_record_retire_marker_valid "$state" "$id" || return 1
  meta="$state/$id.meta"
  [ ! -e "$meta" ] && [ ! -L "$meta" ]
}

fm_record_retire_watcher_state_key() {  # <window>
  local key=$1
  key=${key//:/_}
  key=${key//\//_}
  key=${key//./_}
  printf '%s' "$key"
}

fm_record_retire_window_collision() {  # <target-window> <other-window>
  local target=$1 other=$2 target_key other_key
  if [ "$other" = "$target" ]; then
    printf 'raw'
    return 0
  fi
  target_key=$(fm_record_retire_watcher_state_key "$target")
  other_key=$(fm_record_retire_watcher_state_key "$other")
  [ "$other_key" = "$target_key" ] || return 1
  printf 'collapsed'
}

fm_record_retire_artifact_paths() {  # <state-dir> <task-id> <window>
  local state=$1 id=$2 window=$3 key prefix
  printf '%s\n' \
    "$state/$id.status" \
    "$state/$id.turn-ended" \
    "$state/$id.pi-ext.ts" \
    "$state/$id.grok-turnend-token" \
    "$state/$id.kimi-turnend-token" \
    "$state/$id.muse-session" \
    "$state/$id.muse-session-current" \
    "$state/$id.cursor-session" \
    "$state/$id.control-relaunch" \
    "$state/$id.control-relaunch.meta-prior" \
    "$state/$id.control-relaunch.brief-prior" \
    "$state/$id.control-relaunch.note" \
    "$state/$id.herdr-presentation" \
    "$state/$id.busy-gen" \
    "$state/$id.busy-state" \
    "$state/$id.check.sh" \
    "$state/$id.check-trust" \
    "$state/$id.pr-poll" \
    "$state/$id.pr-poll-registration" \
    "$state/$id.pr-poll-retirement" \
    "$state/.$id.open-decisions-cursor"
  fm_wake_task_surface_paths "$state" "$id"
  key=$(fm_record_retire_watcher_state_key "$window")
  for prefix in hash count stale stale-since paused paused-rechecked paused-resurfaced wedge-escalations; do
    printf '%s/.%s-%s\n' "$state" "$prefix" "$key"
  done
}

fm_record_retire_marker_publish() {  # <state-dir> <task-id> <window> <meta-sha256>
  local state=$1 id=$2 window=$3 digest=$4 marker tmp old_umask
  fm_record_retire_id_valid "$id" || return 1
  [ -n "$window" ] || return 1
  case "$window" in *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  marker=$(fm_record_retire_marker_path "$state" "$id")
  tmp="$marker.tmp.${BASHPID:-$$}"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_record_retire_marker_valid "$state" "$id" || return 1
    [ "$(fm_record_retire_marker_window "$state" "$id")" = "$window" ] || return 1
    [ "$(sed -n '4s/^meta_sha256=//p' "$marker")" = "$digest" ] || return 1
    return 0
  fi
  old_umask=$(umask)
  umask 077
  {
    printf 'schema=%s\n' "$FM_RECORD_RETIRED_SCHEMA"
    printf 'task_id=%s\n' "$id"
    printf 'window=%s\n' "$window"
    printf 'meta_sha256=%s\n' "$digest"
  } > "$tmp" || { rm -f -- "$tmp"; umask "$old_umask"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; umask "$old_umask"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; umask "$old_umask"; return 1; }
  umask "$old_umask"
  fm_record_retire_marker_valid "$state" "$id"
}

fm_record_retire_marker_validate_for_spawn() {  # <state-dir> <task-id>
  local marker
  marker=$(fm_record_retire_marker_path "$1" "$2")
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  fm_record_retire_marker_valid "$1" "$2" || {
    printf 'error: invalid record-retirement marker for task %s; refusing spawn\n' "$2" >&2
    return 1
  }
}

fm_record_retire_marker_clear_for_spawn() {  # <state-dir> <task-id>
  local marker
  fm_record_retire_marker_validate_for_spawn "$1" "$2" || return 1
  marker=$(fm_record_retire_marker_path "$1" "$2")
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  rm -f -- "$marker"
}

fm_record_retire_wake_muted() {  # <state-dir> <kind> <key>
  local state=$1 kind=$2 key=$3 id
  case "$kind" in
    signal)
      case "$key" in
        *.status) id=${key%.status} ;;
        *.turn-ended) id=${key%.turn-ended} ;;
        *) return 1 ;;
      esac
      fm_record_retire_marker_active "$state" "$id"
      ;;
    check)
      case "$key" in
        "$state"/*.check.sh) id=${key##*/}; id=${id%.check.sh} ;;
        *) return 1 ;;
      esac
      fm_record_retire_marker_active "$state" "$id"
      ;;
    # A stale wake is keyed only by a runtime slot and carries no task id.
    # It can never be attributed safely to one retired record, so markers do
    # not mute it.
    stale) return 1 ;;
    *) return 1 ;;
  esac
}
