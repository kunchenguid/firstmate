#!/usr/bin/env bash
# tests/fm-watch-secondmate-wake-stall.test.sh - the secondmate wake-loop stall
# rung (bin/fm-watch.sh secondmate_wake_stall_tick) must not be satisfiable by
# the ordinary behaviour it detects.
#
# A mate drains its own wake queue at TURN START only, so any single turn longer
# than SECONDMATE_WAKE_STALL_SECS (a build, a test sweep, a review, a merge)
# leaves an aged foreign row behind while the mate is provably mid-turn. The rung
# therefore stays silent on a POSITIVE busy read of the mate's own endpoint and
# reports otherwise, so a mate that cannot be proven busy is never silently
# exempted.
#
# Every fixture here is built by running the REAL bin/fm-spawn.sh --secondmate,
# so the busy record exists because production creates it. No test hand-writes
# state/<mate>.busy-state or .busy-gen, and no test seeds a record the spawn
# would not have armed: a fixture that manufactured the record would only prove
# the assumption it was built on.
#
# Each case is wired through exactly one gate so a regression in that gate alone
# fails it:
#   real spawn, busy record   -> silent, and no marker/receipt side effect
#   real spawn, idle event    -> reports with the unchanged reason text
#   real spawn, capture fails -> silent (the semantic record still proves busy)
#   grok, capture fails        -> still reports (no positive read is possible)
#   grok rendered busy footer -> silent (the rendered fallback still suppresses)
#
# Residual gap, stated plainly: grok and rovo classify from their rendered tail,
# and muse and cursor fold their own durable session logs, so those can still
# prove a busy turn; a harness with no semantic or pull source (codex, standalone
# kimi) arms no record and classifies unknown, so its mate is reported. That is
# the honest "cannot be proven" case, not a silent exemption.
#
# Fixtures are driven through bin/fm-watch-checkpoint.sh, the same foreground
# checkpoint harness its neighbours (fm-wake-queue.test.sh) use, with a fake
# tmux that owns the pane bytes. Nothing here is timing-sensitive beyond a
# generous checkpoint window: the age threshold is 1s and the seeded row is 10s
# old, so the rung's own age gate is never the thing under test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-secondmate-wake-stall)

# make_spawned_mate <name> <pane-file> <capture-fails> [harness]
# Runs the real secondmate spawn, then seeds one aged foreign row in the mate's
# own queue - exactly what that queue looks like while the mate is mid-turn on
# it. Echoes the case dir; the parent home is <dir>/home and the mate home is
# <dir>/mate.
make_spawned_mate() {  # <name> <pane-file> <capture-fails> [harness]
  local name=$1 pane=$2 fails=$3 harness=${4:-pi} dir home mate fakebin spawnbin out
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  mate="$dir/mate"
  fakebin="$dir/fakebin"
  spawnbin="$dir/spawnfake"
  mkdir -p "$dir" "$mate/data" "$mate/state" "$mate/config" "$mate/projects" \
    "$mate/bin" "$fakebin"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf '# Charter\n' > "$mate/data/charter.md"
  fm_test_spawn_home "$home" "$harness"
  spawnbin=$(make_spawn_fakebin "$spawnbin" pi)
  out=$(GROK_HOME="$dir/grok-home" \
    fm_test_run_spawn "$home" "$pane" "$spawnbin" mate "$mate" \
    --secondmate --harness "$harness" 2>&1) \
    || fail "the real secondmate spawn failed: $out"
  case "$out" in
    *"spawned mate"*) ;;
    *) fail "the real secondmate spawn did not report success: $out" ;;
  esac
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" \
    > "$mate/state/.wake-queue"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-mate' ;;
  capture-pane)
    [ "$fails" = 1 ] && exit 1
    cat "$pane"
    ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$dir"
}

# run_stall_checkpoint <dir> <seconds> <out-file>: one bounded watcher cycle.
run_stall_checkpoint() {  # <dir> <seconds> <out>
  local dir=$1 seconds=$2 out=$3
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_SECONDMATE_WAKE_STALL_SECS=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds "$seconds" > "$out" 2> "$dir/watch.err" || true
}

