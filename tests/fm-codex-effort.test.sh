#!/usr/bin/env bash
# Behavior tests for the public idle-Codex effort switch interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWITCH="$ROOT/bin/fm-codex-effort.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-effort)
FIXTURE_ROOT="$ROOT/tests/fixtures/codex-effort"

make_case() {  # <name> [backend]
  local name=$1 backend=${2:-herdr} id=effort-task dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/worktree" "$dir/project" "$dir/fakebin"
  printf 'high\n' > "$dir/effort"
  : > "$dir/runtime.log"
  if [ "$backend" = tmux ]; then
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=lab:fm-$id" \
      "endpoint_task_id=$id" \
      "worktree=$dir/worktree" \
      "project=$dir/project" \
      "harness=codex" \
      "model=gpt-5.6-sol" \
      "effort=high" \
      "session_marker=keep-me"
  elif [ "$backend" = zellij ]; then
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=lab:1" \
      "endpoint_task_id=$id" \
      "worktree=$dir/worktree" \
      "project=$dir/project" \
      "harness=codex" \
      "model=gpt-5.6-sol" \
      "effort=high" \
      "backend=zellij" \
      "zellij_session=lab" \
      "zellij_tab_id=1" \
      "zellij_pane_id=1"
  elif [ "$backend" = orca ]; then
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=fm-$id" \
      "endpoint_task_id=$id" \
      "worktree=$dir/worktree" \
      "project=$dir/project" \
      "harness=codex" \
      "model=gpt-5.6-sol" \
      "effort=high" \
      "backend=orca" \
      "terminal=term1" \
      "orca_worktree_id=worktree1"
  elif [ "$backend" = cmux ]; then
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=workspace1:surface1" \
      "endpoint_task_id=$id" \
      "worktree=$dir/worktree" \
      "project=$dir/project" \
      "harness=codex" \
      "model=gpt-5.6-sol" \
      "effort=high" \
      "backend=cmux" \
      "cmux_workspace_id=workspace1" \
      "cmux_surface_id=surface1"
  else
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=lab:w1:p1" \
      "endpoint_task_id=$id" \
      "worktree=$dir/worktree" \
      "project=$dir/project" \
      "harness=codex" \
      "model=gpt-5.6-sol" \
      "effort=high" \
      "backend=$backend" \
      "herdr_session=lab" \
      "herdr_workspace_id=w1" \
      "herdr_tab_id=w1:t1" \
      "herdr_pane_id=w1:p1" \
      "session_marker=keep-me"
  fi
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '<' >> "${FM_FAKE_LOG:?}"
printf '%q ' "$@" >> "$FM_FAKE_LOG"
printf '>\n' >> "$FM_FAKE_LOG"
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "pane get")
    if [ "${FM_FAKE_PANE_STATE:-present}" = missing ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    else
      printf '{"result":{"pane":{"pane_id":"w1:p1","foreground_cwd":"%s"}}}\n' "$FM_FAKE_WORKTREE"
    fi
    ;;
  "agent get")
    status=${FM_FAKE_AGENT_STATUS:-idle}
    if [ -n "${FM_FAKE_AGENT_STATUS_FILE:-}" ] && [ -f "$FM_FAKE_AGENT_STATUS_FILE" ]; then
      status=$(cat "$FM_FAKE_AGENT_STATUS_FILE")
    fi
    printf '{"result":{"agent":{"agent":"codex","agent_status":"%s"}}}\n' "$status"
    ;;
  "pane read")
    effort=$(cat "$FM_FAKE_EFFORT_FILE")
    meta_effort=$(grep '^effort=' "$FM_FAKE_META" | cut -d= -f2-)
    if [ "$effort" = "$FM_FAKE_TARGET_EFFORT" ] && [ "$meta_effort" = high ]; then
      : > "$FM_FAKE_VERIFIED_BEFORE_META"
    fi
    if [ -n "${FM_FAKE_FOOTER_FIXTURE:-}" ]; then
      sed "s/gpt-5.6-sol high ·/gpt-5.6-sol $effort ·/" "$FM_FAKE_FOOTER_FIXTURE"
    elif [ -e "$FM_FAKE_CHANGED_FILE" ]; then
      printf '%s\n' 'unrecognized Codex screen without a footer'
    elif [ "${FM_FAKE_UI:-footer}" = footer ]; then
      printf 'transcript\n\n› \n\n  gpt-5.6-sol %s · %s\n' "$effort" "$FM_FAKE_WORKTREE"
    elif [ "${FM_FAKE_UI}" = busy ]; then
      printf 'Working (esc to interrupt)\n\n› \n\n  gpt-5.6-sol %s · %s\n' "$effort" "$FM_FAKE_WORKTREE"
    elif [ "${FM_FAKE_UI}" = misleading ]; then
      printf 'Model set to gpt-5.6-sol %s\n\n› \n\n  gpt-5.6-sol %s · %s\n' "$FM_FAKE_TARGET_EFFORT" "$effort" "$FM_FAKE_WORKTREE"
    elif [ "${FM_FAKE_UI}" = scrollback-only ]; then
      printf 'transcript copied from an earlier footer: gpt-5.6-sol %s · %s\n\n› \n' "$effort" "$FM_FAKE_WORKTREE"
    else
      printf '%s\n' "${FM_FAKE_UI}"
    fi
    ;;
  "pane send-text")
    key=${4:-}
    if [ "${FM_FAKE_BLOCK_ORDINARY_SEND:-0}" = 1 ] \
      && [ "$key" != "$(printf '\033.')" ] \
      && [ "$key" != "$(printf '\033,')" ]; then
      : > "${FM_FAKE_SEND_ENTERED:?}"
      while [ ! -e "${FM_FAKE_ALLOW_SEND:?}" ]; do sleep 0.01; done
      [ -z "${FM_FAKE_SENT_TEXT:-}" ] || printf '%s\n' "$key" >> "$FM_FAKE_SENT_TEXT"
      exit 0
    fi
    effort=$(cat "$FM_FAKE_EFFORT_FILE")
    case "$key" in
      "$(printf '\033.')")
        case "$effort" in low) effort=medium ;; medium) effort=high ;; high) effort=xhigh ;; xhigh) : ;; esac
        printf 'increase\n' >> "$FM_FAKE_LOG"
        ;;
      "$(printf '\033,')")
        case "$effort" in xhigh) effort=high ;; high) effort=medium ;; medium) effort=low ;; low) : ;; esac
        printf 'decrease\n' >> "$FM_FAKE_LOG"
        ;;
      *)
        [ -z "${FM_FAKE_SENT_TEXT:-}" ] || printf '%s\n' "$key" >> "$FM_FAKE_SENT_TEXT"
        ;;
    esac
    if [ "${FM_FAKE_SWALLOW:-0}" != 1 ]; then
      printf '%s\n' "$effort" > "$FM_FAKE_EFFORT_FILE"
    fi
    if [ "${FM_FAKE_CHANGE_UI_AFTER_SEND:-0}" = 1 ]; then
      : > "$FM_FAKE_CHANGED_FILE"
    fi
    if [ "${FM_FAKE_TERM_AFTER_SEND:-0}" = 1 ]; then
      kill -TERM "$PPID"
    fi
    ;;
  "pane send-keys")
    if [ "${FM_FAKE_BLOCK_KEY_SEND:-0}" = 1 ]; then
      : > "${FM_FAKE_KEY_ENTERED:?}"
      while [ ! -e "${FM_FAKE_ALLOW_KEY:?}" ]; do sleep 0.01; done
    fi
    if [ "${4:-}" = enter ] && [ -n "${FM_FAKE_AGENT_STATUS_FILE:-}" ]; then
      printf 'working\n' > "$FM_FAKE_AGENT_STATUS_FILE"
    fi
    ;;
  *) exit 8 ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
