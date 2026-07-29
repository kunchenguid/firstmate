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
#   - teardown-lock-race: a killed crewmate process can leave a transient worktree
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
#   (f) local-only + truly unpushed + --force                  -> REFUSE (force retains work)
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
# killed crewmate process (bin/fm-teardown.sh's teardown_treehouse_return).
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

write_treehouse_lease() {
  local worktree=$1 holder=$2 slot pool state
  slot=$(cd "$(dirname "$worktree")" && pwd -P)
  pool=$(cd "$(dirname "$slot")" && pwd -P)
  state="$pool/treehouse-state.json"
  python3 - "$state" "$(cd "$worktree" && pwd -P)" "$holder" <<'PY'
import json
import sys

state, path, holder = sys.argv[1:]
with open(state, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "worktrees": [
                {
                    "name": "1",
                    "path": path,
                    "leased": True,
                    "lease_holder": holder,
                }
            ]
        },
        stream,
    )
PY
}

prepare_secondmate_home_fixture() {
  local case_dir=$1 id=${2:-task-x1} root_default default root_tip exclude home_abs
  mkdir -p "$case_dir/data" "$case_dir/wt/data" "$case_dir/wt/state" "$case_dir/wt/config" \
    "$case_dir/wt/projects" "$case_dir/source-projects"
  printf '%s\n' "$id" > "$case_dir/wt/.fm-secondmate-home"
  home_abs=$(cd "$case_dir/wt" && pwd -P)
  printf '%s\n' "- $id - test secondmate (home: $home_abs; scope: test; projects: test; added 2026-07-23)" \
    > "$case_dir/data/secondmates.md"
  root_default=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf 'origin/main')
  default=${root_default#origin/}
  root_tip=$(git -C "$ROOT" rev-parse "$root_default")
  git -C "$case_dir/project" fetch --quiet "$ROOT" "$root_tip"
  git -C "$case_dir/project" checkout --quiet --detach
  git -C "$case_dir/wt" checkout --quiet -B "$default" "$root_tip"
  git -C "$case_dir/project" branch -D fm/task-x1 >/dev/null 2>&1 || true
  git -C "$case_dir/project" remote set-url origin "$ROOT"
  git -C "$case_dir/project" update-ref "refs/remotes/origin/$default" "$root_tip"
  git -C "$case_dir/project" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$default"
  git -C "$case_dir/wt" reflog expire --expire=now --all
  git clone --quiet "$case_dir/origin.git" "$case_dir/source-projects/test"
  git clone --quiet "$case_dir/origin.git" "$case_dir/wt/projects/test"
  exclude=$(git -C "$case_dir/wt" rev-parse --git-path info/exclude)
  printf '%s\n' '.fm-secondmate-home' '/data/' '/state/' '/config/' '/projects/' >> "$exclude"
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ls-remote --symref origin HEAD "*|*" ls-remote --symref origin HEAD")
    remote_head=$("$REAL_GIT_FOR_TEST" -C "$FM_FAKE_FIRSTMATE_SOURCE" \
      symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf 'origin/main')
    remote_tip=$("$REAL_GIT_FOR_TEST" -C "$FM_FAKE_FIRSTMATE_SOURCE" rev-parse "$remote_head")
    printf 'ref: refs/heads/%s\tHEAD\n%s\tHEAD\n' "${remote_head#origin/}" "$remote_tip"
    exit 0
    ;;
esac
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/git"
}

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
[ -z "${FM_EXPECT_CHECKOUT_LOCK:-}" ] || {
  [ -e "$FM_EXPECT_CHECKOUT_LOCK" ] || [ -L "$FM_EXPECT_CHECKOUT_LOCK" ] || exit 91
  lock_pid=$(cat "$FM_EXPECT_CHECKOUT_LOCK/pid" 2>/dev/null || true)
  kill -0 "$lock_pid" 2>/dev/null || exit 92
  [ -z "${FM_EXPECT_CHECKOUT_LOCK_MARKER:-}" ] || touch "$FM_EXPECT_CHECKOUT_LOCK_MARKER"
}
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
state="$(dirname "$0")/.tmux-live"
case "${1:-}" in
  display-message)
    [ -f "$state" ] || exit 1
    case " $* " in
      *' #{pane_current_command} '*) printf '%s\n' bash ;;
    esac
    exit 0
    ;;
  list-windows) [ ! -f "$state" ] || printf '%s\n' fm-task-x1; exit 0 ;;
  kill-window) rm -f "$state"; exit 0 ;;
esac
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
  : > "$fakebin/.tmux-live"

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
  write_treehouse_lease "$case_dir/wt" firstmate-task-x1

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
    "tmux_session_target=firstmate:fm-task-x1" \
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
# (simulating a dying crewmate git process finishing) so the next retry succeeds.
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

