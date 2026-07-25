#!/usr/bin/env bash
# Behavior tests for the verified Kimi Code CLI crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-kimi-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

assert_source_line() {
  local line=$1
  grep -Fqx -- "$line" "$SPAWN" || fail "existing launch template changed: $line"
}

test_existing_launch_templates_are_byte_pinned() {
  assert_source_line "    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "        printf '%s' 'codex __MODELFLAG____EFFORTFLAG__--dangerously-bypass-approvals-and-sandbox -c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch __TURNEND__\\\"]\" \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    opencode) printf '%s' 'OPENCODE_CONFIG_CONTENT='\\''{\"permission\":{\"*\":\"allow\"}}'\\'' opencode __MODELFLAG__--prompt \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  assert_source_line "        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PITURNEND__ -e __PIWATCH__ \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "        printf '%s' 'pi __MODELFLAG____EFFORTFLAG__-e __PIEXT__ \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"'"
  assert_source_line "    grok) printf '%s' 'grok --always-approve __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  pass "fm-spawn: the five pre-existing adapters' launch templates stay byte-pinned"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=$(cat "$FM_FAKE_KIMI_STATE" 2>/dev/null || true)
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
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
        /Users/kunchen/.kimi-code/bin/kimi*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_KIMI_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_KIMI_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_KIMI_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
          pointer-typed)
            if [ "${FM_FAKE_KIMI_DELIVERY:-yes}" = yes ]; then
              printf 'delivered\n' > "$FM_FAKE_KIMI_STATE"
            else
              printf 'ready\n' > "$FM_FAKE_KIMI_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    case "$state" in
      ready)
        printf 'Welcome to Kimi Code!\ncontext: 0%% (0/256k)\n│ > │\n'
        ;;
      pointer-typed)
        printf 'context: 0%% (0/256k)\n│ > pending │\n'
        ;;
      delivered)
        printf '✨ Read the brief at %s and follow it exactly.\ncontext: 1%% (2k/256k)\n│ > │\n' "$FM_FAKE_BRIEF_REAL"
        ;;
      *)
        printf 'shell starting\n$ \n'
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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
  printf 'brief for kimi\n' > "$home/data/$id/brief.md"
  printf 'kimi\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/kimi.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_KIMI_STATE="$case_dir/kimi.state" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/brief.md" \
    FM_KIMI_READY_POLLS=2 FM_KIMI_DELIVERY_POLLS=2 FM_KIMI_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness kimi "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_kimi_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta
  id=kimi-success-z1
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model kimi-code/k3 --effort high)
  rc=$?
  expect_code 0 "$rc" "verified kimi launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=kimi" "kimi spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "/Users/kunchen/.kimi-code/bin/kimi --model 'kimi-code/k3' --auto" ] \
    || fail "kimi launch did not use the absolute binary, model, and --auto only: $launch"
  assert_not_contains "$launch" "--effort" "kimi launch emitted a nonexistent effort flag"
  assert_not_contains "$launch" "turn-ended" "kimi launch implied a turn-end marker"
  assert_not_contains "$launch" "__TURNEND__" "kimi launch retained a turn-end placeholder"

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "kimi pointer was not the exact absolute-path-only instruction: $pointer"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=kimi-code/k3' "$meta" "kimi meta lost the requested model"
  assert_grep 'effort=high' "$meta" "kimi meta did not retain the unsupported effort axis"
  assert_absent "$HOME_DIR/.kimi-code/config.toml" "kimi spawn wrote a global config file"
  pass "fm-spawn: kimi launches bare, waits for readiness, sends an absolute brief pointer, and confirms delivery"
}

