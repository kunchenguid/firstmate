#!/usr/bin/env bash
# Behavior tests for the runner's optional home recorder seam
# (config/procevent-recorder, documented in bin/fm-procevent.sh's header).
#
# The recorder must see every captured result before the result is announced,
# must never acknowledge it, and must be skipped unless it is a private,
# single-link, mode-0700 regular file. A failing recorder must leave the
# capture exactly as an absent one would: published and unhandled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-recorder-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# A fresh home whose one Lavish source prints a single captured message.
make_source_home() {  # <name> <source-id>
  local home="$TMP_ROOT/$1" sid=$2
  mkdir -p "$home/state" "$home/config"
  fm_test_track_procevent_home "$home"
  cat > "$home/source.sh" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  status: feedback\nprompts[1]{uid,prompt,selector,tag,text}:\n  "","keep this comment","","message",""\n'
SH
  chmod +x "$home/source.sh"
  pe "$home" register lavish "$sid" -- "$home/source.sh" >/dev/null \
    || fail "could not register the $1 source"
  printf '%s\n' "$home"
}

# A recorder that notes its arguments, whether the capture was already
# announced when it ran, and refuses a result it has already recorded.
write_recorder() {  # <home> <exit-code>
  local home=$1 code=$2
  cat > "$home/config/procevent-recorder" <<SH
#!/usr/bin/env bash
log="$home/recorded"
if [ -f "\$log" ] && grep -qF "\$3" "\$log"; then
  echo "refused: already recorded" >&2
  exit 3
fi
announced=no
grep -qF "procevent lavish \$2 1" "$home/state/.wake-queue" 2>/dev/null && announced=yes
printf '%s\t%s\t%s\tannounced=%s\n' "\$1" "\$2" "\$3" "\$announced" >> "\$log"
exit $code
SH
  chmod 0700 "$home/config/procevent-recorder"
}

wake_queue() { cat "$1/state/.wake-queue" 2>/dev/null || true; }

test_recorder_runs_before_announcement_and_never_acknowledges() {
  local sid=lavish-rec0000000000001 home out log result
  home=$(make_source_home fed "$sid")
  write_recorder "$home" 0
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_contains "$out" "recorder-fed: $sid" "a valid recorder was not fed: $out"
  result="$home/state/procevent-inbox/$sid.1.result"
  [ -f "$result" ] || fail "the result was not durably captured"
  log=$(cat "$home/recorded" 2>/dev/null || true)
  assert_contains "$log" "lavish	$sid	" "the recorder did not receive the adapter and source id: $log"
  assert_contains "$log" "$sid.1.result" "the recorder did not receive the durable result path: $log"
  assert_contains "$log" "announced=no" "the recorder ran after the capture was announced: $log"
  grep -qF "keep this comment" "$(awk -F '\t' '{print $3}' "$home/recorded")" \
    || fail "the recorder's result path did not hold the captured comment"
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" \
    "the recorder suppressed the wake"
  [ ! -e "$home/state/procevent-inbox/$sid.1.handled" ] \
    || fail "the recorder seam acknowledged the capture"
  out=$(pe "$home" handled "$sid" 1) || fail "handled failed after recording"
  assert_contains "$out" "handled: $sid 1" "the first acknowledgement was not recorded"
  out=$(pe "$home" handled "$sid" 1) || fail "a repeat handled failed"
  assert_contains "$out" "already-handled: $sid 1" "a repeat acknowledgement was not deduplicated"
  pass "the recorder sees the capture before announcement and never acknowledges it"
}

test_failing_recorder_leaves_the_capture_announced_and_unhandled() {
  local sid=lavish-rec0000000000002 home out
  home=$(make_source_home failing "$sid")
  write_recorder "$home" 1
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_not_contains "$out" "recorder-fed:" "a failing recorder was reported as fed: $out"
  [ -f "$home/state/procevent-inbox/$sid.1.result" ] || fail "a failing recorder lost the capture"
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" \
    "a failing recorder suppressed the wake"
  [ ! -e "$home/state/procevent-inbox/$sid.1.handled" ] \
    || fail "a failing recorder acknowledged the capture"
  pass "a failing recorder leaves the capture published and unhandled"
}

test_untrusted_recorder_is_never_run() {
  local sid home out mode
  for mode in 0755 symlink; do
    sid=lavish-rec00000000000${mode#0}
    [ "$mode" = symlink ] && sid=lavish-rec0000000000005
    home=$(make_source_home "untrusted-$mode" "$sid")
    if [ "$mode" = symlink ]; then
      write_recorder "$home" 0
      mv "$home/config/procevent-recorder" "$home/real-recorder"
      ln -s "$home/real-recorder" "$home/config/procevent-recorder"
    else
      write_recorder "$home" 0
      chmod "$mode" "$home/config/procevent-recorder"
    fi
    out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
    assert_not_contains "$out" "recorder-fed:" "a $mode recorder was trusted: $out"
    [ ! -e "$home/recorded" ] || fail "a $mode recorder was executed"
    assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" \
      "a $mode recorder changed announcement"
  done
  pass "a recorder that is not a private mode-0700 regular file is never run"
}

test_absent_recorder_changes_nothing() {
  local sid=lavish-rec0000000000006 home out
  home=$(make_source_home absent "$sid")
  out=$(pe "$home" start "$sid" 2>&1) || fail "the runner did not complete: $out"
  assert_not_contains "$out" "recorder-fed:" "an absent recorder was reported as fed: $out"
  assert_contains "$(wake_queue "$home")" "check: procevent lavish $sid 1" \
    "an absent recorder changed announcement"
  pass "a home with no recorder captures and announces exactly as before"
}

test_recorder_runs_before_announcement_and_never_acknowledges
test_failing_recorder_leaves_the_capture_announced_and_unhandled
test_untrusted_recorder_is_never_run
test_absent_recorder_changes_nothing
printf '# all fm-procevent-recorder tests passed\n'
