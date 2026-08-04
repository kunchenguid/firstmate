#!/usr/bin/env bash
# Behavior tests for the verified Hermes Agent crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
HERMES_RUNTIME_TASK_TMP=
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_hermes_harness() {
  [ -z "$HERMES_RUNTIME_TASK_TMP" ] || rm -rf "$HERMES_RUNTIME_TASK_TMP"
  rm -rf "$TMP_ROOT"
}
trap cleanup_hermes_harness EXIT

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_HERMES_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf 'Hermes Agent v0.19.0\nWelcome to Hermes\n❯\n'
      ;;
    pointer-typed)
      printf 'Hermes Agent v0.19.0\n❯ Read the brief and follow it\n'
      ;;
    delivered-idle)
      printf '✨ Read the brief at %s and follow it exactly.\n❯\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    delivered-busy)
      printf 'Read the brief at %s and follow it exactly.\nInitializing agent...\n⚕ ❯ msg=interrupt · /queue · Ctrl+C cancel\n' "$FM_FAKE_BRIEF_REAL"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_cursor_y() {
  case "$state" in
    pointer-typed) printf '1\n' ;;
    ready|delivered-idle|delivered-busy) printf '2\n' ;;
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
        *' chat --yolo --accept-hooks'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_HERMES_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_HERMES_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_HERMES_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_HERMES_STATE"
            fi
            ;;
          pointer-typed)
            if [ "${FM_FAKE_HERMES_DELIVERY:-yes}" = yes ]; then
              if [ "${FM_FAKE_HERMES_SWALLOW_FIRST:-no}" = yes ] \
                 && [ ! -f "$FM_FAKE_HERMES_SWALLOWED" ]; then
                : > "$FM_FAKE_HERMES_SWALLOWED"
              else
                printf '%s\n' "${FM_FAKE_HERMES_DELIVERED_STATE:-delivered-busy}" \
                  > "$FM_FAKE_HERMES_STATE"
              fi
            else
              printf 'ready\n' > "$FM_FAKE_HERMES_STATE"
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
  fm_fake_exit0 "$fakebin" hermes
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for hermes\n' > "$home/data/$id/brief.md"
  printf 'hermes\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/hermes.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_HERMES_STATE="$case_dir/hermes.state" \
    FM_FAKE_HERMES_SWALLOWED="$case_dir/hermes.swallowed" \
    FM_FAKE_HERMES_SWALLOW_FIRST="${FM_FAKE_HERMES_SWALLOW_FIRST:-no}" \
    FM_FAKE_HERMES_DELIVERED_STATE="${FM_FAKE_HERMES_DELIVERED_STATE:-delivered-busy}" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/brief.md" \
    FM_HERMES_READY_POLLS=2 FM_HERMES_DELIVERY_POLLS=2 FM_HERMES_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness hermes --mode no-mistakes --yolo off "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_hermes_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta task_tmp
  id="hermes-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  HERMES_RUNTIME_TASK_TMP=$task_tmp
  rm -rf "$task_tmp"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_HERMES_SWALLOW_FIRST=yes run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model grok-4.5 --effort high)
  rc=$?
  expect_code 0 "$rc" "verified hermes launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=hermes" "hermes spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "'$FAKEBIN_DIR/hermes' chat --yolo --accept-hooks -m 'grok-4.5' " ] \
    || fail "hermes launch did not use absolute binary, yolo, accept-hooks, and -m only: $launch"
  assert_not_contains "$launch" "--effort" "hermes launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "--tui" "hermes launch must not use broken --tui"
  assert_not_contains "$launch" "turn-ended" "hermes launch embedded a turn-end path"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "hermes pointer was not the exact absolute-path-only instruction: $pointer"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=grok-4.5' "$meta" "hermes meta lost the requested model"
  assert_grep 'effort=high' "$meta" "hermes meta did not retain the unsupported effort axis"
  assert_grep 'harness=hermes' "$meta" "hermes meta lost harness identity"
  assert_grep "tasktmp=$task_tmp" "$meta" "hermes meta did not record its task temp root"
  assert_present "$task_tmp/gotmp" "hermes spawn did not create its Go temp directory"
  pass "fm-spawn: hermes launches, delivers its brief, and records profile axes"
}

