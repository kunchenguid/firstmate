#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_STAT_FOR_TEST=$(command -v stat)
export REAL_STAT_FOR_TEST

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
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
[ -z "${FM_EXPECT_CHILD_LINEAGE_PATH:-}" ] || [ -f "$FM_EXPECT_CHILD_LINEAGE_PATH" ] || {
  echo "child lineage missing before home removal: $FM_EXPECT_CHILD_LINEAGE_PATH" >&2
  exit 96
}
[ -z "${FM_EXPECT_CHILD_LINEAGE_PATH:-}" ] || grep -F 'event=predecessor-released' "$FM_EXPECT_CHILD_LINEAGE_PATH" >/dev/null || {
  echo "child predecessor lineage missing before home removal: $FM_EXPECT_CHILD_LINEAGE_PATH" >&2
  exit 94
}
[ -z "${FM_REJECT_CHILD_LINEAGE_PATH:-}" ] || [ ! -e "$FM_REJECT_CHILD_LINEAGE_PATH" ] || {
  echo "child lineage written outside owning home: $FM_REJECT_CHILD_LINEAGE_PATH" >&2
  exit 95
}
[ -z "${FM_EXPECT_CHILD_LINEAGE_MARKER:-}" ] || touch "$FM_EXPECT_CHILD_LINEAGE_MARKER"
[ -z "${FM_EXPECT_REPORT_PATH:-}" ] || [ -f "$FM_EXPECT_REPORT_PATH" ] || {
  echo "report missing before treehouse return: $FM_EXPECT_REPORT_PATH" >&2
  exit 97
}
[ -z "${FM_EXPECT_PARENT_QUIESCED:-}" ] || [ -f "$FM_EXPECT_PARENT_QUIESCED" ] || {
  echo "secondmate parent was not quiesced before child cleanup: $FM_EXPECT_PARENT_QUIESCED" >&2
  exit 98
}
[ -z "${FM_TEARDOWN_ORDER_LOG:-}" ] || printf 'treehouse-return %s\n' "$*" >> "$FM_TEARDOWN_ORDER_LOG"
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh"

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

add_compatible_tasks_axi() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.1'
  exit 0
fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]'
  printf '%s\n' '  --body-file <path>'
  printf '%s\n' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "generation_id=generation-task-x1"
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

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
target=${FM_FAKE_STAT_ERROR_TARGET:?}
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "$target" ]; then
  echo "stat: simulated failure" >&2
  exit 1
fi
exec "${REAL_STAT_FOR_TEST:?}" "$@"
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_CHECKOUT_REFRESH_LOCK_ROOT="${FM_CHECKOUT_REFRESH_LOCK_ROOT:-$case_dir/checkout-locks}" \
  FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
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

  [ "$rc" -eq 0 ] || fail "fork-allow: teardown should succeed when HEAD is on a fork remote: $(cat "$case_dir/stderr")"
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

