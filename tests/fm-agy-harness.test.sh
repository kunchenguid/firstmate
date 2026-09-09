#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI crewmate/scout adapter.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agy-lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the
# asserted verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI

TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" agy)
  fm_test_spawn_home "$home" agy
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <case-dir> <home> <proj> <wt> <fakebin> <id> [extra spawn args...]
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" --harness agy --mode no-mistakes --yolo off "$@"
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

run_agy_hook() {  # <hooks.json> <hook-event>
  local hooks=$1 event=$2 cmd
  cmd=$(jq -r --arg ev "$event" '.["fm-busy-state"][$ev][0].command' "$hooks")
  [ "$cmd" != null ] && [ -n "$cmd" ] || return 1
  sh -c "$cmd"
}

test_agy_launch_carries_brief_with_native_model_effort() {
  local rec id=agy-launch-z1 out rc launch meta
  rec=$(make_spawn_case launch "$id")
  read_case_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low --effort low)
  rc=$?
  expect_code 0 "$rc" "verified agy launch should succeed: $out"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--prompt-interactive" \
    "agy launch did not start the supervised session with --prompt-interactive"
  assert_contains "$launch" "encode launch-brief" \
    "agy launch did not carry the brief through the operational-input encoder"
  assert_contains "$launch" "--dangerously-skip-permissions" \
    "agy launch omitted the unattended approval flag"
  assert_contains "$launch" "--model 'gemini-3.8-flash-low'" \
    "agy launch omitted the requested native model"
  assert_contains "$launch" "--effort 'low'" \
    "agy launch omitted the requested native effort"
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "agy launch did not clear foreign primary markers"
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "agy launch did not clear cursor's markers via the shared outer wrap"
  assert_not_contains "$launch" "--sandbox" \
    "agy launch passed a terminal-restriction flag an unattended worker cannot survive"
  assert_not_contains "$launch" "turn-ended" \
    "agy launch embedded a turn-end path it does not own"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=gemini-3.8-flash-low' "$meta" "agy meta lost the requested model"
  assert_grep 'effort=low' "$meta" "agy meta lost the requested effort"
  pass "fm-spawn: agy launches with --prompt-interactive, native model/effort, and cleared foreign markers"
}

test_agy_effort_xhigh_is_recorded_but_omitted() {
  local rec id=agy-xhigh-z2 out rc launch meta
  rec=$(make_spawn_case xhigh "$id")
  read_case_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "agy spawn with an unsupported effort should still succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--effort" \
    "agy launch passed an effort value outside its native low|medium|high set"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "agy meta did not retain the unsupported effort axis"
  pass "fm-spawn: agy omits --effort for xhigh but records xhigh in task metadata"
}

test_agy_hooks_semantic_lifecycle() {
  local rec id=agy-hooks-z3 out state hooks
  rec=$(make_spawn_case hooks "$id")
  read_case_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 "$?" "agy spawn should succeed: $out"
  state="$HOME_DIR/state"
  hooks="$WT_DIR/.agents/hooks.json"
  assert_present "$hooks" "agy spawn did not write the worktree hooks file"
  jq -e . "$hooks" >/dev/null || fail "agy hooks file is not valid JSON"
  for ev in PreInvocation PostInvocation Stop; do
    jq -e --arg ev "$ev" '.["fm-busy-state"][$ev]' "$hooks" >/dev/null \
      || fail "agy hooks file lacks the $ev closer under our named key"
  done

  out=$(classify agy "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(run_agy_hook "$hooks" PreInvocation) || fail "PreInvocation hook command failed: $out"
  assert_contains "$out" "{}" "PreInvocation hook did not print agy's required JSON object"
  out=$(classify agy "$id" "$state")
  [ "$out" = "busy agy-hook" ] || fail "PreInvocation must classify 'busy agy-hook', got '$out'"
  [ ! -e "$state/$id.turn-ended" ] || fail "PreInvocation fabricated a completed turn"

  out=$(run_agy_hook "$hooks" PostInvocation) || fail "PostInvocation hook command failed: $out"
  out=$(classify agy "$id" "$state")
  [ "$out" = "idle agy-hook" ] || fail "PostInvocation must classify 'idle agy-hook', got '$out'"

  out=$(run_agy_hook "$hooks" PreInvocation) || fail "second PreInvocation hook command failed"
  out=$(run_agy_hook "$hooks" Stop) || fail "Stop hook command failed: $out"
  assert_contains "$out" "{}" "Stop hook did not print agy's required JSON object"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify agy "$id" "$state")
  [ "$out" = "idle agy-hook" ] || fail "Stop must classify 'idle agy-hook', got '$out'"
  pass "agy hooks report a PreInvocation busy, close idle on PostInvocation and Stop, and keep Stop a notification"
}

