#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

write_fake_ps() {
  local fakebin=$1 body=$2
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
$body
SH
  chmod +x "$fakebin/ps"
}

test_fm_lock_recognizes_omp_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-holder-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-holder-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  write_fake_ps "$fakebin" '
case "$*" in
  *"comm="*) printf "%s\n" "bun"; exit 0 ;;
  *"args="*) printf "%s\n" "bun /Users/x/.bun/bin/omp"; exit 0 ;;
esac
exit 1
'

  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize bun-wrapped omp as a live holder"
  pass "fm-lock recognizes bun-wrapped omp lock holders"
}

test_fm_lock_acquire_finds_omp_harness_pid() {
  local home fakebin out status
  home="$TMP_ROOT/lock-acquire-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-acquire-fake")
  mkdir -p "$home/state"
  write_fake_ps "$fakebin" '
case "$*" in
  *"comm="*) printf "%s\n" "bun"; exit 0 ;;
  *"args="*) printf "%s\n" "bun /path/omp"; exit 0 ;;
  *"ppid="*) printf "%s\n" "1"; exit 0 ;;
esac
exit 1
'

  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1)
  status=$?
  expect_code 0 "$status" "fm-lock should acquire under bun-wrapped omp"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not report acquiring under omp"
  assert_present "$home/state/.lock" "fm-lock did not write the lock file"
  pass "fm-lock acquire resolves the omp harness pid through ancestry"
}

test_fm_lock_dash_comm_is_safe_and_continues() {
  local home fakebin out status err
  home="$TMP_ROOT/lock-dash-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-dash-fake")
  mkdir -p "$home/state"
  write_fake_ps "$fakebin" '
case "$*" in
  *"comm="*"-p 200"*) printf "%s\n" "bun"; exit 0 ;;
  *"args="*"-p 200"*) printf "%s\n" "bun /path/omp"; exit 0 ;;
  *"ppid="*"-p 200"*) printf "%s\n" "1"; exit 0 ;;
  *"comm="*) printf "%s\n" "-zsh"; exit 0 ;;
  *"args="*) printf "%s\n" "-zsh"; exit 0 ;;
  *"ppid="*) printf "%s\n" "200"; exit 0 ;;
esac
exit 1
'

  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1)
  status=$?
  err=$out
  expect_code 0 "$status" "fm-lock should continue past a leading-dash comm"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not continue from -zsh to omp parent"
  assert_not_contains "$err" "illegal option" "leading-dash comm triggered basename option parsing"
  pass "fm-lock handles leading-dash comm values without basename crashes"
}

test_fm_lock_does_not_false_match_omp_substrings() {
  local home fakebin out status
  home="$TMP_ROOT/lock-false-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-false-fake")
  mkdir -p "$home/state"
  write_fake_ps "$fakebin" '
case "$*" in
  *"comm="*) printf "%s\n" "bun"; exit 0 ;;
  *"args="*) printf "%s\n" "bun /x/compile component"; exit 0 ;;
  *"ppid="*) printf "%s\n" "1"; exit 0 ;;
esac
exit 1
'

  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" 2>&1)
  status=$?
  expect_code 1 "$status" "fm-lock should not acquire from compile/component substrings"
  assert_contains "$out" "error: cannot locate harness process in ancestry" "fm-lock failure did not prove the non-harness ancestry"
  pass "fm-lock omp regex rejects compile/component false matches"
}

test_fm_harness_uses_omp_env_marker() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT OMPCODE=1 "$ROOT/bin/fm-harness.sh")
  assert_contains "$out" "omp" "fm-harness did not use OMPCODE=1"
  pass "fm-harness detects omp from OMPCODE"
}

test_fm_harness_prefers_omp_over_claudecode() {
  local out
  out=$(env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 OMPCODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = "omp" ] || fail "fm-harness should prefer OMPCODE over CLAUDECODE when both are set; got '$out'"
  pass "fm-harness prefers OMPCODE over CLAUDECODE"
}

test_fm_harness_detects_omp_ancestry() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/harness-fake")
  write_fake_ps "$fakebin" '
case "$*" in
  *"comm="*) printf "%s\n" "bun"; exit 0 ;;
  *"args="*) printf "%s\n" "bun /Users/x/.bun/bin/omp"; exit 0 ;;
  *"ppid="*) printf "%s\n" "1"; exit 0 ;;
esac
exit 1
'

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u OMPCODE PATH="$fakebin:$PATH" "$ROOT/bin/fm-harness.sh")
  assert_contains "$out" "omp" "fm-harness did not detect bun-wrapped omp ancestry"
  pass "fm-harness detects omp through bun ancestry"
}

test_omp_busy_regex_matches_real_status_lines() {
  local regex
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  regex=$FM_TMUX_BUSY_REGEX_DEFAULT

  printf '%s\n' '⠹ Working... ⟨esc⟩' | grep -qiE "$regex" \
    || fail "busy regex did not match omp model status line"
  printf '%s\n' '⠴ Sleeping 5 seconds ⟨esc⟩' | grep -qiE "$regex" \
    || fail "busy regex did not match omp tool status line"
  if printf '%s\n' 'Done - sleep 5 completed successfully.' | grep -qiE "$regex"; then
    fail "busy regex matched an idle omp completion line"
  fi
  pass "busy regex matches real omp cancel-hint status lines only"
}

test_omp_rounded_composer_classification() {
  local fakebin capture idle_state text_state
  fakebin=$(fm_fakebin "$TMP_ROOT/rounded-composer-fake")
  capture="$TMP_ROOT/rounded-composer.txt"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
esac
case "${1:-}" in
  capture-pane) cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"

  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"

  printf '%s\n' "╰─                                            ─╯" > "$capture"
  idle_state=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" fm_tmux_composer_state fakepane)
  [ "$idle_state" = empty ] || fail "idle OMP rounded composer should read empty, got '$idle_state'"

  printf '%s\n' "╰─ review the patch ─╯" > "$capture"
  text_state=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$capture" fm_tmux_composer_state fakepane)
  [ "$text_state" = pending ] || fail "OMP rounded composer with text should read pending, got '$text_state'"

  pass "fm_tmux_composer_state classifies OMP rounded composer rows"
}

test_fm_lock_recognizes_omp_holder
test_fm_lock_acquire_finds_omp_harness_pid
test_fm_lock_dash_comm_is_safe_and_continues
test_fm_lock_does_not_false_match_omp_substrings
test_fm_harness_uses_omp_env_marker
test_fm_harness_prefers_omp_over_claudecode
test_fm_harness_detects_omp_ancestry
test_omp_busy_regex_matches_real_status_lines
test_omp_rounded_composer_classification
