#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-use-orca-tests)
USE_ORCA="$ROOT/bin/fm-use-orca.sh"

# Helper: stub orca + node + setsid + fmod + pkill into a clean fakebin.
# The fake orca is a no-op; the fake fmod is configurable per-test via
# FM_TEST_FMOD_OUT (the JSON written to stdout).
fakebin_full() {
  local case_dir=$1 fmod_out=${2:-'{"daemon_reachable":true,"daemon_pong":{"pong":true}}'}
  case_dir="$TMP_ROOT/$case_dir"
  mkdir -p "$case_dir"
  local fb="$case_dir/fakebin"
  mkdir -p "$fb"

  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/orca"

  cat > "$fb/node" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/node"

  cat > "$fb/setsid" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/setsid"

  cat > "$fb/fmod" <<SH
#!/usr/bin/env bash
printf '%s\n' "$fmod_out"
exit 0
SH
  chmod +x "$fb/fmod"

  cat > "$fb/pkill" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/pkill"

  cat > "$fb/fusermount" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/fusermount"

  printf '%s\n' "$fb"
}

# A scratch FM_ROOT-ish tree where we control config/ + state/.
fake_home() {
  local case_dir=$1
  local home="$TMP_ROOT/$case_dir/home"
  mkdir -p "$home/config" "$home/state" "$home/bin"
  # Mirror the bin scripts we need; symlinks keep the script content under test.
  ln -sf "$ROOT/bin/fm-supervise-orca.sh" "$home/bin/fm-supervise-orca.sh"
  printf '%s\n' "$home"
}

# Status command should report config/backend and supervisor state without mutating.
test_use_orca_status_reports_state_without_mutating() {
  local case_dir=fm-use-orca-status
  local home config state out_before out_after
  home=$(fake_home "$case_dir")
  config="$home/config"
  state="$home/state"

  printf 'orca\n' > "$config/backend"
  printf 'pi\n' > "$config/crew-harness"

  out_before=$(ls "$config" 2>&1; ls "$state" 2>&1)
  # Stub supervisor out so the script does not actually talk to fmod.
  local fake_status="$TMP_ROOT/$case_dir/fake-supervisor"
  cat > "$fake_status" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status)
    printf 'supervisor: not running\n'
    printf 'daemon:     reachable\n'
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fake_status"

  out=$(FM_HOME="$home" FM_ORCA_FMOD="$fake_status" "$USE_ORCA" status 2>&1)
  assert_contains "$out" "config/backend" "status should mention config/backend"
  assert_contains "$out" "orca" "status should show orca backend"
  assert_contains "$out" "supervisor" "status should mention supervisor"

  out_after=$(ls "$config" 2>&1; ls "$state" 2>&1)
  [ "$out_before" = "$out_after" ] || fail "status should not mutate state (before: $out_before, after: $out_after)"
  pass "use-orca status is read-only"
}

# status command should NOT print a sensitive token or daemon socket path.
test_use_orca_status_does_not_leak_paths() {
  local case_dir=fm-use-orca-leak
  local home config
  home=$(fake_home "$case_dir")
  config="$home/config"
  printf 'orca\n' > "$config/backend"

  local fake_status="$TMP_ROOT/$case_dir/fake-supervisor"
  cat > "$fake_status" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf 'supervisor: not running\ndaemon: reachable\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fake_status"

  local out
  out=$(FM_HOME="$home" FM_ORCA_FMOD="$fake_status" "$USE_ORCA" status 2>&1)
  # The status output is operator-facing; it must not print the daemon socket
  # path or token (those are environment-specific and not for logcat).
  assert_not_contains "$out" "daemon-v" "status must not print the versioned socket path"
  assert_not_contains "$out" ".token" "status must not print the token file path"
  pass "status output is operator-facing and does not leak paths"
}

