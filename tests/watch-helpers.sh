#!/usr/bin/env bash
# tests/watch-helpers.sh - fixtures for the supervision-sensing gates (w1..w6).
#
# The watcher is a long-running loop that EXITS on its first wake, so every case
# here is "arrange a fleet, run one watcher, read the one line it printed". The
# two senses need different arrangements and the helpers below build both.
#
# WHY THE PRE-SEEDED COUNTER. Stale needs two consecutive identical observations
# before it reports, so a from-cold watcher would need three poll cycles. Seeding
# .hash-<key>/.count-<key> - exactly as tests/fm-wake-queue.test.sh already does
# for the tmux path - puts the watcher one cycle from its decision and keeps the
# suites fast without weakening what is asserted.

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

FM_WATCH="$ROOT/bin/fm-watch.sh"

# fm_watch_case <root> <name> -> prints a case dir with state/ and a fakebin
# holding BOTH fakes: a herdr that answers `api snapshot`, and a tmux that
# answers capture-pane. Both are always present so a routing mistake shows up as
# the wrong surface being consulted rather than as a missing binary.
fm_watch_case() {  # <tmp-root> <name>
  local dir="$1/$2"
  mkdir -p "$dir/state"
  fm_herdr_fake_server "$dir" >/dev/null
  fm_herdr_fake_tmux "$dir" >/dev/null
  printf '%s\n' "$dir"
}

# fm_watch_meta <state> <id> <window> <mux> <kind>
fm_watch_meta() {  # a meta with no mux= line is written by passing "" for <mux>
  local state=$1 id=$2 window=$3 mux=$4 kind=$5
  {
    printf 'window=%s\n' "$window"
    printf 'worktree=/wt\nproject=/p/demo\nharness=claude\n'
    [ -n "$mux" ] && printf 'mux=%s\n' "$mux"
    printf 'kind=%s\n' "$kind"
  } > "$state/$id.meta"
}

# fm_watch_prime <state> <window> <observation>: put the watcher one cycle from
# its stale decision for this target.
fm_watch_prime() {  # <state> <window> <observation>
  local key; key=$(printf '%s' "$2" | tr ':/.' '___')
  printf '%s' "$3" > "$1/.hash-$key"
  printf '1\n' > "$1/.count-$key"
}

# fm_watch_run <dir> [limit-tenths] -> runs ONE watcher against the case and
# prints whatever wake line it produced (empty when it never woke). Never leaves
# a watcher behind.
#
# THE BUDGET IS GENEROUS ON PURPOSE. These cases are wall-clock bounded, and a
# gate that goes red because the machine was busy is a false alarm that teaches
# everyone to ignore it. A wake normally lands inside one poll, so 30s costs
# nothing when the answer is yes and only matters when the box is loaded - which
# is exactly what a full ledger sweep, running 47 suites back to back, does to
# it. This flaked w1 and w2 red under `ledger verify` while both passed
# standalone 24 times running.
#
# A LONGER BUDGET ALONE WOULD ONLY TRADE FALSE REDS FOR FALSE GREENS, because a
# case asserting that NOTHING happens passes trivially if the watcher never got
# far enough to decide. So every negative case pairs its budget with
# fm_watch_assert_sensed / fm_watch_assert_ran below, which require evidence the
# decision point was actually reached.
fm_watch_run() {  # <case-dir> [limit]
  local dir=$1 limit=${2:-300} out="$1/watch.out" pid
  : > "$out"
  PATH="$dir/fakebin:$PATH" CALLS="$dir/calls" \
    FM_STATE_OVERRIDE="$dir/state" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$FM_WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!
  wait_for_exit "$pid" "$limit" >/dev/null 2>&1 || true
  cat "$out"
}

# --- proof that a "nothing happened" answer is not vacuous --------------------

# The watcher reached its stale decision for THIS target at least <min> times.
# .count-<key> is advanced once per cycle in which the observation matched the
# previous one - i.e. once per cycle that actually evaluated whether to wake.
fm_watch_assert_sensed() {  # <state> <window> [min] [msg]
  local state=$1 w=$2 min=${3:-2} msg=${4:-} key n
  key=$(printf '%s' "$w" | tr ':/.' '___')
  n=$(cat "$state/.count-$key" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -ge "$min" ] && return 0
  fail "${msg:-the watcher never reached its stale decision for $w} (sensed $n times, wanted >= $min); a 'no wake' result here would be vacuous"
}

# The watcher ran at least one full cycle. For targets whose bookkeeping is
# deliberately skipped - a kind=secondmate, which is exempted before any marker
# is touched - this is the available evidence that the loop actually ran.
fm_watch_assert_ran() {  # <case-dir> [msg]
  local dir=$1 msg=${2:-}
  [ -e "$dir/state/.last-watcher-beat" ] && return 0
  fail "${msg:-the watcher never completed a cycle}; a 'no wake' result here would be vacuous"
}

# The per-target bookkeeping was RESET - the pane stopped holding an agent, so
# whatever episode was in progress ended. Proof that the reset branch ran, which
# is what keeps a relaunch from inheriting the previous wedge's suppressor.
fm_watch_assert_reset() {  # <state> <window> [msg]
  local state=$1 w=$2 msg=${3:-} key
  key=$(printf '%s' "$w" | tr ':/.' '___')
  if [ -e "$state/.hash-$key" ] || [ -e "$state/.stale-$key" ] || [ -e "$state/.count-$key" ]; then
    fail "${msg:-the bookkeeping for $w survived the pane losing its agent}"
  fi
  return 0
}