test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present() {
  local case_dir out
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  add_compatible_tasks_axi "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  printf '%s\n' "$out" | grep -F 'Update data/backlog.md - move task-x1 to Done' >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  printf '%s\n' "$out" | grep -F 'tasks-axi done' >/dev/null \
    && fail "teardown prompted tasks-axi despite manual backend opt-out: $out"
  pass "teardown honors config/backlog-backend=manual even when tasks-axi is compatible"
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
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_pr_check_serializes_with_account_session_updates() {
  local case_dir state meta lookup_ready lookup_release pr_check url head
  case_dir=$(make_case pr-check-meta-lock)
  state="$case_dir/state"
  meta="$state/task-x1.meta"
  lookup_ready="$case_dir/lookup-ready"
  lookup_release="$case_dir/lookup-release"
  url=https://github.com/example/repo/pull/7
  head=deadbeefcafefeed0000000000000000deadbeef
  write_meta "$case_dir" no-mistakes ship
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_LOOKUP_READY"
while [ ! -f "$FM_TEST_LOOKUP_RELEASE" ]; do sleep 0.05; done
printf '%s\n' "$FM_TEST_PR_HEAD"
SH
  chmod +x "$case_dir/fakebin/gh"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
  FM_TEST_LOOKUP_READY="$lookup_ready" FM_TEST_LOOKUP_RELEASE="$lookup_release" \
  FM_TEST_PR_HEAD="$head" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" &
  pr_check=$!
  while [ ! -f "$lookup_ready" ]; do sleep 0.05; done
  if ! bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    held=$(FM_ACCOUNT_META_LOCK_WAIT_SECONDS=1 fm_account_meta_lock_acquire "$2" task-x1) || exit 1
    printf "provider_session_id=session-new\n" >> "$2/task-x1.meta"
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT" "$state"; then
    touch "$lookup_release"
    wait "$pr_check" || true
    fail "PR lookup held the account metadata lock"
  fi
  assert_no_grep '^pr=' "$meta" "PR recording completed before the remote lookup"
  assert_grep 'provider_session_id=session-new' "$meta" "PR recording lost the concurrent provider session update"
  touch "$lookup_release"
  wait "$pr_check" || fail "PR recording failed after the remote lookup completed"
  assert_grep "pr=$url" "$meta" "PR recording did not publish after the account metadata lock was released"
  assert_grep "pr_head=$head" "$meta" "PR recording lost the remote PR head"
  pass "fm-pr-check keeps remote lookups outside account metadata serialization"
}

test_pr_check_rejects_reused_task_generation() {
  local case_dir state meta lookup_ready lookup_release pr_check rc url head staged
  case_dir=$(make_case pr-check-generation-race)
  state="$case_dir/state"; meta="$state/task-x1.meta"
  lookup_ready="$case_dir/lookup-ready"; lookup_release="$case_dir/lookup-release"
  url=https://github.com/example/repo/pull/7
  head=deadbeefcafefeed0000000000000000deadbeef
  staged="$state/.task-x1.meta.reused"
  write_meta "$case_dir" no-mistakes ship
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_LOOKUP_READY"
while [ ! -f "$FM_TEST_LOOKUP_RELEASE" ]; do sleep 0.05; done
printf '%s\n' "$FM_TEST_PR_HEAD"
SH
  chmod +x "$case_dir/fakebin/gh"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
  FM_TEST_LOOKUP_READY="$lookup_ready" FM_TEST_LOOKUP_RELEASE="$lookup_release" \
  FM_TEST_PR_HEAD="$head" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" &
  pr_check=$!
  for _ in $(seq 1 100); do [ -e "$lookup_ready" ] && break; sleep 0.02; done
  [ -e "$lookup_ready" ] || { kill -TERM "$pr_check" 2>/dev/null || true; fail "PR generation lookup gate did not open"; }
  bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    held=$(fm_account_meta_lock_acquire "$2" task-x1) || exit 1
    sed "s/^generation_id=.*/generation_id=generation-task-x1-reused/" "$2/task-x1.meta" > "$3"
    mv "$3" "$2/task-x1.meta"
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT" "$state" "$staged" || fail "PR generation-race setup could not replace metadata"
  touch "$lookup_release"
  set +e
  wait "$pr_check"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "PR lookup attached stale results to a reused task generation"
  assert_grep 'task generation changed' "$case_dir/pr-check.err" \
    "PR generation mismatch failed without an actionable refusal"
  assert_grep 'generation_id=generation-task-x1-reused' "$meta" \
    "PR generation refusal overwrote the replacement task metadata"
  assert_no_grep 'pr=' "$meta" "PR generation refusal attached an old PR to the replacement task"
  assert_absent "$state/task-x1.check.sh" "PR generation refusal armed an orphaned merge poll"
  pass "fm-pr-check binds slow lookup results to the original task generation"
}

test_pr_check_backfills_legacy_generation_and_records_state() {
  local case_dir state meta url head staged count
  case_dir=$(make_case pr-check-legacy-generation-success)
  state="$case_dir/state"; meta="$state/task-x1.meta"
  url=https://github.com/example/repo/pull/7
  head=deadbeefcafefeed0000000000000000deadbeef
  staged="$state/.task-x1.meta.legacy"
  write_meta "$case_dir" no-mistakes ship
  grep -v '^generation_id=' "$meta" > "$staged"
  mv "$staged" "$meta"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' '$head'
SH
  chmod +x "$case_dir/fakebin/gh"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 "$url" >/dev/null \
    || fail "PR check rejected legacy task metadata without a generation identity"
  grep -Eq '^generation_id=legacy:a[0-9a-f]{15}$' "$meta" \
    || fail "successful PR check did not backfill a legacy generation identity"
  count=$(grep -c '^generation_id=' "$meta" || true)
  expect_code 1 "$count" "successful legacy PR generation backfill count"
  assert_grep "pr=$url" "$meta" "successful legacy PR check did not record the PR URL"
  assert_grep "pr_head=$head" "$meta" "successful legacy PR check did not record the PR head"
  assert_present "$state/task-x1.check.sh" "successful legacy PR check did not arm the merge poll"
  pass "fm-pr-check upgrades legacy task metadata without breaking PR handling"
}

test_pr_check_backfills_legacy_generation_before_race_check() {
  local case_dir state meta lookup_ready lookup_release pr_check rc url head staged count
  case_dir=$(make_case pr-check-legacy-generation-race)
  state="$case_dir/state"; meta="$state/task-x1.meta"
  lookup_ready="$case_dir/lookup-ready"; lookup_release="$case_dir/lookup-release"
  url=https://github.com/example/repo/pull/7
  head=deadbeefcafefeed0000000000000000deadbeef
  staged="$state/.task-x1.meta.reused"
  write_meta "$case_dir" no-mistakes ship
  grep -v '^generation_id=' "$meta" > "$staged"
  mv "$staged" "$meta"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
touch "$FM_TEST_LOOKUP_READY"
while [ ! -f "$FM_TEST_LOOKUP_RELEASE" ]; do sleep 0.05; done
printf '%s\n' "$FM_TEST_PR_HEAD"
SH
  chmod +x "$case_dir/fakebin/gh"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
  FM_TEST_LOOKUP_READY="$lookup_ready" FM_TEST_LOOKUP_RELEASE="$lookup_release" \
  FM_TEST_PR_HEAD="$head" PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" &
  pr_check=$!
  for _ in $(seq 1 100); do [ -e "$lookup_ready" ] && break; sleep 0.02; done
  [ -e "$lookup_ready" ] || { kill -TERM "$pr_check" 2>/dev/null || true; fail "legacy PR generation lookup gate did not open"; }
  grep -Eq '^generation_id=legacy:a[0-9a-f]{15}$' "$meta" \
    || fail "PR check did not atomically backfill a legacy generation identity"
  count=$(grep -c '^generation_id=' "$meta" || true)
  expect_code 1 "$count" "legacy PR generation backfill count"
  bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    held=$(fm_account_meta_lock_acquire "$2" task-x1) || exit 1
    sed "s/^generation_id=.*/generation_id=generation-task-x1-reused/" "$2/task-x1.meta" > "$3"
    mv "$3" "$2/task-x1.meta"
    fm_account_meta_lock_release "$held"
  ' _ "$ROOT" "$state" "$staged" || fail "legacy PR generation-race setup could not replace metadata"
  touch "$lookup_release"
  set +e
  wait "$pr_check"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "legacy PR lookup attached stale results to a reused task generation"
  assert_grep 'task generation changed' "$case_dir/pr-check.err" \
    "legacy PR generation mismatch failed without an actionable refusal"
  assert_grep 'generation_id=generation-task-x1-reused' "$meta" \
    "legacy PR generation refusal overwrote replacement task metadata"
  assert_no_grep 'pr=' "$meta" "legacy PR generation refusal attached an old PR to the replacement task"
  assert_absent "$state/task-x1.check.sh" "legacy PR generation refusal armed an orphaned merge poll"
  pass "fm-pr-check backfills legacy identity before generation race checks"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_content_fallback_uses_live_default() {
  local case_dir rc baseline
  case_dir=$(make_case content-live-default)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  baseline=$(git --git-dir="$case_dir/origin.git" rev-parse main^)
  git --git-dir="$case_dir/origin.git" update-ref refs/heads/trunk "$baseline"
  git --git-dir="$case_dir/origin.git" symbolic-ref HEAD refs/heads/trunk
  [ "$(git -C "$case_dir/project" symbolic-ref --short refs/remotes/origin/HEAD)" = origin/main ] \
    || fail "live-default teardown fixture did not preserve stale origin/HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-default teardown must refuse content absent from live trunk"
  assert_present "$case_dir/wt" "live-default teardown discarded the task worktree"
  assert_present "$case_dir/state/task-x1.meta" "live-default teardown removed task metadata"
  assert_grep "task content is not present in authoritative refs/remotes/origin/trunk" \
    "$case_dir/stderr" "live-default teardown did not identify the authoritative branch"
  pass "teardown landing proof uses the live upstream default"
}

test_content_fallback_reprobes_live_default_after_fetch() {
  local case_dir rc baseline
  case_dir=$(make_case content-default-race)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  baseline=$(git --git-dir="$case_dir/origin.git" rev-parse main^)
  git --git-dir="$case_dir/origin.git" update-ref refs/heads/trunk "$baseline"
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
is_fetch=0
for arg in "$@"; do
  [ "$arg" = fetch ] && is_fetch=1
done
if [ "$is_fetch" -eq 1 ]; then
  "$real" "$@"
  status=$?
  if [ "$status" -eq 0 ]; then
    "$real" --git-dir="${FM_TEST_ORIGIN:?}" symbolic-ref HEAD refs/heads/trunk
  fi
  exit "$status"
fi
exec "$real" "$@"
SH
  chmod +x "$case_dir/fakebin/git"

  set +e
  FM_TEST_ORIGIN="$case_dir/origin.git" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "default rename during landing proof must refuse teardown"
  assert_present "$case_dir/wt" "default-rename race discarded the task worktree"
  assert_present "$case_dir/state/task-x1.meta" "default-rename race removed task metadata"
  assert_grep "live origin default changed during landing proof" "$case_dir/stderr" \
    "default-rename race did not surface the changed live authority"
  pass "teardown re-probes live default after fetching"
}

test_content_fallback_honors_shared_checkout_lock() {
  local case_dir rc common key lock_root lock
  case_dir=$(make_case content-shared-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  common=$(git -C "$case_dir/wt" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$case_dir/wt/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  key=$(printf '%s' "$common" | shasum -a 256 | awk '{print substr($1,1,24)}')
  lock_root="$case_dir/checkout-locks"
  lock="$lock_root/$key.lock"
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$lock/pid"

  set +e
  FM_CHECKOUT_REFRESH_LOCK_ROOT="$lock_root" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "contended checkout lock must refuse teardown landing proof"
  assert_present "$case_dir/wt" "lock contention discarded the task worktree"
  assert_present "$case_dir/state/task-x1.meta" "lock contention removed task metadata"
  assert_grep "checkout mutation already running for $case_dir/wt (pid $$)" \
    "$case_dir/stderr" "teardown did not surface shared checkout lock contention"
  rm -rf "$lock"
  pass "teardown landing proof holds the shared checkout lock"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "lsof check failed" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_FAKE_STAT_ERROR_TARGET="$lock" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
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

add_fake_agent_fleet() {
  local case_dir=$1
  cat > "$case_dir/fakebin/agent-fleet" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_AF_LOG"
case "$*" in
  '--format json contract')
    printf '{"contract_version":2}\n'
    exit 0
    ;;
  *"lease release"*)
    [ -z "${FM_TEARDOWN_ORDER_LOG:-}" ] || printf 'lease-release %s\n' "$*" >> "$FM_TEARDOWN_ORDER_LOG"
    [ "${FM_FAKE_AF_RELEASE_FAIL:-0}" != 1 ] || exit 42
    ;;
  *"session remove"*)
    [ -z "${FM_TEARDOWN_ORDER_LOG:-}" ] || printf 'session-remove %s\n' "$*" >> "$FM_TEARDOWN_ORDER_LOG"
    ;;
esac
printf '{"ok":true}\n'
SH
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/agent-fleet" "$case_dir/fakebin/tmux"
}

test_managed_force_teardown_releases_lease_and_session() {
  local case_dir af_log rc
  case_dir=$(make_case managed-force-release)
  af_log="$case_dir/agent-fleet.log"
  : > "$af_log"
  write_meta "$case_dir" local-only ship
  printf '%s\n' \
    'tmux_session_target=firstmate:fm-task-x1' \
    'account_pool=claude-crew' \
    'account_profile=claude-2' \
    'account_task=fm-home-task-x1-attempt-a1' \
    'provider_session_id=session-123' >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "managed unpushed work"
  add_fake_agent_fleet "$case_dir"

  set +e
  FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "managed-force-release: teardown should succeed: $(cat "$case_dir/stderr")"
  assert_grep 'lease release --task fm-home-task-x1-attempt-a1 --force' "$af_log" "managed teardown did not release the lease"
  assert_grep 'session remove --task fm-home-task-x1-attempt-a1' "$af_log" "managed teardown did not remove the session mapping"
  assert_absent "$case_dir/state/task-x1.meta" "managed teardown left task metadata"
  pass "managed teardown releases its lease and session mapping only after endpoint removal"
}

test_managed_teardown_retains_lease_when_endpoint_state_is_unknown() {
  local case_dir af_log rc
  case_dir=$(make_case managed-unknown-endpoint)
  af_log="$case_dir/agent-fleet.log"
  : > "$af_log"
  write_meta "$case_dir" local-only ship
  printf '%s\n' \
    'account_pool=claude-crew' \
    'account_profile=claude-2' \
    'account_task=fm-home-task-x1-attempt-unknown' \
    'provider_session_id=session-unknown' >> "$case_dir/state/task-x1.meta"
  add_fake_agent_fleet "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) exit 1 ;;
  list-panes) echo 'permission denied' >&2; exit 74 ;;
  kill-window) exit 74 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "managed-unknown-endpoint: teardown should fail closed"
  assert_not_contains "$(cat "$af_log")" 'lease release' "unknown endpoint state released the Agent Fleet lease"
  assert_present "$case_dir/state/task-x1.meta" "unknown endpoint state erased retry metadata"
  assert_present "$case_dir/wt/.git" "unknown endpoint state recycled the worktree"
  assert_grep 'managed endpoint state for task-x1 is unknown' "$case_dir/stderr" "unknown endpoint blocker was not reported"
  pass "managed teardown releases only after confirmed endpoint absence"
}

