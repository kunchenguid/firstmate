#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-use-orca-tests)
USE_ORCA="$ROOT/bin/fm-use-orca.sh"

# Helper: stub orca + setsid + fmod + pkill into a clean fakebin.
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
  local fmod_log="$TMP_ROOT/$case_dir/fmod.log"
  cat > "$fake_status" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_FMOD_LOG:?}"
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

  out=$(FM_HOME="$home" FM_ORCA_FMOD="$fake_status" FM_TEST_FMOD_LOG="$fmod_log" "$USE_ORCA" status 2>&1)
  assert_contains "$out" "config/backend" "status should mention config/backend"
  assert_contains "$out" "orca" "status should show orca backend"
  assert_contains "$out" "supervisor" "status should mention supervisor"
  assert_grep "ping" "$fmod_log" "status should probe daemon through FM_ORCA_FMOD"

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
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$fake_root" "$USE_ORCA" start >/dev/null 2>&1 || true

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
  local state_override="$TMP_ROOT/$case_dir/state-override"
  local orca_override="$fb/orca"
  local fmod_override="$fb/fmod"

  # Install
  XDG_CONFIG_HOME="$TMP_ROOT/$case_dir" FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" \
    FM_ORCA_BIN="$orca_override" FM_ORCA_FMOD="$fmod_override" PATH="$fb:$PATH" \
    "$USE_ORCA" autostart install 2>&1 | tail -3
  [ -f "$autostart_dir/fm-supervise-orca.desktop" ] || fail "autostart install did not write the .desktop file"
  assert_grep "\"FM_HOME=$home\"" "$autostart_dir/fm-supervise-orca.desktop" "autostart should preserve the active FM_HOME"
  assert_grep "\"FM_STATE_OVERRIDE=$state_override\"" "$autostart_dir/fm-supervise-orca.desktop" "autostart should preserve FM_STATE_OVERRIDE"
  assert_grep "\"FM_ORCA_BIN=$orca_override\"" "$autostart_dir/fm-supervise-orca.desktop" "autostart should preserve FM_ORCA_BIN"
  assert_grep "\"FM_ORCA_FMOD=$fmod_override\"" "$autostart_dir/fm-supervise-orca.desktop" "autostart should preserve FM_ORCA_FMOD"
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

test_use_orca_smoke_uses_configured_project_and_fm_home_data() {
  local case_dir=fm-use-orca-smoke-project
  local home fake_root project log data_override
  home=$(fake_home "$case_dir")
  fake_root="$TMP_ROOT/$case_dir/fakeroot"
  project="$TMP_ROOT/$case_dir/project"
  log="$TMP_ROOT/$case_dir/spawn.log"
  data_override="$TMP_ROOT/$case_dir/data-override"
  mkdir -p "$fake_root/bin" "$project" "$home/data" "$home/state"
  fm_git_init_commit "$project"

  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_SPAWN_LOG:?}"
mkdir -p "$FM_HOME/state"
touch "$FM_HOME/state/$1.turn-ended"
printf 'spawned %s\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-spawn.sh"
  cat > "$fake_root/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'teardown %s complete\n' "$1"
SH
  chmod +x "$fake_root/bin/fm-teardown.sh"

  FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" \
    FM_TEST_SPAWN_LOG="$log" FM_ORCA_SMOKE_PROJECT="$project" \
    "$USE_ORCA" smoke >/dev/null
  assert_grep "$project" "$log" "smoke should pass the configured smoke project to fm-spawn"
  assert_no_grep "projects/falkordb-stak" "$log" "smoke should not use a hardcoded project path"
  assert_present "$data_override/smoke-use-orca/brief.md" "smoke brief should be written under FM_DATA_OVERRIDE"
  assert_absent "$home/data/smoke-use-orca/brief.md" "smoke brief should not be written under FM_HOME/data when data is overridden"
  pass "use-orca smoke uses configured project and resolved data dir"
}

test_orca_test_suite_reads_config_from_fm_home() {
  local case_dir=fm-orca-suite-fm-home
  local home fakebin fmod out
  home=$(fake_home "$case_dir")
  fakebin="$TMP_ROOT/$case_dir/fakebin"
  mkdir -p "$fakebin"
  printf 'orca\n' > "$home/config/backend"
  printf 'pi\n' > "$home/config/crew-harness"

  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/setsid" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/setsid"
  fmod="$fakebin/fmod"
  cat > "$fmod" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ping) printf '{"pong":true}\n' ;;
  info) printf '{"daemon_reachable":true}\n' ;;
  list) printf '[]\n' ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fmod"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fmod" \
    "$ROOT/bin/fm-orca-test-suite.sh" --no-spawn --no-unit --expected-backend orca 2>&1 || true)
  assert_contains "$out" "config-backend" "suite should print config-backend check"
  assert_contains "$out" "orca (matches --expected-backend)" "suite should read config/backend from FM_HOME"
  assert_contains "$out" "config-crew-harness" "suite should print crew harness check"
  assert_contains "$out" "pi" "suite should read config/crew-harness from FM_HOME"
  pass "orca test suite reads config from FM_HOME"
}

