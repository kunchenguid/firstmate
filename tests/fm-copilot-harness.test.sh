#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)

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
  send-keys)
    if [ -n "${FM_FAKE_TMUX_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    fi
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
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
  id="copilot-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_copilot_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

test_copilot_spawn_installs_worktree_hook() {
  local rec case_dir home proj wt fakebin id out status hook excl
  rec=$(make_spawn_case hook)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" copilot)
  status=$?
  expect_code 0 "$status" "copilot spawn should succeed"
  assert_contains "$out" "spawned $id harness=copilot" "copilot spawn did not report success"

  hook="$wt/.github/hooks/fm-turn-end.$id.json"
  assert_present "$hook" "copilot turn-end hook was not installed in the worktree"
  assert_grep 'agentStop' "$hook" "copilot hook did not register the agentStop event"
  assert_grep "$home/state/$id.turn-ended" "$hook" "copilot hook did not point at this task's turn-ended marker"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_grep ".github/hooks/fm-turn-end.$id.json" "$excl" "copilot hook path was not gitignored"
  pass "copilot spawn installs a worktree-resident agentStop hook"
}

test_copilot_spawn_does_not_clobber_existing_hook_file() {
  local rec case_dir home proj wt fakebin id out status existing
  rec=$(make_spawn_case preserve-existing)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  mkdir -p "$wt/.github/hooks"
  existing="$wt/.github/hooks/fm-turn-end.json"
  printf '%s\n' '{"version":1,"hooks":{"agentStop":[{"type":"command","command":"echo project-hook"}]}}' > "$existing"

  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" copilot)
  status=$?
  expect_code 0 "$status" "copilot spawn should succeed with an existing hook file"
  assert_contains "$out" "spawned $id harness=copilot" "copilot spawn did not report success"
  assert_grep 'echo project-hook' "$existing" "copilot spawn clobbered a pre-existing hook file"
  pass "copilot spawn preserves existing hook files in the worktree"
}

test_copilot_spawn_hook_command_handles_single_quote_paths() {
  local rec case_dir home proj wt fakebin id out status hook cmd_json cmd
  rec=$(make_spawn_case "quote-'path")
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" copilot)
  status=$?
  expect_code 0 "$status" "copilot spawn in a quote-containing path should succeed"
  hook="$wt/.github/hooks/fm-turn-end.$id.json"
  assert_present "$hook" "copilot hook was not installed for quote-path case"
  cmd_json=$(sed -n 's/.*"command":"\([^"]*\)".*/\1/p' "$hook")
  [ -n "$cmd_json" ] || fail "copilot hook command was not extracted"
  cmd=$(printf '%s' "$cmd_json" | sed 's/\\"/"/g; s/\\\\/\\/g')
  rm -f "$home/state/$id.turn-ended"
  bash -c "$cmd"
  assert_present "$home/state/$id.turn-ended" "copilot hook command failed for single-quote path"
  pass "copilot hook command remains executable in single-quote paths"
}

test_copilot_spawn_threads_model_and_effort() {
  local rec case_dir home proj wt fakebin id out status meta
  rec=$(make_spawn_case flags)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --harness copilot --model gpt-5.5 --effort high)
  status=$?
  expect_code 0 "$status" "copilot spawn with model/effort should succeed"
  assert_contains "$out" "harness=copilot" "copilot spawn did not record harness in output"
  meta="$home/state/$id.meta"
  assert_present "$meta" "copilot spawn did not write meta"
  assert_grep 'model=gpt-5.5' "$meta" "copilot spawn did not record the requested model"
  assert_grep 'effort=high' "$meta" "copilot spawn did not record the requested effort"
  pass "copilot spawn threads model and effort into meta"
}

test_copilot_spawn_accepts_none_effort() {
  local rec case_dir home proj wt fakebin id out status meta
  rec=$(make_spawn_case none-effort)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --harness copilot --model gpt-5.5 --effort none)
  status=$?
  expect_code 0 "$status" "copilot spawn with none effort should succeed"
  assert_contains "$out" "harness=copilot" "copilot spawn did not record harness in output"
  meta="$home/state/$id.meta"
  assert_present "$meta" "copilot spawn did not write meta for none effort"
  assert_grep 'model=gpt-5.5' "$meta" "copilot spawn did not record the requested model for none effort"
  assert_grep 'effort=none' "$meta" "copilot spawn did not record effort=none"
  pass "copilot spawn accepts and records none effort"
}