test_managed_release_failure_preserves_unrecycled_worktree_for_retry() {
  local case_dir af_log order_log rc release_line session_line return_line
  case_dir=$(make_case managed-release-failure)
  af_log="$case_dir/agent-fleet.log"
  order_log="$case_dir/teardown-order.log"
  : > "$af_log"
  : > "$order_log"
  write_meta "$case_dir" local-only ship
  printf '%s\n' \
    'tmux_session_target=firstmate:fm-task-x1' \
    'account_pool=codex-crew' \
    'account_profile=codex-2' \
    'account_task=fm-home-task-x1-attempt-b2' \
    'provider_session_id=session-456' >> "$case_dir/state/task-x1.meta"
  add_fake_agent_fleet "$case_dir"

  set +e
  FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" FM_FAKE_AF_RELEASE_FAIL=1 FM_TEARDOWN_ORDER_LOG="$order_log" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "managed-release-failure: teardown should fail closed"
  assert_grep 'lease release --task fm-home-task-x1-attempt-b2 --force' "$af_log" "managed teardown never attempted release"
  ! grep -q 'session remove --task fm-home-task-x1-attempt-b2' "$af_log" || fail "managed teardown removed the mapping after release failed"
  assert_present "$case_dir/state/task-x1.meta" "managed teardown erased retry metadata after release failed"
  assert_grep 'account_profile=codex-2' "$case_dir/state/task-x1.meta" "managed teardown lost sticky account metadata"
  assert_present "$case_dir/wt/.git" "managed teardown recycled the worktree after release failed"
  assert_not_contains "$(cat "$order_log")" 'treehouse-return' "managed teardown returned the worktree before account cleanup succeeded"

  FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" FM_TEARDOWN_ORDER_LOG="$order_log" \
    run_teardown "$case_dir" --force > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" \
    || fail "managed-release-failure: cleanup retry should succeed"

  release_line=$(grep -n 'lease-release .*fm-home-task-x1-attempt-b2' "$order_log" | tail -1 | cut -d: -f1)
  session_line=$(grep -n 'session-remove .*fm-home-task-x1-attempt-b2' "$order_log" | tail -1 | cut -d: -f1)
  return_line=$(grep -n 'treehouse-return' "$order_log" | tail -1 | cut -d: -f1)
  [ "$release_line" -lt "$session_line" ] && [ "$session_line" -lt "$return_line" ] \
    || fail "managed-release-failure: retry recycled the worktree before account cleanup"
  assert_absent "$case_dir/state/task-x1.meta" "managed cleanup retry left task metadata"
  pass "a failed managed release preserves the unrecycled worktree and retry ordering"
}

