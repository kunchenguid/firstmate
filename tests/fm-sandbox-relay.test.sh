#!/usr/bin/env bash
# Behavior tests for bin/fm-sandbox-relay.sh: the host-side relay that applies a
# sandboxed omp worker's busy edges (the worker may write only
# its incarnation spool state/<id>.sbx/events.<gen>/, never state/).
#
# Load-bearing contracts:
#   1. A valid edge file produces the same busy-state record as a direct
#      fm-busy-event.sh apply, with the omp-ext source.
#   2. The gen is fixed host-side: a relay of a superseded incarnation cannot
#      move its replacement's record, and a gen inside the file is ignored.
#   3. A malformed, schema-violating, oversize, non-regular, or flooded event is
#      dropped and leaves the record unchanged; the spool never accumulates.
#   3b. One pass takes at most FM_SANDBOX_RELAY_PASS entries and leaves the rest
#      for the next poll, logs a flood once per pass, and never walks a tree.
#   4. `run` applies edges until the events directory disappears (teardown).
# Hermetic over temp dirs; no sandbox wrapper and no agent is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sandbox-relay)
EV="$ROOT/bin/fm-busy-event.sh"
RELAY="$ROOT/bin/fm-sandbox-relay.sh"

# new_case <name> <id>: arms a task, echoes "<state-dir> <gen>".
new_case() {
  local state="$TMP_ROOT/$1/state" gen
  mkdir -p "$state"
  gen=$("$EV" arm "$state" "$2") || fail "arm failed"
  mkdir -p "$state/$2.sbx/events" "$state/$2.sbx/inflight"
  printf '%s %s' "$state" "$gen"
}

record() {  # <state> <id> -> the busy record without volatile fields
  sed -e 's/ gen=[^ ]*//' -e 's/ ts=[0-9]*//' "$1/$2.busy-state"
}

relay_once() {  # <state> <id> <gen> [env assignments...]
  local state=$1 id=$2 gen=$3
  shift 3
  env "$@" "$RELAY" once --state "$state" --id "$id" --gen "$gen" --events "$state/$id.sbx/events"
}

spool_empty() {  # <state> <id>
  [ -z "$(find "$1/$2.sbx/events" -mindepth 1 -print -quit)" ]
}

