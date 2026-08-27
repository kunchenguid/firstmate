#!/usr/bin/env bash
# fm-remember.sh - best-effort push of ONE captain decision or learning into this
# home's fleet memory (memval-04). A side-effect only: it never blocks, never
# changes the caller's exit status, and never emits diagnostic noise.
#
# It exists so firstmate's natural capture points accumulate the home's memory
# automatically instead of only when someone runs the write CLI by hand. Each
# caller owns which durable, provenance-stamped fact it pushes; today these are a
# recorded captain decision (bin/fm-captain-hold.sh), a resolved worker
# decision/blocker (bin/fm-send.sh), a completed scout's finding
# (bin/fm-teardown.sh), a landed ship outcome (bin/fm-merge-local.sh,
# bin/fm-pr-merge.sh), and a /stow knowledge sweep (the stow skill).
#
# The write path is `brain-axi remember` against this home's store
# (fm-brain-lib.sh resolves the path). remember carries mandatory provenance and
# is idempotent per fact, so a repeated decision is a safe no-op. This wrapper
# owns only the fail-open guards around it:
#   - brain-axi not on PATH (memory not wired for this home) -> do nothing, exit 0.
#   - a slow or wedged binary -> bounded by FM_REMEMBER_TIMEOUT (fm-timeout-lib.sh)
#     so it can never delay decision-hold, stow, or any firstmate flow. The
#     default is deliberately short.
# Any write failure is swallowed; this command always exits 0 (memval-04 fail-open).
#
# Usage:
#   fm-remember.sh "<decision or learning text>"
#   printf '%s' "<text>" | fm-remember.sh
# FM_REMEMBER_PROVENANCE overrides the recorded provenance (default "firstmate");
# brain-axi requires a provenance on every fact.
set -u

FM_REMEMBER_TIMEOUT=${FM_REMEMBER_TIMEOUT:-5}
case "$FM_REMEMBER_TIMEOUT" in ''|*[!0-9]*|0) FM_REMEMBER_TIMEOUT=5 ;; esac

main() {
  local text=${1:-} script_dir store provenance
  [ -n "$text" ] || text=$(cat 2>/dev/null || true)
  [ -n "$text" ] || return 0

  command -v brain-axi >/dev/null 2>&1 || return 0

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-brain-lib.sh
  # shellcheck disable=SC1091
  . "$script_dir/fm-brain-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  # shellcheck disable=SC1091
  . "$script_dir/fm-timeout-lib.sh"

  store=$(fm_brain_store)
  provenance=${FM_REMEMBER_PROVENANCE:-firstmate}

  local by
  by=$(fm_brain_by fm-remember)
  fm_run_timed "$FM_REMEMBER_TIMEOUT" \
    brain-axi remember "$text" --provenance "$provenance" --store "$store" --by "$by" \
    >/dev/null 2>&1 || true
  return 0
}

main "$@"
