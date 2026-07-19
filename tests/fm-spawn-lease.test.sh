#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's treehouse worktree acquisition.
#
# fm-spawn.sh acquires the task worktree by running `treehouse get --lease
# --lease-holder <holder>` from ITS OWN process, then validates the result
# before moving the task window into it with a plain `cd`. The old behavior -
# typing bare `treehouse get` into the just-created window and polling its cwd -
# could block forever on a network credential prompt inside that window
# (2026-07-19, task spawn-worktree-failure). These tests pin the replacement
# contract with a recording fake tmux and a recording fake treehouse, so no real
# pool, network, or terminal is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-lease)

# make_lease_fakebin <dir> <treehouse-reply-mode> <reply-path> -> echoes fakebin dir
#   reply-mode:
#     path    - `treehouse get --lease ...` prints <reply-path> to stdout (success case)
#     empty   - prints nothing (empty lease)
#     silent  - like empty, but also used for the "never consulted" assertions
#   Every invocation of treehouse and every `tmux send-keys` are appended to
#   TREEHOUSE_LOG / TMUX_SEND_LOG (env vars) for assertion.
make_lease_fakebin() {
  local dir=$1 mode=$2 reply=$3 fakebin
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
    if [ -n "${FM_SEND_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ] || [ "$prev" = "-t" ]; then
          :
        fi
        prev=$a
      done
      printf '%s\n' "$*" >> "$FM_SEND_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  case "$mode" in
    path)
      cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
[ -n "\${FM_TREEHOUSE_LOG:-}" ] && printf '%s\n' "\$*" >> "\$FM_TREEHOUSE_LOG"
case "\$*" in
  "get --lease --lease-holder"*) printf '%s\n' "$reply"; exit 0 ;;
esac
exit 0
SH
      ;;
    empty)
      cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TREEHOUSE_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_TREEHOUSE_LOG"
case "$*" in
  "get --lease --lease-holder"*) printf ''; exit 0 ;;
esac
exit 0
SH
      ;;
  esac
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_spawn() {  # <home> <proj> <pane> <fakebin> <id>
  local home=$1 proj=$2 pane=$3 fakebin=$4 id=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  : > "$home/send.log"
  : > "$home/treehouse.log"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_SEND_LOG="$home/send.log" FM_TREEHOUSE_LOG="$home/treehouse.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" codex 2>&1
}

test_lease_acquired_from_own_process_not_typed_into_window() {
  local home proj wt fakebin id out status
  home="$TMP_ROOT/ok-home"; proj="$TMP_ROOT/ok-proj"; wt="$TMP_ROOT/ok-wt"
  id=lease-ok-a1
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fakebin=$(make_lease_fakebin "$TMP_ROOT/ok-fake" path "$wt")

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 0 "$status" "spawn with a valid lease should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  assert_grep "get --lease --lease-holder fm-$id" "$home/treehouse.log" \
    "fm-spawn did not run treehouse get --lease --lease-holder fm-<id> from its own process"
  assert_no_grep 'treehouse get' "$home/send.log" \
    "fm-spawn must never type 'treehouse get' into the task window"
  assert_grep "cd $wt" "$home/send.log" \
    "fm-spawn must cd the window into the leased worktree"
  pass "fm-spawn acquires the worktree via treehouse get --lease from its own process, never by typing into the window"
}

test_lease_empty_path_fails_without_launching() {
  local home proj wt fakebin id out status
  home="$TMP_ROOT/empty-home"; proj="$TMP_ROOT/empty-proj"; wt="$TMP_ROOT/empty-wt"
  id=lease-empty-b2
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fakebin=$(make_lease_fakebin "$TMP_ROOT/empty-fake" empty "")

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 1 "$status" "an empty lease path must fail the spawn"
  assert_contains "$out" "did not yield a worktree" "empty-lease failure did not name the cause"
  assert_absent "$home/state/$id.meta" "an empty-lease spawn must never record meta"
  assert_no_grep 'codex' "$home/send.log" \
    "an empty-lease spawn must never send the agent launch command into the window"
  pass "an empty lease path fails loudly and never launches an agent"
}

test_lease_nondirectory_path_fails_without_launching() {
  local home proj wt fakebin id out status not_a_dir
  home="$TMP_ROOT/notdir-home"; proj="$TMP_ROOT/notdir-proj"; wt="$TMP_ROOT/notdir-wt"
  id=lease-notdir-c3
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  not_a_dir="$TMP_ROOT/notdir-wt-plain-file"
  printf 'not a worktree\n' > "$not_a_dir"
  fakebin=$(make_lease_fakebin "$TMP_ROOT/notdir-fake" path "$not_a_dir")

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id")
  status=$?
  expect_code 1 "$status" "a lease path that is not a directory must fail the spawn"
  assert_contains "$out" "did not yield a worktree" "non-directory lease failure did not name the cause"
  assert_absent "$home/state/$id.meta" "a non-directory-lease spawn must never record meta"
  assert_no_grep 'codex' "$home/send.log" \
    "a non-directory-lease spawn must never send the agent launch command into the window"
  pass "a lease that resolves to a non-directory fails loudly and never launches an agent"
}

test_lease_validated_before_window_moved() {
  local home proj wt fakebin id out status unisolated
  home="$TMP_ROOT/unisolated-home"; proj="$TMP_ROOT/unisolated-proj"; wt="$TMP_ROOT/unisolated-wt-unused"
  id=lease-unisolated-d4
  mkdir -p "$home/data" "$home/state" "$home/config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  # A directory that exists but is not an isolated git worktree at all (plain dir).
  unisolated="$TMP_ROOT/unisolated-plain-dir"
  mkdir -p "$unisolated"
  fakebin=$(make_lease_fakebin "$TMP_ROOT/unisolated-fake" path "$unisolated")

  out=$(run_spawn "$home" "$proj" "$unisolated" "$fakebin" "$id")
  status=$?
  expect_code 1 "$status" "a lease that is not an isolated worktree must fail the spawn"
  assert_contains "$out" "did not yield an isolated worktree" \
    "unisolated-lease failure did not trip validate_spawn_worktree"
  assert_no_grep "cd $unisolated" "$home/send.log" \
    "the task window must never be moved into an unvalidated lease"
  assert_no_grep 'codex' "$home/send.log" \
    "an unisolated-lease spawn must never send the agent launch command into the window"
  assert_absent "$home/state/$id.meta" "an unisolated-lease spawn must never record meta"
  pass "the leased worktree is validated before the window is moved into it"
}

test_lease_acquired_from_own_process_not_typed_into_window
test_lease_empty_path_fails_without_launching
test_lease_nondirectory_path_fails_without_launching
test_lease_validated_before_window_moved

echo "# all fm-spawn-lease tests passed"
