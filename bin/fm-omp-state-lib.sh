#!/usr/bin/env bash

fm_omp_session_evidence_owner_path() {
  local state=$1 id=$2
  printf '%s/%s.omp-session-evidence.owner\n' "$state" "$id"
}

fm_omp_session_evidence_active_path() {
  local state=$1 id=$2
  printf '%s/%s.omp-session-evidence.active\n' "$state" "$id"
}

fm_omp_session_evidence_lock_path() {
  local state=$1 id=$2
  printf '%s/%s.busy-state.lock\n' "$state" "$id"
}

FM_OMP_SESSION_EVIDENCE_LOCK_TOKEN=
FM_OMP_SESSION_EVIDENCE_LOCK_OWNER_PID=

fm_omp_session_evidence_lock_owner_path() {
  local state=$1 id=$2
  printf '%s/owner\n' "$(fm_omp_session_evidence_lock_path "$state" "$id")"
}

fm_omp_session_evidence_lock_owner_write() {
  local state=$1 id=$2 owner
  owner=$(fm_omp_session_evidence_lock_owner_path "$state" "$id")
  FM_OMP_SESSION_EVIDENCE_LOCK_OWNER_PID=${BASHPID:-$$}
  FM_OMP_SESSION_EVIDENCE_LOCK_TOKEN="$FM_OMP_SESSION_EVIDENCE_LOCK_OWNER_PID.$RANDOM.$(date +%s)"
  ( umask 077; set -C; printf '%s %s\n' "$FM_OMP_SESSION_EVIDENCE_LOCK_OWNER_PID" "$FM_OMP_SESSION_EVIDENCE_LOCK_TOKEN" > "$owner" )
}

fm_omp_session_evidence_lock_owner_status() {
  local state=$1 id=$2 owner content owner_pid owner_token extra
  owner=$(fm_omp_session_evidence_lock_owner_path "$state" "$id")
  [ -f "$owner" ] && [ ! -L "$owner" ] || { printf 'missing\n'; return 0; }
  content=$(<"$owner") || { printf 'invalid\n'; return 0; }
  read -r owner_pid owner_token extra <<< "$content"
  if [ -z "$owner_pid" ] || [ -z "$owner_token" ] || [ -n "$extra" ]; then
    printf 'invalid\n'
    return 0
  fi
  case "$owner_pid" in *[!0-9]*) printf 'invalid\n'; return 0 ;; esac
  if [ "$owner_pid" -le 0 ] 2>/dev/null; then
    printf 'invalid\n'
    return 0
  fi
  if kill -0 "$owner_pid" 2>/dev/null; then printf 'live\n'; else printf 'dead\n'; fi
}

fm_omp_session_evidence_lock_acquire() {
  local state=$1 id=$2 lock tries=0 now mtime age owner owner_status
  lock=$(fm_omp_session_evidence_lock_path "$state" "$id")
  while true; do
    if mkdir "$lock" 2>/dev/null; then
      if fm_omp_session_evidence_lock_owner_write "$state" "$id"; then
        return 0
      fi
      rmdir "$lock" 2>/dev/null || true
      return 1
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 40 ]; then
      [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
      now=$(date +%s)
      mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || return 1)
      age=$((now - mtime))
      if [ "$age" -ge "${FM_BUSY_LOCK_STALE_SECS:-5}" ] \
        && [ "$(fm_omp_session_evidence_lock_owner_status "$state" "$id")" = dead ]; then
        owner=$(fm_omp_session_evidence_lock_owner_path "$state" "$id")
        [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
        rm -f -- "$owner" || return 1
        rmdir "$lock" 2>/dev/null || return 1
        tries=0
        continue
      fi
      return 1
    fi
    sleep 0.05
  done
}

fm_omp_session_evidence_lock_release() {
  local state=$1 id=$2 lock owner content owner_pid owner_token extra
  lock=$(fm_omp_session_evidence_lock_path "$state" "$id")
  owner=$(fm_omp_session_evidence_lock_owner_path "$state" "$id")
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 0
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 0
  content=$(<"$owner") || return 0
  read -r owner_pid owner_token extra <<< "$content"
  [ "$owner_pid" = "$FM_OMP_SESSION_EVIDENCE_LOCK_OWNER_PID" ] && [ "$owner_token" = "$FM_OMP_SESSION_EVIDENCE_LOCK_TOKEN" ] \
    && [ -z "$extra" ] || return 0
  rm -f -- "$owner" || return 1
  rmdir "$lock" 2>/dev/null || true
}