test_orca_test_suite_json_survives_quoted_multiline_logs() {
  local case_dir=fm-orca-suite-json-quoting
  local home fakebin fmod out rc
  home=$(fake_home "$case_dir")
  fakebin="$TMP_ROOT/$case_dir/fakebin"
  mkdir -p "$fakebin"
  printf 'orca\n' > "$home/config/backend"
  printf 'pi\n' > "$home/config/crew-harness"

  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/setsid" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/setsid"
  fmod="$fakebin/fmod"
  cat > "$fmod" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ping) printf '{"pong":true}\n' ;;
  info) printf '{"daemon_reachable":true}\n' ;;
  list) printf 'rpc "down"\nsecond line\n'; exit 7 ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fmod"

  set +e
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fmod" \
    "$ROOT/bin/fm-orca-test-suite.sh" --no-spawn --no-unit --expected-backend orca --json 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "suite should fail when fmod list fails"
  printf '%s' "$out" | python3 -c '
import json
import sys

arr = json.load(sys.stdin)
match = [item for item in arr if item["name"] == "fmod-list"]
if not match:
    raise SystemExit("missing fmod-list result")
if match[0]["pass"]:
    raise SystemExit("fmod-list unexpectedly passed")
if "rpc \"down\"" not in match[0]["log"]:
    raise SystemExit("quoted fmod-list log was not preserved")
'
  pass "orca test suite JSON handles quoted multiline failure logs"
}

test_orca_test_suite_bootstrap_probe_is_detect_only() {
  local case_dir=fm-orca-suite-bootstrap-detect
  local fake_root home fakebin fmod log out
  fake_root="$TMP_ROOT/$case_dir/root"
  home="$TMP_ROOT/$case_dir/home"
  fakebin="$TMP_ROOT/$case_dir/fakebin"
  log="$TMP_ROOT/$case_dir/bootstrap.log"
  mkdir -p "$fake_root/bin" "$fakebin" "$home/config" "$home/state"
  cp "$ROOT/bin/fm-orca-test-suite.sh" "$fake_root/bin/fm-orca-test-suite.sh"
  chmod +x "$fake_root/bin/fm-orca-test-suite.sh"
  printf 'orca\n' > "$home/config/backend"
  printf 'pi\n' > "$home/config/crew-harness"

  cat > "$fake_root/bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_BOOTSTRAP_DETECT_ONLY:-unset}" > "$FM_TEST_BOOTSTRAP_LOG"
printf 'ORCA: daemon reachable\n'
SH
  chmod +x "$fake_root/bin/fm-bootstrap.sh"
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/setsid" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/setsid"
  fmod="$fakebin/fmod"
  cat > "$fmod" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ping) printf '{"pong":true}\n' ;;
  info) printf '{"daemon_reachable":true}\n' ;;
  list) printf '[]\n' ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fmod"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ORCA_FMOD="$fmod" FM_TEST_BOOTSTRAP_LOG="$log" \
    "$fake_root/bin/fm-orca-test-suite.sh" --no-spawn --no-unit --expected-backend orca 2>&1 || true)
  assert_contains "$out" "bootstrap-ORCA-line" "suite should run the bootstrap diagnostic check"
  [ "$(cat "$log")" = "1" ] || fail "bootstrap probe should set FM_BOOTSTRAP_DETECT_ONLY=1, got $(cat "$log")"
  pass "orca test suite bootstrap probe is detect-only"
}

# Build the test plan.
test_use_orca_status_reports_state_without_mutating
test_use_orca_status_does_not_leak_paths
test_use_orca_start_writes_config_backend
test_use_orca_autostart_install_then_remove
test_use_orca_stop_when_no_supervisor
test_use_orca_smoke_uses_configured_project_and_fm_home_data
test_orca_test_suite_reads_config_from_fm_home
test_orca_test_suite_json_survives_quoted_multiline_logs
test_orca_test_suite_bootstrap_probe_is_detect_only

if [ "${FAIL_COUNT:-0}" -eq 0 ]; then
  printf 'all use-orca tests passed\n'
  exit 0
fi
printf '%d use-orca test(s) failed\n' "${FAIL_COUNT}"
exit 1