test_agy_hooks_merge_preserves_project_file() {
  # Lib-level: a spawn's freshen step resets the worktree to origin's tip, so
  # a committed project fixture cannot survive to the arm. The merge contract
  # itself needs no git, only the lib.
  local dir wt state id=agy-merge-z4 hooks backup original
  dir="$TMP_ROOT/merge"
  wt="$dir/wt"
  state="$dir/state"
  mkdir -p "$wt/.agents" "$state"
  hooks="$wt/.agents/hooks.json"
  original='{"project-gate": {"PreToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "true"}]}]}}'
  printf '%s\n' "$original" > "$hooks"
  fm_agy_hooks_install "$wt" "$state" "$id" "gen-merge-1" "$state/$id.turn-ended" "$ROOT" \
    || fail "agy install failed on a project hooks file"
  jq -e '."project-gate"' "$hooks" >/dev/null \
    || fail "agy install clobbered the project's own named hook"
  jq -e '."fm-busy-state".Stop' "$hooks" >/dev/null \
    || fail "agy install did not merge our key into the project's hooks file"

  backup="$state/$id.agy-hooks-backup"
  assert_present "$backup" "agy install did not back up the merged project file"
  fm_agy_hooks_remove "$wt" "$state" "$id" \
    || fail "agy hooks remove failed on a merged file"
  [ "$(cat "$hooks")" = "$original" ] \
    || fail "agy remove did not restore the project file byte-exact"
  pass "agy hooks merge into a project hooks.json and restore it byte-exact at teardown"
}

test_agy_hooks_created_file_is_removed() {
  local rec id=agy-created-z5 out state hooks
  rec=$(make_spawn_case created "$id")
  read_case_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 "$?" "agy spawn should succeed: $out"
  state="$HOME_DIR/state"
  hooks="$WT_DIR/.agents/hooks.json"
  assert_present "$hooks" "agy spawn did not create the hooks file"
  fm_agy_hooks_remove "$WT_DIR" "$state" "$id" \
    || fail "agy hooks remove failed on a created file"
  assert_absent "$hooks" "agy remove left a created hooks file behind"
  assert_absent "$state/$id.agy-hooks-mode" "agy remove left its mode sidecar behind"
  pass "agy hooks remove deletes a file it created and retires its sidecars"
}

test_agy_trust_registers_worktree_and_refuses_primary() {
  local rec id=agy-trust-z6 out rc store
  rec=$(make_spawn_case trust "$id")
  read_case_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  expect_code 0 "$?" "agy spawn should succeed: $out"
  store="$HOME_DIR/user-home/.gemini/antigravity-cli/settings.json"
  assert_present "$store" "agy spawn did not pre-register workspace trust"
  jq -e --arg wt "$WT_DIR" '.trustedWorkspaces | index($wt)' "$store" >/dev/null \
    || fail "agy trust registration omitted the worktree"

  out=$(HOME="$HOME_DIR/user-home" "$ROOT/bin/fm-agy-trust.sh" "$PROJ_DIR" "$PROJ_DIR" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "agy trust accepted a primary checkout as a worktree"
  assert_contains "$out" "primary checkout" "agy trust refusal lacked its concrete reason"

  out=$(HOME="$HOME_DIR/user-home" "$ROOT/bin/fm-agy-trust.sh" "$HOME_DIR" "$PROJ_DIR" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "agy trust accepted an unrelated directory as a worktree"
  pass "agy trust pre-registers the worktree and refuses a primary checkout and an unrelated path"
}

test_agy_missing_binary_refuses_before_pane_creation() {
  local rec id=agy-missing-z7 out rc
  rec=$(make_spawn_case missing "$id")
  read_case_record "$rec"
  rm "$FAKEBIN_DIR/agy"
  rc=0
  # agy is installed on this host, so the inherited PATH would resolve the
  # real binary behind the removed stub. Restrict PATH to the fakebin plus
  # the base system dirs, the same shape a host without agy presents.
  out=$(PATH="$FAKEBIN_DIR:$BASE_PATH" \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "missing agy executable should refuse the spawn"
  assert_contains "$out" "searched PATH for 'agy'" "missing agy diagnostic omitted PATH search"
  [ -s "$CASE_DIR/launch.log" ] && fail "missing agy executable created a launch command" || true
  pass "fm-spawn: missing agy executable refuses before pane creation"
}

test_agy_secondmate_is_refused() {
  local rec id=agy-secondmate-z8 out rc
  rec=$(make_spawn_case secondmate-refuse "$id")
  read_case_record "$rec"
  rc=0
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" --secondmate agy 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an agy secondmate spawn should be refused"
  assert_contains "$out" "agy is a verified crewmate/scout adapter only" \
    "agy secondmate refusal lacked its concrete reason"
  pass "fm-spawn: agy cannot be launched as a secondmate"
}

test_agy_detection_ancestry_is_anchored() {
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
  comm=:"$FM_FAKE_COMM_PID") printf '%s\n' "$FM_FAKE_COMM" ;;
  comm=:*) printf '/bin/bash\n' ;;
  ppid=:"$FM_FAKE_COMM_PID") printf '1\n' ;;
  ppid=:*) printf '%s\n' "$FM_FAKE_COMM_PID" ;;
  args=:*) printf 'bash\n' ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(FM_FAKE_COMM_PID=4242 FM_FAKE_COMM=agy \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = agy ] || fail "agy ancestry detection returned '$out'"

  out=$(FM_FAKE_COMM_PID=4242 FM_FAKE_COMM=agy-wrapper \
    PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = unknown ] || fail "an agy-prefixed command claimed the agy identity, got '$out'"

  out=$(FM_FAKE_COMM_PID=4242 FM_FAKE_COMM=agy \
    CLAUDECODE=1 PATH="$fakebin:$BASE_PATH" FM_CONFIG_OVERRIDE="$cfg" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "verified env-marker precedence changed, got '$out'"
  pass "fm-harness: anchored agy ancestry resolves agy, rejects prefixed names, and keeps marker precedence"
}

