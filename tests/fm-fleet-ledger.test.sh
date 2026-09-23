#!/usr/bin/env bash
# tests/fm-fleet-ledger.test.sh - the opt-in fleet activity ledger, driven
# through the real producers: bin/fm-spawn.sh (fake tmux, real git worktree),
# the real watcher through bin/fm-watch-checkpoint.sh, bin/fm-pr-check.sh,
# bin/fm-merge-local.sh, the shared PR merge outcome in bin/fm-merge-outcome-lib.sh, and
# bin/fm-teardown.sh. docs/fleet-ledger.md owns the record contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fleet-ledger)

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes
  printf '%s\n' "$fakebin"
}

# Sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN TASK for one isolated case.
make_case() {  # <name> <on|off>
  local dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"
  PROJ_DIR="$dir/sample"
  TASK="$1-t1"
  WT_DIR="$dir/wt"
  mkdir -p "$HOME_DIR/data/$TASK" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/user-home"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  touch "$HOME_DIR/state/.last-watcher-beat"
  [ "$2" = off ] || : > "$HOME_DIR/config/fleet-ledger"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$TASK"
  cat > "$HOME_DIR/data/$TASK/brief.md" <<EOF
# Task
## Captain's intent
Exercise the fleet ledger for $TASK.

## Firstmate spec
Nothing to build.
EOF
  FAKEBIN=$(make_fakebin "$dir")
}

in_home() {  # <command...>: run one real script against the case home
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN:$PATH" "$@"
}

# Spawn, write status lines, poll once, land locally, clean up.
run_lifecycle() {
  local out
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode local-only --yolo off 2>&1) \
    || fail "spawn failed: $out"
  {
    printf 'working [at=1790000000]: setup done\n'
    printf 'needs-decision [key=pick-one]: choose "a"\\b or c\n'
    printf 'resolved: [key=pick-one]  chose a\n'
    printf 'partial line without its newline'
  } >> "$HOME_DIR/state/$TASK.status"
  out=$(in_home env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 2>&1)
  case "$out" in *"checkpoint:"*|*"signal:"*) ;; *) fail "watcher checkpoint did not run: $out" ;; esac
  LEDGER_AFTER_POLL=$(cat "$HOME_DIR/state/fleet-ledger.jsonl" 2>/dev/null || true)
  printf ' finished\ndone: ready in branch\n' >> "$HOME_DIR/state/$TASK.status"
  printf 'landed\n' > "$WT_DIR/landed.txt"
  git -C "$WT_DIR" add landed.txt
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'landed'
  out=$(in_home "$ROOT/bin/fm-merge-local.sh" "$TASK" 2>&1) || fail "local merge failed: $out"
  out=$(in_home "$ROOT/bin/fm-teardown.sh" "$TASK" 2>&1) || fail "teardown failed: $out"
}

ledger_rows() {  # <jq filter>: print one compact row per ledger record
  jq -c "$1" "$HOME_DIR/state/fleet-ledger.jsonl"
}

test_flag_on_records_the_task_lifecycle() {
  local rows
  make_case on-lifecycle on
  run_lifecycle

  jq -e -s 'all(.[]; .v == 1 and (.ts | type) == "number" and (.task | type) == "string")' \
    "$HOME_DIR/state/fleet-ledger.jsonl" >/dev/null \
    || fail "every record must carry v, ts, event, and task: $(cat "$HOME_DIR/state/fleet-ledger.jsonl")"
  rows=$(ledger_rows '[.event, .task] + (del(.v, .ts, .event, .task) | to_entries | map(.value))')
  assert_equals "$(cat <<EOF
["task.dispatched","$TASK","ship","sample","claude",null]
["task.status","$TASK","working",null," setup done"]
["task.status","$TASK","needs-decision","pick-one"," choose \"a\"\\\\b or c"]
["task.status","$TASK","resolved","pick-one"," [key=pick-one]  chose a"]
["task.status","$TASK",null,null,"partial line without its newline finished"]
["task.status","$TASK","done",null," ready in branch"]
["task.merged","$TASK","local"]
["task.cleaned_up","$TASK"]
EOF
)" "$rows" "ledger rows"
  assert_not_contains "$LEDGER_AFTER_POLL" "partial line" "the poll recorded a line before its newline arrived"
  assert_contains "$LEDGER_AFTER_POLL" '"state":"needs-decision"' "the watcher poll did not record the status lines"
  assert_absent "$HOME_DIR/state/.$TASK.fleet-ledger-offset" "cleanup left the task's ledger offset behind"
  pass "flag on: dispatch, polled status lines, the local merge after its task's pending lines, and cleanup are recorded in order"
}

