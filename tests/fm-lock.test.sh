#!/usr/bin/env bash
# tests/fm-lock.test.sh - typed session-lock outcomes and atomic reclaim tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-lock-tests)
HOLDER_PID=

cleanup() {
  if [ -n "$HOLDER_PID" ]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

new_home() {
  local name=$1 home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$TMP_ROOT/$name/fakebin"
  printf '%s|%s\n' "$home" "$TMP_ROOT/$name/fakebin"
}

make_ps_denied() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"
}

make_ps_all_claude() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_stale_numeric_owner_with_denied_ps_is_reclaimed() {
  local rec home fakebin out rc=0
  rec=$(new_home stale-numeric-denied-ps)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "stale numeric owner with denied ps"
  assert_contains "$out" "LOCK_RESULT=OWNED" "stale numeric owner was not reclaimed as OWNED"
  assert_grep "codex-thread:current-thread" "$home/state/.lock" "reclaim did not install the current Codex thread owner"
  pass "stale numeric owner is reclaimed through Codex identity when ps is denied"
}

test_live_numeric_owner_with_denied_ps_is_not_reclaimed() {
  local rec home fakebin out rc=0
  rec=$(new_home live-numeric-denied-ps)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  sleep 300 &
  HOLDER_PID=$!
  printf '%s\n' "$HOLDER_PID" > "$home/state/.lock"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "live numeric owner with denied ps was reclaimed"
  assert_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "ambiguous live numeric owner was not classified separately"
  assert_grep "$HOLDER_PID" "$home/state/.lock" "ambiguous live numeric owner was overwritten"
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
  pass "live numeric owner is preserved when ps cannot verify its identity"
}

test_same_codex_thread_with_denied_ps_is_owned() {
  local rec home fakebin out rc=0
  rec=$(new_home same-codex-thread)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf 'codex-thread:current-thread\n' > "$home/state/.lock"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "same Codex thread with denied ps"
  assert_contains "$out" "LOCK_RESULT=OWNED" "same Codex thread was not recognized as the owner"
  assert_grep "codex-thread:current-thread" "$home/state/.lock" "same Codex thread lock changed unexpectedly"
  pass "same Codex thread is recognized without ps"
}

test_different_codex_thread_is_not_assumed_stale() {
  local rec home fakebin out rc=0
  rec=$(new_home different-codex-thread)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf 'codex-thread:other-thread\n' > "$home/state/.lock"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "different Codex thread was treated as reclaimable"
  assert_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "different Codex thread was not classified as unverifiable"
  assert_not_contains "$out" "STALE_RECLAIMABLE" "different Codex thread was classified as stale"
  assert_grep "codex-thread:other-thread" "$home/state/.lock" "different Codex thread lock was overwritten"
  pass "different Codex thread is not assumed stale without a lifecycle proof"
}

test_live_numeric_owner_with_readable_identity_is_live_other() {
  local rec home fakebin out rc=0
  rec=$(new_home live-numeric-readable)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_all_claude "$fakebin"
  sleep 300 &
  HOLDER_PID=$!
  printf '%s\n' "$HOLDER_PID" > "$home/state/.lock"

  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "different live numeric owner was accepted"
  assert_contains "$out" "LOCK_RESULT=LIVE_OTHER" "verified live numeric owner did not produce LIVE_OTHER"
  assert_grep "$HOLDER_PID" "$home/state/.lock" "verified live numeric owner was overwritten"
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
  pass "readable live numeric owner is classified as LIVE_OTHER"
}

test_status_reports_stale_reclaimable() {
  local rec home fakebin out rc=0
  rec=$(new_home status-stale)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"

  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" status 2>&1) || rc=$?

  expect_code 0 "$rc" "status for stale numeric owner"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "status did not expose the stale typed outcome"
  pass "status exposes STALE_RECLAIMABLE for a dead numeric owner"
}

