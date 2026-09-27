#!/usr/bin/env bash
# Identify native omp and Bun directly executing either OMP script entrypoint.
# The packaged CLI is the entrypoint used on resume. A later argument naming
# either script does not establish the process's harness identity.
fm_omp_process_matches() {  # <comm> <args>
  local comm=$1 args=$2
  case "${comm##*/}" in
    omp) return 0 ;;
    bun) ;;
    *) return 1 ;;
  esac
  [[ "$args" =~ ^(bun|/[^[:space:]]*/bun)[[:space:]]+/[^[:space:]]*/(\.bun/bin/omp|node_modules/@oh-my-pi/pi-coding-agent/dist/cli\.js)([[:space:]]|$) ]]
}