last=${!#}
if [ "${FM_FAKE_FAIL_META_MV:-0}" = 1 ] && [ "${last##*/}" = effort-task.meta ]; then
  exit 1
fi
exec "${FM_FAKE_REAL_MV:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '<' >> "${FM_FAKE_LOG:?}"
printf '%q ' "$@" >> "$FM_FAKE_LOG"
printf '>\n' >> "$FM_FAKE_LOG"
case "${1:-}" in
  list-windows)
    printf '%s\n' 'fm-effort-task'
    ;;
  display-message)
    format=${*: -1}
    case "$format" in
      '#{pane_current_command}') printf '%s\n' codex ;;
      '#{pane_current_path}') printf '%s\n' "$FM_FAKE_WORKTREE" ;;
      '#{pane_id}') printf '%s\n' '%1' ;;
      '#{cursor_y}') printf '%s\n' 1 ;;
      *) exit 8 ;;
    esac
    ;;
  capture-pane)
    effort=$(cat "$FM_FAKE_EFFORT_FILE")
    if printf '%s\n' "$*" | grep -Fq -- '-e -p'; then
      printf '╭────╮\n│ ›  │\n╰────╯\n  gpt-5.6-sol %s · %s\n' "$effort" "$FM_FAKE_WORKTREE"
    elif [ -e "$FM_FAKE_CHANGED_FILE" ]; then
      printf '%s\n' 'unrecognized Codex screen without a footer'
    elif [ "${FM_FAKE_UI:-footer}" = busy ]; then
      printf 'Working (esc to interrupt)\n\n› \n\n  gpt-5.6-sol %s · %s\n' "$effort" "$FM_FAKE_WORKTREE"
    else
      printf 'transcript\n\n› \n\n  gpt-5.6-sol %s · %s\n' "$effort" "$FM_FAKE_WORKTREE"
    fi
    ;;
  send-keys)
    key=${*: -1}
    effort=$(cat "$FM_FAKE_EFFORT_FILE")
    case "$key" in
      M-.) case "$effort" in low) effort=medium ;; medium) effort=high ;; high) effort=xhigh ;; esac ;;
      M-,) case "$effort" in xhigh) effort=high ;; high) effort=medium ;; medium) effort=low ;; esac ;;
      *) exit 9 ;;
    esac
    printf '%s\n' "$effort" > "$FM_FAKE_EFFORT_FILE"
    ;;
  *) exit 7 ;;
