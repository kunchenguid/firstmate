#!/usr/bin/env bash
# harnesses/claude.sh - the Claude Code harness adapter, and the REFERENCE
# template every other adapter in this directory follows.
#
# Sourced on demand by bin/fm-harness-adapter.sh; never executed directly and
# never sourced by a call site itself. Adapters hold per-harness FACTS and must
# stay free of policy: when to install, when to remove, and what to do with a
# leftover file all belong to fm-spawn and fm-teardown.
#
# Adapter contract:
#   FM_HARNESS_<NAME>_WORKTREE_ARTIFACTS  newline-separated paths RELATIVE to the
#                                         task worktree that this harness's
#                                         wiring writes. fm-spawn adds each to
#                                         info/exclude; fm-teardown removes each.
#   FM_HARNESS_<NAME>_STATE_ARTIFACTS     newline-separated names RELATIVE to the
#                                         state dir, with @ID@ standing for the
#                                         task id.
# Either list may be empty; bin/harnesses/codex.sh declares both empty.
#
# These are constants rather than functions because they are pure data, and the
# dispatcher builds its unions by reading them indirectly.
#
# Adding a harness: create bin/harnesses/<name>.sh declaring both constants, add
# the name to FM_HARNESS_KNOWN (and FM_HARNESS_PRIMARY only when the primary
# session is genuinely supported) plus FM_HARNESS_ADAPTERS, add its source arm,
# and extend tests/fm-harness-artifacts.test.sh's installed-vs-removed proof.
# Do NOT hand-write the new path into fm-teardown's removal blocks - the whole
# point of this directory is that there is one list.
#
# CRITICAL when changing a path here: change it in this file only. The rename
# that motivated this adapter layer (OpenCode's fm-turn-end.js ->
# fm-busy-state.js) was applied to the installer and to two of four removal
# blocks, and the two that were missed silently stopped cleaning anything.

# Claude's turn-end and semantic busy-state wiring are one file: a settings
# overlay carrying the lifecycle hooks (UserPromptSubmit/Stop/StopFailure/
# SessionEnd) that bin/fm-busy-lib.sh trusts as the `claude-hook` source.
# The whole .claude/ directory is firstmate-created in a fresh task worktree.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_CLAUDE_WORKTREE_ARTIFACTS='.claude/settings.local.json'

# Claude keeps no per-task file in the state dir of its own. The busy-state
# record and gen sidecar are per-TASK, not per-harness, so bin/fm-busy-event.sh
# and fm-teardown's retire_busy_state own them rather than any adapter.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_CLAUDE_STATE_ARTIFACTS=''
