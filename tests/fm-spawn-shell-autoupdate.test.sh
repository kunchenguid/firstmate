#!/usr/bin/env bash
# Regression test for the shell auto-update suppression fm-spawn.sh sends
# before `treehouse get` (bin/fm-spawn.sh).
#
# oh-my-zsh's periodic update check prompts "[oh-my-zsh] Would you like to
# update? [Y/n]" in every NEW interactive shell once it comes due, and
# `treehouse get` starts exactly such a shell inside the worktree. The prompt
# blocks on stdin, so the cd never lands and the spawn dies on the worktree
# settle timeout - fleet-wide, with nothing wrong in firstmate, treehouse or
# the pool. Suppressing the check only works if the export reaches the pane
# BEFORE `treehouse get` starts that shell, so this test asserts the order the
# two lines are sent in, not merely that both were sent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-shell-autoupdate)

# make_sendlog_fakebin <dir> builds a fake tmux that appends every send-keys
# payload to FM_FAKE_SEND_LOG in call order, so a test can assert what the
# pane received and in which sequence.
make_sendlog_fakebin() {
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
    for arg in "$@"; do
      case "$arg" in
        export\ DISABLE_AUTO_UPDATE=*|treehouse\ get)
          printf '%s\n' "$arg" >> "${FM_FAKE_SEND_LOG:?FM_FAKE_SEND_LOG unset}"
          ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_autoupdate_case <name> <id> builds a home plus a primary project with a
# real worktree, and returns the paths the run needs.
make_autoupdate_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin sendlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  sendlog="$case_dir/send-log"
  fakebin=$(make_sendlog_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$sendlog"
}

read_autoupdate_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR SEND_LOG <<EOF
$1
EOF
}

run_autoupdate_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_SEND_LOG="$SEND_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# The suppression is worthless if it arrives after the shell that would prompt
# has already started, so the export must be the earlier of the two sends.
test_autoupdate_suppression_precedes_treehouse_get() {
  local rec id out status first second
  id=autoupdate-order-z1
  rec=$(make_autoupdate_case autoupdate-order "$id")
  read_autoupdate_record "$rec"

  out=$(run_autoupdate_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed against the fake pane"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  [ -f "$SEND_LOG" ] || fail "no send-keys payloads were recorded at all"
  first=$(sed -n '1p' "$SEND_LOG")
  second=$(sed -n '2p' "$SEND_LOG")
  [ "$first" = "export DISABLE_AUTO_UPDATE=true" ] || \
    fail "first relevant send was '$first', expected the auto-update suppression"
  [ "$second" = "treehouse get" ] || \
    fail "second relevant send was '$second', expected 'treehouse get'"
  pass "the auto-update suppression is sent before treehouse get starts its shell"
}

test_autoupdate_suppression_precedes_treehouse_get

echo "# all fm-spawn-shell-autoupdate tests passed"
