#!/usr/bin/env bash
# harnesses/codex.sh - the Codex harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# Codex installs NOTHING. Its turn-end signal rides the launch command itself
# (`-c notify=[...]`), so there is no file to write and nothing to remove.
# Both lists are deliberately empty rather than absent: an adapter that declares
# emptiness is a verified fact, while a missing adapter is an unverified harness.
#
# Codex's semantic busy-state wiring is separately gated as not-implemented in
# bin/fm-spawn.sh; if it ever lands and writes a file, declare it here.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_CODEX_WORKTREE_ARTIFACTS=''
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_CODEX_STATE_ARTIFACTS=''
