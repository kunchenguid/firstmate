#!/usr/bin/env bash
# tests/capacity-pin.sh - the single owner of the pinned machine measurements
# every suite that drives a real bin/fm-spawn.sh runs against.
#
# Source this from a test file that does NOT source tests/lib.sh:
#   # shellcheck source=tests/capacity-pin.sh
#   . "$ROOT/tests/capacity-pin.sh"
# tests/lib.sh sources it for every other suite, so most tests get it for free.
#
# WHY
# fm-spawn.sh admits a spawn only when the machine has headroom
# (bin/fm-capacity-lib.sh). Firstmate's own suite runs on exactly the busy
# machines that guard exists to protect, so an unpinned spawn test would pass or
# fail depending on the memory pressure at that second. These values substitute
# MEASUREMENTS, not a switch: the guard still evaluates every rule against them,
# and there is deliberately no environment variable that turns it off. A suite
# testing the guard itself sets its own values per case.
#
# The pinned machine: 16 GB with half of it free, swap untouched, kernel calm,
# and one small agent running.
export FM_CAPACITY_MEM_TOTAL_MB=16384
export FM_CAPACITY_MEM_FREE_MB=8192
export FM_CAPACITY_SWAP_TOTAL_MB=8192
export FM_CAPACITY_SWAP_USED_MB=0
export FM_CAPACITY_MEM_PRESSURE=normal
export FM_CAPACITY_SWAPOUTS=0
export FM_CAPACITY_FLEET_RSS_MB=512
export FM_CAPACITY_FLEET_AGENTS=1
export FM_CAPACITY_FLEET_PROCS=4
export FM_CAPACITY_CORES=8
export FM_CAPACITY_LOAD1=1.0