test_agy_control_lib_table() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-control-lib.sh"
  [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy interrupt key is not Escape"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy interrupt repeat is not 1"
  [ -z "$(fm_control_interrupt_clear_key agy)" ] || fail "agy should need no interrupt clear key"
  [ "$(fm_control_interrupt_ack_source agy)" = none ] || fail "agy interrupt ack source is not none"
  [ "$(fm_control_exit_command agy)" = /exit ] || fail "agy exit command is not /exit"
  [ "$(fm_control_harness_family agy)" = agy ] || fail "agy harness family exact match failed"
  if fm_control_harness_family agy-wrapper >/dev/null 2>&1; then
    fail "agy harness family must not claim a prefixed command"
  fi
  fm_control_harness_supports_kind agy ship || fail "agy should support ship tasks"
  fm_control_harness_supports_kind agy scout || fail "agy should support scout tasks"
  if fm_control_harness_supports_kind agy secondmate; then
    fail "agy should never support secondmate tasks"
  fi
  wiring=$(fm_control_harness_wiring_paths agy /wt /state task-1)
  assert_contains "$wiring" "/state/task-1.agy-hooks-mode" "agy wiring paths omitted the mode sidecar"
  assert_contains "$wiring" "/state/task-1.agy-hooks-backup" "agy wiring paths omitted the backup sidecar"
  assert_not_contains "$wiring" ".agents/hooks.json" "agy wiring paths must never list the worktree hooks file"
  pass "fm-control-lib: agy's lifecycle table matches its verified facts"
}

test_agy_busy_source_and_delivery_regex_isolated() {
  local out
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-composer-lib.sh"
  out=$(fm_busy_sources_for_harness agy)
  assert_contains "$out" "agy-hook" "agy trusted sources omit the hook writer"

  printf 'esc to cancel\n' | fm_busy_lines_match agy \
    || fail "agy's real busy token was not recognized as busy"
  printf '? for shortcuts\n' | fm_busy_lines_match agy \
    && fail "agy's idle footer was misread as busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match agy \
    && fail "claude's exact busy token leaked into agy's harness-scoped matcher"
  printf 'esc to cancel\n' | fm_busy_lines_match claude \
    && fail "agy's busy token leaked into claude's harness-scoped matcher"

  out=$(fm_busy_classify tmux fake:0 agy taskid /nonexistent-state)
  [ "$out" = "unknown missing" ] || fail "agy with no record must classify 'unknown missing', got '$out'"
  pass "busy contract: agy trusts only its hook writer and its delivery token stays harness-scoped"
}

