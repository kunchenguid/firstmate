#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's data/<id>/base -> state/<id>.meta base= promotion.
#
# This promotion is the one link in an otherwise fail-closed feature that could
# disarm it silently: fm-brief.sh writes the sidecar and fm-pr-check.sh reads meta,
# but if the branch name never makes the hop between them, fm-pr-check finds no
# base= and the wrong-base guard is skipped entirely - restoring the exact incident
# the guard exists to prevent, with no diagnostic. Both ends were covered; this is
# the middle.
#
# Matrix:
#   (a) sidecar present -> meta records base=<branch>
#   (b) no sidecar (the common case) -> meta records no base= line at all
#   (c) empty sidecar -> loud refusal, not a silently unguarded spawn
#   (d) a secondmate never carries a task base, even with a stray sidecar
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-base)

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

# Build a spawn case: an isolated firstmate home, a real project + git worktree, and
# a brief for the task. base is written to the data/<id>/base sidecar when non-empty;
# pass "empty" to write the sidecar with no branch name in it.
make_spawn_case() {
  local name=$1 id=$2 base=${3:-} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  case "$base" in
    '') ;;
    empty) : > "$home/data/$id/base" ;;
    *) printf '%s\n' "$base" > "$home/data/$id/base" ;;
  esac
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_sidecar_is_promoted_into_meta() {
  local rec id out status
  id=spawn-base-b1
  rec=$(make_spawn_case promote "$id" feature/admin-dashboard)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "promote: spawn with a base sidecar should succeed"$'\n'"$out"
  assert_grep "base=feature/admin-dashboard" "$HOME_DIR/state/$id.meta" \
    "promote: the declared base never reached meta, so fm-pr-check would skip the wrong-base guard"
  pass "fm-spawn promotes the data/<id>/base sidecar into meta as base="
}

test_no_sidecar_writes_no_base_key() {
  local rec id out status
  id=spawn-base-b2
  rec=$(make_spawn_case nosidecar "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "nosidecar: an ordinary spawn should succeed"$'\n'"$out"
  assert_no_grep "^base=" "$HOME_DIR/state/$id.meta" \
    "nosidecar: a task with no declared base must not gain a base= line"
  pass "fm-spawn writes no base= for the common no-declared-base task"
}

test_empty_sidecar_refuses_loudly() {
  local rec id out status
  id=spawn-base-b3
  rec=$(make_spawn_case emptysidecar "$id" empty)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "emptysidecar: a base declaration that cannot be recorded must refuse, not spawn unguarded"
  assert_contains "$out" "declares no branch" "emptysidecar: refusal did not explain the unusable sidecar"
  assert_absent "$HOME_DIR/state/$id.meta" "emptysidecar: refusal should happen before meta is written"
  pass "fm-spawn refuses loudly when a base sidecar cannot be promoted (no silent unguarded spawn)"
}

test_secondmate_ignores_a_stray_base_sidecar() {
  local rec id out status home
  id=spawn-base-sm4
  rec=$(make_spawn_case secondmate "$id" feature/x)
  read_case_record "$rec"
  home="$CASE_DIR/sm-home"
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$home" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate: spawn should succeed"$'\n'"$out"
  assert_no_grep "^base=" "$HOME_DIR/state/$id.meta" \
    "secondmate: a persistent supervisor has no task base and must never record one"
  pass "fm-spawn never records base= for a secondmate"
}

test_sidecar_is_promoted_into_meta
test_no_sidecar_writes_no_base_key
test_empty_sidecar_refuses_loudly
test_secondmate_ignores_a_stray_base_sidecar