test_copilot_spawn_uses_brief_path_pointer_prompt() {
  local rec case_dir home proj wt fakebin id out status log brief_token
  rec=$(make_spawn_case argv-pointer)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  brief_token="INLINE_BRIEF_TOKEN_SHOULD_NOT_APPEAR"
  printf '%s\n' "$brief_token" > "$home/data/$id/brief.md"
  log="$case_dir/tmux-send-keys.log"
  out=$(FM_FAKE_TMUX_LOG="$log" run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" copilot)
  status=$?
  expect_code 0 "$status" "copilot spawn should succeed with pointer prompt launch"
  assert_contains "$out" "harness=copilot" "copilot spawn did not report harness in output"
  assert_present "$log" "fake tmux send-keys log was not captured"
  assert_grep 'Read and follow the instructions in this file exactly:' "$log" "copilot launch did not use the brief-path pointer prompt"
  if grep -q "$brief_token" "$log"; then
    fail "copilot launch inlined brief content into argv instead of using a brief-path pointer prompt"
  fi
  pass "copilot spawn uses a brief-path pointer prompt and does not inline brief content"
}

test_fm_harness_detects_copilot_env_marker() {
  local out
  out=$(COPILOT_CLI=1 CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' "$HARNESS")
  [ "$out" = "copilot" ] || fail "fm-harness.sh did not detect COPILOT_CLI=1 (got: '$out')"
  pass "fm-harness.sh detects the copilot env marker"
}

test_fm_harness_detects_copilot_mainthread_ancestry() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/harness-mainthread-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/user/.cache/github-copilot-sdk/cli/1.0.0/copilot --server --stdio --no-auto-update'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(COPILOT_CLI='' CLAUDECODE='' PI_CODING_AGENT='' GROK_AGENT='' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = "copilot" ] || fail "fm-harness.sh did not detect copilot from MainThread ancestry (got: '$out')"
  pass "fm-harness.sh detects copilot in MainThread ancestry"
}

test_fm_lock_recognizes_copilot_mainthread_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  # copilot's --server --stdio child reports comm=MainThread, not "copilot";
  # only the args carry the harness name. Regression coverage for the generic-
  # comm fallback in harness_pid()/holder_alive() (bin/fm-lock.sh).
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/user/.cache/github-copilot-sdk/cli/1.0.0/copilot --server --stdio --no-auto-update'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize copilot's generic-comm (MainThread) server process as a live holder"
  pass "fm-lock recognizes copilot's generic-comm (MainThread) server process"
}

test_fm_lock_ignores_unrelated_gh_copilot_process() {
  local home fakebin out
  home="$TMP_ROOT/lock-ignore-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-ignore-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  # An unrelated `gh copilot suggest` process has comm=gh (not a known
  # interpreter), so its args must never be scanned for "copilot" -
  # regression coverage for review finding F1 (args-scan false positive).
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'gh'; exit 0 ;;
  *"args="*) printf '%s\n' 'gh copilot suggest "list files"'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: stale" "fm-lock incorrectly recognized an unrelated 'gh copilot suggest' process as a harness holder"
  pass "fm-lock ignores an unrelated 'gh copilot suggest' process"
}

test_copilot_spawn_installs_worktree_hook
test_copilot_spawn_does_not_clobber_existing_hook_file
test_copilot_spawn_hook_command_handles_single_quote_paths
test_copilot_spawn_threads_model_and_effort
test_copilot_spawn_accepts_none_effort
test_copilot_spawn_uses_brief_path_pointer_prompt
test_fm_harness_detects_copilot_env_marker
test_fm_harness_detects_copilot_mainthread_ancestry
test_fm_lock_recognizes_copilot_mainthread_holder
test_fm_lock_ignores_unrelated_gh_copilot_process
