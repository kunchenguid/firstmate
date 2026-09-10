#!/usr/bin/env bash
# Behavior tests for the verified Rovo CLI crewmate/scout adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor, Claude, Pi, or Grok inherits those markers, which outrank
# the fake ancestry the detection cases set up. Drop the ambient markers so the
# asserted verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-rovo-harness)

# A stateful fake tmux for rovo's launch-then-send shape (the same shape kimi
# uses): a positional brief is dead-on-arrival, so rovo launches BARE and only
# receives an absolute brief pointer after a readiness gate, then a delivery
# gate. This fake renders a rovo-shaped screen that advances through
# launched -> ready -> pointer-typed -> delivered as the real spawn drives it, so
# the launch command, the typed pointer, and both gates are exercised through
# their real code paths rather than asserted from static text.
make_rovo_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_ROVO_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Welcome to Rovo!\nContext: | 0.0%% 0/922K\n? for shortcuts.\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
      ;;
    pointer-typed)
      printf 'Context: | 0.0%% 0/922K\n╭────────────────────────────────╮\n│ > Read the brief and follow it │\n│                                │\n╰────────────────────────────────╯\n'
      ;;
    delivered)
      printf 'Read the brief at %s and follow it exactly.\nContext: | 3.3%% 30.1K/922K\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_cursor_y() {
  case "$state" in
    pointer-typed) printf '4\n' ;;
    ready|delivered) printf '4\n' ;;
    *) printf '1\n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) fake_cursor_y; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *'run --yolo'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_ROVO_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_ROVO_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_ROVO_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_ROVO_STATE"
            fi
            ;;
          pointer-typed)
            if [ "${FM_FAKE_ROVO_DELIVERY:-yes}" = yes ]; then
              printf 'delivered\n' > "$FM_FAKE_ROVO_STATE"
            else
              printf 'ready\n' > "$FM_FAKE_ROVO_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  fm_fake_exit0 "$fakebin" rovo
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_rovo_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Rovo dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'rovo\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/rovo.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_ROVO_STATE="$case_dir/rovo.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_FAKE_ROVO_READY="${FM_FAKE_ROVO_READY:-yes}" \
    FM_FAKE_ROVO_DELIVERY="${FM_FAKE_ROVO_DELIVERY:-yes}" \
    FM_ROVO_READY_POLLS=3 FM_ROVO_DELIVERY_POLLS=3 FM_ROVO_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness rovo --mode no-mistakes --yolo off "$@" 2>&1
}

test_rovo_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta data_real state_real
  id="rovo-success-z1-$$"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto --effort high)
  rc=$?
  expect_code 0 "$rc" "verified rovo launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=rovo" "rovo spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/rovo' run --yolo" \
    "rovo launch did not use the resolved binary with the bare launch-then-send shape"
  assert_not_contains "$launch" "--startup-receipt" "rovo launch used the incompatible --startup-receipt flag"
  assert_not_contains "$launch" "encode launch-brief" "rovo launch carried a positional brief instead of launching bare"
  assert_not_contains "$launch" "brief for rovo" "rovo launch embedded the brief body as a positional argument"
  assert_contains "$launch" "--model 'auto'" "rovo launch omitted the requested model"
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "rovo launch did not clear foreign primary markers"
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "rovo launch did not clear cursor's markers via the shared outer wrap"
  assert_not_contains "$launch" "turn-ended" "rovo launch embedded a turn-end path it does not own"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/launch-brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "rovo pointer was not the exact absolute-path-only instruction: $pointer"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=auto' "$meta" "rovo meta lost the requested model"
  assert_grep 'effort=high' "$meta" "rovo meta lost the requested effort"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful rovo spawn must never tear down the endpoint it just delivered into"

  # rovo confines every file-tool operation to its worktree by default
  # (confirmed live), so the launch must grant allowedExternalPaths covering
  # this task's brief directory, steering inbox, and status file - otherwise
  # the standard instructions/steering/status/report loop cannot work.
  data_real=$(cd "$HOME_DIR/data/$id" && pwd -P)
  state_real=$(cd "$HOME_DIR/state" && pwd -P)
  assert_contains "$launch" "allowedExternalPaths" \
    "rovo launch did not grant allowedExternalPaths for this task's home paths"
  assert_contains "$launch" "$data_real" \
    "rovo launch's allowedExternalPaths grant omitted the brief directory"
  assert_contains "$launch" "$state_real/$id.inbox" \
    "rovo launch's allowedExternalPaths grant omitted the steering inbox directory"
  assert_contains "$launch" "$state_real/$id.status" \
    "rovo launch's allowedExternalPaths grant omitted the status file"
  pass "fm-spawn: rovo launches bare, waits for readiness, and delivers its brief pointer"
}

