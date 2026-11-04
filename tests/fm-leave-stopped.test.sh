#!/usr/bin/env bash
# tests/fm-leave-stopped.test.sh - the durable "leave it stopped" marker
# (bin/fm-leave-stopped.sh): mark and clear through the executable; the
# refusals that keep it the captain's call (exact task id, main actor only, a
# one-line reason); and the warning, not refusal, on a working reading such as a
# dead Grok terminal's stale busy footer. The watcher's own silence for a
# marked task is proven in tests/fm-watch-triage.test.sh
# (test_left_stopped_task_pane_never_realarms), and teardown's removal of the
# marker in tests/fm-teardown.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEAVE="$ROOT/bin/fm-leave-stopped.sh"
TMP_ROOT=$(fm_test_tmproot fm-leave-stopped)

# A home with one recorded task and a hermetic fm-crew-state.sh whose verdict
# FM_FAKE_CREW_STATE sets (the same seam bin/fm-classify-lib.sh documents).
make_home() {  # <name> <task-id>
  local name=$1 id=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin"
  printf 'window=test:fm-%s\nkind=ship\nproject=%s/projects/p\nharness=pi\n' "$id" "$home" > "$home/state/$id.meta"
  cat > "$home/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · no current-state source available}"
SH
  chmod +x "$home/fakebin/fm-crew-state.sh"
  printf '%s\n' "$home"
}

leave() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" "$LEAVE" "$@"
}

test_mark_clear_round_trip() {
  local home out status marker
  home=$(make_home round-trip drawer)
  marker="$home/state/drawer.stopped"

  out=$(leave "$home" drawer mark --reason "captain: leave the AI drawer worker stopped" 2>&1); status=$?
  expect_code 0 "$status" "mark on a dead task must succeed: $out"
  [ -f "$marker" ] || fail "mark did not write state/drawer.stopped"
  grep -Fxq 'schema=fm-leave-stopped.v1' "$marker" || fail "marker lacks its schema line: $(cat "$marker")"
  grep -Eq '^at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$marker" || fail "marker lacks a UTC timestamp: $(cat "$marker")"
  grep -Fxq 'reason=captain: leave the AI drawer worker stopped' "$marker" || fail "marker lacks the captain's reason: $(cat "$marker")"
  case "$out" in *"state/drawer.stopped"*) ;; *) fail "mark did not name the marker it wrote: $out" ;; esac
  case "$out" in *warning*) fail "mark on a non-working task warned: $out" ;; esac
  [ -z "$(find "$home/state" -name '.drawer.stopped.*' 2>/dev/null)" ] || fail "mark left its temp file behind"

  # Re-marking replaces the reason rather than refusing: the captain may restate.
  out=$(leave "$home" drawer mark --reason="still leave it" 2>&1); status=$?
  expect_code 0 "$status" "re-mark must succeed: $out"
  grep -Fxq 'reason=still leave it' "$marker" || fail "re-mark did not replace the reason: $(cat "$marker")"

  out=$(leave "$home" drawer clear 2>&1); status=$?
  expect_code 0 "$status" "clear must succeed: $out"
  [ ! -e "$marker" ] || fail "clear left the marker behind"
  out=$(leave "$home" drawer clear 2>&1); status=$?
  expect_code 0 "$status" "clear on an unmarked task is idempotent: $out"
  case "$out" in *"nothing to clear"*) ;; *) fail "idempotent clear did not say so: $out" ;; esac
  [ ! -e "$marker" ] || fail "an idempotent clear created a marker"
  pass "mark writes the schema, timestamp, and reason; re-mark replaces it; clear removes it idempotently"
}

