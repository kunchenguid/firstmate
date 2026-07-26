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
  [ -z "$(find "$home/state" -name '.lock-reclaim-retired*' -print)" ] \
    || fail "detached reclaim mutex quarantine was not removed"
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

test_aged_legacy_reclaim_mutex_recovers() {
  local rec home fakebin out rc=0
  rec=$(new_home aged-legacy-mutex)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  mkdir "$home/state/.lock-reclaim"
  touch -t 200001010000 "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=legacy-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "aged legacy reclaim mutex"
  assert_contains "$out" "LOCK_RESULT=OWNED" "aged no-pid mutex did not recover"
  [ ! -e "$home/state/.lock-reclaim" ] || fail "aged legacy mutex remained canonical"
  pass "aged legacy no-pid reclaim mutex recovers"
}

test_orphaned_nested_claim_does_not_jam_recovery() {
  local rec home fakebin out rc=0
  rec=$(new_home orphaned-nested-claim)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  mkdir -p "$home/state/.lock-reclaim/.reclaim-claim"
  touch -t 200001010000 "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=claim-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "orphaned nested reclaim claim"
  assert_contains "$out" "LOCK_RESULT=OWNED" "orphaned nested claim jammed recovery"
  [ ! -e "$home/state/.lock-reclaim" ] || fail "orphaned nested claim remained canonical"
  pass "orphaned nested reclaim claims cannot jam the canonical mutex"
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

test_abandonment_marker_does_not_override_live_owner() {
  local rec home fakebin generation out rc=0
  rec=$(new_home live-owner-with-marker)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  printf '%s\n' "$$" > "$home/state/.lock-reclaim/pid"
  printf '1\n' > "$home/state/.lock-reclaim/started"
  if [ "$(uname)" = Darwin ]; then
    generation=$(stat -f '%d.%i' "$home/state/.lock-reclaim")
  else
    generation=$(stat -c '%d.%i' "$home/state/.lock-reclaim")
  fi
  mkdir "$home/state/.lock-reclaim/.reclaim-abandoned-$generation"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 13 "$rc" "live reclaim owner with abandonment marker"
  assert_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "marker bypassed the live-owner proof"
  assert_grep "$$" "$home/state/.lock-reclaim/pid" "marker caused live mutex removal"
  pass "abandonment markers never replace live-owner proof"
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

  for args in \
    "reclaim" \
    "reclaim --expected" \
    "reclaim --bogus" \
    "reclaim --expected 999999 --confirmed-closed"
  do
    rc=0
    # shellcheck disable=SC2086 # Each case intentionally supplies multiple CLI arguments.
    out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$LOCK" $args 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "invalid reclaim invocation succeeded: $args"
    assert_contains "$out" "LOCK_RESULT=" "invalid reclaim invocation omitted LOCK_RESULT: $args"
  done

  pass "every reclaim failure path emits LOCK_RESULT"
}

test_reclaim_mutex_symlink_is_not_followed() {
  local rec home fakebin outside out rc=0
  rec=$(new_home mutex-symlink)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  outside="$TMP_ROOT/mutex-symlink/outside"
  mkdir -p "$outside"
  printf '999999\n' > "$home/state/.lock"
  printf '%s\n' "$$" > "$outside/pid"
  printf 'sentinel\n' > "$outside/started"
  ln -s "$outside" "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 11 "$rc" "symlink reclaim mutex"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "symlink mutex I/O hid the stale main lock"
  assert_not_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "symlink mutex was mislabeled contention"
  assert_grep "$$" "$outside/pid" "symlink mutex traversal removed the foreign pid"
  assert_grep "sentinel" "$outside/started" "symlink mutex traversal removed the foreign timestamp"
  [ -L "$home/state/.lock-reclaim" ] || fail "symlink mutex was unexpectedly replaced"
  pass "reclaim mutex symlinks are never traversed"
}

test_generation_symlinks_are_not_followed() {
  local rec home fakebin outside generation out rc=0
  rec=$(new_home generation-symlink)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  outside="$TMP_ROOT/generation-symlink/outside"
  mkdir -p "$outside" "$home/state/.lock-reclaim"
  printf '999999\n' > "$home/state/.lock"
  printf 'foreign-pid\n' > "$outside/pid"
  printf 'foreign-started\n' > "$outside/started"
  if [ "$(uname)" = Darwin ]; then
    generation=$(stat -f '%d.%i' "$home/state/.lock-reclaim")
  else
    generation=$(stat -c '%d.%i' "$home/state/.lock-reclaim")
  fi
  ln -s "$outside" "$home/state/.lock-reclaim/.generation-claimed-$generation"
  touch -t 200001010000 "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 11 "$rc" "symlinked generation claim"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "generation symlink hid stale main-lock state"
  assert_not_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "generation symlink was mislabeled contention"
  assert_grep "foreign-pid" "$outside/pid" "generation symlink overwrote foreign pid"
  assert_grep "foreign-started" "$outside/started" "generation symlink overwrote foreign timestamp"
  [ -L "$home/state/.lock-reclaim/.generation-claimed-$generation" ] \
    || fail "generation symlink was unexpectedly replaced"

  rc=0
  rec=$(new_home generation-metadata-symlink)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  outside="$TMP_ROOT/generation-metadata-symlink/outside"
  mkdir -p "$outside" "$home/state/.lock-reclaim"
  printf '999999\n' > "$home/state/.lock"
  printf 'foreign-metadata\n' > "$outside/pid"
  if [ "$(uname)" = Darwin ]; then
    generation=$(stat -f '%d.%i' "$home/state/.lock-reclaim")
  else
    generation=$(stat -c '%d.%i' "$home/state/.lock-reclaim")
  fi
  mkdir "$home/state/.lock-reclaim/.generation-claimed-$generation"
  ln -s "$outside/pid" "$home/state/.lock-reclaim/.generation-claimed-$generation/pid"
  touch -t 200001010000 "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 11 "$rc" "symlinked generation metadata"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "metadata symlink hid stale main-lock state"
  assert_not_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "metadata symlink was mislabeled contention"
  assert_grep "foreign-metadata" "$outside/pid" "generation metadata symlink was overwritten"
  pass "generation gate symlinks are classified without traversal"
}

test_nonregular_mutex_metadata_is_rejected() {
  local rec home fakebin generation out rc=0
  rec=$(new_home nonregular-metadata)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  mkfifo "$home/state/.lock-reclaim/pid"
  touch -t 200001010000 "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 11 "$rc" "nonregular canonical mutex metadata"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "canonical FIFO hid stale main-lock state"
  assert_not_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "canonical FIFO was mislabeled contention"

  rc=0
  rec=$(new_home nonregular-claim-metadata)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  if [ "$(uname)" = Darwin ]; then
    generation=$(stat -f '%d.%i' "$home/state/.lock-reclaim")
  else
    generation=$(stat -c '%d.%i' "$home/state/.lock-reclaim")
  fi
  mkdir "$home/state/.lock-reclaim/.generation-claimed-$generation"
  mkfifo "$home/state/.lock-reclaim/.generation-claimed-$generation/pid"
  touch -t 200001010000 "$home/state/.lock-reclaim"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 11 "$rc" "nonregular generation metadata"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "generation FIFO hid stale main-lock state"
  assert_not_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "generation FIFO was mislabeled contention"
  pass "nonregular mutex metadata is rejected without blocking"
}

test_interrupted_reclaim_emits_typed_result() {
  local rec home fakebin out child rc=0
  rec=$(new_home interrupted-reclaim)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  out="$TMP_ROOT/interrupted-reclaim/output"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  printf '%s\n' "$$" > "$home/state/.lock-reclaim/pid"
  date +%s > "$home/state/.lock-reclaim/started"

  CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=20 FM_RECLAIM_BUSY_SLEEP_SECS=0.2 \
    "$LOCK" reclaim --expected 999999 > "$out" 2>&1 &
  child=$!
  sleep 0.1
  kill -TERM "$child"
  wait "$child" || rc=$?

  expect_code 143 "$rc" "interrupted reclaim"
  assert_grep "LOCK_RESULT=STALE_RECLAIMABLE" "$out" "signal-interrupted reclaim omitted typed stale result"
  pass "signal-interrupted reclaim emits a typed main-lock result"
}

test_generation_claim_uses_configured_threshold() {
  local rec home fakebin generation out rc=0
  rec=$(new_home generation-claim-threshold)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  mkdir "$home/state/.lock-reclaim"
  printf '888888\n' > "$home/state/.lock-reclaim/pid"
  printf '1\n' > "$home/state/.lock-reclaim/started"
  if [ "$(uname)" = Darwin ]; then
    generation=$(stat -f '%d.%i' "$home/state/.lock-reclaim")
  else
    generation=$(stat -c '%d.%i' "$home/state/.lock-reclaim")
  fi
  mkdir "$home/state/.lock-reclaim/.generation-claim-$generation"
  touch -t 200001010000 "$home/state/.lock-reclaim/.generation-claim-$generation"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_MUTEX_STALE_AFTER=999999999 FM_RECLAIM_BUSY_RETRIES=0 \
    "$LOCK" 2>&1) || rc=$?

  expect_code 13 "$rc" "configured generation-claim threshold"
  assert_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "claim ignored the configured grace threshold"

  rc=0
  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_MUTEX_STALE_AFTER=0 FM_RECLAIM_BUSY_RETRIES=0 \
    "$LOCK" 2>&1) || rc=$?

  expect_code 0 "$rc" "abandoned generation claim recovery"
  assert_contains "$out" "LOCK_RESULT=OWNED" "abandoned generation claim did not recover"
  [ -n "$(find "$home/state" -type d -name '.lock-reclaim-claim-retired*' -print -quit)" ] \
    || fail "generation-claim tombstone was not retained"
  pass "generation claims honor the configured abandonment threshold"
}