esac
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

run_case() {  # <dir> <effort>
  local dir=$1 effort=$2
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_LOG="$dir/runtime.log" FM_FAKE_WORKTREE="${FM_FAKE_WORKTREE:-$dir/worktree}" \
    FM_FAKE_EFFORT_FILE="$dir/effort" \
    FM_FAKE_META="$dir/home/state/effort-task.meta" \
    FM_FAKE_TARGET_EFFORT="$effort" \
    FM_FAKE_VERIFIED_BEFORE_META="$dir/verified-before-meta" \
    FM_FAKE_CHANGED_FILE="$dir/changed-ui" \
    FM_FAKE_AGENT_STATUS="${FM_FAKE_AGENT_STATUS:-idle}" \
    FM_FAKE_PANE_STATE="${FM_FAKE_PANE_STATE:-present}" \
    FM_FAKE_UI="${FM_FAKE_UI:-footer}" \
    FM_FAKE_SWALLOW="${FM_FAKE_SWALLOW:-0}" \
    FM_FAKE_CHANGE_UI_AFTER_SEND="${FM_FAKE_CHANGE_UI_AFTER_SEND:-0}" \
    FM_FAKE_TERM_AFTER_SEND="${FM_FAKE_TERM_AFTER_SEND:-0}" \
    FM_FAKE_FAIL_META_MV="${FM_FAKE_FAIL_META_MV:-0}" \
    FM_FAKE_FOOTER_FIXTURE="${FM_FAKE_FOOTER_FIXTURE:-}" \
    FM_FAKE_AGENT_STATUS_FILE="${FM_FAKE_AGENT_STATUS_FILE:-}" \
    FM_FAKE_BLOCK_ORDINARY_SEND="${FM_FAKE_BLOCK_ORDINARY_SEND:-0}" \
    FM_FAKE_SEND_ENTERED="${FM_FAKE_SEND_ENTERED:-}" \
    FM_FAKE_ALLOW_SEND="${FM_FAKE_ALLOW_SEND:-}" \
    FM_FAKE_SENT_TEXT="${FM_FAKE_SENT_TEXT:-}" \
    FM_FAKE_BLOCK_KEY_SEND="${FM_FAKE_BLOCK_KEY_SEND:-0}" \
    FM_FAKE_KEY_ENTERED="${FM_FAKE_KEY_ENTERED:-}" \
    FM_FAKE_ALLOW_KEY="${FM_FAKE_ALLOW_KEY:-}" \
    FM_FAKE_REAL_MV="$(command -v mv)" \
    PATH="$dir/fakebin:$PATH" \
    "$SWITCH" effort-task "$effort"
}

