#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards (bin/fm-pending-reply-lib.sh).
#
# Reproduces the missed-report experience: a marked request is delivered, the
# target turn completes, and no correlated parent report arrives. The parent
# must notice without scraping conversation, send exactly one recovery repost,
# and escalate once if that recovery turn is also missed.
#
# Coverage:
#   1. Normal correlated reply resolves once
#   2. Completed turn with no report triggers one recovery only
#   3. Recovery reply resolves the original expectation
#   4. Second missed turn escalates once and remains durable
#   5. Transport success cannot masquerade as reply success
#   6. Unrelated events and stale correlation ids cannot resolve a request
#   7. Restart/compaction preserves the expectation and exact parent destination
#   8. Wrong-home reports are detected but do not silently acknowledge
#   9. Direct unmarked captain input creates no expectation
#  10. fm-send secondmate path embeds corr and creates durable pending records
#  11. Backend busy/idle observation works through the shared busy abstraction
#      used by Pi/Claude secondmate backends (no conversation scrape)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-pending-reply)

export FM_PENDING_REPLY_GRACE_SECS=0
export FM_SEND_SETTLE=0

# --- fixtures ---------------------------------------------------------------

make_stubs() {  # <dir> -> fakebin
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
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

setup_parent() {  # <name> -> home
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_PENDING_REPLY_GRACE_SECS=0 \
    "$SEND" "$@" 2>/dev/null
}

phase_of() {  # <state> <corr>
  fm_pending_reply_get "$(fm_pending_reply_path "$1" "$2")" phase
}

# --- tests ------------------------------------------------------------------

test_normal_correlated_reply_resolves_once() {
  local home state corr status rec
  home=$(setup_parent resolve-once)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=1000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "audit the ledger")
  fm_pending_reply_mark_delivered "$state" "$corr"
  status="$state/hibit.status"
  printf 'done [corr=%s]: ledger clean\n' "$corr" > "$status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "correlated status should resolve"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase should be resolved"
  # Idempotent second resolve.
  fm_pending_reply_try_resolve "$state" "$corr" || fail "second resolve must stay successful"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase must remain resolved"
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = status ] \
    || fail "resolved_via should be status"
  pass "normal correlated reply resolves once (idempotent)"
}

test_completed_turn_no_report_triggers_one_recovery() {
  local home state corr hook_log rec
  home=$(setup_parent one-recovery)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-hook.log"
  : > "$hook_log"
  export FM_PENDING_REPLY_NOW=2000
  export FM_PENDING_REPLY_SEND_HOOK='printf "%s\t%s\n" >>"'"$hook_log"'"'
  # The hook above is wrong for eval form - use a function.
  recovery_hook() {
    printf '%s\t%s\n' "$1" "$2" >> "$hook_log"
  }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "status of phase 7")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Turn completes with no parent report (the Hi Bit missed-report shape).
  fm_pending_reply_observe_busy "$state" "$corr" busy
  fm_pending_reply_observe_busy "$state" "$corr" idle
  fm_pending_reply_send_recovery "$state" "$corr" \
    || fail "recovery should send after completed turn + grace"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "phase should be recovery_sent, got $(phase_of "$state" "$corr")"
  [ -s "$hook_log" ] || fail "recovery hook should have been invoked once"
  # Second attempt must not re-send.
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "second recovery must refuse"
  fi
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "expected exactly one recovery send, got $lines"
  rec=$(fm_pending_reply_path "$state" "$corr")
  case "$(cat "$hook_log")" in
    *"corr=$corr"*) : ;;
    *) fail "recovery message must carry the original corr"$'\n'"$(cat "$hook_log")" ;;
  esac
  case "$(cat "$hook_log")" in
    *REPOST\ REQUIRED*) : ;;
    *) fail "recovery message must ask for a repost"$'\n'"$(cat "$hook_log")" ;;
  esac
  pass "completed turn with no report triggers exactly one recovery"
}

test_recovery_reply_resolves_original() {
  local home state corr hook_log
  home=$(setup_parent recovery-resolve)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-resolve-hook.log"
  : > "$hook_log"
  recovery_hook() { printf '%s\n' "$2" >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  export FM_PENDING_REPLY_NOW=3000

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "phase 7 status")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  printf 'done [corr=%s]: phase 7 is Done (reposted)\n' "$corr" > "$state/hibit.status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "recovery reply should resolve original"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "expected resolved after recovery reply"
  pass "recovery reply resolves the original expectation"
}