test_kimi_unconfirmed_delivery_fails_loudly() {
  local id rec out rc
  id=kimi-drop-z2
  rec=$(make_spawn_case drop "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_DELIVERY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed kimi delivery should fail"
  assert_contains "$out" "kimi brief pointer delivery was not confirmed" \
    "unconfirmed kimi delivery lacked a loud diagnostic"
  assert_grep 'failed: kimi brief pointer delivery was not confirmed' "$HOME_DIR/state/$id.status" \
    "unconfirmed kimi delivery did not leave a supervisor-visible failure"
  pass "fm-spawn: kimi treats a silent pointer drop as a failed spawn"
}

test_kimi_readiness_gate_precedes_pointer() {
  local id rec out rc
  id=kimi-not-ready-z3
  rec=$(make_spawn_case not-ready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIMI_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "kimi spawn without a ready signal should fail"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "kimi readiness failure lacked a loud diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "kimi pointer was sent before readiness"
  pass "fm-spawn: kimi never sends the brief pointer before an observable ready signal"
}

test_kimi_detection_uses_ancestry_after_markers() {
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
  comm=:4242) printf '/Users/kunchen/.kimi-code/bin/kimi\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = kimi ] || fail "kimi ancestry detection returned '$out'"
  out=$(CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: markerless kimi is detected by ancestry after env-marker precedence"
}

test_kimi_busy_signature_is_scoped_to_spinner_lines() {
  local capture phase
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
  for phase in 🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘; do
    printf '%s Thinking\n│ > │\n' "$phase" > "$capture"
    fm_pane_is_busy fake kimi || fail "kimi moon phase $phase was not recognized as busy"
  done
  printf 'ordinary response ending with 🌕\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "a moon outside Kimi's spinner-line shape was misread as busy"
  fi
  printf '🌕 Thinking\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake codex; then
    fail "Kimi's moon spinner signature leaked into another harness"
  fi
  printf 'tip: ctrl+c: cancel\n│ > │\n' > "$capture"
  if fm_pane_is_busy fake kimi; then
    fail "kimi's independently rotating idle tip was misread as busy"
  fi
  for phase in 🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘; do
    grep -Fq "$phase" "$ROOT/bin/fm-watch.sh" \
      || fail "fm-watch default is missing kimi moon phase $phase"
  done
  pass "busy detection: Kimi moon phases require its harness and spinner-line shape"
}

test_watcher_scopes_moon_spinner_to_recorded_kimi_task() (
  local state="$TMP_ROOT/watch-state"
  mkdir -p "$state"
  printf 'window=fake\nharness=kimi\n' > "$state/kimi-watch.meta"
  unset FM_BUSY_REGEX
  FM_HOME="$TMP_ROOT/watch-home"
  FM_STATE_OVERRIDE="$state"
  export FM_HOME FM_STATE_OVERRIDE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  fm_backend_busy_state() { printf 'unknown'; }
  window_is_busy fake '🌕 Thinking' \
    || fail "fm-watch did not recognize a recorded Kimi spinner line"
  printf 'window=fake\nharness=codex\n' > "$state/kimi-watch.meta"
  if window_is_busy fake '🌕 Thinking'; then
    fail "fm-watch applied Kimi's moon spinner to a recorded Codex task"
  fi
  printf 'window=fake\nharness=kimi\n' > "$state/kimi-watch.meta"
  if window_is_busy fake 'ordinary response ending with 🌕'; then
    fail "fm-watch treated an ordinary Kimi moon as a spinner line"
  fi
  pass "fm-watch: moon spinner matching is scoped by metadata and line shape"
)

test_kimi_bordered_prompt_needs_no_override() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_composer_classify_content 1 '>')
  [ "$out" = empty ] || fail "kimi's bordered bare > composer should read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '>')
  [ "$out" = unknown ] || fail "an unbordered dead-shell > must stay unknown, got '$out'"
  pass "composer classifier: kimi's existing bordered > shape is already safe without an override"
}

test_existing_launch_templates_are_byte_pinned
test_kimi_launch_then_send_is_verified
test_kimi_unconfirmed_delivery_fails_loudly
test_kimi_readiness_gate_precedes_pointer
test_kimi_detection_uses_ancestry_after_markers
test_kimi_busy_signature_is_scoped_to_spinner_lines
test_watcher_scopes_moon_spinner_to_recorded_kimi_task
test_kimi_bordered_prompt_needs_no_override
