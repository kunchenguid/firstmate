#!/usr/bin/env bash
# harnesses/opencode.sh - the OpenCode harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# OpenCode's busy footer drops the "to": "esc interrupt", not "esc to interrupt".
# The shared fallback in bin/fm-harness-adapter.sh spells the middle word
# optionally so it covers both, but this adapter stays exact. Moved verbatim from
# bin/fm-tmux-lib.sh's FM_TMUX_OPENCODE_BUSY_REGEX_DEFAULT.
# shellcheck disable=SC2034  # read by bin/fm-harness-adapter.sh's dispatcher;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_OPENCODE_BUSY_REGEX='esc interrupt'