test_managed_teardown_locks_generation_before_endpoint_cleanup() {
  local case_dir af_log kill_started allow_kill teardown_pid teardown_rc updater_rc
  case_dir=$(make_case managed-generation-lock)
  af_log="$case_dir/agent-fleet.log"
  kill_started="$case_dir/kill-started"
  allow_kill="$case_dir/allow-kill"
  : > "$af_log"
  write_meta "$case_dir" local-only ship
  printf '%s\n' \
    'tmux_session_target=firstmate:fm-task-x1' \
    'account_pool=claude-crew' \
    'account_profile=claude-2' \
    'account_task=fm-home-task-x1-old-attempt' \
    'account_attempt=old-attempt' \
    'provider_session_id=session-old' >> "$case_dir/state/task-x1.meta"
  add_fake_agent_fleet "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  kill-window)
    : > "$FM_FAKE_KILL_STARTED"
    while [ ! -f "$FM_FAKE_ALLOW_KILL" ]; do sleep 0.01; done
    exit 0
    ;;
  display-message) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" \
    FM_FAKE_KILL_STARTED="$kill_started" FM_FAKE_ALLOW_KILL="$allow_kill" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" &
  teardown_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$kill_started" ] && break
    sleep 0.05
  done
  [ -f "$kill_started" ] || { kill "$teardown_pid" 2>/dev/null || true; fail "managed generation teardown never reached endpoint cleanup"; }

  set +e
  FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 bash -c '
    . "$1"
    state=$2
    meta=$state/task-x1.meta
    held=$(fm_account_lifecycle_lock_acquire "$state" task-x1) || exit 75
    awk "!/^window=/ && !/^account_task=/ && !/^account_attempt=/" "$meta" > "$state/.replacement.meta"
    printf "%s\n" "window=firstmate:fm-task-x1-replacement" "account_task=fm-home-task-x1-new-attempt" "account_attempt=new-attempt" >> "$state/.replacement.meta"
    mv "$state/.replacement.meta" "$meta"
    fm_account_lifecycle_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$case_dir/state" \
    > "$case_dir/updater-stdout" 2> "$case_dir/updater-stderr"
  updater_rc=$?
  set -e
  : > "$allow_kill"
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  set -e

  [ "$updater_rc" -ne 0 ] || fail "concurrent continuation replaced metadata after teardown began"
  expect_code 0 "$teardown_rc" "managed generation teardown should complete with its original locked generation"
  assert_grep 'lease release --task fm-home-task-x1-old-attempt --force' "$af_log" "teardown did not release its locked generation"
  assert_not_contains "$(cat "$af_log")" 'fm-home-task-x1-new-attempt' "teardown targeted a concurrent replacement generation"
  assert_absent "$case_dir/state/.replacement.meta" "blocked continuation left replacement scratch metadata"
  assert_absent "$case_dir/state/task-x1.meta" "managed generation teardown left metadata"
  pass "managed teardown serializes generation identity through account cleanup and recycling"
}

