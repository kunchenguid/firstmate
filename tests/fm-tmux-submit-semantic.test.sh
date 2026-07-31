#!/usr/bin/env bash
# tests/fm-tmux-submit-semantic.test.sh - semantic submit confirmation on the
# tmux path (bin/fm-tmux-lib.sh, bin/backends/tmux.sh) under the
# independent-review redesign: delivery is confirmed ONLY by a positive
# idle-to-busy transition observed after a delivered Enter, under a per-task
# submit lock. Covered here:
#   - a submit is confirmed from the lifecycle record; at the shipped default
#     (bake-in comparison ON) exactly one post-verdict pane read happens, and
#     with the comparison off (the post-bake-in configuration) zero pane
#     reads happen,
#   - an unchanged record never confirms: a busy baseline (spawn seed or a
#     real trusted mid-turn event) routes to the labelled composer fallback,
#   - a failed Enter keystroke is send-failed, never a confirmation,
#   - a contended submit lock fails closed without typing; a stale lock from
#     a dead holder is broken and the send proceeds,
#   - a contradicted confirmation is DOWNGRADED to unconfirmed and recorded
#     durably; the reverse disagreement stays unconfirmed and is recorded,
#   - harnesses with no semantic source (codex/kimi) keep the scraper with an
#     explicit composer-fallback label, and a context-free call (the
#     away-mode daemon's shape) keeps the bare single-token verdict,
#   - fm-send plumbs the semantic context end to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "could not source the tmux adapter"

SEND="$ROOT/bin/fm-send.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
TMP_ROOT=$(fm_test_tmproot fm-tmux-submit-semantic)

# Fast confirmation and lock windows for every case in this file.
export FM_SUBMIT_SEMANTIC_MIN_BUDGET=0.05
export FM_SUBMIT_SEMANTIC_POLLS=3
export FM_SUBMIT_LOCK_WAIT=1

# Fake tmux: logs every pane-touching call so the pane-read assertions are
# call-count facts, optionally runs a "lifecycle hook" script on Enter to
# simulate the harness writing its busy record at submit time, and optionally
# fails the Enter keystroke itself (FM_FAKE_ENTER_FAIL=1) to model a dead
# pane accepting the literal type but rejecting the submit keystroke.
make_fake_tmux() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log() { [ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$1" >> "$FM_FAKE_TMUX_LOG"; }
case "${1:-}" in
  display-message)
    log display-message
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    log capture-pane
    [ -z "${FM_FAKE_COMPOSER:-}" ] || cat "$FM_FAKE_COMPOSER" 2>/dev/null
    exit 0 ;;
  send-keys)
    shift
    is_enter=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift ;; -l) ;; Enter) is_enter=1 ;; esac
      shift
    done
    if [ "$is_enter" = 1 ]; then
      if [ "${FM_FAKE_ENTER_FAIL:-0}" = 1 ]; then
        log Enter-failed
        exit 1
      fi
      log Enter
      [ -z "${FM_FAKE_HOOK_ON_ENTER:-}" ] || bash "$FM_FAKE_HOOK_ON_ENTER"
    else
      log typed
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

count_log() {  # <log> <token>
  grep -cx "$2" "$1" 2>/dev/null || true
}

# arm_idle <state> <id>: arm the busy contract and settle it to an idle
# baseline through the trusted claude-hook source. Echoes the minted gen.
arm_idle() {
  local state=$1 id=$2 gen
  gen=$("$BUSY_EVENT" arm "$state" "$id") || fail "arm failed for $id"
  "$BUSY_EVENT" apply "$state" "$id" idle --gen "$gen" --source claude-hook --event stop \
    || fail "idle baseline apply failed for $id"
  printf '%s\n' "$gen"
}

write_hook() {  # <file> <state> <id> <gen>
  cat > "$1" <<EOF
"$BUSY_EVENT" apply "$2" "$3" busy --gen "$4" --source claude-hook --event user-prompt-submit >/dev/null 2>&1
EOF
}

