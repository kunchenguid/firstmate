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

fm_omp_session_evidence_record_valid() {
  local path=$1 name content token started last stopped extra remainder generation process_id token_started sequence
  name=${path##*/}
  sequence=${name##*.}
  remainder=${name%.*}
  token_started=${remainder##*.}
  remainder=${remainder%.*}
  process_id=${remainder##*.}
  generation=${remainder%.*}
  [ -n "$generation" ] || return 1
  fm_omp_session_evidence_decimal "$process_id" || return 1
  fm_omp_session_evidence_decimal "$token_started" || return 1
  fm_omp_session_evidence_decimal "$sequence" || return 1
  [ "$sequence" -gt 0 ] 2>/dev/null || return 1
  [ "$process_id" -gt 0 ] 2>/dev/null || return 1
  [ "$token_started" -gt 0 ] 2>/dev/null || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(wc -l < "$path" 2>/dev/null)" -eq 1 ] || return 1
  content=$(<"$path") || return 1
  read -r token started last stopped extra <<< "$content"
  [ -n "$token" ] && [ -n "$started" ] && [ -n "$last" ] && [ -n "$stopped" ] || return 1
  [ -z "$extra" ] || return 1
  [ "$token" = "$name" ] || return 1
  [ "$started" = "$token_started" ] || return 1
  fm_omp_session_evidence_decimal "$started" || return 1
  fm_omp_session_evidence_decimal "$last" || return 1
  fm_omp_session_evidence_decimal "$stopped" || return 1
  [ "$started" -gt 0 ] 2>/dev/null || return 1
  [ "$last" -ge "$started" ] 2>/dev/null || return 1
  [ "$stopped" -eq 0 ] || [ "$stopped" -ge "$last" ] 2>/dev/null || return 1
}

fm_omp_session_evidence_validate() {
  local state=$1 id=$2 evidence_dir owner foreign_entry entry
  evidence_dir="$state/$id.omp-session-evidence"
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  [ ! -L "$evidence_dir" ] && [ ! -L "$owner" ] || return 1
  if [ -e "$evidence_dir" ]; then
    [ -d "$evidence_dir" ] || return 1
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
    foreign_entry=$(find -P "$evidence_dir" -mindepth 1 ! -type f -print -quit) || return 1
    [ -z "$foreign_entry" ] || return 1
    for entry in "$evidence_dir"/* "$evidence_dir"/.[!.]* "$evidence_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      fm_omp_session_evidence_record_valid "$entry" || return 1
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
