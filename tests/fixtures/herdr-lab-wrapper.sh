#!/usr/bin/env bash
# Route a production Herdr adapter call through the isolated lab helper.
set -euo pipefail

helper=${HERDR_LAB_HELPER:?}
session=${HERDR_LAB_SESSION:?}
real_path=${HERDR_LAB_REAL_PATH:?}
args=("$@")
n=${#args[@]}

if [ "$n" -ge 2 ] && [ "${args[$((n - 2))]}" = --session ]; then
  [ "${args[$((n - 1))]}" = "$session" ] || {
    echo "wrapper refused foreign Herdr session" >&2
    exit 97
  }
  args=("${args[@]:0:$((n - 2))}")
else
  [ "${HERDR_SESSION:-}" = "$session" ] || {
    echo "wrapper requires the isolated Herdr lab session" >&2
    exit 98
  }
  for arg in "${args[@]}"; do
    case "$arg" in
      --session|--session=*)
        echo "wrapper refused non-trailing Herdr session flag" >&2
        exit 99
        ;;
    esac
  done
fi

if [ -n "${HERDR_LAB_WRAPPER_LOG:-}" ]; then
  stdout_file=$(mktemp "${HERDR_LAB_WRAPPER_LOG}.stdout.XXXXXX")
  stderr_file=$(mktemp "${HERDR_LAB_WRAPPER_LOG}.stderr.XXXXXX")
  if PATH="$real_path" "$helper" run "$session" "${args[@]}" > "$stdout_file" 2> "$stderr_file"; then
    status=0
  else
    status=$?
  fi
  {
    printf 'status=%s args=' "$status"
    printf ' %q' "${args[@]}"
    printf '\n'
    sed 's/^/stderr: /' "$stderr_file"
  } >> "$HERDR_LAB_WRAPPER_LOG"
  cat "$stdout_file"
  cat "$stderr_file" >&2
  rm -f "$stdout_file" "$stderr_file"
  exit "$status"
fi

PATH="$real_path" exec "$helper" run "$session" "${args[@]}"
