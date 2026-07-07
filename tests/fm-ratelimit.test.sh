#!/usr/bin/env bash
# tests/fm-ratelimit.test.sh - Claude quota footer parsing and auto-resume.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
FM_STATE_OVERRIDE="$(fm_test_tmproot fm-ratelimit-wake-state)/state" . "$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ratelimit-tests)

py_epoch() {
  python3 - "$@" <<'PY'
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

zone, value = sys.argv[1], sys.argv[2]
print(int(datetime.fromisoformat(value).replace(tzinfo=ZoneInfo(zone)).timestamp()))
PY
}

require_python_zoneinfo() {
  python3 - <<'PY' >/dev/null 2>&1 || fail "python3 zoneinfo is required for ratelimit parser tests"
from zoneinfo import ZoneInfo
ZoneInfo("America/Los_Angeles")
PY
}

test_reset_parser_handles_iana_timezone_and_dst() {
  local now expected got text
  require_python_zoneinfo
  now=$(py_epoch America/Los_Angeles 2026-03-08T01:30:00)
  expected=$(py_epoch America/Los_Angeles 2026-03-08T03:30:00)
  text='Claude usage limit reached. Your limit will reset at 3:30 AM (America/Los_Angeles).'
  got=$(fm_ratelimit_reset_epoch "$text" "$now")
  [ "$got" = "$expected" ] || fail "IANA/DST reset parse got $got, expected $expected"
  pass "ratelimit reset parser handles IANA timezone reset across DST"
}

test_reset_parser_handles_utc_24h_and_fallback() {
  local now expected got
  now=$(py_epoch UTC 2026-07-08T20:00:00)
  expected=$(py_epoch UTC 2026-07-08T22:45:00)
  got=$(fm_ratelimit_reset_epoch 'limit reached; resets at 22:45 UTC' "$now")
  [ "$got" = "$expected" ] || fail "UTC 24h reset parse got $got, expected $expected"
  got=$(FM_RATELIMIT_FALLBACK=123 fm_ratelimit_reset_epoch 'limit reached; no reset time rendered' "$now")
  [ "$got" = "$((now + 123))" ] || fail "fallback reset got $got, expected $((now + 123))"
  pass "ratelimit reset parser handles UTC 24h times and fallback"
}

test_footer_match_is_tail_anchored() {
  local text match
  text='Claude usage limit reached in transcript text only.
ordinary line
another ordinary line
idle prompt'
  if fm_ratelimit_render_match "$text" >/dev/null; then
    fail "ratelimit text outside the footer matched"
  fi
  text='ordinary transcript line
another ordinary line
Claude usage limit reached. Your limit will reset at 4 PM (UTC).'
  match=$(fm_ratelimit_render_match "$text")
  case "$match" in
    *"$(printf '\t')"ratelimit) ;;
    *) fail "footer ratelimit did not match as ratelimit: $match" ;;
  esac
  pass "ratelimit matcher is anchored to the footer tail"
}

test_resume_success_is_silent_and_records_trail() {
  local dir state marker out now
  dir="$TMP_ROOT/resume-success"
  state="$dir/state"
  mkdir -p "$state"
  now=$(date +%s)
  marker="$state/task.ratelimit"
  printf '%s\ttest:fm-task\tclaude\n' "$((now - 10))" > "$marker"
  fm_backend_target_exists() { return 0; }
  fm_backend_busy_state() { printf 'idle'; }
  fm_backend_capture() { printf 'Claude usage limit reached. Your limit will reset at 1 PM (UTC).\n'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf 'empty'; }
  out=$(FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 fm_ratelimit_resume_scan "$state")
  [ -z "$out" ] || fail "successful resume printed an escalation: $out"
  [ ! -e "$marker" ] || fail "successful resume did not clear marker"
  grep "$(printf '\tratelimited-resumed\t')" "$state/.wake-queue" >/dev/null \
    || fail "successful resume did not append ratelimited-resumed trail wake"
  pass "successful ratelimit auto-resume is silent and leaves an audit wake"
}

test_resume_exhaustion_escalates_and_leaves_marker() {
  local dir state marker out now
  dir="$TMP_ROOT/resume-fail"
  state="$dir/state"
  mkdir -p "$state"
  now=$(date +%s)
  marker="$state/task.ratelimit"
  printf '%s\ttest:fm-task\tclaude\n' "$((now - 10))" > "$marker"
  fm_backend_target_exists() { return 0; }
  fm_backend_busy_state() { printf 'idle'; }
  fm_backend_capture() { printf 'Claude usage limit reached. Your limit will reset at 1 PM (UTC).\n'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf 'pending'; }
  out=$(FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=1 fm_ratelimit_resume_scan "$state") \
    || [ "$?" = 2 ]
  printf '%s' "$out" | grep -F 'ratelimit auto-resume exhausted' >/dev/null \
    || fail "exhausted resume did not print escalation reason: $out"
  [ -e "$marker.failed" ] || fail "exhausted resume did not leave failed marker"
  grep "$(printf '\tcheck\t')" "$state/.wake-queue" >/dev/null \
    || fail "exhausted resume did not append an escalation wake"
  pass "ratelimit auto-resume exhaustion escalates and leaves a durable marker"
}

test_reset_parser_handles_iana_timezone_and_dst
test_reset_parser_handles_utc_24h_and_fallback
test_footer_match_is_tail_anchored
test_resume_success_is_silent_and_records_trail
test_resume_exhaustion_escalates_and_leaves_marker
