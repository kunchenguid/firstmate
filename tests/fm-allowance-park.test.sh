#!/usr/bin/env bash
# tests/fm-allowance-park.test.sh - detection of a worker parked on the ACCOUNT
# allowance (bin/fm-allowance-lib.sh) and the two callers that act on it:
# bin/fm-watch.sh, which must surface the park as a named wake, and
# bin/fm-crew-state.sh, which must report it as the crew's current state.
#
# The defect these pin: a refused turn leaves the process alive, the endpoint
# alive, and the pane rendering normally, so every liveness probe firstmate owns
# reads healthy and nothing fires. On 2026-08-17 two crewmates parked seconds
# after launch and were found hours after their reset had already passed, by a
# wedge alarm that had nothing to do with the cause.
#
# The verdict is harness-dependent - both signals come from something the vendor
# emits - so this portable half pins the classifier logic with no harness
# installed, and the opt-in live half in
# tests/fm-allowance-park-live-e2e.test.sh proves the transcript store is still
# where firstmate looks for a REAL worker. Neither replaces the other: a stub can
# only confirm the assumption already written into the stub, and a live guard
# cannot run in CI.
#
# Both signals are driven apart deliberately in the cases below, because a
# two-signal check whose signals are never separated is indistinguishable from a
# one-signal check: each case that asserts the verdict survives losing a signal
# first asserts that the signal really is absent.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-allowance-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-allowance-park-tests)

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# The rendered notice exactly as the 2026-08-17 incident's panes carried it,
# including the resume affordance that never reaches the transcript.
PARKED_PANE_LINE="You've hit your session limit · resets 8:30am (UTC) · Press Enter to continue after reset"

# write_transcript <file> <cwd> <parked|resumed>
# A Claude Code session transcript whose LAST conversational record is either the
# refusal itself (parked) or an ordinary reply that landed after it (resumed).
# The refusal record carries the vendor's own machine-readable error fields; the
# trailing non-conversational record is there because a real transcript has one,
# and the fold must skip it rather than stop at it.
write_transcript() {  # <file> <cwd> <mode>
  local file=$1 cwd=$2 mode=$3
  {
    printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"go"}}\n' "$cwd"
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}\n' "$cwd"
    printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 8:30am (UTC)"}]},"error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429}\n' "$cwd"
    if [ "$mode" = resumed ]; then
      printf '{"type":"assistant","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"resumed after the reset"}]}}\n' "$cwd"
    fi
    printf '{"type":"last-prompt","lastPrompt":"go"}\n'
  } > "$file"
}

# make_store <dir> <worktree> <parked|resumed|none>
# A CLAUDE_CONFIG_DIR-shaped transcript store for <worktree>, using the same
# directory mangling Claude Code derives from the session's working directory.
# "none" builds the store with no transcript in it at all, which is how a case
# takes the structural signal away without also taking the store away.
make_store() {  # <dir> <worktree> <mode>
  local base=$1 wt=$2 mode=$3 mangled dir
  mangled=$(printf '%s' "$wt" | tr '/.' '--')
  dir="$base/projects/$mangled"
  mkdir -p "$dir"
  [ "$mode" = none ] || write_transcript "$dir/session.jsonl" "$wt" "$mode"
  printf '%s\n' "$dir"
}

# --- the verdict itself ------------------------------------------------------

test_pane_signal_reads_the_rendered_notice() {
  local dir out
  dir="$TMP_ROOT/pane-signal"; mkdir -p "$dir"
  out=$(printf 'building the thing\n%s\n' "$PARKED_PANE_LINE" | fm_allowance_pane_parked claude) \
    || fail "the rendered limit notice was not read as a park"
  case "$out" in
    *"hit your session limit"*) ;;
    *) fail "the pane verdict did not carry the notice: $out" ;;
  esac
  # An ordinary working pane, including one whose footer talks about limits in
  # passing, must not park: this check may only ever ADD a wake, and a false
  # positive here is a second source of false wedge alarms.
  ! printf 'Running tests (esc to interrupt)\ncontext left until auto-compact: 31%%\n' \
    | fm_allowance_pane_parked claude \
    || fail "ordinary working output was read as parked"
  ! printf 'ok\n' | fm_allowance_pane_parked claude \
    || fail "an unremarkable pane was read as parked"
  pass "the pane signal reads the rendered notice and leaves ordinary output alone"
}