test_reclaim_rejects_wrong_expected_owner() {
  local rec home fakebin out rc=0
  rec=$(new_home reclaim-wrong-expected)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected 888888 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "reclaim accepted the wrong expected owner"
  assert_contains "$out" "LOCK_RESULT=" "wrong expected owner reclaim omitted LOCK_RESULT"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "wrong expected owner did not reclassify the real stale owner"
  assert_contains "$out" "reclaim refused" "wrong expected owner refusal was not explicit"
  assert_grep "999999" "$home/state/.lock" "wrong expected owner changed the lock"
  pass "reclaim refuses when the expected owner no longer matches"
}

test_reclaim_rechecks_owner_inside_mutex() {
  local rec home fakebin out rc=0
  rec=$(new_home reclaim-owner-changed)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  sleep 300 &
  HOLDER_PID=$!
  printf '%s\n' "$HOLDER_PID" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = "-p" ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ "$pid" = "$FM_FAKE_HOLDER_PID" ]; then
      printf '888888\n' > "$FM_FAKE_LOCK_PATH"
      printf '/bin/zsh\n'
    else
      printf '/usr/local/bin/claude\n'
    fi
    exit 0
    ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FM_FAKE_HOLDER_PID="$HOLDER_PID" FM_FAKE_LOCK_PATH="$home/state/.lock" \
    FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected "$HOLDER_PID" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "reclaim overwrote an owner that changed before the mutex recheck"
  assert_contains "$out" "LOCK_RESULT=" "owner-changed reclaim omitted LOCK_RESULT"
  assert_contains "$out" "owner changed" "reclaim did not report its in-mutex compare failure"
  assert_grep "888888" "$home/state/.lock" "reclaim overwrote the changed owner"
  kill "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
  pass "reclaim compares the expected owner again inside the reclaim mutex"
}

test_orphan_reclaim_mutex_with_stale_lock_recovers() {
  local rec home fakebin out rc=0
  rec=$(new_home orphan-mutex-stale)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  printf '888888\n' > "$home/state/.lock-reclaim/pid"
  printf '1\n' > "$home/state/.lock-reclaim/started"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "orphan reclaim mutex with stale lock"
  assert_contains "$out" "LOCK_RESULT=OWNED" "orphan mutex blocked stale reclaim permanently"
  assert_grep "codex-thread:current-thread" "$home/state/.lock" "orphan-mutex stale reclaim did not install owner"
  [ ! -e "$home/state/.lock-reclaim" ] || fail "orphan reclaim mutex was left behind after recovery"
  pass "orphan reclaim mutex plus stale lock recovers without permanent jam"
}

