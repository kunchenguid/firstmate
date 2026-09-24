#!/usr/bin/env bash
# Tests for bin/fm-usage-warner.sh, the opt-in local Claude usage threshold
# warner.
#
# This is a warner, not a viewer: every case here proves it stays silent
# except at a genuine new threshold crossing, and never touches a real
# account, a real Notification Center, or a real credential. quota-axi and
# osascript are both fixtures under the test's own fakebin, and no case ever
# passes --allow-keychain-prompt or any credential-refreshing flag - the
# script itself never does either, which test_check_never_requests_a_refresh
# verifies by capturing the exact quota-axi invocation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WARNER="$ROOT/bin/fm-usage-warner.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-warner)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# arm is macOS-only. Its threshold gate runs before any platform-specific file
# handling, so that refusal case uses a uname stub reporting Darwin and stays
# meaningful on a Linux CI runner. The cases that write the shim go through the
# BSD stat helpers the real macOS host provides, so they run only on Darwin.
DARWIN_BIN="$TMP_ROOT/darwin-bin"
mkdir -p "$DARWIN_BIN"
printf '#!/bin/sh\necho Darwin\n' > "$DARWIN_BIN/uname"
chmod +x "$DARWIN_BIN/uname"

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# fake_quota_axi <dir> <window-json...>: a quota-axi stub returning one
# provider row (schema 5) whose windows are exactly the given
# '{"id":"...","percentUsed":N}' fragments, and logging its own argv so a case
# can assert the read never asked for a credential refresh.
fake_quota_axi() {
  local dir=$1
  shift
  local windows
  windows=$(IFS=,; printf '%s' "$*")
  mkdir -p "$dir"
  cat > "$dir/quota-axi" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$QUOTA_AXI_ARGV_LOG"
cat <<'JSON'
{"generatedAt":"t","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","plan":"team","account":{"accountId":"x","email":"a@b.c","organization":"o","identityStatus":"verified"},"windows":[$windows],"attempts":[],"state":{"status":"fresh","stale":false,"refreshedAt":"t","sourcesTried":[]},"quotaSemantics":{"status":"known","description":"d","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["five_hour"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset"}}]}}]}
JSON
EOF
  chmod +x "$dir/quota-axi"
}

fake_osascript_recorder() {
  local dir=$1 log=$2
  mkdir -p "$dir"
  cat > "$dir/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
EOF
  chmod +x "$dir/osascript"
}

# run_check <home> <fakebin>: runs `check` with the fixture PATH first, real
# ambient PATH after (so real jq resolves), and stdin closed so nothing can
# ever block on an inherited terminal.
run_check() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_HOME="$home" QUOTA_AXI_ARGV_LOG="$fakebin/.argv-log" \
    "$WARNER" check </dev/null
}