test_pane_signal_is_bounded_to_the_prompt_region() {
  local i body=''
  # The same notice quoted in DISPLAYED CONTENT - a file being read, a grep hit,
  # this very test - scrolls out of the region a harness redraws around its own
  # prompt. Without the bound, any worker that so much as greps for the string
  # parks itself.
  body="$PARKED_PANE_LINE"$'\n'
  for i in $(seq 1 "$((FM_ALLOWANCE_PANE_TAIL_LINES + 5))"); do
    body="$body""line $i of ordinary output"$'\n'
  done
  ! printf '%s' "$body" | fm_allowance_pane_parked claude \
    || fail "a limit notice scrolled far above the prompt still matched"
  pass "the pane signal is bounded to the tail, so quoted content cannot park a worker"
}

test_record_signal_is_current_state_not_history() {
  local dir wt out
  dir="$TMP_ROOT/record-signal"; wt="$dir/wt"; mkdir -p "$wt"
  write_transcript "$dir/parked.jsonl" "$wt" parked
  write_transcript "$dir/resumed.jsonl" "$wt" resumed
  out=$(_fm_allowance_record_parked "$dir/parked.jsonl") \
    || fail "a transcript ending on the refusal was not read as parked"
  case "$out" in
    *"hit your session limit"*) ;;
    *) fail "the record verdict did not carry the notice: $out" ;;
  esac
  # The same refusal, with the worker back at work after it. Reading the file for
  # the refusal ANYWHERE would report this one parked forever.
  ! _fm_allowance_record_parked "$dir/resumed.jsonl" \
    || fail "a transcript that resumed after its refusal was still read as parked"
  pass "the record signal reports the last conversational record, not any refusal in history"
}

test_unsupported_harness_never_parks() {
  local dir wt store
  dir="$TMP_ROOT/unsupported"; wt="$dir/wt"; mkdir -p "$wt"
  store=$(make_store "$dir/store" "$wt" parked)
  [ -f "$store/session.jsonl" ] || fail "fixture store was not built"
  # Per-harness support is a gate, not a default. An adapter with no verified
  # signature must behave exactly as it did before this check existed, even when
  # a transcript and a pane are sitting right there saying "parked".
  ! CLAUDE_CONFIG_DIR="$dir/store" fm_allowance_park_detail codex "$wt" "$PARKED_PANE_LINE" \
    || fail "an unverified harness parked on another harness's signature"
  ! CLAUDE_CONFIG_DIR="$dir/store" fm_allowance_park_detail '' "$wt" "$PARKED_PANE_LINE" \
    || fail "a task with no recorded harness parked"
  pass "a harness with no verified signature never parks"
}

test_either_signal_alone_carries_the_verdict() {
  local dir wt store out
  dir="$TMP_ROOT/divergence"; wt="$dir/wt"; mkdir -p "$wt"

  # Signal A alone: the transcript records the refusal, the pane shows ordinary
  # work. First prove the pane really is silent, so the surviving verdict cannot
  # be the pane's.
  store=$(make_store "$dir/record-only" "$wt" parked)
  [ -f "$store/session.jsonl" ] || fail "record-only fixture has no transcript"
  ! printf 'Running tests (esc to interrupt)\n' | fm_allowance_pane_parked claude \
    || fail "the record-only case's pane was not actually silent"
  out=$(CLAUDE_CONFIG_DIR="$dir/record-only" fm_allowance_park_detail claude "$wt" 'Running tests (esc to interrupt)') \
    || fail "the transcript signal alone did not carry the verdict"
  case "$out" in
    "session-record "*) ;;
    *) fail "expected the structural source to be named, got: $out" ;;
  esac

  # Signal B alone: the store holds no transcript, the pane shows the notice.
  # First prove the transcript really is missing, so the surviving verdict cannot
  # be the transcript's.
  make_store "$dir/pane-only" "$wt" none >/dev/null
  ! CLAUDE_CONFIG_DIR="$dir/pane-only" fm_allowance_record_parked claude "$wt" \
    || fail "the pane-only case still had a usable transcript"
  out=$(CLAUDE_CONFIG_DIR="$dir/pane-only" fm_allowance_park_detail claude "$wt" "$PARKED_PANE_LINE") \
    || fail "the pane signal alone did not carry the verdict"
  case "$out" in
    "pane "*) ;;
    *) fail "expected the rendered source to be named, got: $out" ;;
  esac

  # Neither signal: not parked, and the store exists so this is a real negative
  # rather than a missing fixture.
  ! CLAUDE_CONFIG_DIR="$dir/pane-only" fm_allowance_park_detail claude "$wt" 'Running tests (esc to interrupt)' \
    || fail "a worker with neither signal was read as parked"
  pass "either signal alone carries the verdict, and losing both clears it"
}

