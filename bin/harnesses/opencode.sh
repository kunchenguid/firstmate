#!/usr/bin/env bash
# harnesses/opencode.sh - the OpenCode harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# OpenCode's wiring is a plugin that reports session.status as the
# `opencode-plugin` semantic busy source and also touches the turn-end file.
#
# This path was RENAMED from .opencode/plugins/fm-turn-end.js when the semantic
# busy-state contract landed. That rename is exactly what drifted: the installer
# and two of four teardown removal blocks were updated, the other two were not,
# and they kept removing a file fm-spawn no longer writes - so the ordinary
# teardown path cleaned nothing and leaked the plugin into a pooled worktree.
# Declaring it once here is what makes that class of miss impossible.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_OPENCODE_WORKTREE_ARTIFACTS='.opencode/plugins/fm-busy-state.js'

# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_OPENCODE_STATE_ARTIFACT_SUFFIXES=''