test_flag_on_records_a_pr_merge_once() {
  local pr_url=https://github.com/acme/sample/pull/7 rows
  make_case on-pr on
  mkdir -p "$HOME_DIR/state"
  printf 'done: PR %s checks green\n' "$pr_url" > "$HOME_DIR/state/$TASK.status"
  (
    # shellcheck source=bin/fm-merge-outcome-lib.sh
    . "$ROOT/bin/fm-merge-outcome-lib.sh"
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" fm_merge_outcome_report "$HOME_DIR" "$HOME_DIR/state" "$TASK" "$pr_url" self \
      || fail "the merge outcome was not recorded"
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" fm_merge_outcome_report "$HOME_DIR" "$HOME_DIR/state" "$TASK" "$pr_url" poll \
      || fail "the repeated merge outcome failed"
  ) || exit 1
  rows=$(ledger_rows '[.event, .state, .via, .pr]')
  assert_equals "$(cat <<EOF
["task.status","done",null,null]
["task.merged",null,"pr","$pr_url"]
EOF
)" "$rows" "PR merge rows"
  pass "flag on: a PR merge is recorded once, after the task's pending status lines"
}

test_flag_on_records_a_pr_registration() {
  local pr_url=https://github.com/acme/sample/pull/9 rows out
  make_case on-pr-ready on
  # An unreadable forge answer: no draft refusal and no recorded head.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
  out=$(in_home "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ_DIR" --mode direct-PR --yolo off 2>&1) \
    || fail "spawn failed: $out"
  printf 'done: PR %s\n' "$pr_url" >> "$HOME_DIR/state/$TASK.status"
  out=$(in_home "$ROOT/bin/fm-pr-check.sh" "$TASK" "$pr_url" 2>&1) || fail "PR registration failed: $out"
  out=$(in_home env FM_PR_CHECK_MERGE=1 "$ROOT/bin/fm-pr-check.sh" "$TASK" "$pr_url" 2>&1) \
    || fail "merge-time PR re-record failed: $out"
  rows=$(ledger_rows '[.event, .state, .pr]')
  assert_equals "$(cat <<EOF
["task.dispatched",null,null]
["task.status","done",null]
["task.pr_ready",null,"$pr_url"]
EOF
)" "$rows" "PR registration rows"
  pass "flag on: registering a PR records task.pr_ready with its full URL after the task's pending status lines, and the merge-time re-record adds nothing"
}

