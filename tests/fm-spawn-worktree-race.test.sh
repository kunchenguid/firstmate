#!/usr/bin/env bash
# Regression test for the worktree-resolution startup race in fm-spawn.sh.
#
# A brand-new pane can report a transient pre-shell-init cwd (observed on a real
# host: the terminal multiplexer's own default directory) on the very first
# poll(s) of the post-`treehouse get` worktree-detection loop, before the pane
# has even reached PROJ_ABS for the first time. That transient also differs
# from PROJ_ABS_REAL, so an early implementation could latch onto it as "moved
# into the worktree" and then fail the isolation check against the real
# worktree. The fix requires one confirmed sighting of PROJ_ABS_REAL before a
# later divergence is trusted as the real move.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-race)
fm_git_identity fmtest fmtest@example.invalid

make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# A fake tmux whose pane_current_path answer is scripted per-call via a counter
# file: call 1 returns FM_FAKE_TRANSIENT (a pre-init transient unrelated to the
# project dir), call 2 returns FM_FAKE_PROJ (the pane genuinely arriving at the
# project dir), and call 3+ returns FM_FAKE_WORKTREE (treehouse having moved the
# pane into the real, isolated worktree).
make_race_fakebin() {
  local dir=$1 fakebin counter
  fakebin=$(fm_fakebin "$dir")
  counter="$dir/pane-path-calls"
  printf '0\n' > "$counter"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_path}"*)
    n=\$(cat '$counter' 2>/dev/null || echo 0)
    n=\$((n + 1))
    printf '%s\n' "\$n" > '$counter'
    if [ "\$n" -eq 1 ]; then printf '%s\n' "\${FM_FAKE_TRANSIENT:-}"
    elif [ "\$n" -eq 2 ]; then printf '%s\n' "\${FM_FAKE_PROJ:-}"
    else printf '%s\n' "\${FM_FAKE_WORKTREE:-}"
    fi
    exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 fakebin=$4 transient=$5 project_hit=$6 worktree=$7
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_TRANSIENT="$transient" FM_FAKE_PROJ="$project_hit" FM_FAKE_WORKTREE="$worktree" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_spawn_survives_preinit_transient_before_project_dir() {
  local home proj fakebin wt out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  wt="$TMP_ROOT/spawn-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_race_fakebin "$TMP_ROOT/spawn-fake")

  # First poll reports an unrelated transient path (never the project, never
  # the worktree); second poll reports the project dir; third+ report the real
  # isolated worktree. A pre-fix implementation would latch onto the first
  # divergence (the transient) and abort against it instead of the worktree.
  out=$(run_spawn "$home" race-transient-gg7 "$proj" "$fakebin" "$TMP_ROOT/unrelated-transient" "$proj" "$wt")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane genuinely reaches the isolated worktree"
  assert_contains "$out" "spawned race-transient-gg7" "spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "spawn wrongly latched onto the pre-init transient path"
  pass "fm-spawn: worktree-detection loop ignores a pre-init transient path seen before the project dir"
}

test_spawn_survives_preinit_transient_before_project_dir