test_managed_child_teardown_locks_generation_before_snapshot() {
  local case_dir af_log child_id child_project child_worktree kill_started allow_kill teardown_pid teardown_rc updater_rc
  case_dir=$(make_case managed-child-generation-lock)
  af_log="$case_dir/agent-fleet.log"
  child_id=child-lock-x3
  child_project="$case_dir/child-project"
  child_worktree="$case_dir/child-worktree"
  kill_started="$case_dir/kill-started"
  allow_kill="$case_dir/allow-kill"
  : > "$af_log"
  mkdir -p "$case_dir/wt/data" "$case_dir/wt/state" "$case_dir/wt/config" "$case_dir/wt/projects"
  printf '%s\n' task-x1 > "$case_dir/wt/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  fm_write_meta "$case_dir/wt/state/$child_id.meta" \
    "window=fm-$child_id" \
    "tmux_session_target=firstmate:fm-$child_id" \
    "worktree=$child_worktree" \
    "project=$child_project" \
    'harness=claude' \
    'kind=ship' \
    'mode=local-only' \
    'account_pool=claude-crew' \
    'account_profile=claude-2' \
    'account_task=fm-child-old-attempt' \
    'account_attempt=old-attempt' \
    'account_predecessor_task=fm-child-predecessor' \
    'account_predecessor_attempt=predecessor-attempt' \
    'account_predecessor_provider=claude' \
    'account_predecessor_pool=claude-crew' \
    'account_predecessor_profile=claude-1' \
    'account_predecessor_session=session-predecessor' \
    'account_predecessor_cleanup=pending' \
    'provider_session_id=session-old'
  add_fake_agent_fleet "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  kill-window)
    case "$*" in
      *fm-child-lock-x3*)
        : > "$FM_FAKE_KILL_STARTED"
        while [ ! -f "$FM_FAKE_ALLOW_KILL" ]; do sleep 0.01; done
        ;;
    esac
    exit 0
    ;;
  display-message) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" \
    FM_FAKE_KILL_STARTED="$kill_started" FM_FAKE_ALLOW_KILL="$allow_kill" \
    FM_EXPECT_CHILD_LINEAGE_PATH="$case_dir/wt/data/$child_id/account-attempts.md" \
    FM_REJECT_CHILD_LINEAGE_PATH="$case_dir/data/$child_id/account-attempts.md" \
    FM_EXPECT_CHILD_LINEAGE_MARKER="$case_dir/child-lineage-verified" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" &
  teardown_pid=$!
  for _ in $(seq 1 100); do
    [ -f "$kill_started" ] && break
    sleep 0.05
  done
  [ -f "$kill_started" ] || {
    kill "$teardown_pid" 2>/dev/null || true
    fail "managed child teardown never reached endpoint cleanup: $(cat "$case_dir/stderr")"
  }

  set +e
  FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 bash -c '
    . "$1"
    state=$2
    meta=$state/child-lock-x3.meta
    held=$(fm_account_lifecycle_lock_acquire "$state" child-lock-x3) || exit 75
    awk "!/^window=/ && !/^worktree=/ && !/^account_task=/ && !/^account_attempt=/" "$meta" > "$state/.replacement.meta"
    printf "%s\n" "window=fm-child-lock-x3-replacement" "worktree=$3" "account_task=fm-child-new-attempt" "account_attempt=new-attempt" >> "$state/.replacement.meta"
    mv "$state/.replacement.meta" "$meta"
    fm_account_lifecycle_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$case_dir/wt/state" "$case_dir/replacement-worktree" \
    > "$case_dir/updater-stdout" 2> "$case_dir/updater-stderr"
  updater_rc=$?
  set -e
  : > "$allow_kill"
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  set -e

  [ "$updater_rc" -ne 0 ] || fail "concurrent continuation replaced managed child metadata after teardown began"
  expect_code 0 "$teardown_rc" "managed child generation teardown should complete with its locked generation"
  assert_grep 'lease release --task fm-child-old-attempt --force' "$af_log" "child teardown did not release its locked generation"
  assert_grep 'lease release --task fm-child-predecessor --force' "$af_log" "child teardown did not clean its predecessor generation"
  assert_not_contains "$(cat "$af_log")" 'fm-child-new-attempt' "child teardown targeted a concurrent replacement generation"
  assert_absent "$case_dir/wt/state/.replacement.meta" "blocked child continuation left replacement scratch metadata"
  assert_present "$case_dir/child-lineage-verified" "child account lineage was not verified in the owning home before retirement"
  pass "managed child teardown locks generation before snapshot and recycling"
}