# Scaffold a real brief for TASK and print its status command, filled the way a
# worker fills it.
# Optional arguments are the scaffold's state and config overrides; the
# scaffold runs from the home, so a relative config override names its config/.
worker_status_command() {  # <state> <note> [<state-dir> [<config-dir>]]
  local cmd
  rm -rf "${HOME_DIR:?}/data/$TASK"
  (cd "$HOME_DIR" && in_home env FM_STATE_OVERRIDE="${3:-$HOME_DIR/state}" \
    FM_CONFIG_OVERRIDE="${4:-$HOME_DIR/config}" \
    "$ROOT/bin/fm-brief.sh" "$TASK" sample --mode no-mistakes >/dev/null) \
    || fail "brief scaffold failed"
  # shellcheck disable=SC2016 # Match literal backticks in the generated brief.
  cmd=$(sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$HOME_DIR/data/$TASK/brief.md" | head -1)
  [ -n "$cmd" ] || fail "the brief carries no status command"
  cmd=${cmd//\{state\}/$1}
  cmd=${cmd//<epoch>/1790000000}
  printf '%s\n' "${cmd//\{one short line\}/$2}"
}

# Run a filled status command as a worker would: a plain shell with no
# firstmate environment.
run_worker_command() {  # <command>
  env -i PATH="$PATH" HOME="$HOME_DIR/user-home" bash -c "$1"
}

test_worker_status_line_is_recorded_when_written() {
  local out
  make_case on-immediate on
  mkdir -p "$HOME_DIR/data"
  out=$(run_worker_command "$(worker_status_command needs-decision 'pick a lamp colour')" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals "needs-decision [at=1790000000]: pick a lamp colour" \
    "$(cat "$HOME_DIR/state/$TASK.status")" "status log"
  assert_equals '["task.status","needs-decision"," pick a lamp colour"]' \
    "$(ledger_rows '[.event, .state, .text]')" "ledger rows right after the append"
  out=$(in_home "$ROOT/bin/fm-fleet-ledger.sh" capture 2>&1) || fail "backstop capture failed: $out"
  assert_equals 1 "$(wc -l < "$HOME_DIR/state/fleet-ledger.jsonl" | tr -d ' ')" \
    "ledger records after the backstop capture"
  pass "flag on: a worker's status command records its line at once, and the watcher backstop does not record it again"
}

test_worker_status_line_is_recorded_under_a_state_override() {
  local out state_dir
  make_case on-state-override on
  state_dir="$TMP_ROOT/on-state-override/elsewhere/state"
  mkdir -p "$HOME_DIR/data" "$state_dir"
  out=$(run_worker_command "$(worker_status_command blocked 'need a token' "$state_dir")" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals "blocked [at=1790000000]: need a token" "$(cat "$state_dir/$TASK.status")" "status log"
  assert_equals '["task.status","blocked"]' \
    "$(jq -c '[.event, .state]' "$state_dir/fleet-ledger.jsonl" 2>/dev/null)" \
    "ledger rows right after the append"
  pass "flag on, state override outside the home: the worker's status command records its line at once"
}

test_worker_status_line_is_recorded_under_a_relative_config_override() {
  local out
  make_case on-relative-config on
  mkdir -p "$HOME_DIR/data"
  out=$(cd "$PROJ_DIR" && run_worker_command \
    "$(worker_status_command needs-decision 'which lamp' "$HOME_DIR/state" config)" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals '["task.status","needs-decision"]' "$(ledger_rows '[.event, .state]')" \
    "ledger rows right after the append"
  pass "flag on, relative config override: a worker running elsewhere still records its line at once"
}

test_worker_status_command_fails_when_the_append_fails() {
  local out rc=0
  make_case on-append-fails on
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state/$TASK.status"
  out=$(run_worker_command "$(worker_status_command failed 'tests broke')" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the worker status command succeeded although its append failed: $out"
  [ ! -e "$HOME_DIR/state/fleet-ledger.jsonl" ] || fail "a failed append still wrote a ledger record"
  pass "append failing: the worker's status command exits nonzero and records nothing"
}

test_worker_status_line_lands_when_the_ledger_fails() {
  local out
  make_case on-failing on
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/state/fleet-ledger.jsonl"
  out=$(run_worker_command "$(worker_status_command failed 'tests broke')" 2>&1) \
    || fail "a ledger failure changed the worker status command's result: $out"
  assert_equals "" "$out" "worker status command output"
  assert_equals "failed [at=1790000000]: tests broke" \
    "$(cat "$HOME_DIR/state/$TASK.status")" "status log"
  rmdir "$HOME_DIR/state/fleet-ledger.jsonl"
  out=$(in_home "$ROOT/bin/fm-fleet-ledger.sh" capture 2>&1) || fail "backstop capture failed: $out"
  assert_equals '["task.status","failed"]' "$(ledger_rows '[.event, .state]')" \
    "ledger rows after the backstop capture"
  pass "ledger failing: the worker's status line still lands exactly, quietly, and the backstop records it later"
}

test_worker_status_line_with_the_flag_absent() {
  local out leftovers
  make_case off-immediate off
  mkdir -p "$HOME_DIR/data"
  out=$(run_worker_command "$(worker_status_command 'done' 'ready')" 2>&1) \
    || fail "the worker status command failed: $out"
  assert_equals "" "$out" "worker status command output"
  assert_equals "done [at=1790000000]: ready" "$(cat "$HOME_DIR/state/$TASK.status")" "status log"
  leftovers=$(cd "$HOME_DIR/state" && find . -name '*fleet-ledger*')
  assert_equals "" "$leftovers" "ledger files with the flag absent"
  pass "flag off: the worker's status command is a plain append and leaves no ledger file, offset, or lock"
}

test_flag_off_writes_nothing() {
  local leftovers
  make_case off-lifecycle off
  run_lifecycle
  leftovers=$(cd "$HOME_DIR/state" && find . -name '*fleet-ledger*')
  assert_equals "" "$leftovers" "ledger files with the flag absent"
  pass "flag off: the whole lifecycle leaves no ledger file, offset, or lock"
}

test_flag_on_records_the_task_lifecycle
test_flag_on_records_a_pr_merge_once
test_flag_on_records_a_pr_registration
test_worker_status_line_is_recorded_when_written
test_worker_status_line_is_recorded_under_a_state_override
test_worker_status_line_is_recorded_under_a_relative_config_override
test_worker_status_command_fails_when_the_append_fails
test_worker_status_line_lands_when_the_ledger_fails
test_worker_status_line_with_the_flag_absent
test_flag_off_writes_nothing
