#!/usr/bin/env bash
# fm-harness-adapter.sh - agent-harness registry, adapter selection, and dispatch
# for firstmate's harness abstraction.
#
# Design: data/harness-interface-build/design.md ("The interface"), built on the
# phase-1 inventory in data/harness-interface-phase1/report.md. This mirrors
# bin/fm-backend.sh + bin/backends/<name>.sh on the OTHER axis: a BACKEND is the
# session provider a task runs inside (tmux, herdr, zellij, orca, cmux), while a
# HARNESS is the agent CLI running inside that session (claude, codex, opencode,
# pi, pi-signed, grok, kimi). The two axes are independent, and until now only
# the backend axis had a home of its own.
#
# PR A extracts the per-harness BUSY SIGNATURE that bin/fm-tmux-lib.sh used to
# own into bin/harnesses/<name>.sh, carrying those SAME regex strings and the
# SAME case precedence, so every consumer stays byte-identical. Later stages move
# turn-end install/cleanup, process identity, and the launch command; each is its
# own reviewable change and none is anticipated here.
#
# Why the busy table moved (phase-1 report section 2.2, "Leak A"): it is the
# most-consumed harness fact in the system - 8 call sites across 5 files - and it
# lived in a BACKEND-named library. bin/fm-crew-state.sh, bin/fm-supervise-daemon.sh,
# and bin/fm-pending-reply-lib.sh each had to source bin/fm-tmux-lib.sh purely to
# read harness knowledge, and bin/fm-crew-state.sh routes NON-tmux backends
# through it explicitly. That is a cross-axis misplacement, not a style
# complaint: on a herdr or cmux home, every health-inference busy read reached
# into a tmux library.
#
# TWO name sets, deliberately different. Do NOT collapse them:
#   FM_HARNESS_KNOWN    launchable as a crewmate or secondmate (docs/configuration.md)
#   FM_HARNESS_PRIMARY  supported for the PRIMARY session (README.md "Requirements")
# kimi is verified for crewmate and secondmate launches but is NOT a supported
# primary harness. That is why bin/fm-supervision-instructions.sh has no kimi arm
# and docs/supervision-protocols/ has no kimi.md - both are correct, not drift. A
# single merged list would silently promote kimi to a primary harness.
#
# Sourcing this file loads every adapter in bin/harnesses/ (see "adapter loading"
# at the foot of the file for why that is eager rather than lazy). It has no other
# side effects: nothing is written, and no external command is run.

FM_HARNESS_ADAPTER_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_HARNESS_ADAPTER_LIB_DIR="$(cd "$(dirname "$FM_HARNESS_ADAPTER_SCRIPT")" && pwd)"
unset FM_HARNESS_ADAPTER_SCRIPT

# Verified harness adapters. Extend only after a harness gets its own
# bin/harnesses/<name>.sh and empirical verification, mirroring the backend
# axis's adapter-verification discipline (AGENTS.md section 4).
FM_HARNESS_KNOWN="claude codex opencode pi pi-signed grok kimi"
FM_HARNESS_PRIMARY="claude codex opencode pi pi-signed grok"

# The shared fallback signature, used when NO harness is known for a target.
# It is deliberately the union of the plainly-generic footers only: it must be
# safe to run against output from an unidentified agent. Claude's ellipsis-plus-
# elapsed spinner and Kimi's moon-phase spinner are NOT in it, because neither
# shape is generic enough to classify arbitrary output; each stays scoped to its
# own adapter. Moved verbatim from bin/fm-tmux-lib.sh's
# FM_TMUX_BUSY_REGEX_DEFAULT.
FM_HARNESS_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

# fm_harness_list_contains: whitespace-delimited membership without relying on
# shell word splitting, mirroring fm_backend_list_contains. This file is normally
# sourced by bash, but zsh diagnostics can source it too, so name matching must
# stay portable.
fm_harness_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

