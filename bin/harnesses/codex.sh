#!/usr/bin/env bash
# harnesses/codex.sh - the Codex harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# Codex draws the classic "esc to interrupt" footer while a turn is active, with
# no second shape observed. Moved verbatim from bin/fm-tmux-lib.sh's
# FM_TMUX_CODEX_BUSY_REGEX_DEFAULT.
# shellcheck disable=SC2034  # read by bin/fm-harness-adapter.sh's dispatcher;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_CODEX_BUSY_REGEX='esc to interrupt'
