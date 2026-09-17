#!/usr/bin/env bash
# tests/fm-watch-recovery-generation-scope.test.sh - a handling successor's
# suppression of its own predecessor-delivered wake (bin/fm-watch.sh's
# resurface_after_downtime) must be scoped to the exact recovery generation
# open at handoff, never to every future generation for the life of that
# watcher process.
#
# Before this fix, FM_WATCH_HANDLING_SUCCESSOR=1 suppressed
# resurface_after_downtime unconditionally for as long as that one watch.sh
# process stayed the singleton holder. A still-running successor that had
# already acknowledged the handoff it was born for would then silently
# swallow every later, unrelated downtime episode - including one minted by
# an external fm_wake_append call from a completely different task - because
# the marker's generation was never compared to the one the successor was
# actually launched to shepherd. These are real-process tests, matching
# tests/fm-watch-arm.test.sh's fixtures: a real bin/fm-watch-arm.sh launches a
# real bin/fm-watch.sh successor, and real fm_wake_append calls drive the
# recovery marker exactly as production does.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-generation-scope)

# Background starters and helpers below run in THIS shell (never through a
# command/process substitution, which would fork a subshell and drop any pid
# they capture), so each communicates through a plain global instead of a
# return value: ARM_PID names the live arm, HANDOFF_GENERATION and
# HANDOFF_WATCHER_PID name the successor's originating recovery episode.
ARM_PID=
HANDOFF_GENERATION=
HANDOFF_WATCHER_PID=

start_rearm_arm() {  # <home> <state> <fakebin> <arm-out> [predecessor-arm-pid]
  local home=$1 state=$2 fakebin=$3 armout=$4 predecessor=${5:-} i
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_PREDECESSOR_ARM_PID="$predecessor" \
    "$WATCH_ARM" --restart > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -q '^watcher: started ' "$armout" 2>/dev/null && return 0
    is_live_non_zombie "$ARM_PID" || return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 0
}

ack_wakes() {  # <state>
  local state=$1 sequence generation err
  err="$state/.test-ack.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  if [ -z "$sequence" ] || [ -z "$generation" ]; then
    [ ! -s "$state/.wake-queue" ] || return 1
    case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in pending:*|announced:*) return 1 ;; esac
    return 0
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Establish one real crash-gap recovery episode and hand it to a real
# handling successor, exactly as tests/fm-watch-arm.test.sh's
# test_interrupted_handling_is_redrained_on_rearm does: a fixture watcher
# delivers a wake and dies before handling drains it, a bare re-arm surfaces
# the durable recovery, and a --handling-delivered successor takes over
# without re-announcing. Leaves the successor's arm running (ARM_PID) and
# sets HANDOFF_GENERATION/HANDOFF_WATCHER_PID to the episode it was launched
# to shepherd; its own arm output is "$dir/handoff-arm.out".
seed_handling_successor() {  # <dir> <home> <state> <fakebin> <status-key>
  local dir=$1 home=$2 state=$3 fakebin=$4 key=$5
  local first_arm

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/first-arm.out"
  first_arm=$ARM_PID
  is_live_non_zombie "$first_arm" || fail "fixture watcher did not stay live"
  printf 'done: %s wake\n' "$key" > "$state/$key.status"
  wait_for_exit "$first_arm" 120 || fail "fixture watcher did not deliver its status wake"

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/crash-gap-arm.out"
  wait_for_exit "$ARM_PID" 80 || fail "re-arm after fixture crash did not resolve"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "fixture crash-gap left no open recovery episode" ;;
  esac

  start_rearm_arm "$home" "$state" "$fakebin" "$dir/handoff-arm.out" "$ARM_PID"
  is_live_non_zombie "$ARM_PID" \
    || fail "expected handling successor to loop on the pending durable wake"
  HANDOFF_GENERATION=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$HANDOFF_GENERATION" ] || fail "handoff left no recovery generation"
  HANDOFF_WATCHER_PID=$(sed -n 's/^watcher: started pid=\([0-9][0-9]*\).* recovery-generation=.*$/\1/p' "$dir/handoff-arm.out")
  [ -n "$HANDOFF_WATCHER_PID" ] || fail "handoff did not report a successor watcher pid"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$WATCH_ARM" --handling-delivered "$HANDOFF_GENERATION" \
    --watcher-pid "$HANDOFF_WATCHER_PID" \
    || fail "confirmed prompt delivery did not begin handling"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    pending:handling:"$HANDOFF_GENERATION"|announced:handling:"$HANDOFF_GENERATION") ;;
    *) fail "confirmed prompt delivery did not transition its recovery generation" ;;
  esac
}