test_forced_secondmate_child_uses_child_home_for_endpoint_verification() {
  local case_dir af_log zellij_log child_project child_worktree child_id rc
  case_dir=$(make_case secondmate-child-home-probe)
  af_log="$case_dir/agent-fleet.log"
  zellij_log="$case_dir/zellij.log"
  child_project="$case_dir/child-project"
  child_worktree="$case_dir/child-worktree"
  child_id=child-zellij-x2
  : > "$af_log"
  : > "$zellij_log"
  mkdir -p "$case_dir/wt/data" "$case_dir/wt/state" "$case_dir/wt/config" "$case_dir/wt/projects"
  printf '%s\n' task-x1 > "$case_dir/wt/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  fm_write_meta "$case_dir/wt/state/$child_id.meta" \
    'window=firstmate:9' \
    "worktree=$child_worktree" \
    "project=$child_project" \
    'harness=claude' \
    'kind=ship' \
    'mode=local-only' \
    'backend=zellij' \
    'zellij_tab_id=7' \
    'account_pool=claude-crew' \
    'account_profile=claude-2' \
    'account_task=fm-child-home-attempt-c3' \
    'provider_session_id=session-child'
  add_fake_agent_fleet "$case_dir"
  cat > "$case_dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\t%s\n' "${FM_HOME:-}" "$*" >> "$FM_FAKE_ZELLIJ_LOG"
if [ "${1:-}" = list-sessions ]; then
  printf 'firstmate\n'
  exit 0
fi
if [ "${FM_HOME:-}" = "${FM_FAKE_ZELLIJ_HOME:-}" ]; then
  case "$*" in
    *'action list-panes --json'*) printf '[{"id":9,"tab_id":7,"is_plugin":false}]\n'; exit 0 ;;
    *'action list-tabs --json'*) printf '[{"tab_id":7,"name":"fm-child-zellij-x2","active":true}]\n'; exit 0 ;;
    *'action close-tab-by-id 7'*) exit 0 ;;
  esac
fi
case "$*" in
  *'action list-panes --json'*|*'action list-tabs --json'*) printf '[]\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/zellij"

  set +e
  FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" \
    FM_FAKE_ZELLIJ_HOME="$case_dir/wt" FM_FAKE_ZELLIJ_LOG="$zellij_log" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "secondmate-child-home-probe: live child endpoint should block account release"
  assert_grep "$case_dir/wt" "$zellij_log" "child endpoint was not verified under the child firstmate home"
  assert_not_contains "$(cat "$af_log")" 'lease release' "live child endpoint allowed Agent Fleet release"
  assert_present "$case_dir/wt/state/$child_id.meta" "live child endpoint lost retry metadata"
  assert_present "$child_worktree/.git" "live child endpoint worktree was recycled"
  assert_grep 'managed endpoint for child-zellij-x2 is still alive' "$case_dir/stderr" "child endpoint blocker was not reported"
  pass "forced secondmate cleanup verifies managed children in the child home"
}

test_forced_secondmate_quiesces_parent_before_child_cleanup() {
  local case_dir child_project child_worktree child_id parent_live parent_quiesced rc
  case_dir=$(make_case secondmate-parent-quiesce)
  child_project="$case_dir/child-project"
  child_worktree="$case_dir/child-worktree"
  child_id=child-after-quiesce-x4
  parent_live="$case_dir/parent-live"
  parent_quiesced="$case_dir/parent-quiesced"
  mkdir -p "$case_dir/wt/data" "$case_dir/wt/state" "$case_dir/wt/config" "$case_dir/wt/projects"
  printf '%s\n' task-x1 > "$case_dir/wt/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  fm_write_meta "$case_dir/wt/state/$child_id.meta" \
    "window=fm-$child_id" \
    "worktree=$child_worktree" \
    "project=$child_project" \
    'kind=ship' \
    'mode=local-only'
  : > "$parent_live"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) [ -f "$FM_FAKE_PARENT_LIVE" ] ;;
  list-panes) exit 0 ;;
  kill-window)
    case "$*" in
      *fm-task-x1*) rm -f "$FM_FAKE_PARENT_LIVE"; : > "$FM_FAKE_PARENT_QUIESCED" ;;
    esac
    exit 0
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_FAKE_PARENT_LIVE="$parent_live" FM_FAKE_PARENT_QUIESCED="$parent_quiesced" \
    FM_EXPECT_PARENT_QUIESCED="$parent_quiesced" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "secondmate-parent-quiesce: forced teardown should succeed"
  assert_present "$parent_quiesced" "forced secondmate teardown did not quiesce its parent endpoint"
  assert_absent "$case_dir/wt" "forced secondmate teardown retained the retired home"
  pass "forced secondmate teardown quiesces and verifies the parent before child cleanup"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' 'backend=herdr' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

test_required_report_blocks_then_publishes_before_cleanup() {
  local case_dir data stack live quiesced rc
  case_dir=$(make_case report-publication)
  data="$case_dir/data"
  stack="$case_dir/report-stack"
  live="$case_dir/report-endpoint-live"
  quiesced="$case_dir/report-endpoint-quiesced"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' \
    'tmux_session_target=firstmate:fm-task-x1' \
    'report_required=1' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$data/task-x1"
  printf '# Task\n\nPublish before cleanup\n' > "$data/task-x1/brief.md"
  printf 'done: implementation landed\n' > "$case_dir/state/task-x1.status"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) [ -f "$FM_FAKE_REPORT_LIVE" ]; exit $? ;;
  list-panes) exit 0 ;;
  kill-window)
    if [ -f "$FM_FAKE_COMPLETION_PATH" ]; then
      printf '\nQuiesced final state.\n' >> "$FM_FAKE_COMPLETION_PATH"
    fi
    rm -f "$FM_FAKE_REPORT_LIVE"
    touch "$FM_FAKE_REPORT_QUIESCED"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  touch "$live"

  set +e
  FM_DATA_OVERRIDE="$data" FM_REPORT_STACK_ROOT="$stack" FM_FAKE_REPORT_LIVE="$live" \
    FM_FAKE_REPORT_QUIESCED="$quiesced" FM_FAKE_COMPLETION_PATH="$data/task-x1/completion.md" \
    run_teardown "$case_dir" > "$case_dir/missing-stdout" 2> "$case_dir/missing-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "required report: teardown without completion.md must fail"
  assert_present "$quiesced" "required report failure did not quiesce its endpoint before publication"
  assert_present "$case_dir/state/task-x1.meta" "required report failure erased task metadata"
  assert_grep 'required completion report is missing' "$case_dir/missing-stderr" \
    "required report failure did not explain the missing artifact"

  printf '# Completion\n\n## Summary\n\nPublication is ready.\n\n## What changed\n\nHooked teardown.\n\n## Verification\n\nTested.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport stack.\n\n## Follow-ups\n\nNone.\n' > "$data/task-x1/completion.md"
  rm -f "$quiesced"
  touch "$live"
  FM_DATA_OVERRIDE="$data" FM_REPORT_STACK_ROOT="$stack" \
    FM_FAKE_REPORT_LIVE="$live" FM_FAKE_REPORT_QUIESCED="$quiesced" \
    FM_FAKE_COMPLETION_PATH="$data/task-x1/completion.md" FM_EXPECT_REPORT_PATH="$stack/index.html" \
    run_teardown "$case_dir" \
      > "$case_dir/report-stdout" 2> "$case_dir/report-stderr" \
    || fail "required report: teardown failed after completion report was ready: $(cat "$case_dir/report-stderr")"
  assert_present "$quiesced" "required report publication did not confirm endpoint quiescence"
  assert_present "$stack/index.html" "required report was not published"
  grep -R -F 'Quiesced final state.' "$stack/entries" >/dev/null \
    || fail "required report was published from stale pre-quiescence content"
  assert_absent "$case_dir/state/task-x1.meta" "successful report teardown left task metadata"
  pass "teardown quiesces before publishing and still publishes before cleanup"
}

