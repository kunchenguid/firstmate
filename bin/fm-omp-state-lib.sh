#!/usr/bin/env bash

fm_omp_session_evidence_owner_path() {
  local state=$1 id=$2
  printf '%s/%s.omp-session-evidence.owner\n' "$state" "$id"
}

fm_omp_session_evidence_owner_matches() {
  local state=$1 id=$2 owner expected actual
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  expected=$(printf 'firstmate-omp-session-evidence-v1\n%s\n%s' "$id" "$state")
  actual=$(<"$owner") || return 1
  [ "$actual" = "$expected" ]
}

fm_omp_session_evidence_decimal() {
  [ -n "$1" ] || return 1
  case "$1" in
    *[!0-9]*) return 1 ;;
  esac
}

fm_omp_session_evidence_current_generation() {
  local state=$1 id=$2 path generation
  path="$state/$id.busy-gen"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(wc -l < "$path" 2>/dev/null)" -eq 1 ] || return 1
  IFS= read -r generation < "$path" || return 1
  case "$generation" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
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
  local path=$1 current_generation=$2 name temp_sequence uuid incarnation_pid token
  name=${path##*/}
  if [[ "$name" =~ ^(.+)\.([0-9]+)\.([0-9]+)\.tmp$ ]]; then
    token=${BASH_REMATCH[1]}
    incarnation_pid=${BASH_REMATCH[2]}
    temp_sequence=${BASH_REMATCH[3]}
  elif [[ "$name" =~ ^(.+)\.([A-Za-z0-9._-]+)\.([0-9]+)\.([0-9a-f-]{36})\.([0-9]+)\.tmp$ ]]; then
    token=${BASH_REMATCH[1]}
    [ "${BASH_REMATCH[2]}" = "$current_generation" ] || return 1
    incarnation_pid=${BASH_REMATCH[3]}
    uuid=${BASH_REMATCH[4]}
    temp_sequence=${BASH_REMATCH[5]}
    case "$uuid" in
      *[!0-9a-f-]*) return 1 ;;
    esac
  else
    return 1
  fi
  [ -n "$token" ] || return 1
  fm_omp_session_evidence_decimal "$incarnation_pid" || return 1
  fm_omp_session_evidence_decimal "$temp_sequence" || return 1
  [ "$incarnation_pid" -gt 0 ] 2>/dev/null || return 1
  [ "$temp_sequence" -gt 0 ] 2>/dev/null || return 1
  fm_omp_session_evidence_token_valid "$token" "$current_generation" || return 1
  fm_omp_session_evidence_content_valid "$path" "$token"
}

fm_omp_session_evidence_validate() {
  local state=$1 id=$2 evidence_dir owner foreign_entry entry current_generation
  evidence_dir="$state/$id.omp-session-evidence"
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  [ ! -L "$evidence_dir" ] && [ ! -L "$owner" ] || return 1
  if [ -e "$evidence_dir" ]; then
    [ -d "$evidence_dir" ] || return 1
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
    current_generation=$(fm_omp_session_evidence_current_generation "$state" "$id") || return 1
    foreign_entry=$(find -P "$evidence_dir" -mindepth 1 ! -type f -print -quit) || return 1
    [ -z "$foreign_entry" ] || return 1
    for entry in "$evidence_dir"/* "$evidence_dir"/.[!.]* "$evidence_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      case "$entry" in
        *.tmp) fm_omp_session_evidence_temp_valid "$entry" "$current_generation" || return 1 ;;
        *) fm_omp_session_evidence_record_valid "$entry" "$current_generation" || return 1 ;;
      esac
    done
  fi
  if [ -e "$owner" ]; then
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
  fi
}

fm_omp_session_evidence_clear() {
  local state=$1 id=$2 evidence_dir owner
  fm_omp_session_evidence_validate "$state" "$id" || return 1
  evidence_dir="$state/$id.omp-session-evidence"
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  if [ -e "$evidence_dir" ]; then
    rm -rf -- "$evidence_dir" || return 1
  fi
  if [ -e "$owner" ]; then
    rm -f -- "$owner" || return 1
  fi
}

fm_omp_session_evidence_claim() {
  local state=$1 id=$2 owner expected
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    fm_omp_session_evidence_owner_matches "$state" "$id"
    return $?
  fi
  expected=$(printf 'firstmate-omp-session-evidence-v1\n%s\n%s' "$id" "$state")
  ( umask 077; set -C; printf '%s\n' "$expected" > "$owner" ) || return 1
  fm_omp_session_evidence_owner_matches "$state" "$id"
}
