#!/usr/bin/env bash
# Behavior tests for the omp (Oh My Pi) crewmate adapter: harness detection
# (env marker plus anchored ancestry), the session-log busy fold, the crew-only
# control contract, the spawn launch shape, and teardown cleanup of the busy
# binding.
#
# omp is a standalone Rust fork of Pi verified as a CREWMATE/SCOUT adapter only.
# Its busy source is its own append-only session JSONL, one object per line with
# a top-level "type". The turn boundary rides the "message" events: an assistant
# message with a terminal (non-toolUse) stopReason is a settled turn; a trailing
# user, toolResult, or assistant-toolUse message is a turn in flight. The
# fixtures below reproduce omp v18.0.0's real record shapes, including an
# adversarial user message whose escaped text contains the literal stopReason
# key - the whole reason the fold matches unescaped structural bytes rather than
# searching for "stopReason" anywhere on the line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm-harness.sh checks verified ENV markers before ancestry. Drop the ambient
# markers so a marker inherited from whichever harness launched the suite cannot
# outrank the omp verdict these cases exist to pin.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS OMPCODE

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)

# --- session-log fixtures ---------------------------------------------------
# One omp session-log line per record type. The message object always opens with
# "role" and an assistant turn carries "stopReason" as a sibling of content.

omp_msg_user() {
  printf '{"type":"message","id":"u","timestamp":"t","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}\n'
}
omp_msg_assistant_tooluse() {
  printf '{"type":"message","id":"a","timestamp":"t","message":{"role":"assistant","content":[{"type":"thinking"},{"type":"toolCall"}],"stopReason":"toolUse"}}\n'
}
omp_msg_toolresult() {
  printf '{"type":"message","id":"r","timestamp":"t","message":{"role":"toolResult","content":[{"type":"text","text":"tick"}]}}\n'
}
omp_msg_assistant_terminal() {  # <stopReason>
  printf '{"type":"message","id":"z","timestamp":"t","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stopReason":"%s"}}\n' "$1"
}
omp_noise() {
  printf '{"type":"session","version":1,"id":"s","timestamp":"t","cwd":"/x"}\n'
  printf '{"type":"model_change","id":"m","timestamp":"t","model":"opencode-go/deepseek-v4-flash"}\n'
  printf '{"type":"custom","id":"c","customType":"tool_effect","data":{}}\n'
  printf '{"type":"title_change","id":"tc","timestamp":"t","title":"a task"}\n'
}

run_state() {  # <log>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_omp_run_state "$1"
  )
}

classify_omp() {  # <state-dir> <id>
  (
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_classify tmux fake:0 omp "$2" "$1"
  )
}

# --- detection --------------------------------------------------------------

# omp sets OMPCODE=1 on its child/tool processes. The marker layer checks it
# BEFORE claude and Pi, so an inherited CLAUDECODE or PI_CODING_AGENT (which a
# hand-started omp under another primary does not clear) cannot outrank it.
test_env_marker_detects_omp() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS OMPCODE=1 "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE=1 detected as '$out', expected omp"
  # Even with a foreign marker retained, omp's own marker must win.
  out=$(OMPCODE=1 CLAUDECODE=1 PI_CODING_AGENT=true "$HARNESS")
  [ "$out" = omp ] || fail "OMPCODE with foreign markers detected as '$out', expected omp (no collision)"
  pass "OMPCODE=1 identifies omp and outranks inherited claude/pi markers"
}

# The omp binary keeps the exact process name `omp` (no versioned exec), so
# ancestry detection matches the bare name when no marker is present.
test_ancestry_detects_omp() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  ln -s "$(command -v bash)" "$dir/omp"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u OMPCODE \
    "$dir/omp" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = omp ] || fail "fm-harness.sh under process 'omp' reported '$out', expected omp"
  pass "omp is detected through its bare process-name ancestor"
}

# The match is anchored: a command whose name merely CONTAINS omp is a different
# program and must not be claimed by this adapter.
test_detection_is_anchored() {
  local dir bin out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in comp romp chomp ompule notomp; do
    ln -s "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u OMPCODE \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != omp ] || fail "fm-harness.sh misdetected unrelated process '$bin' as omp"
  done
  pass "omp detection does not claim unrelated omp-containing commands"
}