test_second_missed_turn_escalates_once_and_stays_durable() {
  local home state corr hook_log rec status_line
  home=$(setup_parent escalate-once)
  state="$home/state"
  hook_log="$TMP_ROOT/escalate-hook.log"
  : > "$hook_log"
  recovery_hook() { printf '%s\n' ok >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  export FM_PENDING_REPLY_NOW=4000
  # Do not export STATE into the test process: fm-send resolves
  # FM_STATE_OVERRIDE/STATE from the environment and a leak breaks later cases.

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "why is phase 7 stuck")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  # Recovery turn also completes with no correlated report.
  fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
  fm_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation should fire"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase should be escalated"
  status_line=$(tail -1 "$state/hibit.status")
  case "$status_line" in
    blocked:*pending-reply-missed:*pending-reply-id=$corr*) : ;;
    *) fail "parent status should carry one blocked missed-report line"$'\n'"$status_line" ;;
  esac
  # Second escalate must be a no-op (phase no longer recovery_sent).
  if fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null; then
    # Function returns 1 when phase is not recovery_sent - good.
    :
  fi
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase must stay escalated"
  # Durable record retained (never silently expired).
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || fail "escalated record must remain on disk"
  [ "$(fm_pending_reply_get "$rec" parent_status)" = "$state/hibit.status" ] \
    || fail "parent destination must remain exact"
  # Unrelated status activity still does not resolve.
  printf 'working: unrelated churn\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "unrelated status must not resolve an escalated miss"
  fi
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "must remain escalated after unrelated status"
  pass "second missed turn escalates once and remains durable"
}

test_transport_success_is_not_reply_success() {
  local home state corr
  home=$(setup_parent transport-not-reply)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=5000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "ping")
  fm_pending_reply_mark_delivered "$state" "$corr" || fail "mark delivered failed"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "delivery must leave phase awaiting_report, got $(phase_of "$state" "$corr")"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "delivery alone must not resolve"
  fi
  pass "transport success cannot masquerade as reply success"
}

test_unrelated_and_stale_corr_cannot_resolve() {
  local home state corr other
  home=$(setup_parent stale-corr)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=6000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "need answer")
  fm_pending_reply_mark_delivered "$state" "$corr"
  other=$(fm_pending_reply_new_id)
  printf 'done [corr=%s]: wrong token\n' "$other" > "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "stale/wrong corr must not resolve"
  fi
  printf 'working: still thinking\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "unrelated working line must not resolve"
  fi
  printf 'done: finished without corr\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "status without corr must not resolve"
  fi
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase must stay awaiting_report"
  pass "unrelated events and stale correlation ids cannot resolve"
}