# True when <name> is a verified harness firstmate may launch as a crewmate or
# secondmate.
fm_harness_is_known() {  # <name>
  fm_harness_list_contains "$FM_HARNESS_KNOWN" "$1"
}

# True when <name> is verified for the PRIMARY firstmate session. Strictly
# narrower than fm_harness_is_known; see the header.
fm_harness_is_primary() {  # <name>
  fm_harness_list_contains "$FM_HARNESS_PRIMARY" "$1"
}

# fm_harness_adapter_name: the adapter FILE a harness resolves to. pi-signed is
# Pi's distinct signed-wrapper identity, not a separate agent, so it shares
# bin/harnesses/pi.sh. Resolving the alias exactly once here is what lets call
# sites drop their own `pi|pi-signed)` arms.
fm_harness_adapter_name() {  # <name> -> adapter base name on stdout, or 1
  local adapter
  _fm_harness_adapter_name_into adapter "$1" || return 1
  printf '%s' "$adapter"
}

# _fm_harness_adapter_name_into: the same mapping, assigned to <varname> instead
# of printed, so hot-path callers resolve it without a command substitution. The
# alias lives here and nowhere else; every other form delegates to it.
_fm_harness_adapter_name_into() {  # <varname> <name>
  local _var=$1 name=$2
  fm_harness_is_known "$name" || return 1
  case "$name" in
    pi-signed) printf -v "$_var" '%s' pi ;;
    *) printf -v "$_var" '%s' "$name" ;;
  esac
}

# fm_harness_source: source ONE harness adapter, at most once per shell. Called
# by fm_harness_source_all at load time, and usable directly.
# Each adapter is an independently linted canonical root, so the /dev/null source
# boundaries mirror fm_backend_source's. Unlike that one, these are all loaded
# eagerly; the "adapter loading" note at the foot of this file owns that decision.
fm_harness_source() {  # <name>
  local adapter
  _fm_harness_adapter_name_into adapter "$1" || return 1
  case "$adapter" in
    claude)
      if [ -z "${_FM_HARNESS_CLAUDE_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/claude.sh" || return 1
        _FM_HARNESS_CLAUDE_SOURCED=1
      fi
      ;;
    codex)
      if [ -z "${_FM_HARNESS_CODEX_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/codex.sh" || return 1
        _FM_HARNESS_CODEX_SOURCED=1
      fi
      ;;
    opencode)
      if [ -z "${_FM_HARNESS_OPENCODE_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/opencode.sh" || return 1
        _FM_HARNESS_OPENCODE_SOURCED=1
      fi
      ;;
    pi)
      if [ -z "${_FM_HARNESS_PI_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/pi.sh" || return 1
        _FM_HARNESS_PI_SOURCED=1
      fi
      ;;
    grok)
      if [ -z "${_FM_HARNESS_GROK_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/grok.sh" || return 1
        _FM_HARNESS_GROK_SOURCED=1
      fi
      ;;
    kimi)
      if [ -z "${_FM_HARNESS_KIMI_SOURCED:-}" ]; then
        # shellcheck source=/dev/null
        . "$FM_HARNESS_ADAPTER_LIB_DIR/harnesses/kimi.sh" || return 1
        _FM_HARNESS_KIMI_SOURCED=1
      fi
      ;;
    *) return 1 ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Thin wrappers so a caller names an operation and a harness rather than
# hand-writing a per-harness `case` at every call site. Each verified harness
# adds its own adapter file, without changing call sites.

# fm_harness_busy_regex: the verified busy-footer signature for <harness>.
#
# Three arms, preserved exactly from bin/fm-tmux-lib.sh's fm_busy_lines_match:
#   a known harness  -> its own adapter's signature
#   the EMPTY string -> the shared generic fallback (no harness recorded)
#   anything else    -> EMPTY, so an unregistered harness is never classified
#                       busy by borrowing another harness's signature. Register a
#                       verified signature before classifying a new harness.
fm_harness_busy_regex() {  # <harness> -> regex on stdout, empty when unmatched
  local regex
  _fm_harness_busy_regex_into regex "${1:-}"
  printf '%s' "$regex"
}