test_transcript_must_belong_to_this_worktree() {
  local dir wt other store
  dir="$TMP_ROOT/wrong-worktree"; wt="$dir/wt"; other="$dir/other"; mkdir -p "$wt" "$other"
  store=$(make_store "$dir/store" "$wt" none)
  # A transcript sitting in this worktree's store but recording a DIFFERENT
  # working directory is not evidence about this worker.
  write_transcript "$store/session.jsonl" "$other" parked
  ! CLAUDE_CONFIG_DIR="$dir/store" fm_allowance_record_parked claude "$wt" \
    || fail "a transcript recording another worktree was trusted"
  pass "a transcript is trusted only when it records this worktree"
}

# --- fm-crew-state.sh: the park is reported as the cause ---------------------

test_crew_state_reports_the_park_over_a_busy_verdict() {
  local dir wt state out
  dir="$TMP_ROOT/crew-state"; wt="$dir/wt"; state="$dir/state"
  mkdir -p "$wt" "$state"
  make_store "$dir/store" "$wt" parked >/dev/null
  printf 'window=test:fm-parked\nkind=ship\nharness=claude\nworktree=%s\n' "$wt" > "$state/parked.meta"
  out=$(CLAUDE_CONFIG_DIR="$dir/store" FM_STATE_OVERRIDE="$state" "$CREW_STATE" parked) \
    || fail "fm-crew-state.sh failed on a parked crew"
  case "$out" in
    "state: parked"*"source: allowance"*) ;;
    *) fail "a parked crew was not reported as parked on the allowance: $out" ;;
  esac
  case "$out" in
    *"hit your session limit"*) ;;
    *) fail "the reported state did not name the cause: $out" ;;
  esac
  pass "fm-crew-state.sh reports an allowance park as the crew's current state"
}

test_crew_state_leaves_an_unparked_crew_alone() {
  local dir wt state out
  dir="$TMP_ROOT/crew-state-clean"; wt="$dir/wt"; state="$dir/state"
  mkdir -p "$wt" "$state"
  make_store "$dir/store" "$wt" resumed >/dev/null
  printf 'window=test:fm-live\nkind=ship\nharness=claude\nworktree=%s\n' "$wt" > "$state/live.meta"
  printf 'working: still going\n' > "$state/live.status"
  out=$(CLAUDE_CONFIG_DIR="$dir/store" FM_STATE_OVERRIDE="$state" "$CREW_STATE" live) \
    || fail "fm-crew-state.sh failed on a working crew"
  case "$out" in
    *"source: allowance"*) fail "a crew that resumed after its refusal was reported as parked: $out" ;;
  esac
  pass "fm-crew-state.sh leaves a crew that is not parked to the sources below"
}

# --- fm-watch.sh: the park surfaces as a named wake --------------------------

# build_parked_case <name> <transcript-mode> <pane-text>
# Build a one-window fixture for a real watcher run and set CASE_* for the
# caller. The crew is fixed PROVABLY WORKING by launch_case_watcher below: that
# is the whole point of these cases, because the park is exactly the condition
# every existing liveness read calls healthy.
build_parked_case() {  # <name> <mode> <pane-text>
  local name=$1 mode=$2 pane=$3 key
  CASE_DIR=$(make_case "$name")
  CASE_STATE="$CASE_DIR/state"
  CASE_CAPTURE="$CASE_DIR/pane.txt"
  CASE_WINDOW="test:fm-$name"
  CASE_WT="$CASE_DIR/wt"
  mkdir -p "$CASE_WT"
  make_store "$CASE_DIR/store" "$CASE_WT" "$mode" >/dev/null
  printf '%s\n' "$pane" > "$CASE_CAPTURE"
  printf 'window=%s\nkind=ship\nharness=claude\nworktree=%s\n' \
    "$CASE_WINDOW" "$CASE_WT" > "$CASE_STATE/$name.meta"
  # A settled pane: the watcher trusts the rendered arm only once the capture has
  # been byte-identical across consecutive polls, so prime the hash it will match.
  key=$(printf '%s' "$CASE_WINDOW" | tr ':/.' '___')
  CASE_KEY=$key
  printf '%s' "$(hash_text "$pane")" > "$CASE_STATE/.hash-$key"
  printf '1\n' > "$CASE_STATE/.count-$key"
}

