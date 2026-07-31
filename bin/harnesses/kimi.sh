#!/usr/bin/env bash
# harnesses/kimi.sh - the Kimi Code harness adapter.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.
#
# Kimi is verified for crewmate and secondmate launches only. It is NOT in
# FM_HARNESS_PRIMARY, which is why there is no docs/supervision-protocols/kimi.md
# and no kimi arm in bin/fm-supervision-instructions.sh. Those absences are
# correct; do not "fix" them from this adapter's existence.

# Kimi's Stop hook is globally configured but inert unless the working directory
# holds this per-task token pointer and the token resolves through firstmate's
# private registry - the same guarded shape Grok uses.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_KIMI_WORKTREE_ARTIFACTS='.fm-kimi-turnend'

# As with Grok, the registry entry under $HOME/.kimi-code/fm-turn-end.d/ is
# removed by value rather than by path, so bin/fm-teardown.sh's
# remove_kimi_turnend_auth owns it and it is not listed here.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_KIMI_STATE_ARTIFACTS='@ID@.kimi-turnend-token'