add_stale_lock_on_first_return_treehouse() {
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
  if [ ! -f "${TREEHOUSE_FIRST_RETURN_MARKER:?}" ]; then
    : > "$TREEHOUSE_FIRST_RETURN_MARKER"
    mkdir -p "$(dirname "$lock")"
    : > "$lock"
    touch -t 200001010000 "$lock"
  fi
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

add_hanging_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  (
    trap '' TERM
    while :; do
      sleep 1
    done
  ) &
  child=$!
  printf '%s\n' "$child" > "${TREEHOUSE_RETURN_CHILD_PID_FILE:?}"
  wait "$child"
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

checkout_lock_path() {
  local dir=$1 lock_root=$2 common key
  common=$(git -C "$dir" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$dir/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  key=$(printf '%s' "$common" | shasum -a 256 | awk '{print substr($1,1,24)}')
  printf '%s/%s.lock\n' "$lock_root" "$key"
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
  FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-$case_dir/data}" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_PROJECTS_OVERRIDE="${FM_PROJECTS_OVERRIDE:-$case_dir/source-projects}" \
  FM_CHECKOUT_REFRESH_LOCK_ROOT="${FM_CHECKOUT_REFRESH_LOCK_ROOT:-$case_dir/checkout-locks}" \
  FM_EXPECT_CHECKOUT_LOCK="${FM_EXPECT_CHECKOUT_LOCK:-}" \
  FM_EXPECT_CHECKOUT_LOCK_MARKER="${FM_EXPECT_CHECKOUT_LOCK_MARKER:-}" \
  FM_FAKE_FIRSTMATE_SOURCE="${FM_FAKE_FIRSTMATE_SOURCE:-$ROOT}" \
  FM_TEARDOWN_TEST_MOUNT_PATH="${FM_TEARDOWN_TEST_MOUNT_PATH:-}" \
  HOME="${FM_TEST_TEARDOWN_HOME:-$HOME}" \
  FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

run_teardown_named() {
  local case_dir=$1 task=$2
  shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_PROJECTS_OVERRIDE="${FM_PROJECTS_OVERRIDE:-$case_dir/source-projects}" \
  FM_CHECKOUT_REFRESH_LOCK_ROOT="$case_dir/checkout-locks" \
  FM_FAKE_FIRSTMATE_SOURCE="$ROOT" \
  FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$task" "$@"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
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
  local case_dir rc common key expected_lock lock_marker
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  common=$(git -C "$case_dir/wt" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$case_dir/wt/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  key=$(printf '%s' "$common" | shasum -a 256 | awk '{print substr($1,1,24)}')
  expected_lock="$case_dir/checkout-locks/$key.lock"
  lock_marker="$case_dir/checkout-return-held-lock"

  set +e
  FM_EXPECT_CHECKOUT_LOCK="$expected_lock" \
    FM_EXPECT_CHECKOUT_LOCK_MARKER="$lock_marker" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$lock_marker" \
    "normal teardown did not hold the common checkout lock during Treehouse return"
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

test_locked_return_reuses_checkout_lock_for_landing_recheck() {
  local case_dir rc lock marker
  case_dir=$(make_case locked-return-landing-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  add_stale_lock_on_first_return_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  lock=$(git_index_lock_path "$case_dir/wt")
  marker="$case_dir/treehouse-first-return"

  set +e
  TREEHOUSE_FIRST_RETURN_MARKER="$marker" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=0 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "locked landing recheck should reuse its already-held checkout lock"
  assert_present "$marker" "locked landing recheck did not exercise Treehouse return recovery"
  assert_absent "$lock" "locked landing recheck left the stale Git lock behind"
  assert_not_contains "$(cat "$case_dir/stderr")" "checkout mutation already running" \
    "locked landing recheck tried to reacquire its non-reentrant checkout lock"
  pass "locked Treehouse recovery reuses its checkout lock for landing proof"
}

test_treehouse_return_timeout_reaps_children_before_unlock() {
  local case_dir rc child_pid_file child_pid lock
  case_dir=$(make_case treehouse-return-timeout)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  add_hanging_treehouse "$case_dir"
  child_pid_file="$case_dir/treehouse-return-child.pid"
  lock=$(checkout_lock_path "$case_dir/wt" "$case_dir/checkout-locks")

  set +e
  TREEHOUSE_RETURN_CHILD_PID_FILE="$child_pid_file" FM_TREEHOUSE_RETURN_TIMEOUT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "timed-out Treehouse return should retain the task"
  assert_present "$child_pid_file" "timed-out Treehouse return did not start its descendant"
  child_pid=$(cat "$child_pid_file")
  ! kill -0 "$child_pid" 2>/dev/null \
    || fail "timed-out Treehouse return left descendant $child_pid alive"
  assert_absent "$lock" "checkout lock remained held after the Treehouse return process tree was reaped"
  assert_present "$case_dir/wt" "timed-out Treehouse return removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "timed-out Treehouse return removed task metadata"
  assert_grep "Treehouse return timed out after 1s" "$case_dir/stderr" \
    "timed-out Treehouse return did not surface its timeout"
  pass "Treehouse return timeout reaps descendants before releasing checkout lock"
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

test_local_only_force_retains_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "force-retention: --force must not bypass the unpushed-work check"
  assert_present "$case_dir/wt" "force-retention removed a worktree with unpushed work"
  assert_present "$case_dir/state/task-x1.meta" "force-retention removed task metadata"
  assert_grep 'work not yet merged' "$case_dir/stderr" \
    "force-retention did not surface the unpushed work"
  pass "force teardown retains local-only unpushed work"
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

test_managed_force_teardown_retains_unlanded_lease_and_session() {
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

  expect_code 1 "$rc" "managed-force-retention: teardown must retain unlanded work"
  assert_no_grep 'lease release' "$af_log" "managed force teardown released the retained lease"
  assert_no_grep 'session remove' "$af_log" "managed force teardown removed the retained session mapping"
  assert_present "$case_dir/state/task-x1.meta" "managed force teardown removed retry metadata"
  assert_present "$case_dir/wt" "managed force teardown removed unlanded work"
  pass "managed force teardown retains unlanded lease and session state"
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
  list-windows) echo 'permission denied' >&2; exit 74 ;;
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
  prepare_secondmate_home_fixture "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  write_treehouse_lease "$child_worktree" "firstmate-$child_id"
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
  prepare_secondmate_home_fixture "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  write_treehouse_lease "$child_worktree" "firstmate-$child_id"
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
  prepare_secondmate_home_fixture "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  write_treehouse_lease "$child_worktree" "firstmate-$child_id"
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

setup_forced_secondmate_child_case() {
  local name=$1 child_id=$2
  FORCED_CHILD_CASE_DIR=$(make_case "$name")
  FORCED_CHILD_PROJECT="$FORCED_CHILD_CASE_DIR/child-project"
  FORCED_CHILD_WORKTREE="$FORCED_CHILD_CASE_DIR/child-worktree"
  FORCED_CHILD_PARENT_LIVE="$FORCED_CHILD_CASE_DIR/parent-live"
  prepare_secondmate_home_fixture "$FORCED_CHILD_CASE_DIR"
  fm_write_meta "$FORCED_CHILD_CASE_DIR/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$FORCED_CHILD_CASE_DIR/wt" \
    "project=$FORCED_CHILD_CASE_DIR/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$FORCED_CHILD_CASE_DIR/wt"
  fm_git_worktree "$FORCED_CHILD_PROJECT" "$FORCED_CHILD_WORKTREE" child-branch
  write_treehouse_lease "$FORCED_CHILD_WORKTREE" "firstmate-$child_id"
  fm_write_meta "$FORCED_CHILD_CASE_DIR/wt/state/$child_id.meta" \
    "window=fm-$child_id" \
    "worktree=$FORCED_CHILD_WORKTREE" \
    "project=$FORCED_CHILD_PROJECT" \
    'kind=ship' \
    'mode=local-only'
  : > "$FORCED_CHILD_PARENT_LIVE"
  cat > "$FORCED_CHILD_CASE_DIR/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) [ -f "$FM_FAKE_PARENT_LIVE" ]; exit $? ;;
  list-panes) exit 0 ;;
  kill-window) rm -f "$FM_FAKE_PARENT_LIVE"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$FORCED_CHILD_CASE_DIR/fakebin/tmux"
}

test_forced_secondmate_retains_child_on_treehouse_failure() {
  local case_dir child_worktree child_id lock child_pid_file child_ready_file child_pid term_marker rc
  child_id=child-return-failure-x6
  setup_forced_secondmate_child_case secondmate-child-return-failure "$child_id"
  case_dir=$FORCED_CHILD_CASE_DIR
  child_worktree=$FORCED_CHILD_WORKTREE
  lock=$(checkout_lock_path "$child_worktree" "$case_dir/checkout-locks")
  child_pid_file="$case_dir/treehouse-child.pid"
  child_ready_file="$case_dir/treehouse-child.ready"
  term_marker="$case_dir/treehouse-child-terminated-under-lock"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  (
    trap '
      if [ -e "$FM_EXPECT_CHECKOUT_LOCK" ] || [ -L "$FM_EXPECT_CHECKOUT_LOCK" ]; then
        : > "$TREEHOUSE_RETURN_CHILD_TERM_MARKER"
      fi
      exit 0
    ' TERM
    : > "$TREEHOUSE_RETURN_CHILD_READY_FILE"
    while :; do
      sleep 1
    done
  ) &
  child=$!
  printf '%s\n' "$child" > "$TREEHOUSE_RETURN_CHILD_PID_FILE"
  while [ ! -f "$TREEHOUSE_RETURN_CHILD_READY_FILE" ]; do
    :
  done
  exit 17
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  FM_FAKE_PARENT_LIVE="$FORCED_CHILD_PARENT_LIVE" \
  FM_EXPECT_CHECKOUT_LOCK="$lock" \
  TREEHOUSE_RETURN_CHILD_PID_FILE="$child_pid_file" \
  TREEHOUSE_RETURN_CHILD_READY_FILE="$child_ready_file" \
  TREEHOUSE_RETURN_CHILD_TERM_MARKER="$term_marker" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 17 "$rc" "forced secondmate cleanup should preserve the failed Treehouse return status"
  assert_present "$child_pid_file" "failed Treehouse return did not start its descendant"
  child_pid=$(cat "$child_pid_file")
  ! kill -0 "$child_pid" 2>/dev/null \
    || fail "failed Treehouse return left descendant $child_pid alive"
  assert_present "$term_marker" "failed Treehouse return released the checkout lock before terminating descendants"
  assert_absent "$lock" "failed Treehouse return left the checkout lock held"
  assert_present "$child_worktree" "failed Treehouse return deleted the child worktree"
  assert_present "$case_dir/wt/state/$child_id.meta" "failed Treehouse return removed child retry metadata"
  assert_present "$case_dir/state/task-x1.meta" "failed Treehouse return removed parent retry metadata"
  assert_grep "retained child worktree $child_worktree because its locked Treehouse return failed (status 17)" \
    "$case_dir/stderr" "forced secondmate cleanup did not report failed-return retention"
  pass "forced secondmate cleanup retains failed returns after reaping descendants"
}

test_forced_secondmate_retains_unverified_process_group() {
  local case_dir child_worktree child_id lock child_pid_file rc group anchor_state owner
  child_id=child-return-unverified-x8
  setup_forced_secondmate_child_case secondmate-child-return-unverified "$child_id"
  case_dir=$FORCED_CHILD_CASE_DIR
  child_worktree=$FORCED_CHILD_WORKTREE
  lock=$(checkout_lock_path "$child_worktree" "$case_dir/checkout-locks")
  child_pid_file="$case_dir/treehouse-unverified-child.pid"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  (
    trap '' TERM
    while :; do
      sleep 1
    done
  ) &
  printf '%s\n' "$!" > "$TREEHOUSE_RETURN_CHILD_PID_FILE"
fi
exit 0
SH
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/ps"

  set +e
  FM_FAKE_PARENT_LIVE="$FORCED_CHILD_PARENT_LIVE" \
  TREEHOUSE_RETURN_CHILD_PID_FILE="$child_pid_file" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 76 "$rc" "unverified Treehouse process cleanup should fail distinctly"
  assert_present "$child_pid_file" "unverified Treehouse return did not start its descendant"
  assert_present "$lock" "unverified process cleanup released the checkout lock"
  assert_present "$lock/process-group" "unverified process cleanup lost its guarded group identity"
  group=$(cat "$lock/process-group")
  anchor_state=$(ps -p "$group" -o pid= -o pgid= 2>/dev/null | awk '{$1=$1; print}')
  [ "$anchor_state" = "$group $group" ] \
    || fail "unverified process cleanup did not retain its identity-pinned group anchor"
  assert_present "$child_worktree" "unverified process cleanup deleted the child worktree"
  assert_present "$case_dir/wt/state/$child_id.meta" "unverified process cleanup removed child retry metadata"
  assert_present "$case_dir/state/task-x1.meta" "unverified process cleanup removed parent retry metadata"
  assert_grep "bounded command process cleanup could not be verified" "$case_dir/stderr" \
    "unverified process cleanup did not surface the supervisor failure"
  assert_grep "Treehouse return process cleanup could not be verified" "$case_dir/stderr" \
    "unverified process cleanup did not surface retain-only Treehouse handling"
  owner=$(readlink "$lock")
  kill -KILL -- "-$group" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$group" 2>/dev/null || break
    sleep 0.02
  done
  ! kill -0 "$group" 2>/dev/null || fail "test cleanup could not terminate retained anchored group $group"
  rm -f "$lock"
  rm -rf "$owner"
  pass "unverified Treehouse process cleanup retains worktree and checkout lock"
}

test_bounded_runner_preserves_command_status_125() {
  local rc
  # shellcheck source=bin/fm-process-tree-lib.sh
  . "$ROOT/bin/fm-process-tree-lib.sh"
  if fm_run_bounded 2 sh -c 'exit 125'; then
    rc=0
  else
    rc=$?
  fi
  expect_code 125 "$rc" "bounded runner changed a legitimate command exit 125"
  [ "$FM_PROCESS_TREE_CLEANUP_STATUS" = verified ] \
    || fail "bounded runner confused command exit 125 with cleanup failure"
  pass "bounded runner preserves command exit 125 separately from cleanup state"
}

test_forced_secondmate_retains_child_when_treehouse_unavailable() {
  local case_dir child_worktree child_id rc
  child_id=child-return-unavailable-x7
  setup_forced_secondmate_child_case secondmate-child-return-unavailable "$child_id"
  case_dir=$FORCED_CHILD_CASE_DIR
  child_worktree=$FORCED_CHILD_WORKTREE
  rm -f "$case_dir/fakebin/treehouse"

  set +e
  PATH=/usr/bin:/bin FM_FAKE_PARENT_LIVE="$FORCED_CHILD_PARENT_LIVE" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 127 "$rc" "forced secondmate cleanup should surface unavailable Treehouse distinctly"
  assert_present "$child_worktree" "unavailable Treehouse deleted the child worktree"
  assert_present "$case_dir/wt/state/$child_id.meta" "unavailable Treehouse removed child retry metadata"
  assert_present "$case_dir/state/task-x1.meta" "unavailable Treehouse removed parent retry metadata"
  assert_grep "retained child worktree $child_worktree because Treehouse is unavailable" \
    "$case_dir/stderr" "forced secondmate cleanup did not report unavailable-return retention"
  pass "forced secondmate cleanup retains child worktree when Treehouse is unavailable"
}

test_forced_secondmate_retains_child_on_checkout_lock_contention() {
  local case_dir child_project child_worktree child_id lock_root lock parent_live rc
  case_dir=$(make_case secondmate-child-checkout-contention)
  child_project="$case_dir/child-project"
  child_worktree="$case_dir/child-worktree"
  child_id=child-contention-x5
  lock_root="$case_dir/checkout-locks"
  prepare_secondmate_home_fixture "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  write_treehouse_lease "$child_worktree" "firstmate-$child_id"
  fm_write_meta "$case_dir/wt/state/$child_id.meta" \
    "window=fm-$child_id" \
    "worktree=$child_worktree" \
    "project=$child_project" \
    'kind=ship' \
    'mode=local-only'
  lock=$(checkout_lock_path "$child_worktree" "$lock_root")
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  parent_live="$case_dir/parent-live"
  : > "$parent_live"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) [ -f "$FM_FAKE_PARENT_LIVE" ]; exit $? ;;
  list-panes) exit 0 ;;
  kill-window) rm -f "$FM_FAKE_PARENT_LIVE"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_FAKE_PARENT_LIVE="$parent_live" FM_CHECKOUT_REFRESH_LOCK_ROOT="$lock_root" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 75 "$rc" "forced secondmate cleanup should surface checkout lock contention distinctly"
  assert_present "$child_worktree" "checkout lock contention deleted the child worktree"
  assert_present "$case_dir/wt/state/$child_id.meta" "checkout lock contention removed child retry metadata"
  assert_present "$case_dir/state/task-x1.meta" "checkout lock contention removed parent retry metadata"
  assert_grep "checkout mutation already running for $child_worktree (pid $$)" "$case_dir/stderr" \
    "forced secondmate cleanup did not surface checkout lock contention"
  assert_grep "retained child worktree $child_worktree because its common checkout mutation lock is busy" \
    "$case_dir/stderr" "forced secondmate cleanup did not report retention on contention"
  pass "forced secondmate cleanup retains child worktree on checkout lock contention"
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

test_legacy_teardown_revalidates_after_quiescence() {
  local case_dir live rc
  case_dir=$(make_case legacy-post-quiesce-safety)
  live="$case_dir/legacy-endpoint-live"
  write_meta "$case_dir" no-mistakes ship
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) [ -f "$FM_FAKE_REPORT_LIVE" ]; exit $? ;;
  list-windows) exit 0 ;;
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
  FM_FAKE_REPORT_LIVE="$live" FM_FAKE_WORKTREE="$case_dir/wt" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "legacy teardown: post-quiescence dirty work must refuse return"
  assert_absent "$live" "legacy teardown validated before endpoint quiescence"
  assert_present "$case_dir/wt/late-work.txt" "legacy teardown discarded post-quiescence work"
  assert_present "$case_dir/state/task-x1.meta" "legacy teardown removed metadata after safety refusal"
  assert_grep 'endpoint has already been shut down; the worktree and task metadata are preserved' "$case_dir/stderr" \
    "legacy teardown did not explain its post-quiescence fail-safe state"
  pass "legacy teardown quiesces before landed-work validation"
}

test_teardown_rejects_nested_metadata_roots_before_quiescence() {
  local case_dir marker nested tmp rc
  case_dir=$(make_case nested-teardown-root)
  write_meta "$case_dir" no-mistakes ship
  nested="$case_dir/project/nested"
  marker="$case_dir/endpoint-killed"
  mkdir -p "$nested"
  tmp="$case_dir/meta.tmp"
  sed "s#^project=.*#project=$nested#" "$case_dir/state/task-x1.meta" > "$tmp"
  mv "$tmp" "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != kill-window ] || : > "$FM_FAKE_KILL_MARKER"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_FAKE_KILL_MARKER="$marker" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "nested teardown project metadata must be rejected"
  assert_absent "$marker" "teardown quiesced an endpoint before validating metadata roots"
  assert_present "$case_dir/state/task-x1.meta" "nested metadata refusal removed task metadata"
  assert_grep 'not an exact inspectable repository root' "$case_dir/stderr" \
    "nested metadata root refusal was unclear"
  pass "teardown validates exact repository identity before mutation"
}