test_agy_tracked_hooks_refused() {
  local rec id=agy-tracked-z9 original out
  rec=$(make_spawn_case tracked "$id")
  read_case_record "$rec"
  mkdir -p "$WT_DIR/.agents"
  original='{"project":{},"fm-busy-state":{"Stop":[]}}'
  printf '%s\n' "$original" > "$WT_DIR/.agents/hooks.json"
  git -C "$WT_DIR" add .agents/hooks.json
  if out=$(fm_agy_hooks_install "$WT_DIR" "$HOME_DIR/state" "$id" gen \
    "$HOME_DIR/state/$id.turn-ended" "$ROOT" 2>&1); then
    fail "tracked hooks installation succeeded"
  fi
  [ "$(cat "$WT_DIR/.agents/hooks.json")" = "$original" ] || fail "tracked hooks changed"
  assert_absent "$HOME_DIR/state/$id.agy-hooks-mode" "refusal recorded an installation"
  pass "agy refuses tracked hooks before mutation"
}

test_agy_merge_retains_worker_edits() {
  local dir="$TMP_ROOT/worker-edits" hooks
  mkdir -p "$dir/wt/.agents" "$dir/state"
  hooks="$dir/wt/.agents/hooks.json"
  printf '%s\n' '{"project":1,"fm-busy-state":{"Stop":[]}}' > "$hooks"
  fm_agy_hooks_install "$dir/wt" "$dir/state" edit gen "$dir/state/end" "$ROOT" || fail "install failed"
  jq '.project = 2 | .added = true' "$hooks" > "$dir/edited"
  mv "$dir/edited" "$hooks"
  fm_agy_hooks_remove "$dir/wt" "$dir/state" edit || fail "remove failed"
  jq -e '. == {"project":2,"added":true,"fm-busy-state":{"Stop":[]}}' "$hooks" >/dev/null || fail "worker edits or original key lost"
  fm_agy_hooks_remove "$dir/wt" "$dir/state" edit || fail "repeat remove failed"
  jq -e '."fm-busy-state" == {"Stop":[]}' "$hooks" >/dev/null || fail "repeat removal lost project key"
  pass "agy removal preserves worker edits and original project key"
}

test_agy_concurrent_trust() {
  local rec id=agy-parallel-z10 n pid
  local -a pids=()
  rec=$(make_spawn_case parallel "$id")
  read_case_record "$rec"
  for n in 1 2 3 4 5 6 7 8; do
    git -C "$PROJ_DIR" worktree add -q -b "parallel-$n" "$CASE_DIR/wt-$n" || fail "worktree creation failed"
    HOME="$HOME_DIR/user-home" "$ROOT/bin/fm-agy-trust.sh" "$CASE_DIR/wt-$n" "$PROJ_DIR" > "$CASE_DIR/trust-$n.log" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "concurrent trust writer failed"
  done
  jq -e '.trustedWorkspaces | length == 8' "$HOME_DIR/user-home/.gemini/antigravity-cli/settings.json" >/dev/null || fail "concurrent trust lost entries"
  pass "agy concurrent trust retains every workspace"
}

test_agy_stale_trust_lock_is_broken() {
  local dir proj wt home store out
  dir="$TMP_ROOT/stale-lock"
  proj="$dir/project"
  wt="$dir/wt"
  home="$dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-stale"
  store="$home/.gemini/antigravity-cli"
  mkdir -p "$store"
  # A lock whose owner can never return: a dead pid with an ancient stamp, the
  # shape a SIGKILLed or OOM-killed helper leaves behind.
  mkdir -p "$store/.fm-trust.lock"
  printf '999999999:1\n' > "$store/.fm-trust.lock/owner"
  out=$(HOME="$home" "$ROOT/bin/fm-agy-trust.sh" "$wt" "$proj" 2>&1) \
    || fail "trust behind a stale lock refused: $out"
  assert_contains "$out" "trusted: " "stale-lock trust lacked its registration line"
  jq -e --arg wt "$wt" '.trustedWorkspaces | index($wt)' "$store/settings.json" >/dev/null \
    || fail "trust behind a stale lock lost the worktree entry"
  assert_absent "$store/.fm-trust.lock" "a broken stale lock was left behind"
  pass "agy breaks a dead-owner trust lock instead of wedging behind it"
}