# _fm_harness_busy_regex_into: the same resolution, assigned to <varname> instead
# of printed. The printing form above is the public one, but the hot path uses
# this to stay fork-free; see fm_harness_busy_match.
_fm_harness_busy_regex_into() {  # <varname> <harness>
  local _var=$1 harness=${2:-} adapter
  if [ -z "$harness" ]; then
    printf -v "$_var" '%s' "$FM_HARNESS_BUSY_REGEX_DEFAULT"
    return 0
  fi
  _fm_harness_adapter_name_into adapter "$harness" || {
    printf -v "$_var" '%s' ''
    return 0
  }
  case "$adapter" in
    claude) printf -v "$_var" '%s' "$FM_HARNESS_CLAUDE_BUSY_REGEX" ;;
    codex) printf -v "$_var" '%s' "$FM_HARNESS_CODEX_BUSY_REGEX" ;;
    opencode) printf -v "$_var" '%s' "$FM_HARNESS_OPENCODE_BUSY_REGEX" ;;
    pi) printf -v "$_var" '%s' "$FM_HARNESS_PI_BUSY_REGEX" ;;
    grok) printf -v "$_var" '%s' "$FM_HARNESS_GROK_BUSY_REGEX" ;;
    kimi) printf -v "$_var" '%s' "$FM_HARNESS_KIMI_BUSY_REGEX" ;;
  esac
}

# fm_harness_busy_match: read ALL of stdin, then report whether it shows
# <harness>'s busy footer. Exit 0 busy, 1 idle.
#
# FM_BUSY_REGEX globally overrides the per-harness signature, matching the
# override that bin/fm-watch.sh and the away-mode daemon already honor.
# An empty resolved regex never matches, so an unregistered harness reads idle.
fm_harness_busy_match() {  # <harness>  (stdin: captured lines)
  local harness=${1:-} lines regex
  IFS= read -r -d '' lines || true
  if [ -n "${FM_BUSY_REGEX:-}" ]; then
    regex=$FM_BUSY_REGEX
  else
    # The assign-into form, not the printing one: this runs in the watcher's poll
    # loop, and a command substitution here would fork on every busy check.
    _fm_harness_busy_regex_into regex "$harness"
  fi
  [ -n "$regex" ] && printf '%s' "$lines" | grep -qiE "$regex"
}

# --- adapter loading ---------------------------------------------------------
#
# Every adapter is loaded HERE, once, when this file is sourced - not lazily per
# call. Two reasons, both measured:
#
#   fm_harness_busy_match reads stdin, so it is always invoked as the right-hand
#   side of a pipe and therefore always runs in a SUBSHELL. A lazy source inside
#   it could never populate a cross-call guard: the guard would be discarded with
#   the subshell and the adapter re-read on every single busy check. That check
#   runs per task window per watcher poll.
#
#   The adapters are pure data - roughly 110 lines across all six - so loading
#   them eagerly costs one negligible read at startup and keeps the hot path a
#   plain variable read with no fork.
#
# This is the deliberate difference from bin/fm-backend.sh, which loads lazily
# because its adapters are orders of magnitude larger (bin/backends/herdr.sh
# alone is over 1700 lines) and most consumers touch only one of them.
fm_harness_source_all() {
  local h
  for h in claude codex opencode pi grok kimi; do
    fm_harness_source "$h" || return 1
  done
}
# This file is a library and is only ever sourced, so a bare `return` is the
# correct refusal: a consumer that cannot load the adapters must fail closed
# rather than run with an empty signature table, which would read every busy
# pane as idle.
fm_harness_source_all || {
  echo "error: bin/harnesses adapters are missing or unreadable" >&2
  return 1
}
