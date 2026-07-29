#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's best-effort Parlay chat-panel enrollment
# (the `parlay listen --agent <id>` call added after a confirmed launch; see
# bin/fm-spawn.sh's header). Parlay is optional captain tooling, never
# load-bearing, so these cover both the present and absent-from-PATH cases.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-parlay)

# make_spawn_fakebin <dir>: a fake tmux that always reports FM_FAKE_PANE_PATH
# for pane_current_path (an already-settled pane, no staleness), plus exit-0
# treehouse. Mirrors fm-spawn-worktree-settle.test.sh's already-settled case.
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <id>: a home + primary project with a real worktree
# (the pane's reported cwd) and a brief, ready for a successful spawn.
make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_case_spawn() {
  local id=$1; shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

test_parlay_listen_enrolled_when_present() {
  local rec id out calls_log pid
  id=spawn-parlay-present-z1
  rec=$(make_spawn_case spawn-parlay-present "$id")
  read_spawn_record "$rec"

  calls_log="$CASE_DIR/parlay-calls.log"
  cat > "$FAKEBIN_DIR/parlay" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_log"
exit 0
SH
  chmod +x "$FAKEBIN_DIR/parlay"

  out=$(run_case_spawn "$id")
  expect_code 0 "$?" "spawn should succeed with parlay present"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  # The parlay listen call runs backgrounded from fm-spawn.sh, detached from
  # this command substitution's own wait - give it a bounded moment to write.
  for _ in $(seq 1 30); do [ -s "$calls_log" ] && break; sleep 0.1; done

  assert_grep "listen --agent $id" "$calls_log" \
    "parlay was not invoked as 'listen --agent $id'"
  [ -e "$HOME_DIR/state/$id.parlay-listen-pid" ] \
    || fail "spawn did not record a parlay-listen-pid file"
  pid=$(cat "$HOME_DIR/state/$id.parlay-listen-pid")
  case "$pid" in
    ''|*[!0-9]*) fail "recorded parlay-listen-pid '$pid' is not a plain pid" ;;
  esac
  kill "$pid" 2>/dev/null || true
  pass "a confirmed spawn enrolls the agent via 'parlay listen --agent <id>' and records its pid"
}

test_spawn_succeeds_when_parlay_absent() {
  local rec id out safe_path
  id=spawn-parlay-absent-z2
  rec=$(make_spawn_case spawn-parlay-absent "$id")
  read_spawn_record "$rec"
  # No fakebin/parlay is installed. The host machine may still have a real
  # parlay later in PATH, so strip its directory too - the genuine
  # absent-from-PATH case, not just "not shadowed by our mock".
  safe_path=$(fm_path_without parlay)

  out=$(PATH="$FAKEBIN_DIR:$safe_path" \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "spawn should succeed even when parlay is not on PATH"
  assert_contains "$out" "spawned $id" "spawn did not report success without parlay"
  [ -e "$HOME_DIR/state/$id.parlay-listen-pid" ] \
    && fail "spawn recorded a parlay-listen-pid despite parlay being absent from PATH"
  pass "a spawn with no 'parlay' on PATH still succeeds and enrolls nothing"
}

test_parlay_listen_enrolled_when_present
test_spawn_succeeds_when_parlay_absent

echo "# all fm-spawn-parlay tests passed"
