#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  fm_test_write_basic_herdr "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:w1:p8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:w1:p8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:w1:p8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:w1:p1 "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_herdr_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_FAKE_HERDR_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to herdr send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to herdr"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to herdr send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before herdr fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_FAKE_HERDR_DEAD_PANE=w1:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:w1:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit herdr-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live herdr endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=herdr" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:w1:p9" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:w1:p9 literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:w1:p9 literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_removed_runtime_record_never_sends_to_herdr() {
  local dir fb home err log rc
  dir="$TMP_ROOT/removed-runtime"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home removedruntime); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  fm_write_meta "$home/state/upgrade-case.meta" "window=firstmate:fm-upgrade-case" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" upgrade-case "do not misroute" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "removed-runtime record should fail closed"
  assert_contains "$(cat "$err")" "legacy removed runtime" "removed-runtime send refusal lost its diagnostic"
  assert_contains "$(cat "$err")" "do not reinterpret it as Herdr" "removed-runtime send refusal lost its migration warning"
  [ ! -s "$log" ] || fail "removed-runtime record invoked Herdr"$'\n'"$(cat "$log")"
  pass "fm-send strict: removed-runtime records never route to Herdr"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_herdr_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_healthy_fm_id_send_still_works
test_removed_runtime_record_never_sends_to_herdr
