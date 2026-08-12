#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety check.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers two fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
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
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin token
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  token="teardown-$name"
  : > "$case_dir/data/backlog.md"
  printf 'root=%s\ntoken=%s\n' "$ROOT" "$token" > "$case_dir/state/.primary-attestation"
  chmod 600 "$case_dir/state/.primary-attestation"
  printf '%s\n' '1|codex:teardown-fixture|fallback' > "$case_dir/state/.lock"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# Minimal endpoint inventory for the exact task window used by these fixtures.
if [ -n "${FM_FAKE_TMUX_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
fi
if [ "${1:-}" = list-windows ]; then
  if [ "${FM_FAKE_TMUX_QUERY_ERROR:-0}" = 1 ]; then
    printf '%s\n' 'tmux query failed' >&2
    exit 1
  fi
  case " $* " in
    *"#{window_id}|#{session_name}:#{window_name}"*) printf '%s\n' '@1|firstmate:fm-task-x1' ;;
    *"#{window_id} #{window_name}"*) printf '%s\n' '@1 fm-task-x1' ;;
    *"#{window_id}"*) printf '%s\n' '@1' ;;
    *"#{window_name}"*) printf '%s\n' 'fm-task-x1' ;;
  esac
  exit 0
fi
if [ "${1:-}" = display-message ]; then
  case " $* " in
    *"#{pane_pid}"*) printf '%s\n' "$$" ;;
    *"#{pane_current_command}"*) printf '%s\n' bash ;;
    *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_TMUX_PATH:-$PWD}" ;;
    *"#{window_name}"*) printf '%s\n' fm-task-x1 ;;
  esac
  exit 0
fi
if [ "${1:-}" = kill-window ] && [ -n "${FM_FAKE_TMUX_REPLACE_META:-}" ]; then
  printf '%s\n' 'generation=replacement' > "$FM_FAKE_TMUX_REPLACE_META"
fi
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
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tasks-axi"
}

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3 stamp_home=${FM_HOME:-$case_dir} state=${FM_STATE_OVERRIDE:-$case_dir/state}
  mkdir -p "$state"
  fm_write_meta "$state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$case_dir/wt" task-x1 "$stamp_home" ) \
    || fail "could not stamp the task worktree ownership fixture"
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
      *"headRefName"*) printf '%s\n' 'fm/task-x1' ; exit 0 ;;
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

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1 token
  shift
  token=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' \
    "$case_dir/state/.primary-attestation" 2>/dev/null || true)
  FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$ROOT}" \
  FM_HOME="${FM_HOME:-$case_dir}" \
  FM_PRIMARY_ATTESTATION="${FM_PRIMARY_ATTESTATION:-$token}" \
  CODEX_THREAD_ID=teardown-fixture \
  FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$case_dir/state}" \
  FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-$case_dir/config}" \
  FM_FAKE_TMUX_REPLACE_META="${FM_FAKE_TMUX_REPLACE_META:-}" \
  FM_FAKE_TMUX_PATH="${FM_FAKE_TMUX_PATH:-$case_dir/wt}" \
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

