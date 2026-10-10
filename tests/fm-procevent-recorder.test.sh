#!/usr/bin/env bash
# Behavior tests for the runner's optional home recorder
# (config/procevent-recorder, documented in bin/fm-procevent.sh's header).
#
# The recorder must see every built-in capture before it is announced, and
# while it is configured no capture may be acknowledged - by `handled`, a
# worker's re-arm, or a silent no-op - until its record exists. Failures,
# untrusted recorder files, interruptions, and hangs must stay visible and
# bounded, never silently acknowledged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-recorder-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

FEEDBACK_BODY='session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","keep this comment","","message",""\n'
EMPTY_BODY='session:\n  status: ended\n  session_ended: true\n'

# A fresh home with one Lavish source printing <body>. With a task id the
# source is registered as that worker's board.
make_source_home() {  # <name> <source-id> <body> [task-id]
  local home="$TMP_ROOT/$1" sid=$2 body=$3 task=${4-}
  mkdir -p "$home/state" "$home/config"
  fm_test_track_procevent_home "$home"
  printf '#!/usr/bin/env bash\nprintf '"'"'%s'"'"'\n' "$body" > "$home/source.sh"
  chmod +x "$home/source.sh"
  if [ -n "$task" ]; then
    printf 'window=fmtest:fm-%s\nworktree=%s/worktree-%s\nproject=fmtest\n' "$task" "$home" "$task" \
      > "$home/state/$task.meta"
    pe "$home" register-task lavish "$sid" "$task" -- "$home/source.sh" >/dev/null \
      || fail "could not register the $1 worker source"
  else
    pe "$home" register lavish "$sid" -- "$home/source.sh" >/dev/null \
      || fail "could not register the $1 source"
  fi
  printf '%s\n' "$home"
}

# Install a recorder whose body is <script>; it logs each call first.
write_recorder() {  # <home> <script-body>
  local home=$1 body=$2
  {
    printf '#!/usr/bin/env bash\n'
    printf 'announced=no\n'
    # shellcheck disable=SC2016 # $1-$3 and $announced belong to the generated recorder, not this shell
    printf 'grep -qF "procevent lavish $2 1" "%s/state/.wake-queue" 2>/dev/null && announced=yes\n' "$home"
    # shellcheck disable=SC2016 # same: expanded by the generated recorder
    printf 'printf "%%s\\t%%s\\t%%s\\tannounced=%%s\\n" "$1" "$2" "$3" "$announced" >> "%s/recorded"\n' "$home"
    printf '%s\n' "$body"
  } > "$home/config/procevent-recorder"
  chmod 0700 "$home/config/procevent-recorder"
}

wake_queue() { cat "$1/state/.wake-queue" 2>/dev/null || true; }
inbox() { printf '%s/state/procevent-inbox/%s.1\n' "$1" "$2"; }

test_recorder_runs_before_announcement_and_gates_acknowledgement() {
  local sid=lavish-rec0000000000001 home out log base
  home=$(make_source_home fed "$sid" "$FEEDBACK_BODY")
  write_recorder "$home" 'exit 0'
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_contains "$out" "recorder-fed: $sid" "a working recorder was not fed: $out"
  base=$(inbox "$home" "$sid")
  [ -f "$base.recorded" ] || fail "a successful recorder left no recorded marker"
  log=$(cat "$home/recorded" 2>/dev/null || true)
  assert_contains "$log" "lavish	$sid	$base.result" "the recorder got the wrong arguments: $log"
  assert_contains "$log" "announced=no" "the recorder ran after the capture was announced: $log"
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" "recording suppressed the wake"
  [ ! -e "$base.handled" ] || fail "recording acknowledged the capture"
  out=$(pe "$home" handled "$sid" 1) || fail "handled refused a recorded capture: $out"
  assert_contains "$out" "handled: $sid 1" "a recorded capture was not acknowledged"
  out=$(pe "$home" handled "$sid" 1) || fail "a repeat handled failed"
  assert_contains "$out" "already-handled: $sid 1" "a repeat acknowledgement was not deduplicated"
  pass "the recorder runs before announcement and a recorded capture acknowledges normally"
}

