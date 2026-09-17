#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --executor: the one-shot headless task kind.
#
# These drive the real fm-spawn through meta writing, branch creation, poll
# publication, and launch construction over a fake tmux pane and a real
# isolated git worktree, exactly like tests/fm-spawn-dispatch-profile.test.sh.
# The fake tmux captures the literal launch command, so the assertions pin the
# command firstmate would run without starting any real harness.
#   (a) meta fields, fm/<id> pre-created at the recorded base, the byte-static
#       poll published as the task's check, the pull-request body excluded from
#       git, no busy-state or hook wiring, and launch-brief.md as the brief verbatim
#   (b) the verified headless templates per adapter, with the shell-written exit
#       marker appended after every launch
#   (c) refusals: --mode, a second kind flag, a missing or malformed --issue, a
#       missing --yolo, --issue on a ship spawn, an adapter without a headless
#       form, a batch pair, and --relaunch --issue
#   (d) brief/spawn kind and issue agreement in both directions
#   (e) a raw launch command receives the encoded brief as its final argument
#   (f) the registry-deviation notice on a no-mistakes project, and silence on
#       a direct-PR one
#   (g) fm_executor_origin_issue_url resolves github.com origins only
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-executor-lib.sh"

BRIEF_BIN="$ROOT/bin/fm-brief.sh"
POLL="$ROOT/bin/fm-executor-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-executor)
OPINPUT="'$ROOT/bin/fm-operational-input.sh' encode launch-brief"