# T1 + replacement/Pi delivery confirmation: a handling successor must not
# re-announce the exact generation it was launched to shepherd, before or
# after the --handling-delivered confirmation transitions it into "handling".
test_original_generation_is_suppressed_at_handoff() {
  local dir home state fakebin
  dir=$(make_case original-generation-suppressed)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  seed_handling_successor "$dir" "$home" "$state" "$fakebin" original

  ! grep -F 'check: rearm-resurface' "$dir/handoff-arm.out" >/dev/null \
    || fail "handling successor re-announced its own originating generation: $(cat "$dir/handoff-arm.out")"
  is_live_non_zombie "$ARM_PID" \
    || fail "handling successor exited instead of supervising after delivery confirmation"

  kill -TERM "$ARM_PID" 2>/dev/null || true
  wait "$ARM_PID" 2>/dev/null || true
  pass "handling successor suppresses only the exact generation it was launched to shepherd"
}

# T2: the exact running-successor plus external-fm_wake_append scenario. Once
# the originating generation is acknowledged (as a routine drain would do
# after the model handles it), a wake appended by a completely different
# task must mint a new, distinct generation and this SAME still-running
# successor - never restarted - must resurface it instead of staying blind.
test_external_wake_append_flows_through_running_successor() {
  local dir home state fakebin original_generation original_watcher_pid new_generation
  dir=$(make_case running-successor-external-append)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  seed_handling_successor "$dir" "$home" "$state" "$fakebin" runner
  original_generation=$HANDOFF_GENERATION
  original_watcher_pid=$HANDOFF_WATCHER_PID
  is_live_non_zombie "$ARM_PID" || fail "handling successor did not stay live before drain"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/handling-drain.out" \
    2> "$dir/handling-drain.err" || fail "handling drain did not expose the durable wake"
  ack_wakes "$state" || fail "could not acknowledge the originating generation"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) fail "originating generation was not retired by acknowledgement" ;;
  esac
  is_live_non_zombie "$ARM_PID" \
    || fail "the running successor must still be alive after its own generation is acked"
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$original_watcher_pid" ] \
    || fail "the same successor watcher must still hold the lock (never restarted)"

  # An external task appends a completely unrelated wake through the real
  # production path while this exact successor keeps running.
  append_wake "$state" signal unrelated.status 'signal: an unrelated later crew event' \
    || fail "external fm_wake_append failed"
  new_generation=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$new_generation" ] && [ "$new_generation" != "$original_generation" ] \
    || fail "external append did not mint a distinct recovery generation: $new_generation vs $original_generation"

  wait_for_exit "$ARM_PID" 80 \
    || fail "the still-running successor did not resurface the later, unrelated generation"
  grep -F 'check: rearm-resurface' "$dir/handoff-arm.out" >/dev/null \
    || fail "the still-running successor went blind on a later, unrelated generation: $(cat "$dir/handoff-arm.out")"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/later-drain.out" \
    2> "$dir/later-drain.err" || fail "later-generation drain failed"
  grep "$(printf '\tsignal\tunrelated.status\t')" "$dir/later-drain.out" >/dev/null \
    || fail "the later, unrelated wake was not presented by the drain"
  ack_wakes "$state" || fail "could not acknowledge the later, unrelated generation"
  pass "a later, unrelated recovery generation flows through a still-running handling successor"
}