test_failed_recording_stays_visible_and_blocks_acknowledgement() {
  local sid=lavish-rec0000000000002 home out base
  home=$(make_source_home failing "$sid" "$FEEDBACK_BODY")
  write_recorder "$home" 'echo "ledger write failed" >&2; exit 1'
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_contains "$out" "recorder-failed: $sid 1 (exit 1)" "a failed recorder was silent: $out"
  assert_not_contains "$out" "recorder-fed:" "a failing recorder was reported as fed: $out"
  base=$(inbox "$home" "$sid")
  [ -f "$base.recorder-failed" ] || fail "a failed recorder left no failure record"
  assert_contains "$(cat "$base.recorder-log")" "ledger write failed" "the recorder's error output was dropped"
  [ ! -e "$base.recorded" ] || fail "a failed recorder was marked recorded"
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" "a failed recorder suppressed the wake"
  if out=$(pe "$home" handled "$sid" 1 2>&1); then
    fail "an unrecorded capture was acknowledged: $out"
  fi
  assert_contains "$out" "bin/fm-procevent.sh record $sid 1" "the refusal did not name the retry: $out"
  [ ! -e "$base.handled" ] || fail "a refused acknowledgement still wrote its marker"
  write_recorder "$home" 'exit 0'
  out=$(pe "$home" record "$sid" 1 2>&1) || fail "record did not retry the repaired recorder: $out"
  assert_contains "$out" "recorded: $sid 1" "a retried record was not reported"
  [ ! -e "$base.recorder-failed" ] || fail "a successful retry left the old failure record"
  out=$(pe "$home" handled "$sid" 1) || fail "handled refused after a successful retry: $out"
  assert_contains "$out" "handled: $sid 1" "the retried capture was not acknowledged"
  pass "a failed recording stays visible, blocks acknowledgement, and record retries it"
}

test_interrupted_recorder_leaves_no_record() {
  local sid=lavish-rec0000000000003 home out base
  home=$(make_source_home interrupted "$sid" "$FEEDBACK_BODY")
  write_recorder "$home" "printf partial > \"$TMP_ROOT/interrupted-partial\"; kill -9 \$\$"
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_contains "$out" "recorder-failed: $sid 1 (exit 137)" "a killed recorder was not reported: $out"
  base=$(inbox "$home" "$sid")
  [ ! -e "$base.recorded" ] || fail "a killed recorder was marked recorded"
  if pe "$home" handled "$sid" 1 >/dev/null 2>&1; then
    fail "a capture whose recorder was killed was acknowledged"
  fi
  pass "a recorder killed mid-write leaves the capture unrecorded and unacknowledgeable"
}

