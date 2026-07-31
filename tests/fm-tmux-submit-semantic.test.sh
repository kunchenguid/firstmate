#!/usr/bin/env bash
# tests/fm-tmux-submit-semantic.test.sh - semantic submit confirmation on the
# tmux path (the finish of the #1327 migration in bin/fm-tmux-lib.sh and
# bin/backends/tmux.sh):
#   - a submit is confirmed from the harness lifecycle record with NO pane
#     capture (composer geometry and luminance never consulted),
#   - the bake-in disagreement warning fires when the semantic and rendered
#     signals differ, in both directions,
#   - the record-proven busy-queued Enter and genuine-swallow verdicts hold,
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

# Fast confirmation window for every case in this file.
export FM_SUBMIT_SEMANTIC_MIN_BUDGET=0.05
export FM_SUBMIT_SEMANTIC_POLLS=3

# Fake tmux: logs every pane-touching call so the no-capture assertion is a
# call-count fact, and optionally runs a "lifecycle hook" script on Enter to
# simulate the harness writing its busy record at submit time.
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

test_semantic_confirm_no_pane_capture() {
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
    || fail "semantic confirm must not capture the pane"
  [ "$(count_log "$log" display-message)" -eq 0 ] \
    || fail "semantic confirm must not read pane geometry"
  [ "$(count_log "$log" Enter)" -eq 1 ] \
    || fail "a first-attempt confirm should send exactly one Enter"
  pass "semantic submit: confirmed from the lifecycle record with no pane capture"
}

test_disagreement_semantic_confirmed_composer_pending() {
  local dir fb state id gen log vfile err
  dir="$TMP_ROOT/disagree-pending"; state="$dir/state"; mkdir -p "$state"
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
  [ "$(cat "$vfile")" = "empty turn-opened" ] \
    || fail "semantic verdict must decide even when the composer disagrees, got '$(cat "$vfile")'"
  assert_grep "SUBMIT-CONFIRM DISAGREEMENT" "$err" \
    "confirmed turn + pending composer must print the loud disagreement warning"
  assert_grep "mis-wired lifecycle hook" "$err" \
    "the warning must name the mis-wired-hook risk"
  pass "semantic submit: disagreement warning fires when the composer still shows text"
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
  pass "semantic submit: disagreement warning fires when the composer cleared without a turn"
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

test_busy_baseline_enter_queued() {
  local dir fb state id log vfile
  dir="$TMP_ROOT/queued"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  id=task-e
  "$BUSY_EVENT" arm "$state" "$id" >/dev/null || fail "arm failed for $id"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_SUBMIT_SEMANTIC_COMPARE=0 \
    fm_backend_tmux_send_text_submit "sess:win" "steer" 3 0.02 0 "" "$state" "$id" claude \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = "empty enter-queued" ] \
    || fail "a record-proven mid-turn pane must accept the queued Enter, got '$(cat "$vfile")'"
  [ "$(count_log "$log" capture-pane)" -eq 0 ] \
    || fail "the queued verdict must come from the record, not a pane read"
  pass "semantic submit: record-proven busy pane reports the Enter queued"
}

test_codex_keeps_labelled_composer_fallback() {
  local dir fb state log vfile
  dir="$TMP_ROOT/codex-fallback"; state="$dir/state"; mkdir -p "$state"
  fb=$(make_fake_tmux "$dir"); log="$dir/tmux.log"; : > "$log"; vfile="$dir/verdict"
  printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$dir/composer"
  PATH="$fb:$PATH" FM_FAKE_TMUX_LOG="$log" FM_FAKE_COMPOSER="$dir/composer" \
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" task-f codex \
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
    fm_backend_tmux_send_text_submit "sess:win" "do the thing" 3 0.02 0 "" "$state" task-g claude \
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

test_semantic_confirm_no_pane_capture
test_disagreement_semantic_confirmed_composer_pending
test_disagreement_no_turn_composer_empty
test_swallowed_enter_stays_pending
test_busy_baseline_enter_queued
test_codex_keeps_labelled_composer_fallback
test_unarmed_task_falls_back_labelled
test_context_free_call_keeps_bare_verdict
test_fm_send_semantic_end_to_end
test_fm_send_codex_fallback_end_to_end
test_fm_send_unconfirmed_semantic_reports_confirm_source
