#!/usr/bin/env bash
# fm-agy-ladder-tick.sh - run one agy ladder evaluation for this home and queue
# whatever it decided.
#
# Usage: fm-agy-ladder-tick.sh
#   FM_HOME selects the home; FM_STATE_OVERRIDE overrides its state directory.
#
# WHY THIS EXISTS. bin/fm-agy-descent-lib.sh keeps a RUNNING agy worker off the
# captain's reserved quarter of rung 1, and until now only bin/fm-watch.sh ever
# ran it. The watcher is armed by firstmate when firstmate goes to wait and it
# exits as soon as it has something to say, so it runs BETWEEN firstmate's turns
# and never during one. That left the reserve conditional on how long firstmate's
# turns happen to be: on 2026-08-21 an evaluation at 18:48 read 28.7% and
# correctly declined to move anyone, firstmate then spent about ten minutes
# inside a single turn, and the rung was at 19.6% - inside the reserve, still
# being spent - before anything looked again.
#
# This script is the entry point for the driver that firstmate's turn boundaries
# cannot starve: the spender itself. Every agy worker fires firstmate's own Stop
# hook at the end of every turn it takes (bin/fm-spawn.sh installs it), the hook
# runs in the WORKER's process tree, and it runs this detached so the worker's
# turn never waits on a quota read or a picker walk.
#
# IT IS AN ADJUNCT, NOT A DAEMON OR A SECOND WATCHER. It polls nothing, sleeps
# on nothing, and holds no endpoint. It runs one evaluation and exits, and that
# evaluation is single-flight (bin/fm-agy-descent-lib.sh owns the lock), so a
# burst of workers ending turns together costs one evaluation, not one each.
#
# WHAT IS AND IS NOT PROVEN AGAINST A REAL agy. That agy fires this Stop hook at
# the end of every turn is not a new assumption: it is the same hook firstmate's
# semantic busy state has run on since agy 1.1.12 (bin/fm-busy-lib.sh owns that
# contract and its evidence), and this only adds work to it. What IS new is that
# the work is detached, so the hook's own bound cannot reap it - which is why
# bin/fm-spawn.sh detaches it into its own process group, and why
# tests/fm-agy-live-descent.test.sh drives the real generated hook and then
# destroys that hook's process group before asserting the outcome still lands.
#
# THE OUTCOME GOES SOMEWHERE DURABLE, because there may be nothing listening.
# The watcher turns each outcome line into a live wake AND a durable queue
# record; here there is no watcher process to wake, so the record is all there
# is, and firstmate reads it on its next wake-handling turn or at session start.
# fm_agy_descent_turn_end owns that evaluate-and-publish step; this file is the
# executable a hook can name.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

[ -d "$STATE" ] || exit 0

# The same libraries bin/fm-watch.sh loads before the evaluation, in the same
# order. Source analysis stops at each of them: every one is a canonical lint
# root already, so following them from here adds no uncovered line and only
# duplicates the largest source graphs this repo has inside one more root.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-agy-quota-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-agy-descent-lib.sh"

fm_agy_descent_turn_end "$STATE"
