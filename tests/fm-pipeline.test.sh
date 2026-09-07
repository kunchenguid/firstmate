#!/usr/bin/env bash
# Behavior tests for the shadow-only external-wait pipeline writer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

SCRIPT="${FM_PIPELINE_TEST_SCRIPT:-$ROOT/bin/fm-pipeline.sh}"
TMP_ROOT=$(fm_test_tmproot fm-pipeline)

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

new_state() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/worktree"
  printf '%s\n' "$dir"
}

test_line_format_and_unknown_preservation() {
  local root output line rc=0
  root=$(new_state unknown)
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  printf 'kind=ship\nspawn_gen=gen-unknown\nworktree=%s/worktree\nharness=tmux\n' "$root" > "$root/state/task.meta"
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: paused · source: pane · fixture'
EOF
  chmod +x "$root/fake-crew-state.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "probe should succeed for a declared wait"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'ts=' "every event must have a timestamp"
  assert_contains "$line" 'probe=unknown' "an unobserved wait must remain unknown"
  assert_contains "$line" 'mode=shadow' "every event must be shadow-only"
  assert_contains "$line" 'wait=ext:vendor-release' "the keyed wait must be recorded"
  [ "$(printf '%s' "$line" | awk '{print NF}')" -eq 14 ] || fail "event line did not have 14 fields: $line"
  pass "fm-pipeline.sh: line format preserves probe=unknown"
}

test_probe_state_unavailable_is_explicit_and_noncreating() {
  local root state target before after output rc=0
  root=$(new_state state-unavailable)
  state="$root/missing-state"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "a missing state directory must refuse the probe"
  assert_contains "$output" "state unavailable: $state (absent)" \
    "a missing state directory must name its path and kind"
  [ ! -e "$state" ] || fail "a missing state directory was created"

  target="$root/target-state"
  mkdir -p "$target"
  printf '%s\n' sentinel > "$target/sentinel"
  before=$(shasum -a 256 "$target/sentinel")
  state="$root/symlink-state"
  ln -s "$target" "$state"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "a symlinked state directory must refuse the probe"
  assert_contains "$output" "state unavailable: $state (symlink)" \
    "a symlinked state directory must name its path and kind"
  [ -L "$state" ] || fail "the state symlink was changed"
  after=$(shasum -a 256 "$target/sentinel")
  [ "$before" = "$after" ] || fail "the state symlink target changed"
  [ ! -e "$target/pipeline-events.log" ] || fail "the state symlink target received an event log"

  state="$root/not-a-directory"
  printf '%s\n' sentinel > "$state"
  before=$(shasum -a 256 "$state")
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "a non-directory state path must refuse the probe"
  assert_contains "$output" "state unavailable: $state (not-a-directory)" \
    "a non-directory state path must name its path and kind"
  after=$(shasum -a 256 "$state")
  [ "$before" = "$after" ] || fail "the non-directory state path changed"
  pass "fm-pipeline.sh: unavailable state paths are explicit and non-creating"
}