make_case() {  # <name> -> echoes "<case>|<home>|<proj>|<wt>|<fakebin>|<launchlog>"
  local name=$1 case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

executor_brief() {  # <home> <id> <issue>
  FM_ROOT_OVERRIDE='' FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" FM_STATE_OVERRIDE="$1/state" \
    "$BRIEF_BIN" "$2" project --executor --issue "$3" --verify 'make ci' >/dev/null
}

ship_brief() {  # <home> <id>
  fm_test_spawn_brief "$1" "$2"
}

run_spawn() {  # <home> <wt> <fakebin> <launchlog> <args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

launch_line() {  # <launchlog>
  tail -n 1 "$1"
}

test_executor_spawn_records_meta_branch_and_poll() {
  local rec id out rc meta launch expected base exclude
  id=exec-spawn-a1
  rec=$(make_case meta); read_case "$rec"
  executor_brief "$HOME_DIR" "$id" 7
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 7 --yolo off --harness opencode); rc=$?
  expect_code 0 "$rc" "executor spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=opencode kind=executor mode=direct-PR yolo=off issue=7" "success line names the kind, implied mode, yolo, and issue"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'kind=executor' "$meta" "meta kind"
  assert_grep 'mode=direct-PR' "$meta" "meta records the implied direct-PR mode"
  assert_grep 'yolo=off' "$meta" "meta yolo"
  assert_grep 'issue=7' "$meta" "meta issue"
  assert_no_grep 'issue_url=' "$meta" "a file:// origin resolves no GitHub issue URL"
  assert_no_grep 'busy_gen=' "$meta" "an executor arms no busy-state contract"
  grep -q '^executor_launched=[0-9][0-9]*$' "$meta" || fail "meta must record the launch epoch"
  [ "$(git -C "$WT_DIR" branch --show-current)" = "fm/$id" ] || fail "fm/$id must be checked out before launch"
  base=$(git -C "$WT_DIR" rev-parse HEAD)
  assert_grep "executor_base=$base" "$meta" "meta records the branch base commit"
  cmp -s "$POLL" "$HOME_DIR/state/$id.check.sh" || fail "state/$id.check.sh must be a byte copy of the executor poll"
  [ "$(fm_pr_file_mode "$HOME_DIR/state/$id.check.sh")" = 600 ] || fail "the published poll must be private"
  fm_executor_poll_snapshot_capture "$HOME_DIR/state" "$id" "$POLL" || fail "the published poll must validate against the meta"
  exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_grep '.fm-pr-body.md' "$exclude" "the pull-request body file is excluded from git"
  [ ! -e "$WT_DIR/.opencode/plugins/fm-busy-state.js" ] || fail "an executor must get no opencode busy plugin"
  cmp -s "$HOME_DIR/data/$id/brief.md" "$HOME_DIR/data/$id/launch-brief.md" \
    || fail "launch-brief.md must be the executor brief verbatim (no worker role or intent overlay)"
  launch=$(launch_line "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode run \"\$($OPINPUT < '$HOME_DIR/data/$id/launch-brief.md')\"; printf '%s\\n' \"\$?\" > '$HOME_DIR/state/$id.executor-exit'"
  [ "$launch" = "$expected" ] || fail "opencode executor launch mismatch"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "executor spawn: meta, pre-created branch at its base, published poll, excluded PR body, verbatim launch brief"
}

test_headless_templates_per_adapter() {
  local rec id out rc launch
  id=exec-tpl-b1
  rec=$(make_case claude); read_case "$rec"
  executor_brief "$HOME_DIR" "$id" 9
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 9 --yolo on --harness claude --model sonnet --effort high); rc=$?
  expect_code 0 "$rc" "claude executor spawn should succeed: $out"
  launch=$(launch_line "$LAUNCH_LOG")
  assert_contains "$launch" "claude -p --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' --model 'sonnet' --effort 'high' --output-format text \"\$($OPINPUT < '$HOME_DIR/data/$id/launch-brief.md')\"" \
    "claude headless form: -p, the permission flag, attribution settings, model, effort, text output, brief last"
  assert_not_contains "$launch" '--append-system-prompt' "the one-shot form carries no interactive task channel"
  assert_contains "$launch" "; printf '%s\\n' \"\$?\" > '$HOME_DIR/state/$id.executor-exit'" "the pane shell writes the exit marker"
  [ ! -e "$WT_DIR/.claude/settings.local.json" ] || fail "an executor must get no claude hook settings"
  assert_grep 'yolo=on' "$HOME_DIR/state/$id.meta" "yolo on is recorded"

  id=exec-tpl-b2
  rec=$(make_case codex); read_case "$rec"
  executor_brief "$HOME_DIR" "$id" 9
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 9 --yolo off --harness codex --model gpt-5 --effort high); rc=$?
  expect_code 0 "$rc" "codex executor spawn should succeed: $out"
  launch=$(launch_line "$LAUNCH_LOG")
  assert_contains "$launch" "codex exec --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox --disable hooks \"\$($OPINPUT < '$HOME_DIR/data/$id/launch-brief.md')\"" \
    "codex headless form: exec, model, reasoning effort, bypass, hooks off, brief last"
  assert_not_contains "$launch" 'notify=' "the one-shot form carries no turn-end notify program"
  [ ! -e "$HOME_DIR/state/$id.turn-ended" ] || fail "no turn-end marker is armed"

  id=exec-tpl-b3
  rec=$(make_case opencode-model); read_case "$rec"
  executor_brief "$HOME_DIR" "$id" 9
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 9 --yolo off --harness opencode --model 'vendor/model' --effort high); rc=$?
  expect_code 0 "$rc" "opencode executor spawn with a model should succeed: $out"
  launch=$(launch_line "$LAUNCH_LOG")
  assert_contains "$launch" "opencode run --model 'vendor/model' \"\$(" "opencode threads the model"
  assert_not_contains "$launch" 'high' "opencode omits the unmapped effort axis from the launch"
  assert_grep 'effort=high' "$HOME_DIR/state/$id.meta" "the omitted effort is still recorded"
  pass "headless templates: claude -p, codex exec, opencode run, each with the exit marker appended"
}