# Run a real watcher over the built fixture, writing to <out> and setting
# CASE_PID. Backgrounded from the caller's own shell (never a command
# substitution) so wait_for_exit can actually reap it.
launch_case_watcher() {  # <out>
  CASE_OUT=$1
  PATH="$CASE_DIR/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$CASE_WINDOW" \
    FM_FAKE_TMUX_CAPTURE="$CASE_CAPTURE" CLAUDE_CONFIG_DIR="$CASE_DIR/store" \
    FM_CREW_STATE_BIN="$CASE_DIR/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_STATE_OVERRIDE="$CASE_STATE" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$CASE_OUT" &
  CASE_PID=$!
}

test_watcher_surfaces_a_park_it_would_otherwise_call_healthy() {
  local drain_out
  # Both signals present, which is the incident's own shape.
  build_parked_case allowance-both parked "$PARKED_PANE_LINE"
  launch_case_watcher "$CASE_DIR/watch.out"
  drain_out="$CASE_DIR/drain.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced a parked worker: $(cat "$CASE_OUT")"; }
  grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the wake did not name the allowance as the cause: $(cat "$CASE_OUT")"
  grep -Fq "single Enter" "$CASE_OUT" \
    || fail "the wake did not name the recovery: $(cat "$CASE_OUT")"
  grep -Fq "$CASE_WINDOW" "$CASE_OUT" \
    || fail "the wake did not name the window: $(cat "$CASE_OUT")"
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "draining the allowance wake failed"
  grep -Fq "parked on the account allowance" "$drain_out" \
    || fail "the allowance wake was not queued durably: $(cat "$drain_out")"
  pass "a worker parked on the allowance is surfaced as a named wake despite reading as working"
}

test_watcher_surfaces_a_park_from_the_transcript_alone() {
  # The rendered notice is gone - a vendor reword, a harness that never printed
  # it, a capture that lost it - and the transcript alone must still carry it.
  build_parked_case allowance-record parked 'Running tests (esc to interrupt)'
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher missed a park visible only in the transcript: $(cat "$CASE_OUT")"; }
  grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the transcript-only park did not surface as an allowance wake: $(cat "$CASE_OUT")"
  grep -Fq "session-record signal" "$CASE_OUT" \
    || fail "the wake did not name the signal it came from: $(cat "$CASE_OUT")"
  pass "a park recorded only in the transcript still surfaces, with the source named"
}

test_watcher_leaves_an_ordinary_worker_alone() {
  build_parked_case allowance-none resumed 'Running tests (esc to interrupt)'
  launch_case_watcher "$CASE_DIR/watch.out"
  # A crew that is provably working on a settled pane is absorbed exactly as it
  # was before this check existed; the point of the case is that detection did
  # not become a second source of false wedge alarms.
  if ! wait_poll_cycle "$CASE_STATE" "$CASE_PID"; then
    reap "$CASE_PID"; fail "the watcher exited for an ordinary working crew: $(cat "$CASE_OUT")"
  fi
  ! grep -Fq "allowance" "$CASE_OUT" \
    || fail "an ordinary working crew was reported parked on the allowance: $(cat "$CASE_OUT")"
  [ ! -e "$CASE_STATE/.allowance-$CASE_KEY" ] \
    || fail "an ordinary working crew left an allowance marker behind"
  reap "$CASE_PID"
  pass "a worker that is not parked is untouched by the allowance check"
}