test_rovo_effort_xhigh_is_recorded_but_omitted() {
  local id rec out rc launch meta
  id="rovo-xhigh-z2-$$"
  rec=$(make_spawn_case xhigh "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "rovo spawn with an unsupported effort should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "efficiencyLevel" "rovo launch set agent.efficiencyLevel for an unsupported effort value"
  # --config-override still carries the mandatory allowedExternalPaths grant
  # even when the requested effort is unsupported and omitted: the two ride
  # one merged JSON object because rovo's --config-override is single-value
  # (a second occurrence silently discards the first, confirmed live).
  assert_contains "$launch" "allowedExternalPaths" "rovo launch dropped its allowedExternalPaths grant when effort was unsupported"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "rovo meta did not retain the unsupported effort axis"
  pass "fm-spawn: rovo omits efficiencyLevel for xhigh but keeps its allowedExternalPaths grant, recording xhigh in task metadata"
}

test_rovo_effort_high_sets_config_override() {
  local id rec out rc launch override_count
  id="rovo-effort-z6-$$"
  rec=$(make_spawn_case effort-high "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort high)
  rc=$?
  expect_code 0 "$rc" "rovo spawn with a supported effort should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" 'efficiencyLevel' "rovo launch did not set agent.efficiencyLevel via --config-override"
  assert_contains "$launch" '"high"' "rovo launch did not carry the requested efficiency level"
  # Exactly one --config-override: rovo silently discards a second occurrence
  # (confirmed live), so efficiencyLevel and the allowedExternalPaths grant
  # must ride the same merged JSON object rather than two flags.
  override_count=$(printf '%s' "$launch" | grep -o -- '--config-override' | wc -l | tr -d ' ')
  [ "$override_count" = 1 ] \
    || fail "rovo launch emitted $override_count --config-override occurrences; a second one would silently discard the first"
  assert_contains "$launch" 'allowedExternalPaths' "rovo launch's single --config-override dropped the allowedExternalPaths grant when merging in efficiencyLevel"
  pass "fm-spawn: rovo's supported effort values merge into the same --config-override as its allowedExternalPaths grant"
}

test_rovo_readiness_gate_precedes_pointer() {
  local id rec out rc
  id="rovo-not-ready-z3-$$"
  rec=$(make_spawn_case not-ready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_ROVO_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "rovo spawn without a ready signal should fail"
  assert_contains "$out" "rovo did not show a verified ready signal" \
    "rovo readiness failure lacked a loud diagnostic"
  assert_grep 'failed: rovo did not show a verified ready signal' "$HOME_DIR/state/$id.status" \
    "rovo readiness failure did not leave a supervisor-visible failure"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "rovo pointer was sent before an observable ready signal"
  grep -q "kill-window.*fm-$id" "$CASE_DIR/tmux-calls.log" \
    || fail "a failed rovo readiness gate must tear down the exact endpoint it created instead of leaking an orphaned --yolo process"
  pass "fm-spawn: rovo never sends the brief pointer before an observable ready signal, and tears down the created endpoint on failure"
}

test_rovo_unconfirmed_delivery_fails_loudly() {
  local id rec out rc pointer
  id="rovo-drop-z7-$$"
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_ROVO_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed rovo delivery should fail"
  # The pointer was typed (readiness passed) but its delivery never confirmed.
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ -n "$pointer" ] || fail "rovo never typed the pointer before the delivery gate"
  assert_contains "$out" "rovo brief pointer delivery was not confirmed" \
    "unconfirmed rovo delivery lacked a loud diagnostic"
  assert_grep 'failed: rovo brief pointer delivery was not confirmed' "$HOME_DIR/state/$id.status" \
    "unconfirmed rovo delivery did not leave a supervisor-visible failure"
  grep -q "kill-window.*fm-$id" "$CASE_DIR/tmux-calls.log" \
    || fail "an unconfirmed rovo delivery must tear down the exact endpoint it created instead of leaking an orphaned --yolo process"
  pass "fm-spawn: rovo treats a silent pointer drop as a failed spawn, and tears down the created endpoint"
}

test_rovo_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id="rovo-missing-z4-$$"
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm "$FAKEBIN_DIR/rovo"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing rovo executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'rovo'" "missing rovo diagnostic omitted PATH search"
  [ -s "$CASE_DIR/launch.log" ] && fail "missing rovo executable created a launch command" || true
  pass "fm-spawn: missing rovo executable refuses before pane creation"
}

test_rovo_secondmate_is_refused() {
  local id rec out rc
  id="rovo-secondmate-z5-$$"
  rec=$(make_spawn_case secondmate-refuse "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate rovo 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rovo secondmate spawn should be refused"
  assert_contains "$out" "rovo is a verified crewmate/scout adapter only" \
    "rovo secondmate refusal lacked its concrete reason"
  pass "fm-spawn: rovo cannot be launched as a secondmate"
}

test_rovo_detection_precedence_and_ancestry() {
  local dir fakebin cfg out
  dir="$TMP_ROOT/detection"
  fakebin=$(fm_fakebin "$dir")
  cfg="$dir/config"
  mkdir -p "$cfg"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
pid=
prev=
for arg in "$@"; do
  [ "$prev" = -o ] && field=$arg
  [ "$prev" = -p ] && pid=$arg
  prev=$arg
done
case "$field:$pid" in
  comm=:4242) printf 'rovo\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = rovo ] || fail "rovo ancestry detection returned '$out'"

  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    ATLASSIAN_AGENT_TYPE=rovo CLAUDECODE=1 \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = rovo ] || fail "rovo's ATLASSIAN_AGENT_TYPE marker did not outrank an inherited CLAUDECODE, got '$out'"

  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    ROVODEV_CLI=1 CLAUDECODE=1 \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = rovo ] || fail "rovo's ROVODEV_CLI marker did not outrank an inherited CLAUDECODE, got '$out'"

  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: rovo's markers outrank an inherited CLAUDECODE, and markerless ancestry still resolves rovo"
}

