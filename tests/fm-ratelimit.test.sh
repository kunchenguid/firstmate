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

# An accepted `continue` submit whose limit footer still renders is NOT recovery:
# the pane kept taking input while rate-limited (a mis-parsed or fallback reset, a
# weekly cap, or a harness that accepts input during an active limit). The resume
# must count it as one attempt and leave the marker so .attempts accumulates toward
# the FM_RATELIMIT_MAX_RESUMES escalation instead of being wiped as a false success.
test_accepted_submit_while_limited_counts_attempt_not_recovery() {
  local dir state marker out now
  dir="$TMP_ROOT/resume-accepted-still-limited"
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
  out=$(FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=3 fm_ratelimit_resume_scan "$state")
  [ -z "$out" ] || fail "accepted-but-still-limited resume escalated early: $out"
  [ -e "$marker" ] || fail "accepted-but-still-limited resume wiped the marker as a false success"
  [ "$(cat "$marker.attempts" 2>/dev/null)" = 1 ] \
    || fail "accepted-but-still-limited resume did not record a resume attempt: $(cat "$marker.attempts" 2>/dev/null)"
  if [ -e "$state/.wake-queue" ] && grep "$(printf '\tratelimited-resumed\t')" "$state/.wake-queue" >/dev/null 2>&1; then
    fail "accepted-but-still-limited resume falsely recorded a ratelimited-resumed success"
  fi
  pass "an accepted continue that stays rate-limited counts as an attempt, not a recovery"
}

# Repeated accepted-but-still-limited submits accumulate .attempts across scans and
# eventually exhaust to .ratelimit.failed + escalation, so a crew that keeps
# swallowing `continue` while rate-limited still surfaces to the captain rather than
# being re-parked into silence forever.
test_accepted_submit_still_limited_exhausts_across_scans() {
  local dir state marker out now rc
  dir="$TMP_ROOT/resume-accepted-exhaust"
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
  FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=3 fm_ratelimit_resume_scan "$state" >/dev/null
  FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=3 fm_ratelimit_resume_scan "$state" >/dev/null
  [ "$(cat "$marker.attempts" 2>/dev/null)" = 2 ] \
    || fail "attempts did not accumulate across scans on accepted-but-still-limited submits: $(cat "$marker.attempts" 2>/dev/null)"
  [ ! -e "$marker.failed" ] || fail "resume exhausted before reaching FM_RATELIMIT_MAX_RESUMES"
  out=$(FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=3 fm_ratelimit_resume_scan "$state") && rc=0 || rc=$?
  [ "$rc" = 2 ] || fail "final scan did not return the exhaustion code: rc=$rc"
  printf '%s' "$out" | grep -F 'ratelimit auto-resume exhausted' >/dev/null \
    || fail "accepted-but-still-limited exhaustion did not escalate: $out"
  [ -e "$marker.failed" ] || fail "accepted-but-still-limited exhaustion left no failed marker"
  grep "$(printf '\tcheck\t')" "$state/.wake-queue" >/dev/null \
    || fail "accepted-but-still-limited exhaustion did not append an escalation wake"
  pass "repeated accepted-but-still-limited continues accumulate and exhaust to escalation"
}

