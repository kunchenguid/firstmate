#!/usr/bin/env bash
# harnesses/grok.sh - the Grok harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# Grok's Stop hook must live OUTSIDE the worktree: Grok loads project hooks only
# after the folder is granted hook-trust, which firstmate cannot establish at
# launch without editing Grok's managed trust store. So a single firstmate-owned
# GLOBAL hook is installed once, and each task drops this per-task token pointer
# in its worktree to arm that hook for itself.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_GROK_WORKTREE_ARTIFACTS='.fm-grok-turnend'

# The pointer's target lives in the state dir and names an entry in firstmate's
# private hook registry under ${GROK_HOME:-$HOME/.grok}/hooks/fm-turn-end.d/.
# That registry entry is NOT listed here: removing it needs the token's value,
# not just its path, so bin/fm-teardown.sh's remove_grok_turnend_auth owns it.
# That function is already a single owner, so folding it in would buy nothing.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_GROK_STATE_ARTIFACT_SUFFIXES='.grok-turnend-token'
