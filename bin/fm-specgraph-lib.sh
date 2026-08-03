#!/usr/bin/env bash
# fm-specgraph-lib.sh - fail-open adapter for private SpecGraph capture hooks.
#
# The snapshot writer owns validation and durable publication.
# Existing lifecycle entrypoints call this adapter only after their own success
# authority is established.
# A capture failure is recorded privately and never changes the caller's exit
# status or existing safety, supervision, teardown, or decision behavior.

fm_specgraph_capture_best_effort() {
  local state=$1 capture_bin event=unknown subject=unknown arg output rc=0 now
  local -a capture_args
  shift
  capture_args=("$@")
  capture_bin=${FM_SPECGRAPH_CAPTURE_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-specgraph-capture.sh}

  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --event)
        [ "$#" -gt 0 ] || break
        event=$1
        shift
        ;;
      --subject)
        [ "$#" -gt 0 ] || break
        subject=$1
        shift
        ;;
    esac
  done

  if output=$("$capture_bin" capture "${capture_args[@]}" 2>&1); then
    return 0
  else
    rc=$?
  fi

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -d "$state" ] && [ ! -L "$state" ]; then
    umask 077
    printf '%s\tevent=%s\tsubject=%s\texit=%s\n' "$now" "$event" "$subject" "$rc" \
      >> "$state/specgraph-capture.failures.log" 2>/dev/null || true
  fi
  printf 'warning: SpecGraph capture failed for %s/%s and the primary flow is continuing' \
    "$event" "$subject" >&2
  [ -z "$output" ] || printf ': %s' "$(printf '%s' "$output" | tr '\r\n' '  ' | cut -c1-240)" >&2
  printf '\n' >&2
  return 0
}
