#!/usr/bin/env bash
# Side-effect-free exact-build adapter marker primitives.

fm_adapter_file_version() {
  local file=$1
  [ -f "$file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print "sha256:" $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print "sha256:" $1}'
  else
    cksum "$file" | awk '{print "cksum:" $1 ":" $2}'
  fi
}

fm_adapter_loaded_marker_matches() {
  local marker=$1 expected_version=$2 lock=$3 marker_version marker_pid lock_pid
  [ -f "$marker" ] && [ -f "$lock" ] && [ -n "$expected_version" ] || return 1
  marker_version=$(sed -n '1p' "$marker")
  marker_pid=$(sed -n '2p' "$marker")
  lock_pid=$(sed -n '1p' "$lock")
  [ -n "$marker_pid" ] || return 1
  [ "$marker_version" = "$expected_version" ] && [ "$marker_pid" = "$lock_pid" ]
}