test_executor_refusals() {
  local rec id out rc
  id=exec-ref-c1
  rec=$(make_case refusals); read_case "$rec"
  executor_brief "$HOME_DIR" "$id" 3
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 3 --yolo off --mode direct-PR --harness opencode); rc=$?
  expect_code 1 "$rc" "--mode with --executor must refuse"
  assert_contains "$out" 'inherently direct-PR' "the mode refusal explains itself"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --scout --issue 3 --yolo off --harness opencode); rc=$?
  expect_code 1 "$rc" "--scout with --executor must refuse"
  assert_contains "$out" 'exactly one' "conflicting kind flags are named"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --yolo off --harness opencode); rc=$?
  expect_code 1 "$rc" "a missing --issue must refuse"
  assert_contains "$out" 'require --issue' "the missing issue names the flag"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 0x1 --yolo off --harness opencode); rc=$?
  expect_code 1 "$rc" "a malformed --issue must refuse"
  assert_contains "$out" 'positive integer' "the malformed issue names the shape"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 3 --harness opencode); rc=$?
  expect_code 1 "$rc" "a missing --yolo must refuse"
  assert_contains "$out" 'require --yolo' "merge authority stays required"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 3 --yolo off --harness pi); rc=$?
  expect_code 1 "$rc" "an adapter without a headless form must refuse"
  assert_contains "$out" "harness 'pi' has no verified headless one-shot form" "the refusal names the adapter"
  assert_contains "$out" 'claude codex opencode' "the refusal names the verified set"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 3 --yolo off --harness cursor); rc=$?
  expect_code 1 "$rc" "cursor must refuse for --executor"
  assert_contains "$out" "harness 'cursor' has no verified headless" "the cursor refusal names the adapter"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id=$PROJ_DIR" --executor --issue 3 --yolo off --harness opencode); rc=$?
  [ "$rc" -ne 0 ] || fail "a batch pair with --executor must refuse"
  assert_contains "$out" 'batch dispatch does not support --executor' "batch refusal names the flag"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --relaunch --issue 4 --harness opencode); rc=$?
  expect_code 1 "$rc" "--relaunch --issue must refuse"
  assert_contains "$out" "reuses the task's recorded issue" "relaunch keeps the recorded issue"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must publish no record"
  [ "$(git -C "$WT_DIR" branch --show-current)" != "fm/$id" ] || fail "a refused spawn must create no branch"
  ship_brief "$HOME_DIR" ship-ref-c2
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" ship-ref-c2 "$PROJ_DIR" --mode direct-PR --yolo off --issue 3 --harness opencode); rc=$?
  expect_code 1 "$rc" "--issue on a ship spawn must refuse"
  assert_contains "$out" 'applies only to --executor' "the ship refusal names the executor flag"
  pass "executor refusals: mode, kind conflicts, issue, yolo, non-headless adapters, batch, relaunch --issue"
}

test_brief_and_spawn_kind_agreement() {
  local rec out rc
  rec=$(make_case agreement); read_case "$rec"
  ship_brief "$HOME_DIR" exec-agree-d1
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" exec-agree-d1 "$PROJ_DIR" --executor --issue 5 --yolo off --harness opencode); rc=$?
  expect_code 1 "$rc" "a ship brief must refuse an executor spawn"
  assert_contains "$out" 'is not an executor brief' "the refusal names the missing contract"
  executor_brief "$HOME_DIR" ship-agree-d2 5
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" ship-agree-d2 "$PROJ_DIR" --mode direct-PR --yolo off --harness opencode); rc=$?
  expect_code 1 "$rc" "an executor brief must refuse a ship spawn"
  assert_contains "$out" 'is an executor brief' "the refusal names the kind"
  assert_contains "$out" '--executor --issue 5' "the refusal names the correct spawn"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" ship-agree-d2 "$PROJ_DIR" --scout --harness opencode); rc=$?
  expect_code 1 "$rc" "an executor brief must refuse a scout spawn"
  executor_brief "$HOME_DIR" exec-agree-d3 7
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" exec-agree-d3 "$PROJ_DIR" --executor --issue 8 --yolo off --harness opencode); rc=$?
  expect_code 1 "$rc" "an issue mismatch must refuse"
  assert_contains "$out" 'issue mismatch' "the refusal names the mismatch"
  assert_contains "$out" 'closes issue #7' "the refusal names the brief's issue"
  [ ! -e "$HOME_DIR/state/exec-agree-d3.meta" ] || fail "a refused spawn must publish no record"
  pass "brief and spawn agree on kind and issue in both directions"
}

