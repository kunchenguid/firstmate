# shellcheck shell=bash
# Shared no-mistakes capability probe for session-start bootstrap and self-update.
# Usage: . bin/fm-nm-lib.sh
#
# firstmate's direct-PR post-delivery monitor arms `no-mistakes watch --pr <url>`
# (bin/fm-nm-watch.sh) - a subcommand that older no-mistakes binaries do not
# expose. Such a binary is present and executable on PATH, so a plain presence
# check (command -v) passes while the capability firstmate depends on is absent;
# the gap then only surfaces later as a direct-PR task reporting `watch not
# armed`, with CI/review/mergeability no longer monitored continuously.
#
# The probe checks the capability DIRECTLY and non-destructively via
# `no-mistakes watch --help`, never by parsing a version string: a version gate
# drifts from the real command surface, while the help output is the command
# surface. A compatible build documents the required `--pr` flag; an old build
# prints `unknown command "watch"`. `watch --help` neither arms a run nor
# contacts a remote, so it is safe to call at session start.
#
# FM_NM_BIN overrides the binary name (default `no-mistakes`), matching
# bin/fm-nm-watch.sh so both resolve the same tool under test.

fm_nm_bin() {
  printf '%s\n' "${FM_NM_BIN:-no-mistakes}"
}

# fm_nm_supports_watch: is the no-mistakes `watch` subcommand available?
#   0 = present and exposes `watch` (compatible)
#   1 = present but too old / lacks `watch` (incompatible)
#   2 = not installed at all (command -v fails)
# The install/absence case (2) is deliberately distinct so callers can leave the
# not-installed report to their existing MISSING path and treat only 1 as the new
# incompatibility diagnostic.
fm_nm_supports_watch() {
  local bin output rc
  bin=$(fm_nm_bin)
  command -v "$bin" >/dev/null 2>&1 || return 2
  # `--help` is informational: a missing subcommand exits non-zero with an
  # "unknown command" error, a working one exits zero with usage, and a build may
  # also print an unrelated "new build available" banner. Capture both streams and
  # decide from the text plus the exit code.
  output=$("$bin" watch --help 2>&1)
  rc=$?
  # Definite incompatibility: the exact signal an old build emits for a missing
  # subcommand (e.g. `unknown command "watch" for "no-mistakes"`).
  if printf '%s\n' "$output" | grep -qiE 'unknown (command|subcommand) "?watch"?'; then
    return 1
  fi
  # Positive capability: the watch help documents its required --pr flag.
  printf '%s\n' "$output" | grep -Fq -- '--pr' && return 0
  # `watch --help` exited zero without the unknown-command marker: the subcommand
  # exists (its help ran), so treat it as compatible even if the exact --pr text
  # is not matched.
  [ "$rc" -eq 0 ] && return 0
  # Non-zero exit with neither the unknown-command marker nor recognizable watch
  # help: the capability cannot be confirmed, so fail closed rather than silently
  # assume a broken or unfamiliar build is good.
  return 1
}

# fm_nm_incompatible_diagnostic: the single-owner captain-actionable line emitted
# when fm_nm_supports_watch reports 1. Kept here so bootstrap and self-update
# render byte-identical text and firstmate can pin one contract.
fm_nm_incompatible_diagnostic() {
  echo "NM_INCOMPATIBLE: no-mistakes is installed but too old for direct-PR monitoring (its \`watch\` command is missing); direct-PR CI, review, and merge alerts will not arm until it is upgraded (upgrade: no-mistakes update)"
}
