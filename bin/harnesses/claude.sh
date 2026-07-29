#!/usr/bin/env bash
# harnesses/claude.sh - the Claude Code harness adapter, and the REFERENCE
# template every other adapter in this directory follows.
#
# Sourced on demand by bin/fm-harness-adapter.sh's fm_harness_source; never
# executed directly and never sourced by a call site itself. Adapters hold
# per-harness FACTS and must stay free of policy: which panes to scan, when to
# scan them, and what to do with the answer all belong to supervision.
#
# Adapter contract (PR A):
#   FM_HARNESS_<NAME>_BUSY_REGEX   the verified busy-footer signature. One
#                                  extended regex, matched case-insensitively
#                                  against the last few non-blank captured lines.
#                                  It must be specific enough that it cannot fire
#                                  on another harness's ordinary output.
#
# It is a constant rather than a function because it is pure data and because the
# dispatcher resolves it on the watcher's poll path: reading a variable keeps that
# resolution fork-free, while a function would cost a command substitution per
# busy check. Later methods that genuinely compute something will be functions.
#
# Adding a harness: create bin/harnesses/<name>.sh with that constant, add the
# name to FM_HARNESS_KNOWN (and FM_HARNESS_PRIMARY only when the primary session
# is genuinely supported), add its source and dispatch arms, and record the
# empirical basis for the signature the way this file does. Never let a new
# harness fall back to another harness's signature.
#
# Claude Code is the primary-session reference harness (README.md "Recommended
# harnesses") and the one verified against a live binary on the machine this
# adapter was extracted on.

# Claude's active-turn spinner rotates both its glyph and its verb, so neither is
# a stable anchor. Two alternatives cover it: the classic "esc to interrupt"
# footer, and the ellipsis followed by a parenthesized elapsed duration that every
# active-turn line carries even when the interrupt hint is absent from that row.
#
# This signature is deliberately NOT part of the shared fallback in
# bin/fm-harness-adapter.sh: an ellipsis followed by elapsed time is not specific
# enough to classify output from an unidentified agent, so it stays scoped to a
# task recorded as claude. Moved verbatim from bin/fm-tmux-lib.sh's
# FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT.
# shellcheck disable=SC2034  # read by bin/fm-harness-adapter.sh's dispatcher;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_CLAUDE_BUSY_REGEX='esc to interrupt|…[[:space:]]+\([0-9]+[smh]'