# --- busy fold --------------------------------------------------------------

test_fold_reads_busy_for_in_flight_turns() {
  local dir
  dir="$TMP_ROOT/fold-busy"
  mkdir -p "$dir"
  # last message = user submit
  { omp_noise; omp_msg_user; } > "$dir/user.jsonl"
  [ "$(run_state "$dir/user.jsonl")" = busy ] || fail "a trailing user message did not read busy"
  # last message = assistant awaiting a tool loop
  { omp_msg_user; omp_msg_assistant_tooluse; } > "$dir/tooluse.jsonl"
  [ "$(run_state "$dir/tooluse.jsonl")" = busy ] || fail "a trailing assistant toolUse did not read busy"
  # last message = tool result, model not yet resumed
  { omp_msg_assistant_tooluse; omp_msg_toolresult; } > "$dir/toolresult.jsonl"
  [ "$(run_state "$dir/toolresult.jsonl")" = busy ] || fail "a trailing toolResult did not read busy"
  pass "an in-flight turn (user, toolUse, or toolResult tail) reads busy"
}

# The assistant message is written on turn completion, and BOTH a normal stop and
# an interrupt-driven abort are terminal, so the fold covers the manual interrupt
# path the same way muse and cursor do and Claude's Stop hook does not.
test_fold_reads_settled_for_terminal_stopreasons() {
  local dir reason
  dir="$TMP_ROOT/fold-idle"
  mkdir -p "$dir"
  for reason in stop aborted error; do
    { omp_msg_user; omp_msg_assistant_terminal "$reason"; } > "$dir/$reason.jsonl"
    [ "$(run_state "$dir/$reason.jsonl")" = settled ] \
      || fail "a turn settled by stopReason '$reason' did not read settled"
  done
  pass "an assistant message with a terminal stopReason (incl. aborted) reads settled"
}

test_fold_reads_none_without_message_events() {
  local dir
  dir="$TMP_ROOT/fold-none"
  mkdir -p "$dir"
  omp_noise > "$dir/none.jsonl"
  [ "$(run_state "$dir/none.jsonl")" = none ] || fail "a log with no message events did not read none"
  pass "a message-free session log reads none, never settled"
}

# The adversarial line: a USER message whose text contains the escaped literal
# \"stopReason\":\"stop\". The escaped quotes are not the unescaped structural
# key, and the role is user, so the fold must read busy - not be tricked into
# settled by a string inside content.
test_fold_is_not_fooled_by_escaped_stopreason_in_text() {
  local dir
  dir="$TMP_ROOT/fold-adv"
  mkdir -p "$dir"
  printf '{"type":"message","id":"u","message":{"role":"user","content":[{"type":"text","text":"set \\"stopReason\\":\\"stop\\" please"}]}}\n' > "$dir/adv.jsonl"
  [ "$(run_state "$dir/adv.jsonl")" = busy ] \
    || fail "an escaped stopReason inside user text fooled the fold into settled"
  pass "the fold matches structural bytes, not stopReason text inside a message"
}

# --- binding + classify -----------------------------------------------------

# The binding is by construction: the session dir is state/<id>.omp-sessions and
# the newest jsonl there is the live incarnation. omp names logs by ISO
# timestamp, which sorts chronologically, so a relaunch's newer log wins.
test_session_log_selects_newest_incarnation() {
  local state id dir log
  state="$TMP_ROOT/bind/state"
  id=omp-bind-x1
  dir="$state/$id.omp-sessions"
  mkdir -p "$dir"
  { omp_msg_user; omp_msg_assistant_terminal stop; } > "$dir/2026-08-22T10-00-00-000Z_old.jsonl"
  omp_msg_user > "$dir/2026-08-22T11-00-00-000Z_new.jsonl"
  log=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_omp_session_log "$state" "$id"
  )
  case "$log" in
    *2026-08-22T11-00-00-000Z_new.jsonl) : ;;
    *) fail "session_log picked '$log', expected the newest incarnation" ;;
  esac
  # The newest log is a fresh user turn, so the task classifies busy.
  [ "$(classify_omp "$state" "$id")" = "busy omp-session-log" ] \
    || fail "classify did not fold the newest incarnation as busy"
  pass "the newest session log is the live incarnation and drives classification"
}

