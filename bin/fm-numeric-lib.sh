#!/usr/bin/env bash

fm_nonnegative_integer_or_default() {  # <value> <default> <maximum>
  local value=${1-} default=$2 maximum=$3
  case "$value" in ''|*[!0-9]*) printf '%s' "$default"; return 0 ;; esac
  while [ "${#value}" -gt 1 ] && [ "${value#0}" != "$value" ]; do
    value=${value#0}
  done
  if [ "${#value}" -gt "${#maximum}" ] || { [ "${#value}" -eq "${#maximum}" ] && [[ "$value" > "$maximum" ]]; }; then
    printf '%s' "$default"
  else
    printf '%s' "$((10#$value))"
  fi
}