# T3: multiple independent later generations, each minted while the fleet
# keeps handing off to fresh handling successors, must each resurface on
# their own - the scoped suppression must never accumulate or wedge open.
test_multiple_later_generations_each_resurface() {
  local dir home state fakebin original_generation gen2 gen3
  dir=$(make_case multiple-later-generations)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  seed_handling_successor "$dir" "$home" "$state" "$fakebin" multi
  original_generation=$HANDOFF_GENERATION
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "first handling drain failed"
  ack_wakes "$state" || fail "could not acknowledge the first generation"

  append_wake "$state" signal second.status 'signal: second unrelated crew event' \
    || fail "second external fm_wake_append failed"
  gen2=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$gen2" ] && [ "$gen2" != "$original_generation" ] \
    || fail "second append did not mint a distinct generation"
  wait_for_exit "$ARM_PID" 80 || fail "successor did not resurface the second generation"
  grep -F 'check: rearm-resurface' "$dir/handoff-arm.out" >/dev/null \
    || fail "successor went blind on the second generation"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "second-generation drain failed"
  ack_wakes "$state" || fail "could not acknowledge the second generation"

  # A fresh handling successor for a third, independent handoff must repeat
  # the same scoped behavior rather than inheriting or reusing prior state.
  start_rearm_arm "$home" "$state" "$fakebin" "$dir/third-handoff.out" "$ARM_PID"
  is_live_non_zombie "$ARM_PID" || fail "third handling successor did not take the lock"
  ! grep -F 'check: rearm-resurface' "$dir/third-handoff.out" >/dev/null \
    || fail "third handling successor re-announced a generation it never owned"

  append_wake "$state" signal third.status 'signal: third unrelated crew event' \
    || fail "third external fm_wake_append failed"
  gen3=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$gen3" ] && [ "$gen3" != "$gen2" ] \
    || fail "third append did not mint a distinct generation"
  wait_for_exit "$ARM_PID" 80 || fail "third successor did not resurface its later generation"
  grep -F 'check: rearm-resurface' "$dir/third-handoff.out" >/dev/null \
    || fail "third successor went blind on its own later generation"

  pass "each later, independent recovery generation resurfaces on its own"
}

# T4: duplicate prevention - while one episode is still open (unacked), a
# second append from another source must reuse its generation rather than
# fragmenting into a second, redundant recovery episode. This is the
# existing once-per-generation contract the scoped fix must not weaken.
test_repeated_append_reuses_the_open_generation() {
  local dir state gen_first gen_second
  dir=$(make_case duplicate-generation-prevention)
  state="$dir/state"
  mkdir -p "$state"

  append_wake "$state" check first-source 'check: first source' \
    || fail "first append failed"
  gen_first=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$gen_first" ] || fail "first append minted no recovery generation"

  append_wake "$state" check second-source 'check: second source' \
    || fail "second append failed"
  gen_second=$(recovery_marker_generation "$state/.watcher-down")
  [ "$gen_second" = "$gen_first" ] \
    || fail "a second append while the episode was still open minted a duplicate generation: $gen_first vs $gen_second"

  pass "an append against a still-open episode reuses its generation instead of duplicating it"
}

# T5: durable acknowledgement still retires a later, independently-minted
# generation exactly as it retires the original one - the scoped fix must not
# disturb the generation-bound acknowledgement contract.
test_durable_acknowledgement_retires_the_later_generation() {
  local dir home state fakebin original_generation new_generation
  dir=$(make_case durable-ack-later-generation)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"

  seed_handling_successor "$dir" "$home" "$state" "$fakebin" ackcase
  original_generation=$HANDOFF_GENERATION
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "first handling drain failed"
  ack_wakes "$state" || fail "could not acknowledge the originating generation"

  append_wake "$state" signal ack-later.status 'signal: later crew event for ack coverage' \
    || fail "external fm_wake_append failed"
  new_generation=$(recovery_marker_generation "$state/.watcher-down")
  [ -n "$new_generation" ] && [ "$new_generation" != "$original_generation" ] \
    || fail "append did not mint a distinct generation"
  wait_for_exit "$ARM_PID" 80 || fail "successor did not resurface the later generation"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/ack-drain.out" \
    2> "$dir/ack-drain.err" || fail "later-generation drain failed"
  ack_wakes "$state" || fail "could not acknowledge the later generation"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged later generation left rows in the durable queue"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*"$new_generation") ;;
    *) fail "later generation was not retired by its generation-bound acknowledgement" ;;
  esac
  pass "generation-bound acknowledgement retires a later, independently-minted episode"
}

test_original_generation_is_suppressed_at_handoff
test_external_wake_append_flows_through_running_successor
test_multiple_later_generations_each_resurface
test_repeated_append_reuses_the_open_generation
test_durable_acknowledgement_retires_the_later_generation
