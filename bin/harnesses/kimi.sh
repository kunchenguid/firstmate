#!/usr/bin/env bash
# harnesses/kimi.sh - the Kimi Code harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.
#
# Kimi is verified for crewmate and secondmate launches only. It is NOT in
# FM_HARNESS_PRIMARY, which is why there is no docs/supervision-protocols/kimi.md
# and no kimi arm in bin/fm-supervision-instructions.sh. Those absences are
# correct; do not "fix" them from this adapter's existence.

# Kimi exposes no stable ASCII busy token, so the signature anchors on its
# moon-phase spinner. Every constraint below is load-bearing and was derived from
# captured spinner rows; moved verbatim from bin/fm-tmux-lib.sh's
# FM_TMUX_KIMI_BUSY_REGEX_DEFAULT.
#
#   ANCHORED at line start (with optional leading whitespace) because bare moon
#   glyphs in ordinary output must never classify a pane as busy.
#   Whitespace on BOTH sides of the middot separator is REQUIRED: every captured
#   spinner row had it, and a zero-whitespace form has never been observed, so it
#   is deliberately not matched.
#   The line end is intentionally UNANCHORED because rotating tip text follows and
#   is not required to be present.
#
# The idle status bar's lowercase "thinking" label and its independently rotating
# tip text are NOT busy signals on their own and are deliberately unmatched.
# This signature stays locale- and emoji-font-sensitive; that is a known limit of
# anchoring on a glyph set, not an oversight.
# shellcheck disable=SC2034  # read by bin/fm-harness-adapter.sh's dispatcher;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_KIMI_BUSY_REGEX='^[[:space:]]*(🌑|🌒|🌓|🌔|🌕|🌖|🌗|🌘)[[:space:]]+·[[:space:]]+'