test_semantic_confirm_no_pane_capture_when_compare_off() {
  local dir fb state id gen log vfile
  dir="$TMP_ROOT/no-capture"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-a
  gen=$(arm_idle "$state" "$id")
  write_hook "$dir/hook.sh" "$state" "$id" "$gen"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_HOOK_ON_ENTER="$dir/hook.sh" \
    FM_SUBMIT_SEMANTIC_COMPARE=0 \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "empty turn-opened" ] \
    || fail "semantic confirm expected 'empty turn-opened', got '$(cat "$vfile")'"
  [ "$(count_log "$log" capture-pane)" -eq 0 ] \
    || fail "with the comparison off the semantic path must not capture the pane"
  [ "$(count_log "$log" display-message)" -eq 0 ] \
    || fail "with the comparison off the semantic path must not read pane geometry"
  [ "$(count_log "$log" Enter)" -eq 1 ] \
    || fail "a first-attempt confirm should send exactly one Enter"
  [ ! -e "$state/$id.submit-lock" ] \
    || fail "the submit lock must be released after the send"
  pass "semantic submit: confirmed from the lifecycle record with zero pane reads (comparison off)"
}

test_semantic_confirm_default_env_single_post_verdict_read() {
  local dir fb state id gen log vfile err
  dir="$TMP_ROOT/default-env"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"
  vfile="$dir/verdict"; err="$dir/err"
  id=task-a2
  gen=$(arm_idle "$state" "$id")
  write_hook "$dir/hook.sh" "$state" "$id" "$gen"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_HOOK_ON_ENTER="$dir/hook.sh" \
    FM_FAKE_COMPOSER="$dir/composer" \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2> "$err"
  [ "$(cat "$vfile")" = "empty turn-opened" ] \
    || fail "default-env semantic confirm expected 'empty turn-opened', got '$(cat "$vfile")'"
  [ "$(count_log "$log" capture-pane)" -eq 1 ] \
    || fail "the shipped default performs exactly ONE post-verdict comparison capture, got $(count_log "$log" capture-pane)"
  [ ! -s "$err" ] || fail "an agreeing composer must not warn: $(cat "$err")"
  assert_absent "$state/$id.submit-disagreement" \
    "an agreeing comparison must not write a disagreement record"
  pass "semantic submit: shipped default reads the pane exactly once, after the verdict, for comparison only"
}

test_contradicted_confirmation_downgrades_to_unconfirmed() {
  local dir fb state id gen log vfile err
  dir="$TMP_ROOT/downgrade"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"
  vfile="$dir/verdict"; err="$dir/err"
  id=task-b
  gen=$(arm_idle "$state" "$id")
  write_hook "$dir/hook.sh" "$state" "$id" "$gen"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_HOOK_ON_ENTER="$dir/hook.sh" \
    FM_FAKE_COMPOSER="$dir/composer" FM_SUBMIT_SEMANTIC_COMPARE=1 \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2> "$err"
  [ "$(cat "$vfile")" = "unknown semantic-contradicted" ] \
    || fail "a contradicted confirmation must downgrade to unconfirmed, got '$(cat "$vfile")'"
  assert_grep "SUBMIT-CONFIRM DISAGREEMENT" "$err" \
    "the downgrade must print the loud disagreement warning"
  assert_grep "DOWNGRADED" "$err" \
    "the warning must state the confirmation was downgraded"
  assert_present "$state/$id.submit-disagreement" \
    "the disagreement must be recorded durably, not only on stderr"
  assert_grep "action=downgraded" "$state/$id.submit-disagreement" \
    "the durable record must carry the downgrade action"
  pass "semantic submit: a contradicted confirmation is downgraded and durably recorded"
}

