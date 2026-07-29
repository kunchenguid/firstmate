#!/usr/bin/env bash
# harnesses/pi.sh - the Pi harness adapter. Serves BOTH pi and pi-signed:
# pi-signed is Pi's distinct signed-wrapper identity, not a separate agent, and
# bin/fm-harness-adapter.sh's fm_harness_adapter_name resolves that alias once so
# call sites no longer need their own `pi|pi-signed)` arms.
# bin/harnesses/claude.sh is the reference template and owns the adapter contract.

# Pi prints a literal "Working..." status while a turn is active. Moved verbatim
# from bin/fm-tmux-lib.sh's FM_TMUX_PI_BUSY_REGEX_DEFAULT.
# shellcheck disable=SC2034  # read by bin/fm-harness-adapter.sh's dispatcher;
# each adapter is linted as its own canonical root, so its consumer is out of scope.
FM_HARNESS_PI_BUSY_REGEX='Working\.\.\.'
