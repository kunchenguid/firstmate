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
#   - pi 0.99.2, 1.0.0: same banner plus hint-row shape as 0.87.1
#
# The adapter reads the installed release from the first line of `--version`,
# once per process per executable. A caller that knows the task names the Pi
# executable that drew the pane in FM_COMPOSER_PI_EXECUTABLE (`pi` or
# `pi-signed`, from the task's recorded harness); the adapter then checks only
# that executable. Unset (or any other value), the pane's executable is unknown
# because the identity probe reports `pi` for both, so the adapter checks every
# Pi executable on PATH and requires at least one to exist and all found to be
# pinned. FM_COMPOSER_PI_ADAPTER_VERSION overrides the lookup (test fixtures pin
# it explicitly). Outside the pin set, or when no version can
# be read, the adapter refuses the banner-as-empty verdict so an unpinned Pi
# rendering cannot become a shared empty proof and the classifier keeps its
# ordinary unknown answer. The live guard proves the pinned shape on a pinned
# install, and on an unpinned install proves that refusal and names the release
# whose pin needs refreshing.
#
# Sourced only from bin/fm-composer-lib.sh. Not a standalone entrypoint.

# shellcheck shell=bash

# Pinned releases whose rendered banner shape has a live guard record.
# Space-separated exact `pi --version` first-line values (no "pi " prefix).
FM_COMPOSER_PI_BANNER_PINNED_VERSIONS=${FM_COMPOSER_PI_BANNER_PINNED_VERSIONS:-'0.85.1 0.87.1 0.99.2 1.0.0'}

# The terminal provider-error banner pi draws directly above its composer once
# a turn has ended on Codex's usage limit. Why it may relax the separated
# shape's idle/done status requirement (issue #5000): herdr learns pi's status
# only from pi's own lifecycle integration, so a status that never followed the
# failed turn parks at `working` or at herdr's `unknown` placeholder for as long
# as the worker sits on the banner, and every lifecycle verb then refuses a
# composer that is provably empty. The banner is structural evidence that the
# turn ENDED: a running pi retitles its opening rule (`── ⠏ Working ──`), which
# is no longer a solid separator and dissolves the pair, and a new prompt pushes
# transcript rows between the banner and the rule. The match is exact and
# case-sensitive, so a similar message from another provider, a worker
# discussing this text, or a wrapped copy of it never qualifies.
# From pi 0.87.1 on, pi draws the fixed bug-report hint directly below EVERY
# error banner. It is vendor boilerplate attached to the banner, not a
# transcript row proving a new turn, so the scan skips at most one occurrence.
# FM_COMPOSER_PI_TERMINAL_ERROR_RE and FM_COMPOSER_PI_ERROR_HINT_RE override
# for an unverified rendering.
# Fixed banner Pi draws once a turn ended on Codex's usage limit.
FM_COMPOSER_PI_TERMINAL_ERROR_RE_DEFAULT='^Error: Codex error: The usage limit has been reached$'
# Fixed bug-report hint row pi 0.87.1 draws under every error banner.
FM_COMPOSER_PI_ERROR_HINT_RE_DEFAULT='^If this looks like a pi bug, /bug sends a report to the developers\.$'

# 0 when $1 is one of the pinned version strings (exact match after trim).
fm_composer_pi_adapter_version_pinned() {  # <version>
  local v=${1:-} pin
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  # Accept "0.85.1" or "pi 0.85.1"; anything after the version word is ignored,
  # but the version itself must equal a pin exactly (1.0.0 never admits 1.0.01).
  v=${v#pi }
  v=${v#Pi }
  [ -n "$v" ] || return 1
  v=${v%%[[:space:]]*}
  for pin in $FM_COMPOSER_PI_BANNER_PINNED_VERSIONS; do
    [ "$v" = "$pin" ] && return 0
  done
  return 1
}

# 0 when the Pi release(s) behind the pane are pinned. The identity probe
# reports `pi` for both `pi` and `pi-signed`, so only a caller that knows the
# task can say which executable drew the pane. With FM_COMPOSER_PI_EXECUTABLE
# naming `pi` or `pi-signed`, only that executable is checked and it must be on
# PATH. Otherwise every Pi executable found on PATH is checked and at least one
# must be found. Each `--version` first line is read at most once per process
# (cached in globals, no subshell); a checked executable that is unpinned or
# prints no version keeps the banner unproven.
fm_composer_pi_adapter_installed_pinned() {
  local exe found=0 v candidates='pi pi-signed'
  if [ -n "${FM_COMPOSER_PI_ADAPTER_VERSION:-}" ]; then
    fm_composer_pi_adapter_version_pinned "$FM_COMPOSER_PI_ADAPTER_VERSION"
    return
  fi
  case "${FM_COMPOSER_PI_EXECUTABLE:-}" in
    pi|pi-signed) candidates=$FM_COMPOSER_PI_EXECUTABLE ;;
  esac
  for exe in $candidates; do
    command -v "$exe" >/dev/null 2>&1 || continue
    found=1
    if [ "$exe" = pi ]; then
      if [ -z "${_FM_COMPOSER_PI_VERSION_PI+x}" ]; then
        _FM_COMPOSER_PI_VERSION_PI=$(pi --version 2>/dev/null | head -1) || _FM_COMPOSER_PI_VERSION_PI=
      fi
      v=$_FM_COMPOSER_PI_VERSION_PI
    else
      if [ -z "${_FM_COMPOSER_PI_VERSION_SIGNED+x}" ]; then
        _FM_COMPOSER_PI_VERSION_SIGNED=$(pi-signed --version 2>/dev/null | head -1) || _FM_COMPOSER_PI_VERSION_SIGNED=
      fi
      v=$_FM_COMPOSER_PI_VERSION_SIGNED
    fi
    fm_composer_pi_adapter_version_pinned "$v" || return 1
  done
  [ "$found" = 1 ]
}

# 0 when the last non-blank row above the scanned pair's opening separator is
# pi's terminal provider-error banner, tolerating at most one occurrence of
# pi's fixed bug-report hint row directly beneath it. Rows are read plain.
# Returns 1 when the adapter version is unpinned or outside the pin set, so an
# unpinned Pi rendering cannot prove emptiness through this path.
fm_composer_pi_adapter_terminal_banner_above() {  # <screen>
  local screen=$1 row raw trimmed hint_seen=0
  fm_composer_pi_adapter_installed_pinned || return 1
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