test_required_report_restores_rollback_generation_before_publish() {
  local case_dir data stack af_log live backup rc
  case_dir=$(make_case report-rollback-generation)
  data="$case_dir/data"
  stack="$case_dir/report-stack"
  af_log="$case_dir/agent-fleet.log"
  live="$case_dir/report-endpoint-live"
  backup="$case_dir/state/.task-x1.meta.rollback.restore1"
  : > "$af_log"
  mkdir -p "$data/task-x1"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' \
    'tmux_session_target=firstmate:fm-task-x1' \
    'harness=codex' \
    'report_required=1' >> "$case_dir/state/task-x1.meta"
  cp "$case_dir/state/task-x1.meta" "$backup"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'harness=claude' \
    'kind=ship' \
    'mode=no-mistakes' \
    'report_required=1' \
    'account_pool=claude-crew' \
    'account_profile=claude-2' \
    'account_task=fm-home-task-x1-failed' \
    'account_attempt=failed' \
    'provider_session_id=session-failed' \
    'account_rollback_cleanup=pending' \
    'account_rollback_backup=.task-x1.meta.rollback.restore1'
  printf '# Task\n\nRestored report generation\n' > "$data/task-x1/brief.md"
  printf '# Completion\n\n## Summary\n\nSettled generation.\n\n## What changed\n\nRestored metadata.\n\n## Verification\n\nTested.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$data/task-x1/completion.md"
  add_fake_agent_fleet "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) [ -f "$FM_FAKE_REPORT_LIVE" ]; exit $? ;;
  list-panes) exit 0 ;;
  kill-window) rm -f "$FM_FAKE_REPORT_LIVE"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$live"

  set +e
  FM_DATA_OVERRIDE="$data" FM_REPORT_STACK_ROOT="$stack" \
    FM_AGENT_FLEET_BIN="$case_dir/fakebin/agent-fleet" FM_FAKE_AF_LOG="$af_log" \
    FM_FAKE_REPORT_LIVE="$live" run_teardown "$case_dir" \
      > "$case_dir/rollback-stdout" 2> "$case_dir/rollback-stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "required rollback report: restoration pass should stop before publication"
  assert_grep 'rerun teardown against the restored task generation' "$case_dir/rollback-stderr" \
    "required rollback report did not request a fresh settled-generation pass"
  grep -qx 'harness=codex' "$case_dir/state/task-x1.meta" \
    || fail "rollback did not restore predecessor metadata"
  assert_absent "$stack/index.html" "failed generation was published before rollback restoration"

  FM_DATA_OVERRIDE="$data" FM_REPORT_STACK_ROOT="$stack" FM_FAKE_REPORT_LIVE="$live" \
    run_teardown "$case_dir" > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr" \
    || fail "required rollback report: settled-generation retry failed: $(cat "$case_dir/retry-stderr")"
  assert_grep '"harness": "codex"' "$(find "$stack/entries" -name manifest.json -print -quit)" \
    "settled-generation report retained the failed generation harness"
  assert_absent "$case_dir/state/task-x1.meta" "settled-generation teardown retained task metadata"
  pass "teardown restores pending rollback state before required report publication"
}

test_required_report_revalidates_after_quiescence() {
  local case_dir data live rc
  case_dir=$(make_case report-post-quiesce-safety)
  data="$case_dir/data"
  live="$case_dir/report-endpoint-live"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' \
    'tmux_session_target=firstmate:fm-task-x1' \
    'report_required=1' >> "$case_dir/state/task-x1.meta"
  mkdir -p "$data/task-x1"
  printf '# Task\n\nQuiesce before validation\n' > "$data/task-x1/brief.md"
  printf '# Completion\n\n## Summary\n\nReady.\n\n## What changed\n\nChanged.\n\n## Verification\n\nVerified.\n\n## Visual evidence\n\nNone.\n\n## Artifacts\n\nReport.\n\n## Follow-ups\n\nNone.\n' > "$data/task-x1/completion.md"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) [ -f "$FM_FAKE_REPORT_LIVE" ]; exit $? ;;
  list-panes) exit 0 ;;
  kill-window)
    printf 'late work\n' > "$FM_FAKE_WORKTREE/late-work.txt"
    rm -f "$FM_FAKE_REPORT_LIVE"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$live"

  set +e
  FM_DATA_OVERRIDE="$data" FM_REPORT_STACK_ROOT="$case_dir/report-stack" \
    FM_FAKE_REPORT_LIVE="$live" FM_FAKE_WORKTREE="$case_dir/wt" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "required report: post-quiescence dirty work must refuse teardown"
  assert_absent "$live" "required report validation ran before endpoint quiescence"
  assert_present "$case_dir/wt/late-work.txt" "post-quiescence safety refusal discarded late work"
  assert_present "$case_dir/state/task-x1.meta" "post-quiescence safety refusal removed metadata"
  assert_grep 'endpoint has already been shut down; the worktree and task metadata are preserved' "$case_dir/stderr" \
    "post-quiescence safety refusal did not explain the fail-safe state"
  assert_absent "$case_dir/report-stack/index.html" "unsafe post-quiescence state was published"
  pass "required report teardown quiesces before its final safety validation"
}