test_restart_preserves_expectation_and_parent_destination() {
  local home state corr rec parent_status parent_home
  home=$(setup_parent restart)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=7000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "survive restart")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  parent_home=$(fm_pending_reply_get "$rec" parent_home)
  # Simulate process restart: re-source library and re-read the same record.
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  [ -f "$rec" ] || fail "record must survive restart"
  [ "$(fm_pending_reply_get "$rec" parent_status)" = "$parent_status" ] \
    || fail "parent_status must be stable across restart"
  [ "$(fm_pending_reply_get "$rec" parent_home)" = "$parent_home" ] \
    || fail "parent_home must be stable across restart"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase preserved"
  # Compaction-safe: destination is absolute path fields, not chat memory.
  case "$parent_status" in
    /*.status) : ;;
    *) fail "parent_status should be an absolute status path, got $parent_status" ;;
  esac
  pass "restart preserves expectation and exact parent destination"
}

test_wrong_home_detected_not_acknowledged() {
  local home state sm_home corr rec hits
  home=$(setup_parent wrong-home)
  state="$home/state"
  sm_home="$TMP_ROOT/sm-home-$RANDOM"
  mkdir -p "$sm_home/state"
  export FM_PENDING_REPLY_NOW=8000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "report to parent")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Historical incident shape: report written under the secondmate home.
  printf 'done [corr=%s]: stranded in self-home\n' "$corr" > "$sm_home/state/hibit.status"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "wrong-home detect should succeed"
  rec=$(fm_pending_reply_path "$state" "$corr")
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" -ge 1 ] || fail "wrong_home_hits should increment, got $hits"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "wrong-home must not silently acknowledge (phase=$(phase_of "$state" "$corr"))"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "wrong-home status must not resolve via parent path"
  fi
  pass "wrong-home reports are detected but do not silently acknowledge"
}

test_unmarked_captain_input_creates_no_expectation() {
  local dir fb log home rc pending_count
  dir="$TMP_ROOT/unmarked"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent unmarked)
  # Crewmate target stays unmarked and creates no pending-reply record.
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "build" "captain says hello"; rc=$?
  expect_code 0 "$rc" "unmarked crewmate send should succeed"
  [ "$(cat "$log")" = "captain says hello" ] \
    || fail "crewmate send should stay unmarked"$'\n'"$(cat "$log" | od -An -c)"
  pending_count=$(find "$home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$pending_count" = 0 ] || fail "unmarked input must create no pending-reply records (got $pending_count)"
  pass "direct unmarked captain input creates no expectation"
}

test_fm_send_marked_secondmate_creates_pending_and_embeds_corr() {
  local dir fb log home rc got corr rec
  dir="$TMP_ROOT/send-pending"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent send-pending)
  fm_write_secondmate_meta "$home/state/hibit.meta" "$home/sm" "sess:fm-hibit"
  run_send "$fb" "$home" "$log" "hibit" "audit the build"; rc=$?
  expect_code 0 "$rc" "secondmate send should succeed"
  got=$(cat "$log")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "secondmate send must embed marker+corr"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  corr=$(fm_pending_reply_extract_corr "$got")
  [ "${#corr}" -eq 16 ] || fail "corr id should be 16 hex chars, got '$corr'"
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  [ -f "$rec" ] || fail "pending-reply record must exist after marked send"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "phase should be awaiting_report after delivery"
  [ -n "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "delivered_epoch must be set after successful send"
  [ "$(fm_pending_reply_get "$rec" task_id)" = hibit ] \
    || fail "task_id must match secondmate id"
  pass "fm-send marked secondmate path creates pending and embeds corr"
}

test_document_pointer_resolves() {
  local home state corr
  home=$(setup_parent doc-pointer)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "deep audit")
  fm_pending_reply_mark_delivered "$state" "$corr"
  printf 'done [corr=%s]: see data/hibit/report.md\n' "$corr" > "$state/hibit.status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "document pointer status should resolve"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" resolved_via)" = document ] \
    || fail "resolved_via should be document"
  pass "status-pointed document resolves the expectation"
}

test_helper_report_resolves() {
  local home state corr
  home=$(setup_parent helper)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9100
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "quick answer")
  fm_pending_reply_mark_delivered "$state" "$corr"
  "$REPORT" "$state/hibit.status" "done" "$corr" "all good" \
    || fail "helper report failed"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "helper report should resolve"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" resolved_via)" = helper ] \
    || fail "resolved_via should be helper"
  pass "optional helper report resolves without being required for correctness"
}

test_busy_idle_observation_via_backend_abstraction() {
  local home state corr
  home=$(setup_parent busy-idle)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9200
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "backend turn")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Simulates Pi/Claude secondmate busy_state from fm_backend_busy_state without
  # reading conversation text (herdr native idle/busy or tmux unknown fallback).
  fm_pending_reply_observe_busy "$state" "$corr" unknown
  [ -z "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" request_turn_completed_epoch)" ] \
    || fail "unknown busy_state must not prove turn completion"
  fm_pending_reply_observe_busy "$state" "$corr" busy
  fm_pending_reply_observe_busy "$state" "$corr" idle
  [ -n "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" request_turn_completed_epoch)" ] \
    || fail "busy->idle must prove turn completion"
  pass "backend busy/idle observation covers Pi/Claude paths without conversation scrape"
}

test_tick_end_to_end_missed_then_escalate() {
  local home state corr hook_log sm_home
  home=$(setup_parent tick-e2e)
  state="$home/state"
  sm_home="$home/sm"
  mkdir -p "$sm_home/state"
  hook_log="$TMP_ROOT/tick-hook.log"
  : > "$hook_log"
  recovery_hook() { printf 'recovered\n' >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  export FM_PENDING_REPLY_NOW=9300

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "e2e miss")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "sess:fm-hibit"
  # Override backend busy via direct tick_one (backend may be unknown in hermetic home).
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "tick should send recovery after idle+grace, got $(phase_of "$state" "$corr")"
  [ -s "$hook_log" ] || fail "recovery should have been sent via tick"
  # Recovery turn completes empty.
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = escalated ] \
    || fail "tick should escalate after second miss, got $(phase_of "$state" "$corr")"
  # Expired age must not erase the unresolved record.
  export FM_PENDING_REPLY_NOW=999999
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ -f "$(fm_pending_reply_path "$state" "$corr")" ] \
    || fail "expiration must never silently erase an unresolved reply"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "must stay escalated"
  pass "tick end-to-end: miss -> one recovery -> escalate -> durable"
}

test_failed_send_discards_undelivered_expectation() {
  local home state corr
  home=$(setup_parent discard)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9400
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "never lands")
  # Not delivered: discard is allowed.
  fm_pending_reply_discard_undelivered "$state" "$corr" || fail "discard undelivered failed"
  [ ! -f "$(fm_pending_reply_path "$state" "$corr")" ] \
    || fail "undelivered record should be removed"
  # Delivered records must not be discarded by this path.
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "landed")
  fm_pending_reply_mark_delivered "$state" "$corr"
  if fm_pending_reply_discard_undelivered "$state" "$corr" 2>/dev/null; then
    fail "delivered record must not be discarded"
  fi
  [ -f "$(fm_pending_reply_path "$state" "$corr")" ] || fail "delivered record must remain"
  pass "failed transport discards undelivered expectation only"
}

# --- run --------------------------------------------------------------------

test_normal_correlated_reply_resolves_once
test_completed_turn_no_report_triggers_one_recovery
test_recovery_reply_resolves_original
test_second_missed_turn_escalates_once_and_stays_durable
test_transport_success_is_not_reply_success
test_unrelated_and_stale_corr_cannot_resolve
test_restart_preserves_expectation_and_parent_destination
test_wrong_home_detected_not_acknowledged
test_unmarked_captain_input_creates_no_expectation
test_fm_send_marked_secondmate_creates_pending_and_embeds_corr
test_document_pointer_resolves
test_helper_report_resolves
test_busy_idle_observation_via_backend_abstraction
test_tick_end_to_end_missed_then_escalate
test_failed_send_discards_undelivered_expectation

printf 'ok - all pending-reply tests passed\n'