test_teardown_reconciles_consumed_presentation_receipt() {
  local case_dir receipt
  case_dir=$(make_case presentation-receipt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  receipt="$case_dir/state/task-x1.pr-presentation"
  cat > "$receipt" <<'EOF'
firstmate-pr-presentation-v1
pr=https://github.com/example/repo/pull/7
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  chmod 0600 "$receipt"
  run_teardown "$case_dir" >/dev/null || fail 'teardown refused valid leftover presentation receipt'
  assert_absent "$receipt" 'teardown left a validated presentation receipt orphaned'
  pass 'teardown reconciles a validated leftover v1 presentation receipt'
}

test_teardown_refuses_foreign_presentation_receipt() {
  local case_dir receipt rc
  case_dir=$(make_case presentation-foreign)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  receipt="$case_dir/state/task-x1.pr-presentation"
  cat > "$receipt" <<'EOF'
firstmate-pr-presentation-v2
pr=https://github.com/example/repo/pull/8
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
presented_pr_base_ref=main
presented_pr_base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
presentation_nonce=11111111111111111111111111111111
EOF
  chmod 0600 "$receipt"
  set +e; run_teardown "$case_dir" >/dev/null 2>"$case_dir/stderr"; rc=$?; set -e
  expect_code 1 "$rc" 'foreign presentation receipt must fail closed'
  assert_present "$receipt" 'foreign presentation receipt was removed'
  assert_present "$case_dir/state/task-x1.meta" 'foreign presentation receipt allowed task cleanup'
  pass 'teardown preserves task state on foreign presentation evidence'
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

test_teardown_refuses_unsafe_tasktmp() {
  local case_dir rc victim
  case_dir=$(make_case unsafe-tasktmp)
  write_meta "$case_dir" no-mistakes ship
  victim="$case_dir/victim"
  mkdir -p "$victim"
  printf 'keep\n' > "$victim/keep.txt"
  printf 'tasktmp=%s\n' "$victim" >> "$case_dir/state/task-x1.meta"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-tasktmp: teardown should refuse unsafe tasktmp metadata"
  assert_present "$victim/keep.txt" "unsafe-tasktmp: teardown must not delete meta-provided arbitrary paths"
  grep -q "unsafe tasktmp" "$case_dir/stderr" || fail "unsafe-tasktmp: refusal did not cite unsafe tasktmp"
  pass "teardown refuses arbitrary tasktmp cleanup targets from meta"
}

# An interrupted durable return must never become a permanent one-way door: the
# refusal has to hand the operator the exact recovery for state/<id>.meta.
test_teardown_refusal_on_incomplete_return_prints_recovery() {
  local case_dir rc
  case_dir=$(make_case incomplete-return)
  write_meta "$case_dir" no-mistakes ship
  printf 'slot_returning=1\n' >> "$case_dir/state/task-x1.meta"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "incomplete-return: teardown must refuse while a durable return is incomplete"
  grep -q 'durable return for task-x1 is incomplete' "$case_dir/stderr" \
    || fail "incomplete-return: refusal did not cite the incomplete return"
  grep -q 'teardown: RECOVERY:' "$case_dir/stderr" \
    || fail "incomplete-return: refusal left no recovery instruction"
  grep -F "$case_dir/state/task-x1.meta" "$case_dir/stderr" >/dev/null \
    || fail "incomplete-return: the recovery instruction did not name the meta file to edit"
  assert_present "$case_dir/state/task-x1.meta" "incomplete-return: task state must be preserved"
  pass "an incomplete durable return refuses with an exact, documented recovery"
}

# A spawn that leased a pooled slot but never resolved its path records the
# lease holder instead of a fabricated worktree. Teardown must retire the
# endpoint and records, return nothing, and print the reclaim instruction.
test_teardown_retires_an_unresolved_lease_record() {
  local case_dir rc
  case_dir=$(make_case unresolved-lease)
  add_compatible_tasks_axi "$case_dir"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "worktree=" \
    "slot_lease_state=unresolved" \
    "slot_lease_holder=task-x1" \
    "slot_worktree_candidate=$case_dir/half-settled" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unresolved-lease: teardown must retire a record with no resolved slot path: $(cat "$case_dir/stderr")"
  grep -q 'teardown: RECLAIM:' "$case_dir/stderr" \
    || fail "unresolved-lease: teardown left no reclaim instruction for the still-held lease"
  grep -F "$case_dir/half-settled" "$case_dir/stderr" >/dev/null \
    || fail "unresolved-lease: the reclaim instruction did not name the recorded candidate path"
  assert_absent "$case_dir/state/task-x1.meta" "unresolved-lease: the record should be retired"
  assert_absent "$case_dir/treehouse.log" \
    "unresolved-lease: teardown must not run treehouse against a slot it could not identify"
  grep -q 'lease is still held by task-x1' "$case_dir/stdout" \
    || fail "unresolved-lease: the completion line did not report the still-held lease"
  pass "an unresolved-lease record is retirable and reports its still-held lease"
}

# The recovery the previous refusal advertises has to be REACHABLE. A failed
# return must leave the worktree on its task branch, so the retry passes
# fm_assert_task_branch_matches_meta instead of dying on an unrelated identity
# mismatch, and the task branch is only retired once the return is proven.
test_teardown_failed_return_stays_retryable_for_a_ship_task() {
  local case_dir rc wt_head gate branch
  case_dir=$(make_case failed-return-retry)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "landed work before the failed return"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  gate="$case_dir/treehouse-allow"

  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ -e "$gate" ] || { echo "fatal: pool is busy" >&2; exit 1; }
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-return-retry: teardown must refuse when the return fails"
  grep -q 'teardown can be retried' "$case_dir/stderr" \
    || fail "failed-return-retry: the failure did not advertise a retry: $(cat "$case_dir/stderr")"
  grep -q '^slot_returning=1$' "$case_dir/state/task-x1.meta" \
    && fail "failed-return-retry: a retryable failure left an uncleanable slot_returning mark"
  branch=$(git -C "$case_dir/wt" symbolic-ref --quiet --short HEAD || printf 'DETACHED')
  [ "$branch" = "fm/task-x1" ] \
    || fail "failed-return-retry: the failed return left the worktree on $branch, not its task branch"

  touch "$gate"
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e

  expect_code 0 "$rc" "failed-return-retry: the advertised retry must succeed: $(cat "$case_dir/stderr2")"
  assert_absent "$case_dir/state/task-x1.meta" "failed-return-retry: the retry should retire the record"
  git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    && fail "failed-return-retry: the task branch survived a proven return"
  pass "a failed return stays retryable and only retires the task branch once the return is proven"
}

test_teardown_preserves_replacement_metadata() {
  local case_dir rc wt_head token replacement_meta
  case_dir=$(make_case replacement-metadata)
  mkdir -p "$case_dir/project/bin" "$case_dir/project/state" "$case_dir/project/data" "$case_dir/project/config"
  printf '%s\n' '# agents' > "$case_dir/project/AGENTS.md"
  printf '%s\n' '# secondmate registry' > "$case_dir/project/data/secondmates.md"
  token="replacement-$RANDOM"
  printf 'root=%s\ntoken=%s\n' "$case_dir/project" "$token" > "$case_dir/project/state/.primary-attestation"
  chmod 600 "$case_dir/project/state/.primary-attestation"
  FM_ROOT_OVERRIDE="$case_dir/project" FM_HOME="$case_dir/project" \
    FM_STATE_OVERRIDE="$case_dir/project/state" write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "landed work before replacement"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  replacement_meta="$case_dir/project/state/task-x1.meta"

  set +e
  (
    cd "$case_dir/project"
    FM_ROOT_OVERRIDE="$case_dir/project" FM_HOME="$case_dir/project" \
      FM_PRIMARY_ATTESTATION="$token" \
      FM_CONFIG_OVERRIDE="$case_dir/project/config" \
      FM_STATE_OVERRIDE="$case_dir/project/state" \
      FM_FAKE_TMUX_REPLACE_META="$replacement_meta" \
      run_teardown "$case_dir" --force
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown must refuse to delete replacement metadata"
  assert_present "$replacement_meta" \
    "teardown removed metadata after the replacement was published"
  assert_contains "$(cat "$replacement_meta")" "generation=replacement" \
    "teardown deleted metadata published after the original generation"
  pass "teardown preserves metadata replaced during lifecycle cleanup"
}

test_teardown_retries_transient_index_lock() {
  local case_dir rc wt_head attempts
  case_dir=$(make_case transient-index-lock)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "landed work before transient lock"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  attempts="$case_dir/treehouse-attempts"

  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' attempt >> "$attempts"
if [ "\$(wc -l < "$attempts")" -eq 1 ]; then
  echo "fatal: Unable to create '/tmp/example/index.lock': File exists" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should retry once the lock clears"
  [ "$(wc -l < "$attempts")" -eq 2 ] || fail "transient-index-lock: treehouse should be called twice"
  pass "teardown retries a transient index lock without weakening landed-work checks"
}

test_forced_secondmate_teardown_retries_child_index_lock() {
  local case_dir rc home child attempts
  case_dir=$(make_case forced-child-index-lock)
  home="$case_dir/home"
  child="$case_dir/wt"
  attempts="$case_dir/treehouse-attempts"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$home/state/child-x1.meta" \
    "window=fm-child-x1" \
    "worktree=$child" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$child" child-x1 "$home" ) \
    || fail "forced-child-index-lock: could not stamp child worktree ownership"

  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' attempt >> "$attempts"
if [ "\$(wc -l < "$attempts")" -eq 1 ]; then
  echo "fatal: Unable to create '/tmp/example/index.lock': File exists" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forced-child-index-lock: forced secondmate teardown should retry a child worktree lock"
  [ "$(wc -l < "$attempts")" -eq 2 ] || fail "forced-child-index-lock: child treehouse return should be retried"
  [ ! -e "$home" ] || fail "forced-child-index-lock: secondmate home should be removed after child return succeeds"
  pass "forced secondmate teardown retries a transient child worktree index lock"
}

test_forced_secondmate_teardown_uses_child_receipt_identity() {
  local case_dir rc home child receipt
  case_dir=$(make_case forced-child-presentation)
  home="$case_dir/home"
  child="$case_dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$home/state/child-x1.meta" \
    "window=fm-child-x1" \
    "worktree=$child" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/example/child/pull/9"
  receipt="$home/state/child-x1.pr-presentation"
  cat > "$receipt" <<'EOF'
firstmate-pr-presentation-v2
pr=https://github.com/example/child/pull/9
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
presented_pr_base_ref=main
presented_pr_base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
presentation_nonce=11111111111111111111111111111111
EOF
  chmod 0600 "$receipt"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forced-child-presentation: child receipt should use child metadata"
  [ ! -e "$home" ] || fail "forced-child-presentation: secondmate home was not removed"
  pass "forced secondmate teardown validates each child receipt against child metadata"
}

test_forced_secondmate_teardown_propagates_child_close_failure() {
  local case_dir rc home child child_pid kill_log
  case_dir=$(make_case forced-child-close-failure)
  home="$case_dir/home"
  child="$case_dir/wt"
  kill_log="$case_dir/tmux-kill.log"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$home/state/child-x1.meta" \
    "window=firstmate:fm-child-x1" \
    "worktree=$child" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  ( cd "$child" && FM_AGENT_ROLE=crewmate FM_AGENT_TASK=child-x1 \
      FM_AGENT_OWNER_HOME="$home" exec sleep 300 ) >/dev/null 2>&1 </dev/null &
  child_pid=$!
  while [ ! -e "/proc/$child_pid/cwd" ] && kill -0 "$child_pid" 2>/dev/null; do
    sleep 0.05
  done
  export FM_CHILD_PID="$child_pid"

  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "kill-window -t firstmate:fm-child-x1") printf '%s\n' "$*" >> "${FM_TMUX_KILL_LOG:?}"; exit 0 ;;
  "kill-window -t @2") printf '%s\n' "$*" >> "${FM_TMUX_KILL_LOG:?}"; exit 1 ;;
  *"list-windows -t firstmate -F #{window_name}"*)
    printf '%s\n' 'fm-child-x1'
    exit 0
    ;;
  *"list-windows -t =firstmate -F #{window_id} #{window_name}"*)
    printf '%s\n' '@2 fm-child-x1'
    exit 0
    ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_CHILD_PID:?}"; exit 0 ;;
  *"#{pane_current_command}"*) printf '%s\n' claude; exit 0 ;;
  "list-windows -a -F #{window_id}|#{session_name}:#{window_name}")
    printf '%s\n' '@2|firstmate:fm-child-x1'
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/tmux"
  export FM_TMUX_KILL_LOG="$kill_log"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  kill "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
  unset FM_CHILD_PID
  unset FM_TMUX_KILL_LOG

  expect_code 1 "$rc" "forced-child-close-failure: parent teardown must fail closed"
  assert_present "$case_dir/state/task-x1.meta" \
    "forced-child-close-failure: parent metadata must survive child close refusal"
  assert_present "$home/state/child-x1.meta" \
    "forced-child-close-failure: child metadata must survive child close refusal"
  [ -d "$home" ] || fail "forced-child-close-failure: parent home was removed after child close refusal"
  grep -Fx 'kill-window -t @2' "$kill_log" >/dev/null \
    || fail "forced-child-close-failure: teardown did not use the stable window id"
  grep -q "child cleanup failed" "$case_dir/stderr" \
    || fail "forced-child-close-failure: refusal did not identify child cleanup"
  pass "forced and recursive secondmate teardown propagate child close failures"
}