test_disagreement_no_turn_composer_empty() {
  local dir fb state id log vfile err
  dir="$TMP_ROOT/disagree-empty"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"
  vfile="$dir/verdict"; err="$dir/err"
  id=task-c
  arm_idle "$state" "$id" >/dev/null
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SUBMIT_SEMANTIC_COMPARE=1 \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2> "$err"
  [ "$(cat "$vfile")" = "pending no-turn" ] \
    || fail "no lifecycle event must stay unconfirmed, got '$(cat "$vfile")'"
  assert_grep "SUBMIT-CONFIRM DISAGREEMENT" "$err" \
    "cleared composer without a turn must print the loud disagreement warning"
  assert_grep "UNCONFIRMED" "$err" \
    "the warning must state the send stays unconfirmed"
  assert_present "$state/$id.submit-disagreement" \
    "the disagreement must be recorded durably, not only on stderr"
  assert_grep "action=reported" "$state/$id.submit-disagreement" \
    "the durable record must carry the reported action"
  pass "semantic submit: disagreement warning fires and is recorded when the composer cleared without a turn"
}

test_swallowed_enter_stays_pending() {
  local dir fb state id log vfile
  dir="$TMP_ROOT/swallow"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-d
  arm_idle "$state" "$id" >/dev/null
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_SUBMIT_SEMANTIC_COMPARE=0 \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "pending no-turn" ] \
    || fail "an idle pane with no lifecycle event must stay pending, got '$(cat "$vfile")'"
  [ "$(count_log "$log" Enter)" -eq 3 ] \
    || fail "a genuine swallow should consume the configured Enter retry budget"
  pass "semantic submit: idle baseline with no turn stays pending (genuine swallow preserved)"
}

test_enter_keystroke_failure_reports_send_failed() {
  local dir fb state id gen log vfile
  dir="$TMP_ROOT/enter-fail"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-e
  gen=$(arm_idle "$state" "$id")
  write_hook "$dir/hook.sh" "$state" "$id" "$gen"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_HOOK_ON_ENTER="$dir/hook.sh" \
    FM_FAKE_ENTER_FAIL=1 FM_SUBMIT_SEMANTIC_COMPARE=0 \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "send-failed" ] \
    || fail "a send whose every Enter keystroke failed must be send-failed, got '$(cat "$vfile")'"
  [ "$(count_log "$log" Enter-failed)" -eq 3 ] \
    || fail "the failed Enter should still consume the retry budget"
  pass "semantic submit: a rejected Enter keystroke is send-failed, never a confirmation"
}

test_busy_baseline_routes_to_labelled_fallback() {
  local dir fb state id gen log vfile
  # (a) The spawn-time seed: armed, no lifecycle event ever. An unchanged
  # record must never confirm - the send must go to the composer fallback,
  # where an undelivered instruction reads pending and fails loudly.
  dir="$TMP_ROOT/stuck-seed"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-f
  "$BUSY_EVENT" arm "$state" "$id" >/dev/null || fail "arm failed for $id"
  printf '╭────────────╮\n│ > steer    │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$dir/composer" \
    fm_backend_tmux_send_text_submit "sess:win" "steer" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "pending composer-fallback" ] \
    || fail "a stuck spawn-seed busy record must not confirm; expected the fallback's pending, got '$(cat "$vfile")'"
  [ "$(count_log "$log" capture-pane)" -gt 0 ] \
    || fail "the busy-baseline route must prove pane facts at decision time, not trust the record"
  case "$(cat "$vfile")" in
    *enter-queued*) fail "the enter-queued record-trusting verdict must not exist" ;;
  esac
  # (b) A genuine trusted mid-turn record (claude-hook busy event) routes the
  # same way: mid-turn delivery is the fallback's job, labelled as such.
  dir="$TMP_ROOT/real-busy"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-f2
  gen=$("$BUSY_EVENT" arm "$state" "$id") || fail "arm failed for $id"
  "$BUSY_EVENT" apply "$state" "$id" busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "busy apply failed for $id"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$dir/composer" \
    fm_backend_tmux_send_text_submit "sess:win" "steer" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "empty composer-fallback" ] \
    || fail "a proven mid-turn send must confirm through the labelled fallback, got '$(cat "$vfile")'"
  pass "semantic submit: busy baselines never confirm from the record and route to the labelled fallback"
}