test_classify_idle_and_unknown() {
  local state id dir
  state="$TMP_ROOT/classify/state"
  id=omp-classify-x1
  dir="$state/$id.omp-sessions"
  mkdir -p "$dir"
  { omp_msg_user; omp_msg_assistant_terminal stop; } > "$dir/2026-08-22T12-00-00-000Z_s.jsonl"
  [ "$(classify_omp "$state" "$id")" = "idle omp-session-log" ] \
    || fail "a settled session did not classify idle"
  # No session directory yet (or empty) is unknown, never idle.
  [ "$(classify_omp "$state" omp-missing)" = "unknown omp-session-log" ] \
    || fail "a missing session directory did not classify unknown"
  pass "a settled log reads idle and a missing binding reads unknown, never a false idle"
}

# omp records no busy events (no armed writer), so it must trust no record
# source: a trusted source with no writer would seed a busy record nothing could
# ever settle.
test_omp_trusts_no_record_sources() {
  local out
  out=$(
    # shellcheck source=bin/fm-busy-lib.sh
    . "$ROOT/bin/fm-busy-lib.sh"
    fm_busy_sources_for_harness omp
  )
  [ -z "$out" ] || fail "omp trusts record sources it has no writer for: '$out'"
  pass "omp trusts no busy record source"
}

# --- delivery busy signature ------------------------------------------------

# The composer is a compact 2-row box whose input rides on the bottom border,
# so the shared structural classifier reads it `unknown`; a steer is instead
# acknowledged by the idle-to-busy transition through fm_busy_lines_match. These
# fixtures are omp v18.0.0's REAL captured rows: mid-turn it renders a rotating
# braille spinner beside `Working…` (a UNICODE ellipsis, not Pi's ASCII dots)
# and an `⟦esc⟧` cancel hint; idle it shows only the box, whose top border can
# carry a session TITLE. The regex must fire mid-turn and stay silent when idle,
# including on the title, or every omp steer would report delivery unconfirmed.
test_delivery_busy_signature() {
  local busy idle
  busy=$' Count to 60 slowly, one number per line\n ⠇ Working… ⟦esc⟧\n╭── π  > ⬢ Opus 4.6 · ◒ high > (sub) ▶──12%──┃──250K──╮\n╰─                                            ─╯'
  idle=$' 59\n 60\n╭── π  > ⬢ Opus 4.6 · ◒ high > S0.21 ▶──13%──┃──250K─◀ Count slowly from 1 to 20 ──╮\n╰─                                            ─╯'
  (
    # shellcheck source=bin/fm-composer-lib.sh
    . "$ROOT/bin/fm-composer-lib.sh"
    printf '%s' "$busy" | fm_busy_lines_match omp \
      || fail "omp busy render (Working… / ⟦esc⟧) did not match the delivery busy regex"
    ! printf '%s' "$idle" | fm_busy_lines_match omp \
      || fail "omp idle render (incl. a session title) falsely matched the delivery busy regex"
    # The rotating braille spinner glyph itself must NOT be load-bearing: a busy
    # tail carrying the label but a different frame still matches.
    printf '%s' "$busy" | fm_busy_lines_match omp \
      || fail "omp busy match depended on a specific spinner frame"
  ) || exit 1
  pass "omp delivery busy signature matches mid-turn and stays silent when idle"
}

# --- control contract -------------------------------------------------------

test_control_contract() {
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  fm_control_harness_supported omp || fail "omp is not a supported control harness"
  [ "$(fm_control_harness_family omp)" = omp ] || fail "omp family did not resolve to omp"
  fm_control_harness_supports_kind omp ship || fail "omp should support ship"
  fm_control_harness_supports_kind omp scout || fail "omp should support scout"
  ! fm_control_harness_supports_kind omp secondmate || fail "omp must NOT support secondmate"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key should be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp should interrupt on a single press"
  # omp's composer returns empty after Escape, so it needs NO clear key.
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp should need no composer clear key"
  [ "$(fm_control_exit_command omp)" = /exit ] || fail "omp exit command should be /exit"
  pass "omp control contract: Escape interrupt, no clear, /exit, crew-only"
}