test_teardown_rejects_drifted_treehouse_task_lease() {
  local case_dir marker rc
  case_dir=$(make_case drifted-treehouse-task-lease)
  write_meta "$case_dir" no-mistakes ship
  write_treehouse_lease "$case_dir/wt" firstmate-other-task
  marker="$case_dir/endpoint-killed"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != kill-window ] || : > "$FM_FAKE_KILL_MARKER"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_FAKE_KILL_MARKER="$marker" run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "drifted Treehouse task lease must be rejected"
  assert_absent "$marker" "teardown stopped an endpoint before proving Treehouse task ownership"
  assert_present "$case_dir/state/task-x1.meta" "Treehouse ownership refusal removed task metadata"
  assert_grep "expected 'firstmate-task-x1'" "$case_dir/stderr" \
    "Treehouse ownership refusal did not identify the expected task holder"
  pass "teardown requires the recorded Treehouse lease holder"
}

test_teardown_rechecks_treehouse_lease_after_locked_safety() {
  local case_dir count_file return_marker state rc branch
  case_dir=$(make_case lease-drift-during-locked-safety)
  write_meta "$case_dir" no-mistakes ship
  count_file="$case_dir/status-count"
  return_marker="$case_dir/treehouse-returned"
  state="$TMP_ROOT/treehouse-state.json"
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *" status --porcelain"*)
    count=0
    [ ! -f "$FM_FAKE_STATUS_COUNT" ] || count=$(cat "$FM_FAKE_STATUS_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_STATUS_COUNT"
    if [ "$count" -eq 2 ]; then
      python3 - "$FM_FAKE_TREEHOUSE_STATE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    state = json.load(stream)
state["worktrees"][0]["lease_holder"] = "firstmate-other-task"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
PY
    fi
    ;;
esac
exec "$REAL_GIT_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
: > "$FM_FAKE_TREEHOUSE_RETURNED"
exit 0
SH
  chmod +x "$case_dir/fakebin/git" "$case_dir/fakebin/treehouse"

  set +e
  FM_FAKE_STATUS_COUNT="$count_file" FM_FAKE_TREEHOUSE_STATE="$state" \
    FM_FAKE_TREEHOUSE_RETURNED="$return_marker" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "lease reassignment during locked safety checks must abort return"
  assert_absent "$return_marker" "Treehouse return ran after the task lease changed"
  assert_present "$case_dir/wt" "lease reassignment removed the task worktree"
  assert_present "$case_dir/state/task-x1.meta" "lease reassignment removed task metadata"
  branch=$("$REAL_GIT_FOR_TEST" -C "$case_dir/wt" symbolic-ref --quiet --short HEAD)
  [ "$branch" = fm/task-x1 ] || fail "lease reassignment detached or deleted the task branch"
  assert_grep "ownership changed during final safety checks" "$case_dir/stderr" \
    "lease reassignment was not surfaced at the locked mutation boundary"
  pass "locked teardown rechecks ownership before return mutation"
}

test_secondmate_rejects_drifted_home_repository_identity() {
  local case_dir marker rc
  case_dir=$(make_case secondmate-home-identity-drift)
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
  marker="$case_dir/endpoint-killed"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != kill-window ] || : > "$FM_FAKE_KILL_MARKER"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_FAKE_KILL_MARKER="$marker" run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "secondmate home repository identity drift must block teardown"
  assert_absent "$marker" "secondmate endpoint was stopped before home identity was proved"
  assert_present "$case_dir/wt" "identity-drifted secondmate home was removed"
  assert_present "$case_dir/state/task-x1.meta" "identity-drifted secondmate metadata was removed"
  assert_grep "secondmate home repository identity does not match" "$case_dir/stderr" \
    "secondmate home identity drift was not surfaced"
  pass "secondmate teardown proves its home repository identity"
}

test_normal_secondmate_retires_proven_detached_head() {
  local case_dir rc
  case_dir=$(make_case normal-secondmate-quiescence)
  prepare_secondmate_home_fixture "$case_dir"
  git -C "$case_dir/wt" checkout --quiet --detach
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "normal secondmate retirement should quiesce and complete"
  assert_absent "$case_dir/fakebin/.tmux-live" "normal secondmate retirement left its endpoint alive"
  assert_absent "$case_dir/wt" "normal secondmate retirement retained its home"
  pass "normal secondmate retirement proves endpoint absence"
}

test_forced_secondmate_retains_untracked_skill_draft() {
  local case_dir draft rc
  case_dir=$(make_case secondmate-untracked-skill)
  prepare_secondmate_home_fixture "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/wt" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  draft="$case_dir/wt/.claude/skills/new-skill/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' draft > "$draft"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "forced secondmate retirement must retain an untracked skill draft"
  assert_present "$case_dir/fakebin/.tmux-live" "dirty-home refusal stopped the secondmate endpoint"
  assert_present "$draft" "forced secondmate retirement discarded an untracked skill draft"
  assert_present "$case_dir/state/task-x1.meta" "dirty-home refusal removed secondmate metadata"
  assert_grep "new-skill/SKILL.md" "$case_dir/stderr" \
    "dirty-home refusal did not surface the untracked skill draft"
  pass "forced secondmate retirement retains untracked skill drafts"
}

test_forced_secondmate_retains_unique_detached_head() {
  local case_dir rc
  case_dir=$(make_case secondmate-clean-unique-commit)
  prepare_secondmate_home_fixture "$case_dir"
  git -C "$case_dir/wt" checkout --quiet --detach
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/wt" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  printf '%s\n' unique > "$case_dir/wt/unique.txt"
  git -C "$case_dir/wt" add unique.txt
  git -C "$case_dir/wt" -c user.name=tests -c user.email=tests@example.invalid \
    commit --quiet -m unique

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "forced secondmate retirement must retain a clean unique commit"
  assert_present "$case_dir/fakebin/.tmux-live" "unique-commit refusal stopped the secondmate endpoint"
  assert_present "$case_dir/wt/unique.txt" "forced secondmate retirement discarded a clean unique commit"
  assert_present "$case_dir/state/task-x1.meta" "unique-commit refusal removed secondmate metadata"
  assert_grep "not proven in authoritative" "$case_dir/stderr" \
    "unique-commit refusal did not surface the unlanded ref"
  pass "forced secondmate retirement retains clean unique commits"
}

test_forced_secondmate_retains_stash() {
  local case_dir rc
  case_dir=$(make_case secondmate-retained-stash)
  prepare_secondmate_home_fixture "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/wt" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  printf '%s\n' retained > "$case_dir/wt/retained-stash.txt"
  git -C "$case_dir/wt" add retained-stash.txt
  git -C "$case_dir/wt" stash push --quiet

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "forced secondmate retirement must retain stash history"
  assert_present "$case_dir/wt" "forced secondmate retirement removed a home with a stash"
  assert_present "$case_dir/state/task-x1.meta" "stash refusal removed secondmate metadata"
  [ -n "$(git -C "$case_dir/wt" stash list)" ] || fail "forced secondmate retirement discarded the stash"
  assert_grep "retained stash history" "$case_dir/stderr" \
    "stash refusal was not surfaced"
  pass "forced secondmate retirement retains stash history"
}

test_forced_secondmate_retains_unlanded_child_work() {
  local case_dir child_id child_worktree rc
  child_id=child-unlanded-x7
  setup_forced_secondmate_child_case secondmate-child-unlanded "$child_id"
  case_dir=$FORCED_CHILD_CASE_DIR
  child_worktree=$FORCED_CHILD_WORKTREE
  printf '%s\n' retained > "$child_worktree/untracked-child.txt"

  set +e
  FM_FAKE_PARENT_LIVE="$FORCED_CHILD_PARENT_LIVE" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "forced secondmate cleanup must retain unlanded child work"
  assert_present "$child_worktree/untracked-child.txt" "forced cleanup discarded untracked child work"
  assert_present "$case_dir/wt/state/$child_id.meta" "forced cleanup removed child retry metadata"
  assert_present "$case_dir/state/task-x1.meta" "forced cleanup removed parent retry metadata"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "forced child retention did not surface uncommitted work"
  pass "forced secondmate cleanup retains unlanded child work"
}

test_forced_secondmate_retains_unquiesced_unmanaged_child() {
  local case_dir child_id child_project child_worktree parent_live child_live rc
  case_dir=$(make_case secondmate-unmanaged-child-live)
  child_id=child-live-x9
  child_project="$case_dir/child-project"
  child_worktree="$case_dir/child-worktree"
  parent_live="$case_dir/parent-live"
  child_live="$case_dir/child-live"
  prepare_secondmate_home_fixture "$case_dir"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  fm_git_worktree "$child_project" "$child_worktree" child-branch
  write_treehouse_lease "$child_worktree" "firstmate-$child_id"
  fm_write_meta "$case_dir/wt/state/$child_id.meta" \
    "window=fm-$child_id" \
    "tmux_session_target=firstmate:fm-$child_id" \
    "worktree=$child_worktree" \
    "project=$child_project" \
    'kind=ship' \
    'mode=local-only'
  : > "$parent_live"
  : > "$child_live"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=
prev=
for arg in "$@"; do
  [ "$prev" = -t ] && target=$arg
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$target" in
      *task-x1) [ -f "$FM_FAKE_PARENT_LIVE" ] ;;
      *child-live-x9) [ -f "$FM_FAKE_CHILD_LIVE" ] ;;
      *) exit 1 ;;
    esac
    exit $?
    ;;
  list-windows)
    [ -f "$FM_FAKE_PARENT_LIVE" ] && printf '%s\n' fm-task-x1
    [ -f "$FM_FAKE_CHILD_LIVE" ] && printf '%s\n' fm-child-live-x9
    ;;
  kill-window)
    case "$target" in
      *child-live-x9) exit 74 ;;
      *) rm -f "$FM_FAKE_PARENT_LIVE" ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_FAKE_PARENT_LIVE="$parent_live" FM_FAKE_CHILD_LIVE="$child_live" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "a live unmanaged child must block forced secondmate cleanup"
  assert_present "$child_live" "the child endpoint fixture unexpectedly disappeared"
  assert_present "$case_dir/wt" "forced cleanup removed the parent home after child quiescence failed"
  assert_present "$child_worktree" "forced cleanup removed a worktree with a live child endpoint"
  assert_present "$case_dir/wt/state/$child_id.meta" "forced cleanup removed live-child retry metadata"
  assert_present "$case_dir/state/task-x1.meta" "forced cleanup removed parent metadata after child quiescence failed"
  assert_grep "child endpoint for $child_id is still alive" "$case_dir/stderr" \
    "forced cleanup did not surface the surviving child endpoint"
  pass "forced secondmate cleanup retains unquiesced unmanaged children"
}