# The reported production defect: a mate provably mid-turn on an aged row. The
# busy record is the one the real spawn armed, so this case fails if the spawn
# stops arming it AND if the rung stops reading it.
test_busy_mate_from_real_spawn_stays_silent() {
  local dir state out
  dir=$(make_spawned_mate busy-mate "$TMP_ROOT/busy-pane.txt" 0)
  state="$dir/home/state"
  out="$dir/watch.out"
  printf 'Working... (279k context)\n' > "$TMP_ROOT/busy-pane.txt"

  [ -s "$state/mate.busy-state" ] \
    || fail "the real secondmate spawn armed no busy record, so the rung has nothing to read"
  grep -F 'state=busy' "$state/mate.busy-state" >/dev/null \
    || fail "the real secondmate spawn did not seed a busy record: $(cat "$state/mate.busy-state")"

  run_stall_checkpoint "$dir" 6 "$out"

  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "a provably busy mate reported a wake-loop stall: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a provably busy mate still published a durable parent notification"
  [ ! -e "$state/.secondmate-wake-stall-mate" ] \
    || fail "a suppressed busy row still wrote the marker that hides a later real stall"
  [ ! -e "$state/.secondmate-wake-stall-receipts/mate" ] \
    || fail "a suppressed busy row still wrote a stall receipt"
  pass "a busy mate from a real spawn stays silent with no side effect"
}

# An idle mate on an aged row is a genuine stall and keeps the exact reason text,
# marker, receipt, and durable publication it has today. The idle event goes
# through the real writer against the gen the real spawn minted.
test_idle_mate_from_real_spawn_reports() {
  local dir state out gen
  dir=$(make_spawned_mate idle-mate "$TMP_ROOT/idle-pane.txt" 0)
  state="$dir/home/state"
  out="$dir/watch.out"
  printf 'Idle\n' > "$TMP_ROOT/idle-pane.txt"
  gen=$(cat "$state/mate.busy-gen" 2>/dev/null || true)
  [ -n "$gen" ] || fail "the real secondmate spawn minted no busy gen"
  "$BUSY_EVENT" apply "$state" mate idle --gen "$gen" --source pi-ext --event agent-settled \
    || fail "applying the idle verdict failed"

  run_stall_checkpoint "$dir" 8 "$out"

  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 age=' "$out" >/dev/null \
    || fail "an idle mate's aged row did not report: $(cat "$out"); err=$(cat "$dir/watch.err")"
  grep -E 'check: secondmate wake-loop stalled: mate=mate row=7 age=[0-9]+s$' "$out" >/dev/null \
    || fail "the reported reason text changed shape: $(cat "$out")"
  [ -s "$state/.wake-queue" ] || fail "the idle mate's stall was not published durably"
  [ -e "$state/.secondmate-wake-stall-mate" ] \
    || fail "the idle mate's stall wrote no marker, so it would repeat every poll"
  pass "an idle mate's aged row reports with the unchanged reason, marker, and publication"
}

# A semantic busy record is positive proof of a turn in flight and does not
# depend on the rendered pane, so a transient capture failure must not turn a
# provably busy mate into a reported stall.
test_capture_failure_does_not_override_semantic_busy() {
  local dir state out
  dir=$(make_spawned_mate capture-failure "$TMP_ROOT/unreadable-pane.txt" 1)
  state="$dir/home/state"
  out="$dir/watch.out"

  [ -s "$state/mate.busy-state" ] \
    || fail "the real secondmate spawn armed no busy record"

  run_stall_checkpoint "$dir" 8 "$out"

  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "a failed pane capture overrode a provably busy mate: $(cat "$out"); err=$(cat "$dir/watch.err")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a failed pane capture published a false stall for a busy mate"
  pass "a failed pane capture does not override a semantic busy record"
}