test_agy_live_trust_lock_is_never_broken() {
  local dir proj wt home store out holder
  dir="$TMP_ROOT/live-lock"
  proj="$dir/project"
  wt="$dir/wt"
  home="$dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-live"
  store="$home/.gemini/antigravity-cli"
  mkdir -p "$store"
  # A live holder occupies the lock for a few seconds; the helper must wait
  # for its release rather than removing it, even across the mkdir-to-owner
  # write window a racing contender can observe.
  (
    mkdir "$store/.fm-trust.lock" 2>/dev/null || exit 0
    printf '%s:%s\n' "$$" "$(date +%s)" > "$store/.fm-trust.lock/owner"
    sleep 4
    rm -f "$store/.fm-trust.lock/owner"
    rmdir "$store/.fm-trust.lock" 2>/dev/null || true
  ) &
  holder=$!
  sleep 1
  out=$(HOME="$home" "$ROOT/bin/fm-agy-trust.sh" "$wt" "$proj" 2>&1) || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "trust behind a live lock refused: $out"
  }
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "trusted: " "live-lock trust lacked its registration line"
  jq -e --arg wt "$wt" '.trustedWorkspaces | index($wt)' "$store/settings.json" >/dev/null \
    || fail "trust behind a live lock lost the worktree entry"
  assert_absent "$store/.fm-trust.lock" "the live lock was left behind"
  pass "agy waits out a live trust lock instead of removing it"
}

test_agy_refused_teardown_preserves_wiring() {
  local rec id=agy-refuse-z11 mode out rc hooks state
  for mode in created merged; do
    rec=$(make_spawn_case "refuse-$mode" "$id")
    read_case_record "$rec"
    state="$HOME_DIR/state"
    hooks="$WT_DIR/.agents/hooks.json"
    mkdir -p "$WT_DIR/.agents"
    if [ "$mode" = merged ]; then
      printf '%s\n' '{"project":{},"fm-busy-state":{"Stop":[]}}' > "$hooks"
    fi
    fm_agy_hooks_install "$WT_DIR" "$state" "$id" gen "$state/$id.turn-ended" "$ROOT" || fail "install failed"
    cp "$hooks" "$CASE_DIR/hooks-before"
    cp "$state/$id.agy-hooks-mode" "$CASE_DIR/mode-before"
    if [ "$mode" = merged ]; then
      cp "$state/$id.agy-hooks-backup" "$CASE_DIR/backup-before"
    fi
    printf '%s\n' '.agents/hooks.json' >> "$PROJ_DIR/.git/info/exclude"
    git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unlanded
    fm_write_meta "$state/$id.meta" "window=firstmate:fm-$id" \
      "endpoint_task_id=$id" "worktree=$WT_DIR" "project=$PROJ_DIR" \
      'kind=ship' 'mode=local-only' 'harness=agy' 'spawn_gen=gen'
    fm_fake_exit0 "$FAKEBIN_DIR" no-mistakes gh gh-axi
    rc=0
    out=$(FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" PATH="$FAKEBIN_DIR:$PATH" \
      "$ROOT/bin/fm-teardown.sh" "$id" 2>&1) || rc=$?
    expect_code 1 "$rc" "unlanded teardown should refuse: $out"
    assert_contains "$out" 'not yet merged' "teardown did not reach the landed-work refusal"
    cmp -s "$hooks" "$CASE_DIR/hooks-before" || fail "refusal changed hooks"
    cmp -s "$state/$id.agy-hooks-mode" "$CASE_DIR/mode-before" || fail "refusal changed mode record"
    if [ "$mode" = merged ]; then
      cmp -s "$state/$id.agy-hooks-backup" "$CASE_DIR/backup-before" || fail "refusal changed backup"
    fi
    assert_present "$state/$id.meta" "refusal removed the task"
  done
  pass "agy refused teardown preserves created and merged hook wiring"
}

test_agy_refused_teardown_preserves_wiring

test_agy_tracked_hooks_refused
test_agy_merge_retains_worker_edits
test_agy_concurrent_trust
test_agy_stale_trust_lock_is_broken
test_agy_live_trust_lock_is_never_broken

test_agy_launch_carries_brief_with_native_model_effort
test_agy_effort_xhigh_is_recorded_but_omitted
test_agy_hooks_semantic_lifecycle
test_agy_hooks_merge_preserves_project_file
test_agy_hooks_created_file_is_removed
test_agy_trust_registers_worktree_and_refuses_primary
test_agy_missing_binary_refuses_before_pane_creation
test_agy_secondmate_is_refused
test_agy_detection_ancestry_is_anchored
test_agy_control_lib_table
test_agy_busy_source_and_delivery_regex_isolated