run_send_case() {  # <dir> <message>
  local dir=$1 message=$2
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_LOG="$dir/runtime.log" FM_FAKE_WORKTREE="${FM_FAKE_WORKTREE:-$dir/worktree}" \
    FM_FAKE_EFFORT_FILE="$dir/effort" \
    FM_FAKE_META="$dir/home/state/effort-task.meta" \
    FM_FAKE_TARGET_EFFORT=high \
    FM_FAKE_CHANGED_FILE="$dir/changed-ui" \
    FM_FAKE_AGENT_STATUS="${FM_FAKE_AGENT_STATUS:-idle}" \
    FM_FAKE_PANE_STATE="${FM_FAKE_PANE_STATE:-present}" \
    FM_FAKE_UI="${FM_FAKE_UI:-footer}" \
    FM_FAKE_FOOTER_FIXTURE="${FM_FAKE_FOOTER_FIXTURE:-}" \
    FM_FAKE_AGENT_STATUS_FILE="${FM_FAKE_AGENT_STATUS_FILE:-}" \
    FM_FAKE_BLOCK_ORDINARY_SEND="${FM_FAKE_BLOCK_ORDINARY_SEND:-0}" \
    FM_FAKE_SEND_ENTERED="${FM_FAKE_SEND_ENTERED:-}" \
    FM_FAKE_ALLOW_SEND="${FM_FAKE_ALLOW_SEND:-}" \
    FM_FAKE_SENT_TEXT="${FM_FAKE_SENT_TEXT:-}" \
    FM_FAKE_BLOCK_KEY_SEND="${FM_FAKE_BLOCK_KEY_SEND:-0}" \
    FM_FAKE_KEY_ENTERED="${FM_FAKE_KEY_ENTERED:-}" \
    FM_FAKE_ALLOW_KEY="${FM_FAKE_ALLOW_KEY:-}" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    PATH="$dir/fakebin:$PATH" \
    "$SEND" effort-task "$message"
}

run_key_send_case() {  # <dir> <key>
  local dir=$1 key=$2
  env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_LOG="$dir/runtime.log" FM_FAKE_WORKTREE="${FM_FAKE_WORKTREE:-$dir/worktree}" \
    FM_FAKE_EFFORT_FILE="$dir/effort" \
    FM_FAKE_META="$dir/home/state/effort-task.meta" \
    FM_FAKE_TARGET_EFFORT=high \
    FM_FAKE_CHANGED_FILE="$dir/changed-ui" \
    FM_FAKE_AGENT_STATUS="${FM_FAKE_AGENT_STATUS:-idle}" \
    FM_FAKE_PANE_STATE="${FM_FAKE_PANE_STATE:-present}" \
    FM_FAKE_UI="${FM_FAKE_UI:-footer}" \
    FM_FAKE_FOOTER_FIXTURE="${FM_FAKE_FOOTER_FIXTURE:-}" \
    FM_FAKE_AGENT_STATUS_FILE="${FM_FAKE_AGENT_STATUS_FILE:-}" \
    FM_FAKE_BLOCK_ORDINARY_SEND="${FM_FAKE_BLOCK_ORDINARY_SEND:-0}" \
    FM_FAKE_SEND_ENTERED="${FM_FAKE_SEND_ENTERED:-}" \
    FM_FAKE_ALLOW_SEND="${FM_FAKE_ALLOW_SEND:-}" \
    FM_FAKE_SENT_TEXT="${FM_FAKE_SENT_TEXT:-}" \
    FM_FAKE_BLOCK_KEY_SEND="${FM_FAKE_BLOCK_KEY_SEND:-0}" \
    FM_FAKE_KEY_ENTERED="${FM_FAKE_KEY_ENTERED:-}" \
    FM_FAKE_ALLOW_KEY="${FM_FAKE_ALLOW_KEY:-}" \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    PATH="$dir/fakebin:$PATH" \
    "$SEND" effort-task --key "$key"
}

test_success_changes_effort_in_place_and_then_metadata() {
  local dir out
  dir=$(make_case success)
  out=$(run_case "$dir" medium) || fail "successful effort switch failed: $out"
  assert_contains "$out" "effort-task: gpt-5.6-sol medium" "success did not report the confirmed live effort"
  [ "$(cat "$dir/effort")" = medium ] || fail "live fake Codex effort did not change"
  [ "$(grep '^effort=' "$dir/home/state/effort-task.meta")" = effort=medium ] \
    || fail "metadata did not record the confirmed effort"
  assert_grep "decrease" "$dir/runtime.log" "success did not use the dedicated decrease-reasoning input"
  assert_no_grep "/quit" "$dir/runtime.log" "success exited Codex instead of changing effort in place"
  assert_no_grep "pane run" "$dir/runtime.log" "success submitted a turn instead of using an idle keybinding"
  assert_grep "session_marker=keep-me" "$dir/home/state/effort-task.meta" "success changed session identity metadata"
  assert_present "$dir/verified-before-meta" "metadata changed before the live footer was verified"
  pass "fm-codex-effort: changes an idle Codex effort through the public interface without quit/resume"
}

