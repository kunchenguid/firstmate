#!/usr/bin/env bash
# Behavior tests for the verified Anti-Gravity CLI harness adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
AGY_HOOK="$ROOT/bin/fm-agy-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
AGY_RUNTIME_TASK_TMP=
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

cleanup_agy_harness() {
  [ -z "$AGY_RUNTIME_TASK_TMP" ] || rm -rf "$AGY_RUNTIME_TASK_TMP"
  fm_test_cleanup
}
trap cleanup_agy_harness EXIT

agy_empty_capture() {
  printf '%s\n' \
    'Antigravity CLI' \
    '────────────────────────────────────────────────────────────────' \
    '>' \
    '────────────────────────────────────────────────────────────────' \
    '? for shortcuts                              Gemini 3.6 Flash · low'
}

agy_pending_capture() {
  printf '%s\n' \
    'Antigravity CLI' \
    '────────────────────────────────────────────────────────────────' \
    '> captain steer' \
    '────────────────────────────────────────────────────────────────' \
    '? for shortcuts                              Gemini 3.6 Flash · low'
}

claude_lookalike_capture() {
  printf '%s\n' \
    '────────────────────────────────────────────────────────────────' \
    '> a quoted transcript line Claude rendered from markdown' \
    '────────────────────────────────────────────────────────────────' \
    '╭──────────────────────────────────────────────────────────────╮' \
    '│ >                                                            │' \
    '╰──────────────────────────────────────────────────────────────╯' \
    '  ? for shortcuts'
}

test_separated_composer_is_structural() {
  local state
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  state=$(FM_COMPOSER_HARNESS=agy fm_composer_separated_state "$(agy_empty_capture)")
  [ "$state" = empty ] || fail "Agy empty separated composer read as $state"
  state=$(FM_COMPOSER_HARNESS=agy fm_composer_separated_state "$(agy_pending_capture)")
  [ "$state" = pending ] || fail "Agy typed separated composer read as $state"
  state=$(FM_COMPOSER_HARNESS=agy fm_composer_separated_state $'>\n$ ')
  [ -z "$state" ] || fail "bare shell prompt was accepted as Agy structure"
  state=$(FM_COMPOSER_HARNESS=agy fm_composer_separated_state "$(agy_empty_capture)"$'\n────────────────────\n>\n────────────────────')
  [ -z "$state" ] || fail "a stale Agy footer authorized a later separator pair"
  pass "Agy composer classification requires the complete separated container"
}

test_separated_composer_is_harness_scoped() {
  local state
  # shellcheck source=bin/fm-composer-lib.sh
  . "$ROOT/bin/fm-composer-lib.sh"
  state=$(FM_COMPOSER_HARNESS= fm_composer_separated_state "$(agy_empty_capture)")
  [ -z "$state" ] || fail "unscoped separated check claimed a pane as an Agy composer: $state"
  state=$(FM_COMPOSER_HARNESS=claude fm_composer_separated_state "$(claude_lookalike_capture)")
  [ -z "$state" ] || fail "a Claude rule/quote/rule transcript was claimed as an Agy composer: $state"
  state=$(
    # shellcheck source=bin/fm-tmux-lib.sh
    . "$ROOT/bin/fm-tmux-lib.sh"
    tmux() {
      case "$*" in
        *cursor_y*) printf '4\n' ;;
        *capture-pane*) claude_lookalike_capture ;;
        *) return 0 ;;
      esac
    }
    FM_COMPOSER_HARNESS=claude fm_tmux_composer_state pane
  )
  [ "$state" = empty ] || fail "a Claude pane with a rule/quote/rule tail did not fall through to its own box classifier: $state"
  state=$(
    # shellcheck source=bin/backends/cmux.sh
    . "$ROOT/bin/backends/cmux.sh"
    fm_backend_cmux_capture() {
      printf '%s\n' \
        '────────────────────────────────────────────────────────────────' \
        '> a quoted transcript line rendered from markdown' \
        '────────────────────────────────────────────────────────────────' \
        '' \
        '? for shortcuts'
    }
    FM_COMPOSER_HARNESS=claude fm_backend_cmux_composer_state workspace:surface
  )
  [ "$state" = unknown ] || fail "a non-Agy cmux pane with a rule/quote/rule tail was misclassified as $state"
  pass "the structural Agy composer check never claims another harness's pane"
}

test_agy_busy_signature_is_harness_scoped() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$ROOT/bin/fm-tmux-lib.sh"
  printf 'esc to cancel\n' | fm_busy_lines_match agy \
    || fail "Agy busy footer did not classify its task as busy"
  if printf 'esc to cancel\n' | fm_busy_lines_match grok; then
    fail "Agy busy footer leaked into Grok's harness-scoped matcher"
  fi
  pass "Agy busy classification is explicit and harness-scoped"
}