test_forced_secondmate_teardown_refuses_missing_child_with_live_occupant() {
  local case_dir rc home child child_pid
  case_dir=$(make_case forced-child-missing-occupant)
  home="$case_dir/home"
  child="$case_dir/wt"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'task-x1\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$home/state/child-x1.meta" \
    "window=firstmate:fm-child-x1" \
    "worktree=$child" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$child" child-x1 "$home" ) \
    || fail "forced-child-missing-occupant: child worktree fixture could not be stamped"

  ( cd "$child" && FM_AGENT_ROLE=crewmate FM_AGENT_TASK=child-x1 \
      FM_AGENT_OWNER_HOME="$home" exec sleep 300 ) >/dev/null 2>&1 </dev/null &
  child_pid=$!
  while [ ! -e "/proc/$child_pid/cwd" ] && kill -0 "$child_pid" 2>/dev/null; do
    sleep 0.05
  done

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  kill "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true

  expect_code 1 "$rc" "forced-child-missing-occupant: teardown must fail closed"
  assert_present "$case_dir/state/task-x1.meta" \
    "forced-child-missing-occupant: parent metadata must survive occupant refusal"
  assert_present "$home/state/child-x1.meta" \
    "forced-child-missing-occupant: child metadata must survive occupant refusal"
  [ -d "$home" ] || fail "forced-child-missing-occupant: parent home was removed"
  grep -q "child cleanup failed" "$case_dir/stderr" \
    || fail "forced-child-missing-occupant: refusal did not identify child cleanup"
  pass "forced teardown retains a child home when its endpoint is missing but occupied"
}