test_mark_on_a_stale_working_footer_warns_and_records() {
  local home out status reading marker
  home=$(make_home grok-footer drawer)
  marker="$home/state/drawer.stopped"
  # A Grok worker that dropped to a shell with its last busy footer still on
  # screen keeps reading as working through its pane.
  reading='state: working · source: pane · busy'
  out=$(FM_FAKE_CREW_STATE="$reading" leave "$home" drawer mark --reason "captain: leave the AI drawer worker stopped" 2>&1); status=$?
  expect_code 0 "$status" "mark on a stale working footer must succeed: $out"
  [ -f "$marker" ] || fail "mark on a stale working footer did not write the marker"
  grep -Fxq 'reason=captain: leave the AI drawer worker stopped' "$marker" || fail "marker lacks the captain's reason: $(cat "$marker")"
  case "$out" in
    *warning*"reads as working"*"$reading"*) ;;
    *) fail "mark did not warn with the current reading: $out" ;;
  esac
  grep -Fxq 'harness=pi' "$home/state/drawer.meta" || fail "mark disturbed the task record"

  # A run-step working reading is likewise recorded with the warning.
  out=$(FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    leave "$home" drawer mark --reason "leave it" 2>&1); status=$?
  expect_code 0 "$status" "mark on a run-step working reading must succeed: $out"
  case "$out" in *warning*"source: run-step"*) ;; *) fail "run-step reading was not named in the warning: $out" ;; esac
  grep -Fxq 'reason=leave it' "$marker" || fail "the run-step mark did not record its reason: $(cat "$marker")"
  pass "mark records the captain's order on a working reading and warns with that reading"
}

test_refusals_keep_it_the_captains_call() {
  local home out status
  home=$(make_home refusals drawer)

  out=$(leave "$home" drawer mark 2>&1); status=$?
  expect_code 2 "$status" "mark without --reason must refuse"
  case "$out" in *"requires --reason"*) ;; *) fail "missing-reason refusal was not explained: $out" ;; esac

  out=$(leave "$home" drawer mark --reason "$(printf 'two\nlines')" 2>&1); status=$?
  expect_code 2 "$status" "a multi-line reason must refuse"
  [ ! -e "$home/state/drawer.stopped" ] || fail "a refused multi-line reason still wrote the marker"

  out=$(leave "$home" nope mark --reason r 2>&1); status=$?
  expect_code 2 "$status" "an unrecorded task id must refuse"
  case "$out" in *"no task 'nope'"*) ;; *) fail "unknown-task refusal was not explained: $out" ;; esac
  [ ! -e "$home/state/nope.stopped" ] || fail "an unrecorded task got a marker"

  out=$(leave "$home" fm-drawer mark --reason r 2>&1); status=$?
  expect_code 2 "$status" "a window label must refuse"
  case "$out" in *"window label"*"'drawer'"*) ;; *) fail "window-label refusal did not point at the task id: $out" ;; esac

  out=$(leave "$home" "../drawer" mark --reason r 2>&1); status=$?
  expect_code 2 "$status" "a path-shaped id must refuse"
  out=$(leave "$home" drawer show 2>&1); status=$?
  expect_code 2 "$status" "an unknown verb must refuse"
  out=$(leave "$home" drawer clear --reason r 2>&1); status=$?
  expect_code 2 "$status" "--reason on clear must refuse"

  # The supervision branch never records the captain's order; main does.
  out=$(FM_SUPERVISION_ACTOR=branch leave "$home" drawer mark --reason r 2>&1); status=$?
  expect_code 6 "$status" "the branch actor must be refused on mark"
  case "$out" in *"supervision branch never performs this action"*) ;; *) fail "branch refusal was not the role-partition message: $out" ;; esac
  [ ! -e "$home/state/drawer.stopped" ] || fail "the branch actor wrote the marker"
  leave "$home" drawer mark --reason r >/dev/null 2>&1 || fail "main could not mark after the branch refusal"
  out=$(FM_SUPERVISION_ACTOR=branch leave "$home" drawer clear 2>&1); status=$?
  expect_code 6 "$status" "the branch actor must be refused on clear"
  [ -e "$home/state/drawer.stopped" ] || fail "the branch actor cleared the marker"
  pass "mark and clear refuse an unrecorded or path-shaped id, an unknown verb, a missing or multi-line reason, and the branch actor"
}

test_mark_clear_round_trip
test_mark_on_a_stale_working_footer_warns_and_records
test_refusals_keep_it_the_captains_call
