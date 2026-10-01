#!/usr/bin/env bash
# fm-composer-pi-adapter.sh - named, version-pinned Pi rendered-screen adapter.
#
# VISION.md: a vendor rendered surface may be read only as a named, quarantined,
# version-pinned adapter that carries its own verification and is expected to
# break on that vendor's next release. This file owns Pi's Codex usage-limit
# banner recognition for composer classification (issue #5000).
#
# Verified pins (refresh via tests/fm-composer-pi-codex-banner-live-e2e.test.sh
# and docs/verification/runtime-backends.md "Pi Codex usage-limit banner"):
#   - pi 0.85.1: banner alone above the separator pair
#   - pi 0.87.1: banner plus one fixed "/bug sends a report" hint row
#
# Callers set FM_COMPOSER_PI_ADAPTER_VERSION to the installed `pi --version`
# text (or a test fixture pin). Outside the pin set the adapter refuses the
# banner-as-empty verdict so an unpinned Pi rendering cannot become a shared
# empty proof. The portable byte fixtures set the pin explicitly; the live
# guard fails naming pi and its version when the installed release is outside
# the set or respells the banner.
#
# Sourced only from bin/fm-composer-lib.sh. Not a standalone entrypoint.

# shellcheck shell=bash

# Pinned releases whose rendered banner shape has a live guard record.
# Space-separated exact `pi --version` first-line values (no "pi " prefix).
FM_COMPOSER_PI_BANNER_PINNED_VERSIONS=${FM_COMPOSER_PI_BANNER_PINNED_VERSIONS:-'0.85.1 0.87.1'}

# Fixed banner Pi draws once a turn ended on Codex's usage limit.
FM_COMPOSER_PI_TERMINAL_ERROR_RE_DEFAULT='^Error: Codex error: The usage limit has been reached$'
# Fixed bug-report hint row pi 0.87.1 draws under every error banner.
FM_COMPOSER_PI_ERROR_HINT_RE_DEFAULT='^If this looks like a pi bug, /bug sends a report to the developers\.$'

# 0 when $1 is one of the pinned version strings (exact match after trim).
fm_composer_pi_adapter_version_pinned() {  # <version>
  local v=${1:-} pin
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  # Accept "0.85.1" or "pi 0.85.1" or longer first lines that start with the pin.
  v=${v#pi }
  v=${v#Pi }
  [ -n "$v" ] || return 1
  for pin in $FM_COMPOSER_PI_BANNER_PINNED_VERSIONS; do
    case "$v" in
      "$pin"|"$pin"*) return 0 ;;
    esac
  done
  return 1
}

# Resolve the adapter version: explicit override, else empty (unpinned).
fm_composer_pi_adapter_resolved_version() {
  local v=${FM_COMPOSER_PI_ADAPTER_VERSION:-}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

# 0 when the last non-blank row above the scanned pair's opening separator is
# pi's terminal provider-error banner, tolerating at most one occurrence of
# pi's fixed bug-report hint row directly beneath it. Rows are read plain.
# Returns 1 when the adapter version is unpinned or outside the pin set, so an
# unpinned Pi rendering cannot prove emptiness through this path.
fm_composer_pi_adapter_terminal_banner_above() {  # <screen>
  local screen=$1 row raw trimmed hint_seen=0 version
  version=$(fm_composer_pi_adapter_resolved_version)
  fm_composer_pi_adapter_version_pinned "$version" || return 1
  # Requires the shared scan context from fm-composer-lib.sh.
  [ -n "${FM_COMPOSER_SCAN_PI_OPEN:-}" ] || return 1
  row=$((FM_COMPOSER_SCAN_PI_OPEN - 1))
  while [ "$row" -ge 0 ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    trimmed=$(_fm_composer_row_content "$raw" 0)
    if [ -n "$trimmed" ]; then
      if fm_composer_idle_matches "$trimmed" \
        "${FM_COMPOSER_PI_TERMINAL_ERROR_RE:-$FM_COMPOSER_PI_TERMINAL_ERROR_RE_DEFAULT}" sensitive; then
        return 0
      fi
      if [ "$hint_seen" = 0 ] && fm_composer_idle_matches "$trimmed" \
        "${FM_COMPOSER_PI_ERROR_HINT_RE:-$FM_COMPOSER_PI_ERROR_HINT_RE_DEFAULT}" sensitive; then
        hint_seen=1
        row=$((row - 1))
        continue
      fi
      return 1
    fi
    row=$((row - 1))
  done
  return 1
}

# 0 when a stale (non-idle/done) pi status may still read empty because the
# pinned adapter recognized the terminal banner above the pair.
fm_composer_pi_adapter_settles_stale_status() {  # <screen>
  fm_composer_pi_adapter_terminal_banner_above "$1"
}