test_secondmate_teardown_refuses_open_pending_reply() {
  local case_dir rc home corr
  case_dir=$(make_case secondmate-open-reply)
  home="$case_dir/home"
  corr=0123456789abcdef
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
    "$case_dir/state/pending-replies"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$case_dir/state/pending-replies/$corr" \
    "corr_id=$corr" \
    "task_id=task-x1" \
    "phase=awaiting_report"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "secondmate-open-reply: teardown must refuse"
  assert_present "$case_dir/state/task-x1.meta" \
    "secondmate-open-reply: parent metadata must survive refusal"
  [ -d "$home" ] || fail "secondmate-open-reply: secondmate home was removed"
  grep -Fq "open pending reply" "$case_dir/stderr" \
    || fail "secondmate-open-reply: refusal did not identify the open reply"
  pass "secondmate teardown preserves routing while a reply remains open"
}

test_forced_secondmate_teardown_handoffs_escalated_reply() {
  local case_dir rc home corr history
  case_dir=$(make_case secondmate-escalated-reply)
  home="$case_dir/home"
  corr=1123456789abcdef
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
    "$case_dir/state/pending-replies"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$case_dir/state/pending-replies/$corr" \
    "corr_id=$corr" \
    "task_id=task-x1" \
    "phase=escalated"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "secondmate-escalated-reply: forced teardown should succeed"
  history="$case_dir/state/pending-reply-history/$corr"
  assert_present "$history" \
    "secondmate-escalated-reply: forced teardown must retain reply history"
  [ "$(sed -n 's/^phase=//p' "$history")" = retired ] \
    || fail "secondmate-escalated-reply: history phase must be retired"
  [ "$(sed -n 's/^retired_from=//p' "$history")" = escalated ] \
    || fail "secondmate-escalated-reply: source phase was not retained"
  [ "$(sed -n 's/^retired_via=//p' "$history")" = forced-teardown ] \
    || fail "secondmate-escalated-reply: forced handoff outcome was not retained"
  [ ! -e "$case_dir/state/pending-replies/$corr" ] \
    || fail "secondmate-escalated-reply: retired reply remained in the active scan"
  [ ! -e "$home" ] || fail "secondmate-escalated-reply: secondmate home was not removed"
  pass "forced teardown durably hands off an escalated reply"
}

test_forced_secondmate_teardown_failure_keeps_active_reply() {
  local case_dir rc home corr active history
  case_dir=$(make_case secondmate-staged-close-failure)
  home="$case_dir/home"
  corr=1223456789abcdef
  active="$case_dir/state/pending-replies/$corr"
  history="$case_dir/state/pending-reply-history/$corr"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
    "$case_dir/state/pending-replies"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$active" \
    "corr_id=$corr" \
    "task_id=task-x1" \
    "parent_status=$case_dir/state/task-x1.status" \
    "delivered_epoch=1" \
    "recovery_delivery_outcome=unknown" \
    "phase=recovery_unknown"

  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "kill-window -t fm-task-x1") exit 1 ;;
  "list-windows -a -F #{window_id}|#{session_name}:#{window_name}")
    printf '%s\n' '@2|fm-task-x1'
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "secondmate-staged-close-failure: teardown must fail closed"
  assert_present "$active" \
    "secondmate-staged-close-failure: active reply must survive endpoint failure"
  [ "$(sed -n 's/^phase=//p' "$active")" = escalated ] \
    || fail "secondmate-staged-close-failure: staged reply must remain active"
  [ "$(sed -n 's/^retirement_staged_from=//p' "$active")" = recovery_unknown ] \
    || fail "secondmate-staged-close-failure: original recovery phase was not staged"
  [ ! -e "$history" ] \
    || fail "secondmate-staged-close-failure: failed teardown must not publish retired history"
  assert_present "$case_dir/state/task-x1.meta" \
    "secondmate-staged-close-failure: task metadata must survive endpoint failure"
  [ -d "$home" ] || fail "secondmate-staged-close-failure: home was removed"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "secondmate-staged-close-failure: retry should succeed"
  assert_present "$history" \
    "secondmate-staged-close-failure: retry must publish retained history"
  [ "$(sed -n 's/^retired_from=//p' "$history")" = recovery_unknown ] \
    || fail "secondmate-staged-close-failure: retry overwrote the original recovery phase"
  pass "failed forced teardown retries with its original staged phase"
}