test_rovo_control_lib_table() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  [ "$(fm_control_interrupt_key rovo)" = Escape ] || fail "rovo interrupt key is not Escape"
  [ "$(fm_control_interrupt_repeat rovo)" = 1 ] || fail "rovo interrupt repeat is not 1"
  [ -z "$(fm_control_interrupt_clear_key rovo)" ] || fail "rovo should need no interrupt clear key"
  [ "$(fm_control_interrupt_ack_source rovo)" = none ] || fail "rovo interrupt ack source is not none"
  [ "$(fm_control_exit_command rovo)" = /exit ] || fail "rovo exit command is not /exit"
  [ "$(fm_control_harness_family rovo-anything)" = rovo ] || fail "rovo harness family prefix match failed"
  fm_control_harness_supports_kind rovo ship || fail "rovo should support ship tasks"
  fm_control_harness_supports_kind rovo scout || fail "rovo should support scout tasks"
  if fm_control_harness_supports_kind rovo secondmate; then
    fail "rovo should never support secondmate tasks"
  fi
  pass "fm-control-lib: rovo's lifecycle table matches its verified facts"
}

test_rovo_busy_regex_isolated() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  printf 'Enter to queue, Ctrl+Enter to steer\n⬢ Rovo is thinking...\n' | fm_busy_rovo_tail_busy \
    || fail "rovo's real busy line was not recognized as busy"
  printf 'Context: 5.3%% 48.7K/922K\n? for shortcuts.\n' | fm_busy_rovo_tail_busy \
    && fail "an idle rovo composer footer was misread as busy"
  printf 'Ctrl+c:cancel\n' | fm_busy_rovo_tail_busy \
    && fail "Grok's exact busy token leaked into rovo's harness-scoped matcher"
  printf 'Rovo is thinking\n' | fm_busy_grok_tail_busy \
    && fail "rovo's busy line leaked into Grok's harness-scoped matcher"

  local out
  out=$(fm_busy_classify tmux fake:0 rovo taskid /nonexistent-state '⬢ Rovo is thinking...')
  [ "$out" = "busy rovo-regex" ] || fail "fm_busy_classify did not read a real rovo busy tail as busy rovo-regex, got '$out'"
  # A tail with no busy marker at all is "can't tell," never definitive idle:
  # rovo's fallback is best-effort, so absence of the marker must not let
  # supervision conclude a still-working worker went idle.
  out=$(fm_busy_classify tmux fake:0 rovo taskid /nonexistent-state 'Context: 1% 2K/900K')
  [ "$out" = "unknown rovo-regex" ] || fail "fm_busy_classify misread a marker-absent rovo tail as definitive idle instead of unknown, got '$out'"
  pass "busy detection: rovo's rendered busy line classifies through its own isolated fallback"
}

test_rovo_busy_marker_scrolled_out_of_tail_is_unknown() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-busy-lib.sh"
  local tail40 out i
  # fm_busy_rovo_tail_busy only inspects the last 12 nonblank lines. Build a
  # captured tail where the busy marker is present but pushed out of that
  # window by a long active turn's own output, so a naive "marker absent"
  # check would misread this still-busy worker as idle.
  tail40='⬢ Rovo is thinking...'
  for i in $(seq 1 20); do
    tail40="$tail40
tool output line $i"
  done
  out=$(fm_busy_classify tmux fake:0 rovo taskid /nonexistent-state "$tail40")
  [ "$out" = "unknown rovo-regex" ] \
    || fail "an active rovo turn whose busy marker scrolled out of the tail must classify unknown, not idle; got '$out'"
  pass "busy detection: a rovo busy marker scrolled out of the tail classifies unknown, never idle"
}

test_rovo_launch_then_send_is_verified
test_rovo_effort_xhigh_is_recorded_but_omitted
test_rovo_effort_high_sets_config_override
test_rovo_readiness_gate_precedes_pointer
test_rovo_unconfirmed_delivery_fails_loudly
test_rovo_missing_binary_refuses_before_pane_creation
test_rovo_secondmate_is_refused
test_rovo_detection_precedence_and_ancestry
test_rovo_control_lib_table
test_rovo_busy_regex_isolated
test_rovo_busy_marker_scrolled_out_of_tail_is_unknown
