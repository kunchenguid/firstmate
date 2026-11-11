#!/usr/bin/env bash
# tests/fm-send-liveness.test.sh - fm-send refuses a steer to a worker that is
# not live (guard G8). The miss this pins: an inbox message was delivered to a
# task whose process was gone, and it sat unread. The real fm-send runs over a
# stubbed tmux whose window inventory, pane foreground process, and inventory
# failure are driven per case:
#   1. A recorded window that is gone is refused with exit 3 before anything is
#      written, and the error names when it was last live and says to relaunch.
#   2. A verified-alive worker is never refused for silence alone.
#   3. An endpoint that cannot be verified is refused only after six hours with
#      no activity, and that horizon is configurable.
#   4. --allow-dead records the steer anyway, warns, and leaves an audit line.
#   5. An idle secondmate is not refused for silence: an idle secondmate endpoint
#      is healthy and is judged by its routed status rather than pane quiet, and
#      the secondmate liveness sweep (SECONDMATE_LIVENESS lines in
#      bin/fm-bootstrap.sh) owns dead-secondmate detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The suite-wide escape hatch is exactly what this file verifies.
unset FM_SEND_LIVENESS_BYPASS

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-liveness)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux and ps. FAKE_WINDOWS is the session's window list; FAKE_FG the
# pane's foreground command; FAKE_INVENTORY=fail makes list-windows fail with
# an unrecognised error (an unreadable inventory).
make_stubs() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    if [ "${FAKE_INVENTORY:-}" = fail ]; then echo "server exited unexpectedly" >&2; exit 1; fi
    printf '%s\n' "${FAKE_WINDOWS:-}"; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_tty*) printf '/dev/ttysfake\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -t "*) printf '100 100 100 %s\n' "${FAKE_FG:-claude}" ;;
  *) printf '%s\n' "${FAKE_FG:-claude}" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/tmux" "$fb/ps" "$fb/sleep"
}

setup_case() {  # <name> [kind] -> echoes case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state"
  make_stubs "$dir"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=${2:-ship}" "harness=claude"
  printf 'working: started\n' > "$dir/home/state/t1.status"
  printf '%s\n' "$dir"
}

age_records() {  # <case-dir> <seconds-ago>
  local stamp
  stamp=$(python3 -c 'import sys,time; print(time.strftime("%Y%m%d%H%M.%S", time.localtime(time.time()-int(sys.argv[1]))))' "$2")
  touch -t "$stamp" "$1/home/state/t1.meta" "$1/home/state/t1.status"
}

run_send() {  # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} "$SEND" "$@" >/dev/null 2>"$err"
}

test_a_gone_window_is_refused_before_anything_is_written() {
  local dir err rc
  dir=$(setup_case gone); err="$dir/send.err"
  run_send "$dir" "$err" FAKE_WINDOWS=other -- t1 "please rebase"; rc=$?
  expect_code 3 "$rc" "a steer to a gone window"
  assert_contains "$(cat "$err")" "target not live since 20" "the refusal did not name when the worker was last live"
  assert_contains "$(cat "$err")" "relaunch first" "the refusal did not say to relaunch"
  assert_contains "$(cat "$err")" "bin/fm-control.sh t1 relaunch --note" "the refusal did not give a relaunch command that runs for a ship"
  assert_contains "$(cat "$err")" "endpoint sess:fm-t1 is missing" "the refusal did not say why"
  [ ! -e "$dir/home/state/t1.inbox/001.msg" ] || fail "a refused steer still wrote an inbox record"
  pass "a steer to a gone window is refused with exit 3 and nothing is written"
}

test_a_live_worker_is_never_refused_for_silence() {
  local dir err rc
  dir=$(setup_case alive-silent); err="$dir/send.err"
  age_records "$dir" 90000
  run_send "$dir" "$err" FAKE_WINDOWS=fm-t1 FAKE_FG=claude -- t1 "your decision: option B"; rc=$?
  expect_code 0 "$rc" "a steer to a live worker silent for 25 hours"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer to a live worker was not recorded"
  pass "a verified-alive worker gets its steer however long it has been quiet"
}

test_an_unverifiable_endpoint_is_refused_only_after_the_silence_horizon() {
  local dir err rc
  dir=$(setup_case unreadable); err="$dir/send.err"
  age_records "$dir" 3600
  run_send "$dir" "$err" FAKE_INVENTORY=fail -- t1 "hello"; rc=$?
  expect_code 0 "$rc" "a steer to an unreadable endpoint active an hour ago"
  age_records "$dir" 25200
  run_send "$dir" "$err" FAKE_INVENTORY=fail -- t1 "hello again"; rc=$?
  expect_code 3 "$rc" "a steer to an unreadable endpoint silent for 7 hours"
  assert_contains "$(cat "$err")" "no activity for 7h and its endpoint reads unreadable" "the silence refusal did not say why"
  run_send "$dir" "$err" FAKE_INVENTORY=fail FM_SEND_LIVENESS_SILENCE_SECS=30000 -- t1 "hello once more"; rc=$?
  expect_code 0 "$rc" "a steer inside a raised silence horizon"
  pass "an endpoint that cannot be verified is refused only after the configurable silence horizon"
}

test_allow_dead_records_with_a_warning_and_an_audit_line() {
  local dir err rc
  dir=$(setup_case allow); err="$dir/send.err"
  run_send "$dir" "$err" FAKE_WINDOWS=other -- t1 --allow-dead "relaunch queued; message must wait" "context for the relaunched worker"; rc=$?
  expect_code 0 "$rc" "an --allow-dead steer to a gone window"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "--allow-dead did not record the steer"
  assert_contains "$(cat "$err")" "writing the steer anyway (--allow-dead: relaunch queued" "--allow-dead did not warn"
  assert_contains "$(cat "$dir/home/state/.fm-send-allow-dead.log")" $'\tt1\t' "--allow-dead left no audit line"
  run_send "$dir" "$err" FAKE_WINDOWS=other -- t1 --allow-dead "  " "x"; rc=$?
  expect_code 1 "$rc" "an --allow-dead with a blank reason"
  pass "--allow-dead records the steer, warns, and audits the override"
}

test_an_idle_secondmate_is_not_refused_for_silence() {
  local dir err rc
  dir=$(setup_case mate secondmate); err="$dir/send.err"
  age_records "$dir" 90000
  run_send "$dir" "$err" FAKE_INVENTORY=fail -- t1 "a routed request"; rc=$?
  expect_code 0 "$rc" "a steer to an idle secondmate whose endpoint is unreadable"
  pass "an idle secondmate is not refused for silence"
}

test_a_gone_window_is_refused_before_anything_is_written
test_a_live_worker_is_never_refused_for_silence
test_an_unverifiable_endpoint_is_refused_only_after_the_silence_horizon
test_allow_dead_records_with_a_warning_and_an_audit_line
test_an_idle_secondmate_is_not_refused_for_silence
