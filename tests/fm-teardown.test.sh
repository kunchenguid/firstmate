#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's unpushed-work safety check.
#
# Covers the local-only fork-remote fix: a local-only-registered project whose
# task pushes its work to a fork (upstream-contribution PRs) must be teardown-
# eligible because a fork IS a remote. The pre-fix code short-circuited to a
# strict local-main check and false-refused legitimate fork-pushed work.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (the fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes  + HEAD on origin remote-tracking branch   -> ALLOW  (no regression)
#   (e) no-mistakes  + truly unpushed work                     -> REFUSE (no regression)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-teardown-tests.XXXXXX")

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Install a logging `no-mistakes` mock. Every invocation appends a line to
# $case_dir/nm.log recording its args, cwd, and the git branch at that cwd, so
# tests can assert whether/where/on-which-branch `axi abort` ran. Args: case_dir
add_logging_no_mistakes() {
  local case_dir=$1 log="$case_dir/nm.log"
  : > "$log"
  cat > "$case_dir/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
branch=\$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo NO-GIT)
printf 'ARGS=[%s] CWD=%s BRANCH=%s\n' "\$*" "\$(pwd)" "\$branch" >> "$log"
exit 0
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

# Install a `no-mistakes` mock that fails (non-zero) to prove teardown's abort
# step is best-effort. Args: case_dir
add_failing_no_mistakes() {
  local case_dir=$1
  cat > "$case_dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "no active run" >&2
exit 3
SH
  chmod +x "$case_dir/fakebin/no-mistakes"
}

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  cat > "$case_dir/state/task-x1.meta" <<EOF
window=fm-task-x1
worktree=$case_dir/wt
project=$case_dir/project
kind=$kind
mode=$mode
EOF
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# Exit code expectation. Args: expected actual label
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  pass "local-only worktree with HEAD on a fork remote is torn down (fix holds)"
}