# start writes config/backend = orca under the active FM_HOME.
# We use the real FM_ROOT (where the bin scripts live) but a temp state/ dir,
# backing up the real config/backend so the test does not pollute it.
test_use_orca_start_writes_config_backend() {
  local case_dir=fm-use-orca-isolated
  local home fake_root real_root_backup real_root_existed
  home=$(fake_home "$case_dir")
  fake_root="$TMP_ROOT/$case_dir/fakeroot"
  mkdir -p "$fake_root/config" "$fake_root/state"

  # Back up the real config/backend.
  real_root_existed=0
  if [ -f "$ROOT/config/backend" ]; then
    real_root_existed=1
    real_root_backup=$(cat "$ROOT/config/backend")
  fi

  local fb
  fb=$(fakebin_full "$case_dir")
  cat > "$fb/fm-supervise-orca.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  start|status|once) printf 'fake-supervisor: ok\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/fm-supervise-orca.sh"

  # Run use-orca against a fake FM_ROOT (so it writes under our temp dir).
  PATH="$fb:$PATH" FM_ROOT="$fake_root" FM_HOME="$fake_root" "$USE_ORCA" start >/dev/null 2>&1 || true

  assert_contains "$(cat "$fake_root/config/backend" 2>/dev/null)" "orca" "fake-root config/backend should be orca"
  if [ ! -f "$fake_root/config/crew-harness" ] || ! grep -q . "$fake_root/config/crew-harness"; then
    : # crew-harness is conditional; do not fail if absent (real one in ROOT is unchanged)
  fi

  # Restore the real config/backend so other tests and the actual repo state
  # are unaffected by this test.
  if [ "$real_root_existed" -eq 1 ]; then
    printf '%s' "$real_root_backup" > "$ROOT/config/backend"
  else
    rm -f "$ROOT/config/backend"
  fi

  pass "use-orca start writes config/backend = orca under FM_HOME"
}

# autostart install: an entry under XDG_CONFIG_HOME/autostart/ must be created
# when autostart install is requested. Idempotent on re-run.
test_use_orca_autostart_install_then_remove() {
  local case_dir=fm-use-orca-autostart
  local home autostart_dir
  home=$(fake_home "$case_dir")
  autostart_dir="$TMP_ROOT/$case_dir/autostart"
  mkdir -p "$autostart_dir"

  local fb
  fb=$(fakebin_full "$case_dir")

  # Install
  XDG_CONFIG_HOME="$TMP_ROOT/$case_dir" FM_HOME="$home" PATH="$fb:$PATH" \
    "$USE_ORCA" autostart install 2>&1 | tail -3
  [ -f "$autostart_dir/fm-supervise-orca.desktop" ] || fail "autostart install did not write the .desktop file"
  pass "autostart install wrote $autostart_dir/fm-supervise-orca.desktop"

  # Idempotent: a second install must not fail and the file must still exist.
  XDG_CONFIG_HOME="$TMP_ROOT/$case_dir" FM_HOME="$home" PATH="$fb:$PATH" \
    "$USE_ORCA" autostart install 2>&1 | tail -3
  [ -f "$autostart_dir/fm-supervise-orca.desktop" ] || fail "autostart re-install removed the file"
  pass "autostart install is idempotent"

  # Remove
  XDG_CONFIG_HOME="$TMP_ROOT/$case_dir" FM_HOME="$home" PATH="$fb:$PATH" \
    "$USE_ORCA" autostart remove 2>&1 | tail -3
  [ ! -f "$autostart_dir/fm-supervise-orca.desktop" ] || fail "autostart remove did not delete the file"
  pass "autostart remove deleted the file"
}

# stop: if no supervisor is running, stop should still succeed and report cleanly.
test_use_orca_stop_when_no_supervisor() {
  local case_dir=fm-use-orca-stop-noop
  local home
  home=$(fake_home "$case_dir")

  local fake_status="$TMP_ROOT/$case_dir/fake-supervisor"
  cat > "$fake_status" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  stop|status) printf 'supervisor: not running\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fake_status"

  local out rc
  set +e
  out=$(FM_HOME="$home" FM_ORCA_FMOD="$fake_status" "$USE_ORCA" stop 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "stop should exit 0 when nothing is running (got $rc)"
  assert_contains "$out" "not running" "stop should report supervisor as not running"
  pass "stop is idempotent when no supervisor is running"
}

# Build the test plan.
test_use_orca_status_reports_state_without_mutating
test_use_orca_status_does_not_leak_paths
test_use_orca_start_writes_config_backend
test_use_orca_autostart_install_then_remove
test_use_orca_stop_when_no_supervisor

if [ "${FAIL_COUNT:-0}" -eq 0 ]; then
  printf 'all use-orca tests passed\n'
  exit 0
fi
printf '%d use-orca test(s) failed\n' "${FAIL_COUNT}"
exit 1