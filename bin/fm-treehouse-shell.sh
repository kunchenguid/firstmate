#!/usr/bin/env bash
# Record treehouse get's result, then start the shell it enters on success.
# Usage: FM_TREEHOUSE_{READY,FAILURE}_FILE=<path> FM_TREEHOUSE_REAL_SHELL=<shell> fm-treehouse-shell.sh --get
set -eu

ready=${FM_TREEHOUSE_READY_FILE:?}
failure=${FM_TREEHOUSE_FAILURE_FILE:?}
real_shell=${FM_TREEHOUSE_REAL_SHELL:?}

if [ "${1:-}" = --get ]; then
  failure_tmp="$failure.${BASHPID:-$$}"
  failure_pipe="$failure_tmp.pipe"
  tee_pid=
  cleanup_get() {
    [ -z "$tee_pid" ] || kill "$tee_pid" 2>/dev/null || true
    rm -f -- "$failure_tmp" "$failure_pipe"
  }
  trap cleanup_get EXIT
  rm -f -- "$failure_tmp" "$failure_pipe"
  mkfifo "$failure_pipe"
  tee "$failure_tmp" < "$failure_pipe" >&2 &
  tee_pid=$!
  export FM_TREEHOUSE_IN_SHELL=1
  export SHELL=$0
  set +e
  treehouse get 2> "$failure_pipe"
  status=$?
  wait "$tee_pid" 2>/dev/null
  tee_pid=
  rm -f -- "$failure_pipe"
  set -e
  if [ "$status" -ne 0 ]; then
    mv -f -- "$failure_tmp" "$failure"
    trap - EXIT
    exit "$status"
  fi
  rm -f -- "$failure_tmp"
  trap - EXIT
  exit 0
fi

[ "${FM_TREEHOUSE_IN_SHELL:-}" = 1 ] || exit 2
tmp="$ready.${BASHPID:-$$}"
trap 'rm -f -- "$tmp"' EXIT
pwd -P > "$tmp"
mv -f -- "$tmp" "$ready"
trap - EXIT
export SHELL=$real_shell
unset FM_TREEHOUSE_READY_FILE FM_TREEHOUSE_FAILURE_FILE FM_TREEHOUSE_REAL_SHELL FM_TREEHOUSE_IN_SHELL
exec "$real_shell" "$@"