test_valid_edge_matches_a_direct_apply() {
  local c state gen d_state d_gen
  c=$(new_case valid relay-v1)
  state=${c% *}
  gen=${c#* }
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$state/relay-v1.sbx/events/0000000000001-1-000000.json"
  relay_once "$state" relay-v1 "$gen" || fail "relay pass failed"
  d_state="$TMP_ROOT/valid/direct"
  mkdir -p "$d_state"
  d_gen=$("$EV" arm "$d_state" relay-d1) || fail "direct arm failed"
  "$EV" apply "$d_state" relay-d1 idle --gen "$d_gen" --source omp-ext --event agent-end || fail "direct apply failed"
  [ "$(record "$state" relay-v1 | sed 's/relay-v1//')" = "$(record "$d_state" relay-d1 | sed 's/relay-d1//')" ] \
    || fail "relayed record differs from a direct apply: $(record "$state" relay-v1) vs $(record "$d_state" relay-d1)"
  [ "$(fm_busy_classify tmux w omp relay-v1 "$state")" = "idle omp-ext" ] || fail "relayed idle edge must classify 'idle omp-ext'"
  spool_empty "$state" relay-v1 || fail "an applied edge must leave the spool empty"
  pass "relay: a valid edge file yields the same record as a direct fm-busy-event.sh apply"
}

test_edges_apply_in_write_order() {
  local c state gen
  c=$(new_case order relay-o1)
  state=${c% *}
  gen=${c#* }
  printf '%s' '{"state":"busy","event":"agent-start"}' >"$state/relay-o1.sbx/events/0000000000001-1-000000.json"
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$state/relay-o1.sbx/events/0000000000001-1-000001.json"
  relay_once "$state" relay-o1 "$gen" || fail "relay pass failed"
  [ "$(fm_busy_classify tmux w omp relay-o1 "$state")" = "idle omp-ext" ] || fail "the later edge must win"
  pass "relay: edges apply in sequence order"
}

test_superseded_incarnation_and_file_gen_are_ignored() {
  local c state gen before
  c=$(new_case stale relay-s1)
  state=${c% *}
  gen=${c#* }
  "$EV" arm "$state" relay-s1 >/dev/null || fail "re-arm failed"
  before=$(cat "$state/relay-s1.busy-state")
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$state/relay-s1.sbx/events/0000000000001-1-000000.json"
  relay_once "$state" relay-s1 "$gen" || fail "relay pass failed"
  [ "$(cat "$state/relay-s1.busy-state")" = "$before" ] || fail "a relay holding a superseded gen must not move the new incarnation's record"
  # The gen a file names is never read: forging the current gen in the file does
  # not help a relay that was started for an older incarnation.
  printf '{"state":"idle","event":"agent-end","gen":"%s"}' "$(cat "$state/relay-s1.busy-gen")" \
    >"$state/relay-s1.sbx/events/0000000000001-1-000001.json"
  relay_once "$state" relay-s1 "$gen" || fail "relay pass failed"
  [ "$(cat "$state/relay-s1.busy-state")" = "$before" ] || fail "a gen inside the file must be ignored"
  grep -q 'reason=refused' "$state/relay-s1.sbx/relay.log" || fail "a refused apply must be logged as refused"
  pass "relay: a superseded incarnation and a forged file gen leave the record unchanged"
}

test_bad_events_are_dropped_without_a_state_change() {
  local c state gen before i
  c=$(new_case bad relay-b1)
  state=${c% *}
  gen=${c#* }
  before=$(cat "$state/relay-b1.busy-state")
  e="$state/relay-b1.sbx/events"
  printf '%s' 'not json' >"$e/0000000000001-1-000000.json"
  printf '%s' '{"state":"sleeping","event":"agent-end"}' >"$e/0000000000001-1-000001.json"
  printf '%s' '{"state":"idle","event":"has space"}' >"$e/0000000000001-1-000002.json"
  printf '%s' '{"state":"idle","event":"a/b"}' >"$e/0000000000001-1-000003.json"
  printf '%s' '{"state":7,"event":"agent-end"}' >"$e/0000000000001-1-000004.json"
  printf '%s' '["idle","agent-end"]' >"$e/0000000000001-1-000005.json"
  printf '{"state":"idle","event":"%s"}' "$(printf 'a%.0s' $(seq 1 65))" >"$e/0000000000001-1-000006.json"
  printf '{"state":"idle","event":"agent-end","pad":"%s"}' "$(printf 'x%.0s' $(seq 1 600))" >"$e/0000000000001-1-000007.json"
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$e/stray.txt"
  mkdir "$e/0000000000001-1-000008.json"
  mkdir -p "$e/0000000000001-1-000009.json/deep"
  : >"$e/0000000000001-1-000009.json/deep/kept"
  relay_once "$state" relay-b1 "$gen" || fail "relay pass failed"
  [ "$(cat "$state/relay-b1.busy-state")" = "$before" ] || fail "a bad event moved the record: $(cat "$state/relay-b1.busy-state")"
  spool_empty "$state" relay-b1 || fail "dropped events must still be removed from the spool"
  for i in malformed oversize nonregular; do
    grep -q "reason=$i" "$state/relay-b1.sbx/relay.log" || fail "drop reason $i was not logged"
  done
  [ -n "$(find "$state/relay-b1.sbx/inflight" -name kept -print -quit)" ] \
    || fail "a worker-made tree must be moved out of the spool, never walked and deleted by the relay"
  pass "relay: malformed, oversize, schema-violating, and stray entries are dropped and the record is unchanged"
}

test_symlink_is_dropped_and_never_followed() {
  local c state gen before secret
  c=$(new_case link relay-l1)
  state=${c% *}
  gen=${c#* }
  before=$(cat "$state/relay-l1.busy-state")
  secret="$TMP_ROOT/link/target.json"
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$secret"
  ln -s "$secret" "$state/relay-l1.sbx/events/0000000000001-1-000000.json"
  relay_once "$state" relay-l1 "$gen" || fail "relay pass failed"
  [ "$(cat "$state/relay-l1.busy-state")" = "$before" ] || fail "a symlinked event must not be applied"
  [ -f "$secret" ] || fail "the relay must remove the link, never its target"
  spool_empty "$state" relay-l1 || fail "the link must be removed from the spool"
  pass "relay: a symlink is dropped without following it"
}

# The worker can rename a FIFO over its event file at any moment. A `head` shim
# plays that worker at the worst instant, just as the relay opens the file: it
# turns the spool entry of the same name into a FIFO first. A relay that reads
# the sandbox-writable path blocks on that FIFO forever; one that reads only a
# host-held copy applies the edge and finishes.
test_entry_swapped_after_the_check_cannot_block_the_relay() {
  local c state gen shim pid waited=0
  c=$(new_case swap relay-s1)
  state=${c% *}
  gen=${c#* }
  shim="$TMP_ROOT/swap/bin"
  mkdir -p "$shim"
  cat >"$shim/head" <<'SH'
#!/usr/bin/env bash
for last in "$@"; do :; done
t="$FM_TEST_SPOOL/${last##*/}"
if [ -f "$t" ]; then
  rm -f -- "$t"
  mkfifo "$t"
fi
exec "$FM_TEST_REAL_HEAD" "$@"
SH
  chmod +x "$shim/head"
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$state/relay-s1.sbx/events/0000000000001-1-000000.json"
  relay_once "$state" relay-s1 "$gen" PATH="$shim:$PATH" FM_TEST_SPOOL="$state/relay-s1.sbx/events" \
    FM_TEST_REAL_HEAD="$(command -v head)" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    : >"$state/relay-s1.sbx/events/0000000000001-1-000000.json" &
    wait "$pid"
    fail "the relay blocked on a FIFO swapped into the spool after its check"
  fi
  wait "$pid" || fail "relay pass failed"
  [ "$(fm_busy_classify tmux w omp relay-s1 "$state")" = "idle omp-ext" ] || fail "the held edge must still apply: $(cat "$state/relay-s1.busy-state")"
  spool_empty "$state" relay-s1 || fail "the spool must be empty after the pass"
  pass "relay: an entry swapped for a FIFO after the check cannot block the relay"
}

test_flood_is_bounded() {
  local c state gen i seq_before seq_after e started elapsed applied_edges left
  c=$(new_case flood relay-f1)
  state=${c% *}
  gen=${c#* }
  e="$state/relay-f1.sbx/events"
  seq_before=$(sed -n 's/.* seq=\([0-9]*\) .*/\1/p' "$state/relay-f1.busy-state")
  for i in $(seq 1 200); do
    printf '{"state":"%s","event":"agent-start"}' "$([ $((i % 2)) = 0 ] && echo idle || echo busy)" \
      >"$e/$(printf '0000000000001-1-%06d' "$i").json"
  done
  started=$(date +%s)
  relay_once "$state" relay-f1 "$gen" FM_SANDBOX_RELAY_RATE=2 FM_SANDBOX_RELAY_PASS=10 || fail "relay pass failed"
  elapsed=$(($(date +%s) - started))
  seq_after=$(sed -n 's/.* seq=\([0-9]*\) .*/\1/p' "$state/relay-f1.busy-state")
  applied_edges=$((seq_after - seq_before))
  [ "$applied_edges" -le $((2 * (elapsed + 1))) ] || fail "a flood applied $applied_edges edges in ${elapsed}s, the rate cap is 2 per second"
  [ "$applied_edges" -ge 1 ] || fail "the first edges of a flood must still apply"
  left=$(find "$e" -mindepth 1 | wc -l | tr -d ' ')
  [ "$left" = 190 ] || fail "one pass must take exactly the 10-entry budget and leave 190 for the next poll, left $left"
  [ -e "$e/0000000000001-1-000011.json" ] && [ ! -e "$e/0000000000001-1-000010.json" ] \
    || fail "a pass must take the oldest entries first"
  [ "$(grep -c 'reason=flood' "$state/relay-f1.sbx/relay.log")" = 1 ] || fail "a pass must log its flood drops as one line"
  grep -q "reason=flood count=$((10 - applied_edges))" "$state/relay-f1.sbx/relay.log" \
    || fail "the flood line must count every rate-capped drop of the pass: $(cat "$state/relay-f1.sbx/relay.log")"
  for i in $(seq 1 19); do
    relay_once "$state" relay-f1 "$gen" FM_SANDBOX_RELAY_RATE=2 FM_SANDBOX_RELAY_PASS=10 || fail "relay pass failed"
  done
  spool_empty "$state" relay-f1 || fail "later polls must drain the spool"
  pass "relay: a flood costs one bounded pass per poll, is logged once per pass, and the spool drains"
}

test_run_applies_edges_and_ends_with_the_spool() {
  local c state gen pid i cls
  c=$(new_case run relay-r1)
  state=${c% *}
  gen=${c#* }
  "$RELAY" run --state "$state" --id relay-r1 --gen "$gen" --events "$state/relay-r1.sbx/events" --interval 0.05 &
  pid=$!
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$state/relay-r1.sbx/events/.tmp"
  mv "$state/relay-r1.sbx/events/.tmp" "$state/relay-r1.sbx/events/0000000000001-1-000000.json"
  for i in $(seq 1 100); do
    cls=$(fm_busy_classify tmux w omp relay-r1 "$state")
    [ "$cls" = "idle omp-ext" ] && break
    sleep 0.1
  done
  [ "$cls" = "idle omp-ext" ] || { kill "$pid" 2>/dev/null; fail "run did not apply the edge: '$cls'"; }
  rm -rf "$state/relay-r1.sbx"
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    fail "run must end once the events directory is removed (teardown)"
  fi
  wait "$pid" 2>/dev/null
  pass "relay: run applies a file written while it polls and ends when teardown removes the spool"
}

test_run_ends_when_the_task_is_rearmed() {
  local c state gen pid i
  c=$(new_case rearm relay-a1)
  state=${c% *}
  gen=${c#* }
  "$RELAY" run --state "$state" --id relay-a1 --gen "$gen" --events "$state/relay-a1.sbx/events" --interval 0.05 &
  pid=$!
  "$EV" arm "$state" relay-a1 >/dev/null || fail "re-arm failed"
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    fail "a relay of a superseded incarnation must end by itself"
  fi
  wait "$pid" 2>/dev/null
  pass "relay: a relay whose incarnation was re-armed ends by itself"
}

test_term_applies_the_final_edge_before_exit() {
  local c state gen pid i
  c=$(new_case term relay-t1)
  state=${c% *}
  gen=${c#* }
  # A long poll interval: the edge below is written, and the wrapper's TERM
  # arrives, before any poll would have seen it.
  "$RELAY" run --state "$state" --id relay-t1 --gen "$gen" --events "$state/relay-t1.sbx/events" --interval 30 &
  pid=$!
  sleep 0.5
  printf '%s' '{"state":"idle","event":"agent-end"}' >"$state/relay-t1.sbx/events/0000000000001-1-000000.json"
  kill -TERM "$pid"
  for i in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    fail "the relay must end promptly on TERM even mid-poll"
  fi
  wait "$pid" 2>/dev/null
  [ "$(fm_busy_classify tmux w omp relay-t1 "$state")" = "idle omp-ext" ] || fail "the final edge must be applied before the relay exits"
  pass "relay: TERM drains the final edge, then ends"
}

test_valid_edge_matches_a_direct_apply
test_edges_apply_in_write_order
test_superseded_incarnation_and_file_gen_are_ignored
test_bad_events_are_dropped_without_a_state_change
test_symlink_is_dropped_and_never_followed
test_entry_swapped_after_the_check_cannot_block_the_relay
test_flood_is_bounded
test_run_applies_edges_and_ends_with_the_spool
test_run_ends_when_the_task_is_rearmed
test_term_applies_the_final_edge_before_exit

echo "all fm-sandbox-relay tests passed"