test_teardown_retains_untracked_claude_skill_draft() {
  local case_dir draft rc
  case_dir=$(make_case retained-claude-skill)
  write_meta "$case_dir" no-mistakes ship
  draft="$case_dir/wt/.claude/skills/draft/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# draft' > "$draft"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "untracked .claude skill draft must refuse teardown"
  assert_present "$draft" "teardown discarded an untracked .claude skill draft"
  assert_present "$case_dir/state/task-x1.meta" "skill-draft refusal removed task metadata"
  assert_grep 'has uncommitted changes' "$case_dir/stderr" \
    "skill-draft refusal did not surface uncommitted work"
  pass "teardown retains untracked .claude skill drafts"
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

test_teardown_removes_safe_tasktmp_and_accepts_absence() {
  local case_dir tasktmp
  tasktmp=/tmp/fm-task-x1
  assert_absent "$tasktmp" "safe tasktmp fixture collided with an existing task temp root"
  mkdir -p "$tasktmp/gotmp"
  printf '%s\n' leftover > "$tasktmp/gotmp/build-artifact"

  case_dir=$(make_case safe-tasktmp)
  write_meta "$case_dir" local-only ship
  printf 'tasktmp=%s\n' "$tasktmp" >> "$case_dir/state/task-x1.meta"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "teardown rejected its exact task temp root: $(cat "$case_dir/stderr")"
  assert_absent "$tasktmp" "teardown retained its exact task temp root"

  case_dir=$(make_case absent-tasktmp)
  write_meta "$case_dir" local-only ship
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "teardown rejected backward-compatible metadata without tasktmp: $(cat "$case_dir/stderr")"
  pass "teardown removes its exact task temp root and accepts metadata without tasktmp"
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

write_secondmate_meta() {
  local case_dir=$1 home
  home=${2:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=fm-task-x1' \
    'tmux_session_target=firstmate:fm-task-x1' \
    "worktree=$home" \
    "project=$home" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$home"
}

test_secondmate_state_enumeration_fails_closed() {
  local case_dir rc
  case_dir=$(make_case missing-secondmate-state)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  rmdir "$case_dir/wt/state"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing secondmate state teardown exit"
  assert_present "$case_dir/wt" "missing state allowed secondmate home removal"
  assert_present "$case_dir/state/task-x1.meta" "missing state allowed secondmate metadata removal"
  assert_grep 'secondmate child state is unprovable' "$case_dir/stderr" \
    "missing secondmate state was not surfaced"

  case_dir=$(make_case unreadable-secondmate-state)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  chmod 100 "$case_dir/wt/state"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 700 "$case_dir/wt/state"
  expect_code 1 "$rc" "unreadable secondmate state teardown exit"
  assert_present "$case_dir/wt" "unreadable state allowed secondmate home removal"
  assert_present "$case_dir/state/task-x1.meta" "unreadable state allowed secondmate metadata removal"
  pass "secondmate child-state enumeration fails closed"
}

test_secondmate_missing_treehouse_child_is_retained() {
  local case_dir child_id missing_worktree rc
  case_dir=$(make_case missing-treehouse-child)
  child_id=missing-child
  missing_worktree="$case_dir/missing-child-worktree"
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  fm_write_meta "$case_dir/wt/state/$child_id.meta" \
    "window=fm-$child_id" \
    "tmux_session_target=firstmate:fm-$child_id" \
    "worktree=$missing_worktree" \
    "project=$case_dir/project" \
    'harness=claude' \
    'kind=ship' \
    'mode=local-only'
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing Treehouse child teardown exit"
  assert_present "$case_dir/wt/state/$child_id.meta" \
    "missing Treehouse child metadata was forgotten"
  assert_present "$case_dir/wt" "missing Treehouse child allowed parent home removal"
  assert_grep 'Treehouse worktree is missing or uninspectable' "$case_dir/stderr" \
    "missing Treehouse child lease blocker was not surfaced"
  pass "missing Treehouse children retain their metadata and parent home"
}

test_secondmate_registry_home_drift_blocks_removal() {
  local case_dir copied rc
  case_dir=$(make_case secondmate-registry-drift)
  prepare_secondmate_home_fixture "$case_dir"
  copied="$case_dir/copied-home"
  cp -R "$case_dir/wt" "$copied"
  write_secondmate_meta "$case_dir" "$copied"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "secondmate registry drift teardown exit"
  assert_present "$copied" "registry drift allowed copied home removal"
  assert_present "$case_dir/wt" "registry drift damaged the registered home"
  assert_present "$case_dir/data/secondmates.md" "registry drift removed the real registration"
  assert_grep 'secondmate registry home for task-x1' "$case_dir/stderr" \
    "secondmate registry drift was not surfaced"
  pass "secondmate retirement requires exact registry-home ownership"
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

test_never_created_direct_spawn_endpoint_is_not_quiesced() {
  local case_dir meta_tmp rc
  case_dir=$(make_case never-created-direct-spawn-endpoint)
  write_meta "$case_dir" local-only ship
  meta_tmp=$(mktemp "$case_dir/state/.never-created-meta.XXXXXX")
  awk '!/^window=/ && !/^tmux_session_target=/' "$case_dir/state/task-x1.meta" > "$meta_tmp"
  printf '%s\n' \
    'window=' \
    'account_home=/tmp/direct-account-home' \
    'direct_spawn_endpoint=not-created' \
    'direct_spawn_cleanup=pending' \
    'rollback_pending=1' >> "$meta_tmp"
  mv "$meta_tmp" "$case_dir/state/task-x1.meta"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "never-created endpoint teardown"
  assert_present "$case_dir/fakebin/.tmux-live" \
    "never-created endpoint cleanup acted on the currently focused tmux endpoint"
  assert_absent "$case_dir/state/task-x1.meta" \
    "never-created endpoint cleanup left completed task metadata"
  pass "never-created direct-spawn endpoint skips endpoint quiescence"
}

test_secondmate_registry_duplicate_home_blocks_removal() {
  local case_dir home rc
  case_dir=$(make_case secondmate-registry-duplicate-home)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  home=$(cd "$case_dir/wt" && pwd -P)
  printf '%s\n' "- other-secondmate - duplicate home (home: $home; scope: test; projects: test; added 2026-07-23)" \
    >> "$case_dir/data/secondmates.md"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate secondmate registry home teardown exit"
  assert_present "$case_dir/wt" "duplicate registry home allowed secondmate removal"
  assert_present "$case_dir/state/task-x1.meta" "duplicate registry home allowed metadata removal"
  assert_grep 'secondmate registry is malformed, duplicated, redirected' "$case_dir/stderr" \
    "duplicate secondmate registry home was not surfaced"
  pass "secondmate retirement rejects registry home aliases"
}

test_secondmate_retirement_retains_idle_registered_child() {
  local case_dir child_home parent_home rc
  case_dir=$(make_case secondmate-idle-registered-child)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  child_home="$case_dir/idle-child-home"
  mkdir -p "$child_home"
  parent_home=$(cd "$case_dir/wt" && pwd -P)
  child_home=$(cd "$child_home" && pwd -P)
  printf '%s\n' "- idle-child - idle child (home: $child_home; scope: idle; projects: ; added 2026-07-23)" \
    > "$parent_home/data/secondmates.md"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "idle registered child must block parent retirement"
  assert_present "$case_dir/wt" "idle registered child allowed parent home removal"
  assert_present "$child_home" "idle registered child home was removed"
  assert_present "$case_dir/state/task-x1.meta" "idle registered child allowed parent metadata removal"
  assert_grep 'has no inspectable child metadata' "$case_dir/stderr" \
    "idle registered child was not surfaced"
  pass "parent retirement retains idle externally registered children"
}

test_secondmate_retirement_retains_unlanded_project_clone() {
  local case_dir rc
  case_dir=$(make_case secondmate-unlanded-project-clone)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  printf 'draft\n' > "$case_dir/wt/projects/test/unlanded.txt"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "unlanded nested project clone must block retirement"
  assert_present "$case_dir/wt/projects/test/unlanded.txt" "force retirement discarded nested project work"
  assert_present "$case_dir/wt" "unlanded nested project clone allowed parent home removal"
  assert_present "$case_dir/state/task-x1.meta" "unlanded nested project clone allowed metadata removal"
  assert_grep 'project clone has unlanded changes' "$case_dir/stderr" \
    "nested project clone work was not surfaced"
  pass "force retirement retains unlanded nested project clones"
}

test_secondmate_project_tags_do_not_prove_landing() {
  local case_dir clone rc
  case_dir=$(make_case secondmate-project-tag-only)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  clone="$case_dir/wt/projects/test"
  printf 'tag only\n' > "$clone/tag-only.txt"
  git -C "$clone" add tag-only.txt
  git -C "$clone" commit -qm "tag-only project work"
  git -C "$clone" tag tag-only-proof
  git -C "$clone" push -q origin refs/tags/tag-only-proof
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "tag-only project reachability must block retirement"
  assert_present "$clone/tag-only.txt" "tag-only project work was discarded"
  assert_present "$case_dir/state/task-x1.meta" "tag-only project work allowed metadata removal"
  assert_grep 'not proven on a live remote branch' "$case_dir/stderr" \
    "tag-only reachability was not distinguished from a durable branch"
  pass "remote tags alone never prove secondmate project work landed"
}

test_secondmate_project_origin_authority_survives_home_removal() {
  local drift_case drift_clone drift_origin in_home_case in_home_clone in_home_origin rc
  drift_case=$(make_case secondmate-project-origin-drift)
  prepare_secondmate_home_fixture "$drift_case"
  write_secondmate_meta "$drift_case"
  drift_clone="$drift_case/wt/projects/test"
  drift_origin="$drift_case/drift-origin.git"
  git clone --quiet --bare "$drift_case/origin.git" "$drift_origin"
  git -C "$drift_clone" remote set-url origin "$drift_origin"
  set +e
  run_teardown "$drift_case" --force > "$drift_case/stdout" 2> "$drift_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "drifted project origin must block retirement"
  assert_present "$drift_clone" "drifted project origin allowed clone removal"
  assert_grep 'origin drifted from its registered source' "$drift_case/stderr" \
    "drifted project origin was not surfaced"

  in_home_case=$(make_case secondmate-project-in-home-origin)
  prepare_secondmate_home_fixture "$in_home_case"
  write_secondmate_meta "$in_home_case"
  in_home_clone="$in_home_case/wt/projects/test"
  in_home_origin="$in_home_case/wt/data/in-home-origin.git"
  git clone --quiet --bare "$in_home_case/origin.git" "$in_home_origin"
  git -C "$in_home_clone" remote set-url origin "$in_home_origin"
  set +e
  run_teardown "$in_home_case" --force > "$in_home_case/stdout" 2> "$in_home_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "in-home project origin must block retirement"
  assert_present "$in_home_origin" "in-home landing authority was deleted"
  assert_grep 'does not survive home removal' "$in_home_case/stderr" \
    "in-home project landing authority was not surfaced"
  pass "project landing authority is bound and survives secondmate removal"
}

test_secondmate_retirement_recurses_into_ignored_nested_repositories() {
  local case_dir source_clone clone nested_origin nested rc
  case_dir=$(make_case secondmate-nested-project-repository)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  source_clone="$case_dir/source-projects/test"
  clone="$case_dir/wt/projects/test"
  nested_origin="$case_dir/nested-origin.git"
  git clone --quiet --bare "$case_dir/origin.git" "$nested_origin"
  git -C "$source_clone" -c protocol.file.allow=always submodule add -q \
    "$nested_origin" vendor/nested
  git -C "$source_clone" commit -qm "register nested project fixture"
  git -C "$source_clone" push -q origin main
  git -C "$clone" pull -q --ff-only
  git -C "$clone" -c protocol.file.allow=always submodule update -q --init
  nested="$clone/vendor/nested"
  printf 'unlanded nested work\n' > "$nested/unlanded.txt"
  git -C "$nested" add unlanded.txt
  git -C "$nested" commit -qm "unlanded nested repository work"
  git -C "$clone" add vendor/nested
  git -C "$clone" commit -qm "reference unlanded nested repository work"
  git -C "$clone" push -q origin main
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "unpushed submodule repository must block retirement"
  assert_present "$nested/unlanded.txt" "unpushed submodule repository work was discarded"
  assert_present "$case_dir/state/task-x1.meta" "nested repository work allowed metadata removal"
  assert_grep 'not proven on a live remote branch' "$case_dir/stderr" \
    "unlanded nested repository ref was not surfaced"
  pass "secondmate retirement recursively proves submodule repositories"
}

test_secondmate_retirement_rejects_linked_worktree_graphs() {
  local nested_case nested_source nested_clone nested_worktree nested_exclude external_case external_clone external_worktree rc
  nested_case=$(make_case secondmate-nested-linked-worktree)
  prepare_secondmate_home_fixture "$nested_case"
  write_secondmate_meta "$nested_case"
  nested_source="$nested_case/source-projects/test"
  nested_clone="$nested_case/wt/projects/test"
  nested_worktree="$nested_clone/linked-owned-elsewhere"
  nested_exclude="$(git -C "$nested_clone" rev-parse --absolute-git-dir)/info/exclude"
  printf '%s\n' '/linked-owned-elsewhere/' >> "$nested_exclude"
  git clone --quiet "$nested_case/origin.git" "$nested_source/linked-owned-elsewhere"
  git -C "$nested_source" worktree add -q -b linked-retirement "$nested_worktree" main
  set +e
  run_teardown "$nested_case" --force > "$nested_case/stdout" 2> "$nested_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "nested linked worktree must block retirement"
  assert_present "$nested_worktree" "nested linked worktree was removed without unregistering its owner"
  assert_present "$nested_case/state/task-x1.meta" "nested linked worktree allowed metadata removal"
  assert_grep 'linked-worktree graph depends on the retiring home' "$nested_case/stderr" \
    "nested linked-worktree ownership was not surfaced"

  external_case=$(make_case secondmate-external-linked-worktree)
  prepare_secondmate_home_fixture "$external_case"
  write_secondmate_meta "$external_case"
  external_clone="$external_case/wt/projects/test"
  external_worktree="$external_case/external-linked-worktree"
  git -C "$external_clone" worktree add -q -b external-retirement "$external_worktree" main
  set +e
  run_teardown "$external_case" --force > "$external_case/stdout" 2> "$external_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "external linked worktree must block common-directory removal"
  assert_present "$external_worktree" "external linked worktree lost its common Git directory"
  assert_present "$external_case/state/task-x1.meta" "external linked worktree allowed metadata removal"
  assert_grep 'owns another linked worktree' "$external_case/stderr" \
    "external linked worktree was not surfaced"
  pass "secondmate retirement retains every linked-worktree graph"
}

test_secondmate_retirement_accounts_for_directory_symlinks() {
  local escape_case escape_clone escape_exclude external cycle_case cycle_clone cycle_exclude rc
  escape_case=$(make_case secondmate-project-symlink-escape)
  prepare_secondmate_home_fixture "$escape_case"
  write_secondmate_meta "$escape_case"
  escape_clone="$escape_case/wt/projects/test"
  external="$escape_case/external-repository"
  git clone --quiet "$escape_case/origin.git" "$external"
  ln -s "$external" "$escape_clone/escaping-repository"
  escape_exclude="$(git -C "$escape_clone" rev-parse --absolute-git-dir)/info/exclude"
  printf '%s\n' '/escaping-repository' >> "$escape_exclude"
  set +e
  run_teardown "$escape_case" --force > "$escape_case/stdout" 2> "$escape_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "escaping repository symlink must block retirement"
  assert_present "$escape_case/wt" "escaping repository symlink allowed home removal"
  assert_grep 'nested project repositories cannot be safely enumerated' "$escape_case/stderr" \
    "escaping repository symlink was not surfaced"

  cycle_case=$(make_case secondmate-project-symlink-cycle)
  prepare_secondmate_home_fixture "$cycle_case"
  write_secondmate_meta "$cycle_case"
  cycle_clone="$cycle_case/wt/projects/test"
  mkdir -p "$cycle_clone/cycle"
  ln -s .. "$cycle_clone/cycle/back"
  cycle_exclude="$(git -C "$cycle_clone" rev-parse --absolute-git-dir)/info/exclude"
  printf '%s\n' '/cycle/' >> "$cycle_exclude"
  set +e
  run_teardown "$cycle_case" --force > "$cycle_case/stdout" 2> "$cycle_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "repository symlink cycle must block retirement"
  assert_present "$cycle_case/wt" "repository symlink cycle allowed home removal"
  assert_grep 'nested project repositories cannot be safely enumerated' "$cycle_case/stderr" \
    "repository symlink cycle was not surfaced"
  pass "secondmate retirement accounts for directory symlinks"
}

test_secondmate_retirement_rejects_loopback_and_stale_tracking_authority() {
  local loopback_case loopback_clone loopback_source loopback_origin stale_case stale_clone unique_tip rc
  loopback_case=$(make_case secondmate-loopback-origin)
  prepare_secondmate_home_fixture "$loopback_case"
  write_secondmate_meta "$loopback_case"
  loopback_clone="$loopback_case/wt/projects/test"
  loopback_source="$loopback_case/source-projects/test"
  loopback_origin="$loopback_case/wt/data/loopback-origin.git"
  git clone --quiet --bare "$loopback_case/origin.git" "$loopback_origin"
  git -C "$loopback_clone" remote set-url origin "ssh://localhost$loopback_origin"
  git -C "$loopback_source" remote set-url origin "ssh://localhost$loopback_origin"
  set +e
  run_teardown "$loopback_case" --force > "$loopback_case/stdout" 2> "$loopback_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "in-home loopback origin must block retirement"
  assert_present "$loopback_origin" "loopback landing authority inside the home was deleted"
  assert_grep 'does not survive home removal' "$loopback_case/stderr" \
    "loopback landing authority was assumed durable"

  stale_case=$(make_case secondmate-stale-remote-tracking-ref)
  prepare_secondmate_home_fixture "$stale_case"
  write_secondmate_meta "$stale_case"
  stale_clone="$stale_case/wt/projects/test"
  git -C "$stale_clone" checkout -q -b stale-only
  printf 'stale tracking work\n' > "$stale_clone/stale-tracking.txt"
  git -C "$stale_clone" add stale-tracking.txt
  git -C "$stale_clone" commit -qm "stale tracking work"
  unique_tip=$(git -C "$stale_clone" rev-parse HEAD)
  git -C "$stale_clone" update-ref refs/remotes/origin/deleted "$unique_tip"
  git -C "$stale_clone" checkout -q main
  git -C "$stale_clone" branch -D stale-only >/dev/null
  set +e
  run_teardown "$stale_case" --force > "$stale_case/stdout" 2> "$stale_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "stale remote-tracking ref must block retirement"
  assert_present "$stale_case/wt" "stale remote-tracking work was discarded"
  assert_present "$stale_case/state/task-x1.meta" "stale remote-tracking ref allowed metadata removal"
  assert_grep 'ref refs/remotes/origin/deleted is not proven on a live remote branch' "$stale_case/stderr" \
    "stale remote-tracking work was not surfaced"
  pass "loopback and stale remote-tracking authority never prove landing"
}

test_secondmate_retirement_rejects_mount_boundaries() {
  local case_dir mounted rc root_case
  case_dir=$(make_case secondmate-project-mount-boundary)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  mounted="$case_dir/wt/projects/test/mounted-storage"
  mkdir -p "$mounted"
  set +e
  FM_TEARDOWN_TEST_MOUNT_PATH="$mounted" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "mounted project subtree must block retirement"
  assert_present "$case_dir/wt" "mounted project subtree allowed home removal"
  assert_present "$case_dir/state/task-x1.meta" "mounted project subtree allowed metadata removal"
  assert_grep 'crosses an untrusted filesystem boundary' "$case_dir/stderr" \
    "mounted project subtree was not surfaced"

  root_case=$(make_case secondmate-mounted-removal-root)
  prepare_secondmate_home_fixture "$root_case"
  write_secondmate_meta "$root_case"
  set +e
  FM_TEARDOWN_TEST_MOUNT_PATH="$root_case/wt" \
    run_teardown "$root_case" --force > "$root_case/stdout" 2> "$root_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "mounted secondmate home root must block retirement"
  assert_present "$root_case/wt" "mounted secondmate home root was traversed"
  assert_present "$root_case/state/task-x1.meta" "mounted secondmate home removed metadata"
  assert_grep 'crosses an untrusted filesystem boundary' "$root_case/stderr" \
    "mounted secondmate home root was not surfaced"

  root_case=$(make_case treehouse-mounted-return-root)
  write_meta "$root_case" local-only ship
  set +e
  FM_TEARDOWN_TEST_MOUNT_PATH="$root_case/wt" \
    run_teardown "$root_case" --force > "$root_case/stdout" 2> "$root_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "mounted Treehouse return root must block teardown"
  assert_present "$root_case/wt" "mounted Treehouse worktree was returned"
  assert_present "$root_case/state/task-x1.meta" "mounted Treehouse return removed metadata"
  pass "secondmate retirement refuses mounted deletion boundaries"
}

test_secondmate_retirement_rejects_effective_ssh_redirects() {
  local case_dir clone source redirect local_origin rc
  case_dir=$(make_case secondmate-effective-ssh-redirect)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  clone="$case_dir/wt/projects/test"
  source="$case_dir/source-projects/test"
  local_origin="$case_dir/wt/data/redirected-origin.git"
  redirect="$case_dir/fakebin/redirect-ssh"
  git clone --quiet --bare "$case_dir/origin.git" "$local_origin"
  cat > "$redirect" <<'SH'
#!/usr/bin/env bash
exec git-upload-pack "${FM_REDIRECT_ORIGIN:?}"
SH
  chmod +x "$redirect"
  git -C "$clone" remote set-url origin ssh://8.8.8.8/repository.git
  git -C "$source" remote set-url origin ssh://8.8.8.8/repository.git
  git -C "$clone" config core.sshCommand "$redirect"
  git -C "$source" config core.sshCommand "$redirect"
  set +e
  FM_REDIRECT_ORIGIN="$local_origin" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "effective SSH redirect must block retirement"
  assert_present "$local_origin" "effective SSH redirect landing authority was deleted"
  assert_present "$case_dir/state/task-x1.meta" "effective SSH redirect allowed metadata removal"
  assert_grep 'remote identity is unsafe' "$case_dir/stderr" \
    "effective SSH transport override was not surfaced"
  pass "effective Git SSH transport must match landing validation"
}

test_secondmate_retirement_rejects_incomplete_surviving_authority() {
  local case_dir source rc promisor_case promisor_source
  case_dir=$(make_case secondmate-shallow-source-authority)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  source="$case_dir/source-projects/test"
  rm -rf "$source"
  git clone --quiet --depth 1 "file://$case_dir/origin.git" "$source"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "shallow source authority must block retirement"
  assert_present "$case_dir/wt" "shallow source authority allowed home removal"
  assert_grep 'is shallow and does not prove a complete surviving object graph' \
    "$case_dir/stderr" "shallow source authority was accepted"

  promisor_case=$(make_case secondmate-promisor-source-authority)
  prepare_secondmate_home_fixture "$promisor_case"
  write_secondmate_meta "$promisor_case"
  promisor_source="$promisor_case/source-projects/test"
  git -C "$promisor_source" config core.repositoryFormatVersion 1
  git -C "$promisor_source" config extensions.partialClone origin
  git -C "$promisor_source" config remote.origin.promisor true
  set +e
  run_teardown "$promisor_case" --force > "$promisor_case/stdout" 2> "$promisor_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "promisor source authority must block retirement"
  assert_present "$promisor_case/wt" "promisor source authority allowed home removal"
  assert_grep 'uses promisor or partial-clone object semantics' \
    "$promisor_case/stderr" "promisor source authority was accepted"
  pass "surviving authorities require complete local object graphs"
}

test_secondmate_retirement_validates_top_level_source_storage() {
  local case_dir owner source root_ref root_tip rc
  case_dir=$(make_case secondmate-top-source-storage)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  owner="$case_dir/wt/data/top-source-owner"
  source="$case_dir/top-source"
  root_ref=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf 'origin/main')
  root_tip=$(git -C "$ROOT" rev-parse "$root_ref")
  git clone --quiet "$ROOT" "$owner"
  git -C "$owner" checkout --quiet --detach "$root_tip"
  git -C "$owner" branch --force main "$root_tip"
  git -C "$owner" update-ref refs/remotes/origin/main "$root_tip"
  git -C "$owner" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$owner" worktree add --quiet "$source" main
  git -C "$case_dir/project" remote set-url origin "$source"
  set +e
  FM_ROOT_OVERRIDE="$source" \
  FM_HOME="$source" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  FM_PROJECTS_OVERRIDE="$case_dir/source-projects" \
  FM_CHECKOUT_REFRESH_LOCK_ROOT="$case_dir/checkout-locks" \
  FM_FAKE_FIRSTMATE_SOURCE="$source" \
  FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "top-level source storage inside retiring home must block retirement"
  assert_present "$owner/.git" "top-level source storage inside retiring home was deleted"
  assert_present "$case_dir/state/task-x1.meta" "top-level source storage allowed metadata removal"
  assert_grep 'secondmate top-level source repository Git storage depends on the retiring home' \
    "$case_dir/stderr" "top-level source storage graph was not validated"
  pass "top-level source storage must survive secondmate retirement"
}

test_secondmate_retirement_rejects_local_network_aliases() {
  local case_dir clone source ssh_home local_origin rc
  case_dir=$(make_case secondmate-local-network-alias)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  clone="$case_dir/wt/projects/test"
  source="$case_dir/source-projects/test"
  local_origin="$case_dir/wt/data/local-alias-origin.git"
  ssh_home="$case_dir/ssh-home"
  mkdir -p "$ssh_home/.ssh"
  chmod 700 "$ssh_home/.ssh"
  git clone --quiet --bare "$case_dir/origin.git" "$local_origin"
  printf '%s\n' \
    'Host local-store-alias' \
    '  HostName localhost' \
    > "$ssh_home/.ssh/config"
  chmod 600 "$ssh_home/.ssh/config"
  git -C "$clone" remote set-url origin "ssh://local-store-alias$local_origin"
  git -C "$source" remote set-url origin "ssh://local-store-alias$local_origin"
  set +e
  FM_TEST_TEARDOWN_HOME="$ssh_home" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "local SSH alias must block retirement"
  assert_present "$local_origin" "local SSH alias landing authority was deleted"
  assert_present "$case_dir/state/task-x1.meta" "local SSH alias allowed metadata removal"
  assert_grep 'remote identity is unsafe' "$case_dir/stderr" \
    "local SSH alias was assumed to be durable network storage"
  pass "network-shaped local aliases never prove durable landing"
}

test_secondmate_retirement_rejects_in_home_remote_object_storage() {
  local case_dir clone source in_home_origin external_authority rc
  case_dir=$(make_case secondmate-remote-object-alternate)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  clone="$case_dir/wt/projects/test"
  source="$case_dir/source-projects/test"
  in_home_origin="$case_dir/wt/data/in-home-object-authority.git"
  external_authority="$case_dir/external-shared-authority.git"
  git clone --quiet --bare "$case_dir/origin.git" "$in_home_origin"
  git clone --quiet --bare --shared "$in_home_origin" "$external_authority"
  git -C "$clone" remote set-url origin "$external_authority"
  git -C "$source" remote set-url origin "$external_authority"
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "remote object alternate inside the home must block retirement"
  assert_present "$in_home_origin" "remote object authority inside the home was deleted"
  assert_present "$case_dir/state/task-x1.meta" "in-home remote object storage allowed metadata removal"
  assert_grep 'object storage is not independently durable' "$case_dir/stderr" \
    "remote object alternates were not included in survival proof"
  pass "landing authority object storage must survive home removal"
}

test_secondmate_retirement_rejects_source_common_dir_in_home() {
  local case_dir source owner rc
  case_dir=$(make_case secondmate-source-common-in-home)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  source="$case_dir/source-projects/test"
  owner="$case_dir/wt/data/source-owner"
  rm -rf "$source"
  git clone --quiet "$case_dir/origin.git" "$owner"
  git -C "$owner" worktree add --quiet --detach "$source" main
  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "source project common directory inside the home must block retirement"
  assert_present "$owner/.git" "source project common directory inside the home was deleted"
  assert_present "$case_dir/state/task-x1.meta" "source common-directory drift allowed metadata removal"
  assert_grep 'registered source project repository Git storage depends on the retiring home' \
    "$case_dir/stderr" "source project storage graph was not validated"
  pass "registered source storage must survive secondmate removal"
}

test_teardown_removal_roots_fail_closed() {
  local missing_case retained caller rc symlink_case target
  missing_case=$(make_case missing-secondmate-removal-root)
  prepare_secondmate_home_fixture "$missing_case"
  write_secondmate_meta "$missing_case"
  retained="$missing_case/retained-home"
  caller="$missing_case/caller"
  mv "$missing_case/wt" "$retained"
  mkdir -p "$caller"
  printf 'caller sentinel\n' > "$caller/sentinel"
  set +e
  (
    cd "$caller" || exit 1
    run_teardown "$missing_case" --force
  ) > "$missing_case/stdout" 2> "$missing_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "missing removal root must fail closed"
  assert_present "$caller/sentinel" "missing removal root deleted the caller working directory"
  assert_present "$retained/.fm-secondmate-home" "missing removal root deleted retained home data"
  assert_present "$missing_case/state/task-x1.meta" "missing removal root removed retry metadata"
  assert_grep 'missing secondmate home removal target' "$missing_case/stderr" \
    "missing removal root was not surfaced"

  symlink_case=$(make_case symlinked-secondmate-removal-root)
  prepare_secondmate_home_fixture "$symlink_case"
  write_secondmate_meta "$symlink_case"
  target="$symlink_case/retained-home"
  mv "$symlink_case/wt" "$target"
  ln -s "$target" "$symlink_case/wt"
  set +e
  run_teardown "$symlink_case" --force > "$symlink_case/stdout" 2> "$symlink_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "symlinked removal root must fail closed"
  assert_present "$target/.fm-secondmate-home" "symlinked removal root traversed its target"
  assert_present "$symlink_case/state/task-x1.meta" "symlinked removal root removed retry metadata"
  assert_grep 'error:' "$symlink_case/stderr" "symlinked removal root was not surfaced"
  pass "missing and redirected removal roots never select another directory"
}

test_treehouse_return_stays_bound_to_validated_root() {
  local case_dir moved redirect marker rc
  case_dir=$(make_case treehouse-return-root-swap)
  write_meta "$case_dir" local-only ship
  moved="$case_dir/moved-worktree"
  redirect="$case_dir/redirect-target"
  marker="$case_dir/bound-root-observed"
  mkdir -p "$case_dir/wt/retained-descendant"
  printf 'validated worktree\n' > "$case_dir/wt/.bound-root-identity"
  printf 'retained descendant\n' > "$case_dir/wt/retained-descendant/identity"
  git -C "$case_dir/wt" add .bound-root-identity retained-descendant/identity
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -qm "record bound worktree identity"
  add_fork_with_pushed_branch "$case_dir"
  rm -f "$case_dir/fakebin/.tmux-live"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "$1" = return ] && [ "$2" = --force ] || exit 91
[ "$3" = "." ] || exit 92
[ "$FM_TREEHOUSE_RETURN_PROJECT" = "$FM_TREEHOUSE_EXPECT_PROJECT" ] || exit 93
bound_target=$3
old_ifs=$IFS
IFS=,
set -- $FM_TREEHOUSE_RETURN_BOUNDARY_FDS
IFS=$old_ifs
[ "$#" -ge 2 ] || exit 95
for descriptor in "$@"; do
  [ -d "/dev/fd/$descriptor" ] || exit 96
done
mv "$FM_TREEHOUSE_SWAP_TARGET" "$FM_TREEHOUSE_MOVED_TARGET" || exit 92
mkdir -p "$FM_TREEHOUSE_REDIRECT_TARGET" || exit 93
printf 'redirect target\n' > "$FM_TREEHOUSE_REDIRECT_TARGET/.bound-root-identity"
ln -s "$FM_TREEHOUSE_REDIRECT_TARGET" "$FM_TREEHOUSE_SWAP_TARGET" || exit 94
[ "$(cat "$bound_target/.bound-root-identity")" = "validated worktree" ] || exit 97
[ "$(cat "$bound_target/retained-descendant/identity")" = "retained descendant" ] || exit 98
: > "$FM_TREEHOUSE_BOUND_MARKER"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  set +e
  FM_TREEHOUSE_SWAP_TARGET="$case_dir/wt" \
  FM_TREEHOUSE_MOVED_TARGET="$moved" \
  FM_TREEHOUSE_REDIRECT_TARGET="$redirect" \
  FM_TREEHOUSE_EXPECT_PROJECT="$case_dir/project" \
  FM_TREEHOUSE_BOUND_MARKER="$marker" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || fail "identity-bound Treehouse return exited unexpectedly"
  [ -e "$marker" ] || fail \
    "Treehouse return did not execute from the validated worktree descriptor: $(cat "$case_dir/stderr")"
  assert_grep 'redirect target' "$redirect/.bound-root-identity" \
    "Treehouse return traversed the replacement symlink target"
  pass "Treehouse return remains bound across pathname replacement"
}

test_teardown_distinguishes_dead_and_live_harness_processes() {
  local dead_case live_case rc
  dead_case=$(make_case dead-harness-endpoint)
  write_meta "$dead_case" local-only ship
  cat > "$dead_case/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
state="$(dirname "$0")/.tmux-live"
case "${1:-}" in
  display-message)
    [ -f "$state" ] || exit 1
    case " $* " in *pane_current_command*) printf 'zsh\n' ;; esac
    ;;
  list-windows) [ ! -f "$state" ] || printf '%s\n' fm-task-x1 ;;
  kill-window) rm -f "$state" ;;
