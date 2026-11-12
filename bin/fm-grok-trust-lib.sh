#!/usr/bin/env bash
# bin/fm-grok-trust-lib.sh - Grok Build directory-trust predicates over one
# visible-pane capture. Sourced by bin/fm-spawn.sh's Grok readiness gate.
#
# Every function takes one plain pane capture as $1 and prints nothing.
# The wording recognized here was read from the Grok Build 1.0.70 binary
# (grok-1.0.70-linux-x86_64), not from a launched session:
#   question: Do you trust the contents of this directory?
#   warning:  posing security risks.
#   hint:     Enter or y to trust
#             (matched as two tokens, so a hint wrapped in a narrow pane
#             still counts)
#   options:  Yes, proceed, then No, quit
# The older "Trust this folder?" / "No, cancel" prompt is a different dialog.
# It is not answered here.
# Pane text is matched with case patterns rather than regexes because bash
# patterns compare the captured bytes, including newlines, without a regex
# dialect.

# grok_trust_dialog_is_visible <plain-pane-capture>
# True only for the complete 1.0.70 directory dialog. On success
# GROK_TRUST_AFFIRMATIVE and GROK_TRUST_NEGATIVE name the options, so a
# diagnostic can quote the wording the pane actually showed.
# shellcheck disable=SC2034 # Output globals read by the sourcing caller.
grok_trust_dialog_is_visible() {
  local pane=$1
  GROK_TRUST_AFFIRMATIVE=''
  GROK_TRUST_NEGATIVE=''
  case "$pane" in *'Do you trust the contents of this directory?'*) ;; *) return 1 ;; esac
  case "$pane" in *'posing security risks.'*) ;; *) return 1 ;; esac
  case "$pane" in *'Enter or y'*) ;; *) return 1 ;; esac
  case "$pane" in *'to trust'*) ;; *) return 1 ;; esac
  case "$pane" in
    *'Yes, proceed'*'No, quit'*)
      GROK_TRUST_AFFIRMATIVE='Yes, proceed'
      GROK_TRUST_NEGATIVE='No, quit'
      ;;
    *) return 1 ;;
  esac
}

# grok_trust_marker_is_present <plain-pane-capture>
# Any single marker of a trust prompt. A capture caught mid-redraw, or one
# that has painted only the question, fails the complete-dialog test while
# the prompt is still up, so none of those may read as ready. "to trust"
# alone is not a marker: that phrase is too ordinary to withhold readiness.
# "Trust this folder?" is the older prompt. It is not answered, and it is
# not a ready session either.
grok_trust_marker_is_present() {
  case "$1" in
    *'Do you trust the contents of this directory?'* | \
      *'posing security risks.'* | \
      *'Enter or y'* | \
      *'Yes, proceed'* | \
      *'No, quit'* | \
      *'Trust this folder?'*)
      return 0
      ;;
  esac
  return 1
}