test_send_contended_fails_closed() {
  local dir fb state id lockdir log vfile
  dir="$TMP_ROOT/contended"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-g
  arm_idle "$state" "$id" >/dev/null
  # Hold the per-task lock from this live test process.
  lockdir="$state/$id.submit-lock"
  mkdir "$lockdir" || fail "could not pre-hold the submit lock"
  printf '%s\n' "$$" > "$lockdir/pid"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_SUBMIT_SEMANTIC_COMPARE=0 \
    fm_backend_tmux_send_text_submit "sess:win" "steer" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  rm -rf "$lockdir"
  [ "$(cat "$vfile")" = "unknown send-contended" ] \
    || fail "a contended submit lock must fail closed, got '$(cat "$vfile")'"
  [ "$(count_log "$log" typed)" -eq 0 ] \
    || fail "a contended send must not type anything into the pane"
  pass "semantic submit: concurrent sends serialize on the per-task lock and fail closed when contended"
}

test_stale_lock_is_broken_and_send_proceeds() {
  local dir fb state id gen lockdir dead_pid log vfile
  dir="$TMP_ROOT/stale-lock"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-h
  gen=$(arm_idle "$state" "$id")
  write_hook "$dir/hook.sh" "$state" "$id" "$gen"
  # A lock held by a process that no longer exists.
  dead_pid=$(bash -c 'echo $$')
  while kill -0 "$dead_pid" 2>/dev/null; do sleep 0.05; done
  lockdir="$state/$id.submit-lock"
  mkdir "$lockdir" || fail "could not stage the stale lock"
  printf '%s\n' "$dead_pid" > "$lockdir/pid"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_HOOK_ON_ENTER="$dir/hook.sh" \
    FM_SUBMIT_SEMANTIC_COMPARE=0 \
    fm_backend_tmux_send_text_submit "sess:win" "steer" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "empty turn-opened" ] \
    || fail "a stale lock from a dead holder must be broken, got '$(cat "$vfile")'"
  [ ! -e "$lockdir" ] || fail "the reacquired lock must be released after the send"
  pass "semantic submit: a dead holder's stale lock is broken and the send confirms normally"
}

test_codex_keeps_labelled_composer_fallback() {
  local dir fb state log vfile
  dir="$TMP_ROOT/codex-fallback"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$dir/composer" \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" task-i codex \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "empty composer-fallback" ] \
    || fail "codex must confirm through the labelled scraper fallback, got '$(cat "$vfile")'"
  pass "semantic submit: codex keeps the scraper, labelled composer-fallback"
}

test_unarmed_task_falls_back_labelled() {
  local dir fb state log vfile
  dir="$TMP_ROOT/unarmed"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$dir/composer" \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" task-j claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "empty composer-fallback" ] \
    || fail "an unarmed claude task must fall back with the label, got '$(cat "$vfile")'"
  pass "semantic submit: a task without an armed busy contract keeps the labelled fallback"
}

test_context_free_call_keeps_bare_verdict() {
  local dir fb log vfile
  dir="$TMP_ROOT/bare"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$dir/composer" \
    fm_backend_tmux_send_text_submit "sess:win" "digest" 3 0.02 0 \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "empty" ] \
    || fail "a context-free call must keep the bare single-token verdict, got '$(cat "$vfile")'"
  pass "semantic submit: the away-mode daemon call shape keeps its exact bare verdict"
}

test_fm_send_semantic_end_to_end() {
  local dir fb home state id gen log err rc
  dir="$TMP_ROOT/send-e2e"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; err="$dir/err"
  home="$dir/home"; state="$home/state"; mkdir -p "$state"
  id=lane-sem
  fm_write_meta "$state/$id.meta" "window=sess:fm-$id" "kind=ship" "harness=claude"
  gen=$(arm_idle "$state" "$id")
  write_hook "$dir/hook.sh" "$state" "$id" "$gen"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_HOOK_ON_ENTER="$dir/hook.sh" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.02 \
    "$SEND" "$id" "carry on" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "fm-send should confirm a semantic submit"
  [ "$(count_log "$log" typed)" -eq 1 ] || fail "fm-send should type the text once"
  [ "$(count_log "$log" Enter)" -ge 1 ] || fail "fm-send should submit with Enter"
  assert_no_grep "SUBMIT-CONFIRM DISAGREEMENT" "$err" \
    "an agreeing composer must not warn"
  pass "fm-send: semantic context is plumbed end to end and confirms delivery"
}