test_orphan_reclaim_mutex_with_free_lock_recovers() {
  local rec home fakebin out rc=0
  rec=$(new_home orphan-mutex-free)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  mkdir "$home/state/.lock-reclaim"
  # Legacy orphan: mkdir only, no owner PID. Age threshold 0 forces recovery.
  out=$(CODEX_THREAD_ID=free-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_MUTEX_STALE_AFTER=0 FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "orphan reclaim mutex with free lock"
  assert_contains "$out" "LOCK_RESULT=OWNED" "orphan mutex blocked free-lock claim permanently"
  assert_grep "codex-thread:free-thread" "$home/state/.lock" "orphan-mutex free claim did not install owner"
  [ ! -e "$home/state/.lock-reclaim" ] || fail "orphan reclaim mutex was left behind after free claim"
  pass "orphan reclaim mutex plus free lock recovers without permanent jam"
}

test_live_reclaim_mutex_owner_is_not_taken() {
  local rec home fakebin out rc=0
  rec=$(new_home live-mutex-owner)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  # This test process is alive; the mutex owner must not be overridden.
  printf '%s\n' "$$" > "$home/state/.lock-reclaim/pid"
  date +%s > "$home/state/.lock-reclaim/started"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "live reclaim mutex owner was overridden"
  assert_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "live mutex contention was not typed as RECLAIM_BUSY"
  assert_not_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "live mutex busy was mislabeled identity failure"
  assert_grep "999999" "$home/state/.lock" "live mutex path overwrote the session lock"
  assert_grep "$$" "$home/state/.lock-reclaim/pid" "live mutex owner file was removed"
  # status still reports the real main-lock state (independent of mutex busy).
  rc=0
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" status 2>&1) || rc=$?
  expect_code 0 "$rc" "status during live mutex hold"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "status lost stale classification during mutex busy"
  pass "live reclaim mutex owner is never taken over"
}

test_reclaim_failure_paths_always_emit_lock_result() {
  local rec home fakebin out rc=0
  rec=$(new_home reclaim-typed-failures)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"

  # Free lock + reclaim
  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected 999999 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "reclaim on free lock succeeded"
  assert_contains "$out" "LOCK_RESULT=" "free-lock reclaim omitted LOCK_RESULT"

  # Wrong expected on foreign codex (identity unavailable path)
  rc=0
  printf 'codex-thread:other-thread\n' > "$home/state/.lock"
  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected codex-thread:other-thread 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unconfirmed foreign codex reclaim succeeded"
  assert_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "foreign codex reclaim omitted typed result"

  # Confirmed path refused when expected mismatches
  rc=0
  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected codex-thread:missing-thread --confirmed-closed 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "confirmed reclaim accepted mismatched expected owner"
  assert_contains "$out" "LOCK_RESULT=" "confirmed mismatch reclaim omitted LOCK_RESULT"

  pass "every reclaim failure path emits LOCK_RESULT"
}

test_confirmed_closed_codex_owner_is_reclaimed_exactly() {
  local rec home fakebin out rc=0
  rec=$(new_home reclaim-confirmed-codex)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf 'codex-thread:other-thread\n' > "$home/state/.lock"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected codex-thread:other-thread --confirmed-closed 2>&1) || rc=$?

  expect_code 0 "$rc" "confirmed closed Codex owner reclaim"
  assert_contains "$out" "LOCK_RESULT=OWNED" "confirmed closed Codex owner was not reclaimed"
  assert_grep "codex-thread:current-thread" "$home/state/.lock" "confirmed reclaim did not install the exact current owner"
  pass "explicit closed-window confirmation enables targeted Codex owner reclaim"
}

test_unconditional_clear_is_refused() {
  local rec home fakebin out rc=0
  rec=$(new_home clear-refused)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf 'codex-thread:other-thread\n' > "$home/state/.lock"

  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" clear 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "unconditional clear command succeeded"
  assert_contains "$out" "unconditional clear is not supported" "clear refusal did not direct callers to expected-owner reclaim"
  assert_grep "codex-thread:other-thread" "$home/state/.lock" "clear refusal removed the lock"
  pass "unconditional clear is unavailable and preserves the recorded owner"
}

flock_helper_present() {
  command -v perl >/dev/null 2>&1
}

# Hold the flock(2) form of a mutex file from a disposable process; prints
# nothing, touches $2 once the lock is held, then sleeps until killed.
write_flock_holder() {
  local holder=$1
  cat > "$holder" <<'SH'
#!/usr/bin/env bash
exec 9<>"$1" || exit 3
perl -e '
use Fcntl qw(:flock);
open(my $fh, "+<&=", 9) or exit 3;
flock($fh, LOCK_EX | LOCK_NB) or exit 1;
' || exit 1
touch "$2"
exec sleep 300
SH
  chmod +x "$holder"
}

test_flock_reclaim_mutex_busy_then_released_by_death() {
  local rec home fakebin out rc=0 marker holder
  if ! flock_helper_present; then
    pass "flock helper unavailable here; mkdir fallback tests cover this home"
    return 0
  fi
  rec=$(new_home flock-death-release)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  marker="$TMP_ROOT/flock-death-release/held"
  holder="$TMP_ROOT/flock-death-release/holder.sh"
  write_flock_holder "$holder"
  "$holder" "$home/state/.lock-reclaim" "$marker" &
  HOLDER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$marker" ] && break
    sleep 0.1
  done
  [ -e "$marker" ] || fail "flock holder did not report holding the reclaim mutex"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "reclaim proceeded while a live process held the flock mutex"
  assert_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "live flock mutex contention was not typed as RECLAIM_BUSY"
  assert_grep "999999" "$home/state/.lock" "flock mutex contention overwrote the session lock"

  kill -9 "$HOLDER_PID" 2>/dev/null || true
  wait "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=

  rc=0
  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?
  expect_code 0 "$rc" "reclaim after flock holder death"
  assert_contains "$out" "LOCK_RESULT=OWNED" "killed flock holder left an orphaned reclaim mutex jam"
  assert_grep "codex-thread:current-thread" "$home/state/.lock" "post-death reclaim did not install the current owner"
  [ ! -e "$home/state/.lock-reclaim" ] || fail "reclaim mutex file was left behind after clean release"
  pass "kernel releases the flock reclaim mutex on holder death; no orphan jam"
}