# --- spawn ------------------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  ln -s "$(command -v bash)" "$fakebin/omp"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="omp-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_omp_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" omp "$@" 2>&1
}

test_spawn_launch_shape() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "omp spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "omp spawn did not report success"
  launch=$(cat "$home/launch.log")
  # Autonomy: without --approval-mode yolo omp holds every tool call for approval.
  assert_contains "$launch" '--approval-mode yolo' "omp launch omitted --approval-mode yolo"
  # The busy binding: omp writes its session jsonl into this per-task directory.
  assert_contains "$launch" "--session-dir '$home/state/$id.omp-sessions'" \
    "omp launch did not point --session-dir at the per-task session directory"
  # Foreign markers stripped so a stored CLAUDECODE/Pi marker cannot outrank OMPCODE.
  assert_contains "$launch" 'env -u CLAUDECODE -u PI_CODING_AGENT' \
    "omp launch did not strip foreign primary markers"
  assert_contains "$launch" 'encode launch-brief' "omp launch did not deliver the brief positionally"
  assert_grep 'harness=omp' "$home/state/$id.meta" "omp harness was not recorded in meta"
  # The session directory is created at spawn.
  assert_present "$home/state/$id.omp-sessions" "omp spawn did not create the session directory"
  pass "omp spawn launches with autonomy, the session-dir binding, and a positional brief"
}

test_spawn_maps_effort_and_model() {
  local rec case_dir home proj wt fakebin id launch entry effort expect
  local -a cases=(
    "low|--thinking 'low'"
    "high|--thinking 'high'"
    "xhigh|--thinking 'xhigh'"
    "max|--thinking 'max'"
  )
  for entry in "${cases[@]}"; do
    effort=${entry%%|*}
    expect=${entry#*|}
    rec=$(make_spawn_case "effort-$effort")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
    run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
      --mode no-mistakes --yolo off --model opencode-go/deepseek-v4-flash --effort "$effort" >/dev/null \
      || fail "omp spawn with effort $effort failed"
    launch=$(cat "$home/launch.log")
    assert_contains "$launch" "$expect" "omp effort $effort did not map to '$expect'"
    assert_contains "$launch" "--model 'opencode-go/deepseek-v4-flash'" "omp spawn dropped the model axis"
  done
  # No effort chosen leaves omp on its own default; firstmate invents none.
  rec=$(make_spawn_case effort-default)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "omp spawn without an effort axis failed"
  assert_not_contains "$(cat "$home/launch.log")" '--thinking' "omp spawn invented an effort when none was chosen"
  pass "omp maps the shared effort vocabulary through --thinking and invents none by default"
}

test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="omp-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" omp --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "omp was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" "omp secondmate refusal did not explain the boundary"
  pass "omp is refused as a secondmate harness"
}

test_teardown_removes_session_dir() {
  local rec case_dir home proj wt fakebin id dir
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_omp_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "omp spawn failed"
  dir="$home/state/$id.omp-sessions"
  assert_present "$dir" "omp spawn did not create the session directory"
  # Drop a session log inside so the removal is a non-empty directory.
  omp_msg_user > "$dir/2026-08-22T13-00-00-000Z_x.jsonl"
  # No busy record is armed for omp: the source is pull-only.
  assert_absent "$home/state/$id.busy-gen" "omp spawn armed a busy record it can never clear"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "omp teardown failed"
  assert_absent "$dir" "omp session directory survived teardown"
  pass "omp spawn creates a session directory that teardown removes"
}

test_env_marker_detects_omp
test_ancestry_detects_omp
test_detection_is_anchored
test_fold_reads_busy_for_in_flight_turns
test_fold_reads_settled_for_terminal_stopreasons
test_fold_reads_none_without_message_events
test_fold_is_not_fooled_by_escaped_stopreason_in_text
test_session_log_selects_newest_incarnation
test_classify_idle_and_unknown
test_omp_trusts_no_record_sources
test_delivery_busy_signature
test_control_contract
test_spawn_launch_shape
test_spawn_maps_effort_and_model
test_spawn_refuses_secondmate
test_teardown_removes_session_dir