test_probe_activity_read_failure_leaves_unknown_trace() {
  local root bad_status output line rc=0
  root=$(new_state activity-read-failure)
  bad_status="$root/state/bad.status"
  printf 'paused: [key=bad-wait] waiting on an unreadable status file\n' > "$bad_status"
  printf 'kind=ship\nstep=working\nspawn_gen=bad-gen\n' > "$root/state/bad.meta"
  printf 'paused: [key=good-wait] waiting on a readable status file\n' > "$root/state/good.status"
  printf 'kind=ship\nstep=working\nspawn_gen=good-gen\n' > "$root/state/good.meta"
  chmod 000 "$bad_status"
  if cat "$bad_status" >/dev/null 2>&1; then
    chmod 0600 "$bad_status"
    pass "fm-pipeline.sh: activity-read-failure fixture skipped when permissions are readable"
    return
  fi
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  chmod 0600 "$bad_status"
  expect_code 0 "$rc" "a failed activity read should leave a trace and continue"
  line=$(rg 'task=bad ' "$root/state/pipeline-events.log" || true)
  assert_contains "$line" 'probe=unknown' "a failed activity read must remain unknown"
  assert_contains "$line" 'rule=- action=none' "a failed activity read must not request healing"
  assert_contains "$line" 'evidence=scan:activity-read-failed' \
    "a failed activity read must name its scan evidence"
  assert_contains "$line" 'wait=ext:-' "a failed activity read must use the unkeyed wait identity"
  [ "$(rg -c 'task=bad ' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "a failed activity read produced more than one row"
  [ ! -e "$root/state/bad.pipeline-seen" ] \
    || fail "a failed activity read polluted the pause observation cache"
  line=$(rg 'task=good ' "$root/state/pipeline-events.log" || true)
  assert_contains "$line" 'evidence=state/good.status:' \
    "a readable task should retain its normal activity evidence"
  assert_not_contains "$line" 'activity-read-failed' \
    "a readable task inherited another task's read failure"
  pass "fm-pipeline.sh: failed activity reads produce one unknown row without affecting peers"
}

test_probe_deadline_coverage_is_clock_scripted() {
  local root fakebin epochs date_log output rc=0 start cutoff cursor before id expected_deadline served
  root=$(new_state deadline-clock)
  fakebin="$root/fakebin"
  epochs="$root/epochs"
  date_log="$root/date-served"
  mkdir -p "$fakebin"
  for id in alpha beta gamma; do
    printf 'paused: [key=%s-wait] waiting on the fixture\n' "$id" > "$root/state/$id.status"
    printf 'kind=ship\nstep=working\nspawn_gen=%s-gen\n' "$id" > "$root/state/$id.meta"
  done
  cat > "$fakebin/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = '+%s' ]; then
  value=$(awk 'NR == 1 { print; exit }' "$FM_PIPELINE_TEST_DATE_EPOCHS") || exit 1
  [ -n "$value" ] || exit 1
  tail -n +2 "$FM_PIPELINE_TEST_DATE_EPOCHS" > "$FM_PIPELINE_TEST_DATE_EPOCHS.next" || exit 1
  mv "$FM_PIPELINE_TEST_DATE_EPOCHS.next" "$FM_PIPELINE_TEST_DATE_EPOCHS" || exit 1
  printf '%s\n' "$value" >> "$FM_PIPELINE_TEST_DATE_LOG"
  printf '%s\n' "$value"
  exit 0
fi
if [ "${1:-}" = '-u' ] && [ "${2:-}" = '+%Y-%m-%dT%H:%M:%SZ' ]; then
  printf '%s\n' '2026-09-06T00:00:00Z'
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$fakebin/date"
  printf '%s\n' 100 100 101 104 105 106 > "$epochs"
  : > "$date_log"
  output=$(PATH="$fakebin:$PATH" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_DEADLINE=5 FM_PIPELINE_TEST_DATE_EPOCHS="$epochs" \
    FM_PIPELINE_TEST_DATE_LOG="$date_log" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "a crossed deadline must return one"
  served=$(cat "$date_log")
  start=$(awk 'NR == 1 { print; exit }' "$date_log")
  cutoff=$((start + 5))
  cursor=2
  expected_deadline=
  for id in alpha beta gamma; do
    before=$(awk -v line="$cursor" 'NR == line { print; exit }' "$date_log")
    cursor=$((cursor + 1))
    if [ "$before" -ge "$cutoff" ]; then
      expected_deadline="${expected_deadline}${id}\n"
    else
      cursor=$((cursor + 1))
    fi
  done
  [ "$served" = $'100\n100\n101\n104\n105\n106' ] \
    || fail "the controlled clock did not record the real date-call sequence: $served"
  for id in alpha beta gamma; do
    if printf '%b' "$expected_deadline" | rg -Fx "$id" >/dev/null; then
      [ "$(rg -c "task=$id " "$root/state/pipeline-events.log")" -eq 1 ] \
        || fail "deadline task $id did not receive exactly one row"
      rg -F "task=$id " "$root/state/pipeline-events.log" | rg -F 'evidence=scan:deadline' >/dev/null \
        || fail "deadline task $id did not receive scan:deadline evidence"
    else
      [ "$(rg -c "task=$id " "$root/state/pipeline-events.log")" -eq 1 ] \
        || fail "visited task $id did not receive exactly one row"
      rg -F "task=$id " "$root/state/pipeline-events.log" | rg -F 'evidence=state/' >/dev/null \
        || fail "visited task $id did not receive activity evidence"
    fi
  done
  [ "$(rg -c 'evidence=scan:deadline' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "deadline coverage emitted the wrong number of rows"

  root=$(new_state deadline-disabled)
  for id in alpha beta; do
    printf 'paused: [key=%s-wait] waiting on the fixture\n' "$id" > "$root/state/$id.status"
    printf 'kind=ship\nstep=working\nspawn_gen=%s-gen\n' "$id" > "$root/state/$id.meta"
  done
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_DEADLINE=0 \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "zero must disable deadline coverage"
  [ "$(rg -c '^' "$root/state/pipeline-events.log")" -eq 2 ] \
    || fail "disabled deadline did not visit every task"
  assert_not_contains "$(cat "$root/state/pipeline-events.log")" 'scan:deadline' \
    "disabled deadline emitted a deadline row"

  root=$(new_state deadline-large)
  printf 'paused: [key=fixture] waiting on the fixture\n' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_DEADLINE=9223372036854775807 "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "the largest representable deadline must not expire immediately"
  [ "$(rg -c '^' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "the largest representable deadline did not visit the task"
  assert_not_contains "$(cat "$root/state/pipeline-events.log")" 'scan:deadline' \
    "the largest representable deadline expired at elapsed zero"
  pass "fm-pipeline.sh: deadline coverage follows a controlled call-boundary clock and large values fail safely"
}

test_probe_invalid_deadline_refuses_before_scan() {
  local value root output rc
  for value in '' abc -1 9223372036854775808 18446744073709551616; do
    root=$(new_state "deadline-invalid-${value:-empty}")
    printf 'paused: [key=fixture] waiting on the fixture\n' > "$root/state/task.status"
    printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
    rc=0
    output=$(FM_PIPELINE_DEADLINE="$value" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
      "$SCRIPT" probe 2>&1) || rc=$?
    expect_code 2 "$rc" "invalid deadline '$value' must refuse before scanning"
    assert_contains "$output" 'invalid FM_PIPELINE_DEADLINE:' \
      "invalid deadline '$value' did not name the variable"
    assert_contains "$output" '(non-negative integer seconds; 0 disables)' \
      "invalid deadline '$value' did not name its domain"
    [ ! -e "$root/state/pipeline-events.log" ] \
      || fail "invalid deadline '$value' wrote an event before refusing"
    [ ! -e "$root/state/task.pipeline" ] \
      || fail "invalid deadline '$value' reconciled before refusing"
  done
  pass "fm-pipeline.sh: invalid deadline values refuse before any scan"
}

test_pipeline_probe_units() {
  local root output
  root=$(new_state probe-units)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_SOURCE_ONLY=1 \
    bash -c '
      set -u
      source "$1"
      for case in "100 100 0" "100 104 5" "100 105 5" "100 100 9223372036854775807"; do
        set -- $case
        printf "decision=%s\n" "$(pipeline_deadline_decision "$1" "$2" "$3")"
      done
      printf "max=%s\n" "$(pipeline_deadline_validate 9223372036854775807)"
      large_rc=0
      pipeline_deadline_validate 9223372036854775808 >/dev/null || large_rc=$?
      printf "large_rc=%s\n" "$large_rc"
      row=$(pipeline_probe_row 2026-09-06T00:00:00Z task ship working 0 unknown - none scan:deadline gen-1 - ext:-)
      event_valid "$row"
      printf "row=%s\n" "$row"
    ' _ "$SCRIPT")
  assert_contains "$output" 'decision=continue' "deadline unit did not preserve a continuing scan"
  assert_contains "$output" 'decision=stop' "deadline unit did not stop at the boundary"
  assert_contains "$output" 'max=9223372036854775807' "deadline unit did not preserve the maximum value"
  assert_contains "$output" 'large_rc=1' "deadline unit accepted an overflowing value"
  assert_contains "$output" 'evidence=scan:deadline' "probe row unit omitted scan evidence"
  assert_contains "$output" 'wait=ext:-' "probe row unit omitted the unkeyed wait"
  pass "fm-pipeline.sh: deadline decision and scan-row units validate through event_valid"
}

test_probe_stress_measurement() {
  local live_dir live_status live_lines candidate candidate_lines
  command -v python3 >/dev/null 2>&1 || {
    pass "fm-pipeline.sh: stress measurement skipped (python3 is unavailable)"
    return
  }
  run_stress_python() {
    python3 - "$SCRIPT" "$TMP_ROOT/stress" "$1" "$2" "$3" <<'PY'
import hashlib
import os
import shutil
import signal
import subprocess
import sys
import time

script, base, live_lines, live_source, enabled = sys.argv[1:]


def censored_median(results, censored):
    ordered = sorted(results) + [float("inf")] * censored
    middle = ordered[len(ordered) // 2]
    return None if middle == float("inf") else middle


assert censored_median([10.0], 2) is None
assert censored_median([10.0, 20.0], 1) == 20.0
print("median_unit=mixed-censored-ok")
if enabled != "1" or live_source == "-":
    if enabled == "1":
        print("stress=live fixture skipped (no live status file found)")
    raise SystemExit(0)

os.makedirs(base, exist_ok=True)
live_fixture = os.path.join(base, "live.status")
with open(live_source, "rb") as source_handle:
    live_bytes = source_handle.read()
with open(live_fixture, "wb") as fixture_handle:
    fixture_handle.write(live_bytes)
live_fixture_lines = live_bytes.count(b"\n")
print(
    f"stress=live fixture_lines={live_fixture_lines} "
    f"fixture_sha256={hashlib.sha256(live_bytes).hexdigest()}"
)


def measure(label, line_count, source):
    results = []
    censored = 0
    for index in range(3):
        home = f"{base}-{label}-{index}"
        state = os.path.join(home, "state")
        os.makedirs(state, exist_ok=True)
        status = os.path.join(state, "task.status")
        if source == "-":
            with open(status, "w", encoding="utf-8") as handle:
                handle.write("paused: [key=one] waiting on the fixture\n")
                handle.write("paused: [key=two] waiting on the fixture\n")
                handle.write("paused: [key=three] waiting on the fixture\n")
                for filler in range(line_count - 3):
                    handle.write(f"note: filler line {filler}\n")
        else:
            shutil.copyfile(source, status)
        with open(os.path.join(state, "task.meta"), "w", encoding="utf-8") as handle:
            handle.write("kind=ship\nstep=working\nspawn_gen=stress\n")
        process = subprocess.Popen(
            [script, "probe"],
            cwd=home,
            env={**os.environ, "FM_HOME": home, "FM_STATE_OVERRIDE": state, "FM_PIPELINE_DEADLINE": "0"},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        started = time.monotonic()
        try:
            result = process.wait(timeout=30)
            elapsed = time.monotonic() - started
            print(f"stress={label} run={index + 1} seconds={elapsed:.3f} rc={result}")
            if result != 0:
                raise SystemExit(result)
            results.append(elapsed)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            censored += 1
            print(f"stress={label} run={index + 1} censored=>30s")
    median = censored_median(results, censored)
    if median is None:
        print(f"stress={label} median_seconds=>30s censored={censored}")
    else:
        print(f"stress={label} median_seconds={median:.3f} censored={censored}")


measure("20000", 20000, "-")
measure(str(live_fixture_lines), live_fixture_lines, live_fixture)
PY
  }
  if [ "${FM_PIPELINE_STRESS:-0}" != 1 ]; then
    run_stress_python 0 - 0 || return 1
    pass "fm-pipeline.sh: stress measurement skipped (set FM_PIPELINE_STRESS=1)"
    return
  fi
  live_dir=${FM_PIPELINE_STRESS_LIVE_STATE_DIR:-${FM_HOME:-$ROOT}/state}
  live_status=
  live_lines=0
  for candidate in "$live_dir"/*.status; do
    [ -f "$candidate" ] || continue
    candidate_lines=$(wc -l < "$candidate" | tr -d ' ')
    if [ "$candidate_lines" -gt "$live_lines" ]; then
      live_lines=$candidate_lines
      live_status=$candidate
    fi
  done
  run_stress_python "$live_lines" "${live_status:--}" 1 || return $?
  if [ -z "$live_status" ]; then
    pass "fm-pipeline.sh: stress measurement skipped (no live status file found)"
  else
    pass "fm-pipeline.sh: opt-in stress measurement completed for 20k and fixed live-max content"
  fi
}

test_would_heal_without_evidence_is_rejected() {
  local root output rc=0
  root=$(new_state invalid-evidence)
  output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
    'ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=stall rule=recheck-external action=would-heal mode=shadow evidence=- gen=1 attempt=- wait=ext:x snap=-' 2>&1) || rc=$?
  expect_code 1 "$rc" "a would-heal without evidence must be refused"
  assert_contains "$output" "inadmissible" "the refusal must identify inadmissible evidence"
  [ ! -e "$root/state/pipeline-events.log" ] || fail "invalid event was written"
  pass "fm-pipeline.sh: would-heal with evidence=- is inadmissible"
}

test_append_rejects_malformed_fields() {
  local root line bad_line output rc
  root=$(new_state malformed-event)
  line='ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=unknown rule=- action=none mode=shadow evidence=state/t1.status:1 gen=1 attempt=- wait=ext:x snap=-'
  for bad_line in \
    "${line/task=t1/task=../escape}" \
    "${line/since=10/since=-1}" \
    "${line/gen=1/gen=bad=value}" \
    "${line/attempt=-/attempt=bad value}" \
    "${line/wait=ext:x/wait=ext:}" \
    "${line/snap=-/snap=bad value}"; do
    rc=0
    output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append "$bad_line" 2>&1) || rc=$?
    expect_code 1 "$rc" "malformed event fields must be refused"
  done
  [ ! -e "$root/state/pipeline-events.log" ] || fail "malformed events were written"
  pass "fm-pipeline.sh: malformed event fields are rejected"
}

test_event_log_symlink_is_rejected() {
  local root outside output rc=0
  root=$(new_state log-safety)
  outside="$root/outside.log"
  printf 'sentinel\n' > "$outside"
  ln -s "$outside" "$root/state/pipeline-events.log"
  output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
    'ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=unknown rule=- action=none mode=shadow evidence=state/t1.status:1 gen=1 attempt=- wait=ext:x snap=-' 2>&1) || rc=$?
  expect_code 1 "$rc" "a symlinked event log must be refused"
  [ "$(cat "$outside")" = sentinel ] || fail "symlinked event log was followed"
  pass "fm-pipeline.sh: symlinked event logs are rejected"
}

test_stale_wait_is_shadow_only() {
  local root output line rc=0
  root=$(new_state stale)
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\nworktree=%s/worktree\nharness=tmux\n' "$root" > "$root/state/task.meta"
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: done · source: run-step · fixture'
EOF
  chmod +x "$root/fake-crew-state.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a declared wait should be observed successfully"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'probe=unknown' "an unobserved wait must remain unknown"
  assert_contains "$line" 'rule=-' "an unobserved wait must have no rule"
  assert_contains "$line" 'action=none' "an unobserved wait must not request healing"
  assert_contains "$line" 'mode=shadow' "wait observations must remain shadow-only"
  assert_contains "$line" 'since=0' "first observations must start their lower-bound duration at zero"
  assert_contains "$line" 'gen=gen-1' "events must use the spawn incarnation"
  [ -f "$root/state/task.pipeline" ] || fail "the first observation was not recorded"
  pass "fm-pipeline.sh: unobserved waits remain unknown without a healing action"
}

test_terminal_statuses_without_premise_are_unknown() {
  local root status_line verb output line rc
  for status_line in 'done: finished' 'blocked: x' 'failed: x'; do
    root=$(new_state "terminal-${status_line%%:*}")
    printf '%s\n' \
      'paused: [key=vendor-release] waiting on vendor' \
      "$status_line" > "$root/state/task.status"
    printf 'kind=ship\nstep=working\nspawn_gen=gen-terminal\n' > "$root/state/task.meta"
    verb=${status_line%%:*}
    cat > "$root/fake-crew-state.sh" <<EOF
#!/usr/bin/env bash
printf '%s\\n' 'state: $verb · source: run-step · fixture'
EOF
    chmod +x "$root/fake-crew-state.sh"
    rc=0
    output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
      FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
    expect_code 0 "$rc" "$verb status should still produce an observation"
    line=$(tail -1 "$root/state/pipeline-events.log")
    assert_contains "$line" 'probe=unknown' "$verb status must not prove an external premise"
    assert_contains "$line" 'rule=-' "$verb status must have no healing rule"
    assert_contains "$line" 'action=none' "$verb status must not request healing"
  done
  pass "fm-pipeline.sh: done, blocked, and failed status lines remain unknown"
}

test_resumed_wait_is_not_reprobed() {
  local root output rc=0 events
  root=$(new_state resumed)
  printf '%s\n' 'paused: [key=vendor-release] waiting on vendor' > "$root/state/task.status"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "the initial paused wait should be observed"
  printf '%s\n' 'working: [key=vendor-release] resumed after vendor release' >> "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "the resumed wait should close"
  events=$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')
  [ "$events" -eq 2 ] || fail "the resumed wait did not emit exactly one closure"
  [ "$(rg -c 'probe=ok.*evidence=state/task.status:2' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "the closure did not cite the resume line"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a closed wait should remain closed"
  [ "$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')" -eq 2 ] \
    || fail "a closed wait was re-probed"
  pass "fm-pipeline.sh: resumed waits close once and are not re-probed"
}

test_note_preserves_active_wait() {
  local root output line rc=0
  root=$(new_state note)
  printf '%s\n' \
    'paused: [key=vendor-release] waiting on vendor' \
    'note: vendor contact recorded' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "an informational note should preserve an active pause"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'wait=ext:vendor-release' "the active paused wait must survive a note"
  pass "fm-pipeline.sh: informational notes preserve active waits"
}

test_configured_pause_verb_is_supported() {
  local root output line rc=0
  root=$(new_state custom-pause)
  printf 'waiting: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  output=$(FM_CLASSIFY_PAUSED_VERB=waiting FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a configured pause verb should be probed"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'wait=ext:vendor-release' "configured pause verbs must preserve the wait key"
  pass "fm-pipeline.sh: configured pause verbs are supported"
}

test_all_active_waits_are_probed_independently() {
  local root output rc=0
  root=$(new_state multiple-waits)
  printf '%s\n' \
    'paused: [key=vendor-release] waiting on vendor' \
    'paused: [key=rate-limit] waiting on provider' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "all active waits should be probed"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 2 ] || fail "only one active wait was probed"
  [ "$(rg -c 'probe=unknown' "$root/state/pipeline-events.log")" -eq 2 ] || fail "active waits were not recorded as unknown"
  [ "$(rg -c 'wait=ext:vendor-release' "$root/state/pipeline-events.log")" -eq 1 ] || fail "vendor wait was not recorded"
  [ "$(rg -c 'wait=ext:rate-limit' "$root/state/pipeline-events.log")" -eq 1 ] || fail "rate-limit wait was not recorded"
  local cache="$root/state/task.pipeline-seen"
  [ -f "$cache" ] || cache="$root/state/task.pipeline"
  [ "$(rg -c '^wait=ext:' "$cache")" -eq 2 ] || fail "wait timings were not kept independently"
  pass "fm-pipeline.sh: all active waits receive independent observations"
}

test_pause_key_sentinels_remain_distinct() {
  local root output rc=0
  root=$(new_state pause-sentinels)
  printf '%s\n' \
    'paused: waiting on an external service' \
    'paused: [key=-] waiting on a literal hyphen key' \
    'paused: [key=bad key] malformed key' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "pause key sentinel probing should succeed"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 2 ] || fail "invalid pause key changed active wait count"
  [ "$(rg -c 'probe=unknown' "$root/state/pipeline-events.log")" -eq 2 ] || fail "active sentinel waits were not recorded as unknown"
  grep -F 'wait=ext:-' "$root/state/pipeline-events.log" >/dev/null \
    || fail "unkeyed pause lost its wait identity"
  grep -F 'wait=ext:%2D' "$root/state/pipeline-events.log" >/dev/null \
    || fail "literal hyphen key collided with unkeyed pause"
  grep -F 'evidence=state/task.status:3' "$root/state/pipeline-events.log" >/dev/null \
    && fail "invalid pause key was treated as an active wait"
  pass "fm-pipeline.sh: pause key sentinels remain distinct"
}

test_valid_invalid_slug_remains_distinct() {
  local root output rc=0
  root=$(new_state invalid-slug)
  printf '%s\n' \
    'paused: [key=invalid] waiting on a valid key' \
    'paused: [key=bad key] malformed key' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "valid and malformed pause keys should be handled"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 1 ] || fail "malformed key changed the active wait count"
  grep -F 'wait=ext:invalid' "$root/state/pipeline-events.log" >/dev/null \
    || fail "valid key=invalid was treated as malformed"
  grep -F 'evidence=state/task.status:2' "$root/state/pipeline-events.log" >/dev/null \
    && fail "malformed key was treated as the valid key"
  pass "fm-pipeline.sh: valid invalid-slug keys remain distinct"
}

test_explicit_default_key_remains_distinct() {
  local root output rc=0
  root=$(new_state default-key)
  printf '%s\n' \
    'paused: waiting on an unkeyed wait' \
    'paused: [key=default] waiting on the default key' \
    'paused: [key=invalid] waiting on the invalid key' \
    'paused: [key=bad key] malformed key' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "explicit and unkeyed pause keys should be handled"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 3 ] \
    || fail "explicit default key changed the active wait count"
  [ "$(rg -c 'probe=unknown' "$root/state/pipeline-events.log")" -eq 3 ] \
    || fail "active default/sentinel waits were not recorded as unknown"
  grep -F 'wait=ext:-' "$root/state/pipeline-events.log" >/dev/null \
    || fail "unkeyed pause lost its wait identity"
  grep -F 'wait=ext:%64efault' "$root/state/pipeline-events.log" >/dev/null \
    || fail "literal default key collided with the unkeyed pause"
  grep -F 'wait=ext:invalid' "$root/state/pipeline-events.log" >/dev/null \
    || fail "literal invalid key lost its wait identity"
  grep -F 'evidence=state/task.status:4' "$root/state/pipeline-events.log" >/dev/null \
    && fail "malformed key was treated as an active wait"
  pass "fm-pipeline.sh: explicit default keys remain distinct"
}

test_stale_event_lock_is_recovered() {
  local root output rc=0
  root=$(new_state stale-lock)
  mkdir "$root/state/pipeline-events.log.lock"
  touch -t 202001010000 "$root/state/pipeline-events.log.lock"
  output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
    'ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=stall rule=recheck-external action=would-heal mode=shadow evidence=state/t1.status:1 gen=1 attempt=- wait=ext:x snap=-' 2>&1) || rc=$?
  expect_code 0 "$rc" "a stale event lock should be recovered"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 1 ] || fail "event was not appended after stale lock recovery"
  [ ! -e "$root/state/pipeline-events.log.lock" ] || fail "recovered event lock remained"
  pass "fm-pipeline.sh: stale event locks recover through shared locking"
}

test_task_paths_are_confined() {
  local root outside output rc=0
  root=$(new_state path-safety)
  outside="$root/escape.status"
  printf 'sentinel\n' > "$outside"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe --task ../escape 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "task traversal was accepted"
  [ "$(cat "$outside")" = sentinel ] || fail "task traversal touched an outside file"

  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/link.status"
  ln -s "$outside" "$root/state/link.meta"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe --task link 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked metadata was accepted"
  [ ! -e "$root/state/pipeline-events.log" ] || fail "symlinked metadata produced an event"

  rm -f "$root/state/link.meta"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/link.meta"
  ln -s "$outside" "$root/state/link.pipeline"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe --task link 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked pipeline state was accepted"
  [ "$(cat "$outside")" = sentinel ] || fail "symlinked pipeline state was followed"
  pass "fm-pipeline.sh: task and state paths stay confined"
}

test_arm_preserves_existing_check_on_registration_failure() {
  local root check trust fakebin count shasum_count old old_trust output rc=0
  root=$(new_state arm-rollback)
  check="$root/state/pipeline-probe.check.sh"
  trust="$root/state/pipeline-probe.check-trust"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not create the expected pipeline probe check"
  old=$(cat "$check")
  old_trust=$(cat "$trust")
  fakebin="$root/fakebin"
  count="$root/fake-cat-count"
  shasum_count="$root/fake-shasum-count"
  mkdir -p "$fakebin"
  : > "$count"
  : > "$shasum_count"
  cat > "$fakebin/cat" <<'EOF'
#!/usr/bin/env bash
count=0
IFS= read -r count < "${FM_PIPELINE_FAKE_CAT_COUNT}" || true
count=$((count + 1))
printf '%s\n' "$count" > "$FM_PIPELINE_FAKE_CAT_COUNT"
if [ "$count" -eq 3 ]; then
  printf '%s\n' changed
else
  /bin/cat "$@"
  fi
EOF
  cat > "$fakebin/shasum" <<'EOF'
#!/usr/bin/env bash
count=0
IFS= read -r count < "${FM_PIPELINE_FAKE_SHASUM_COUNT}" || true
count=$((count + 1))
printf '%s\n' "$count" > "$FM_PIPELINE_FAKE_SHASUM_COUNT"
case "$count" in
  1) hash=$(sed -n '2p' "$FM_PIPELINE_EXPECTED_TRUST") ;;
  2) hash=0000000000000000000000000000000000000000000000000000000000000000 ;;
  *) hash=1111111111111111111111111111111111111111111111111111111111111111 ;;
esac
printf '%s  %s\n' "$hash" "${1-}"
EOF
  chmod +x "$fakebin/cat" "$fakebin/shasum"
  output=$(PATH="$fakebin:$PATH" FM_PIPELINE_FAKE_CAT_COUNT="$count" \
    FM_PIPELINE_FAKE_SHASUM_COUNT="$shasum_count" FM_PIPELINE_EXPECTED_TRUST="$trust" \
    FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "registration failure should fail arming"
  [ "$(cat "$check")" = "$old" ] || fail "registration rollback did not restore the existing check"
  [ -f "$trust" ] || fail "registration rollback removed the existing trust artifact"
  [ "$(cat "$trust")" = "$old_trust" ] || fail "registration rollback did not restore the existing trust artifact"
  pass "fm-pipeline.sh: registration rollback preserves check and trust"
}

test_relative_arm_embeds_absolute_state() {
  local root state output rc=0
  root=$(new_state relative-arm)
  state="$root/state"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  (cd "$TMP_ROOT" && FM_HOME=relative-arm FM_STATE_OVERRIDE=relative-arm/state "$SCRIPT" arm >/dev/null) \
    || fail "relative arming failed"
  output=$(cd / && "$state/pipeline-probe.check.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "an armed check should work from another directory"
  [ -s "$state/pipeline-events.log" ] || fail "relative arming did not preserve the absolute state"
  pass "fm-pipeline.sh: armed checks retain absolute state paths"
}

test_reconcile_ignores_status_testimony() {
  local root output record rc=0
  root=$(new_state reconcile-testimony)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf 'done: finished while a PR remains under review\n' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "reconcile should derive dispatch from metadata"
  record=$(cat "$root/state/task.pipeline")
  assert_contains "$record" 'step=dispatched' "status testimony must not replace the artifact step"
  assert_not_contains "$record" 'status-log' "status-log must never enter the lifecycle record"
  pass "fm-pipeline.sh: reconcile ignores status testimony"
}

test_append_is_not_agent_facing() {
  local root output rc=0
  root=$(new_state append-guard)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append anything 2>&1) || rc=$?
  expect_code 1 "$rc" "append must be guarded from the agent-facing surface"
  assert_contains "$output" 'internal test-only' "append refusal did not name its boundary"
  pass "fm-pipeline.sh: append is guarded"
}

test_legacy_cache_migrates_without_reinterpretation() {
  local root output record cache rc=0
  root=$(new_state legacy-cache)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf 'wait=ext:old step=- gen=- evidence=state/task.status:1 observed_at=1\n' > "$root/state/task.pipeline"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "legacy cache should be migrated on first owner touch"
  [ -f "$root/state/task.pipeline-seen" ] || fail "legacy cache was not moved to pipeline-seen"
  cache=$(cat "$root/state/task.pipeline-seen")
  assert_contains "$cache" 'wait=ext:old' "legacy cache bytes were not preserved"
  record=$(cat "$root/state/task.pipeline")
  assert_contains "$record" 'schema=fm-pipeline.v3' "lifecycle record header was not created"
  assert_not_contains "$record" 'wait=ext:old' "legacy cache was reinterpreted as lifecycle state"
  assert_contains "$output" 'migrated legacy observation cache' "migration was not logged"
  pass "fm-pipeline.sh: legacy observation cache is migrated, not reinterpreted"
}

test_board_json_does_not_migrate_legacy_cache() {
  local root board
  root=$(new_state board-legacy-cache)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf '%s\n' 'wait=ext:old step=- gen=- evidence=state/task.status:1 observed_at=1' > "$root/state/task.pipeline"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[0].record_state == "refused:legacy-cache" and .tasks[0].initialized == false' >/dev/null \
    || fail "board-json did not project an unmigrated legacy cache"
  [ -e "$root/state/task.pipeline" ] || fail "board-json moved the legacy cache"
  [ ! -e "$root/state/task.pipeline-seen" ] || fail "board-json created a cache migration"
  pass "fm-pipeline.sh: board-json does not mutate legacy cache"
}

test_legacy_cache_migration_collision_refuses() {
  local root output before after rc=0
  root=$(new_state migration-collision)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf 'legacy\n' > "$root/state/task.pipeline"
  printf 'existing\n' > "$root/state/task.pipeline-seen"
  before=$(cat "$root/state/task.pipeline")
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "ambiguous cache migration must refuse"
  assert_contains "$output" 'refused:migration-collision' "migration collision was not named"
  after=$(cat "$root/state/task.pipeline")
  [ "$before" = "$after" ] || fail "migration collision changed the legacy file"
  pass "fm-pipeline.sh: migration collision preserves both files"
}

test_probe_reads_owner_record_not_meta_step_claim() {
  local root output line rc=0
  root=$(new_state record-probe)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" "step=merged" "attempt=caller-claim"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the owner record"
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" "step=merged" "attempt=changed-claim"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "probe should use the owner record"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'step=dispatched' "probe trusted the metadata step claim"
  assert_contains "$line" 'gen=gen-1' "probe lost the record generation"
  assert_contains "$line" 'attempt=caller-claim' "probe read attempt from outside the owner record"
  assert_not_contains "$line" 'attempt=changed-claim' "probe trusted the metadata attempt claim"
  pass "fm-pipeline.sh: probe uses lifecycle record fields"
}

test_reconcile_absent_meta_refuses_without_writing() {
  local root output rc=0
  root=$(new_state absent-meta)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "reconcile must refuse absent metadata"
  assert_contains "$output" 'refused:absent-meta-not-cleaned' "absent metadata needs the explicit refusal"
  [ ! -e "$root/state/task.pipeline" ] || fail "absent metadata created a lifecycle record"
  pass "fm-pipeline.sh: absent metadata is not cleaned"
}

test_record_reader_rejects_unproven_hand_append() {
  local root output before after board rc=0
  root=$(new_state unproven-record)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the proven dispatch record"
  {
    cat "$root/state/task.pipeline"
    printf '%s\n' 'rev=2 ts=2026-09-05T00:00:00Z step=merged evidence=forge:x gen=gen-1 head=unknown attempt=-'
  } > "$root/state/task.pipeline.tmp"
  mv "$root/state/task.pipeline.tmp" "$root/state/task.pipeline"
  before=$(cat "$root/state/task.pipeline")
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "unproven hand-written lifecycle lines must refuse"
  assert_contains "$output" 'refused:unproven-step' "the refusal must name the unsupported step"
  after=$(cat "$root/state/task.pipeline")
  [ "$before" = "$after" ] || fail "unproven lifecycle bytes changed"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[0].step_proven == false and .tasks[0].record_state == "refused:unproven-step"' >/dev/null \
    || fail "board-json did not project the refused record"
  pass "fm-pipeline.sh: unproven record lines are refused and projected"
}

test_foreign_generation_is_refused() {
  local root output before after rc=0
  root=$(new_state foreign-generation)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=current"
  printf '%s\n' 'schema=fm-pipeline.v3 task=task kind=ship gen=old' > "$root/state/task.pipeline"
  before=$(cat "$root/state/task.pipeline")
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "foreign generations must refuse"
  assert_contains "$output" 'refused:foreign-gen' "the refusal must name the foreign generation"
  after=$(cat "$root/state/task.pipeline")
  [ "$before" = "$after" ] || fail "foreign-generation bytes changed"
  pass "fm-pipeline.sh: foreign generations are fenced"
}

test_pr_registration_and_merge_artifacts() {
  local root output record rc=0 head
  root=$(new_state pr-artifacts)
  head=0123456789012345678901234567890123456789
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" \
    "pr=https://github.com/example/project/pull/7"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "canonical PR identity should prove registration"
  record=$(cat "$root/state/task.pipeline")
  assert_contains "$record" 'step=pr-registered' "pr registration should be recorded"
  assert_contains "$record" 'head=unknown' "missing PR head must remain unknown"
  assert_not_contains "$record" 'pr-open' "registration must not claim a remote open state"
  printf '%s\n' "pr_head=$head" >> "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "a later PR head must not invalidate an honest unknown receipt"
  fm_write_meta "$root/state/task2.meta" "kind=ship" "spawn_gen=gen-2" \
    "pr=https://github.com/example/project/pull/8" "pr_head=$head"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task2 2>&1) || rc=$?
  expect_code 0 "$rc" "a recorded PR head should be retained"
  assert_contains "$(cat "$root/state/task2.pipeline")" "head=$head" "recorded PR head was lost"
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_poll_merge_mark_notified "$root/state" task2 github github.com example/project 8 \
    || fail "could not create the merge receipt fixture"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task2 2>&1) || rc=$?
  expect_code 0 "$rc" "the merge receipt should prove merge"
  assert_contains "$(cat "$root/state/task2.pipeline")" 'step=merged' "merge receipt was not reconciled"
  pass "fm-pipeline.sh: registration and merge use artifact receipts"
}

test_steps_print_ordered_graph() {
  local root output rc=0
  root=$(new_state steps)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" steps ship-nm 2>&1) || rc=$?
  expect_code 0 "$rc" "steps should print the ship graph"
  assert_contains "$output" 'nodes=dispatched ingress working validating pr-registered checks merge-wait merged' \
    "ship graph nodes are not ordered"
  assert_contains "$output" 'edges=dispatched>ingress' "ship graph edges are missing"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" steps secondmate 2>&1) || rc=$?
  expect_code 0 "$rc" "steps should print the recurring graph"
  assert_contains "$output" 'nodes=session-live inbox-current queue-current reporting' "secondmate graph is incomplete"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" steps unknown 2>&1) || rc=$?
  expect_code 1 "$rc" "unknown pipeline kinds must refuse"
  assert_contains "$output" 'unknown pipeline kind' "unknown pipeline kind was not named"
  pass "fm-pipeline.sh: steps owns ordered nodes and edges"
}

test_probe_cost_fixture_removes_sensor_calls() {
  local root check fake count output rc=0 i start elapsed script_dir
  root=$(new_state probe-cost)
  fake="$root/fake-crew-state.sh"
  count="$root/crew-state-calls"
  : > "$count"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_PIPELINE_TEST_CREW_COUNT:?}"
printf '%s\n' 'state: paused · source: pane · fixture'
EOF
  chmod +x "$fake"
  i=1
  while [ "$i" -le 40 ]; do
    fm_write_meta "$root/state/task-$i.meta" "kind=ship" "spawn_gen=gen-$i"
    printf 'paused: [key=fixture] waiting on the fixture\n' > "$root/state/task-$i.status"
    i=$((i + 1))
  done
  script_dir=$(cd "$(dirname "$SCRIPT")" && pwd)
  mkdir "$root/bin"
  cp -R "$script_dir/." "$root/bin/"
  cp "$fake" "$root/bin/fm-crew-state.sh"
  chmod +x "$root/bin/fm-crew-state.sh"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_TEST_CREW_COUNT="$count" \
    "$root/bin/fm-pipeline.sh" probe >/dev/null \
    || fail "could not initialize the 40-task probe fixture"
  [ "$(wc -l < "$count" | tr -d ' ')" -eq 0 ] \
    || fail "the probe still made crew-state calls"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$root/bin/fm-pipeline.sh" arm >/dev/null \
    || fail "could not arm the cost fixture"
  check="$root/state/pipeline-probe.check.sh"
  start=$(date +%s)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_TEST_CREW_COUNT="$count" \
    "$check" 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "the 40-task check fixture should succeed"
  [ -z "$output" ] || fail "the steady-state fixture emitted output: $output"
  [ "$(wc -l < "$count" | tr -d ' ')" -eq 0 ] \
    || fail "the steady-state probe still made crew-state calls"
  [ "$elapsed" -lt 20 ] || fail "the 40-task check fixture exceeded its smoke bound"
  printf 'pr=https://github.com/example/project/pull/7\n' >> "$root/state/task-1.meta"
  : > "$count"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_TEST_CREW_COUNT="$count" \
    "$check" 2>&1) || rc=$?
  expect_code 0 "$rc" "the changed-artifact fixture should succeed"
  [ "$(wc -l < "$count" | tr -d ' ')" -eq 0 ] \
    || fail "the changed-artifact probe still made crew-state calls"
  assert_contains "$(cat "$root/state/task-1.pipeline")" 'step=pr-registered' \
    "changed artifact did not advance the owner record"
  pass "fm-pipeline.sh: 40-task probes remove crew-state calls"
}

test_board_json_fixture_inventory_and_bound() {
  local root output start elapsed i rc=0
  root=$(new_state board-fixture)
  i=1
  while [ "$i" -le 40 ]; do
    fm_write_meta "$root/state/task-$i.meta" "kind=ship" "spawn_gen=gen-$i"
    i=$((i + 1))
  done
  start=$(date +%s)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "board-json should scan the fixture"
  [ "$elapsed" -lt 20 ] || fail "board-json exceeded the 20 second fixture bound"
  printf '%s' "$output" | jq -e '.generated_epoch > 0 and (.tasks | length) == 40 and all(.tasks[]; .initialized == false and .crew_state == {verb:"unavailable",source:"-",ts:"-"}) and (.tasks[0].steps.nodes | length) == 8' >/dev/null \
    || fail "board-json did not include the complete uninitialized inventory"
  pass "fm-pipeline.sh: board-json covers 40 tasks within the smoke bound"
}

test_quiet_registered_probe_and_refusal_projection() {
  local root check output board err rc=0
  root=$(new_state quiet-probe)
  fm_write_meta "$root/state/good.meta" "kind=ship" "spawn_gen=good-gen"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile good >/dev/null \
    || fail "could not initialize the healthy fixture"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm the real probe shim"
  check="$root/state/pipeline-probe.check.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$check" 2>&1) || rc=$?
  expect_code 0 "$rc" "a healthy registered probe should succeed"
  [ -z "$output" ] || fail "an unchanged probe emitted actionable stdout: $output"
  fm_write_meta "$root/state/bad.meta" "kind=ship" "spawn_gen=bad-gen"
  {
    printf '%s\n' 'schema=fm-pipeline.v3 task=bad kind=ship gen=bad-gen'
    printf '%s\n' broken
  } > "$root/state/bad.pipeline"
  printf 'paused: [key=bad-wait] waiting on the bad record\n' > "$root/state/bad.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$check" 2>&1) || rc=$?
  expect_code 0 "$rc" "a refusal in the probe should not wake the watcher"
  [ -z "$output" ] || fail "a refused probe emitted actionable stdout: $output"
  [ ! -e "$root/state/pipeline-events.log" ] || fail "a refused probe wrote a lifecycle event"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "bad") | .record_state == "refused:malformed-record-line"' >/dev/null \
    || fail "board-json did not expose the malformed record"
  err=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile bad 2>&1) || rc=$?
  assert_contains "$err" 'refused:malformed-record-line' "direct reconcile did not expose the refusal"
  assert_contains "$err" 'repair:' "direct reconcile omitted the repair path"
  pass "fm-pipeline.sh: registered probe stays quiet while board-json exposes refusal"
}

test_retire_owner_records() {
  local root output rc=0
  root=$(new_state retire-record)
  printf '%s\n' legacy > "$root/state/task.pipeline-seen"
  printf '%s\n' legacy > "$root/state/task.pipeline"
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" retire task 2>&1) || rc=$?
  expect_code 1 "$rc" "retire must refuse a live metadata row"
  [ -e "$root/state/task.pipeline" ] && [ -e "$root/state/task.pipeline-seen" ] \
    || fail "live metadata refusal removed owner records"
  rm -f "$root/state/task.meta"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" retire task 2>&1) || rc=$?
  expect_code 0 "$rc" "retire should remove stale owner records"
  [ ! -e "$root/state/task.pipeline" ] && [ ! -e "$root/state/task.pipeline-seen" ] \
    || fail "retire left owner records behind"
  pass "fm-pipeline.sh: retire is generation-safe"
}

test_pipeline_pure_function_units() {
  local root output
  root=$(new_state pure-units)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_SOURCE_ONLY=1 \
    bash -c '
      set -u
      source "$1"
      state=$2
      cat > "$state/task.pipeline" <<EOF
schema=fm-pipeline.v3 task=task kind=ship gen=gen-1
EOF
      valid="rev=1 ts=2026-09-05T00:00:00Z step=dispatched evidence=meta:state/task.meta gen=gen-1 head=unknown attempt=-"
      pipeline_record_reset
      good_rc=0
      pipeline_record_line_load "$valid" "$state/task.pipeline" 2 gen-1 || good_rc=$?
      bad_rc=0
      pipeline_record_line_load "rev=2 ts=2026-09-05T00:00:00Z step=unknown evidence=meta:state/task.meta gen=gen-1 head=unknown attempt=-" "$state/task.pipeline" 3 gen-1 || bad_rc=$?
      header_rc=0
      pipeline_record_header_valid "$state/task.pipeline" task ship gen-2 || header_rc=$?
      printf "%s\n" "record_rc=$good_rc step=$PIPELINE_RECORD_STEP" "bad_rc=$bad_rc header_rc=$header_rc"
      printf "%s\n" kind=ship spawn_gen=gen-1 > "$state/task.meta"
      pipeline_meta_cache_load "$state/task.meta" 1
      dispatched_rc=0
      pipeline_predicate_dispatched "$state/task.meta" || dispatched_rc=$?
      printf "predicate_dispatched_rc=%s\n" "$dispatched_rc"
      printf "derived=%s\n" "$(pipeline_derived_step task "$state/task.meta" ship)"
      printf "%s\n" pr=https://github.com/example/project/pull/7 >> "$state/task.meta"
      pipeline_meta_cache_load "$state/task.meta" 1
      registered_rc=0
      pipeline_predicate_pr_registered "$state/task.meta" || registered_rc=$?
      printf "predicate_registered_rc=%s\n" "$registered_rc"
      printf "derived=%s\n" "$(pipeline_derived_step task "$state/task.meta" ship)"
      fm_pr_poll_merge_mark_notified "$state" task github github.com example/project 7
      merged_rc=0
      pipeline_predicate_merged task "$state/task.meta" || merged_rc=$?
      printf "predicate_merged_rc=%s\n" "$merged_rc"
      printf "derived=%s\n" "$(pipeline_derived_step task "$state/task.meta" ship)"
      tsv=$(pipeline_kind_steps ship)
      tab=$(printf "\\t")
      IFS="$tab" read -r nodes edges <<EOF
$tsv
EOF
      printf "tsv=%s|%s\n" "$nodes" "$edges"
      printf "kind=ship\tinvented\nspawn_gen=actual\n" > "$state/tab.meta"
      tab_rc=0
      pipeline_meta_cache_load "$state/tab.meta" 1 || tab_rc=$?
      printf "tab_rc=%s\n" "$tab_rc"
    ' _ "$SCRIPT" "$root/state")
  assert_contains "$output" 'record_rc=0 step=dispatched' "record parser unit did not accept the valid line"
  assert_contains "$output" 'bad_rc=1 header_rc=2' "record/header unit refusals were not exercised"
  assert_contains "$output" 'derived=dispatched' "step derivation unit missed dispatch"
  assert_contains "$output" 'predicate_dispatched_rc=0' "dispatched predicate unit failed"
  assert_contains "$output" 'predicate_registered_rc=0' "PR predicate unit failed"
  assert_contains "$output" 'predicate_merged_rc=0' "merge predicate unit failed"
  assert_contains "$output" 'derived=pr-registered' "step derivation unit missed PR registration"
  assert_contains "$output" 'derived=merged' "step derivation unit missed merge proof"
  assert_contains "$output" 'tsv=dispatched ingress working validating pr-registered checks merge-wait merged|dispatched>ingress ingress>working working>validating validating>pr-registered pr-registered>checks checks>merge-wait merge-wait>merged' "TSV step graph unit did not preserve both fields"
  assert_contains "$output" 'tab_rc=2' "scalar parser unit did not reject a tab"
  pass "fm-pipeline.sh: pure record, derivation, header, and scalar units pass"
}

s6_write_task() {
  local root=$1 id=$2 gen=$3
  printf 'kind=ship\nspawn_gen=%s\n' "$gen" > "$root/state/$id.meta"
  printf 'paused: [key=x] waiting on the fixture\n' > "$root/state/$id.status"
}

s6_rewrite_record_ts() {
  local file=$1 ts=$2
  awk -v ts="$ts" 'NR == 2 { sub(/ts=[^ ]+/, "ts=" ts) } { print }' \
    "$file" > "$file.next" || fail "could not rewrite the record timestamp fixture"
  mv -- "$file.next" "$file" || fail "could not install the record timestamp fixture"
}

s6_probe() {
  local root=$1 output rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "the S6 probe fixture should succeed"
}

test_s6_pure_since_unit() {
  local root output
  root=$(new_state s6-pure)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_SOURCE_ONLY=1 \
    bash -c '
      set -u
      source "$1"
      valid_rc=0
      valid=$(pipeline_since_from_ts 1970-01-01T00:15:00Z 1000) || valid_rc=$?
      invalid_rc=0
      invalid=$(pipeline_since_from_ts 2026-99-99T00:00:00Z 2000) || invalid_rc=$?
      future_rc=0
      future=$(pipeline_since_from_ts 2099-01-01T00:00:00Z 2000) || future_rc=$?
      printf "valid=%s/%s invalid=%s/%s future=%s/%s\\n" \
        "$valid" "$valid_rc" "$invalid" "$invalid_rc" "$future" "$future_rc"
    ' _ "$SCRIPT")
  assert_contains "$output" 'valid=100/0 invalid=0/1 future=0/1' \
    "since conversion did not distinguish valid, invalid, and future timestamps"
  pass "fm-pipeline.sh: since conversion handles valid, invalid, and future timestamps"
}

test_s6_since_uses_record_step_timestamp() {
  local root now old_ts output line since cache_now fakebin real_date
  root=$(new_state s6-since)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  now=$(date +%s)
  old_ts=$(node -e 'process.stdout.write(new Date((Number(process.argv[1]) - 100) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"))' "$now")
  s6_rewrite_record_ts "$root/state/task.pipeline" "$old_ts"
  cache_now=$((now - 10))
  printf 'wait=ext:x step=dispatched gen=gen-1 evidence=state/task.status:1 observed_at=%s\n' \
    "$cache_now" > "$root/state/task.pipeline-seen"
  fakebin="$root/fakebin"
  real_date=$(command -v date) || fail "no date command for the clock fixture"
  mkdir -p "$fakebin"
  cat > "$fakebin/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ]; then
  printf '%s\n' "${FM_PIPELINE_TEST_NOW:?}"
else
  exec "${FM_PIPELINE_REAL_DATE:?}" "$@"
fi
EOF
  chmod +x "$fakebin/date"
  output=$(PATH="$fakebin:$PATH" FM_PIPELINE_TEST_NOW="$now" FM_PIPELINE_REAL_DATE="$real_date" \
    FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || \
    fail "the fixed-clock probe failed: $output"
  line=$(tail -1 "$root/state/pipeline-events.log")
  since=$(printf '%s\n' "$line" | awk '{for (i=1; i<=NF; i++) if ($i ~ /^since=/) { sub(/^since=/, "", $i); print $i; exit }}')
  [ "$since" = 100 ] || fail "since was not exactly now minus the record step timestamp: $line"
  [ "$since" -ne 10 ] || fail "since still used the observation cache age"
  pass "fm-pipeline.sh: since follows the current record step timestamp"
}

test_s6_invalid_future_and_uninitialized_timestamps() {
  local root line output events
  root=$(new_state s6-uninitialized)
  printf '%s\n' 'paused: [key=x] waiting' > "$root/state/task.status"
  s6_probe "$root"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'since=0' "an uninitialized task needs zero duration"
  assert_contains "$line" 'probe=unknown' "an uninitialized task needs an unknown probe"
  printf '%s\n' 'working [key=x]: resumed' >> "$root/state/task.status"
  s6_probe "$root"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'probe=unknown' "an uninitialized closure must remain unknown"
  assert_not_contains "$line" 'probe=ok' "an uninitialized closure must not claim a resume"
  assert_not_contains "$(cat "$root/state/task.pipeline-seen")" 'closed_at=' \
    "an uninitialized closure must leave the cache open"

  root=$(new_state s6-future)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  s6_rewrite_record_ts "$root/state/task.pipeline" 2099-01-01T00:00:00Z
  events=$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')
  s6_probe "$root"
  [ "$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')" -eq $((events + 1)) ] \
    || fail "an invalid active clock emitted a duplicate unknown row"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'since=0' "a future record timestamp must have zero duration"
  assert_contains "$line" 'probe=unknown' "a future record timestamp must remain unknown"
  assert_contains "$line" 'evidence=state/task.pipeline:2' "future-clock evidence must cite the record line"
  printf '%s\n' 'working [key=x]: resumed' >> "$root/state/task.status"
  s6_probe "$root"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'since=0' "a future-clock closure must have zero duration"
  assert_contains "$line" 'probe=unknown' "a future-clock closure must remain unknown"
  assert_not_contains "$line" 'probe=ok' "a future-clock closure must not claim a resume"
  now=$(date +%s)
  old_ts=$(node -e 'process.stdout.write(new Date((Number(process.argv[1]) - 100) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"))' "$now")
  s6_rewrite_record_ts "$root/state/task.pipeline" "$old_ts"
  s6_probe "$root"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'probe=ok' "a later valid clock must close the retained occurrence"
  assert_contains "$(cat "$root/state/task.pipeline-seen")" 'closed_at=' \
    "a later valid clock must mark the occurrence closed"

  root=$(new_state s6-invalid)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  s6_rewrite_record_ts "$root/state/task.pipeline" 2026-99-99T00:00:00Z
  s6_probe "$root"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'since=0' "an unparseable record timestamp must have zero duration"
  assert_contains "$line" 'probe=unknown' "an unparseable record timestamp must remain unknown"
  assert_contains "$line" 'evidence=state/task.pipeline:2' "invalid-clock evidence must cite the record line"

  root=$(new_state s6-header-evidence)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  rm -f "$root/state/task.meta"
  s6_probe "$root"
  assert_contains "$(tail -2 "$root/state/pipeline-events.log")" 'evidence=state/task.pipeline:1' \
    "a record without a step line must cite the header, not line zero"
  rm -f "$root/state/task.pipeline"
  s6_probe "$root"
  assert_not_contains "$(tail -2 "$root/state/pipeline-events.log")" 'state/task.pipeline:1' \
    "an absent record must not cite a nonexistent header"
  assert_contains "$(tail -2 "$root/state/pipeline-events.log")" 'evidence=state/task.status:1' \
    "an absent record must cite the cached pause evidence"
  pass "fm-pipeline.sh: invalid, future, and uninitialized clocks remain unknown"
}

test_s6_occurrence_closures() {
  local root line events cache ok_count bad_evidence
  root=$(new_state s6-closure)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  printf '%s\n' 'working [key=x]: resumed' >> "$root/state/task.status"
  s6_probe "$root"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'probe=ok' "a later working line must close the cached pause"
  assert_contains "$line" 'evidence=state/task.status:2' "closure must cite its resume line"
  cache="$root/state/task.pipeline-seen"
  assert_contains "$(cat "$cache")" 'closed_at=2' "closure did not mark the cache occurrence"
  events=$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')
  s6_probe "$root"
  [ "$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')" -eq "$events" ] \
    || fail "a marked occurrence emitted a duplicate closure"

  root=$(new_state s6-replaced-pause)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  printf '%s\n' 'paused [key=x]: refreshed pause' >> "$root/state/task.status"
  s6_probe "$root"
  printf '%s\n' 'working [key=x]: resumed after refresh' >> "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok.*evidence=state/task.status:3.*wait=ext:x' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "the newest pause did not close exactly once at the working line"
  [ "$(rg -c 'probe=unknown.*evidence=state/task.status:1.*wait=ext:x' "$root/state/pipeline-events.log")" -eq 2 ] \
    || fail "the replaced pause did not remain unknown"
  [ "$(rg -c 'closed_at=3' "$root/state/task.pipeline-seen")" -eq 1 ] \
    || fail "the replaced pause row was incorrectly closed"

  for bad_evidence in 00 junk:1; do
    root=$(new_state "s6-corrupt-${bad_evidence//:/-}")
    s6_write_task "$root" task gen-1
    s6_probe "$root"
    if [ "$bad_evidence" = 00 ]; then
      printf '%s\n' 'working [key=x]: resumed' > "$root/state/task.status"
    else
      printf '%s\n' 'paused [key=x]: waiting' 'working [key=x]: resumed' > "$root/state/task.status"
    fi
    printf 'wait=ext:x step=dispatched gen=gen-1 evidence=state/task.status:%s observed_at=0\n' \
      "$bad_evidence" > "$root/state/task.pipeline-seen"
    s6_probe "$root"
    ok_count=$(rg -c 'probe=ok' "$root/state/pipeline-events.log" || true)
    [ "${ok_count:-0}" -eq 0 ] || fail "corrupt cache evidence $bad_evidence invented a closure"
    [ "$(rg -c "probe=unknown.*evidence=state/task.status:$bad_evidence" "$root/state/pipeline-events.log")" -eq 1 ] \
      || fail "corrupt cache evidence $bad_evidence did not remain unknown"
    assert_not_contains "$(cat "$root/state/task.pipeline-seen")" 'closed_at=' \
      "corrupt cache evidence $bad_evidence was marked closed"
  done

  root=$(new_state s6-observer-stopped)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  [ "$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')" -eq 1 ] \
    || fail "the stopped observer did not leave one observation"

  root=$(new_state s6-sibling)
  printf '%s\n' 'paused [key=x]: waiting' 'paused [key=y]: waiting' > "$root/state/task.status"
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  s6_probe "$root"
  printf '%s\n' 'working [key=x]: resumed' >> "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok.*wait=ext:x' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "the resumed sibling did not close"
  [ "$(rg -c 'probe=ok.*wait=ext:y' "$root/state/pipeline-events.log" 2>/dev/null || printf 0)" -eq 0 ] \
    || fail "the still-paused sibling was closed"

  root=$(new_state s6-note)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  printf '%s\n' 'note [key=x]: progress' >> "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok' "$root/state/pipeline-events.log" 2>/dev/null || printf 0)" -eq 0 ] \
    || fail "a keyed note closed the active pause"
  assert_not_contains "$(cat "$root/state/task.pipeline-seen")" 'closed_at=' \
    "a keyed note marked the active occurrence closed"

  root=$(new_state s6-step-change)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  printf '%s\n' 'pr=https://github.com/example/project/pull/7' >> "$root/state/task.meta"
  s6_probe "$root"
  printf '%s\n' 'working [key=x]: resumed' >> "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "a step change emitted more than one closure"
  [ "$(rg -c '^wait=ext:x .*evidence=state/task.status:1 .*closed_at=2' "$root/state/task.pipeline-seen")" -eq 2 ] \
    || fail "all cache rows for one occurrence were not marked closed"

  root=$(new_state s6-missed-intermediate)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  printf '%s\n' 'working [key=x]: resumed' 'paused [key=x]: waiting again' >> "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok.*evidence=state/task.status:2' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "the missed intermediate resume was not cited"
  assert_not_contains "$(rg '^wait=ext:x .*evidence=state/task.status:3' "$root/state/task.pipeline-seen")" 'closed_at=' \
    "the new occurrence was closed by the old resume"
  printf '%s\n' 'working [key=x]: resumed again' >> "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok.*evidence=state/task.status:4' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "the second occurrence did not close at its own resume"
  [ "$(rg -c 'probe=ok' "$root/state/pipeline-events.log")" -eq 2 ] \
    || fail "missed intermediate emitted the wrong number of closures"

  root=$(new_state s6-repeated)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  printf '%s\n' 'working [key=x]: first' >> "$root/state/task.status"
  s6_probe "$root"
  printf '%s\n' 'paused [key=x]: second' >> "$root/state/task.status"
  s6_probe "$root"
  printf '%s\n' 'working [key=x]: second resume' >> "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok.*wait=ext:x' "$root/state/pipeline-events.log")" -eq 2 ] \
    || fail "repeated pause/resume did not produce two closures"
  [ "$(rg -c 'probe=ok.*evidence=state/task.status:2' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "first repeated closure cited the wrong line"
  [ "$(rg -c 'probe=ok.*evidence=state/task.status:4' "$root/state/pipeline-events.log")" -eq 1 ] \
    || fail "second repeated closure cited the wrong line"

  root=$(new_state s6-truncated)
  s6_write_task "$root" task gen-1
  s6_probe "$root"
  printf '%s\n' 'note: rewritten without the pause' > "$root/state/task.status"
  s6_probe "$root"
  [ "$(rg -c 'probe=ok' "$root/state/pipeline-events.log" 2>/dev/null || printf 0)" -eq 0 ] \
    || fail "a truncated log produced a false closure"
  assert_contains "$(tail -1 "$root/state/pipeline-events.log")" 'probe=unknown' \
    "a truncated log did not remain unknown"
  assert_contains "$(tail -1 "$root/state/pipeline-events.log")" 'evidence=state/task.status:1' \
    "a truncated log did not cite the cached pause line"
  assert_not_contains "$(cat "$root/state/task.pipeline-seen")" 'closed_at=' \
    "a truncated log closed its cache row"

  root=$(new_state s6-stale-gen)
  s6_write_task "$root" task gen-new
  s6_probe "$root"
  printf 'wait=ext:x step=dispatched gen=gen-old evidence=state/task.status:1 observed_at=1\n' \
    > "$root/state/task.pipeline-seen"
  s6_probe "$root"
  assert_contains "$(tail -2 "$root/state/pipeline-events.log")" 'evidence=state/task.pipeline:2' \
    "a stale generation did not cite the current record line"
  assert_not_contains "$(tail -2 "$root/state/pipeline-events.log")" 'probe=ok' \
    "a stale generation produced a closure"
  pass "fm-pipeline.sh: closures are occurrence-bound, idempotent, and conservative"
}

test_pipeline_lock_timeout_validation() {
  local root output
  root=$(new_state lock-timeout-units)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_SOURCE_ONLY=1 \
    bash -c '
      set -u
      source "$1"
      check() {
        local label=$1 result
        shift
        if result=$(pipeline_lock_timeout_validate "$@"); then
          printf "%s=%s\\n" "$label" "$result"
        else
          printf "%s=refused\\n" "$label"
        fi
      }
      check unset
      check empty ""
      check one 1
      check ten 10
      check zero 0
      check double-zero 00
      check plus +1
      check negative -1
      check decimal 1.5
      check alpha abc
    ' _ "$SCRIPT")
  assert_contains "$output" 'unset=10' "unset lock timeout did not default to 10"
  assert_contains "$output" 'empty=refused' "empty lock timeout was accepted"
  assert_contains "$output" 'one=1' "positive lock timeout was refused"
  assert_contains "$output" 'ten=10' "ten-second lock timeout was refused"
  assert_contains "$output" 'zero=refused' "zero lock timeout was accepted"
  assert_contains "$output" 'double-zero=refused' "double-zero lock timeout was accepted"
  assert_contains "$output" 'plus=refused' "plus-prefixed lock timeout was accepted"
  assert_contains "$output" 'negative=refused' "negative lock timeout was accepted"
  assert_contains "$output" 'decimal=refused' "decimal lock timeout was accepted"
  assert_contains "$output" 'alpha=refused' "non-numeric lock timeout was accepted"
  pass "fm-pipeline.sh: lock timeout validation accepts only positive integer seconds"
}

test_pipeline_restart_recovery() {
  local root fakebin ready hold target writer pgid lock_pid before after event_size event_tmp temp candidate orphan_before orphan_after header revs board output rc=0 i=0
  root=$(new_state restart-recovery)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the complete pre-crash record"
  before=$(shasum -a 256 "$root/state/task.pipeline")
  printf '%s\n' 'pr=https://github.com/example/project/pull/7' >> "$root/state/task.meta"
  fakebin="$root/fake-bin"
  ready="$root/mv-ready"
  hold="$root/mv-hold"
  target="$root/state/task.pipeline"
  mkdir -p "$fakebin"
  : > "$ready"
  mkfifo "$hold" || fail "could not create the writer barrier"
  cat > "$fakebin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "${4:-}" = "${FM_PIPELINE_TEST_RECORD_TARGET:-}" ]; then
  awk 'NR == 3 { sub(/ts=[^ ]+/, "ts=2099-01-01T00:00:00Z") } { print }' "$3" > "$3.changed"
  /bin/mv -- "$3.changed" "$3"
  printf '%s\n' ready > "$FM_PIPELINE_TEST_MV_READY"
  cat "$FM_PIPELINE_TEST_MV_HOLD" >/dev/null
fi
exec /bin/mv "$@"
EOF
  chmod +x "$fakebin/mv"
  set -m
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" PATH="$fakebin:$PATH" \
    FM_PIPELINE_TEST_RECORD_TARGET="$target" FM_PIPELINE_TEST_MV_READY="$ready" \
    FM_PIPELINE_TEST_MV_HOLD="$hold" "$SCRIPT" reconcile task >"$root/writer.out" 2>"$root/writer.err" &
  writer=$!
  pgid=$(ps -o pgid= -p "$writer" 2>/dev/null | tr -d '[:space:]')
  [ "$pgid" = "$writer" ] || fail "writer did not get a dedicated process group"
  while [ ! -s "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -s "$ready" ] || fail "writer never reached the temp-to-record barrier"
  [ -d "$root/state/pipeline-events.log.lock" ] || fail "writer lock was absent before restart"
  lock_pid=$(cat "$root/state/pipeline-events.log.lock/pid")
  [ "$lock_pid" = "$writer" ] || fail "writer lock did not name the fixture writer"
  kill -KILL -- "-$pgid" 2>/dev/null || fail "could not kill the fixture writer process group"
  wait "$writer" 2>/dev/null || true
  set +m
  after=$(shasum -a 256 "$target")
  [ "$after" = "$before" ] || fail "killed writer changed the canonical record"
  temp=
  for candidate in "$root/state"/.fm-pipeline-record.*; do
    [ -f "$candidate" ] || continue
    temp=$candidate
    break
  done
  [ -n "$temp" ] || fail "killed writer did not leave its private temp"
  orphan_before=$(shasum -a 256 "$temp" | awk '{print $1}')
  assert_contains "$(cat "$temp")" 'ts=2099-01-01T00:00:00Z' "the abandoned temp was not a valid distinguishable record"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "reconcile should recover after the writer process tree was killed"
  assert_contains "$output" 'step=pr-registered rev=2' "restart recovery did not append the intended next step"
  assert_not_contains "$(cat "$target")" 'ts=2099-01-01T00:00:00Z' "the orphan timestamp reached the canonical record"
  orphan_after=$(shasum -a 256 "$temp" | awk '{print $1}')
  [ "$orphan_after" = "$orphan_before" ] || fail "recovery consumed or changed the abandoned temp"
  header=$(head -n 1 "$target")
  [ "$header" = 'schema=fm-pipeline.v3 task=task kind=ship gen=gen-1' ] || fail "restart recovery changed the canonical header"
  revs=$(awk 'NR > 1 { print $1 }' "$target")
  [ "$revs" = $'rev=1\nrev=2' ] || fail "restart recovery did not preserve the exact rev sequence"
  [ "$(wc -l < "$target" | tr -d ' ')" -eq 3 ] || fail "restart recovery produced duplicate or missing record lines"
  [ ! -d "$root/state/pipeline-events.log.lock" ] || fail "stale owner lock was not reclaimed"

  root=$(new_state restart-corruption)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the corruption-control record"
  printf '%s' 'rev=2 ts=2026-09-05T00:00:00Z step=dispatched evidence=meta:' >> "$root/state/task.pipeline"
  before=$(shasum -a 256 "$root/state/task.pipeline")
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "a truncated canonical record must refuse"
  assert_contains "$output" 'refused:malformed-record-line' "truncated record refusal was not named"
  assert_contains "$output" 'repair:' "truncated record refusal omitted repair guidance"
  [ "$(shasum -a 256 "$root/state/task.pipeline")" = "$before" ] \
    || fail "malformed record refusal changed canonical bytes"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "task") | .record_state == "refused:malformed-record-line" and .step_proven == false' >/dev/null \
    || fail "board-json did not project the corruption refusal"

  root=$(new_state restart-event-tail)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf '%s\n' 'paused: [key=tail] waiting for the fixture' > "$root/state/task.status"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe >/dev/null \
    || fail "could not create the event-tail fixture"
  before=$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')
  [ "$before" -gt 0 ] || fail "event-tail fixture did not create an event"
  event_size=$(wc -c < "$root/state/pipeline-events.log" | tr -d ' ')
  event_tmp="$root/state/pipeline-events.log.partial"
  head -c $((event_size - 8)) "$root/state/pipeline-events.log" > "$event_tmp"
  mv -- "$event_tmp" "$root/state/pipeline-events.log"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a partial event tail should not stop the next append"
  assert_contains "$output" 'malformed shadow event' "partial event tail was not reported by name"
  after=$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')
  [ "$after" -eq $((before + 1)) ] || fail "next event merged into the partial log tail"
  [ "$(tail -c 1 "$root/state/pipeline-events.log" | od -An -tx1 | tr -d '[:space:]')" = 0a ] \
    || fail "event log did not end on a complete line"

  root=$(new_state restart-tail-read)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf '%s\n' 'paused: [key=tail] waiting for the fixture' > "$root/state/task.status"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe >/dev/null \
    || fail "could not create the tail-read fixture"
  before=$(shasum -a 256 "$root/state/pipeline-events.log")
  fakebin="$root/fake-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tail" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
  chmod +x "$fakebin/tail"
  rc=0
  output=$(PATH="$fakebin:$PATH" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "a tail read failure must refuse the append"
  assert_contains "$output" 'cannot append event log' "tail read failure was not surfaced"
  [ "$(shasum -a 256 "$root/state/pipeline-events.log")" = "$before" ] \
    || fail "tail read failure changed the event log"
  pass "fm-pipeline.sh: killed-writer restart, corruption refusal, and partial-log recovery pass"
}

test_reconcile_serializes_owner_transaction() {
  local root gate second_ready p1 p2 rc1 rc2
  root=$(new_state reconcile-transaction)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the initial dispatch record"
  printf '%s\n' 'pr=https://github.com/example/project/pull/7' >> "$root/state/task.meta"
  gate="$root/reconcile-gate"
  : > "$gate"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/first.out" 2>"$root/first.err") &
  p1=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "first reconcile did not reach the owner gate"
  second_ready="$root/second.ready"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_BEFORE_LOCK_READY="$second_ready" \
    "$SCRIPT" reconcile task >"$root/second.out" 2>"$root/second.err") &
  p2=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$second_ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$second_ready" ] || fail "second reconcile did not reach the lock boundary"
  rm -f "$gate"
  rc1=0; rc2=0
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  expect_code 0 "$rc1" "the first serialized reconcile should succeed"
  expect_code 0 "$rc2" "the second serialized reconcile should succeed"
  [ "$(rg -c '^rev=' "$root/state/task.pipeline")" -eq 2 ] \
    || fail "serialized reconciles did not produce exactly one new revision"
  assert_contains "$(cat "$root/second.out")" 'unchanged: task step=pr-registered rev=2' \
    "the losing reconcile did not observe the committed revision"
  pass "fm-pipeline.sh: reconcile serializes load, derive, and append"
}

test_reconcile_rechecks_metadata_inside_owner_transaction() {
  local root gate output pid rc=0 lines
  root=$(new_state reconcile-meta-race)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the initial record"
  gate="$root/reconcile-gate"
  : > "$gate"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/race.out" 2>&1) &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "metadata race did not reach the owner gate"
  printf '%s\n' 'kind=ship' 'spawn_gen=gen-2' > "$root/state/task.meta.next"
  mv "$root/state/task.meta.next" "$root/state/task.meta"
  rm -f "$gate"
  wait "$pid" || rc=$?
  expect_code 1 "$rc" "a generation replacement must refuse"
  assert_contains "$(cat "$root/race.out")" 'refused:foreign-gen' \
    "generation replacement was not fenced"
  lines=$(rg -c '^rev=' "$root/state/task.pipeline")
  [ "$lines" -eq 1 ] || fail "generation replacement appended a stale revision"

  rm -f "$root/state/task.meta"
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  rm -f "$root/state/task.pipeline"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not reset the metadata race fixture"
  gate="$root/reconcile-remove-gate"
  rm -f "$gate.ready"
  : > "$gate"
  rc=0
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/remove.out" 2>&1) &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "metadata removal did not reach the owner gate"
  rm -f "$root/state/task.meta" "$gate"
  wait "$pid" || rc=$?
  expect_code 1 "$rc" "metadata removal must refuse"
  assert_contains "$(cat "$root/remove.out")" 'refused:absent-meta-not-cleaned' \
    "metadata removal was not fenced"
  [ "$(rg -c '^rev=' "$root/state/task.pipeline")" -eq 1 ] \
    || fail "metadata removal appended a stale revision"
  pass "fm-pipeline.sh: reconcile rechecks metadata under the owner lock"
}

test_reconcile_refuses_same_generation_artifact_change() {
  local root gate output pid rc=0
  root=$(new_state reconcile-artifact-race)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" \
    "pr=https://github.com/example/project/pull/7"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the registered record"
  gate="$root/reconcile-gate"
  : > "$gate"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/race.out" 2>&1) &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "artifact race did not reach the refresh boundary"
  printf '%s\n' 'kind=ship' 'spawn_gen=gen-1' > "$root/state/task.meta.next"
  mv "$root/state/task.meta.next" "$root/state/task.meta"
  rm -f "$gate"
  wait "$pid" || rc=$?
  expect_code 1 "$rc" "a same-generation artifact removal must refuse"
  assert_contains "$(cat "$root/race.out")" 'refused:unproven-step' \
    "artifact removal was not checked before record proof"
  [ "$(rg -c '^rev=' "$root/state/task.pipeline")" -eq 1 ] \
    || fail "same-generation artifact removal appended a regressed step"
  pass "fm-pipeline.sh: reconcile proves records against refreshed artifacts"
}

test_meta_scalar_tabs_refuse_before_cache_parse() {
  local root output rc=0
  root=$(new_state scalar-tabs)
  printf 'kind=ship\tinvented\nspawn_gen=actual\n' > "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "a tabbed metadata scalar must refuse"
  assert_contains "$output" 'refused:malformed-meta-artifact' \
    "tabbed metadata did not name the malformed scalar"
  [ ! -e "$root/state/task.pipeline" ] || fail "tabbed metadata invented a lifecycle record"
  pass "fm-pipeline.sh: metadata scalar tabs fail before serialization"
}

test_absent_home_reconcile_does_not_recreate_state() {
  local root output rc=0 verb
  root="$TMP_ROOT/missing-home"
  for verb in reconcile retire board-json; do
    rc=0
    if [ "$verb" = board-json ]; then
      output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" "$verb" 2>&1) || rc=$?
    else
      output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" "$verb" task 2>&1) || rc=$?
    fi
    expect_code 1 "$rc" "$verb must refuse a missing home"
    [ ! -e "$root" ] || fail "absent-home $verb recreated the home"
  done
  pass "fm-pipeline.sh: absent-home non-creating verbs preserve state"
}

test_board_filters_observations_by_generation() {
  local root board
  root=$(new_state board-generation)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-new"
  printf '%s\n' \
    'ts=2026-09-05T00:00:00Z task=task kind=ship step=dispatched since=1 probe=stall rule=recheck-external action=would-heal mode=shadow evidence=state/task.status:1 gen=gen-old attempt=- wait=ext:old snap=-' \
    > "$root/state/pipeline-events.log"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[0].waits == [] and .tasks[0].probe_last == null' >/dev/null \
    || fail "board-json projected an old-generation observation as current"
  pass "fm-pipeline.sh: board observations are generation-fenced"
}

test_board_projects_unknown_and_kind_inconsistent_tasks() {
  local root board output rc=0
  root=$(new_state board-kinds)
  fm_write_meta "$root/state/good.meta" "kind=ship" "spawn_gen=good-gen"
  fm_write_meta "$root/state/bad.meta" "kind=unrecognized" "spawn_gen=bad-gen"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks | length == 2 and any(.[]; .id == "bad" and .record_state == "refused:unknown-pipeline-kind" and .steps.nodes == [])' >/dev/null \
    || fail "board-json did not preserve the unknown kind per task"
  fm_write_meta "$root/state/mate.meta" "kind=secondmate" "spawn_gen=mate-gen"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile mate 2>&1) || rc=$?
  expect_code 1 "$rc" "secondmate must not invent a dispatched lifecycle step"
  assert_contains "$output" 'refused:no-proven-artifact' "secondmate refusal was not explicit"
  [ ! -e "$root/state/mate.pipeline" ] || fail "secondmate received a ship lifecycle record"
  pass "fm-pipeline.sh: board and reconcile honor per-kind lifecycle graphs"
}

test_registered_check_reaches_watcher() {
  local dir state fakebin out pid i
  dir=$(make_case pipeline-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the task status marker"

  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$state/pipeline-events.log" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$state/pipeline-events.log" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not invoke the registered pipeline check"
  fi
  [ -f "$state/pipeline-probe.check.sh" ] || fail "watcher did not create the pipeline check"
  [ -f "$state/pipeline-probe.check-trust" ] || fail "watcher did not register the pipeline check"
  printf 'done: finished\n' >> "$state/task.status"
  wait_for_exit "$pid" 40 || fail "watcher did not exit after the integration signal"
  grep -F 'wait=ext:vendor-release' "$state/pipeline-events.log" >/dev/null \
    || fail "watcher invocation did not produce a pipeline event"
  rg -F 'step=dispatched' "$state/task.pipeline" >/dev/null \
    || fail "watcher invocation did not reconcile the lifecycle record"
  pass "fm-watch.sh: registered pipeline check reaches the probe and reconciles"
}

test_arm_refusal_watcher_reaches_supervision() {
  local dir state fakebin out pid content
  dir=$(make_case pipeline-watcher-arm-refused)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the task status marker"

  printf '#!/usr/bin/env bash\necho foreign\n' > "$state/pipeline-probe.check.sh"
  chmod 0600 "$state/pipeline-probe.check.sh"
  content=$(cat "$state/pipeline-probe.check.sh")

  # A not-due check cadence, PLUS a freshly touched .last-check, keeps the
  # unauthenticated-foreign-shim scan (fm-watch.sh:2072,2134-2138) from firing
  # on its own during this window: age_of treats a missing .last-check as due
  # immediately regardless of FM_CHECK_INTERVAL (fm-watch.sh:1364-1370), so the
  # interval alone does not suppress it on a fresh state dir. Without both,
  # that scan's own wake could exit the watcher before the done: signal does,
  # and the test would prove nothing about ordinary signal handling.
  touch "$state/.last-check"
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$dir/watch.err" &
  pid=$!
  local i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$state/.last-watcher-beat" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not reach supervision after a refused shadow arm"
  fi
  rg -F 'pipeline shadow check not registered' "$dir/watch.err" >/dev/null \
    || fail "watcher did not log the refused shadow arm"
  # The watcher-authored prefix alone would still match if the relayed arm
  # diagnostic it wraps were dropped; assert that stable inner diagnostic too.
  rg -F 'fm-pipeline.sh: could not arm pipeline watcher check' "$dir/watch.err" >/dev/null \
    || fail "watcher did not relay the arm command's own diagnostic"
  [ "$(cat "$state/pipeline-probe.check.sh")" = "$content" ] \
    || fail "the foreign shim was overwritten"
  [ ! -e "$state/pipeline-probe.check-trust" ] || fail "a trust file appeared despite the refused arm"
  printf 'done: finished\n' >> "$state/task.status"
  wait_for_exit "$pid" 40 || fail "watcher did not exit after the integration signal"
  rg -F "signal: $state/task.status" "$out" >/dev/null \
    || fail "the watcher did not exit on the ordinary status-signal wake reason"
  pass "fm-watch.sh: a refused shadow arm is a logged refusal that reaches supervision"
}

test_disarm_marker_persists_and_force_clears() {
  local dir state fakebin out pid
  dir=$(make_case pipeline-watcher-disarm-persists)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the task status marker"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm the pipeline probe before disarming"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SCRIPT" disarm >/dev/null \
    || fail "could not disarm the pipeline probe"
  [ -f "$state/pipeline-probe.disabled" ] || fail "disarm did not write the disabled marker"
  [ "$(fm_pr_file_mode "$state/pipeline-probe.disabled")" = 600 ] \
    || fail "the disabled marker is not mode 0600"
  [ ! -e "$state/pipeline-probe.check.sh" ] || fail "disarm did not retire the check shim"
  [ ! -e "$state/pipeline-probe.check-trust" ] || fail "disarm did not retire the trust artifact"

  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$dir/watch.err" &
  pid=$!
  local i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$state/.last-watcher-beat" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not reach supervision with the pipeline probe disarmed"
  fi
  [ ! -e "$state/pipeline-probe.check.sh" ] || fail "watcher startup recreated the shim despite disarm"
  [ ! -e "$state/pipeline-probe.check-trust" ] \
    || fail "watcher startup recreated the trust artifact despite disarm"
  [ -f "$state/pipeline-probe.disabled" ] || fail "the disabled marker did not persist across watcher start"
  printf 'done: finished\n' >> "$state/task.status"
  wait_for_exit "$pid" 40 || fail "watcher did not exit after the integration signal"

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SCRIPT" arm --force >/dev/null \
    || fail "arm --force did not clear the disabled marker"
  [ ! -e "$state/pipeline-probe.disabled" ] || fail "arm --force did not remove the disabled marker"
  [ -f "$state/pipeline-probe.check.sh" ] || fail "arm --force did not recreate the check shim"
  [ -f "$state/pipeline-probe.check-trust" ] || fail "arm --force did not recreate the trust artifact"
  pass "fm-pipeline.sh: disarm persists across the next watcher start and arm --force clears it"
}

test_invalid_marker_refuses_and_preserves() {
  local dir state fakebin out pid rc output i

  dir=$(make_case pipeline-watcher-invalid-marker-symlink)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the task status marker"
  ln -s /dev/null "$state/pipeline-probe.disabled"

  rc=0
  output=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SCRIPT" arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a symlinked disabled marker"
  printf '%s\n' "$output" | rg -F 'state/pipeline-probe.disabled' >/dev/null \
    || fail "arm's refusal did not name the marker path for a symlink marker"
  [ -L "$state/pipeline-probe.disabled" ] || fail "arm deleted the invalid (symlink) marker"
  [ ! -e "$state/pipeline-probe.check.sh" ] || fail "arm armed the shim despite a symlink marker"
  [ ! -e "$state/pipeline-probe.check-trust" ] || fail "arm armed the trust artifact despite a symlink marker"

  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$dir/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$state/.last-watcher-beat" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not reach supervision with a symlink disabled marker"
  fi
  rg -F 'pipeline shadow check not registered' "$dir/watch.err" >/dev/null \
    || fail "watcher did not log the refused shadow arm for a symlink marker"
  [ -L "$state/pipeline-probe.disabled" ] || fail "the watcher deleted the invalid (symlink) marker"
  [ ! -e "$state/pipeline-probe.check.sh" ] \
    || fail "watcher startup armed the shim despite a symlink marker"
  printf 'done: finished\n' >> "$state/task.status"
  wait_for_exit "$pid" 40 \
    || fail "watcher did not exit after the integration signal with a symlink marker"

  dir=$(make_case pipeline-watcher-invalid-marker-dir)
  state="$dir/state"
  mkdir -p "$state/pipeline-probe.disabled"
  rc=0
  output=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$SCRIPT" arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a directory disabled marker"
  printf '%s\n' "$output" | rg -F 'state/pipeline-probe.disabled' >/dev/null \
    || fail "arm's refusal did not name the marker path for a directory marker"
  [ -d "$state/pipeline-probe.disabled" ] || fail "arm deleted the invalid (directory) marker"
  [ ! -e "$state/pipeline-probe.check.sh" ] || fail "arm armed the shim despite a directory marker"
  [ ! -e "$state/pipeline-probe.check-trust" ] || fail "arm armed the trust artifact despite a directory marker"
  pass "fm-pipeline.sh: an invalid disabled marker refuses arm and is preserved"
}

test_disarm_records_intent_when_retire_fails() {
  local root rc=0 output
  root=$(new_state disarm-retire-failure)
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm before forcing a retire failure"
  rm -f "$root/state/pipeline-probe.check-trust"
  mkdir -p "$root/state/pipeline-probe.check-trust"

  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" disarm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "disarm succeeded despite a forced retire failure"
  [ -f "$root/state/pipeline-probe.disabled" ] \
    || fail "disarm did not record the disable intent although the marker write should still succeed"
  [ "$(fm_pr_file_mode "$root/state/pipeline-probe.disabled")" = 600 ] \
    || fail "the disabled marker is not mode 0600"
  [ -f "$root/state/pipeline-probe.check.sh" ] \
    || fail "the check shim was removed despite a failed retire"
  [ -d "$root/state/pipeline-probe.check-trust" ] \
    || fail "the forced-failure trust directory was removed despite a failed retire"
  printf '%s\n' "$output" | rg -F 'disable policy recorded at state/pipeline-probe.disabled' >/dev/null \
    || fail "the refusal did not confirm the recorded disable intent"
  printf '%s\n' "$output" | rg -F 'the registered check was NOT retired' >/dev/null \
    || fail "the refusal did not name the unretired check"
  printf '%s\n' "$output" | rg -F 'fm-check-register.sh retire pipeline-probe' >/dev/null \
    || fail "the refusal did not name the hand-repair exit"
  pass "fm-pipeline.sh: disarm records the disable intent and names the repair when retire fails"
}

test_marker_policy_public_boundary() {
  local root rc=0 output
  root=$(new_state marker-policy)

  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm before testing the valid-marker refusal"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" disarm >/dev/null \
    || fail "could not disarm before testing the valid-marker refusal"

  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a valid disabled marker"
  printf '%s\n' "$output" | rg -F 'run arm --force to clear it' >/dev/null \
    || fail "the valid-marker refusal did not name arm --force"

  chmod 0644 "$root/state/pipeline-probe.disabled"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a mode-0644 disabled marker"
  printf '%s\n' "$output" | rg -F 'not a private regular file' >/dev/null \
    || fail "a mode-0644 marker was not treated as invalid"
  [ -f "$root/state/pipeline-probe.disabled" ] || fail "arm deleted a mode-0644 marker"

  rm -f "$root/state/pipeline-probe.disabled"
  ln -s /dev/null "$root/state/pipeline-probe.disabled"
  rc=0
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm --force >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "arm --force accepted an invalid (symlink) marker"
  [ -L "$root/state/pipeline-probe.disabled" ] || fail "arm --force deleted the invalid (symlink) marker"
  pass "fm-pipeline.sh: the disabled-marker policy's valid/0644/force-on-invalid rows hold at the public boundary"
}

test_arm_disarm_serialize_against_concurrent_contention() {
  local root rc=0 output
  root=$(new_state arm-disarm-lock)

  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm before testing the contention lock"

  # Simulates a concurrent arm or disarm mid-transaction: the marker check (or
  # write) and the transaction it gates are not atomic on their own, so an
  # interleaving here could otherwise arm the check under a disabled marker.
  mkdir "$root/state/pipeline-probe.lock" \
    || fail "could not simulate a concurrent arm/disarm holding the lock"

  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" disarm 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "disarm proceeded while another arm/disarm held the lock"
  printf '%s\n' "$output" | rg -F 'state/pipeline-probe.lock is held or being reclaimed' >/dev/null \
    || fail "the contention refusal did not name the lock"
  [ ! -e "$root/state/pipeline-probe.disabled" ] \
    || fail "disarm wrote the marker despite the contention refusal"
  [ -f "$root/state/pipeline-probe.check.sh" ] \
    || fail "the check shim was retired despite the contention refusal"
  [ -f "$root/state/pipeline-probe.check-trust" ] \
    || fail "the trust artifact was retired despite the contention refusal"

  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm --force 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "arm proceeded while another arm/disarm held the lock"
  printf '%s\n' "$output" | rg -F 'state/pipeline-probe.lock is held or being reclaimed' >/dev/null \
    || fail "the contention refusal did not name the lock for arm"

  rmdir "$root/state/pipeline-probe.lock" \
    || fail "could not clear the simulated lock"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" disarm >/dev/null \
    || fail "disarm did not succeed once the lock cleared"
  [ -f "$root/state/pipeline-probe.disabled" ] \
    || fail "disarm did not record the disable intent once the lock cleared"
  pass "fm-pipeline.sh: arm and disarm refuse a named contention instead of interleaving"
}

test_arm_reports_unknown_holder_for_live_steal_reclaim() {
  local root holder_file holder output rc=0
  root=$(new_state arm-live-steal-no-primary)
  holder_file="$root/holder"
  FM_STATE_OVERRIDE="$root/state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2/pipeline-probe.lock.steal" || exit 7
    printf "%s\n" "${BASHPID:-$$}" > "$3"
    sleep 2
    fm_lock_release "$2/pipeline-probe.lock.steal"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$root/state" "$holder_file" &
  holder=$!
  local i=0
  while [ "$i" -lt 50 ] && [ ! -s "$holder_file" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$holder_file" ] || fail "live steal mutex holder did not start"

  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm 2>&1) || rc=$?
  wait "$holder" || fail "live steal mutex holder failed"
  [ "$rc" -ne 0 ] || fail "arm proceeded while a live steal mutex held the absent primary"
  assert_contains "$output" 'state/pipeline-probe.lock is held or being reclaimed (holder unknown); retry' \
    "arm did not name an unknown holder while the lock was being reclaimed"
  assert_not_contains "$output" 'could not create state/pipeline-probe.lock' \
    "arm misclassified a live steal mutex as owner creation failure"
  [ ! -e "$root/state/pipeline-probe.check.sh" ] \
    || fail "arm wrote the check shim while the steal mutex was live"
  pass "fm-pipeline.sh: arm names a live steal mutex with an unknown holder"
}

test_arm_reclaims_a_dead_pid_lock() {
  local root rc=0 dead
  root=$(new_state arm-lock-reclaim)
  dead=$(dead_pid)

  mkdir "$root/state/pipeline-probe.lock" \
    || fail "could not simulate a stale lock"
  printf '%s\n' "$dead" > "$root/state/pipeline-probe.lock/pid"

  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "arm refused a stale lock left behind by a dead pid"
  [ -f "$root/state/pipeline-probe.check.sh" ] \
    || fail "arm did not complete after reclaiming a stale lock"
  [ "$(cat "$root/state/pipeline-probe.lock/pid" 2>/dev/null)" != "$dead" ] \
    || fail "the stale lock's dead pid was not replaced"
  pass "fm-pipeline.sh: arm reclaims a lock left behind by a dead pid"
}

test_arm_takes_lock_before_marker_check() {
  local root fakebin real_uname seen rc=0

  # Proves ORDER, not just that both verbs consult the lock: a uname stub
  # invoked from inside the marker check (fm_pr_file_device, reached only
  # once a marker exists to classify) records whether the transaction lock
  # is already present at that moment. If the check ever moved above the
  # lock acquisition, this would observe the lock absent and fail.
  root=$(new_state arm-lock-ordering)
  fakebin="$root/fakebin"
  mkdir -p "$fakebin"
  real_uname=$(command -v uname) || fail "no real uname on PATH to wrap"

  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm before installing a valid disabled marker"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" disarm >/dev/null \
    || fail "could not disarm to install a valid disabled marker"

  cat > "$fakebin/uname" <<EOF
#!/usr/bin/env bash
if [ -e "$root/state/pipeline-probe.lock" ]; then
  printf '1\n' > "$root/lock-seen-by-uname"
else
  printf '0\n' > "$root/lock-seen-by-uname"
fi
exec "$real_uname" "\$@"
EOF
  chmod +x "$fakebin/uname"

  PATH="$fakebin:$PATH" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" arm >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "arm accepted a valid disabled marker (test setup is broken)"
  [ -f "$root/lock-seen-by-uname" ] || fail "uname was never invoked during the marker check"
  seen=$(cat "$root/lock-seen-by-uname")
  [ "$seen" = 1 ] || fail "the transaction lock was not held when the marker check ran"
  pass "fm-pipeline.sh: the transaction lock is held before the marker check runs"
}

test_arm_lock_create_failure_watcher_reaches_supervision() {
  local dir state fakebin out pid rc real_mktemp
  dir=$(make_case pipeline-watcher-lock-create-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  real_mktemp=$(command -v mktemp) || fail "no real mktemp on PATH to wrap"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the task status marker"

  # Forces ONLY the pipeline-probe transaction lock's owner-directory
  # creation to fail with no lock present, at any ".steal" depth: before
  # the sixth-head fix this recursed without bound inside
  # fm_lock_try_acquire, so arm never returned and the watcher never
  # reached supervision. Scoped to pipeline-probe.lock's own owner paths
  # so the watcher's unrelated .watch.lock is unaffected.
  cat > "$fakebin/mktemp" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pipeline-probe.lock"*".owner."*) exit 1 ;;
esac
exec "$real_mktemp" "\$@"
EOF
  chmod +x "$fakebin/mktemp"
  touch "$state/.last-check"

  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$dir/watch.err" &
  pid=$!
  local i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$state/.last-watcher-beat" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not reach supervision after a lock creation failure"
  fi
  rg -F 'could not create state/pipeline-probe.lock (owner directory)' "$dir/watch.err" >/dev/null \
    || fail "watcher did not relay the creation-failure refusal by name"
  rg -F 'another arm or disarm holds' "$dir/watch.err" >/dev/null \
    && fail "a creation failure was misreported as contention"
  [ ! -e "$state/pipeline-probe.disabled" ] || fail "the marker was written despite a lock creation failure"
  [ ! -e "$state/pipeline-probe.check.sh" ] || fail "arm armed the shim despite a lock creation failure"
  printf 'done: finished\n' >> "$state/task.status"
  wait_for_exit "$pid" 40 || fail "watcher did not exit after the integration signal"
  pass "fm-watch.sh: a lock-creation failure is a named refusal that reaches supervision, never a hang"
}

test_working_step_vocabulary() {
  local root output
  root=$(new_state working-vocabulary)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_SOURCE_ONLY=1 \
    bash -c '
      set -u
      source "$1"
      line="rev=1 ts=2026-09-07T00:00:00Z step=working evidence=busy:state/task.busy-state gen=gen-1 head=unknown attempt=-"
      pipeline_record_line_load "$line" "$2/task.pipeline" 2 gen-1
      printf "step=%s\n" "$PIPELINE_RECORD_STEP"
    ' _ "$SCRIPT" "$root/state") || fail "the working record vocabulary was refused"
  assert_contains "$output" 'step=working' "working vocabulary did not load through the record parser"
  pass "fm-pipeline.sh: working is accepted by the record parser"
}

test_working_and_report_artifacts_drive_board_json() {
  local root gen output board rc=0
  root=$(new_state working-artifacts)
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$root/state" ship) \
    || fail "could not arm the ship busy fixture"
  fm_write_meta "$root/state/ship.meta" "kind=ship" "busy_gen=$gen" "spawn_gen=s-ship"
  "$ROOT/bin/fm-busy-event.sh" apply "$root/state" ship busy --gen "$gen" \
    --source pi-ext --event agent-start >/dev/null \
    || fail "could not write the non-synthetic busy event"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile ship 2>&1) || rc=$?
  expect_code 0 "$rc" "a current-generation non-synthetic busy event should reconcile"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "ship") | .step == "working" and .step_proven == true' >/dev/null \
    || fail "board-json did not project the busy ship as working"

  "$ROOT/bin/fm-busy-event.sh" apply "$root/state" ship idle --gen "$gen" \
    --source pi-ext --event agent-settled >/dev/null \
    || fail "could not settle the busy fixture"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile ship 2>&1) || rc=$?
  expect_code 0 "$rc" "a settled busy event must not retroactively refuse working"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "ship") | .step == "working" and .record_state == "ok"' >/dev/null \
    || fail "a settled busy event regressed the recorded working step"

  "$ROOT/bin/fm-busy-event.sh" retire "$root/state" ship --current-gen >/dev/null \
    || fail "could not retire the busy wiring"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile ship 2>&1) || rc=$?
  expect_code 0 "$rc" "retired busy wiring must not invalidate recorded working"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "ship") | .step == "working" and .record_state == "ok"' >/dev/null \
    || fail "retired busy wiring invalidated recorded working"

  root=$(new_state synthetic-busy)
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$root/state" synthetic) \
    || fail "could not arm the synthetic fixture"
  fm_write_meta "$root/state/synthetic.meta" "kind=ship" "busy_gen=$gen" "spawn_gen=s-synthetic"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile synthetic >/dev/null \
    || fail "the synthetic fixture did not reconcile"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "synthetic") | .step == "dispatched"' >/dev/null \
    || fail "the synthetic launch event incorrectly derived working"
  "$ROOT/bin/fm-busy-event.sh" apply "$root/state" synthetic idle --gen "$gen" \
    --source fm-interrupt --event escape >/dev/null \
    || fail "could not write the first synthetic idle event"
  "$ROOT/bin/fm-busy-event.sh" apply "$root/state" synthetic idle --gen "$gen" \
    --source fm-interrupt --event escape >/dev/null \
    || fail "could not write the second synthetic idle event"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile synthetic >/dev/null \
    || fail "the synthetic idle fixture did not reconcile"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "synthetic") | .step == "dispatched"' >/dev/null \
    || fail "synthetic idle events incorrectly derived working"

  root=$(new_state stale-busy)
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$root/state" stale) \
    || fail "could not arm the stale-generation fixture"
  fm_write_meta "$root/state/stale.meta" "kind=ship" "busy_gen=other-gen" "spawn_gen=s-stale"
  "$ROOT/bin/fm-busy-event.sh" apply "$root/state" stale busy --gen "$gen" \
    --source pi-ext --event agent-start >/dev/null \
    || fail "could not write the stale-generation busy event"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile stale >/dev/null \
    || fail "the stale-generation fixture did not reconcile"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "stale") | .step == "dispatched"' >/dev/null \
    || fail "a busy event from another generation incorrectly derived working"

  root=$(new_state scout-report)
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$root/state" scout) \
    || fail "could not arm the scout busy fixture"
  fm_write_meta "$root/state/scout.meta" "kind=scout" "busy_gen=$gen" "spawn_gen=s-scout"
  "$ROOT/bin/fm-busy-event.sh" apply "$root/state" scout busy --gen "$gen" \
    --source pi-ext --event agent-start >/dev/null \
    || fail "could not write the scout busy event"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile scout >/dev/null \
    || fail "the scout busy fixture did not reconcile"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "scout") | .step == "working"' >/dev/null \
    || fail "a scout without its report did not remain working"
  mkdir -p "$root/data/scout"
  printf '%s\n' 'report body' > "$root/data/scout/report.md"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile scout >/dev/null \
    || fail "the scout report fixture did not reconcile"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "scout") | .step == "report-exists" and .step_proven == true' >/dev/null \
    || fail "board-json did not project the written scout report"
  pass "fm-pipeline.sh: busy and report artifacts drive board-json monotonically"
}

test_working_recorded_state_fixture() {
  local root state board output rc=0
  root=$(new_state working-recorded-state)
  state="$root/state"
  cp -R "$ROOT/tests/fixtures/fm-pipeline-recorded-state/." "$state/" \
    || fail "could not seed the recorded busy-state fixture"
  for id in working synthetic mismatch absent-busy; do
    output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$state" "$SCRIPT" reconcile "$id" 2>&1) || rc=$?
    expect_code 0 "$rc" "recorded fixture task $id should reconcile"
  done
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '
    .tasks as $tasks
    | ($tasks | map(select(.id == "working"))[0])
      | .step == "working" and .step_proven == true
    and ($tasks | map(select(.id == "synthetic"))[0].step == "dispatched")
    and ($tasks | map(select(.id == "mismatch"))[0].step == "dispatched")
    and ($tasks | map(select(.id == "absent-busy"))[0].step == "dispatched")
  ' >/dev/null || fail "board-json did not classify the recorded state fixture"
  pass "fm-pipeline.sh: recorded busy-state fixture drives board-json deterministically"
}

test_line_format_and_unknown_preservation
test_probe_state_unavailable_is_explicit_and_noncreating
test_probe_activity_read_failure_leaves_unknown_trace
test_probe_deadline_coverage_is_clock_scripted
test_probe_invalid_deadline_refuses_before_scan
test_pipeline_probe_units
test_probe_stress_measurement
test_would_heal_without_evidence_is_rejected
test_append_rejects_malformed_fields
test_event_log_symlink_is_rejected
test_stale_wait_is_shadow_only
test_terminal_statuses_without_premise_are_unknown
test_resumed_wait_is_not_reprobed
test_note_preserves_active_wait
test_configured_pause_verb_is_supported
test_all_active_waits_are_probed_independently
test_pause_key_sentinels_remain_distinct
test_valid_invalid_slug_remains_distinct
test_explicit_default_key_remains_distinct
test_stale_event_lock_is_recovered
test_task_paths_are_confined
test_arm_preserves_existing_check_on_registration_failure
test_relative_arm_embeds_absolute_state
test_registered_check_reaches_watcher
test_reconcile_ignores_status_testimony
 test_append_is_not_agent_facing
 test_legacy_cache_migrates_without_reinterpretation
 test_board_json_does_not_migrate_legacy_cache
 test_legacy_cache_migration_collision_refuses
 test_probe_reads_owner_record_not_meta_step_claim
 test_reconcile_absent_meta_refuses_without_writing
 test_record_reader_rejects_unproven_hand_append
 test_foreign_generation_is_refused
 test_pr_registration_and_merge_artifacts
 test_steps_print_ordered_graph
 test_probe_cost_fixture_removes_sensor_calls
 test_board_json_fixture_inventory_and_bound
 test_quiet_registered_probe_and_refusal_projection
 test_retire_owner_records
 test_pipeline_pure_function_units
test_s6_pure_since_unit
test_s6_since_uses_record_step_timestamp
test_s6_invalid_future_and_uninitialized_timestamps
test_s6_occurrence_closures
 test_pipeline_lock_timeout_validation
 test_pipeline_restart_recovery
 test_reconcile_serializes_owner_transaction
 test_reconcile_rechecks_metadata_inside_owner_transaction
 test_reconcile_refuses_same_generation_artifact_change
 test_meta_scalar_tabs_refuse_before_cache_parse
 test_absent_home_reconcile_does_not_recreate_state
 test_board_filters_observations_by_generation
 test_board_projects_unknown_and_kind_inconsistent_tasks
test_arm_refusal_watcher_reaches_supervision
test_disarm_marker_persists_and_force_clears
test_invalid_marker_refuses_and_preserves
test_disarm_records_intent_when_retire_fails
test_marker_policy_public_boundary
test_arm_disarm_serialize_against_concurrent_contention
test_arm_reports_unknown_holder_for_live_steal_reclaim
test_arm_reclaims_a_dead_pid_lock
test_arm_takes_lock_before_marker_check
test_effect_owner_claim_deliver_and_terminal_guards() {
  local root payload key output rc slot before after deliver_out1 deliver_out2 deliver_pid1 deliver_pid2
  root=$(new_state effect-owner)
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  payload=$(printf '%064d' 0)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
    --gen gen-1 --target github.com/o/r#7 --payload "$payload") || fail "initial effect claim refused"
  key=${output#claimed }
  [ "${#key}" -eq 64 ] || fail "effect key was not a sha256"
  [ "$key" = 91c48c5adb89b07f0f3ed377f013a0ff4f73e9b4cdd4400cfc70cb2813c27c25 ] \
    || fail "effect key changed for the fixed tuple"
  slot="$root/state/task.effect-$key"
  [ -f "$slot" ] || fail "effect claim did not create its dedicated slot"
  assert_contains "$(cat "$slot")" 'schema=fm-effect.v1' "effect slot lost its schema"
  assert_contains "$(cat "$slot")" 'state=requested' "effect claim did not record requested"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
    --gen gen-1 --target github.com/o/r#7 --payload "$payload" 2>&1) || rc=$?
  expect_code 3 "$rc" "a requested effect must not be claimed a second time"
  assert_contains "$output" 'unresolved requested' "repeat claim did not remain unresolved"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect deliver task "$key" \
    --gen gen-1 --receipt 42 --target github.com/o/r#7 --payload "$payload" > "$root/deliver-1") &
  deliver_pid1=$!
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect deliver task "$key" \
    --gen gen-1 --receipt 42 --target github.com/o/r#7 --payload "$payload" > "$root/deliver-2") &
  deliver_pid2=$!
  wait "$deliver_pid1" || fail "first concurrent effect delivery refused"
  wait "$deliver_pid2" || fail "second concurrent effect delivery refused"
  deliver_out1=$(cat "$root/deliver-1")
  deliver_out2=$(cat "$root/deliver-2")
  [ "$deliver_out1" = 'delivered 42' ] || fail "first concurrent delivery returned: $deliver_out1"
  [ "$deliver_out2" = 'delivered 42' ] || fail "second concurrent delivery returned: $deliver_out2"
  before=$(cat "$slot")
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect deliver task "$key" \
    --gen gen-1 --receipt 42 --target github.com/o/r#7 --payload "$payload") \
    || fail "idempotent effect delivery refused"
  after=$(cat "$slot")
  [ "$before" = "$after" ] || fail "idempotent delivery rewrote a terminal slot"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect deliver task "$key" \
    --gen gen-1 --receipt 41 --target github.com/o/r#7 --payload "$payload" 2>&1) || rc=$?
  expect_code 1 "$rc" "a different receipt must be refused"
  assert_contains "$output" 'refused:receipt-mismatch' "receipt mismatch was not named"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect ambiguous task "$key" --gen gen-1 \
    >/dev/null || fail "late ambiguous transition refused"
  [ "$(cat "$slot")" = "$before" ] || fail "late ambiguous downgraded delivered slot"
  pass "fm-pipeline.sh: keyed effect slots claim once, deliver idempotently, and keep terminal state"
}

test_effect_owner_refuses_foreign_generation_and_corrupt_slots() {
  local root payload output rc key slot
  root=$(new_state effect-refusals)
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  payload=$(printf '%064d' 1)
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
    --gen gen-2 --target github.com/o/r#7 --payload "$payload" 2>&1) || rc=$?
  expect_code 1 "$rc" "foreign generation claim must refuse"
  assert_contains "$output" 'refused:foreign-gen' "foreign generation refusal was not named"
  [ ! -e "$root/state/task.effect" ] || fail "foreign generation claim wrote an effect"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
    --gen gen-1 --target github.com/o/r#7 --payload "$payload") || fail "valid effect claim refused"
  key=${output#claimed }
  slot="$root/state/task.effect-$key"
  rm -f "$slot"
  mkdir "$slot"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
    --gen gen-1 --target github.com/o/r#7 --payload "$payload" 2>&1) || rc=$?
  expect_code 1 "$rc" "a directory at the effect slot must refuse"
  assert_contains "$output" 'refused:corrupt-slot' "corrupt effect slot was not named"
  [ -d "$slot" ] || fail "corrupt effect slot was changed"
  for effect in "$root/state/task.effect-"*; do
    [ -e "$effect" ] || [ -L "$effect" ] || continue
    [ "$effect" = "$slot" ] || fail "foreign generation claim wrote an effect outside the keyed namespace"
  done
  pass "fm-pipeline.sh: effect mutations fence generations and refuse corrupt slots"
}

test_effect_owner_rejects_invalid_receipts_and_stock_bash_retire() {
  local root payload target key slot before_file invalid_file output rc=0
  root=$(new_state effect-receipts)
  payload=$(printf '%064d' 2)
  target=github.com/o/r#7
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
    --gen gen-1 --target "$target" --payload "$payload") || fail "receipt fixture claim refused"
  key=${output#claimed }
  slot="$root/state/task.effect-$key"
  before_file="$root/pristine.slot"
  invalid_file="$root/invalid.slot"
  cp -- "$slot" "$before_file"
  local bad positive
  for bad in - 0 007 77junk 12.3; do
    sed "s/state=requested receipt=-/state=delivered receipt=$bad/" "$before_file" > "$slot.tmp"
    chmod 600 "$slot.tmp"
    mv "$slot.tmp" "$slot"
    cp -- "$slot" "$invalid_file"
    assert_contains "$(cat "$slot")" "state=delivered receipt=$bad" "invalid receipt fixture did not install receipt $bad"
    rc=0
    output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
      --gen gen-1 --target "$target" --payload "$payload" 2>&1) || rc=$?
    expect_code 1 "$rc" "delivered receipt $bad must refuse"
    assert_contains "$output" 'refused:corrupt-slot' "invalid delivered receipt $bad was not named"
    cmp -s "$slot" "$invalid_file" || fail "invalid delivered receipt $bad refusal changed the slot bytes"
  done
  for positive in 1 7 42; do
    sed "s/state=requested receipt=-/state=delivered receipt=$positive/" "$before_file" > "$slot"
    chmod 600 "$slot"
    rc=0
    output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
      --gen gen-1 --target "$target" --payload "$payload" 2>&1) || rc=$?
    expect_code 0 "$rc" "positive delivered receipt $positive must verify"
    [ "$output" = "delivered $positive" ] || fail "positive receipt $positive returned: $output"
  done
  cp -- "$before_file" "$slot"
  local bad_write
  for bad_write in 0 007 77junk 12.3 -; do
    cp -- "$before_file" "$slot"
    rc=0
    output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect deliver task "$key" \
      --gen gen-1 --receipt "$bad_write" --target "$target" --payload "$payload" 2>&1) || rc=$?
    expect_code 1 "$rc" "effect deliver receipt $bad_write must refuse"
    assert_contains "$output" 'refused:invalid-receipt' "effect deliver receipt $bad_write refusal was not named"
    cmp -s "$slot" "$before_file" || fail "effect deliver receipt $bad_write changed the slot bytes"
  done
  printf 'kind=ship\nspawn_gen=gen-retire-effect\n' > "$root/state/retire-with-effect.meta"
  printf 'schema=fm-pipeline.v3 task=retire-with-effect kind=ship gen=gen-retire-effect rev=1 ts=2026-01-01T00:00:00Z step=working evidence=meta:state/retire-with-effect.meta\n' > "$root/state/retire-with-effect.pipeline"
  cp -- "$before_file" "$root/state/retire-with-effect.effect-$key"
  rm -f "$root/state/retire-with-effect.meta"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" /bin/bash "$SCRIPT" retire retire-with-effect 2>&1) || rc=$?
  expect_code 0 "$rc" "stock Bash must retire a task with effect slots"
  assert_contains "$output" 'retired: retire-with-effect' "stock Bash effect-slot retire did not report success"
  [ ! -e "$root/state/retire-with-effect.pipeline" ] || fail "stock Bash effect-slot retire left the record behind"
  [ ! -e "$root/state/retire-with-effect.effect-$key" ] || fail "stock Bash effect-slot retire left the effect slot behind"
  [ -e "$slot" ] || fail "retiring one task removed another task's effect slot"

  printf 'kind=ship\nspawn_gen=gen-retire\n' > "$root/state/retire.meta"
  printf 'schema=fm-pipeline.v3 task=retire kind=ship gen=gen-retire rev=1 ts=2026-01-01T00:00:00Z step=working evidence=meta:state/retire.meta\n' > "$root/state/retire.pipeline"
  rm -f "$root/state/retire.meta"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" /bin/bash "$SCRIPT" retire retire 2>&1) || rc=$?
  expect_code 0 "$rc" "stock Bash must retire a task without effect slots"
  assert_contains "$output" 'retired: retire' "stock Bash retire did not report success"
  [ ! -e "$root/state/retire.pipeline" ] || fail "stock Bash retire left the record behind"
  pass "fm-pipeline.sh: invalid receipts refuse and stock Bash retires empty effect sets"
}

test_arm_lock_create_failure_watcher_reaches_supervision
test_working_step_vocabulary
test_working_and_report_artifacts_drive_board_json
test_working_recorded_state_fixture
 test_effect_owner_claim_deliver_and_terminal_guards
 test_effect_owner_refuses_foreign_generation_and_corrupt_slots
test_effect_owner_competing_claims_and_abandonment() {
  local root payload target out1 out2 key claimed unresolved output rc=0
  root=$(new_state effect-competing)
  payload=$(printf '%064d' 3)
  target=github.com/o/r#7
  printf 'kind=ship\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  (
    FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
      --gen gen-1 --target "$target" --payload "$payload" > "$root/out1" 2>&1
    printf '%s\n' "$?" > "$root/rc1"
  ) &
  local pid1=$!
  (
    FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
      --gen gen-1 --target "$target" --payload "$payload" > "$root/out2" 2>&1
    printf '%s\n' "$?" > "$root/rc2"
  ) &
  local pid2=$!
  wait "$pid1" || true
  wait "$pid2" || true
  out1=$(cat "$root/out1")
  out2=$(cat "$root/out2")
  claimed=$(printf '%s\n%s\n' "$out1" "$out2" | rg -c '^claimed ' || true)
  unresolved=$(printf '%s\n%s\n' "$out1" "$out2" | rg -c '^unresolved requested$' || true)
  [ "$claimed" -eq 1 ] || fail "competing claims produced $claimed claim results: $out1 / $out2"
  [ "$unresolved" -eq 1 ] || fail "competing claims produced $unresolved unresolved results: $out1 / $out2"
  case "$out1" in claimed\ *) key=${out1#claimed } ;; *) key=${out2#claimed } ;; esac
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect ambiguous task "$key" --gen gen-1 \
    >/dev/null || fail "open effect did not become ambiguous"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect abandon task "$key" --gen gen-1 \
    >/dev/null || fail "ambiguous effect did not become abandoned"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" effect claim task \
    --gen gen-1 --target "$target" --payload "$payload" 2>&1) || rc=$?
  expect_code 1 "$rc" "an abandoned effect must not reopen"
  assert_contains "$output" 'refused:abandoned' "abandoned effect reopening was not refused"
  pass "fm-pipeline.sh: competing claims serialize and abandonment is terminal"
}

test_effect_owner_competing_claims_and_abandonment
 test_effect_owner_rejects_invalid_receipts_and_stock_bash_retire