test_plain_backends_share_agy_composer_contract() {
  local state
  state=$(
    # shellcheck source=bin/backends/herdr.sh
    . "$ROOT/bin/backends/herdr.sh"
    fm_backend_herdr_parse_target() {
      FM_BACKEND_HERDR_SESSION='test'
      FM_BACKEND_HERDR_PANE=pane
      return 0
    }
    fm_backend_herdr_capture_ansi() { agy_empty_capture; }
    FM_COMPOSER_HARNESS=agy fm_backend_herdr_composer_state test:pane
  )
  [ "$state" = empty ] || fail "Herdr Agy composer read as $state"
  state=$(
    # shellcheck source=bin/backends/orca.sh
    . "$ROOT/bin/backends/orca.sh"
    fm_backend_orca_read_text_paged() { agy_pending_capture; }
    FM_COMPOSER_HARNESS=agy fm_backend_orca_composer_state terminal
  )
  [ "$state" = pending ] || fail "Orca Agy composer read as $state"
  state=$(
    # shellcheck source=bin/backends/cmux.sh
    . "$ROOT/bin/backends/cmux.sh"
    fm_backend_cmux_capture() { agy_empty_capture; }
    FM_COMPOSER_HARNESS=agy fm_backend_cmux_composer_state workspace:surface
  )
  [ "$state" = empty ] || fail "cmux Agy composer read as $state"
  pass "Herdr, Orca, and cmux consume the shared Agy composer interface"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  apply_fake_tmux "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

apply_fake_tmux() {
  local path=$1
  cp "$ROOT/tests/fixtures/fm-agy-fake-tmux.sh" "$path"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for agy\n' > "$home/data/$id/brief.md"
  printf 'agy\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/agy.state"
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
    FM_FAKE_AGY_STATE="$case_dir/agy.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/brief.md" \
    FM_AGY_READY_POLLS=5 FM_AGY_DELIVERY_POLLS=3 FM_AGY_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness agy "$@" 2>&1
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_agy_spawn_delivers_after_trust_and_registers_hook() {
  local id rec out rc launch pointer brief_real meta task_tmp token hook_root payload target
  id="agy-success-z1-$$"
  task_tmp="/tmp/fm-$id"
  AGY_RUNTIME_TASK_TMP=$task_tmp
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.6-flash-low --effort high)
  rc=$?
  expect_code 0 "$rc" "verified Agy spawn should succeed"
  assert_contains "$out" "spawned $id harness=agy" "Agy spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "agy --model 'gemini-3.6-flash-low' --effort 'high' --dangerously-skip-permissions" ] \
    || fail "Agy launch was not bare interactive with profile flags: $launch"
  assert_not_contains "$launch" "brief" "Agy launch raced the trust gate with an initial prompt"
  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "Agy pointer was not the exact absolute-path instruction: $pointer"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=gemini-3.6-flash-low' "$meta" "Agy meta lost the model"
  assert_grep 'effort=high' "$meta" "Agy meta lost the effort"
  token=$(sed -n '1p' "$HOME_DIR/state/$id.agy-turnend-token")
  hook_root=$(sed -n '2p' "$HOME_DIR/state/$id.agy-turnend-token")
  assert_grep "token=$token" "$WT_DIR/.fm-agy-turnend" "Agy pointer lost its token"
  assert_present "$WT_DIR/$hook_root/hooks.json" "Agy task hook was not installed"
  assert_present "$HOME_DIR/state/agy-turn-end.d/$token" "Agy auth token was not registered"

  target="$HOME_DIR/state/$id.turn-ended"
  payload=$(printf '{"conversationId":"crew","executionNum":0,"workspacePaths":["%s"]}' "$WT_DIR")
  out=$(printf '%s\n' "$payload" \
    | "$AGY_HOOK" "$HOME_DIR/state/agy-turn-end.d" "$token" "$WT_DIR")
  [ "$out" = '{}' ] || fail "registered Agy hook did not emit its neutral result: $out"
  assert_present "$target" "registered Agy Stop payload did not touch the marker"
  rm "$target"
  out=$(printf '{"conversationId":"other","executionNum":0,"workspacePaths":["%s"]}\n' "$CASE_DIR/other" \
    | "$AGY_HOOK" "$HOME_DIR/state/agy-turn-end.d" "$token" "$WT_DIR")
  [ "$out" = '{}' ] || fail "foreign Agy hook did not emit its neutral result: $out"
  assert_absent "$target" "foreign Agy workspace touched the task marker"
  pass "Agy spawn gates trust, delivers the brief, and registers a workspace-bound Stop hook"
}

test_agy_spawn_refuses_when_all_hook_roots_are_owned() {
  local id rec out rc root
  id="agy-roots-z2-$$"
  rec=$(make_spawn_case roots "$id")
  read_spawn_record "$rec"
  for root in .agents .agent _agents _agent; do
    mkdir -p "$WT_DIR/$root"
    printf '{}\n' > "$WT_DIR/$root/hooks.json"
  done
  rc=0
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "Agy spawn overwrote an occupied hook root"
  assert_contains "$out" "will not merge or overwrite project hook configuration" \
    "Agy occupied-root refusal lacked its safety reason"
  pass "Agy spawn refuses instead of mutating existing hook configuration"
}

test_agy_omits_unsupported_explicit_effort() {
  local id rec out rc launch
  id="agy-effort-z4-$$"
  rec=$(make_spawn_case effort "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.6-flash-high --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "explicit unsupported Agy effort should be recorded and omitted"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--model 'gemini-3.6-flash-high'" "Agy launch lost the model"
  assert_not_contains "$launch" "--effort" "Agy launch passed unsupported xhigh effort"
  assert_grep 'effort=xhigh' "$HOME_DIR/state/$id.meta" "Agy meta lost the requested effort"
  pass "Agy records but does not pass an unsupported explicit effort"
}

test_agy_teardown_removes_task_hook_and_auth() {
  local id rec out rc token hook_root
  id="agy-teardown-z3-$$"
  rec=$(make_spawn_case teardown "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "Agy spawn should succeed before teardown"
  token=$(sed -n '1p' "$HOME_DIR/state/$id.agy-turnend-token")
  hook_root=$(sed -n '2p' "$HOME_DIR/state/$id.agy-turnend-token")
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 || fail "Agy teardown failed"
  assert_absent "$WT_DIR/.fm-agy-turnend" "Agy pointer survived teardown"
  assert_absent "$WT_DIR/$hook_root/hooks.json" "Agy hook survived teardown"
  assert_absent "$HOME_DIR/state/agy-turn-end.d/$token" "Agy auth token survived teardown"
  assert_absent "$HOME_DIR/state/$id.agy-turnend-token" "Agy token state survived teardown"
  pass "Agy teardown removes the generated hook, pointer, and registry token"
}

test_agy_primary_guard_bounds_continuation() {
  local dir out rc
  dir="$TMP_ROOT/primary-guard"
  mkdir -p "$dir"
  cp "$ROOT/bin/fm-turnend-guard-agy.sh" "$dir/fm-turnend-guard-agy.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "repair watcher" >&2' 'exit 2' > "$dir/fm-turnend-guard.sh"
  chmod +x "$dir/fm-turnend-guard-agy.sh" "$dir/fm-turnend-guard.sh"
  out=$(printf '{"executionNum":0}\n' | PATH="$(dirname "$JQ_BIN"):$BASE_PATH" "$dir/fm-turnend-guard-agy.sh")
  [ "$(printf '%s' "$out" | jq -r '.decision')" = continue ] \
    || fail "Agy primary guard did not request a same-session continuation"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/fm-turnend-guard.sh"
  out=$(printf '{"executionNum":0}\n' | PATH="$(dirname "$JQ_BIN"):$BASE_PATH" "$dir/fm-turnend-guard-agy.sh")
  [ "$out" = '{}' ] || fail "Agy satisfied primary guard did not emit the neutral hook result: $out"
  rc=0
  out=$(printf '{"executionNum":1}\n' | PATH="$(dirname "$JQ_BIN"):$BASE_PATH" "$dir/fm-turnend-guard-agy.sh") || rc=$?
  expect_code 0 "$rc" "Agy second execution must be allowed"
  [ "$out" = '{}' ] || fail "Agy second execution did not emit the neutral hook result: $out"
  pass "Agy primary Stop guard forces at most one same-session continuation"
}

test_agy_detection_uses_marker_and_ancestry() {
  local dir fakebin cfg detected
  detected=$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$detected" = agy ] || fail "Agy marker lost to inherited Claude marker: $detected"

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
  comm=:4242) printf '/home/test/.local/bin/agy\n' ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:4242) printf '1\n' ;;
  ppid=:*) printf '4242\n' ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  detected=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u ANTIGRAVITY_AGENT \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$detected" = agy ] || fail "Agy ancestry detection returned '$detected'"
  pass "Agy child marker and parent process both identify the active harness"
}

test_agy_session_lock_identity() {
  local home fakebin out
  home="$TMP_ROOT/session-lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/session-lock-fake")
  mkdir -p "$home/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/home/test/.local/bin/agy'; exit 0 ;;
  *"args="*) printf '%s\n' 'agy'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" \
    || fail "fm-lock did not acquire from Agy ancestry"
  case "$(cat "$home/state/.lock")" in
    ''|*[!0-9]*) fail "fm-lock did not record the Agy harness ancestor" ;;
  esac
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" \
    "fm-lock did not recognize Agy as a live holder"
  pass "fm-lock recognizes Agy ancestry and live lock holders"
}

test_separated_composer_is_structural
test_separated_composer_is_harness_scoped
test_agy_busy_signature_is_harness_scoped
test_plain_backends_share_agy_composer_contract
test_agy_spawn_delivers_after_trust_and_registers_hook
test_agy_spawn_refuses_when_all_hook_roots_are_owned
test_agy_omits_unsupported_explicit_effort
test_agy_teardown_removes_task_hook_and_auth
test_agy_primary_guard_bounds_continuation
test_agy_detection_uses_marker_and_ancestry
test_agy_session_lock_identity