write_nested_secondmate_reply_fixture() {
  local case_dir=$1 phase=$2 corr=$3 home nested
  home="$case_dir/home"
  nested="$case_dir/nested-home"
  mkdir -p "$home/state/pending-replies" "$home/data" "$home/config" "$home/projects" \
    "$nested/state" "$nested/data" "$nested/config" "$nested/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-x1 > "$nested/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$home" \
    "project=$case_dir/project" \
    "home=$home" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$home/state/nested-x1.meta" \
    "window=fm-nested-x1" \
    "worktree=$nested" \
    "project=$case_dir/project" \
    "home=$nested" \
    "kind=secondmate" \
    "mode=no-mistakes"
  fm_write_meta "$home/state/pending-replies/$corr" \
    "corr_id=$corr" \
    "task_id=nested-x1" \
    "parent_status=$home/state/nested-x1.status" \
    "delivered_epoch=1" \
    "recovery_delivery_outcome=unknown" \
    "phase=$phase"
}

test_nested_secondmate_teardown_refuses_unescalated_reply() {
  local case_dir rc corr home nested
  case_dir=$(make_case nested-open-reply)
  corr=2123456789abcdef
  home="$case_dir/home"
  nested="$case_dir/nested-home"
  write_nested_secondmate_reply_fixture "$case_dir" awaiting_report "$corr"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nested-open-reply: forced teardown must refuse"
  assert_present "$case_dir/state/task-x1.meta" \
    "nested-open-reply: parent metadata must survive refusal"
  assert_present "$home/state/nested-x1.meta" \
    "nested-open-reply: nested metadata must survive refusal"
  assert_present "$home/state/pending-replies/$corr" \
    "nested-open-reply: active reply must survive refusal"
  [ -d "$home" ] && [ -d "$nested" ] \
    || fail "nested-open-reply: a secondmate home was removed"
  grep -Fq "child secondmate nested-x1 has a pending reply" "$case_dir/stderr" \
    || fail "nested-open-reply: refusal did not identify the nested reply"
  pass "recursive teardown preserves an un-escalated nested reply"
}

test_nested_secondmate_teardown_handoffs_escalated_reply() {
  local case_dir rc corr history
  case_dir=$(make_case nested-escalated-reply)
  corr=3123456789abcdef
  write_nested_secondmate_reply_fixture "$case_dir" recovery_unknown "$corr"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nested-escalated-reply: forced teardown should succeed"
  history="$case_dir/state/pending-reply-history/$corr"
  assert_present "$history" \
    "nested-escalated-reply: nested reply history must survive parent-home removal"
  [ "$(sed -n 's/^phase=//p' "$history")" = retired ] \
    || fail "nested-escalated-reply: nested history phase must be retired"
  [ "$(sed -n 's/^retired_from=//p' "$history")" = recovery_unknown ] \
    || fail "nested-escalated-reply: nested source phase was not retained"
  [ -n "$(sed -n 's/^escalated_epoch=//p' "$history")" ] \
    || fail "nested-escalated-reply: recovery uncertainty was not durably escalated"
  [ "$(sed -n 's/^recovery_delivery_outcome=//p' "$history")" = unknown ] \
    || fail "nested-escalated-reply: escalation outcome was not retained"
  [ ! -e "$case_dir/home" ] && [ ! -e "$case_dir/nested-home" ] \
    || fail "nested-escalated-reply: retired homes were not removed"
  pass "recursive teardown hands off nested reply history to durable parent state"
}

test_nested_secondmate_late_report_handoffs_resolved_history() {
  local case_dir rc corr history
  case_dir=$(make_case nested-late-resolved-reply)
  corr=3173456789abcdef
  write_nested_secondmate_reply_fixture "$case_dir" recovery_unknown "$corr"
  printf 'done [corr=%s]: late report\n' "$corr" \
    > "$case_dir/home/state/nested-x1.status"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nested-late-resolved-reply: forced teardown should succeed"
  history="$case_dir/state/pending-reply-history/$corr"
  assert_present "$history" \
    "nested-late-resolved-reply: resolved history must migrate to retained state"
  [ "$(sed -n 's/^phase=//p' "$history")" = resolved ] \
    || fail "nested-late-resolved-reply: late report must remain resolved"
  [ "$(sed -n 's/^resolved_via=//p' "$history")" = status ] \
    || fail "nested-late-resolved-reply: resolution evidence was not retained"
  [ ! -e "$case_dir/home" ] && [ ! -e "$case_dir/nested-home" ] \
    || fail "nested-late-resolved-reply: retired homes were not removed"
  pass "late nested reports migrate resolved history before teardown"
}