test_flock_crash_leftover_files_recover() {
  local rec home fakebin out rc=0
  if ! flock_helper_present; then
    pass "flock helper unavailable here; mkdir fallback tests cover this home"
    return 0
  fi
  rec=$(new_home flock-crash-leftovers)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  # As after kill -9: both mutex files exist on disk but nothing holds them.
  : > "$home/state/.lock.acquire"
  : > "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "acquire over unlocked crash-leftover mutex files"
  assert_contains "$out" "LOCK_RESULT=OWNED" "crash-leftover mutex files jammed the acquisition"
  assert_grep "codex-thread:current-thread" "$home/state/.lock" "crash-leftover recovery did not install the owner"
  [ ! -e "$home/state/.lock.acquire" ] || fail "claim mutex file was left behind after clean release"
  [ ! -e "$home/state/.lock-reclaim" ] || fail "reclaim mutex file was left behind after clean release"
  pass "crash-leftover flock mutex files are unlocked and never jam"
}

test_fallback_without_helper_recovers_and_stays_typed() {
  local rec home fakebin out rc=0
  rec=$(new_home fallback-no-flock)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  printf '888888\n' > "$home/state/.lock-reclaim/pid"
  printf '1\n' > "$home/state/.lock-reclaim/started"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_LOCK_NO_FLOCK=1 FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?
  expect_code 0 "$rc" "mkdir fallback reclaim without the flock helper"
  assert_contains "$out" "LOCK_RESULT=OWNED" "mkdir fallback did not reclaim a stale owner"
  assert_grep "codex-thread:current-thread" "$home/state/.lock" "mkdir fallback did not install the owner"
  [ ! -e "$home/state/.lock-reclaim" ] || fail "mkdir fallback left the recovered mutex behind"

  # A live directory-form owner still yields the typed busy result.
  rc=0
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  printf '%s\n' "$$" > "$home/state/.lock-reclaim/pid"
  date +%s > "$home/state/.lock-reclaim/started"
  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_LOCK_NO_FLOCK=1 FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "mkdir fallback overrode a live mutex owner"
  assert_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "mkdir fallback lost the typed busy result"
  rm -rf "$home/state/.lock-reclaim"
  pass "mkdir fallback works without the flock helper and keeps typed results"
}

# A crash-leftover flock-form mutex file can neither be taken nor proven
# abandoned by the mkdir fallback, so it must report the typed unavailable
# result instead of a busy state that no retry could ever clear.
test_fallback_flock_leftover_file_is_typed_unavailable() {
  local rec home fakebin out rc=0
  rec=$(new_home fallback-flock-leftover)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  : > "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_LOCK_NO_FLOCK=1 FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?
  expect_code 12 "$rc" "stale reclaim over a flock-form mutex file without the helper"
  assert_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "leftover flock mutex file was reported as a retryable state"
  assert_contains "$out" "state/.lock-reclaim" "the typed result did not name the unusable reclaim mutex"
  assert_grep "999999" "$home/state/.lock" "the refused reclaim changed the session lock"

  rc=0
  rm -f "$home/state/.lock"
  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_LOCK_NO_FLOCK=1 FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?
  expect_code 12 "$rc" "free-lock claim over a flock-form mutex file without the helper"
  assert_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "free-lock claim lost the typed unavailable result"
  [ ! -e "$home/state/.lock" ] || fail "free-lock claim published an owner through an unusable mutex"
  pass "leftover flock mutex file without the helper is typed, never endlessly busy"
}