test_hung_recorder_is_bounded() {
  local sid=lavish-rec0000000000004 home out began took
  home=$(make_source_home hung "$sid" "$FEEDBACK_BODY")
  write_recorder "$home" 'sleep 307'
  began=$(date +%s)
  out=$(FM_PROCEVENT_RECORDER_TIMEOUT=1 pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  took=$(( $(date +%s) - began ))
  [ "$took" -lt 20 ] || fail "a hung recorder held the runner for ${took}s"
  assert_contains "$out" "recorder-failed: $sid 1 (timed out after 1s)" "a hung recorder was not reported: $out"
  sleep 1
  if pgrep -f 'sleep 307' >/dev/null 2>&1; then
    pkill -f 'sleep 307' 2>/dev/null || true
    fail "the hung recorder's child outlived the bound"
  fi
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" "a hung recorder suppressed the wake"
  [ ! -e "$(inbox "$home" "$sid").recorded" ] || fail "a timed-out recorder was marked recorded"
  pass "a hung recorder is stopped at its bound and the capture stays announced"
}

test_untrusted_recorder_is_never_run_and_blocks() {
  local sid home out kind
  for kind in mode symlink; do
    if [ "$kind" = mode ]; then sid=lavish-rec0000000000005; else sid=lavish-rec0000000000006; fi
    home=$(make_source_home "untrusted-$kind" "$sid" "$FEEDBACK_BODY")
    write_recorder "$home" 'exit 0'
    if [ "$kind" = symlink ]; then
      mv "$home/config/procevent-recorder" "$home/real-recorder"
      ln -s "$home/real-recorder" "$home/config/procevent-recorder"
    else
      chmod 0755 "$home/config/procevent-recorder"
    fi
    out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
    assert_contains "$out" "recorder-failed: $sid 1 (recorder is not a private mode-0700 regular file)" \
      "an untrusted $kind recorder was not reported: $out"
    [ ! -e "$home/recorded" ] || fail "an untrusted $kind recorder was executed"
    if pe "$home" handled "$sid" 1 >/dev/null 2>&1; then
      fail "an untrusted $kind recorder let a capture through unrecorded"
    fi
  done
  pass "an untrusted recorder is never run and its captures stay unacknowledged"
}

test_empty_capture_is_not_silenced_past_a_failed_recorder() {
  local sid=lavish-rec0000000000007 home out
  home=$(make_source_home empty-absent "$sid" "$EMPTY_BODY")
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_not_contains "$(wake_queue "$home")" "procevent lavish $sid 1" \
    "baseline changed: an empty ended capture woke the handler with no recorder"
  sid=lavish-rec0000000000008
  home=$(make_source_home empty-failing "$sid" "$EMPTY_BODY")
  write_recorder "$home" 'exit 1'
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_contains "$out" "recorder-failed: $sid 1" "the failed recorder was silent: $out"
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" \
    "an empty capture with a failed record was silently acknowledged"
  [ ! -e "$(inbox "$home" "$sid").handled" ] || fail "the silent path acknowledged an unrecorded capture"
  pass "a silent no-op capture is announced instead of acknowledged when its record failed"
}

test_worker_rearm_refuses_an_unrecorded_round() {
  local sid=lavish-rec0000000000009 home out
  home=$(make_source_home worker "$sid" "$FEEDBACK_BODY" t-worker)
  write_recorder "$home" 'exit 1'
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_contains "$out" "recorder-failed: $sid 1" "the worker board's failed record was silent: $out"
  if out=$(pe "$home" register-task lavish "$sid" t-worker -- "$home/source.sh" 2>&1); then
    fail "a worker re-arm acknowledged an unrecorded round: $out"
  fi
  assert_contains "$out" "not recorded by config/procevent-recorder" "the re-arm refusal did not say why: $out"
  [ ! -e "$(inbox "$home" "$sid").handled" ] || fail "a refused re-arm still acknowledged the round"
  pass "a worker re-arm refuses to acknowledge an unrecorded round"
}

test_extension_capture_is_never_fed_or_gated() {
  local sid=lavish-rec0000000000010 home out base digest
  home="$TMP_ROOT/extension"
  mkdir -p "$home/state" "$home/config"
  fm_test_track_procevent_home "$home"
  write_recorder "$home" 'exit 1'
  printf 'extension result\n' > "$home/out"
  digest="sha256:$(printf '%064d' 0)"
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  (. "$ROOT/bin/fm-pr-lib.sh" && . "$ROOT/bin/fm-procevent-lib.sh" \
    && fm_procevent_capture "$home/state" "$sid" lavish "$home/out" demo-ext 1.0.0 1 "$digest" "$digest") \
    >/dev/null || fail "could not capture an extension result"
  base=$(inbox "$home" "$sid")
  [ -f "$base.extension" ] || fail "the extension capture has no owner marker"
  if out=$(pe "$home" record "$sid" 1 2>&1); then
    fail "record fed an extension capture to the recorder: $out"
  fi
  [ ! -e "$home/recorded" ] || fail "the recorder ran on an extension capture"
  out=$(pe "$home" handled "$sid" 1 2>&1) || fail "the record gate refused an extension capture: $out"
  assert_contains "$out" "handled: $sid 1" "an extension capture was not acknowledged"
  pass "an extension capture is never fed to the recorder and never gated by it"
}

test_absent_recorder_changes_nothing() {
  local sid=lavish-rec0000000000011 home out
  home=$(make_source_home absent "$sid" "$FEEDBACK_BODY")
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_not_contains "$out" "recorder-fed:" "a home with no recorder reported a feed: $out"
  assert_not_contains "$out" "recorder-failed:" "a home with no recorder reported a failure: $out"
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" "an absent recorder changed announcement"
  out=$(pe "$home" handled "$sid" 1) || fail "handled was gated with no recorder: $out"
  assert_contains "$out" "handled: $sid 1" "an absent recorder changed acknowledgement"
  pass "a home with no recorder captures, announces, and acknowledges exactly as before"
}

test_recorder_runs_before_announcement_and_gates_acknowledgement
test_failed_recording_stays_visible_and_blocks_acknowledgement
test_interrupted_recorder_leaves_no_record
test_hung_recorder_is_bounded
test_untrusted_recorder_is_never_run_and_blocks
test_empty_capture_is_not_silenced_past_a_failed_recorder
test_worker_rearm_refuses_an_unrecorded_round
test_extension_capture_is_never_fed_or_gated
test_absent_recorder_changes_nothing
printf '# all fm-procevent-recorder tests passed\n'