test_hermes_idle_delivery_is_accepted() {
  local id rec out rc
  id=hermes-idle-delivery-z2
  rec=$(make_spawn_case idle-delivery "$id")
  read_spawn_record "$rec"
  out=$(FM_FAKE_HERMES_DELIVERED_STATE=delivered-idle run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "hermes idle pointer echo should confirm delivery"
  assert_contains "$out" "spawned $id harness=hermes" "idle delivery spawn did not report success"
  pass "fm-spawn: hermes accepts idle composer plus visible pointer as delivery"
}

test_hermes_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id=hermes-missing-z3
  rec=$(make_spawn_case missing "$id")
  read_spawn_record "$rec"
  rm -f "$FAKEBIN_DIR/hermes" "$FAKEBIN_DIR/hermes-agent"
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing hermes executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'hermes'" "missing hermes diagnostic omitted PATH"
  assert_contains "$out" "hermes-agent" "missing hermes diagnostic omitted hermes-agent fallback"
  if grep -Eq '(^| )new-(session|window)( |$)' "$CASE_DIR/tmux-calls.log"; then
    fail "missing hermes executable created a tmux container or pane"
  fi
  pass "fm-spawn: missing hermes executable refuses before pane creation"
}

test_hermes_falls_back_to_hermes_agent_binary() {
  local id rec out rc launch
  id=hermes-agent-fallback-z4
  rec=$(make_spawn_case agent-fallback "$id")
  read_spawn_record "$rec"
  rm -f "$FAKEBIN_DIR/hermes"
  fm_fake_exit0 "$FAKEBIN_DIR" hermes-agent
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "hermes-agent PATH fallback spawn should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "'$FAKEBIN_DIR/hermes-agent' chat --yolo --accept-hooks " ] \
    || fail "hermes-agent fallback did not expand to an absolute executable: $launch"
  pass "fm-spawn: hermes falls back to hermes-agent on PATH"
}

test_hermes_unconfirmed_delivery_fails_loudly() {
  local id rec out rc
  id=hermes-drop-z5
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_HERMES_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed hermes delivery should fail"
  assert_contains "$out" "hermes brief pointer delivery was not confirmed" \
    "unconfirmed hermes delivery lacked a loud diagnostic"
  assert_grep 'failed: hermes brief pointer delivery was not confirmed' "$HOME_DIR/state/$id.status" \
    "unconfirmed hermes delivery did not leave a supervisor-visible failure"
  pass "fm-spawn: hermes treats an unconfirmed pointer as a failed spawn"
}

test_hermes_readiness_gate_precedes_pointer() {
  local id rec out rc
  id=hermes-not-ready-z6
  rec=$(make_spawn_case not-ready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_HERMES_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "hermes spawn without a ready signal should fail"
  assert_contains "$out" "hermes did not show a verified ready signal" \
    "hermes readiness failure lacked a loud diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "hermes pointer was sent before readiness"
  pass "fm-spawn: hermes never sends the brief pointer before an observable ready signal"
}

test_hermes_detection_uses_argv_not_bare_python() {
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
  comm=:5151) printf 'Python\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:5151) printf '1\n' ;;
  ppid=:*) printf '5151\n' ;;
  args=:5151) printf 'Python /opt/homebrew/bin/hermes chat --yolo\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = hermes ] || fail "hermes argv detection returned '$out'"

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
  comm=:6161) printf 'Python\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:6161) printf '1\n' ;;
  ppid=:*) printf '6161\n' ;;
  args=:6161) printf 'Python /usr/bin/some-other-tool\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "bare Python without hermes argv must stay unknown, got '$out'"
  pass "fm-harness: hermes is detected from argv hermes, never bare Python alone"
}

