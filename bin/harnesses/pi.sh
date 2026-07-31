#!/usr/bin/env bash
# harnesses/pi.sh - the Pi harness adapter. Serves BOTH pi and pi-signed:
# pi-signed is Pi's distinct signed-wrapper identity, not a separate agent, and
# bin/fm-harness-adapter.sh resolves that alias once so call sites no longer
# need their own `pi|pi-signed)` arms.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# Pi installs NOTHING inside the worktree. Its extension is written to the STATE
# dir and loaded by absolute path via `-e`, deliberately: Pi's project-trust gate
# fires on any extension loaded from inside the project, but an explicit path
# elsewhere loads with no dialog. That is why this adapter's worktree list is
# empty while its state list is not - a shape no other adapter has.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_PI_WORKTREE_ARTIFACTS=''

# The extension supplies the `pi-ext` semantic busy source (agent_start /
# agent_settled) in addition to the turn-end signal.
# shellcheck disable=SC2034  # read indirectly by bin/fm-harness-adapter.sh;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_PI_STATE_ARTIFACTS='@ID@.pi-ext.ts'