test_teardown_refuses_unsafe_tasktmp_metadata() {
  local case_dir sentinel rc
  case_dir=$(make_case unsafe-tasktmp)
  sentinel="$case_dir/must-survive"
  write_meta "$case_dir" local-only ship
  mkdir -p "$sentinel"
  printf 'preserve\n' > "$sentinel/marker"
  printf 'tasktmp=%s\n' "$sentinel" >> "$case_dir/state/task-x1.meta"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "unsafe tasktmp teardown exit"
  assert_present "$sentinel/marker" "teardown deleted a metadata-selected arbitrary directory"
  assert_present "$case_dir/state/task-x1.meta" "unsafe tasktmp refusal removed task metadata"
  assert_grep 'unsafe task temp path' "$case_dir/stderr" "unsafe teardown tasktmp refusal was unclear"
  pass "teardown only removes its exact task temp root"
}

test_teardown_rejects_malformed_report_requirement() {
  local case_dir rc
  case_dir=$(make_case malformed-report-required)
  write_meta "$case_dir" local-only ship
  printf 'report_required=0\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "malformed report_required teardown exit"
  assert_present "$case_dir/state/task-x1.meta" "malformed report_required metadata was destructively bypassed"
  assert_grep 'invalid report_required metadata' "$case_dir/stderr" \
    "malformed report_required refusal was unclear"

  case_dir=$(make_case duplicate-report-required)
  write_meta "$case_dir" local-only ship
  printf 'report_required=1\nreport_required=1\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate report_required teardown exit"
  assert_present "$case_dir/state/task-x1.meta" "duplicate report_required metadata was destructively bypassed"
  pass "teardown treats only one exact report_required marker as valid"
}

test_retained_direct_spawn_requires_confirmed_endpoint_quiescence() {
  local case_dir rc
  case_dir=$(make_case retained-direct-spawn-quiescence)
  write_meta "$case_dir" local-only ship
  printf '%s\n' \
    'tmux_session_target=firstmate:fm-task-x1' \
    'account_home=/tmp/direct-account-home' \
    'direct_spawn_cleanup=pending' \
    'rollback_pending=1' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 0 ;;
  list-windows) echo "control plane unavailable" >&2; exit 1 ;;
  display-message) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "retained direct-spawn teardown should fail on unknown endpoint state"
  assert_grep 'retained direct-spawn endpoint state for task-x1 is unknown' "$case_dir/stderr" \
    "retained direct-spawn teardown did not explain the endpoint blocker"
  assert_present "$case_dir/wt/.git" "retained direct-spawn teardown recycled the worktree without endpoint proof"
  assert_present "$case_dir/state/task-x1.meta" "retained direct-spawn teardown erased cleanup metadata without endpoint proof"
  pass "retained direct-spawn teardown requires confirmed endpoint quiescence"
}

if [ "${FM_TEST_FOCUSED:-}" = tasktmp-safety ]; then
  test_teardown_refuses_unsafe_tasktmp_metadata
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = managed-force-release ]; then
  test_managed_force_teardown_releases_lease_and_session
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = managed-endpoint-identity ]; then
  test_managed_force_teardown_releases_lease_and_session
  test_managed_teardown_retains_lease_when_endpoint_state_is_unknown
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-34-report-required ]; then
  test_teardown_rejects_malformed_report_requirement
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-35-pr ]; then
  test_pr_check_serializes_with_account_session_updates
  test_pr_check_rejects_reused_task_generation
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = direct-spawn-cleanup ]; then
  test_retained_direct_spawn_requires_confirmed_endpoint_quiescence
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = legacy-pr-generation ]; then
  test_pr_check_backfills_legacy_generation_and_records_state
  test_pr_check_backfills_legacy_generation_before_race_check
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-6 ]; then
  test_content_in_default_fallback_allows
  test_content_fallback_refreshes_stale_origin_ref
  test_content_fallback_uses_live_default
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-7 ]; then
  test_content_fallback_reprobes_live_default_after_fetch
  test_content_fallback_honors_shared_checkout_lock
  exit 0
fi

test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_managed_force_teardown_releases_lease_and_session
test_managed_teardown_retains_lease_when_endpoint_state_is_unknown
test_managed_release_failure_preserves_unrecycled_worktree_for_retry
test_managed_teardown_locks_generation_before_endpoint_cleanup
test_managed_child_teardown_locks_generation_before_snapshot
test_forced_secondmate_child_uses_child_home_for_endpoint_verification
test_forced_secondmate_quiesces_parent_before_child_cleanup
test_herdr_teardown_clears_escalation_marker
test_required_report_blocks_then_publishes_before_cleanup
test_required_report_restores_rollback_generation_before_publish
test_required_report_revalidates_after_quiescence
test_teardown_refuses_unsafe_tasktmp_metadata
test_teardown_rejects_malformed_report_requirement
test_retained_direct_spawn_requires_confirmed_endpoint_quiescence
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_pr_check_serializes_with_account_session_updates
test_pr_check_rejects_reused_task_generation
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_content_fallback_uses_live_default
test_content_fallback_reprobes_live_default_after_fetch
test_content_fallback_honors_shared_checkout_lock
test_dirty_worktree_refuses
test_gh_error_and_content_absent_refuses
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
