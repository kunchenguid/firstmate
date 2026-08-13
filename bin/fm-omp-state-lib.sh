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

fm_omp_session_evidence_validate() {
  local state=$1 id=$2 evidence_dir owner foreign_entry
  evidence_dir="$state/$id.omp-session-evidence"
  owner=$(fm_omp_session_evidence_owner_path "$state" "$id")
  [ ! -L "$evidence_dir" ] && [ ! -L "$owner" ] || return 1
  if [ -e "$evidence_dir" ]; then
    [ -d "$evidence_dir" ] || return 1
    fm_omp_session_evidence_owner_matches "$state" "$id" || return 1
    foreign_entry=$(find -P "$evidence_dir" -mindepth 1 ! -type f -print -quit) || return 1
    [ -z "$foreign_entry" ] || return 1
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