test_raw_command_receives_brief_as_final_argument() {
  local rec id out rc launch
  id=exec-raw-e1
  rec=$(make_case raw); read_case "$rec"
  executor_brief "$HOME_DIR" "$id" 11
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 11 --yolo off --harness 'mytool run --fast'); rc=$?
  expect_code 0 "$rc" "a raw executor command should launch: $out"
  assert_contains "$out" "spawned $id harness=mytool kind=executor" "the raw command's basename is recorded"
  launch=$(launch_line "$LAUNCH_LOG")
  [ "$launch" = "mytool run --fast \"\$($OPINPUT < '$HOME_DIR/data/$id/launch-brief.md')\"; printf '%s\\n' \"\$?\" > '$HOME_DIR/state/$id.executor-exit'" ] \
    || fail "the raw command must receive the encoded brief as its final argument, got: $launch"
  id=exec-raw-e2
  rec=$(make_case raw-placed); read_case "$rec"
  executor_brief "$HOME_DIR" "$id" 11
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 11 --yolo off --harness 'mytool --brief __BRIEF__ run'); rc=$?
  expect_code 0 "$rc" "a raw command naming __BRIEF__ should launch: $out"
  launch=$(launch_line "$LAUNCH_LOG")
  [ "$launch" = "mytool --brief '$HOME_DIR/data/$id/launch-brief.md' run; printf '%s\\n' \"\$?\" > '$HOME_DIR/state/$id.executor-exit'" ] \
    || fail "a raw command that places __BRIEF__ itself must keep that placement, got: $launch"
  pass "a raw executor command receives the encoded brief last unless it places __BRIEF__ itself"
}

test_registry_deviation_notice() {
  local rec id out rc
  id=exec-reg-f1
  rec=$(make_case registry); read_case "$rec"
  printf '%s\n' '- project [no-mistakes] - fixture (added 2026-07-01)' > "$HOME_DIR/data/projects.md"
  executor_brief "$HOME_DIR" "$id" 2
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 2 --yolo off --harness opencode); rc=$?
  expect_code 0 "$rc" "the notice never blocks the spawn: $out"
  assert_contains "$out" "notice: $id is an executor (mode=direct-PR) while the standing posture for project is no-mistakes" "the deviation notice is printed"
  id=exec-reg-f2
  rec=$(make_case registry-direct); read_case "$rec"
  printf '%s\n' '- project [direct-PR] - fixture (added 2026-07-01)' > "$HOME_DIR/data/projects.md"
  executor_brief "$HOME_DIR" "$id" 2
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --executor --issue 2 --yolo off --harness opencode); rc=$?
  expect_code 0 "$rc" "a direct-PR project spawns cleanly: $out"
  assert_not_contains "$out" 'notice:' "no notice when the standing posture is already direct-PR"
  pass "an executor on a no-mistakes project prints the deviation notice and continues"
}

test_origin_issue_url_resolution() {
  local repo url
  repo="$TMP_ROOT/origin-url"
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin git@github.com:Acme-Org/widget.git
  url=$(fm_executor_origin_issue_url "$repo" 12) || fail "an ssh github origin must resolve"
  [ "$url" = 'https://github.com/Acme-Org/widget/issues/12' ] || fail "unexpected issue URL: $url"
  git -C "$repo" remote set-url origin https://github.com/Acme-Org/widget
  url=$(fm_executor_origin_issue_url "$repo" 12) || fail "an https github origin must resolve"
  [ "$url" = 'https://github.com/Acme-Org/widget/issues/12' ] || fail "unexpected https issue URL: $url"
  git -C "$repo" remote set-url origin https://gitlab.example.com/group/widget.git
  ! fm_executor_origin_issue_url "$repo" 12 >/dev/null || fail "a non-GitHub origin must resolve no URL"
  ! fm_executor_origin_issue_url "$repo" 0 >/dev/null || fail "an invalid issue must resolve no URL"
  pass "issue URLs come only from a github.com origin"
}

test_executor_spawn_records_meta_branch_and_poll
test_headless_templates_per_adapter
test_executor_refusals
test_brief_and_spawn_kind_agreement
test_raw_command_receives_brief_as_final_argument
test_registry_deviation_notice
test_origin_issue_url_resolution