test_tmux_refuses_without_a_verified_semantic_idle_source() {
  local dir before out rc
  dir=$(make_case tmux-no-semantic-idle tmux)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "tmux effort switch was accepted without semantic idle evidence"
  assert_contains "$out" "no verified semantic Codex idle source" "tmux idle-source refusal was unclear"
  assert_no_grep "send-keys" "$dir/runtime.log" "tmux received an effort chord without semantic idle evidence"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "tmux refusal changed metadata"
  pass "fm-codex-effort: refuses tmux until Codex has a verified semantic idle source"
}

test_invalid_effort_and_wrong_harness_refuse_without_runtime_input() {
  local dir before out rc
  dir=$(make_case invalid-effort)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(run_case "$dir" max 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unsupported effort was accepted"
  assert_contains "$out" "unsupported Codex effort" "invalid effort refusal was unclear"
  [ ! -s "$dir/runtime.log" ] || fail "invalid effort contacted the runtime"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "invalid effort changed metadata"

  dir=$(make_case wrong-harness)
  sed -i 's/^harness=codex$/harness=claude/' "$dir/home/state/effort-task.meta"
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "non-Codex harness was accepted"
  assert_contains "$out" "not Codex" "wrong-harness refusal was unclear"
  assert_no_grep "pane send-text" "$dir/runtime.log" "wrong harness received runtime input"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "wrong harness changed metadata"
  pass "fm-codex-effort: refuses invalid effort and non-Codex tasks without side effects"
}

test_task_id_uses_current_creation_contract() {
  local dir long_id out rc
  dir=$(make_case invalid-id)
  out=$(env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SWITCH" .hidden medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a leading-dot task id was accepted"
  assert_contains "$out" "invalid task id" "leading-dot task-id refusal was unclear"
  [ ! -s "$dir/runtime.log" ] || fail "leading-dot task-id refusal contacted the runtime"

  long_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  out=$(env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SWITCH" "$long_id" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "an overlong task id was accepted"
  assert_contains "$out" "invalid task id" "overlong task-id refusal was unclear"
  [ ! -s "$dir/runtime.log" ] || fail "overlong task-id refusal contacted the runtime"
  pass "fm-codex-effort: uses the current task-id creation boundary"
}

test_lifecycle_and_metadata_locks_refuse_before_runtime_input() {
  local dir lock out rc
  dir=$(make_case control-lock)
  lock="$dir/home/state/.control-effort-task.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  out=$(run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a concurrent lifecycle action was accepted"
  assert_contains "$out" "lifecycle action" "control-lock refusal was unclear"
  [ ! -s "$dir/runtime.log" ] || fail "control-lock refusal contacted the runtime"

  dir=$(make_case metadata-lock)
  lock="$dir/home/state/.meta-effort-task.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  out=$(run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a concurrent metadata update was accepted"
  assert_contains "$out" "metadata update" "metadata-lock refusal was unclear"
  [ ! -s "$dir/runtime.log" ] || fail "metadata-lock refusal contacted the runtime"
  pass "fm-codex-effort: serializes with lifecycle actions and metadata writers"
}

test_busy_and_ambiguous_runtime_states_refuse() {
  local dir before out rc
  dir=$(make_case busy-agent)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(FM_FAKE_AGENT_STATUS=working run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "busy native agent state was accepted"
  assert_contains "$out" "not idle" "busy native-state refusal was unclear"
  assert_no_grep "pane send-text" "$dir/runtime.log" "busy agent received effort input"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "busy refusal changed metadata"

  dir=$(make_case ambiguous-agent)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(FM_FAKE_AGENT_STATUS=mystery run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "ambiguous agent state was accepted"
  assert_contains "$out" "unreadable" "ambiguous endpoint refusal was unclear"
  assert_no_grep "pane send-text" "$dir/runtime.log" "ambiguous endpoint received effort input"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "ambiguous refusal changed metadata"

  dir=$(make_case dead-endpoint)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(FM_FAKE_PANE_STATE=missing run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "dead endpoint was accepted"
  assert_contains "$out" "missing" "dead endpoint refusal was unclear"
  assert_no_grep "pane send-text" "$dir/runtime.log" "dead endpoint received effort input"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "dead endpoint refusal changed metadata"

  dir=$(make_case busy-footer)
  out=$(FM_FAKE_UI=busy run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "busy Codex footer was accepted"
  assert_contains "$out" "busy Codex turn" "busy footer refusal was unclear"
  assert_no_grep "pane send-text" "$dir/runtime.log" "busy footer received effort input"
  pass "fm-codex-effort: refuses busy, ambiguous, and dead live states"
}

test_swallowed_input_and_changed_ui_never_report_success() {
  local dir before out rc
  dir=$(make_case swallowed)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(FM_FAKE_SWALLOW=1 FM_FAKE_UI=misleading run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "swallowed input with misleading transcript reported success"
  assert_contains "$out" "did not confirm" "swallowed-input refusal was unclear"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "swallowed input changed metadata"

  dir=$(make_case changed-ui)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(FM_FAKE_CHANGE_UI_AFTER_SEND=1 run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "changed UI reported false success"
  assert_contains "$out" "did not confirm" "changed-UI refusal was unclear"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "changed UI changed metadata"
  pass "fm-codex-effort: reports no false success when input is swallowed or the UI changes"
}

test_footer_requires_the_current_bottom_status_row() {
  local dir before out rc
  dir=$(make_case scrollback-footer)
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(FM_FAKE_UI=scrollback-only run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "footer-shaped scrollback was accepted as the current status row"
  assert_contains "$out" "no verifiable Codex model/effort footer" "scrollback-only footer refusal was unclear"
  assert_no_grep "pane send-text" "$dir/runtime.log" "scrollback-only footer delivered an effort chord"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "scrollback-only footer changed metadata"
  pass "fm-codex-effort: requires a structurally current footer instead of transcript prose"
}

test_captured_real_codex_0147_footers_bind_the_recorded_worktree() {
  local dir fixture out expected_worktree before rc
  expected_worktree=/home/pranay/.treehouse/firstmate-7e2c14/5/firstmate
  for fixture in "$FIXTURE_ROOT/codex-0.147-absolute-footer.txt" \
    "$FIXTURE_ROOT/codex-0.147-home-abbreviated-footer.txt"; do
    dir=$(make_case "captured-$(basename "$fixture" .txt)")
    sed -i "s|^worktree=.*$|worktree=$expected_worktree|" "$dir/home/state/effort-task.meta"
    out=$(HOME=/home/pranay FM_FAKE_WORKTREE="$expected_worktree" \
      FM_FAKE_FOOTER_FIXTURE="$fixture" run_case "$dir" medium) \
      || fail "captured Codex 0.147 footer was rejected: $(cat "$fixture")"
    [ "$(cat "$dir/effort")" = medium ] \
      || fail "captured Codex 0.147 footer did not confirm the live effort"
  done

  dir=$(make_case captured-footer-wrong-worktree)
  sed -i 's|^worktree=.*$|worktree=/var/lib/not-pranay/firstmate|' "$dir/home/state/effort-task.meta"
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(HOME=/home/pranay FM_FAKE_WORKTREE=/var/lib/not-pranay/firstmate \
    FM_FAKE_FOOTER_FIXTURE="$FIXTURE_ROOT/codex-0.147-home-abbreviated-footer.txt" \
    run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a captured Codex footer for another worktree was accepted"
  assert_contains "$out" 'no verifiable Codex model/effort footer' \
    "wrong-worktree captured footer refusal was unclear"
  assert_no_grep 'increase|decrease' "$dir/runtime.log" \
    "wrong-worktree captured footer received an effort chord"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] \
    || fail "wrong-worktree captured footer changed metadata"
  pass "fm-codex-effort: accepts captured Codex 0.147 footers only when their displayed path binds the recorded worktree"
}

test_ordinary_send_serializes_with_effort_chords_and_forces_a_fresh_idle_check() {
  local dir send_pid effort_pid send_rc effort_rc waited=0
  dir=$(make_case ordinary-send-race)
  : > "$dir/agent-status"
  printf 'idle\n' > "$dir/agent-status"

  FM_FAKE_AGENT_STATUS_FILE="$dir/agent-status" \
  FM_FAKE_BLOCK_ORDINARY_SEND=1 \
  FM_FAKE_SEND_ENTERED="$dir/send-entered" \
  FM_FAKE_ALLOW_SEND="$dir/allow-send" \
  FM_FAKE_SENT_TEXT="$dir/sent-text" \
    run_send_case "$dir" 'ordinary steer' >"$dir/send.out" 2>"$dir/send.err" &
  send_pid=$!
  while [ ! -e "$dir/send-entered" ] && [ "$waited" -lt 100 ]; do
    sleep 0.02
    waited=$((waited + 1))
  done
  if [ ! -e "$dir/send-entered" ]; then
    : > "$dir/allow-send"
    wait "$send_pid" || true
    fail "ordinary send did not reach its deterministic in-flight point"
  fi

  FM_FAKE_AGENT_STATUS_FILE="$dir/agent-status" \
  FM_FAKE_BLOCK_ORDINARY_SEND=1 \
  FM_FAKE_SEND_ENTERED="$dir/send-entered" \
  FM_FAKE_ALLOW_SEND="$dir/allow-send" \
  FM_FAKE_SENT_TEXT="$dir/sent-text" \
    run_case "$dir" medium >"$dir/effort.out" 2>"$dir/effort.err" &
  effort_pid=$!
  waited=0
  while ! grep -Eq 'increase|decrease' "$dir/runtime.log" && [ "$waited" -lt 100 ]; do
    sleep 0.02
    waited=$((waited + 1))
  done
  if grep -Eq 'increase|decrease' "$dir/runtime.log"; then
    : > "$dir/allow-send"
    wait "$send_pid" || true
    wait "$effort_pid" || true
    fail "effort chord landed while ordinary send held the endpoint input transaction"
  fi

  : > "$dir/allow-send"
  send_rc=0; wait "$send_pid" || send_rc=$?
  effort_rc=0; wait "$effort_pid" || effort_rc=$?
  expect_code 0 "$send_rc" "ordinary send should complete before the effort helper retries its idle check"
  [ "$effort_rc" -ne 0 ] || fail "effort helper accepted an endpoint made busy by the serialized ordinary send"
  assert_contains "$(cat "$dir/effort.err")" "not idle" \
    "effort helper did not recheck native semantic idle while it held the input lock"
  assert_no_grep 'increase|decrease' "$dir/runtime.log" \
    "effort helper delivered a chord after the serialized send began a turn"
  assert_grep 'ordinary steer' "$dir/sent-text" "ordinary send did not deliver its own text"
  pass "fm-codex-effort: ordinary fm-send input serializes with chords and receives a fresh semantic idle check"
}

test_key_send_serializes_with_effort_chords_and_forces_a_fresh_idle_check() {
  local dir key_pid effort_pid key_rc effort_rc waited=0
  dir=$(make_case key-send-race)
  printf 'idle\n' > "$dir/agent-status"

  FM_FAKE_AGENT_STATUS_FILE="$dir/agent-status" \
  FM_FAKE_BLOCK_KEY_SEND=1 \
  FM_FAKE_KEY_ENTERED="$dir/key-entered" \
  FM_FAKE_ALLOW_KEY="$dir/allow-key" \
    run_key_send_case "$dir" Enter >"$dir/key.out" 2>"$dir/key.err" &
  key_pid=$!
  while [ ! -e "$dir/key-entered" ] && [ "$waited" -lt 100 ]; do
    sleep 0.02
    waited=$((waited + 1))
  done
  if [ ! -e "$dir/key-entered" ]; then
    : > "$dir/allow-key"
    wait "$key_pid" || true
    fail "key send did not reach its deterministic in-flight point"
  fi

  FM_FAKE_AGENT_STATUS_FILE="$dir/agent-status" \
  FM_FAKE_BLOCK_KEY_SEND=1 \
  FM_FAKE_KEY_ENTERED="$dir/key-entered" \
  FM_FAKE_ALLOW_KEY="$dir/allow-key" \
    run_case "$dir" medium >"$dir/effort.out" 2>"$dir/effort.err" &
  effort_pid=$!
  waited=0
  while ! grep -Eq 'increase|decrease' "$dir/runtime.log" && [ "$waited" -lt 100 ]; do
    sleep 0.02
    waited=$((waited + 1))
  done
  if grep -Eq 'increase|decrease' "$dir/runtime.log"; then
    : > "$dir/allow-key"
    wait "$key_pid" || true
    wait "$effort_pid" || true
    fail "effort chord landed while key input held the endpoint input transaction"
  fi

  : > "$dir/allow-key"
  key_rc=0; wait "$key_pid" || key_rc=$?
  effort_rc=0; wait "$effort_pid" || effort_rc=$?
  expect_code 0 "$key_rc" "key send should complete before the effort helper retries its idle check"
  assert_grep 'pane send-keys w1:p1 enter' "$dir/runtime.log" \
    "serialized key send did not deliver its recorded Enter input"
  [ "$effort_rc" -ne 0 ] || fail "effort helper accepted an endpoint made busy by the serialized key send"
  assert_contains "$(cat "$dir/effort.err")" "not idle" \
    "effort helper did not recheck native semantic idle after a serialized key send"
  assert_no_grep 'increase|decrease' "$dir/runtime.log" \
    "effort helper delivered a chord after the serialized key send began a turn"
  pass "fm-codex-effort: recorded fm-send --key input serializes with chords and receives a fresh semantic idle check"
}

test_post_send_failures_leave_a_durable_recoverable_record() {
  local dir before out rc
  dir=$(make_case recover-multi-step)
  printf 'low\n' > "$dir/effort"
  sed -i 's/^effort=high$/effort=low/' "$dir/home/state/effort-task.meta"
  before=$(cksum < "$dir/home/state/effort-task.meta")
  out=$(FM_FAKE_CHANGE_UI_AFTER_SEND=1 run_case "$dir" high 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "unreadable UI after the first multi-step input was accepted"
  [ "$(cat "$dir/effort")" = medium ] || fail "first multi-step effort transition was not delivered"
  [ "$(cksum < "$dir/home/state/effort-task.meta")" = "$before" ] || fail "failed multi-step switch changed metadata"
  assert_present "$dir/home/state/effort-task.codex-effort-recovery" "post-send failure left no durable recovery record"
  rm -f "$dir/changed-ui"
  out=$(run_case "$dir" high) || fail "retry did not reconcile and complete a partially delivered multi-step switch: $out"
  [ "$(cat "$dir/effort")" = high ] || fail "retry did not reach the requested multi-step effort"
  [ "$(grep '^effort=' "$dir/home/state/effort-task.meta")" = effort=high ] || fail "retry did not reconcile metadata to the live effort"
  [ ! -e "$dir/home/state/effort-task.codex-effort-recovery" ] || fail "successful retry retained the recovery record"

  dir=$(make_case recover-signal)
  out=$(FM_FAKE_TERM_AFTER_SEND=1 run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted effort switch reported success"
  [ "$(cat "$dir/effort")" = medium ] || fail "signal fixture did not deliver the live effort transition"
  [ "$(grep '^effort=' "$dir/home/state/effort-task.meta")" = effort=high ] || fail "interrupted switch updated metadata before recovery"
  assert_present "$dir/home/state/effort-task.codex-effort-recovery" "signal interruption left no durable recovery record"
  out=$(run_case "$dir" medium) || fail "retry did not reconcile a signal-interrupted effort switch: $out"
  [ "$(grep '^effort=' "$dir/home/state/effort-task.meta")" = effort=medium ] || fail "signal retry did not reconcile metadata"
  [ ! -e "$dir/home/state/effort-task.codex-effort-recovery" ] || fail "signal retry retained the recovery record"

  dir=$(make_case recover-meta-write)
  out=$(FM_FAKE_FAIL_META_MV=1 run_case "$dir" medium 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "metadata-write failure reported success"
  [ "$(cat "$dir/effort")" = medium ] || fail "metadata-write fixture did not deliver the live effort transition"
  [ "$(grep '^effort=' "$dir/home/state/effort-task.meta")" = effort=high ] || fail "metadata-write failure changed metadata"
  assert_present "$dir/home/state/effort-task.codex-effort-recovery" "metadata-write failure left no recovery record"
  out=$(run_case "$dir" medium) || fail "retry did not reconcile metadata-write failure: $out"
  [ "$(grep '^effort=' "$dir/home/state/effort-task.meta")" = effort=medium ] || fail "metadata-write retry did not reconcile metadata"
  [ ! -e "$dir/home/state/effort-task.codex-effort-recovery" ] || fail "metadata-write retry retained the recovery record"
  pass "fm-codex-effort: durably recovers post-send multi-step, signal, and metadata-write failures"
}

test_unverified_backends_refuse_before_input() {
  local backend dir out rc
  for backend in zellij orca cmux; do
    dir=$(make_case "unsupported-$backend" "$backend")
    out=$(run_case "$dir" medium 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$backend was accepted without a verified effort-switch path"
    assert_contains "$out" "no verified in-session" "$backend refusal was unclear"
    [ ! -s "$dir/runtime.log" ] || fail "$backend refusal contacted a runtime"
  done
  pass "fm-codex-effort: refuses runtime backends without verified identity and input evidence"
}

test_success_changes_effort_in_place_and_then_metadata
test_tmux_refuses_without_a_verified_semantic_idle_source
test_invalid_effort_and_wrong_harness_refuse_without_runtime_input
test_task_id_uses_current_creation_contract
test_lifecycle_and_metadata_locks_refuse_before_runtime_input
test_busy_and_ambiguous_runtime_states_refuse
test_swallowed_input_and_changed_ui_never_report_success
test_footer_requires_the_current_bottom_status_row
test_captured_real_codex_0147_footers_bind_the_recorded_worktree
test_ordinary_send_serializes_with_effort_chords_and_forces_a_fresh_idle_check
test_key_send_serializes_with_effort_chords_and_forces_a_fresh_idle_check
test_post_send_failures_leave_a_durable_recoverable_record
test_unverified_backends_refuse_before_input
