#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-default-base)

make_fakebin() {
  local wt=$2 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_TMUX_LOG:?}"
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$wt"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 case_dir="$TMP_ROOT/$1" home proj wt remote fakebin tmux_log treehouse_log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/worktree"
  remote="$case_dir/origin.git"
  tmux_log="$case_dir/tmux.log"
  treehouse_log="$case_dir/treehouse.log"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  fm_git_init_commit "$proj"
  git -C "$proj" branch -M trunk
  fm_git_add_origin "$proj" "$remote"
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/trunk
  git -C "$proj" switch -q -c main
  printf 'wrong base\n' > "$proj/main-only.txt"
  git -C "$proj" add main-only.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm main-only
  git -C "$proj" push -q origin main
  git -C "$proj" switch -q -c feature
  printf 'feature pollution\n' > "$proj/feature-only.txt"
  git -C "$proj" add feature-only.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm feature-only
  git -C "$proj" worktree add --quiet --detach "$wt" feature
  git -C "$proj" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  fakebin=$(make_fakebin "$case_dir" "$wt")
  printf '%s\n' "$case_dir|$home|$proj|$wt|$remote|$fakebin|$tmux_log|$treehouse_log"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 tmux_log=$4 treehouse_log=$5 id=$6 proj=$7
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  : > "$tmux_log"
  : > "$treehouse_log"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_TMUX_LOG="$tmux_log" \
    FM_FAKE_TREEHOUSE_LOG="$treehouse_log" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off claude 2>&1
}

test_remote_head_overrides_stale_cached_ref() {
  local record case_dir home proj wt remote fakebin tmux_log treehouse_log id out status expected
  record=$(make_case actual-remote-head)
  IFS='|' read -r case_dir home proj wt remote fakebin tmux_log treehouse_log <<EOF
$record
EOF
  id=default-base-trunk-z1
  out=$(run_spawn "$home" "$wt" "$fakebin" "$tmux_log" "$treehouse_log" "$id" "$proj")
  status=$?
  expect_code 0 "$status" "spawn should base successfully on the advertised remote default"$'\n'"$out"
  expected=$(git --git-dir="$remote" rev-parse refs/heads/trunk)
  [ "$(git -C "$wt" rev-parse HEAD)" = "$expected" ] \
    || fail "spawn used the stale cached origin/HEAD instead of the remote's advertised HEAD"
  [ "$(git -C "$wt" symbolic-ref -q HEAD || true)" = "" ] \
    || fail "spawn did not leave the fresh worktree detached"
  [ ! -s "$treehouse_log" ] \
    || fail "spawn returned the worktree after metadata took ownership"
  assert_not_contains "$(cat "$tmux_log")" "kill-window" \
    "spawn killed the backend task after metadata took ownership"
  rm -rf "/tmp/fm-$id"
  pass "spawn resolves the remote default instead of cached origin/HEAD"
}

test_fetch_failure_refuses_launch() {
  local record case_dir home proj wt remote fakebin tmux_log treehouse_log id out status real_git
  record=$(make_case fetch-failure)
  IFS='|' read -r case_dir home proj wt remote fakebin tmux_log treehouse_log <<EOF
$record
EOF
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != fetch ] || exit 1
done
exec "$real_git" "\$@"
SH
  chmod +x "$fakebin/git"
  id=default-base-fetch-fail-z2
  out=$(run_spawn "$home" "$wt" "$fakebin" "$tmux_log" "$treehouse_log" "$id" "$proj")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the remote default cannot be fetched"
  assert_contains "$out" "could not fetch origin's default branch 'trunk'" \
    "spawn did not report the failed default-branch fetch"
  assert_not_contains "$(cat "$tmux_log")" "claude --dangerously-skip-permissions" \
    "spawn launched the crewmate after the default-branch fetch failed"
  assert_absent "$home/state/$id.meta" "spawn wrote task metadata after the default-branch fetch failed"
  assert_contains "$(cat "$treehouse_log")" "return --force $wt" \
    "spawn did not return the leased worktree after the default-branch fetch failed"
  assert_contains "$(cat "$tmux_log")" "kill-window -t =firstmate:=fm-$id" \
    "spawn did not kill the backend task after the default-branch fetch failed"
  pass "spawn refuses launch when the remote default cannot be fetched"
}

test_remote_head_overrides_stale_cached_ref
test_fetch_failure_refuses_launch
