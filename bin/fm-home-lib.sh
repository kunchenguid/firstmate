#!/usr/bin/env bash
# fm-home-lib.sh - shared FM_HOME resolution for fleet-facing commands.
#
# Source this, then resolve the effective firstmate home with:
#   FM_HOME=$(fm_resolve_home) || exit 1
#
# Resolution order:
#   1. FM_HOME, when set and non-empty, is honored as-is. It is the caller's
#      explicit choice; downstream validation (each script's own home checks)
#      owns whether that home is usable, exactly as before this helper existed.
#   2. Otherwise the conventional operational home, ${HOME}/data/firstmate.
#
# An unset FM_HOME is normal, not an error: it resolves to the default. The ONLY
# failure this helper reports is a DEFAULTED home whose directory does not exist,
# and it reports that with a clear diagnostic naming the path and how it was
# chosen - never a bare ${VAR:?} abort, which gives the caller no path and no
# remedy. On that failure it prints the diagnostic to stderr and returns 1 so
# the caller can exit cleanly; on success it prints the resolved home to stdout.
#
# It deliberately does not create the home, mutate the environment, or check an
# explicit FM_HOME for existence: honoring an explicitly set FM_HOME unchanged
# keeps every existing caller and test byte-for-byte compatible.

fm_resolve_home() {
  local home source
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s\n' "$FM_HOME"
    return 0
  fi
  home="${HOME:-}/data/firstmate"
  # The literal $HOME token is intentional user-facing text, not an expansion.
  # shellcheck disable=SC2016
  source='default ($HOME/data/firstmate)'
  if [ -z "${HOME:-}" ]; then
    printf 'fm: cannot resolve a default firstmate home: HOME is unset\n' >&2
    printf 'fm: set FM_HOME to an existing firstmate home and retry\n' >&2
    return 1
  fi
  if [ ! -d "$home" ]; then
    printf 'fm: firstmate home does not exist: %s (resolved from %s)\n' "$home" "$source" >&2
    printf 'fm: set FM_HOME to an existing home, or create %s, and retry\n' "$home" >&2
    return 1
  fi
  printf '%s\n' "$home"
  return 0
}
