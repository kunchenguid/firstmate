#!/usr/bin/env bash
# fm-browser.sh behavior tests using fake HTTP and browser processes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROWSER_HELPER="$ROOT/bin/fm-browser.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser)

make_fake_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_BROWSER_MARKER:-}" ] && [ -e "$FM_TEST_BROWSER_MARKER" ]; then
  printf '%s\n' '{"webSocketDebuggerUrl":"ws://127.0.0.1/devtools/browser/test"}'
  exit 0
fi
exit 7
SH
  chmod +x "$fakebin/curl"
}

make_fake_browser() {
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_TEST_BROWSER_LAUNCH_LOG"
[ -z "${FM_TEST_BROWSER_MARKER:-}" ] || touch "$FM_TEST_BROWSER_MARKER"
trap 'exit 0' INT TERM
while :; do sleep 0.1; done
SH
  chmod +x "$path"
}

test_probe_hit_reuses_without_launching() {
  local dir fakebin marker browser out
  dir="$TMP_ROOT/probe-hit"
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  marker="$dir/ready"
  browser="$dir/browser"
  : > "$marker"
  make_fake_browser "$browser"
  out=$(FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19222 \
    FM_BROWSER_BIN="$browser" FM_TEST_BROWSER_MARKER="$marker" \
    FM_TEST_BROWSER_LAUNCH_LOG="$dir/launched" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" url)
  [ "$out" = 'http://127.0.0.1:19222' ] || fail "probe-hit path returned '$out'"
  [ ! -e "$dir/launched" ] || fail "probe-hit path launched a second browser"
  pass "probe-hit path reuses the reachable endpoint without launching"
}

test_discovery_prefers_explicit_binary() {
  local dir fakebin marker preferred fallback out second launches args
  dir="$TMP_ROOT/discovery-order"
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  marker="$dir/ready"
  preferred="$dir/preferred-browser"
  fallback="$dir/fallback-browser"
  make_fake_browser "$preferred"
  make_fake_browser "$fallback"
  out=$(FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19223 \
    FM_BROWSER_BIN="$preferred" FM_TEST_BROWSER_MARKER="$marker" \
    FM_TEST_BROWSER_LAUNCH_LOG="$dir/preferred-launched" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" url)
  [ "$out" = 'http://127.0.0.1:19223' ] || fail "discovery path returned '$out'"
  [ -e "$dir/preferred-launched" ] || fail "FM_BROWSER_BIN was not selected first"
  launches=$(wc -l < "$dir/preferred-launched")
  [ "$launches" -eq 1 ] || fail "initial helper launch count was '$launches'"
  second=$(FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19223 \
    FM_BROWSER_BIN="$fallback" FM_TEST_BROWSER_MARKER="$marker" \
    FM_TEST_BROWSER_LAUNCH_LOG="$dir/fallback-launched" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" url)
  [ "$second" = 'http://127.0.0.1:19223' ] || fail "repeat url returned '$second'"
  launches=$(wc -l < "$dir/preferred-launched")
  [ "$launches" -eq 1 ] || fail "repeat url launched a second browser"
  args=$(sed -n '1p' "$dir/preferred-launched")
  assert_contains "$args" '--headless --no-sandbox --disable-gpu --disable-dev-shm-usage --remote-debugging-address=127.0.0.1' \
    "browser launch omitted required flags"
  assert_contains "$args" '--remote-debugging-port=19223' \
    "browser launch omitted the configured debug port"
  assert_contains "$args" "--user-data-dir=$dir/runtime/profile" \
    "browser launch omitted the dedicated profile"
  FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19223 \
    FM_TEST_BROWSER_MARKER="$marker" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" stop >/dev/null 2>&1 || fail "failed to stop the fake browser"
  pass "discovery order selects FM_BROWSER_BIN before cached or PATH browsers"
}

test_concurrent_urls_start_one_browser() {
  local dir fakebin marker browser out_a out_b pid_a pid_b launches
  dir="$TMP_ROOT/concurrent"
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  marker="$dir/ready"
  browser="$dir/browser"
  make_fake_browser "$browser"
  mkdir -p "$dir/runtime/lock"
  chmod 700 "$dir/runtime"
  printf '99999999\n' > "$dir/runtime/lock/pid"
  : > "$dir/launch-a"
  : > "$dir/launch-b"
  (
    FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19227 \
      FM_BROWSER_BIN="$browser" FM_TEST_BROWSER_MARKER="$marker" \
      FM_TEST_BROWSER_LAUNCH_LOG="$dir/shared-launches" PATH="$fakebin:$PATH" \
      "$BROWSER_HELPER" url >"$dir/out-a"
  ) &
  pid_a=$!
  (
    FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19227 \
      FM_BROWSER_BIN="$browser" FM_TEST_BROWSER_MARKER="$marker" \
      FM_TEST_BROWSER_LAUNCH_LOG="$dir/shared-launches" PATH="$fakebin:$PATH" \
      "$BROWSER_HELPER" url >"$dir/out-b"
  ) &
  pid_b=$!
  wait "$pid_a" || fail "first concurrent url call failed"
  wait "$pid_b" || fail "second concurrent url call failed"
  out_a=$(cat "$dir/out-a")
  out_b=$(cat "$dir/out-b")
  [ "$out_a" = 'http://127.0.0.1:19227' ] || fail "first concurrent call returned '$out_a'"
  [ "$out_b" = 'http://127.0.0.1:19227' ] || fail "second concurrent call returned '$out_b'"
  launches=$(wc -l < "$dir/shared-launches")
  [ "$launches" -eq 1 ] || fail "concurrent calls launched '$launches' browsers"
  FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19227 \
    FM_TEST_BROWSER_MARKER="$marker" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" stop >/dev/null 2>&1 || fail "failed to stop the concurrent fake browser"
  pass "concurrent callers share one machine-scoped browser lock and launch once"
}

test_missing_binary_refuses_without_url() {
  local dir fakebin out err status
  dir="$TMP_ROOT/missing"
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  if out=$(FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19224 \
    FM_BROWSER_BIN="$dir/not-a-browser" HOME="$dir/home" \
    FM_TEST_BROWSER_MARKER="$dir/never" PATH="$fakebin:/usr/bin:/bin" \
    "$BROWSER_HELPER" url 2>"$dir/error"); then
    status=0
  else
    status=$?
  fi
  err=$(cat "$dir/error")
  [ "$status" -ne 0 ] || fail "missing browser unexpectedly succeeded"
  [ -z "$out" ] || fail "missing browser printed a URL: $out"
  assert_contains "$err" 'npx -y puppeteer@latest browsers install chrome' \
    "missing browser error omitted the installation command"
  pass "missing browser refuses with no URL and an actionable installation message"
}

test_stop_does_not_signal_unowned_pid() {
  local dir fakebin out
  dir="$TMP_ROOT/unowned-stop"
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  mkdir -p "$dir/runtime"
  chmod 700 "$dir/runtime"
  {
    printf 'pid=%s\n' "$$"
    printf 'port=19225\n'
    printf 'profile=%s\n' "$dir/not-owned-profile"
  } > "$dir/runtime/pid"
  out=$(FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19225 \
    FM_TEST_BROWSER_MARKER="$dir/never" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" stop)
  [ "$out" = 'stopped=no-owned-browser' ] || fail "unowned stop returned '$out'"
  kill -0 "$$" 2>/dev/null || fail "stop signaled the test process"
  pass "stop refuses to signal a PID that is not the helper-owned browser"
}

test_stale_lock_is_reclaimed() {
  local dir fakebin out
  dir="$TMP_ROOT/stale-lock"
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  mkdir -p "$dir/runtime/lock"
  chmod 700 "$dir/runtime"
  printf '99999999\n' > "$dir/runtime/lock/pid"
  out=$(FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19228 \
    FM_TEST_BROWSER_MARKER="$dir/never" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" stop)
  [ "$out" = 'stopped=no-owned-browser' ] || fail "stale-lock stop returned '$out'"
  [ ! -e "$dir/runtime/lock" ] || fail "stale lock was not released"
  mkdir -p "$dir/runtime/lock"
  out=$(FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19228 \
    FM_TEST_BROWSER_MARKER="$dir/never" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" stop)
  [ "$out" = 'stopped=no-owned-browser' ] || fail "ownerless-lock stop returned '$out'"
  [ ! -e "$dir/runtime/lock" ] || fail "ownerless lock was not released"
  pass "dead and ownerless browser locks are claimed atomically"
}

test_insecure_runtime_dir_is_refused() {
  local dir fakebin err status
  dir="$TMP_ROOT/insecure-runtime"
  fakebin=$(fm_fakebin "$dir")
  make_fake_curl "$fakebin"
  mkdir -p "$dir/runtime"
  chmod 777 "$dir/runtime"
  if FM_BROWSER_RUNTIME_DIR="$dir/runtime" FM_BROWSER_PORT=19229 \
    FM_TEST_BROWSER_MARKER="$dir/never" PATH="$fakebin:$PATH" \
    "$BROWSER_HELPER" stop >"$dir/output" 2>"$dir/error"; then
    status=0
  else
    status=$?
  fi
  err=$(cat "$dir/error")
  [ "$status" -ne 0 ] || fail "insecure runtime directory unexpectedly succeeded"
  assert_contains "$err" 'not group/other-writable' \
    "insecure runtime refusal omitted the permissions requirement"
  [ ! -e "$dir/runtime/lock" ] || fail "insecure runtime directory was modified"
  pass "group/other-writable runtime directories are refused"
}

test_probe_hit_reuses_without_launching
test_discovery_prefers_explicit_binary
test_concurrent_urls_start_one_browser
test_missing_binary_refuses_without_url
test_stop_does_not_signal_unowned_pid
test_stale_lock_is_reclaimed
test_insecure_runtime_dir_is_refused

echo "# all fm-browser tests passed"