test_state_path_failure_is_not_reclaim_busy() {
  local rec home fakebin out rc=0
  rec=$(new_home invalid-state-path)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  rm -rf "$home/state"
  printf 'not-a-directory\n' > "$home/state"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 12 "$rc" "invalid state path"
  assert_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "state I/O failure lacked a typed result"
  assert_not_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "state I/O failure was mislabeled mutex contention"
  pass "state directory failures are distinct from reclaim contention"
}

test_reclaim_owner_publication_failure_is_not_busy() {
  local rec home fakebin out rc=0
  rec=$(new_home publication-failure)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/date"
  chmod +x "$fakebin/date"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    FM_RECLAIM_BUSY_RETRIES=0 "$LOCK" 2>&1) || rc=$?

  expect_code 12 "$rc" "reclaim owner publication failure"
  assert_contains "$out" "LOCK_RESULT=IDENTITY_UNAVAILABLE" "metadata publication failure lacked I/O classification"
  assert_not_contains "$out" "LOCK_RESULT=RECLAIM_BUSY" "metadata publication failure was mislabeled contention"
  pass "reclaim owner publication failures are distinct from contention"
}

test_stale_reclaim_write_failure_stays_stale() {
  local rec home fakebin out rc=0
  rec=$(new_home stale-write-failure)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/mv"
  chmod +x "$fakebin/mv"

  out=$(CODEX_THREAD_ID=current-thread FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected 999999 2>&1) || rc=$?

  expect_code 11 "$rc" "stale reclaim write failure"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "write failure hid the stale main lock"
  assert_grep "999999" "$home/state/.lock" "write failure changed the stale owner"
  pass "main-lock write failures preserve stale classification"
}

