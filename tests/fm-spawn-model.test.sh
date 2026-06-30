#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh per-task model selection (`--model <name>`).
#
# These run fm-spawn through to the meta-write and launch construction, so unlike
# the batch test (which fails fast at the missing-brief check) they need a real
# isolated worktree and a fake tmux/treehouse. The fake tmux also captures every
# literal (`-l`) send-keys payload - the constructed launch line - to
# FM_FAKE_LAUNCH_LOG so a test can assert on what would actually be launched.
#
# The crew harness is pinned to claude via config/crew-harness so the launch is
# deterministic and exercises the only adapter --model is wired for today.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-model)

# Fake tmux/treehouse: enough for a claude spawn to reach the meta-write and the
# launch send-keys, with no real terminal or worktree machinery. The pane path is
# served from FM_FAKE_PANE_PATH (the isolation guard then validates it as a real,
# separate worktree), and every literal send-keys payload is appended to
# FM_FAKE_LAUNCH_LOG when that variable is set.
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
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" = "-l" ] && printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        prev=$a
      done
    fi
    exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> [id...]: build an isolated home with a claude-pinned crew
# harness, one project + worktree, and a brief for each given id. Echoes a
# pipe-joined record: case_dir|home|proj|wt|fakebin|launchlog
make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief\n' > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

# run_spawn <home> <wt> <fakebin> <launchlog> <spawn-args...>
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# --model <name> is recorded as model=<name> in the task meta and threaded into
# the claude launch as a --model flag.
test_model_flag_threaded_for_claude() {
  local rec case_dir home proj wt fakebin launchlog id out status
  rec=$(make_spawn_case model-on model-on-z1)
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF
  id=model-on-z1
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj" --model sonnet)
  status=$?
  expect_code 0 "$status" "claude spawn with --model should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report a claude launch"
  assert_contains "$out" "model=sonnet" "spawn report did not echo model=sonnet"
  assert_grep 'model=sonnet' "$home/state/$id.meta" "meta did not record model=sonnet"
  assert_grep '--model' "$launchlog" "claude launch did not thread the --model flag"
  assert_grep 'sonnet' "$launchlog" "claude launch did not carry the model name"
  pass "--model sonnet records model=sonnet in meta and threads --model into the claude launch"
}

# With no --model the meta records model=default and the launch is byte-for-byte
# today's: no --model flag at all.
test_no_model_is_todays_launch() {
  local rec case_dir home proj wt fakebin launchlog id out status
  rec=$(make_spawn_case model-off model-off-z2)
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF
  id=model-off-z2
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "claude spawn without --model should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report a claude launch"
  assert_contains "$out" "model=default" "spawn report did not echo model=default"
  assert_grep 'model=default' "$home/state/$id.meta" "meta did not record model=default"
  assert_no_grep '--model' "$launchlog" "no-model launch must not carry a --model flag"
  # The $(cat ...) here is a literal substring of the launch command, not an
  # expansion we want evaluated.
  # shellcheck disable=SC2016
  assert_grep 'claude --dangerously-skip-permissions "$(cat ' "$launchlog" \
    "no-model launch is not today's claude launch form"
  pass "no --model records model=default and leaves the claude launch as today's"
}

# A batch (id=repo pairs) forwards a single shared --model to each spawned task.
test_batch_forwards_shared_model() {
  local rec case_dir home proj wt fakebin launchlog id1 id2 out status
  id1=model-batch-z3
  id2=model-batch-z4
  rec=$(make_spawn_case model-batch "$id1" "$id2")
  IFS='|' read -r case_dir home proj wt fakebin launchlog <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$wt" "$fakebin" "$launchlog" "$id1=$proj" "$id2=$proj" --model sonnet)
  status=$?
  expect_code 0 "$status" "batch claude spawn with shared --model should succeed"
  assert_grep 'model=sonnet' "$home/state/$id1.meta" "first batch task did not receive the shared --model"
  assert_grep 'model=sonnet' "$home/state/$id2.meta" "second batch task did not receive the shared --model"
  pass "a shared --model is forwarded to every id=repo pair in a batch"
}

test_model_flag_threaded_for_claude
test_no_model_is_todays_launch
test_batch_forwards_shared_model