fm_omp_session_evidence_owner_matches() {
  fm_omp_session_evidence_owner_content_valid "$1" "$2"
}

fm_omp_session_evidence_decimal() {
  [ -n "$1" ] || return 1
  case "$1" in
    *[!0-9]*) return 1 ;;
  esac
}

fm_omp_session_evidence_uuid() {
  local uuid=$1
  [ "${#uuid}" -eq 36 ] || return 1
  case "$uuid" in
    *[!0-9a-f-]*) return 1 ;;
  esac
}

fm_omp_session_evidence_generation_valid() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_omp_session_evidence_owner_content_valid() {
  local state=$1 id=$2 owner expected actual rest line marker generation process_id uuid extra newline
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  expected=$(printf 'firstmate-omp-session-evidence-v1\n%s\n%s' "$id" "$state")
  actual=$(<"$owner") || return 1
  [ "$actual" = "$expected" ] && return 0
  newline=$'\n'
  case "$actual" in
    "$expected"$'\n'*) ;;
    *) return 1 ;;
  esac
  rest=${actual#"$expected"}
  rest=${rest#"$newline"}
  [ -n "$rest" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || return 1
    read -r marker generation process_id uuid extra <<< "$line"
    [ "$marker" = firstmate-omp-incarnation-v1 ] || return 1
    [ -n "$generation" ] && [ -n "$process_id" ] && [ -n "$uuid" ] || return 1
    [ -z "$extra" ] || return 1
    fm_omp_session_evidence_generation_valid "$generation" || return 1
    fm_omp_session_evidence_decimal "$process_id" || return 1
    [ "$process_id" -gt 0 ] 2>/dev/null || return 1
    fm_omp_session_evidence_uuid "$uuid" || return 1
  done <<< "$rest"
}

fm_omp_session_evidence_owner_incarnation_registered() {
  local state=$1 id=$2 expected_generation=$3 expected_pid=$4 expected_uuid=$5
  local owner expected actual rest line marker generation process_id uuid extra newline
  fm_omp_session_evidence_owner_content_valid "$state" "$id" || return 1
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  expected=$(printf 'firstmate-omp-session-evidence-v1\n%s\n%s' "$id" "$state")
  actual=$(<"$owner") || return 1
  [ "$actual" = "$expected" ] && return 1
  newline=$'\n'
  rest=${actual#"$expected"}
  rest=${rest#"$newline"}
  while IFS= read -r line; do
    read -r marker generation process_id uuid extra <<< "$line"
    if [ "$marker" = firstmate-omp-incarnation-v1 ] \
      && [ "$generation" = "$expected_generation" ] \
      && [ "$process_id" = "$expected_pid" ] \
      && [ "$uuid" = "$expected_uuid" ] \
      && [ -z "$extra" ]; then
      return 0
    fi
  done <<< "$rest"
  return 1
}

fm_omp_session_evidence_active_incarnation_matches() {
  local state=$1 id=$2 expected_generation=$3 expected_pid=$4 expected_uuid=$5
  local active content marker generation process_id uuid extra
  active=$(fm_omp_session_evidence_active_path "$state" "$id")
  [ -f "$active" ] && [ ! -L "$active" ] || return 1
  [ "$(wc -l < "$active" 2>/dev/null)" -eq 1 ] || return 1
  content=$(<"$active") || return 1
  read -r marker generation process_id uuid extra <<< "$content"
  [ "$marker" = firstmate-omp-incarnation-v1 ] || return 1
  [ "$generation" = "$expected_generation" ] || return 1
  [ "$process_id" = "$expected_pid" ] || return 1
  [ "$uuid" = "$expected_uuid" ] || return 1
  [ -z "$extra" ] || return 1
  fm_omp_session_evidence_generation_valid "$generation" || return 1
  fm_omp_session_evidence_decimal "$process_id" || return 1
  [ "$process_id" -gt 0 ] 2>/dev/null || return 1
  fm_omp_session_evidence_uuid "$uuid"
}

fm_omp_session_evidence_current_generation() {
  local state=$1 id=$2 path generation
  path="$state/$id.busy-gen"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(wc -l < "$path" 2>/dev/null)" -eq 1 ] || return 1
  IFS= read -r generation < "$path" || return 1
  fm_omp_session_evidence_generation_valid "$generation" || return 1
  printf '%s\n' "$generation"
}

fm_omp_session_evidence_token_valid() {
  local token=$1 current_generation=$2 remainder generation process_id started sequence
  sequence=${token##*.}
  remainder=${token%.*}
  started=${remainder##*.}
  remainder=${remainder%.*}
  process_id=${remainder##*.}
  generation=${remainder%.*}
  [ "$generation" = "$current_generation" ] || return 1
  [ -n "$generation" ] || return 1
  fm_omp_session_evidence_decimal "$process_id" || return 1
  fm_omp_session_evidence_decimal "$started" || return 1
  fm_omp_session_evidence_decimal "$sequence" || return 1
  [ "$process_id" -gt 0 ] 2>/dev/null || return 1
  [ "$started" -gt 0 ] 2>/dev/null || return 1
  [ "$sequence" -gt 0 ] 2>/dev/null || return 1
}

fm_omp_session_evidence_content_valid() {
  local path=$1 expected_token=$2 content token started last stopped extra expected_started
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(wc -l < "$path" 2>/dev/null)" -eq 1 ] || return 1
  content=$(<"$path") || return 1
  read -r token started last stopped extra <<< "$content"
  [ -n "$token" ] && [ -n "$started" ] && [ -n "$last" ] && [ -n "$stopped" ] || return 1
  [ -z "$extra" ] || return 1
  [ "$token" = "$expected_token" ] || return 1
  expected_started=${expected_token%.*}
  expected_started=${expected_started##*.}
  [ "$started" = "$expected_started" ] || return 1
  fm_omp_session_evidence_decimal "$started" || return 1
  fm_omp_session_evidence_decimal "$last" || return 1
  fm_omp_session_evidence_decimal "$stopped" || return 1
  [ "$started" -gt 0 ] 2>/dev/null || return 1
  [ "$last" -ge "$started" ] 2>/dev/null || return 1
  [ "$stopped" -eq 0 ] || [ "$stopped" -ge "$last" ] 2>/dev/null || return 1
}

fm_omp_session_evidence_record_valid() {
  local path=$1 current_generation=$2 name
  name=${path##*/}
  fm_omp_session_evidence_token_valid "$name" "$current_generation" || return 1
  fm_omp_session_evidence_content_valid "$path" "$name"
}

fm_omp_session_evidence_temp_valid() {
  local path=$1 state=$2 id=$3 current_generation=$4
  local name temp_sequence uuid incarnation_pid token generation
  name=${path##*/}
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if [[ "$name" =~ ^(.+)\.incarnation-([0-9a-f-]{36})\.generation-([A-Za-z0-9._-]+)\.pid-([0-9]+)\.seq-([0-9]+)\.tmp$ ]]; then
    token=${BASH_REMATCH[1]}
    uuid=${BASH_REMATCH[2]}
    generation=${BASH_REMATCH[3]}
    incarnation_pid=${BASH_REMATCH[4]}
    temp_sequence=${BASH_REMATCH[5]}
    [ "$generation" = "$current_generation" ] || return 1
    case "$uuid" in
      *[!0-9a-f-]*) return 1 ;;
    esac
  else
    return 1
  fi
  [ -n "$token" ] || return 1
  fm_omp_session_evidence_uuid "$uuid" || return 1
  fm_omp_session_evidence_decimal "$incarnation_pid" || return 1
  fm_omp_session_evidence_decimal "$temp_sequence" || return 1
  [ "$incarnation_pid" -gt 0 ] 2>/dev/null || return 1
  [ "$temp_sequence" -gt 0 ] 2>/dev/null || return 1
  fm_omp_session_evidence_token_valid "$token" "$current_generation" || return 1
  fm_omp_session_evidence_owner_incarnation_registered \
    "$state" "$id" "$current_generation" "$incarnation_pid" "$uuid" \
    && fm_omp_session_evidence_active_incarnation_matches \
      "$state" "$id" "$current_generation" "$incarnation_pid" "$uuid"
}

fm_omp_session_evidence_validate() {
  local state=$1 id=$2 evidence_dir owner active foreign_entry entry current_generation
  local content marker generation process_id uuid extra
  evidence_dir="$state/$id.omp-session-evidence"
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  active=$(fm_omp_session_evidence_active_path "$state" "$id")
  [ ! -L "$evidence_dir" ] && [ ! -L "$owner" ] && [ ! -L "$active" ] || return 1
  if [ -e "$evidence_dir" ]; then
    [ -d "$evidence_dir" ] || return 1
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
    current_generation=$(fm_omp_session_evidence_current_generation "$state" "$id") || return 1
    foreign_entry=$(find -P "$evidence_dir" -mindepth 1 ! -type f -print -quit) || return 1
    [ -z "$foreign_entry" ] || return 1
    for entry in "$evidence_dir"/* "$evidence_dir"/.[!.]* "$evidence_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      case "$entry" in
        *.tmp) fm_omp_session_evidence_temp_valid "$entry" "$state" "$id" "$current_generation" || return 1 ;;
        *) fm_omp_session_evidence_record_valid "$entry" "$current_generation" || return 1 ;;
      esac
    done
  fi
  if [ -e "$owner" ]; then
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
  fi
  if [ -e "$active" ]; then
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
    [ -f "$active" ] && [ ! -L "$active" ] || return 1
    [ "$(wc -l < "$active" 2>/dev/null)" -eq 1 ] || return 1
    current_generation=$(fm_omp_session_evidence_current_generation "$state" "$id") || return 1
    content=$(<"$active") || return 1
    read -r marker generation process_id uuid extra <<< "$content"
    [ "$marker" = firstmate-omp-incarnation-v1 ] || return 1
    [ -z "$extra" ] || return 1
    fm_omp_session_evidence_generation_valid "$generation" || return 1
    fm_omp_session_evidence_decimal "$process_id" || return 1
    [ "$process_id" -gt 0 ] 2>/dev/null || return 1
    fm_omp_session_evidence_uuid "$uuid" || return 1
    [ "$generation" = "$current_generation" ] || return 1
    fm_omp_session_evidence_owner_incarnation_registered \
      "$state" "$id" "$generation" "$process_id" "$uuid" || return 1
  fi
}

fm_omp_session_evidence_path_identity() {
  local path=$1
  [ -e "$path" ] && [ ! -L "$path" ] || return 1
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%d:%i' "$path" 2>/dev/null
  else
    stat -c '%d:%i' "$path" 2>/dev/null
  fi
}

fm_omp_session_evidence_clear_pause() {
  local gate=${FM_OMP_TEST_EVIDENCE_CLEAR_GATE:-}
  [ -n "$gate" ] || return 0
  : > "$gate.ready" || return 1
  while [ ! -e "$gate.release" ]; do
    sleep 0.01
  done
}

fm_omp_session_evidence_clear_entry_pause() {
  local gate=${FM_OMP_TEST_EVIDENCE_CLEAR_ENTRY_GATE:-}
  [ -n "$gate" ] || return 0
  : > "$gate.ready" || return 1
  while [ ! -e "$gate.release" ]; do
    sleep 0.01
  done
}

fm_omp_session_evidence_clear_locked() {
  local state=$1 id=$2 evidence_dir owner active entry entry_name foreign_entry current_generation
  local evidence_identity entry_identity current_identity owner_identity active_identity
  fm_omp_session_evidence_validate "$state" "$id" || return 1
  fm_omp_session_evidence_clear_pause || return 1
  fm_omp_session_evidence_validate "$state" "$id" || return 1
  evidence_dir="$state/$id.omp-session-evidence"
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  active=$(fm_omp_session_evidence_active_path "$state" "$id")
  if [ -e "$evidence_dir" ] || [ -L "$evidence_dir" ]; then
    [ -d "$evidence_dir" ] && [ ! -L "$evidence_dir" ] || return 1
    evidence_identity=$(fm_omp_session_evidence_path_identity "$evidence_dir") || return 1
    (
      CDPATH= cd -- "$evidence_dir" || exit 1
      current_identity=$(fm_omp_session_evidence_path_identity .) || exit 1
      [ "$current_identity" = "$evidence_identity" ] || exit 1
      current_generation=$(fm_omp_session_evidence_current_generation "$state" "$id") || exit 1
      for entry_name in * .[!.]* ..?*; do
        entry_name=${entry_name#./}
        [ -e "./$entry_name" ] || [ -L "./$entry_name" ] || continue
        current_identity=$(fm_omp_session_evidence_path_identity .) || exit 1
        [ "$current_identity" = "$evidence_identity" ] || exit 1
        [ -f "./$entry_name" ] && [ ! -L "./$entry_name" ] || exit 1
        entry_identity=$(fm_omp_session_evidence_path_identity "./$entry_name") || exit 1
        current_generation=$(fm_omp_session_evidence_current_generation "$state" "$id") || exit 1
        case "$entry_name" in
          *.tmp) fm_omp_session_evidence_temp_valid "./$entry_name" "$state" "$id" "$current_generation" || exit 1 ;;
          *) fm_omp_session_evidence_record_valid "./$entry_name" "$current_generation" || exit 1 ;;
        esac
        fm_omp_session_evidence_clear_entry_pause || exit 1
        current_identity=$(fm_omp_session_evidence_path_identity .) || exit 1
        [ "$current_identity" = "$evidence_identity" ] || exit 1
        current_identity=$(fm_omp_session_evidence_path_identity "./$entry_name") || exit 1
        [ "$current_identity" = "$entry_identity" ] || exit 1
        case "$entry_name" in
          *.tmp) fm_omp_session_evidence_temp_valid "./$entry_name" "$state" "$id" "$current_generation" || exit 1 ;;
          *) fm_omp_session_evidence_record_valid "./$entry_name" "$current_generation" || exit 1 ;;
        esac
        rm -f -- "./$entry_name" || exit 1
        [ ! -e "./$entry_name" ] && [ ! -L "./$entry_name" ] || exit 1
      done
      foreign_entry=$(find -P . -mindepth 1 -print -quit) || exit 1
      [ -z "$foreign_entry" ] || exit 1
    ) || return 1
    [ -d "$evidence_dir" ] && [ ! -L "$evidence_dir" ] || return 1
    current_identity=$(fm_omp_session_evidence_path_identity "$evidence_dir") || return 1
    [ "$current_identity" = "$evidence_identity" ] || return 1
    foreign_entry=$(find -P "$evidence_dir" -mindepth 1 -print -quit) || return 1
    [ -z "$foreign_entry" ] || return 1
    (
      CDPATH= cd -- "$state" || exit 1
      current_identity=$(fm_omp_session_evidence_path_identity "./$id.omp-session-evidence") || exit 1
      [ "$current_identity" = "$evidence_identity" ] || exit 1
      rmdir "./$id.omp-session-evidence" || exit 1
    ) || return 1
    [ ! -e "$evidence_dir" ] && [ ! -L "$evidence_dir" ] || return 1
  fi
  [ ! -e "$evidence_dir" ] && [ ! -L "$evidence_dir" ] || return 1
  if [ -e "$active" ] || [ -L "$active" ]; then
    [ -f "$active" ] && [ ! -L "$active" ] || return 1
    active_identity=$(fm_omp_session_evidence_path_identity "$active") || return 1
    fm_omp_session_evidence_validate "$state" "$id" || return 1
    current_identity=$(fm_omp_session_evidence_path_identity "$active") || return 1
    [ "$current_identity" = "$active_identity" ] || return 1
    rm -f -- "$active" || return 1
    [ ! -e "$active" ] && [ ! -L "$active" ] || return 1
  fi
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
    owner_identity=$(fm_omp_session_evidence_path_identity "$owner") || return 1
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
    current_identity=$(fm_omp_session_evidence_path_identity "$owner") || return 1
    [ "$current_identity" = "$owner_identity" ] || return 1
    rm -f -- "$owner" || return 1
    [ ! -e "$owner" ] && [ ! -L "$owner" ] || return 1
  fi
}

fm_omp_session_evidence_clear() {
  local state=$1 id=$2 status release_status
  fm_omp_session_evidence_lock_acquire "$state" "$id" || return 1
  if fm_omp_session_evidence_clear_locked "$state" "$id"; then
    status=0
  else
    status=$?
  fi
  if fm_omp_session_evidence_lock_release "$state" "$id"; then
    release_status=0
  else
    release_status=$?
  fi
  [ "$status" -eq 0 ] || return "$status"
  return "$release_status"
}

fm_omp_session_evidence_claim() {
  local state=$1 id=$2 owner expected status release_status
  fm_omp_session_evidence_lock_acquire "$state" "$id" || return 1
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    if fm_omp_session_evidence_owner_matches "$state" "$id"; then
      status=0
    else
      status=$?
    fi
  else
    expected=$(printf 'firstmate-omp-session-evidence-v1\n%s\n%s' "$id" "$state")
    if ( umask 077; set -C; printf '%s\n' "$expected" > "$owner" ) \
      && fm_omp_session_evidence_owner_matches "$state" "$id"; then
      status=0
    else
      status=$?
    fi
  fi
  if fm_omp_session_evidence_lock_release "$state" "$id"; then
    release_status=0
  else
    release_status=$?
  fi
  [ "$status" -eq 0 ] || return "$status"
  return "$release_status"
}