test_stale_reclaim_identity_failure_stays_stale() {
  local rec home fakebin out rc=0
  rec=$(new_home stale-identity-failure)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_ps_denied "$fakebin"
  printf '999999\n' > "$home/state/.lock"

  out=$(/usr/bin/env -u CODEX_THREAD_ID FM_HOME="$home" PATH="$fakebin:$BASE_PATH" \
    "$LOCK" reclaim --expected 999999 2>&1) || rc=$?

  expect_code 11 "$rc" "stale reclaim identity failure"
  assert_contains "$out" "LOCK_RESULT=STALE_RECLAIMABLE" "identity failure hid the stale main lock"
  pass "pre-mutex identity failures preserve stale classification"
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
    aged-legacy-mutex) test_aged_legacy_reclaim_mutex_recovers ;;
    orphaned-nested-claim) test_orphaned_nested_claim_does_not_jam_recovery ;;
    live-mutex) test_live_reclaim_mutex_owner_is_not_taken ;;
    live-marker) test_abandonment_marker_does_not_override_live_owner ;;
    typed-failures) test_reclaim_failure_paths_always_emit_lock_result ;;
    mutex-symlink) test_reclaim_mutex_symlink_is_not_followed ;;
    generation-symlink) test_generation_symlinks_are_not_followed ;;
    nonregular-metadata) test_nonregular_mutex_metadata_is_rejected ;;
    interrupted-reclaim) test_interrupted_reclaim_emits_typed_result ;;
    claim-threshold) test_generation_claim_uses_configured_threshold ;;
    invalid-state) test_state_path_failure_is_not_reclaim_busy ;;
    publication-failure) test_reclaim_owner_publication_failure_is_not_busy ;;
    stale-write-failure) test_stale_reclaim_write_failure_stays_stale ;;
    stale-identity-failure) test_stale_reclaim_identity_failure_stays_stale ;;
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
  test_aged_legacy_reclaim_mutex_recovers
  test_orphaned_nested_claim_does_not_jam_recovery
  test_live_reclaim_mutex_owner_is_not_taken
  test_abandonment_marker_does_not_override_live_owner
  test_reclaim_failure_paths_always_emit_lock_result
  test_reclaim_mutex_symlink_is_not_followed
  test_generation_symlinks_are_not_followed
  test_nonregular_mutex_metadata_is_rejected
  test_interrupted_reclaim_emits_typed_result
  test_generation_claim_uses_configured_threshold
  test_state_path_failure_is_not_reclaim_busy
  test_reclaim_owner_publication_failure_is_not_busy
  test_stale_reclaim_write_failure_stays_stale
  test_stale_reclaim_identity_failure_stays_stale
fi
