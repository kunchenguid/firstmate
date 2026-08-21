#!/usr/bin/env bash
# Shared structural process identity for the OMP harness.
#
# OMP 17.3.4 runs the generic `bun` runtime, so its process name alone cannot
# identify a Firstmate agent without classifying unrelated Bun programs as
# alive. The runtime's argv carries either the selected `omp` launcher or the
# `@oh-my-pi/pi-coding-agent` package path, which is the stable structural
# evidence consumers pair with their own task or session scope.

fm_omp_process_matches() {  # <comm> <args>
  local comm=${1-} args=${2-} base
  base=$(basename -- "$comm")
  base=${base#-}
  case "$base" in
    bun|bun-*) ;;
    *) return 1 ;;
  esac
  case "$args" in
    # Keep the bare launcher form for argv ending at omp, and accept trailing
    # argv tokens for the real OMP shape: `bun /path/omp --advisor ...`.
    *'/pi-coding-agent/'*|*'/omp '*|*'/omp') return 0 ;;
  esac
  return 1
}