test_watcher_surfaces_each_park_once() {
  build_parked_case allowance-once parked "$PARKED_PANE_LINE"
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced the first park"; }
  [ -s "$CASE_STATE/.allowance-$CASE_KEY" ] \
    || fail "the surfaced park left no marker, so it would re-wake every poll"
  # Firstmate handles the wake: drain and acknowledge it exactly as a supervision
  # turn does, so the queue is clean before the next watcher runs.
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$CASE_DIR/drain2.out" 2> "$CASE_DIR/drain2.err" || true
  ack_drain_err "$CASE_STATE" "$CASE_DIR/drain2.err" \
    || fail "could not acknowledge the first allowance wake"
  # The worker is still sitting at its limit prompt, and must not wake firstmate
  # again for the same park. Other wake traffic (a check re-arm, say) may still
  # end this watcher's cycle, so the assertion is about the allowance wake alone,
  # not about the watcher staying alive.
  launch_case_watcher "$CASE_DIR/watch2.out"
  wait_for_exit "$CASE_PID" 60 >/dev/null 2>&1 || true
  reap "$CASE_PID"
  ! grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the same park woke firstmate twice: $(cat "$CASE_OUT")"
  ! grep -Fq "parked on the account allowance" "$CASE_STATE/.wake-queue" 2>/dev/null \
    || fail "the same park was queued twice: $(cat "$CASE_STATE/.wake-queue")"
  pass "a park surfaces once per episode rather than on every poll"
}

# Pins the pane-only fallback (no locatable/trusted transcript for this
# worktree) specifically, since that is the path where an ordinary worker's
# structural-only probe - the one run ahead of the secondmate skip, with an
# empty tail - used to clear the marker on its own inconclusive failure just
# before the settled-pane call re-detected the same park and re-fired the wake.
# A "parked" fixture never reaches this: its transcript resolves on the first,
# empty-tail probe, so the marker is never at risk of that probe's failure path.
test_watcher_surfaces_a_pane_only_park_once_across_relaunches() {
  build_parked_case allowance-pane-only none "$PARKED_PANE_LINE"
  launch_case_watcher "$CASE_DIR/watch.out"
  wait_for_exit "$CASE_PID" 100 \
    || { reap "$CASE_PID"; fail "the watcher never surfaced the pane-only park"; }
  grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the pane-only park did not surface as an allowance wake: $(cat "$CASE_OUT")"
  [ -s "$CASE_STATE/.allowance-$CASE_KEY" ] \
    || fail "the surfaced pane-only park left no marker, so it would re-wake every poll"
  # Firstmate handles the wake exactly as in the once-per-episode case above, so
  # the next watcher does not immediately re-announce the prior run's own exit as
  # downtime before ever reaching the stale scan this bug lives in.
  FM_STATE_OVERRIDE="$CASE_STATE" "$DRAIN" > "$CASE_DIR/drain2.out" 2> "$CASE_DIR/drain2.err" || true
  ack_drain_err "$CASE_STATE" "$CASE_DIR/drain2.err" \
    || fail "could not acknowledge the first pane-only allowance wake"
  # The worker is still sitting at its limit prompt with the same unreadable
  # transcript, so relaunching must not wake firstmate again for the same park.
  launch_case_watcher "$CASE_DIR/watch2.out"
  wait_for_exit "$CASE_PID" 60 >/dev/null 2>&1 || true
  reap "$CASE_PID"
  ! grep -Fq "parked on the account allowance" "$CASE_OUT" \
    || fail "the same pane-only park woke firstmate twice: $(cat "$CASE_OUT")"
  ! grep -Fq "parked on the account allowance" "$CASE_STATE/.wake-queue" 2>/dev/null \
    || fail "the same pane-only park was queued twice: $(cat "$CASE_STATE/.wake-queue")"
  pass "a pane-only park surfaces once per episode instead of re-waking on every poll"
}

test_pane_signal_reads_the_rendered_notice
test_pane_signal_is_bounded_to_the_prompt_region
test_record_signal_is_current_state_not_history
test_unsupported_harness_never_parks
test_either_signal_alone_carries_the_verdict
test_transcript_must_belong_to_this_worktree
test_crew_state_reports_the_park_over_a_busy_verdict
test_crew_state_leaves_an_unparked_crew_alone
test_watcher_surfaces_a_park_it_would_otherwise_call_healthy
test_watcher_surfaces_a_park_from_the_transcript_alone
test_watcher_leaves_an_ordinary_worker_alone
test_watcher_surfaces_each_park_once
test_watcher_surfaces_a_pane_only_park_once_across_relaunches
