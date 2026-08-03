#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
# They also pin the other side of the loud-failure boundary: an inconclusive
# submit verdict on a provably BUSY pane whose capture still shows the typed
# text is a queued delivery (exit 0), never a "retype it" failure (the loop
# audit 2026-08-02 double-queue false negative), while absent text keeps the
# nonzero refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
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
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

# A minimal herdr CLI fake for the read-back boundary: server always running,
# agent get always "working" (busy pane), pane read prints the file named by
# FM_FAKE_HERDR_PANEFILE. send-text/send-keys succeed silently like the real
# CLI. jq stays real (a required tool for the herdr adapter, same stance as
# tests/fm-backend-herdr.test.sh).
make_herdr_stub() {  # <fakebin-dir>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '{"server":{"running":true}}\n'; exit 0 ;;
  "agent get") printf '{"result":{"agent":{"agent_status":"working"}}}\n'; exit 0 ;;
  "pane read") cat "${FM_FAKE_HERDR_PANEFILE:?}"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

setup_readback_home() {  # <name> -> echoes home dir
  local home
  home=$(setup_home "$1")
  fm_write_meta "$home/state/rb-lane.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" \
    "herdr_pane_id=wB:p2" "kind=ship"
  printf '%s\n' "$home"
}

test_busy_pane_queued_text_readback_exits_zero() {
  command -v jq >/dev/null 2>&1 || { echo "note: jq not found; read-back cases not exercised"; return 0; }
  local dir fb home err out rc
  dir="$TMP_ROOT/readback-queued"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); make_herdr_stub "$fb"; home=$(setup_readback_home rbq)
  err="$dir/send.err"; out="$dir/send.out"
  # The pane shows the steer wrapped in a bordered composer, split across rows:
  # the condensed comparison must still find it.
  printf '│ ship the fix, push github, │\n│ open PR, done: PR url │\n' > "$dir/pane.txt"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 \
    FM_FAKE_HERDR_PANEFILE="$dir/pane.txt" \
    "$SEND" rb-lane "ship the fix, push github, open PR, done: PR url" >"$out" 2>"$err"; rc=$?
  expect_code 0 "$rc" "busy pane with queued text should read back as delivered"$'\n'"$(cat "$err")"
  assert_contains "$(cat "$out")" "queued while pane busy" "read-back success should say the message was queued"
  pass "fm-send strict: busy-pane queued text read-back exits zero"
}

test_busy_pane_absent_text_readback_still_fails() {
  command -v jq >/dev/null 2>&1 || { echo "note: jq not found; read-back cases not exercised"; return 0; }
  local dir fb home err rc
  dir="$TMP_ROOT/readback-absent"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); make_herdr_stub "$fb"; home=$(setup_readback_home rba)
  err="$dir/send.err"
  printf 'some unrelated transcript output\n' > "$dir/pane.txt"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 \
    FM_FAKE_HERDR_PANEFILE="$dir/pane.txt" \
    "$SEND" rb-lane "ship the fix, push github, open PR" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "absent text should keep the nonzero refusal"
  assert_contains "$(cat "$err")" "delivery unconfirmed" "absent-text failure should keep the unconfirmed diagnostic"
  assert_contains "$(cat "$err")" "read-back: text absent from capture" "absent-text failure should name the read-back result"
  pass "fm-send strict: busy-pane absent text keeps the loud refusal"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_healthy_fm_id_send_still_works
test_busy_pane_queued_text_readback_exits_zero
test_busy_pane_absent_text_readback_still_fails