test_nested_secondmate_teardown_handoffs_archived_resolution() {
  local case_dir rc corr source_history history
  case_dir=$(make_case nested-archived-resolved-reply)
  corr=3193456789abcdef
  write_nested_secondmate_reply_fixture "$case_dir" resolved "$corr"
  source_history="$case_dir/home/state/pending-reply-history/$corr"
  mkdir -p "$(dirname "$source_history")"
  mv "$case_dir/home/state/pending-replies/$corr" "$source_history"
  printf '%s\n' "resolved_epoch=2" "resolved_via=status" >> "$source_history"

  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "kill-window -t fm-nested-x1") exit 1 ;;
  "list-windows -a -F #{window_id}|#{session_name}:#{window_name}")
    printf '%s\n' '@3|fm-nested-x1'
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nested-archived-resolved-reply: first endpoint close should fail"
  history="$case_dir/state/pending-reply-history/$corr"
  assert_present "$history" \
    "nested-archived-resolved-reply: failed close must retain migrated history"
  if ! compgen -G "$case_dir/state/pending-reply-history/.handoff-*" >/dev/null; then
    fail "nested-archived-resolved-reply: failed close lost its handoff receipt"
  fi

  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/retry-stdout" 2> "$case_dir/retry-stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nested-archived-resolved-reply: forced teardown should succeed"
  assert_present "$history" \
    "nested-archived-resolved-reply: archived history must migrate before home deletion"
  [ "$(sed -n 's/^phase=//p' "$history")" = resolved ] \
    || fail "nested-archived-resolved-reply: resolved phase was not retained"
  if compgen -G "$case_dir/state/pending-reply-history/.handoff-*" >/dev/null; then
    fail "nested-archived-resolved-reply: resolved handoff receipt remained"
  fi
  [ ! -e "$case_dir/home" ] && [ ! -e "$case_dir/nested-home" ] \
    || fail "nested-archived-resolved-reply: retired homes were not removed"
  pass "recursive teardown migrates already archived nested history"
}

test_nested_secondmate_teardown_failure_keeps_active_reply() {
  local case_dir rc corr home active history
  case_dir=$(make_case nested-staged-close-failure)
  corr=3223456789abcdef
  home="$case_dir/home"
  active="$home/state/pending-replies/$corr"
  history="$case_dir/state/pending-reply-history/$corr"
  write_nested_secondmate_reply_fixture "$case_dir" escalated "$corr"

  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "kill-window -t fm-nested-x1") exit 1 ;;
  "list-windows -a -F #{window_id}|#{session_name}:#{window_name}")
    printf '%s\n' '@3|fm-nested-x1'
    exit 0
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nested-staged-close-failure: teardown must fail closed"
  assert_present "$active" \
    "nested-staged-close-failure: nested active reply must survive endpoint failure"
  [ "$(sed -n 's/^phase=//p' "$active")" = escalated ] \
    || fail "nested-staged-close-failure: nested reply must remain active"
  [ ! -e "$history" ] \
    || fail "nested-staged-close-failure: failed teardown must not publish retired history"
  assert_present "$home/state/nested-x1.meta" \
    "nested-staged-close-failure: nested metadata must survive endpoint failure"
  if [ ! -d "$home" ] || [ ! -d "$case_dir/nested-home" ]; then
    fail "nested-staged-close-failure: a secondmate home was removed"
  fi
  pass "failed nested teardown keeps the staged reply active"
}

make_herdr_teardown_fake() {
  local case_dir=$1
  printf '%s\n' '{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1"},{"workspace_id":"w9","label":"PROJECTION_LABEL","focused":false,"active_tab_id":"w9:t2"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","focused":true,"label":"firstmate"},{"tab_id":"w9:t2","workspace_id":"w9","focused":false,"label":"fm-task-x1"}],"panes":[{"pane_id":"w9:p2","tab_id":"w9:t2","workspace_id":"w9"}]}' > "$case_dir/herdr-state.json"
  jq --arg cwd "$case_dir/wt" '.panes[0].foreground_cwd=$cwd' "$case_dir/herdr-state.json" > "$case_dir/herdr-state.tmp"
  mv "$case_dir/herdr-state.tmp" "$case_dir/herdr-state.json"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_HERDR_LOG:?}
printf '%s\n' "$*" >> "$log"
cmd=${1:-}; sub=${2:-}
workspace=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = --workspace ]; then
    workspace=${args[$((i + 1))]:-}
  fi
