#!/usr/bin/env bash
# tests/fm-spawn-gh-repo.test.sh - a ship or scout worker's gh and gh-axi
# commands must address the task's project even when the worker's shell sits
# inside the firstmate home, whose own git remote names the firstmate repo.
#
# gh and gh-axi both take GH_REPO over the current directory's git remote, so
# the assertions drive the real spawn against a fake pane and a real isolated
# git worktree, then EXECUTE the launch command the pane received with the
# harness binary replaced by a probe. The probe changes into the firstmate home
# first, exactly where the misrouted command ran, and reports both the GH_REPO
# it inherited and the repository that home's remote would have supplied.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-gh-repo)
FIRSTMATE_REMOTE=https://github.com/kunchenguid/firstmate.git

# make_case <name> <harness> <id> <project-github-url-or-empty>
# Echoes "<home>|<project>|<worktree>|<fakebin>|<launch-log>|<pane-log>".
make_case() {
  local name=$1 harness=$2 id=$3 url=$4 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  # The firstmate home is itself a clone of the firstmate repo.
  git -C "$home" init -q
  git -C "$home" remote add origin "$FIRSTMATE_REMOTE"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  # The fixture's origin is a local bare repo spawn can fetch; the project's
  # GitHub identity rides a second remote, as a mirror or push remote would.
  [ -z "$url" ] || git -C "$proj" remote add github "$url"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG <<EOF
$1
EOF
}

run_case_spawn() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The probe stands in for the agent: it moves into the firstmate home and
# prints "<GH_REPO>|<that directory's origin>".
install_probe() {  # <fakebin> <harness> <firstmate-home>
  cat > "$1/$2" <<SH
#!/bin/sh
cd '$3' || exit 1
printf '%s|%s\n' "\${GH_REPO-unset}" "\$(git remote get-url origin)"
SH
  chmod +x "$1/$2"
}

# Replay the pane's pre-launch exports, then the launch, in a cleared synthetic
# pane environment that carries no GH_REPO of its own.
emitted_launch_probe() {
  local preamble launch
  preamble=$(grep '^export ' "$PANE_LOG")
  launch=$(cat "$LAUNCH_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    TMUX=synthetic-pane /bin/sh -c "$preamble
$launch"
}

test_worker_in_firstmate_home_targets_its_project() {
  local kind setting id rec out status seen
  for kind in ship scout; do
    for setting in absent enabled; do
      id="ghrepo-$kind-$setting-a1"
      rec=$(make_case "$kind-$setting" codex "$id" git@github.com:acme/widget.git)
      read_case "$rec"
      [ "$setting" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
      if [ "$kind" = ship ]; then
        out=$(run_case_spawn "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
      else
        out=$(run_case_spawn "$id" "$PROJ_DIR" --scout)
      fi
      status=$?
      expect_code 0 "$status" "$kind spawn with allowlist=$setting should succeed: $out"
      install_probe "$FAKEBIN_DIR" codex "$HOME_DIR"
      seen=$(emitted_launch_probe) || fail "$kind, allowlist=$setting: the emitted launch failed to run"
      # The case is only meaningful while the home's own remote would have
      # supplied a different repository.
      assert_equals "$FIRSTMATE_REMOTE" "$(git -C "$HOME_DIR" remote get-url origin)" \
        "the firstmate home must resolve to the firstmate repo on its own"
      assert_equals "acme/widget|$FIRSTMATE_REMOTE" "$seen" \
        "a $kind worker in the firstmate home (allowlist=$setting) must still have GH_REPO name its project"
    done
  done
  pass "ship and scout workers carry their project's GitHub repository into the firstmate home in both allowlist postures"
}

test_project_without_github_repository_sets_nothing() {
  local rec out status seen
  rec=$(make_case no-github codex ghrepo-none-a1 "")
  read_case "$rec"
  : > "$HOME_DIR/config/launch-env-allowlist"
  out=$(run_case_spawn ghrepo-none-a1 "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn for a project with no GitHub remote should succeed: $out"
  install_probe "$FAKEBIN_DIR" codex "$HOME_DIR"
  seen=$(emitted_launch_probe) || fail "no-github: the emitted launch failed to run"
  assert_equals "unset|$FIRSTMATE_REMOTE" "$seen" \
    "a project with no GitHub repository must not be given a guessed GH_REPO"
  pass "a project with no GitHub repository launches without GH_REPO"
}

test_worker_in_firstmate_home_targets_its_project
test_project_without_github_repository_sets_nothing