test_teardown_prompts_tasks_axi_done_when_compatible() {
  local case_dir out
  case_dir=$(make_case tasks-axi-reminder)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with compatible tasks-axi"
  printf '%s\n' "$out" | grep -F 'tasks-axi done task-x1 --pr https://github.com/example/repo/pull/7' >/dev/null \
    || fail "teardown did not prompt tasks-axi done: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi ready' >/dev/null \
    || fail "teardown did not prompt tasks-axi ready: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'keep Done to the 10 most recent' >/dev/null \
    && fail "teardown kept manual Done pruning in compatible tasks-axi prompt: $out"
  pass "teardown prompts tasks-axi backlog refresh when compatible"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with truly unpushed work is refused (no regression)"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

# The zombie-run fix: a no-mistakes ship teardown must close the run by calling
# `no-mistakes axi abort` from inside the worktree while still on the task branch
# (before the detach), so an externally-merged run does not linger as "running".
test_no_mistakes_ship_aborts_run_on_task_branch() {
  local case_dir line
  case_dir=$(make_case abort-nm-ship)
  write_meta "$case_dir" no-mistakes ship
  add_logging_no_mistakes "$case_dir"

  run_teardown "$case_dir" >/dev/null 2>&1 || fail "abort-nm-ship: teardown failed"

  [ -s "$case_dir/nm.log" ] || fail "abort-nm-ship: no-mistakes was never invoked"
  line=$(cat "$case_dir/nm.log")
  printf '%s\n' "$line" | grep -qF 'ARGS=[axi abort]' \
    || fail "abort-nm-ship: expected 'axi abort', got: $line"
  printf '%s\n' "$line" | grep -qF "CWD=$case_dir/wt" \
    || fail "abort-nm-ship: abort did not run from inside the worktree: $line"
  printf '%s\n' "$line" | grep -qF 'BRANCH=fm/task-x1' \
    || fail "abort-nm-ship: abort did not run while on the task branch: $line"
  pass "no-mistakes ship teardown aborts the run from the worktree on the task branch"
}

# Guarded to KIND!=scout: a scout teardown must NOT abort a run.
test_scout_does_not_abort_run() {
  local case_dir
  case_dir=$(make_case abort-scout)
  write_meta "$case_dir" no-mistakes scout
  add_logging_no_mistakes "$case_dir"
  # Scout teardown needs a report to be eligible; point DATA at the case dir.
  mkdir -p "$case_dir/data/task-x1"
  echo findings > "$case_dir/data/task-x1/report.md"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 >/dev/null 2>&1 || fail "abort-scout: teardown failed"

  [ ! -s "$case_dir/nm.log" ] \
    || fail "abort-scout: scout teardown invoked no-mistakes: $(cat "$case_dir/nm.log")"
  pass "scout teardown does not abort a no-mistakes run (KIND!=scout guard holds)"
}

# Guarded to MODE=no-mistakes: a local-only teardown must NOT abort a run.
test_local_only_does_not_abort_run() {
  local case_dir
  case_dir=$(make_case abort-local-only)
  write_meta "$case_dir" local-only ship
  add_logging_no_mistakes "$case_dir"
  # Make it teardown-eligible: merge the (unchanged) HEAD is already on main.

  run_teardown "$case_dir" >/dev/null 2>&1 || fail "abort-local-only: teardown failed"

  [ ! -s "$case_dir/nm.log" ] \
    || fail "abort-local-only: local-only teardown invoked no-mistakes: $(cat "$case_dir/nm.log")"
  pass "local-only teardown does not abort a run (MODE=no-mistakes guard holds)"
}

# Best-effort: a failing `no-mistakes axi abort` must not fail teardown.
test_abort_failure_does_not_fail_teardown() {
  local case_dir rc
  case_dir=$(make_case abort-fails)
  write_meta "$case_dir" no-mistakes ship
  add_failing_no_mistakes "$case_dir"

  set +e
  run_teardown "$case_dir" >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "abort-fails: teardown must succeed despite a failing abort"
  [ ! -f "$case_dir/state/task-x1.meta" ] \
    || fail "abort-fails: teardown did not complete (meta still present)"
  pass "a failing no-mistakes abort does not fail teardown (best-effort |\\| true)"
}

# A PR-based teardown passes project= back to fm-fleet-sync.sh explicitly.
# When that project path is a symlink, the canonical checkout must still catch
# up to origin after teardown. The git wrapper rejects the symlink as a -C path,
# proving fleet sync resolved it rather than relying on git to follow it.
test_teardown_syncs_symlink_project_target() {
  local case_dir canonical updater real_git out
  case_dir=$(make_case symlink-project-sync)
  canonical="$case_dir/canonical-project"
  updater="$case_dir/updater"

  mv "$case_dir/project" "$canonical"
  ln -s "$canonical" "$case_dir/project"
  write_meta "$case_dir" no-mistakes ship
  add_failing_no_mistakes "$case_dir"

  git clone -q "$case_dir/origin.git" "$updater"
  printf 'merged change\n' > "$updater/merged.txt"
  git -C "$updater" add merged.txt
  git -C "$updater" -c user.email=t@t -c user.name=t commit -qm "merged change"
  git -C "$updater" push -q origin main

  real_git=$(command -v git)
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ]; then
  printf '%s\n' "\${2:-}" >> "$case_dir/git-c.log"
  if [ -L "\${2:-}" ]; then
    printf 'test git wrapper refuses symlink -C path: %s\n' "\${2:-}" >&2
    exit 97
  fi
fi
exec "$real_git" "\$@"
SH
  chmod +x "$case_dir/fakebin/git"

  out=$(run_teardown "$case_dir") || fail "symlink-project-sync: teardown failed: $out"

  [ "$(git -C "$canonical" rev-parse HEAD)" = "$(git -C "$case_dir/origin.git" rev-parse main)" ] \
    || fail "symlink-project-sync: canonical checkout did not catch up to origin/main"
  printf '%s\n' "$out" | grep -F "$case_dir/project: synced " >/dev/null \
    || fail "symlink-project-sync: teardown did not report the symlink project sync: $out"
  if grep -Fx "$case_dir/project" "$case_dir/git-c.log" >/dev/null; then
    fail "symlink-project-sync: fleet sync passed the symlink path to git -C"
  fi
  grep -Fx "$canonical" "$case_dir/git-c.log" >/dev/null \
    || fail "symlink-project-sync: fleet sync did not operate on the canonical target"
  pass "PR-based teardown fast-forwards a symlink project's canonical target"
}

test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_no_mistakes_ship_aborts_run_on_task_branch
test_scout_does_not_abort_run
test_local_only_does_not_abort_run
test_abort_failure_does_not_fail_teardown
test_teardown_syncs_symlink_project_target
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