done
case "$cmd $sub" in
  "session list")
    jq -n --arg socket "${FM_FAKE_HERDR_SOCKET:?}" \
      '{sessions:[{name:"fmtest",running:true,socket_path:$socket}]}'
    ;;
  "workspace list") jq '{result:{workspaces:.workspaces}}' "$state" ;;
  "tab list") jq --arg workspace "$workspace" '{result:{tabs:[.tabs[] | select(.workspace_id == $workspace)]}}' "$state" ;;
  "tab get")
    tab=${3:-}
    if jq -e --arg tab "$tab" '.tabs[] | select(.tab_id == $tab)' "$state" >/dev/null; then
      jq --arg tab "$tab" '{result:{tab:(.tabs[] | select(.tab_id == $tab))}}' "$state"
    else
      printf '%s\n' '{"error":{"code":"tab_not_found"}}'
    fi
    ;;
  "pane get")
    pane=${3:-}
    if jq -e --arg pane "$pane" '.panes[] | select(.pane_id == $pane)' "$state" >/dev/null; then
      jq --arg pane "$pane" '{result:{pane:(.panes[] | select(.pane_id == $pane))}}' "$state"
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    fi
    ;;
  "pane close")
    pane=${3:-}; tmp="$state.tmp.$$"
    jq --arg pane "$pane" '.panes |= [.[] | select(.pane_id != $pane)]' "$state" > "$tmp"
    mv "$tmp" "$state"
    ;;
  "agent get")
    if [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] \
      && { [ -z "${FM_FAKE_HERDR_WORKER_PID:-}" ] \
        || { kill -0 "$FM_FAKE_HERDR_WORKER_PID" 2>/dev/null \
          && [ "$(ps -o stat= -p "$FM_FAKE_HERDR_WORKER_PID" 2>/dev/null | tr -d '[:space:]')" != Z ]; }; }; then
      jq -n --arg status "$FM_FAKE_HERDR_AGENT_STATUS" \
        '{result:{agent:{agent:"grok",agent_status:$status}}}'
    else
      printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    fi
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_projection_journal_retires_before_worktree_return() {
  local case_dir rc journal token
  case_dir=$(make_case projection-journal-order)
  mkdir -p "$case_dir/data"
  printf '%s\n' '# Backlog' > "$case_dir/data/backlog.md"
  write_meta "$case_dir" local-only ship
  sed -i 's/^window=.*/window=fmtest:w9:p2/' "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w9' \
    'herdr_tab_id=w9:t2' \
    'display_label=fm-task-x1' \
    'herdr_pane_id=w9:p2' >> "$case_dir/state/task-x1.meta"
  journal="$case_dir/state/task-x1.herdr-presentation"
  token=$(FM_HOME="$case_dir" bash -c '
    . "$0/bin/backends/herdr.sh"
    token=$(fm_backend_herdr_projection_journal_create "$1" task-x1) || exit 1
    label=$(fm_backend_herdr_projection_workspace_label task-x1 "$token")
    fm_backend_herdr_projection_journal_bind \
      "$1/task-x1.herdr-presentation" task-x1 "$2" fmtest w9 w9:t2 w9:p2 \
      w1 firstmate "$label" fm-task-x1 || exit 1
    printf "%s" "$token"
  ' "$ROOT" "$case_dir/state" "$case_dir") || fail "could not create a valid projection journal fixture"
  make_herdr_teardown_fake "$case_dir"
  sed -i "s/PROJECTION_LABEL/└ task-x1 · p:$token/" "$case_dir/herdr-state.json"
  printf '%s\n' absent > "$case_dir/treehouse-journal"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' called > "$case_dir/treehouse-called"
if [ -e "$journal" ] || [ -L "$journal" ]; then
  printf '%s\n' present > "$case_dir/treehouse-journal"
else
  printf '%s\n' absent > "$case_dir/treehouse-journal"
fi
exit 1
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/herdr.log"

  set +e
  (
    export FM_HERDR_LOG="$case_dir/herdr.log"
    export FM_FAKE_HERDR_STATE="$case_dir/herdr-state.json"
    export FM_FAKE_HERDR_SOCKET="$case_dir/herdr.sock"
    run_teardown "$case_dir" --force
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "projection-journal-order: a failed worktree return must fail closed"
  assert_present "$case_dir/treehouse-called" \
    "projection-journal-order: fake treehouse return was not invoked"
  [ "$(cat "$case_dir/treehouse-journal")" = absent ] \
    || fail "projection-journal-order: worktree return ran before journal retirement"
  assert_absent "$journal" "projection-journal-order: retired projection journal survived return failure"
  assert_present "$case_dir/state/task-x1.meta" \
    "projection-journal-order: task metadata was lost after return failure"
  assert_contains "$(cat "$case_dir/herdr.log")" 'pane close w9:p2' \
    "projection-journal-order: exact Herdr endpoint was not closed before return"
  pass "projection journal retires after endpoint close and before a failed worktree return"
}

test_projection_teardown_refuses_missing_identity() {
  local case_dir rc
  case_dir=$(make_case projection-missing-identity)
  write_meta "$case_dir" local-only ship
  sed -i 's/^window=.*/window=fmtest:w9:p2/' "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_tab_id=w9:t2' \
    'display_label=fm-task-x1' \
    'herdr_pane_id=w9:p2' >> "$case_dir/state/task-x1.meta"
  make_herdr_teardown_fake "$case_dir"
  : > "$case_dir/herdr.log"

  set +e
  (
    export FM_HERDR_LOG="$case_dir/herdr.log"
    export FM_FAKE_HERDR_STATE="$case_dir/herdr-state.json"
    export FM_FAKE_HERDR_SOCKET="$case_dir/herdr.sock"
    run_teardown "$case_dir" --force
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "projection-missing-identity: teardown must fail closed"
  assert_present "$case_dir/state/task-x1.meta" \
    "projection-missing-identity: task metadata was removed"
  assert_not_contains "$(cat "$case_dir/herdr.log")" 'pane close' \
    "projection-missing-identity: unbound pane was closed"
  jq -e '.panes | any(.[]; .pane_id == "w9:p2")' "$case_dir/herdr-state.json" >/dev/null \
    || fail "projection-missing-identity: pane state changed after identity refusal"
  pass "projection teardown refuses to close a pane without bound identity"
}

test_projection_teardown_closes_owned_live_pane() {
  local case_dir rc worker_pid
  case_dir=$(make_case projection-live-owned)
  write_meta "$case_dir" local-only ship
  sed -i 's/^window=.*/window=fmtest:w9:p2/' "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w9' \
    'herdr_tab_id=w9:t2' \
    'display_label=fm-task-x1' \
    'harness=grok' \
    'herdr_pane_id=w9:p2' >> "$case_dir/state/task-x1.meta"
  make_herdr_teardown_fake "$case_dir"
  : > "$case_dir/herdr.log"
  env -i PATH="$PATH" FM_AGENT_TASK=task-x1 FM_AGENT_ROLE=crewmate \
    FM_AGENT_OWNER_HOME="$case_dir" sh -c 'cd "$1" && exec sleep 30' sh "$case_dir/wt" &
  worker_pid=$!
  trap 'kill "$worker_pid" 2>/dev/null || true' RETURN
  set +e
  (
    export FM_HERDR_LOG="$case_dir/herdr.log"
    export FM_FAKE_HERDR_STATE="$case_dir/herdr-state.json"
    export FM_FAKE_HERDR_SOCKET="$case_dir/herdr.sock"
    export FM_FAKE_HERDR_AGENT_STATUS=working
    export FM_FAKE_HERDR_WORKER_PID=$worker_pid
    run_teardown "$case_dir" --force
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  kill "$worker_pid" 2>/dev/null || true
  wait "$worker_pid" 2>/dev/null || true
  trap - RETURN
  expect_code 0 "$rc" "projection-live-owned: valid live task teardown should succeed"
  assert_contains "$(cat "$case_dir/herdr.log")" 'pane close w9:p2' \
    "projection-live-owned: valid live task pane was not closed"
  assert_absent "$case_dir/state/task-x1.meta" \
    "projection-live-owned: task metadata survived successful teardown"
  pass "projection teardown closes a live pane with complete task ownership proof"
}

test_endpoint_recovery_uses_stable_window_id() {
  local case_dir rc
  case_dir=$(make_case endpoint-recovery-stable-id)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=firstmate:stale-name' \
    'window_id=@1' \
    "project=$case_dir/project" \
    'backend=tmux' \
    'endpoint_recovery=1' \
    'spawn_state=aborted' \
    'kind=ship' \
    'mode=local-only'
  : > "$case_dir/tmux.log"
  set +e
  (
    export FM_FAKE_TMUX_LOG="$case_dir/tmux.log"
    export FM_FAKE_TMUX_PATH="$case_dir/project"
    run_teardown "$case_dir"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "endpoint-recovery-stable-id: teardown should retire a valid recovery endpoint"
  assert_absent "$case_dir/state/task-x1.meta" \
    "endpoint-recovery-stable-id: recovery metadata survived endpoint retirement"
  assert_contains "$(cat "$case_dir/tmux.log")" 'kill-window -t @1' \
    "endpoint-recovery-stable-id: teardown did not kill the immutable window id"
  pass "endpoint recovery consumes the immutable tmux window id"
}

test_endpoint_recovery_retains_on_tmux_query_error() {
  local case_dir rc
  case_dir=$(make_case endpoint-recovery-query-error)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=firstmate:stale-name' \
    'window_id=@1' \
    "project=$case_dir/project" \
    'backend=tmux' \
    'endpoint_recovery=1' \
    'spawn_state=aborted' \
    'kind=ship' \
    'mode=local-only'
  : > "$case_dir/tmux.log"
  set +e
  (
    export FM_FAKE_TMUX_LOG="$case_dir/tmux.log"
    export FM_FAKE_TMUX_PATH="$case_dir/project"
    export FM_FAKE_TMUX_QUERY_ERROR=1
    run_teardown "$case_dir"
  ) > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "endpoint-recovery-query-error: teardown must retain uncertain recovery state"
  assert_present "$case_dir/state/task-x1.meta" \
    "endpoint-recovery-query-error: uncertain recovery metadata was removed"
  assert_not_contains "$(cat "$case_dir/tmux.log")" 'kill-window' \
    "endpoint-recovery-query-error: teardown killed an endpoint after an uncertain query"
  pass "endpoint recovery retains metadata when tmux presence is unreadable"
}

test_local_only_fork_remote_allows
test_teardown_prompts_tasks_axi_done_when_compatible
test_teardown_reconciles_consumed_presentation_receipt
test_teardown_refuses_foreign_presentation_receipt
test_teardown_manual_backend_prompts_hand_edit_even_when_tasks_axi_present
test_teardown_refuses_unsafe_tasktmp
test_teardown_refusal_on_incomplete_return_prints_recovery
test_teardown_retires_an_unresolved_lease_record
test_teardown_failed_return_stays_retryable_for_a_ship_task
test_teardown_preserves_replacement_metadata
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_origin_remote_allows
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_gh_error_and_content_absent_refuses
test_teardown_retries_transient_index_lock
test_forced_secondmate_teardown_retries_child_index_lock
test_forced_secondmate_teardown_uses_child_receipt_identity
test_forced_secondmate_teardown_propagates_child_close_failure
test_forced_secondmate_teardown_refuses_missing_child_with_live_occupant
test_secondmate_teardown_refuses_open_pending_reply
test_forced_secondmate_teardown_handoffs_escalated_reply
test_forced_secondmate_teardown_failure_keeps_active_reply
test_nested_secondmate_teardown_refuses_unescalated_reply
test_nested_secondmate_teardown_handoffs_escalated_reply
test_nested_secondmate_late_report_handoffs_resolved_history
test_nested_secondmate_teardown_handoffs_archived_resolution
test_nested_secondmate_teardown_failure_keeps_active_reply
test_projection_journal_retires_before_worktree_return
test_projection_teardown_refuses_missing_identity
test_projection_teardown_closes_owned_live_pane
test_endpoint_recovery_uses_stable_window_id
test_endpoint_recovery_retains_on_tmux_query_error