test_fm_send_codex_fallback_end_to_end() {
  local dir fb home state id log err rc
  dir="$TMP_ROOT/send-codex"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; err="$dir/err"
  home="$dir/home"; state="$home/state"; mkdir -p "$state"
  id=lane-cdx
  fm_write_meta "$state/$id.meta" "window=sess:fm-$id" "kind=ship" "harness=codex"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_COMPOSER="$dir/composer" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.02 \
    "$SEND" "$id" "carry on" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "fm-send to a codex task should still deliver via the labelled fallback"
  [ "$(count_log "$log" typed)" -eq 1 ] || fail "fm-send should type the text once"
  pass "fm-send: codex still works through the labelled composer fallback"
}

test_fm_send_unconfirmed_semantic_reports_confirm_source() {
  local dir fb home state id log err rc
  dir="$TMP_ROOT/send-unconfirmed"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; err="$dir/err"
  home="$dir/home"; state="$home/state"; mkdir -p "$state"
  id=lane-swl
  fm_write_meta "$state/$id.meta" "window=sess:fm-$id" "kind=ship" "harness=claude"
  arm_idle "$state" "$id" >/dev/null
  printf '╭────────────╮\n│ > carry on │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_COMPOSER="$dir/composer" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.02 \
    "$SEND" "$id" "carry on" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed semantic submit must exit non-zero"
  assert_grep "delivery unconfirmed" "$err" "fm-send must report the unconfirmed submit"
  assert_grep "confirm=no-turn" "$err" "fm-send must surface how confirmation was attempted"
  pass "fm-send: an unconfirmed semantic submit fails loudly and names the confirm source"
}

test_fm_send_contradicted_confirmation_fails_and_preserves_recovery() {
  local dir fb home state id gen log err rc
  dir="$TMP_ROOT/send-contradicted"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; err="$dir/err"
  home="$dir/home"; state="$home/state"; mkdir -p "$state"
  id=lane-ctd
  fm_write_meta "$state/$id.meta" "window=sess:fm-$id" "kind=ship" "harness=claude"
  gen=$(arm_idle "$state" "$id")
  write_hook "$dir/hook.sh" "$state" "$id" "$gen"
  printf '╭────────────╮\n│ > carry on │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_HOOK_ON_ENTER="$dir/hook.sh" FM_FAKE_COMPOSER="$dir/composer" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.02 \
    "$SEND" "$id" "carry on" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a contradicted confirmation must make fm-send exit non-zero, not report delivery"
  assert_grep "confirm=semantic-contradicted" "$err" \
    "fm-send must surface the contradiction downgrade"
  assert_present "$state/$id.submit-disagreement" \
    "the contradiction must leave its durable record"
  pass "fm-send: a contradicted confirmation fails loudly instead of marking the instruction delivered"
}

test_semantic_confirm_no_pane_capture_when_compare_off
test_semantic_confirm_default_env_single_post_verdict_read
test_contradicted_confirmation_downgrades_to_unconfirmed
test_disagreement_no_turn_composer_empty
test_swallowed_enter_stays_pending
test_enter_keystroke_failure_reports_send_failed
test_busy_baseline_routes_to_labelled_fallback
test_send_contended_fails_closed
test_stale_lock_is_broken_and_send_proceeds
test_codex_keeps_labelled_composer_fallback
test_unarmed_task_falls_back_labelled
test_context_free_call_keeps_bare_verdict
test_fm_send_semantic_end_to_end
test_fm_send_codex_fallback_end_to_end
test_fm_send_unconfirmed_semantic_reports_confirm_source
test_fm_send_contradicted_confirmation_fails_and_preserves_recovery