esac
exit 0
SH
  chmod +x "$dead_case/fakebin/tmux"
  run_teardown "$dead_case" --force > "$dead_case/stdout" 2> "$dead_case/stderr" \
    || fail "dead harness endpoint false-refused teardown: $(cat "$dead_case/stderr")"
  assert_absent "$dead_case/fakebin/.tmux-live" \
    "dead harness process left its managed endpoint behind"
  assert_absent "$dead_case/state/task-x1.meta" "dead harness endpoint retained task metadata"

  live_case=$(make_case live-harness-endpoint)
  write_meta "$live_case" local-only ship
  cat > "$live_case/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case " $* " in *pane_current_command*) printf 'codex\n' ;; esac
    exit 0
    ;;
  list-windows) printf '%s\n' fm-task-x1 ;;
  kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$live_case/fakebin/tmux"
  set +e
  run_teardown "$live_case" --force > "$live_case/stdout" 2> "$live_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "live harness process must block teardown"
  assert_present "$live_case/state/task-x1.meta" "live harness process removed retry metadata"
  assert_grep 'endpoint for task-x1 is still alive' "$live_case/stderr" \
    "live harness process was not surfaced"
  pass "teardown distinguishes dead harnesses from live processes"
}

test_secondmate_retirement_retains_reflog_and_rewritten_history() {
  local reflog_case clone unique_tip rc rewrite_case grafts
  reflog_case=$(make_case secondmate-reflog-only-history)
  prepare_secondmate_home_fixture "$reflog_case"
  write_secondmate_meta "$reflog_case"
  clone="$reflog_case/wt/projects/test"
  git -C "$clone" checkout -q -b reflog-only
  printf 'recoverable history\n' > "$clone/reflog-only.txt"
  git -C "$clone" add reflog-only.txt
  git -C "$clone" commit -qm "reflog-only project work"
  unique_tip=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" reset -q --hard HEAD^
  git -C "$clone" checkout -q main
  git -C "$clone" branch -D reflog-only >/dev/null
  set +e
  run_teardown "$reflog_case" --force > "$reflog_case/stdout" 2> "$reflog_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "reflog-only project history must block retirement"
  assert_present "$reflog_case/wt" "reflog-only project history allowed home removal"
  assert_present "$reflog_case/state/task-x1.meta" "reflog-only history removed retry metadata"
  assert_grep "$unique_tip" "$reflog_case/stderr" "reflog-only commit was not inventoried"

  rewrite_case=$(make_case secondmate-grafted-history)
  prepare_secondmate_home_fixture "$rewrite_case"
  write_secondmate_meta "$rewrite_case"
  clone="$rewrite_case/wt/projects/test"
  grafts=$(git -C "$clone" rev-parse --git-path info/grafts)
  case "$grafts" in /*) ;; *) grafts="$clone/$grafts" ;; esac
  mkdir -p "$(dirname "$grafts")"
  printf '%s\n' "$(git -C "$clone" rev-parse HEAD)" > "$grafts"
  set +e
  run_teardown "$rewrite_case" --force > "$rewrite_case/stdout" 2> "$rewrite_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "grafted project history must block retirement"
  assert_present "$rewrite_case/wt" "grafted project history allowed home removal"
  assert_grep 'uses local grafted history' "$rewrite_case/stderr" \
    "grafted history was not surfaced"
  pass "retirement retains reflog-only and rewritten Git history"
}

test_secondmate_retirement_rejects_http_proxy_and_object_redirects() {
  local proxy_case clone source rc object_case objects pack redirected
  proxy_case=$(make_case secondmate-scoped-http-proxy)
  prepare_secondmate_home_fixture "$proxy_case"
  write_secondmate_meta "$proxy_case"
  clone="$proxy_case/wt/projects/test"
  source="$proxy_case/source-projects/test"
  git -C "$clone" remote set-url origin https://example.com/repository.git
  git -C "$source" remote set-url origin https://example.com/repository.git
  git -C "$clone" config 'http.https://example.com.proxy' http://127.0.0.1:9
  git -C "$source" config 'http.https://example.com.proxy' http://127.0.0.1:9
  set +e
  run_teardown "$proxy_case" --force > "$proxy_case/stdout" 2> "$proxy_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "URL-scoped HTTP proxy must block retirement"
  assert_present "$proxy_case/wt" "URL-scoped HTTP proxy allowed home removal"
  assert_grep 'remote identity is unsafe' "$proxy_case/stderr" \
    "URL-scoped HTTP proxy was not surfaced"

  object_case=$(make_case secondmate-object-file-redirect)
  prepare_secondmate_home_fixture "$object_case"
  write_secondmate_meta "$object_case"
  source="$object_case/source-projects/test"
  git -C "$source" gc --quiet --prune=now
  objects=$(git -C "$source" rev-parse --git-path objects)
  case "$objects" in /*) ;; *) objects="$source/$objects" ;; esac
  pack=$(find "$objects/pack" -type f -name '*.pack' -print -quit)
  [ -n "$pack" ] || fail "object redirect fixture did not create a pack"
  redirected="$object_case/wt/data/$(basename "$pack")"
  mv "$pack" "$redirected"
  ln -s "$redirected" "$pack"
  set +e
  run_teardown "$object_case" --force > "$object_case/stdout" 2> "$object_case/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "redirected pack storage must block retirement"
  assert_present "$redirected" "redirected pack storage inside home was deleted"
  assert_present "$object_case/state/task-x1.meta" "redirected object storage removed retry metadata"
  assert_grep 'redirected object storage entry' "$object_case/stderr" \
    "redirected pack storage was not surfaced"
  pass "HTTP routing and object-file redirects never prove durable landing"
}

test_secondmate_network_fetches_pin_validated_addresses() {
  local case_dir clone source tip rc count
  case_dir=$(make_case secondmate-pinned-network-authority)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  clone="$case_dir/wt/projects/test"
  source="$case_dir/source-projects/test"
  tip=$(git -C "$source" rev-parse refs/remotes/origin/main)
  git -C "$clone" remote set-url origin https://example.com/repository.git
  git -C "$source" remote set-url origin https://example.com/repository.git
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
network_operation=
pin=
any_pin=
repository=
previous=
network_target=
for argument in "$@"; do
  if [ "$previous" = -C ]; then
    repository=$argument
  fi
  case "$argument" in
    ls-remote|fetch) network_operation=$argument ;;
    http.curloptResolve=example.com:443:*) pin=$argument; any_pin=$argument ;;
    http.curloptResolve=*) any_pin=$argument ;;
    https://example.com/repository.git) network_target=1 ;;
  esac
  previous=$argument
done
case " $* " in
  *" ls-remote --symref origin HEAD "*|*" ls-remote --symref origin HEAD")
    if [ "$repository" = "$FM_FAKE_FIRSTMATE_SOURCE" ]; then
      [ -n "$any_pin" ] || exit 88
      remote_head=$("$FM_REAL_GIT" -C "$FM_FAKE_FIRSTMATE_SOURCE" \
        symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf 'origin/main')
      remote_tip=$("$FM_REAL_GIT" -C "$FM_FAKE_FIRSTMATE_SOURCE" rev-parse "$remote_head")
      printf 'ref: refs/heads/%s\tHEAD\n%s\tHEAD\n' "${remote_head#origin/}" "$remote_tip"
      exit 0
    fi
    ;;
esac
if [ -n "$network_operation" ]; then
  if [ -z "$network_target" ] && [ -n "$repository" ]; then
    remote=$("$FM_REAL_GIT" -C "$repository" remote get-url origin 2>/dev/null || true)
    [ "$remote" != https://example.com/repository.git ] || network_target=1
  fi
  [ -n "$network_target" ] || exec "$FM_REAL_GIT" "$@"
  printf '%s\t%s\n' "$network_operation" "$pin" >> "$FM_GIT_PIN_LOG"
  [ -n "$pin" ] || exit 88
  if [ "$network_operation" = ls-remote ]; then
    printf 'ref: refs/heads/main\tHEAD\n%s\tHEAD\n' "$FM_PINNED_TIP"
    exit 0
  fi
  exit 89
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$case_dir/fakebin/git"
  : > "$case_dir/pinned-network.log"
  set +e
  FM_REAL_GIT="$(command -v git)" \
  FM_GIT_PIN_LOG="$case_dir/pinned-network.log" \
  FM_PINNED_TIP="$tip" \
  FM_TEARDOWN_TEST_NETWORK_ADDRESSES=203.0.113.10 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "synthetic pinned authority fetch stops before retirement"
  count=$(wc -l < "$case_dir/pinned-network.log" | tr -d ' ')
  [ "$count" -ge 1 ] || fail \
    "network authority did not exercise its graph probe: $(cat "$case_dir/pinned-network.log"); teardown: $(cat "$case_dir/stderr")"
  if grep -v $'\thttp.curloptResolve=example.com:443:' "$case_dir/pinned-network.log" >/dev/null; then
    fail "network authority re-resolved an unpinned hostname: $(cat "$case_dir/pinned-network.log")"
  fi
  assert_present "$case_dir/wt" "failed pinned authority proof removed the secondmate home"
  pass "network authority fetches retain validated address bindings"
}

test_surviving_object_storage_is_bound_through_graph_proof() {
  local case_dir source objects pack redirected marker release teardown_pid rc waited
  case_dir=$(make_case secondmate-object-storage-toctou)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  source="$case_dir/source-projects/test"
  git -C "$source" gc --quiet --prune=now
  objects=$(git -C "$source" rev-parse --git-path objects)
  case "$objects" in /*) ;; *) objects="$source/$objects" ;; esac
  pack=$(find "$objects/pack" -type f -name '*.pack' -print -quit)
  [ -n "$pack" ] || fail "object-storage identity fixture did not create a pack"
  redirected="$case_dir/wt/data/$(basename "$pack")"
  marker="$case_dir/object-scan-ready"
  release="$case_dir/object-scan-release"
  FM_TEARDOWN_TEST_OBJECT_SCAN_ROOT="$objects" \
  FM_TEARDOWN_TEST_OBJECT_SCAN_MARKER="$marker" \
  FM_TEARDOWN_TEST_OBJECT_SCAN_RELEASE="$release" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" &
  teardown_pid=$!
  waited=0
  while [ ! -f "$marker" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ ! -f "$marker" ]; then
    : > "$release"
    wait "$teardown_pid" || true
    fail "object-storage graph proof did not expose its retained-identity boundary"
  fi
  mv "$pack" "$redirected"
  ln -s "$redirected" "$pack"
  : > "$release"
  set +e
  wait "$teardown_pid"
  rc=$?
  set -e
  expect_code 1 "$rc" "object storage replacement during graph proof must fail closed"
  assert_present "$case_dir/wt" "object storage replacement allowed secondmate home removal"
  assert_grep 'object storage identity changed during graph proof' "$case_dir/stderr" \
    "object storage replacement was not detected under retained identities"
  pass "surviving object storage remains identity-bound through graph proof"
}

test_secondmate_retirement_serializes_child_spawn() {
  local case_dir child_project rc teardown_pid spawn_rc waited
  case_dir=$(make_case secondmate-retirement-child-race)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  child_project="$case_dir/wt/projects/child-project"
  fm_git_init_commit "$child_project"
  mkdir -p "$case_dir/wt/data/child"
  printf '%s\n' 'Do bounded child work.' > "$case_dir/wt/data/child/brief.md"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
state="$(dirname "$0")/.tmux-live"
started="$(dirname "$0")/.retirement-started"
release="$(dirname "$0")/.retirement-release"
case "${1:-}" in
  display-message) [ -f "$state" ]; exit $? ;;
  list-windows) [ ! -f "$state" ] || printf '%s\n' fm-task-x1; exit 0 ;;
  kill-window)
    : > "$started"
    while [ ! -f "$release" ]; do sleep 0.05; done
    rm -f "$state"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" &
  teardown_pid=$!
  waited=0
  while [ ! -f "$case_dir/fakebin/.retirement-started" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$case_dir/fakebin/.retirement-started" ] || {
    : > "$case_dir/fakebin/.retirement-release"
    wait "$teardown_pid" || true
    fail "secondmate retirement did not reach the serialized quiescence boundary"
  }
  set +e
  FM_HOME="$case_dir/wt" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_CHECKOUT_REFRESH_LOCK_ROOT="$case_dir/checkout-locks" \
  FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 \
  FM_SPAWN_NO_GUARD=1 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" child child-project claude \
      > "$case_dir/spawn-stdout" 2> "$case_dir/spawn-stderr"
  spawn_rc=$?
  set -e
  : > "$case_dir/fakebin/.retirement-release"
  set +e
  wait "$teardown_pid"
  rc=$?
  set -e
  expect_code 1 "$spawn_rc" "child spawn during secondmate retirement exit"
  assert_grep 'secondmate home lifecycle lock' "$case_dir/spawn-stderr" \
    "child spawn did not contend on the retiring secondmate home"
  expect_code 0 "$rc" "serialized secondmate retirement exit"
  assert_absent "$case_dir/wt" "serialized secondmate retirement retained the home"
  assert_absent "$case_dir/state/task-x1.meta" "serialized secondmate retirement retained metadata"
  pass "secondmate retirement serializes child spawn through removal"
}

test_nested_secondmate_cleanup_requires_child_home_lock() {
  local case_dir nested holder_pid waited rc
  case_dir=$(make_case nested-secondmate-home-lock)
  prepare_secondmate_home_fixture "$case_dir"
  write_secondmate_meta "$case_dir"
  nested="$case_dir/nested-home"
  git clone --quiet "$case_dir/wt" "$nested"
  mkdir -p "$nested/data" "$nested/state" "$nested/config" "$nested/projects"
  printf '%s\n' nested > "$nested/.fm-secondmate-home"
  printf '%s\n' "- nested - nested secondmate (home: $nested; scope: nested; projects: ; added 2026-07-23)" \
    > "$case_dir/wt/data/secondmates.md"
  fm_write_meta "$case_dir/wt/state/nested.meta" \
    'window=fm-nested' \
    'tmux_session_target=firstmate:fm-nested' \
    "worktree=$nested" \
    "project=$nested" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$nested"
  bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    lock=$(fm_secondmate_home_lifecycle_lock_acquire "$2" "$3") || exit 1
    : > "$4"
    while [ ! -f "$5" ]; do sleep 0.05; done
    fm_account_lifecycle_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/checkout-locks" "$nested" \
    "$case_dir/nested-lock-ready" "$case_dir/nested-lock-release" &
  holder_pid=$!
  waited=0
  while [ ! -f "$case_dir/nested-lock-ready" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$case_dir/nested-lock-ready" ] || {
    : > "$case_dir/nested-lock-release"
    wait "$holder_pid" || true
    fail "nested secondmate lock holder did not start"
  }
  set +e
  FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  : > "$case_dir/nested-lock-release"
  wait "$holder_pid" || fail "nested secondmate lock holder failed to release"
  expect_code 1 "$rc" "nested secondmate home lock teardown exit"
  assert_present "$nested" "nested lock contention allowed child home removal"
  assert_present "$case_dir/wt/state/nested.meta" "nested lock contention removed child metadata"
  assert_present "$case_dir/wt" "nested lock contention allowed parent home removal"
  assert_grep 'secondmate home lifecycle lock' "$case_dir/stderr" \
    "nested secondmate home lock contention was not surfaced"
  pass "recursive secondmate cleanup acquires each child home lock"
}

test_secondmate_registry_updates_are_locked_and_literal() {
  local case_dir id other_home holder_pid waited rc
  case_dir=$(make_case secondmate-registry-locked-literal)
  id='foo.bar'
  prepare_secondmate_home_fixture "$case_dir" "$id"
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=fm-$id" \
    "tmux_session_target=firstmate:fm-$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/wt" \
    'kind=secondmate' \
    'mode=secondmate' \
    "home=$case_dir/wt"
  other_home="$case_dir/other-home"
  mkdir -p "$other_home"
  printf '%s\n' "- fooxbar - retained neighbor (home: $other_home; scope: neighbor; projects: test; added 2026-07-23)" \
    >> "$case_dir/data/secondmates.md"
  bash -c '
    . "$1/bin/fm-account-routing-lib.sh"
    lock=$(fm_secondmate_registry_lock_acquire "$2" "$3") || exit 1
    : > "$4"
    while [ ! -f "$5" ]; do sleep 0.05; done
    fm_account_lifecycle_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/checkout-locks" "$case_dir/data/secondmates.md" \
    "$case_dir/registry-lock-ready" "$case_dir/registry-lock-release" &
  holder_pid=$!
  waited=0
  while [ ! -f "$case_dir/registry-lock-ready" ] && [ "$waited" -lt 200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$case_dir/registry-lock-ready" ] || {
    : > "$case_dir/registry-lock-release"
    wait "$holder_pid" || true
    fail "registry lock holder did not start"
  }
  set +e
  FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=0 \
    run_teardown_named "$case_dir" "$id" --force > "$case_dir/locked-stdout" 2> "$case_dir/locked-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "registry-locked teardown exit"
  assert_present "$case_dir/wt" "registry lock contention allowed home removal"
  assert_grep 'fooxbar' "$case_dir/data/secondmates.md" \
    "registry lock contention overwrote a neighboring registration"
  : > "$case_dir/registry-lock-release"
  wait "$holder_pid" || fail "registry lock holder failed to release"
  run_teardown_named "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "dotted-id teardown failed after registry lock release: $(cat "$case_dir/stderr")"
  assert_grep '- fooxbar ' "$case_dir/data/secondmates.md" \
    "retiring foo.bar removed the literal neighbor fooxbar"
  assert_no_grep '- foo.bar ' "$case_dir/data/secondmates.md" \
    "retiring foo.bar left its exact registry entry"
  pass "secondmate registry updates are serialized and compare ids literally"
}

if [ "${FM_TEST_FOCUSED:-}" = tasktmp-safety ]; then
  test_teardown_removes_safe_tasktmp_and_accepts_absence
  test_teardown_refuses_unsafe_tasktmp_metadata
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = managed-force-release ]; then
  test_managed_force_teardown_retains_unlanded_lease_and_session
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = managed-endpoint-identity ]; then
  test_managed_force_teardown_retains_unlanded_lease_and_session
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
  test_never_created_direct_spawn_endpoint_is_not_quiesced
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-teardown-state ]; then
  test_secondmate_state_enumeration_fails_closed
  test_secondmate_missing_treehouse_child_is_retained
  test_secondmate_registry_home_drift_blocks_removal
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

if [ "${FM_TEST_FOCUSED:-}" = review-round-8 ]; then
  test_content_in_default_fallback_allows
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-9 ]; then
  test_forced_secondmate_retains_child_on_checkout_lock_contention
  test_locked_return_reuses_checkout_lock_for_landing_recheck
  test_treehouse_return_timeout_reaps_children_before_unlock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-10-treehouse-return ]; then
  test_forced_secondmate_retains_child_on_treehouse_failure
  test_forced_secondmate_retains_child_when_treehouse_unavailable
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-11-process-group ]; then
  test_forced_secondmate_retains_child_on_treehouse_failure
  test_treehouse_return_timeout_reaps_children_before_unlock
  test_forced_secondmate_retains_unverified_process_group
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-12-ownership ]; then
  test_forced_secondmate_retains_child_on_treehouse_failure
  test_treehouse_return_timeout_reaps_children_before_unlock
  test_forced_secondmate_retains_unverified_process_group
  test_bounded_runner_preserves_command_status_125
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-refresh-safety ]; then
  test_legacy_teardown_revalidates_after_quiescence
  test_teardown_rejects_nested_metadata_roots_before_quiescence
  test_teardown_retains_untracked_claude_skill_draft
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-teardown-ownership ]; then
  test_teardown_rejects_drifted_treehouse_task_lease
  test_teardown_rechecks_treehouse_lease_after_locked_safety
  test_secondmate_rejects_drifted_home_repository_identity
  test_normal_secondmate_retires_proven_detached_head
  test_forced_secondmate_retains_untracked_skill_draft
  test_forced_secondmate_retains_unique_detached_head
  test_forced_secondmate_retains_stash
  test_forced_secondmate_retains_unlanded_child_work
  test_forced_secondmate_retains_unquiesced_unmanaged_child
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-teardown-lifecycle ]; then
  test_secondmate_registry_duplicate_home_blocks_removal
  test_secondmate_retirement_serializes_child_spawn
  test_nested_secondmate_cleanup_requires_child_home_lock
  test_secondmate_registry_updates_are_locked_and_literal
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-durable-secondmate ]; then
  test_normal_secondmate_retires_proven_detached_head
  test_secondmate_retirement_retains_idle_registered_child
  test_secondmate_retirement_retains_unlanded_project_clone
  test_secondmate_project_tags_do_not_prove_landing
  test_secondmate_project_origin_authority_survives_home_removal
  test_secondmate_retirement_recurses_into_ignored_nested_repositories
  test_secondmate_retirement_rejects_linked_worktree_graphs
  test_secondmate_retirement_accounts_for_directory_symlinks
  test_secondmate_retirement_rejects_loopback_and_stale_tracking_authority
  test_secondmate_retirement_rejects_mount_boundaries
  test_secondmate_retirement_rejects_effective_ssh_redirects
  test_secondmate_retirement_rejects_incomplete_surviving_authority
  test_secondmate_retirement_validates_top_level_source_storage
  test_secondmate_retirement_rejects_local_network_aliases
  test_secondmate_retirement_rejects_in_home_remote_object_storage
  test_secondmate_retirement_rejects_source_common_dir_in_home
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13-safety ]; then
  test_teardown_removal_roots_fail_closed
  test_treehouse_return_stays_bound_to_validated_root
  test_teardown_distinguishes_dead_and_live_harness_processes
  test_secondmate_retirement_retains_reflog_and_rewritten_history
  test_secondmate_retirement_rejects_http_proxy_and_object_redirects
  test_secondmate_retirement_rejects_incomplete_surviving_authority
  test_secondmate_network_fetches_pin_validated_addresses
  test_surviving_object_storage_is_bound_through_graph_proof
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-13-network ]; then
  test_secondmate_network_fetches_pin_validated_addresses
  test_surviving_object_storage_is_bound_through_graph_proof
  exit 0
fi

test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_retains_unpushed
test_managed_force_teardown_retains_unlanded_lease_and_session
test_managed_teardown_retains_lease_when_endpoint_state_is_unknown
test_managed_release_failure_preserves_unrecycled_worktree_for_retry
test_managed_teardown_locks_generation_before_endpoint_cleanup
test_managed_child_teardown_locks_generation_before_snapshot
test_forced_secondmate_child_uses_child_home_for_endpoint_verification
test_forced_secondmate_quiesces_parent_before_child_cleanup
test_forced_secondmate_retains_child_on_treehouse_failure
test_forced_secondmate_retains_unverified_process_group
test_forced_secondmate_retains_child_when_treehouse_unavailable
test_forced_secondmate_retains_child_on_checkout_lock_contention
test_herdr_teardown_clears_escalation_marker
test_required_report_blocks_then_publishes_before_cleanup
test_required_report_restores_rollback_generation_before_publish
test_required_report_revalidates_after_quiescence
test_legacy_teardown_revalidates_after_quiescence
test_teardown_rejects_nested_metadata_roots_before_quiescence
test_teardown_rejects_drifted_treehouse_task_lease
test_teardown_rechecks_treehouse_lease_after_locked_safety
test_secondmate_rejects_drifted_home_repository_identity
test_normal_secondmate_retires_proven_detached_head
test_forced_secondmate_retains_untracked_skill_draft
test_forced_secondmate_retains_unique_detached_head
test_forced_secondmate_retains_stash
test_forced_secondmate_retains_unlanded_child_work
test_forced_secondmate_retains_unquiesced_unmanaged_child
test_secondmate_registry_duplicate_home_blocks_removal
test_secondmate_retirement_retains_idle_registered_child
test_secondmate_retirement_retains_unlanded_project_clone
test_secondmate_project_tags_do_not_prove_landing
test_secondmate_project_origin_authority_survives_home_removal
test_secondmate_retirement_recurses_into_ignored_nested_repositories
test_secondmate_retirement_rejects_linked_worktree_graphs
test_secondmate_retirement_accounts_for_directory_symlinks
test_secondmate_retirement_rejects_loopback_and_stale_tracking_authority
test_secondmate_retirement_rejects_mount_boundaries
test_secondmate_retirement_rejects_effective_ssh_redirects
test_secondmate_retirement_rejects_incomplete_surviving_authority
test_secondmate_retirement_validates_top_level_source_storage
test_secondmate_retirement_rejects_local_network_aliases
test_secondmate_retirement_rejects_in_home_remote_object_storage
test_secondmate_retirement_rejects_source_common_dir_in_home
test_teardown_removal_roots_fail_closed
test_treehouse_return_stays_bound_to_validated_root
test_teardown_distinguishes_dead_and_live_harness_processes
test_secondmate_retirement_retains_reflog_and_rewritten_history
test_secondmate_retirement_rejects_http_proxy_and_object_redirects
test_secondmate_network_fetches_pin_validated_addresses
test_surviving_object_storage_is_bound_through_graph_proof
test_secondmate_retirement_serializes_child_spawn
test_nested_secondmate_cleanup_requires_child_home_lock
test_secondmate_registry_updates_are_locked_and_literal
test_teardown_retains_untracked_claude_skill_draft
test_teardown_refuses_unsafe_tasktmp_metadata
test_teardown_removes_safe_tasktmp_and_accepts_absence
test_teardown_rejects_malformed_report_requirement
test_secondmate_state_enumeration_fails_closed
test_secondmate_missing_treehouse_child_is_retained
test_secondmate_registry_home_drift_blocks_removal
test_retained_direct_spawn_requires_confirmed_endpoint_quiescence
test_never_created_direct_spawn_endpoint_is_not_quiesced
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
test_locked_return_reuses_checkout_lock_for_landing_recheck
test_treehouse_return_timeout_reaps_children_before_unlock
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