test_hermes_composer_idle_glyph_is_empty() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 0 '❯')
  [ "$out" = empty ] || fail "hermes bare ❯ must read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '⚕ ❯ msg=interrupt · Ctrl+C cancel')
  [ "$out" = pending ] || fail "hermes busy footer content must not read empty, got '$out'"
  pass "composer classifier: hermes idle ❯ is empty and busy footer is not"
}

test_hermes_busy_signature_is_harness_scoped() {
  local capture
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-tmux-lib.sh"
  unset FM_BUSY_REGEX
  capture="$TMP_ROOT/busy-pane"
  tmux() {
    case "${1:-}" in
      capture-pane) cat "$capture" ;;
      *) return 0 ;;
    esac
  }
  printf '⚕ ❯ msg=interrupt · /queue · Ctrl+C cancel\n' > "$capture"
  fm_pane_is_busy fake hermes || fail "hermes busy footer was not recognized as busy"
  printf 'Initializing agent...\n❯\n' > "$capture"
  fm_pane_is_busy fake hermes || fail "hermes initializing line was not recognized as busy"
  printf '❯\n' > "$capture"
  if fm_pane_is_busy fake hermes; then
    fail "hermes bare idle ❯ was misread as busy"
  fi
  printf 'Ctrl+c:cancel\n' > "$capture"
  if fm_pane_is_busy fake hermes; then
    fail "Grok's exact busy token leaked into hermes"
  fi
  printf '⚕ ❯ msg=interrupt · Ctrl+C cancel\n' > "$capture"
  if fm_pane_is_busy fake grok; then
    fail "hermes busy chrome leaked into grok"
  fi
  if fm_pane_is_busy fake claude; then
    fail "hermes busy chrome leaked into claude"
  fi
  pass "busy detection: hermes ASCII busy tokens stay harness-scoped"
}

test_watcher_classifies_hermes_from_its_own_fallback_only() (
  local state="$TMP_ROOT/watch-state"
  mkdir -p "$state"
  printf 'window=fake\nharness=hermes\n' > "$state/hermes-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  # shellcheck disable=SC2329 # Runtime override called by the sourced watcher.
  fm_backend_busy_state() { printf 'unknown'; }
  window_is_busy fake '⚕ ❯ msg=interrupt · Ctrl+C cancel' \
    || fail "fm-watch must classify a hermes task busy from hermes chrome"
  if window_is_busy fake 'Ctrl+c:cancel'; then
    fail "fm-watch applied Grok's token to a recorded hermes task"
  fi
  [ "$(fm_busy_classify tmux fake hermes hermes-watch "$state" '❯')" = "idle hermes-regex" ] \
    || fail "a hermes idle pane must classify idle hermes-regex"
  printf 'window=fake\nharness=grok\n' > "$state/hermes-watch.meta"
  if window_is_busy fake '⚕ ❯ msg=interrupt · Ctrl+C cancel'; then
    fail "hermes chrome classified a recorded Grok task"
  fi
  window_is_busy fake 'Ctrl+c:cancel' \
    || fail "Grok's own verified token must still classify a recorded Grok task busy"
  pass "fm-watch classifies hermes only through hermes-regex and keeps Grok isolated"
)

test_hermes_launch_then_send_is_verified
test_hermes_idle_delivery_is_accepted
test_hermes_missing_binary_refuses_before_pane_creation
test_hermes_falls_back_to_hermes_agent_binary
test_hermes_unconfirmed_delivery_fails_loudly
test_hermes_readiness_gate_precedes_pointer
test_hermes_detection_uses_argv_not_bare_python
test_hermes_composer_idle_glyph_is_empty
test_hermes_busy_signature_is_harness_scoped
test_watcher_classifies_hermes_from_its_own_fallback_only
