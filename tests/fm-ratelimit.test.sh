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

test_marker_write_preserves_active_episode_reset() {
  local dir state marker got
  dir="$TMP_ROOT/marker-preserve"
  state="$dir/state"
  mkdir -p "$state"
  marker="$state/task.ratelimit"
  printf '%s\ttest:fm-task\tclaude\n' 1000 > "$marker"
  if fm_ratelimit_marker_write "$state" task 2000 "test:fm-task" claude; then
    fail "marker_write overwrote an active episode for the same window+harness"
  fi
  got=$(cat "$marker")
  [ "$got" = "$(printf '1000\ttest:fm-task\tclaude')" ] \
    || fail "marker_write did not preserve the original reset epoch: $got"
  fm_ratelimit_marker_write "$state" task 3000 "test:fm-other" claude \
    || fail "marker_write refused a genuinely new episode on a different window"
  pass "marker_write preserves an active episode's reset and writes new episodes"
}

test_resume_self_recovered_clears_without_submit() {
  local dir state marker submitted now
  dir="$TMP_ROOT/resume-recovered"
  state="$dir/state"
  mkdir -p "$state"
  now=$(date +%s)
  marker="$state/task.ratelimit"
  printf '%s\ttest:fm-task\tclaude\n' "$((now - 10))" > "$marker"
  submitted="$dir/submitted"
  fm_backend_target_exists() { return 0; }
  fm_backend_busy_state() { printf 'idle'; }
  fm_backend_capture() { printf 'a healthy idle prompt with no limit in sight\n'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf 'sent' > "$submitted"; printf 'empty'; }
  FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 fm_ratelimit_resume_scan "$state" >/dev/null \
    || fail "self-recovered resume scan returned non-zero"
  [ ! -e "$marker" ] || fail "self-recovered pane did not clear its marker"
  [ ! -e "$submitted" ] || fail "self-recovered idle pane received an unsolicited continue"
  grep "$(printf '\tratelimited-resumed\t')" "$state/.wake-queue" >/dev/null \
    || fail "self-recovered resume did not append a ratelimited-resumed trail wake"
  pass "a self-recovered idle pane clears its marker without submitting continue"
}

test_overload_regex_matches_only_529() {
  local match
  if fm_ratelimit_render_match 'ordinary line
the model is overloaded right now
please try again later' >/dev/null; then
    fail "tightened overload regex still matched generic retry phrasing"
  fi
  match=$(fm_ratelimit_render_match 'ordinary line
another line
API Error: 529 overloaded_error')
  case "$match" in
    *"$(printf '\t')"overload) ;;
    *) fail "API Error: 529 footer did not match as overload: $match" ;;
  esac
  pass "overload matcher fires only on API Error: 529, not generic retry text"
}

# A transient API Error: 529 overload parks with the SHORT FM_OVERLOAD_FALLBACK
# (default 120s), not the hourly FM_RATELIMIT_FALLBACK a quota reset uses, so an
# idle overloaded pane is not suppressed for a full quota-reset window before the
# first auto-resume attempt. The quota fallback stays 3600s (the two are
# independent knobs).
test_overload_uses_short_fallback_distinct_from_quota() {
  local now match reset kind
  now=1000000000
  match=$(fm_ratelimit_render_match 'ordinary line
another line
API Error: 529 overloaded_error' "$now")
  IFS=$(printf '\t') read -r reset kind <<EOF
$match
EOF
  [ "$kind" = overload ] || fail "529 footer did not classify as overload: $match"
  [ "$reset" = "$((now + 120))" ] \
    || fail "overload used the wrong default fallback: reset=$reset, expected $((now + 120))"
  match=$(FM_OVERLOAD_FALLBACK=45 fm_ratelimit_render_match 'API Error: 529 overloaded_error' "$now")
  IFS=$(printf '\t') read -r reset kind <<EOF
$match
EOF
  [ "$reset" = "$((now + 45))" ] || fail "FM_OVERLOAD_FALLBACK override not honored: reset=$reset"
  # A quota footer with no parseable reset time still falls back to the hourly 3600s.
  match=$(fm_ratelimit_render_match 'ordinary line
another line
Claude usage limit reached' "$now")
  IFS=$(printf '\t') read -r reset kind <<EOF
$match
EOF
  [ "$kind" = ratelimit ] || fail "quota footer did not classify as ratelimit: $match"
  [ "$reset" = "$((now + 3600))" ] \
    || fail "quota fallback changed from 3600s: reset=$reset, expected $((now + 3600))"
  pass "API Error: 529 parks with the short overload fallback while quota reset fallback stays 3600s"
}

test_reset_parser_handles_iana_timezone_and_dst
test_reset_parser_handles_utc_24h_and_fallback
test_footer_match_is_tail_anchored
test_resume_success_is_silent_and_records_trail
test_resume_exhaustion_escalates_and_leaves_marker
test_marker_write_preserves_active_episode_reset
test_resume_self_recovered_clears_without_submit
test_overload_regex_matches_only_529
test_overload_uses_short_fallback_distinct_from_quota
