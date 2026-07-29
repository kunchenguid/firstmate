#!/usr/bin/env bash
# harnesses/grok.sh - the Grok harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# Grok's active-turn footer offers its cancel binding: "Ctrl+c:cancel", with no
# surrounding whitespace around the colon. Moved verbatim from
# bin/fm-tmux-lib.sh's FM_TMUX_GROK_BUSY_REGEX_DEFAULT.
# shellcheck disable=SC2034  # read by bin/fm-harness-adapter.sh's dispatcher;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_GROK_BUSY_REGEX='Ctrl\+c:cancel'