test_concurrent_acquisitions_admit_one_winner() {
  local rec home fakebin outdir i owned rc=0 winner
  rec=$(new_home concurrent-single-winner)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  outdir="$TMP_ROOT/concurrent-single-winner/out"
  mkdir -p "$outdir"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    (
      CODEX_THREAD_ID="thread-$i" FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
        "$LOCK" > "$outdir/$i.out" 2>&1
    ) &
  done
  wait
  owned=$(grep -l 'LOCK_RESULT=OWNED' "$outdir"/*.out | wc -l | tr -d ' ')
  [ "$owned" = 1 ] || fail "expected exactly one OWNED winner, got $owned"
  winner=$(cat "$home/state/.lock")
  case "$winner" in
    codex-thread:thread-*) ;;
    *) fail "published owner '$winner' is not one of the contenders" ;;
  esac
  rc=0
  grep -q "LOCK_RESULT=OWNED" "$outdir/${winner#codex-thread:thread-}.out" || rc=$?
  expect_code 0 "$rc" "published owner matches the OWNED contender"
  pass "concurrent acquisitions admit exactly one winner"
}

run_one() {
  case "$1" in
    stale-numeric) test_stale_numeric_owner_with_denied_ps_is_reclaimed ;;
    live-numeric-denied) test_live_numeric_owner_with_denied_ps_is_not_reclaimed ;;
    same-codex) test_same_codex_thread_with_denied_ps_is_owned ;;
    different-codex) test_different_codex_thread_is_not_assumed_stale ;;
    live-other) test_live_numeric_owner_with_readable_identity_is_live_other ;;
    status-stale) test_status_reports_stale_reclaimable ;;
    wrong-expected) test_reclaim_rejects_wrong_expected_owner ;;
    owner-changed) test_reclaim_rechecks_owner_inside_mutex ;;
    confirmed-codex) test_confirmed_closed_codex_owner_is_reclaimed_exactly ;;
    clear-refused) test_unconditional_clear_is_refused ;;
    orphan-mutex-stale) test_orphan_reclaim_mutex_with_stale_lock_recovers ;;
    orphan-mutex-free) test_orphan_reclaim_mutex_with_free_lock_recovers ;;
    live-mutex) test_live_reclaim_mutex_owner_is_not_taken ;;
    typed-failures) test_reclaim_failure_paths_always_emit_lock_result ;;
    flock-death-release) test_flock_reclaim_mutex_busy_then_released_by_death ;;
    flock-crash-leftovers) test_flock_crash_leftover_files_recover ;;
    fallback-no-flock) test_fallback_without_helper_recovers_and_stays_typed ;;
    fallback-flock-leftover) test_fallback_flock_leftover_file_is_typed_unavailable ;;
    single-winner) test_concurrent_acquisitions_admit_one_winner ;;
    *) fail "unknown test selector: $1" ;;
  esac
}

if [ "$#" -gt 0 ]; then
  run_one "$1"
else
  test_stale_numeric_owner_with_denied_ps_is_reclaimed
  test_live_numeric_owner_with_denied_ps_is_not_reclaimed
  test_same_codex_thread_with_denied_ps_is_owned
  test_different_codex_thread_is_not_assumed_stale
  test_live_numeric_owner_with_readable_identity_is_live_other
  test_status_reports_stale_reclaimable
  test_reclaim_rejects_wrong_expected_owner
  test_reclaim_rechecks_owner_inside_mutex
  test_confirmed_closed_codex_owner_is_reclaimed_exactly
  test_unconditional_clear_is_refused
  test_orphan_reclaim_mutex_with_stale_lock_recovers
  test_orphan_reclaim_mutex_with_free_lock_recovers
  test_live_reclaim_mutex_owner_is_not_taken
  test_reclaim_failure_paths_always_emit_lock_result
  test_flock_reclaim_mutex_busy_then_released_by_death
  test_flock_crash_leftover_files_recover
  test_fallback_without_helper_recovers_and_stays_typed
  test_fallback_flock_leftover_file_is_typed_unavailable
  test_concurrent_acquisitions_admit_one_winner
fi
