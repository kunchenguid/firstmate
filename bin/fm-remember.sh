#!/usr/bin/env bash
# fm-remember.sh - best-effort push of ONE captain decision or learning into this
# home's fleet memory (memval-04). A side-effect only: it never blocks, never
# changes the caller's exit status, and never emits diagnostic noise.
#
# It exists so firstmate's natural capture points - a durably recorded captain
# decision (bin/fm-decision-hold.sh) and a /stow knowledge sweep (the stow skill)
# - accumulate the home's memory automatically instead of only when someone runs
# the write CLI by hand.
#
# The write path itself is memval-03's per-home CLI,
# "$FM_HOME/config/memory/memhub-remember.mjs", which is idempotent and
# user_id-scoped, so a repeated decision is a safe no-op. This wrapper only owns
# the fail-open guards around it:
#   - memory not wired for this home (the CLI is absent) -> do nothing, exit 0.
#   - node missing -> do nothing, exit 0.
#   - a slow or down hub -> bounded by FM_REMEMBER_TIMEOUT (fm-timeout-lib.sh) so
#     it can never delay decision-hold, stow, or any firstmate flow. The write CLI
#     is itself internally timeboxed, so this bound is only a hard backstop for a
#     wedged node process; the default is deliberately short.
# Any write failure is swallowed; this command always exits 0.
#
# Usage:
#   fm-remember.sh "<decision or learning text>"
#   printf '%s' "<text>" | fm-remember.sh
set -u

FM_REMEMBER_TIMEOUT=${FM_REMEMBER_TIMEOUT:-5}
case "$FM_REMEMBER_TIMEOUT" in ''|*[!0-9]*|0) FM_REMEMBER_TIMEOUT=5 ;; esac

main() {
  local text=${1:-} home mjs script_dir
  [ -n "$text" ] || text=$(cat 2>/dev/null || true)
  [ -n "$text" ] || return 0

  home=${FM_HOME:-}
  [ -n "$home" ] || home=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  mjs="$home/config/memory/memhub-remember.mjs"
  [ -f "$mjs" ] || return 0
  command -v node >/dev/null 2>&1 || return 0

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-timeout-lib.sh
  # shellcheck disable=SC1091
  . "$script_dir/fm-timeout-lib.sh"

  fm_run_timed "$FM_REMEMBER_TIMEOUT" node "$mjs" "$text" >/dev/null 2>&1 || true
  return 0
}

main "$@"