# A grok mate has no semantic record, so its only positive read is the rendered
# tail. When the capture itself fails there is no positive read, and the rung
# must still report rather than silently exempt the mate.
test_grok_capture_failure_still_reports() {
  local dir state out
  dir=$(make_spawned_mate grok-capture-failure "$TMP_ROOT/grok-unreadable-pane.txt" 1 grok)
  state="$dir/home/state"
  out="$dir/watch.out"

  run_stall_checkpoint "$dir" 8 "$out"

  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 age=' "$out" >/dev/null \
    || fail "a grok mate with no readable pane was silently exempted: $(cat "$out"); err=$(cat "$dir/watch.err")"
  [ -s "$state/.wake-queue" ] \
    || fail "a grok mate with no readable pane published no durable notification"
  pass "a grok capture failure still reports the stall"
}

# The residual gap, pinned so it cannot be forgotten: a grok mate arms no
# semantic record, so the busy lib falls back to its rendered tail. A tail
# carrying the verified busy footer is a positive read and the rung stays
# silent; a tail without it cannot be proven working, so the rung still reports.
# That second half is the honest "cannot be proven" case, not a silent
# exemption - it is the behaviour the captain's ruling requires.
test_grok_rendered_tail_decides_the_rung() {
  local dir state out
  dir=$(make_spawned_mate grok-busy "$TMP_ROOT/grok-pane.txt" 0 grok)
  state="$dir/home/state"
  out="$dir/watch.out"
  # grok's verified busy footer (bin/fm-busy-lib.sh fm_busy_grok_tail_busy).
  printf 'Working... (279k context)\n  Ctrl+c:cancel\n' > "$TMP_ROOT/grok-pane.txt"

  run_stall_checkpoint "$dir" 6 "$out"

  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "a grok mate showing a busy footer reported a false wake-loop stall: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a grok mate showing a busy footer still published a durable notification"
  [ ! -e "$state/.secondmate-wake-stall-mate" ] \
    || fail "a grok mate showing a busy footer still wrote the stall marker"

  # Same mate, same aged row, footer scrolled out of the tail: unprovable, so
  # the rung must still report rather than exempt the mate silently.
  printf 'Working... (279k context)\n' > "$TMP_ROOT/grok-pane.txt"
  run_stall_checkpoint "$dir" 8 "$out"

  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 age=' "$out" >/dev/null \
    || fail "a grok mate with no busy footer was silently exempted: $(cat "$out")"
  pass "a grok mate's rendered tail decides the rung: busy footer silent, unprovable reports"
}

# A valid busy record proves nothing once the mate's endpoint is gone. The live
# classifier checks the endpoint before the record, so a killed harness that
# left its busy record behind can never silence the rung forever.
test_endpoint_gone_does_not_suppress_a_busy_record() {
  local dir state out
  dir=$(make_spawned_mate endpoint-gone "$TMP_ROOT/gone-pane.txt" 0)
  state="$dir/home/state"
  out="$dir/watch.out"
  printf 'Working... (279k context)\n' > "$TMP_ROOT/gone-pane.txt"

  [ -s "$state/mate.busy-state" ] \
    || fail "the real secondmate spawn armed no busy record"
  grep -F 'state=busy' "$state/mate.busy-state" >/dev/null \
    || fail "the real secondmate spawn did not seed a busy record: $(cat "$state/mate.busy-state")"

  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) exit 1 ;;
  capture-pane) cat "$TMP_ROOT/gone-pane.txt" ;;
  display-message) exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"

  run_stall_checkpoint "$dir" 8 "$out"

  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7 age=' "$out" >/dev/null \
    || fail "a gone endpoint with a stale busy record silenced the rung: $(cat "$out"); err=$(cat "$dir/watch.err")"
  [ -s "$state/.wake-queue" ] \
    || fail "a gone endpoint with a stale busy record published no durable notification"
  pass "a gone endpoint does not suppress the rung even with a valid busy record"
}

test_busy_mate_from_real_spawn_stays_silent
test_idle_mate_from_real_spawn_reports
test_endpoint_gone_does_not_suppress_a_busy_record
test_capture_failure_does_not_override_semantic_busy
test_grok_capture_failure_still_reports
test_grok_rendered_tail_decides_the_rung

echo "# all fm-watch-secondmate-wake-stall tests passed"