# The happy path: a limited pane accepts `continue` (attempt recorded, marker kept),
# then on the next scan its footer no longer renders a limit, so recovery clears the
# whole marker set silently - a successfully-resumed pane never false-exhausts.
test_resume_submit_then_recovery_clears_marker() {
  local dir state marker now
  dir="$TMP_ROOT/resume-then-recover"
  state="$dir/state"
  mkdir -p "$state"
  now=$(date +%s)
  marker="$state/task.ratelimit"
  printf '%s\ttest:fm-task\tclaude\n' "$((now - 10))" > "$marker"
  fm_backend_target_exists() { return 0; }
  fm_backend_busy_state() { printf 'idle'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf 'empty'; }
  # Scan 1: still limited -> attempt recorded, marker preserved.
  fm_backend_capture() { printf 'Claude usage limit reached. Your limit will reset at 1 PM (UTC).\n'; }
  FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=3 fm_ratelimit_resume_scan "$state" >/dev/null
  [ -e "$marker" ] || fail "first resume attempt wiped the marker before recovery"
  [ "$(cat "$marker.attempts" 2>/dev/null)" = 1 ] || fail "first resume attempt was not recorded"
  # Scan 2: footer no longer shows a limit -> recovery clears the marker set.
  fm_backend_capture() { printf 'a healthy idle prompt with no limit in sight\n'; }
  FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=3 fm_ratelimit_resume_scan "$state" >/dev/null
  [ ! -e "$marker" ] || fail "recovered pane did not clear its marker after resume"
  [ ! -e "$marker.attempts" ] || fail "recovered pane did not clear its attempts counter"
  grep "$(printf '\tratelimited-resumed\t')" "$state/.wake-queue" >/dev/null \
    || fail "recovery after resume did not append a ratelimited-resumed trail wake"
  pass "a limited pane that accepts continue then recovers clears its marker without false exhaustion"
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

# While a pane stays parked, the watcher re-classifies its footer every poll but
# already holds the reset in <id>.ratelimit. Passing that reset back to
# fm_ratelimit_render_match must pin it verbatim - never re-derive it - so a pane
# parked for ~an hour does not re-spawn python (quota) or slide its reset forward
# (overload) once per poll only to discard the recomputed value.
test_render_match_reuses_marker_reset_without_reparsing() {
  local now match reset kind
  now=1000000000
  # A quota footer with no parseable reset time would normally fall back to
  # now+3600; with a reuse-reset the recorded epoch is returned verbatim instead.
  match=$(fm_ratelimit_render_match 'ordinary line
another line
Claude usage limit reached' "$now" 1234567890)
  IFS=$(printf '\t') read -r reset kind <<EOF
$match
EOF
  [ "$kind" = ratelimit ] || fail "reuse path did not classify footer as ratelimit: $match"
  [ "$reset" = 1234567890 ] || fail "render_match did not reuse the supplied quota reset: reset=$reset"
  # Overload reuse likewise pins the reset instead of sliding to now+120 each poll.
  match=$(fm_ratelimit_render_match 'API Error: 529 overloaded_error' "$now" 1111111111)
  IFS=$(printf '\t') read -r reset kind <<EOF
$match
EOF
  [ "$kind" = overload ] || fail "reuse path did not classify 529 footer as overload: $match"
  [ "$reset" = 1111111111 ] || fail "overload reuse did not pin the reset: reset=$reset"
  # A non-numeric reuse value is ignored: the footer is re-parsed (fallback here).
  match=$(fm_ratelimit_render_match 'ordinary line
Claude usage limit reached' "$now" 'not-a-number')
  IFS=$(printf '\t') read -r reset kind <<EOF
$match
EOF
  [ "$reset" = "$((now + 3600))" ] || fail "non-numeric reuse was not ignored: reset=$reset"
  pass "render_match reuses an active marker reset verbatim without re-parsing the footer"
}

test_marker_reset_reads_only_matching_episode() {
  local dir state marker got
  dir="$TMP_ROOT/marker-reset"
  state="$dir/state"
  mkdir -p "$state"
  marker="$state/task.ratelimit"
  printf '%s\ttest:fm-task\tclaude\n' 4242 > "$marker"
  got=$(fm_ratelimit_marker_reset "$state" task "test:fm-task" claude) \
    || fail "marker_reset failed to read a matching episode"
  [ "$got" = 4242 ] || fail "marker_reset returned the wrong reset: $got"
  # A different window or harness is a different episode; do not reuse its reset.
  if fm_ratelimit_marker_reset "$state" task "test:fm-other" claude >/dev/null; then
    fail "marker_reset reused a reset across a different window"
  fi
  if fm_ratelimit_marker_reset "$state" task "test:fm-task" codex >/dev/null; then
    fail "marker_reset reused a reset across a different harness"
  fi
  # A non-numeric or absent marker never yields a reset.
  printf 'garbage\ttest:fm-task\tclaude\n' > "$marker"
  if fm_ratelimit_marker_reset "$state" task "test:fm-task" claude >/dev/null; then
    fail "marker_reset returned a reset for a corrupt marker"
  fi
  rm -f "$marker"
  if fm_ratelimit_marker_reset "$state" task "test:fm-task" claude >/dev/null; then
    fail "marker_reset returned a reset with no marker present"
  fi
  pass "marker_reset returns a reset only for the same active window+harness episode"
}

# firstmate's OWN supervisor pane is parked as firstmate.ratelimit during away
# mode and resumed by the same shared scan. A BARE continue there would read as
# "captain is back" and prematurely exit afk / stop the daemon, so the resume must
# prefix the inject sentinel (FM_INJECT_MARK) that marks it as an internal
# escalation. Crew panes still get a plain, unmarked continue.
test_supervisor_resume_marks_continue_for_firstmate() {
  local dir state marker submitted now
  dir="$TMP_ROOT/resume-firstmate-mark"
  state="$dir/state"
  mkdir -p "$state"
  now=$(date +%s)
  marker="$state/firstmate.ratelimit"
  printf '%s\tfirstmate:0\tclaude\n' "$((now - 10))" > "$marker"
  submitted="$dir/submitted"
  fm_backend_target_exists() { return 0; }
  fm_backend_busy_state() { printf 'idle'; }
  fm_backend_capture() { printf 'Claude usage limit reached. Your limit will reset at 1 PM (UTC).\n'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf '%s' "$3" > "$submitted"; printf 'pending'; }
  FM_STATE_OVERRIDE="$state" FM_SUPERVISOR_BACKEND=tmux FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=9 \
    fm_ratelimit_resume_scan "$state" >/dev/null || true
  [ -s "$submitted" ] || fail "firstmate supervisor resume never submitted a continue"
  case "$(cat "$submitted")" in
    "${FM_INJECT_MARK}continue") ;;
    *) fail "firstmate resume text was not the marked continue: $(od -An -tx1 "$submitted")" ;;
  esac
  pass "firstmate supervisor-pane auto-resume submits an inject-marked continue"
}

test_crew_resume_submits_plain_unmarked_continue() {
  local dir state marker submitted now
  dir="$TMP_ROOT/resume-crew-plain"
  state="$dir/state"
  mkdir -p "$state"
  now=$(date +%s)
  marker="$state/task.ratelimit"
  printf '%s\ttest:fm-task\tclaude\n' "$((now - 10))" > "$marker"
  submitted="$dir/submitted"
  fm_backend_target_exists() { return 0; }
  fm_backend_busy_state() { printf 'idle'; }
  fm_backend_capture() { printf 'Claude usage limit reached. Your limit will reset at 1 PM (UTC).\n'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf '%s' "$3" > "$submitted"; printf 'pending'; }
  FM_STATE_OVERRIDE="$state" FM_RATELIMIT_MARGIN=0 FM_RATELIMIT_MAX_RESUMES=9 \
    fm_ratelimit_resume_scan "$state" >/dev/null || true
  [ -s "$submitted" ] || fail "crew resume never submitted a continue"
  [ "$(cat "$submitted")" = continue ] \
    || fail "crew resume text was not a plain continue: $(od -An -tx1 "$submitted")"
  pass "a crew pane auto-resume submits a plain, unmarked continue"
}

test_reset_parser_handles_iana_timezone_and_dst
test_reset_parser_handles_utc_24h_and_fallback
test_footer_match_is_tail_anchored
test_accepted_submit_while_limited_counts_attempt_not_recovery
test_accepted_submit_still_limited_exhausts_across_scans
test_resume_submit_then_recovery_clears_marker
test_resume_exhaustion_escalates_and_leaves_marker
test_marker_write_preserves_active_episode_reset
test_resume_self_recovered_clears_without_submit
test_overload_regex_matches_only_529
test_overload_uses_short_fallback_distinct_from_quota
test_render_match_reuses_marker_reset_without_reparsing
test_marker_reset_reads_only_matching_episode
test_supervisor_resume_marks_continue_for_firstmate
test_crew_resume_submits_plain_unmarked_continue