test_help_and_usage() {
  local out rc=0
  out=$("$WARNER" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  rc=0
  out=$("$WARNER" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-usage-warner: help and usage plumbing"
}

test_unconfigured_home_stays_silent() {
  local home fakebin out rc=0
  home=$(make_home unconfigured)
  fakebin="$TMP_ROOT/unconfigured/fakebin"
  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":99}'
  : > "$fakebin/.argv-log"
  out=$(run_check "$home" "$fakebin" 2>&1) || rc=$?
  expect_code 0 "$rc" "unconfigured check must still exit 0"
  [ -z "$out" ] || fail "an unconfigured home must stay completely silent: $out"
  assert_absent "$home/state/.usage-warner" "an unconfigured check must never write a de-dupe record"
  [ ! -s "$fakebin/.argv-log" ] || fail "an unconfigured home must never call quota-axi at all"
  pass "fm-usage-warner: an unconfigured home sees no behaviour change"
}

test_config_parses_comments_whitespace_and_model_ids() {
  local home fakebin out
  home=$(make_home config-parsing)
  fakebin="$TMP_ROOT/config-parsing/fakebin"
  printf '%s\n' \
    '# a comment line' \
    '   ' \
    '  five_hour:20  ' \
    'seven_day:10' \
    'model:fable:40' \
    'bad-no-colon' \
    'seven_day:not-a-number' \
    'seven_day:0' \
    'seven_day:101' \
    > "$home/config/usage-warner"
  # Thresholds count percent LEFT and cross downward. five_hour crosses
  # (15 left <= 20): proves a directive survives leading/trailing whitespace.
  # seven_day sits at 50 left, still above its one valid threshold of 10; if
  # any of the three malformed seven_day directives above it had leaked past
  # validation - especially seven_day:101, which no percent left can stay above
  # - it would show up here too. model:fable crosses (40 left <= 40), proving
  # the boundary is inclusive and that the id/percent split lands on the LAST
  # colon, not the first.
  fake_quota_axi "$fakebin" \
    '{"id":"five_hour","percentUsed":85}' \
    '{"id":"seven_day","percentUsed":50}' \
    '{"id":"model:fable","percentUsed":60}'
  out=$(run_check "$home" "$fakebin")
  assert_contains "$out" "five_hour at 15% left (85% used)" \
    "a directive survives surrounding whitespace, and the line names both figures"
  assert_contains "$out" "model:fable at 40% left (60% used)" \
    "a colon-containing window id splits on the LAST colon"
  assert_not_contains "$out" "seven_day" "malformed duplicate directives (no colon, non-numeric, out-of-range) never leak a usable threshold"
  pass "fm-usage-warner: config parsing keeps only valid directives, including colon-containing ids"
}

test_check_crosses_notifies_stays_quiet_then_rearms() {
  local home fakebin notify_log out
  home=$(make_home lifecycle)
  fakebin="$TMP_ROOT/lifecycle/fakebin"
  notify_log="$TMP_ROOT/lifecycle/notify.log"
  : > "$notify_log"
  fake_osascript_recorder "$fakebin" "$notify_log"
  printf 'five_hour:20\n' > "$home/config/usage-warner"

  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":90}'
  out=$(run_check "$home" "$fakebin")
  assert_contains "$out" "five_hour at 10% left (90% used), threshold 20% left" \
    "a fresh crossing is reported, naming percent left, percent used, and the threshold"
  assert_grep "Firstmate: Claude usage" "$notify_log" "a fresh crossing posts one osascript notification"

  : > "$notify_log"
  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":95}'
  out=$(run_check "$home" "$fakebin")
  [ -z "$out" ] || fail "sinking further below the threshold must stay quiet: $out"
  [ ! -s "$notify_log" ] || fail "sinking further below the threshold must not notify again"

  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":50}'
  out=$(run_check "$home" "$fakebin")
  [ -z "$out" ] || fail "recovering back above the threshold must stay quiet (it only re-arms): $out"

  : > "$notify_log"
  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":85}'
  out=$(run_check "$home" "$fakebin")
  assert_contains "$out" "five_hour at 15% left (85% used)" "crossing again after recovering must notify again"
  assert_grep "Firstmate: Claude usage" "$notify_log" "the re-crossing posts a fresh notification"
  pass "fm-usage-warner: edge-triggered de-dupe crosses once, stays quiet, and re-arms on drop"
}

test_check_batches_multiple_crossings_into_one_notification() {
  local home fakebin notify_log out
  home=$(make_home batch)
  fakebin="$TMP_ROOT/batch/fakebin"
  notify_log="$TMP_ROOT/batch/notify.log"
  : > "$notify_log"
  fake_osascript_recorder "$fakebin" "$notify_log"
  printf 'five_hour:20\nseven_day:10\n' > "$home/config/usage-warner"
  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":92}' '{"id":"seven_day","percentUsed":97}'
  out=$(run_check "$home" "$fakebin")
  assert_contains "$out" "five_hour at 8% left" "the batched line names the first crossing"
  assert_contains "$out" "seven_day at 3% left" "the batched line names the second crossing"
  local notify_count
  notify_count=$(grep -c . "$notify_log" || true)
  [ "$notify_count" -eq 1 ] || fail "two crossings in one read must post exactly one notification, got $notify_count"
  pass "fm-usage-warner: multiple crossings in one read batch into a single notification"
}

test_check_ignores_a_window_the_account_does_not_return() {
  local home fakebin out
  home=$(make_home missing-window)
  fakebin="$TMP_ROOT/missing-window/fakebin"
  printf 'model:sonnet:50\n' > "$home/config/usage-warner"
  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":1}'
  out=$(run_check "$home" "$fakebin")
  [ -z "$out" ] || fail "a configured window id the account never returns must stay silent: $out"
  pass "fm-usage-warner: a configured but absent window id is silently skipped"
}

test_check_never_requests_a_refresh() {
  local home fakebin out argv
  home=$(make_home no-refresh)
  fakebin="$TMP_ROOT/no-refresh/fakebin"
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":10}'
  : > "$fakebin/.argv-log"
  run_check "$home" "$fakebin" >/dev/null
  argv=$(cat "$fakebin/.argv-log")
  assert_contains "$argv" "--no-credential-refresh" "every read passes --no-credential-refresh"
  assert_not_contains "$argv" "--allow-keychain-prompt" "the warner must never request a keychain prompt"
  pass "fm-usage-warner: the read is always strictly read-only"
}

test_quota_axi_missing_is_reported_once() {
  local home fakebin out1 out2
  home=$(make_home no-quota-axi)
  fakebin=$(fm_test_base_path_sans "$BASE_PATH" quota-axi)
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  out1=$(FM_HOME="$home" PATH="$fakebin" "$WARNER" check </dev/null 2>&1)
  assert_contains "$out1" "quota-axi is not installed" "a missing quota-axi is reported by name"
  out2=$(FM_HOME="$home" PATH="$fakebin" "$WARNER" check </dev/null 2>&1)
  [ -z "$out2" ] || fail "a repeated identical failure must stay silent: $out2"
  pass "fm-usage-warner: a missing quota-axi is reported once until it changes"
}

test_jq_missing_is_reported() {
  local home fakebin out
  home=$(make_home no-jq)
  fakebin=$(fm_test_base_path_sans "$BASE_PATH" jq)
  local qfake="$TMP_ROOT/no-jq/qbin"
  fake_quota_axi "$qfake" '{"id":"five_hour","percentUsed":10}'
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  out=$(FM_HOME="$home" PATH="$qfake:$fakebin" "$WARNER" check </dev/null 2>&1)
  assert_contains "$out" "jq is not installed" "a missing jq is reported by name"
  pass "fm-usage-warner: a missing jq is reported by name"
}

test_malformed_quota_axi_output_is_reported() {
  local home fakebin out
  home=$(make_home malformed)
  fakebin="$TMP_ROOT/malformed/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'not json at all'
EOF
  chmod +x "$fakebin/quota-axi"
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  out=$(run_check "$home" "$fakebin" 2>&1)
  assert_contains "$out" "unexpected response shape" "an unparsable quota-axi response is reported, not silently swallowed"
  pass "fm-usage-warner: a malformed quota-axi response is reported"
}

test_slow_quota_axi_is_reported_as_a_timeout() {
  local home fakebin out
  home=$(make_home slow)
  fakebin="$TMP_ROOT/slow/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
  chmod +x "$fakebin/quota-axi"
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  out=$(run_check "$home" "$fakebin" 2>&1)
  assert_contains "$out" "did not finish within the 10s budget" "a hung read is bounded and reported, not left to hang the watcher"
  pass "fm-usage-warner: a slow read is bounded and reported as a timeout"
}

test_read_bound_fits_a_lowered_check_timeout() {
  local home fakebin out start elapsed
  home=$(make_home low-check-timeout)
  fakebin="$TMP_ROOT/low-check-timeout/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
  chmod +x "$fakebin/quota-axi"
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  start=$(date +%s)
  out=$(FM_CHECK_TIMEOUT=6 PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" check </dev/null 2>&1)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 6 ] || fail "the read must end inside a lowered watcher bound, took ${elapsed}s"
  assert_contains "$out" "did not finish within the 3s budget" "the read bound is cut to fit FM_CHECK_TIMEOUT"
  pass "fm-usage-warner: the read bound is cut to fit a lowered FM_CHECK_TIMEOUT"
}

test_no_room_for_a_read_is_recorded_as_not_measured() {
  local home fakebin out rc=0 start elapsed
  home=$(make_home no-room)
  fakebin="$TMP_ROOT/no-room/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
  chmod +x "$fakebin/quota-axi"
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  start=$(date +%s)
  out=$(FM_CHECK_TIMEOUT=2 PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" check </dev/null 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "a watcher bound too small for a read must not fail the check"
  [ "$elapsed" -lt 2 ] || fail "a skipped read must return inside the watcher bound, took ${elapsed}s"
  assert_contains "$out" "not measured" "a skipped read is reported as not measured"
  assert_contains "$(cat "$home/state/.usage-warner")" "not measured" "the de-dupe record keeps the not-measured report"
  pass "fm-usage-warner: a watcher bound with no room for a read is recorded as not measured"
}

test_unconfigured_invocation_ignores_unused_environment() {
  local home out rc=0
  home=$(make_home unused-env)
  out=$(FM_USAGE_WARNER_TIMEOUT_SECS=0 FM_CHECK_TIMEOUT=bogus FM_HOME="$home" "$WARNER" check </dev/null 2>&1) || rc=$?
  expect_code 0 "$rc" "an unconfigured check must not fail on environment it does not use"
  [ -z "$out" ] || fail "an unconfigured check must stay silent whatever the environment: $out"
  rc=0
  out=$(FM_USAGE_WARNER_TIMEOUT_SECS=0 FM_CHECK_TIMEOUT=bogus "$WARNER" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must not fail on environment it does not use"
  pass "fm-usage-warner: an unconfigured invocation never fails on unused environment"
}

test_arm_refuses_without_a_configured_threshold() {
  local home out rc=0
  home=$(make_home arm-unconfigured)
  out=$(PATH="$DARWIN_BIN:$PATH" FM_HOME="$home" "$WARNER" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm without a threshold must fail"
  assert_contains "$out" "no threshold configured" "arm names the reason it refused"
  assert_absent "$home/state/usage-warner.check.sh" "a refused arm must not leave a shim behind"
  pass "fm-usage-warner: arm refuses without a configured threshold, mirroring the opt-in gate"
}

test_arm_refuses_on_a_non_macos_platform() {
  local home fakebin out rc=0
  home=$(make_home arm-linux)
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  fakebin=$(fm_test_base_path_sans "$BASE_PATH" uname)
  mkdir -p "$TMP_ROOT/arm-linux/unamebin"
  printf '#!/bin/sh\necho Linux\n' > "$TMP_ROOT/arm-linux/unamebin/uname"
  chmod +x "$TMP_ROOT/arm-linux/unamebin/uname"
  out=$(FM_HOME="$home" PATH="$TMP_ROOT/arm-linux/unamebin:$fakebin" "$WARNER" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm on a non-macOS platform must fail"
  assert_contains "$out" "only available on macOS" "arm names why it refused on a non-macOS platform"
  pass "fm-usage-warner: arm refuses on a platform with no Notification Center path"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm-ok)
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  out=$(FM_HOME="$home" "$WARNER" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/usage-warner.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/usage-warner.check.sh" "arm writes the check shim"
  assert_present "$home/state/usage-warner.check-trust" "arm registers a trust binding"
  [ "$(stat -c %a "$home/state/usage-warner.check.sh" 2>/dev/null || stat -f %Lp "$home/state/usage-warner.check.sh")" = 700 ] \
    || fail "the shim must be mode 700"
  assert_grep "exec" "$home/state/usage-warner.check.sh" "the shim execs the trusted check script"
  assert_grep "check" "$home/state/usage-warner.check.sh" "the shim invokes the check action"

  out=$(FM_HOME="$home" "$WARNER" disarm 2>&1)
  assert_contains "$out" "disarmed: state/usage-warner.check.sh" "disarm names the shim it removed"
  assert_absent "$home/state/usage-warner.check.sh" "disarm removes the shim"
  assert_absent "$home/state/usage-warner.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.usage-warner" "disarm removes the de-dupe record"
  pass "fm-usage-warner: arm writes a bound shim the watcher can run, disarm removes it cleanly"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home arm-symlink)
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  target="$TMP_ROOT/arm-symlink/elsewhere"
  mkdir -p "$(dirname "$target")"
  printf '#!/usr/bin/env bash\n' > "$target"
  ln -s "$target" "$home/state/usage-warner.check.sh"
  out=$(FM_HOME="$home" "$WARNER" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "arm reports the shim write failure"
  assert_absent "$home/state/usage-warner.check-trust" "no trust binding is left behind by a refused arm"
  [ -f "$target" ] || fail "arm must never write through the symlink to its target"
  pass "fm-usage-warner: arm refuses a symlink at the shim path instead of following it"
}

test_armed_shim_runs_a_real_check() {
  local home fakebin notify_log out
  home=$(make_home arm-integration)
  fakebin="$TMP_ROOT/arm-integration/fakebin"
  notify_log="$TMP_ROOT/arm-integration/notify.log"
  : > "$notify_log"
  fake_osascript_recorder "$fakebin" "$notify_log"
  fake_quota_axi "$fakebin" '{"id":"five_hour","percentUsed":92}'
  printf 'five_hour:80\n' > "$home/config/usage-warner"
  FM_HOME="$home" "$WARNER" arm >/dev/null 2>&1 || fail "arm must succeed"
  out=$(PATH="$fakebin:$PATH" "$home/state/usage-warner.check.sh" </dev/null)
  assert_contains "$out" "five_hour at 8% left (92% used)" "the armed shim, run the way the watcher runs it, performs a real check"
  pass "fm-usage-warner: the armed shim is exactly what the watcher would dispatch"
}

# --- threshold setter --------------------------------------------------------
# The setter exists so an operator never has to know this file's path or line
# format, and so the direction matches bin/fm-seat.sh's threshold rather than
# opposing it. Every number here is percent LEFT.

test_threshold_setter_writes_reads_and_clears_a_directive() {
  local home fakebin out
  home=$(make_home threshold-setter)
  fakebin="$TMP_ROOT/threshold-setter/fakebin"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold)
  assert_contains "$out" "(unset" "an unconfigured home must report no watched window"
  assert_absent "$home/config/usage-warner" "reading the thresholds must not create the config file"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold five_hour 20)
  expect_code 0 "$?" "setting a threshold should succeed"
  assert_contains "$out" "20% left" "the setter must echo percent left"
  assert_contains "$out" "80% used" "the setter must also name the percent-used figure during the transition"
  assert_grep "five_hour:20" "$home/config/usage-warner" "the directive must be written in the canonical schema"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold)
  assert_contains "$out" "five_hour" "the threshold must read back"
  assert_contains "$out" "20% left" "the listing must count percent left"
  assert_contains "$out" "80% used" "the listing must name both figures"

  # A colon-carrying window id must round-trip, because the schema splits on the
  # LAST colon and a setter that broke that would silently write a dead line.
  PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold model:fable 30 >/dev/null
  assert_grep "model:fable:30" "$home/config/usage-warner" "a colon-carrying window id must round-trip"

  # Re-setting replaces rather than appends, so a file cannot accumulate two
  # live directives for one window.
  PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold five_hour 5 >/dev/null
  [ "$(grep -c '^five_hour:' "$home/config/usage-warner")" -eq 1 ] ||
    fail "re-setting a window must replace its directive, not add a second"
  assert_grep "five_hour:5" "$home/config/usage-warner" "the replacement must hold the new value"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold five_hour off)
  expect_code 0 "$?" "clearing one window should succeed"
  grep -q '^five_hour:' "$home/config/usage-warner" &&
    fail "clearing a window must remove its directive"
  assert_grep "model:fable:30" "$home/config/usage-warner" "clearing one window must leave the others alone"
  pass "fm-usage-warner: the threshold setter writes, lists, replaces, and clears directives in percent left"
}

test_threshold_setter_refuses_an_out_of_range_percent() {
  local home fakebin out
  home=$(make_home threshold-setter-range)
  fakebin="$TMP_ROOT/threshold-setter-range/fakebin"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold five_hour 20 >/dev/null

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold five_hour 101 2>&1)
  expect_code 1 "$?" "a percent above 100 must be refused"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold five_hour 0 2>&1)
  expect_code 1 "$?" "a percent of 0 must be refused, because no window can sit below it"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" threshold five_hour banana 2>&1)
  expect_code 1 "$?" "a non-numeric percent must be refused"
  assert_grep "five_hour:20" "$home/config/usage-warner" "every refusal must leave the configured directive intact"
  pass "fm-usage-warner: the threshold setter refuses an out-of-range or non-numeric percent and changes nothing"
}

test_notify_exposes_the_homes_single_notification_path() {
  local home fakebin notify_log out
  home=$(make_home notify-action)
  fakebin="$TMP_ROOT/notify-action/fakebin"
  notify_log="$TMP_ROOT/notify-action/notify.log"
  : > "$notify_log"
  fake_osascript_recorder "$fakebin" "$notify_log"

  PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" notify "seat work is on paid extra usage" >/dev/null
  expect_code 0 "$?" "notify should post through the existing path"
  assert_grep "Firstmate: Claude usage" "$notify_log" "notify must use the home's one notification title"
  assert_grep "paid extra usage" "$notify_log" "notify must carry the caller's summary"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$WARNER" notify 2>&1)
  expect_code 2 "$?" "notify with no summary must be refused rather than posting an empty banner"
  pass "fm-usage-warner: notify exposes the home's single notification path for another feature to speak through"
}


test_help_and_usage
test_unconfigured_home_stays_silent
test_config_parses_comments_whitespace_and_model_ids
test_check_crosses_notifies_stays_quiet_then_rearms
test_check_batches_multiple_crossings_into_one_notification
test_check_ignores_a_window_the_account_does_not_return
test_check_never_requests_a_refresh
test_quota_axi_missing_is_reported_once
test_jq_missing_is_reported
test_malformed_quota_axi_output_is_reported
test_slow_quota_axi_is_reported_as_a_timeout
test_read_bound_fits_a_lowered_check_timeout
test_no_room_for_a_read_is_recorded_as_not_measured
test_unconfigured_invocation_ignores_unused_environment
test_threshold_setter_writes_reads_and_clears_a_directive
test_threshold_setter_refuses_an_out_of_range_percent
test_notify_exposes_the_homes_single_notification_path
test_arm_refuses_without_a_configured_threshold
test_arm_refuses_on_a_non_macos_platform
if [ "$(uname)" = Darwin ]; then
  test_arm_writes_and_binds_the_check_and_disarm_removes_it
  test_arm_refuses_a_symlink_at_the_shim_path
  test_armed_shim_runs_a_real_check
else
  printf 'ok - fm-usage-warner: shim-writing arm cases are macOS-only; skipping on %s\n' "$(uname)"
fi
