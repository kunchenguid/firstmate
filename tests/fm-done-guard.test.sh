#!/usr/bin/env bash
# Behavior tests for the ship-done acceptance gate (bin/fm-done-guard.sh).
# A PR-requiring ship may report done only after its own branch is on the remote
# and the forge confirms an open PR in that task's repository. Tests drive the
# public check/apply CLI and, for the captain-facing half, the real watcher and
# wake queue - never implementation source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-done-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-done-guard)

# The forge is stubbed, never reached: the gate's accept path is a live read, so
# these tests own a fake forge whose answers they set per case.
FAKE_ORIGIN=https://github.com/example/repo.git
FAKE_PR_URL=https://github.com/example/repo/pull/7

make_ship() {  # <name> <mode> <kind>
  local name=$1 mode=$2 kind=${3:-ship} home wt branch
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/data"
  branch="fm/${name}"
  fm_git_worktree "$TMP_ROOT/$name/repo" "$TMP_ROOT/$name/wt" "$branch"
  wt="$TMP_ROOT/$name/wt"
  fm_write_meta "$home/state/${name}.meta" \
    "window=test:fm-${name}" \
    "worktree=$wt" \
    "kind=$kind" \
    "mode=$mode"
  printf '%s\n' "$home|$wt|$branch"
}

commit_on() {  # <worktree> <file> <message>
  local wt=$1 file=$2 msg=$3
  printf 'x\n' >> "$wt/$file"
  git -C "$wt" add "$file"
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$msg"
}

run_check() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$GUARD" check "$id"
}

# A forge that answers for one PR. FM_FAKE_GH_MODE=down makes every call fail so
# a test can drive the unreachable-forge path; FM_FAKE_GH_STATE picks the state
# and FM_FAKE_GH_HEAD the PR's head branch. FM_FAKE_GH_LOG records each call and
# FM_FAKE_GH_SLEEP makes each one slow.
install_fake_forge() {  # <home>
  local home=$1
  mkdir -p "$home/bin"
  cat > "$home/bin/gh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"
[ -z "${FM_FAKE_GH_SLEEP:-}" ] || sleep "$FM_FAKE_GH_SLEEP"
[ "${FM_FAKE_GH_MODE:-up}" = up ] || exit 1
case "$*" in
  *state,headRefName*) printf '%s %s\n' "${FM_FAKE_GH_STATE:-OPEN}" "${FM_FAKE_GH_HEAD:-}" ;;
  api\ *) printf 'state=%s\nmerged=false\n' "${FM_FAKE_GH_STATE:-OPEN}" ;;
  pr\ *) printf '%s\n' "${FM_FAKE_GH_PR_URL:-}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$home/bin/gh"
}

# Push the task branch and point origin at the repository the fake PR lives in.
publish() {  # <worktree> <branch>
  git -C "$1" push -q -u origin "$2"
  git -C "$1" remote set-url origin "$FAKE_ORIGIN"
}

run_apply() {  # <home> <id>
  local home=$1 id=$2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DONE_GUARD_SEND="$home/fake-send" "$GUARD" apply "$id"
}

install_fake_send() {  # <home>
  local home=$1
  cat > "$home/fake-send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_DONE_GUARD_SEND_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$home/fake-send"
}

test_unpushed_commit_refuses_done() {
  local rec home wt id=unpushed-a1 out rc
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "local only"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  out=$(run_check "$home" "$id") || rc=$?
  rc=${rc:-0}
  [ "$rc" -eq 1 ] || fail "unpushed ship done should be refused, got exit $rc ($out)"
  assert_contains "$out" "verdict=refused" "unpushed ship did not print refused"
  assert_contains "$out" "reason=unpushed" "unpushed ship did not name the unpushed reason"
  pass "worker commits but does not push -> done refused"
}

test_pushed_without_pr_refuses_done() {
  local rec home wt branch id=pushed-nopr-a1 out rc
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  rc=0
  out=$(FM_DONE_GUARD_NO_FORGE=1 run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "pushed ship without a PR should be refused, got exit $rc ($out)"
  assert_contains "$out" "verdict=refused" "pushed no-PR ship did not print refused"
  assert_contains "$out" "reason=no-pr" "pushed no-PR ship did not name the no-pr reason"
  pass "worker pushes but opens no PR -> done refused for ship tasks"
}

test_pushed_with_open_pr_accepts_done() {
  local rec home wt branch id=pushed-pr-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  install_fake_forge "$home"
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  out=$(FM_FAKE_GH_HEAD=$branch run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "pushed ship with an open PR should be accepted, got exit $rc ($out)"
  assert_contains "$out" "verdict=accepted" "pushed+open-PR ship did not print accepted"
  pass "worker pushes and opens a PR the forge confirms -> done accepted"
}

# Two concurrent tasks in one repository: A pushes its own branch but reports
# B's open PR. The PR is open in the right repository, but its head is B's
# branch, so it is not A's completion.
test_pr_of_another_task_refuses_done() {
  local rec home wt branch id=task-a-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  install_fake_forge "$home"
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  out=$(FM_FAKE_GH_HEAD=fm/task-b-a1 run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "task A citing task B's PR should be refused, got exit $rc ($out)"
  assert_contains "$out" "reason=unverified-pr" "another task's PR was not named unverified"
  pass "task A reports task B's open PR -> done refused"
}

# An accepted done is read from the forge once: repeat checks of the same line,
# meta, and HEAD reuse the verdict, and a new HEAD re-judges it.
test_accepted_verdict_is_read_once_per_head() {
  local rec home wt branch id=cached-a1 out rc=0 log
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  install_fake_forge "$home"
  log="$home/gh.log"
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  for _ in 1 2 3; do
    out=$(FM_FAKE_GH_LOG=$log FM_FAKE_GH_HEAD=$branch run_check "$home" "$id") || rc=$?
    [ "$rc" -eq 0 ] || fail "a repeat check of an accepted done refused it, exit $rc ($out)"
  done
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] \
    || fail "unchanged repeat checks re-read the forge: $(cat "$log")"
  commit_on "$wt" feature.txt "more"
  # The new head reached the remote (origin now names the fake forge's URL).
  git -C "$wt" update-ref "refs/remotes/origin/$branch" HEAD
  out=$(FM_FAKE_GH_LOG=$log FM_FAKE_GH_HEAD=$branch run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "a re-pushed head was refused, exit $rc ($out)"
  [ "$(wc -l < "$log" | tr -d ' ')" = 2 ] \
    || fail "a changed HEAD did not re-judge the done: $(cat "$log")"
  # A renamed branch no longer heads the cached PR: the done is re-judged and
  # refused rather than served from the cache.
  git -C "$wt" branch -m "$branch" fm/renamed-a1
  git -C "$wt" update-ref refs/remotes/origin/fm/renamed-a1 HEAD
  rc=0
  out=$(FM_FAKE_GH_LOG=$log FM_FAKE_GH_HEAD=$branch run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "a renamed branch reused the cached accept, exit $rc ($out)"
  [ "$(wc -l < "$log" | tr -d ' ')" -gt 2 ] \
    || fail "a renamed branch did not re-judge the done: $(cat "$log")"
  git -C "$wt" branch -m fm/renamed-a1 "$branch"
  out=$(FM_FAKE_GH_LOG=$log FM_FAKE_GH_HEAD=$branch run_check "$home" "$id") || fail "re-accept failed ($out)"
  # A repointed origin no longer names the PR's repository.
  git -C "$wt" remote set-url origin https://github.com/example/other.git
  rc=0
  out=$(FM_FAKE_GH_LOG=$log FM_FAKE_GH_HEAD=$branch run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "a repointed origin reused the cached accept, exit $rc ($out)"
  pass "accepted done is read from the forge once per line, meta, HEAD, branch, and origin"
}

test_unpushed_branch_with_pr_url_refuses_done() {
  local rec home wt id=claimed-pr-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  install_fake_forge "$home"
  # The base branch is on the remote and the worker made no commit at all, so
  # nothing is missing from the remotes: only the task branch's own absence
  # there distinguishes this from a real ship.
  git -C "$wt" push -q origin HEAD:refs/heads/base
  git -C "$wt" remote set-url origin "$FAKE_ORIGIN"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "a done naming a PR from an unpushed branch should be refused, got exit $rc ($out)"
  assert_contains "$out" "reason=unpushed" "a branch that never reached the remote was read as pushed"
  pass "worker names a PR but never pushes its own branch -> done refused"
}

test_pr_in_another_repository_refuses_done() {
  local rec home wt branch id=foreign-pr-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  install_fake_forge "$home"
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: PR https://github.com/someone-else/other/pull/7 checks green\n' \
    > "$home/state/${id}.status"
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "a PR in another repository should be refused, got exit $rc ($out)"
  assert_contains "$out" "reason=unverified-pr" "a foreign-repository PR was not named unverified"
  pass "worker names a PR in another repository -> done refused"
}

test_closed_pr_refuses_done() {
  local rec home wt branch id=closed-pr-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  install_fake_forge "$home"
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  out=$(FM_FAKE_GH_STATE=CLOSED run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "a closed PR should be refused, got exit $rc ($out)"
  assert_contains "$out" "reason=unverified-pr" "a closed PR was not named unverified"
  pass "worker names a PR the forge reports closed -> done refused"
}

test_unreachable_forge_refuses_done() {
  local rec home wt branch id=forge-down-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  install_fake_forge "$home"
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  out=$(FM_FAKE_GH_MODE=down run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "an unreachable forge should refuse, got exit $rc ($out)"
  assert_contains "$out" "reason=unverified-pr" "an unreachable forge did not refuse the claim"
  pass "forge unreachable -> done refused rather than accepted on the claim"
}

test_scout_and_local_only_skip() {
  local rec home wt id out rc
  id=scout-skip-a1
  rec=$(make_ship "$id" scout scout)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" notes.txt "findings"
  printf 'done: report complete\n' > "$home/state/${id}.status"
  rc=0
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "scout done should be skipped, got exit $rc ($out)"
  assert_contains "$out" "verdict=skipped" "scout did not skip the PR requirement"

  id=local-skip-a1
  rec=$(make_ship "$id" local-only)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "local"
  printf 'done: ready in branch fm/%s\n' "$id" > "$home/state/${id}.status"
  rc=0
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "local-only done should be skipped, got exit $rc ($out)"
  assert_contains "$out" "verdict=skipped" "local-only did not skip the PR requirement"
  pass "scout and local-only dones are skipped"
}

# A recorded worktree that is not a git checkout is absence of evidence, not
# proof of an unpushed branch, so the gate skips it exactly as it skips a
# missing one. Every classification consumer reads a ship this way, so refusing
# here would turn any task whose worktree is not a checkout into a permanent
# unknown that no push could clear.
test_non_checkout_worktree_skips() {
  local home id=no-checkout-a1 out rc
  home="$TMP_ROOT/$id/home"
  mkdir -p "$home/state" "$TMP_ROOT/$id/plain-dir"
  fm_write_meta "$home/state/${id}.meta" \
    "window=test:fm-${id}" \
    "worktree=$TMP_ROOT/$id/plain-dir" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  rc=0
  out=$(run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "a non-checkout worktree should skip, got exit $rc ($out)"
  assert_contains "$out" "verdict=skipped" "non-checkout worktree did not skip"
  assert_contains "$out" "reason=no-worktree" "non-checkout worktree did not name the worktree reason"
  pass "a recorded worktree that is not a checkout skips the gate"
}

record_merge() {  # <home> <id> <number>
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_poll_merge_mark_notified "$1/state" "$2" github github.com example/repo "$3" )
}

# The PR merged after an accepted done and the merge poll recorded it, but the
# task is not torn down yet: the forge now reports the PR closed and fleet sync
# may have pruned the branch. Every consumer reads the receipt through the one
# gate, offline included, so the landed ship stays terminal.
test_recorded_merge_accepts_done() {
  local rec home wt branch id=merged-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt branch <<EOF
$rec
EOF
  install_fake_forge "$home"
  commit_on "$wt" feature.txt "ready"
  publish "$wt" "$branch"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  record_merge "$home" "$id" 7 || fail "could not record the merge receipt"
  out=$(FM_FAKE_GH_STATE=MERGED run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "a recorded merge should accept the done, got exit $rc ($out)"
  assert_contains "$out" "reason=merged" "a recorded merge was not named merged"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-done-guard-lib.sh"
  FM_DONE_GUARD_NO_FORGE=1 status_is_captain_relevant_accepted "$home/state/${id}.status" \
    "$(cat "$home/state/${id}.status")" \
    || fail "an offline consumer read a recorded merge as a refused done"
  pass "PR merges after done and the merge is recorded -> done accepted, offline too"
}

test_recorded_merge_accepts_pruned_branch() {
  local rec home wt id=merged-pruned-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "squash-merged, branch pruned"
  printf 'pr=%s\n' "$FAKE_PR_URL" >> "$home/state/${id}.meta"
  printf 'done: shipped\n' > "$home/state/${id}.status"
  record_merge "$home" "$id" 7 || fail "could not record the merge receipt"
  out=$(FM_DONE_GUARD_NO_FORGE=1 run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 0 ] || fail "a recorded merge should accept a pruned branch, got exit $rc ($out)"
  assert_contains "$out" "reason=merged" "a pruned merged branch was not named merged"
  pass "fleet sync prunes a merged branch -> the recorded merge still accepts the done"
}

test_merge_receipt_for_another_pr_refuses_done() {
  local rec home wt id=merged-other-a1 out rc=0
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "local only"
  printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$home/state/${id}.status"
  record_merge "$home" "$id" 8 || fail "could not record the merge receipt"
  out=$(FM_DONE_GUARD_NO_FORGE=1 run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "a receipt for another PR should not accept the done, got exit $rc ($out)"
  assert_contains "$out" "reason=unpushed" "a foreign receipt changed the refusal reason"
  pass "merge receipt names a different PR -> done still refused"
}

FAKE_CHANGE_URL=https://review.example/c/proj/+/42

# A Gerrit server that answers for change 42: FM_FAKE_GERRIT_STATUS picks its
# status and FM_FAKE_GERRIT_REVISION its current patch set.
install_fake_gerrit() {  # <home>
  local home=$1
  mkdir -p "$home/bin"
  cat > "$home/bin/gerrit-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = show ] && [ "${2:-}" = 42 ] || exit 1
printf '{"ok":true,"changes":[{"change":42,"status":"%s","revision":"%s"}]}\n' \
  "${FM_FAKE_GERRIT_STATUS:-NEW}" "${FM_FAKE_GERRIT_REVISION:-}"
SH
  chmod +x "$home/bin/gerrit-axi"
}

# A Gerrit worker publishes through refs/for/, so its branch is never on a
# remote; the published change carrying its HEAD is the evidence instead.
test_gerrit_change_carrying_head_accepts_done() {
  local mode rec home wt id out rc
  for mode in direct-PR no-mistakes; do
    id=gerrit-ok-${mode,,}
    rec=$(make_ship "$id" "$mode")
    IFS='|' read -r home wt _ <<EOF
$rec
EOF
    install_fake_gerrit "$home"
    commit_on "$wt" feature.txt "published as a change"
    printf 'done: PR %s published for review\n' "$FAKE_CHANGE_URL" > "$home/state/${id}.status"
    rc=0
    out=$(FM_FAKE_GERRIT_REVISION=$(git -C "$wt" rev-parse HEAD) run_check "$home" "$id") || rc=$?
    [ "$rc" -eq 0 ] || fail "$mode gerrit done carrying HEAD should be accepted, got exit $rc ($out)"
    assert_contains "$out" "verdict=accepted" "$mode gerrit done carrying HEAD was not accepted"
  done
  pass "gerrit change's current patch set carries HEAD -> done accepted in both ship modes"
}

test_gerrit_change_without_head_refuses_done() {
  local rec home wt id=gerrit-stale-a1 out rc base
  rec=$(make_ship "$id" direct-PR)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  install_fake_gerrit "$home"
  base=$(git -C "$wt" rev-parse HEAD)
  commit_on "$wt" feature.txt "committed after publishing"
  printf 'done: PR %s published for review\n' "$FAKE_CHANGE_URL" > "$home/state/${id}.status"
  rc=0
  out=$(FM_FAKE_GERRIT_REVISION=$base run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "a stale gerrit patch set should refuse, got exit $rc ($out)"
  assert_contains "$out" "reason=unverified-change" "stale gerrit patch set did not name the change reason"
  rc=0
  out=$(FM_FAKE_GERRIT_STATUS=ABANDONED FM_FAKE_GERRIT_REVISION=$(git -C "$wt" rev-parse HEAD) \
    run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "an abandoned gerrit change should refuse, got exit $rc ($out)"
  rc=0
  out=$(FM_DONE_GUARD_NO_FORGE=1 FM_FAKE_GERRIT_REVISION=$(git -C "$wt" rev-parse HEAD) \
    run_check "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "an offline gerrit check should refuse, got exit $rc ($out)"
  pass "gerrit change stale, abandoned, or unreadable -> done refused"
}

test_span_drops_refused_done() {
  local rec home wt id=span-drop-a1 event rc
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  commit_on "$wt" feature.txt "local only"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-done-guard-lib.sh"
  rc=0
  event=$(status_span_first_actionable "$home/state/${id}.status" 0) || rc=$?
  [ "$rc" -eq 1 ] || fail "refused done span should not be actionable, got rc=$rc event='$event'"
  [ -z "$event" ] || fail "refused done span leaked an event: $event"
  pass "classifier drops a refused ship done from the actionable span"
}

test_apply_steers_on_refuse() {
  local rec home wt id=steer-a1 out rc log
  rec=$(make_ship "$id" direct-PR)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  install_fake_send "$home"
  log="$home/send.log"
  commit_on "$wt" feature.txt "local only"
  printf 'done: ready\n' > "$home/state/${id}.status"
  rc=0
  out=$(FM_DONE_GUARD_SEND_LOG="$log" run_apply "$home" "$id") || rc=$?
  [ "$rc" -eq 1 ] || fail "apply on unpushed ship should refuse, got exit $rc ($out)"
  [ -s "$log" ] || fail "refused done did not steer the worker"
  assert_contains "$(cat "$log")" "$id" "steer did not name the task"
  assert_contains "$(cat "$log")" "pushed branch" "steer did not tell the worker to push"
  pass "apply refuses an unpushed done and steers the worker to push"
}

# The reported failure at the surface it actually bit: a ship crewmate commits
# locally, reports `done:`, and the always-on watcher hands that completion to
# the captain's durable wake queue, which reads as a delivered ship. The gate
# must keep that done out of the queue and steer the crewmate to push instead.
# This drives the real bin/fm-watch.sh and reads the queue back through the real
# bin/fm-wake-drain.sh rather than re-deriving either.
install_watch_fakes() {  # <home>
  local home=$1
  mkdir -p "$home/bin" "$home/nogit"
  cat > "$home/bin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && { printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-}"; exit 0; }
[ "${1:-}" = capture-pane ] && exit 0
exit 1
SH
  cat > "$home/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown - source: pane - harness state unavailable\n'
SH
  chmod +x "$home/bin/tmux" "$home/bin/fm-crew-state.sh"
}

test_watcher_keeps_false_done_out_of_the_wake_queue() {
  local rec home wt id=watch-queue-a1 log pid i=0 exited=no drained signal_rows
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  install_watch_fakes "$home"
  install_fake_send "$home"
  log="$home/send.log"
  commit_on "$wt" feature.txt "local only"
  printf 'done: implementation complete\n' > "$home/state/${id}.status"
  PATH="$home/bin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home/nogit" \
    FM_CREW_STATE_BIN="$home/bin/fm-crew-state.sh" FM_FAKE_TMUX_WINDOWS="fm-$id" \
    FM_DONE_GUARD_SEND="$home/fake-send" FM_DONE_GUARD_SEND_LOG="$log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2>&1 &
  pid=$!
  # The watcher exits on its first actionable wake; whatever it decides, it has
  # decided by then. A watcher still running at the cap is killed and the queue
  # read anyway, so a gate that never ran cannot pass by stalling.
  while [ "$i" -lt 80 ]; do
    kill -0 "$pid" 2>/dev/null || { exited=yes; break; }
    sleep 0.25
    i=$((i + 1))
  done
  [ "$exited" = yes ] || kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  drained=$(PATH="$home/bin:$PATH" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$home/nogit" "$ROOT/bin/fm-wake-drain.sh" 2>&1 || true)
  signal_rows=$(printf '%s\n' "$drained" | grep "$(printf '\tsignal\t')" \
    | grep -F "${id}.status" || true)
  [ -z "$signal_rows" ] \
    || fail "the captain's wake queue carried the unpushed done: $signal_rows"
  [ -s "$log" ] || fail "the watcher did not steer the crewmate: $(cat "$home/watch.out")"
  assert_contains "$(cat "$log")" "pushed branch" \
    "the steer did not tell the crewmate to push and open a PR"
  pass "watcher drops an unpushed ship done from the captain's wake queue and steers the crewmate"
}

# A refused done followed, inside the signal grace, by another append: the
# steer and its dedupe marker belong to the refused done, not the later line.
test_watcher_steers_on_the_refused_done_line() {
  local rec home wt id=watch-later-a1 log pid i=0 expected
  rec=$(make_ship "$id" no-mistakes)
  IFS='|' read -r home wt _ <<EOF
$rec
EOF
  install_watch_fakes "$home"
  install_fake_send "$home"
  log="$home/send.log"
  commit_on "$wt" feature.txt "local only"
  printf 'done: implementation complete\nblocked: need a credential\n' > "$home/state/${id}.status"
  PATH="$home/bin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$home/nogit" \
    FM_CREW_STATE_BIN="$home/bin/fm-crew-state.sh" FM_FAKE_TMUX_WINDOWS="fm-$id" \
    FM_DONE_GUARD_SEND="$home/fake-send" FM_DONE_GUARD_SEND_LOG="$log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 80 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.25
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -s "$log" ] || fail "the watcher did not steer the refused done: $(cat "$home/watch.out")"
  # shellcheck source=/dev/null
  expected=$(. "$ROOT/bin/fm-done-guard-lib.sh"; fm_done_guard_steer_fingerprint 'done: implementation complete')
  [ "$(cat "$home/state/${id}.done-guard-steered" 2>/dev/null)" = "$expected" ] \
    || fail "the steer marker was keyed to a line other than the refused done"
  pass "watcher steers on the refused done line even when a later line follows it"
}

# The drain backstop presents several accepted ship completions under its
# presentation lock without a forge read per completion, so a slow forge
# neither delays them nor, by failing, hides them.
test_drain_presents_completions_without_forge_reads() {
  local home state cfg n rec wt branch log out start elapsed old
  home="$TMP_ROOT/drain-shared/home"
  state="$home/state"
  cfg="$TMP_ROOT/drain-shared/config"
  mkdir -p "$state" "$cfg" "$home/nogit"
  : > "$cfg/supervision-host-off"
  install_fake_forge "$home"
  log="$home/gh.log"
  : > "$log"
  old=$(( $(date +%s) - 20 ))
  for n in 1 2 3; do
    rec=$(make_ship "drain-$n" no-mistakes)
    IFS='|' read -r _ wt branch <<EOF
$rec
EOF
    commit_on "$wt" feature.txt "ready"
    publish "$wt" "$branch"
    fm_write_meta "$state/drain-$n.meta" "window=test:fm-drain-$n" \
      "worktree=$wt" "kind=ship" "mode=no-mistakes"
    printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$state/drain-$n.status"
    touch -d "@$old" "$state/drain-$n.status"
    # The watcher's online check accepts and caches each done before the drain.
    PATH="$home/bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_FAKE_GH_HEAD=$branch \
      "$GUARD" check "drain-$n" >/dev/null || fail "online check refused drain-$n"
  done
  : > "$log"
  start=$(date +%s)
  out=$(PATH="$home/bin:$PATH" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$cfg" \
    FM_ROOT_OVERRIDE="$home/nogit" FM_FAKE_GH_LOG="$log" FM_FAKE_GH_SLEEP=10 \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "drain failed: $out"
  elapsed=$(( $(date +%s) - start ))
  for n in 1 2 3; do
    assert_contains "$out" "drain-$n done: PR $FAKE_PR_URL" "uncovered completion drain-$n was not presented"
  done
  [ ! -s "$log" ] || fail "the drain read the forge under its presentation lock: $(cat "$log")"
  [ "$elapsed" -lt 10 ] || fail "the drain took ${elapsed}s with a slow forge"
  pass "drain backstop presents several ship completions without a forge read each"
}

# Offline, the drain backstop presents a ship done only on a cached accept or a
# merge receipt: a pushed branch with no PR, an unverifiable PR, a closed PR, and
# an unverified Gerrit change are all held, not shown as completed.
test_drain_holds_unaccepted_completions() {
  local home state cfg id rec wt branch out old
  home="$TMP_ROOT/drain-held/home"
  state="$home/state"
  cfg="$TMP_ROOT/drain-held/config"
  mkdir -p "$state" "$cfg" "$home/nogit"
  : > "$cfg/supervision-host-off"
  install_fake_forge "$home"
  install_fake_gerrit "$home"
  old=$(( $(date +%s) - 20 ))
  for id in held-nopr held-unverified held-closed held-gerrit; do
    rec=$(make_ship "$id" no-mistakes)
    IFS='|' read -r _ wt branch <<EOF
$rec
EOF
    commit_on "$wt" feature.txt "ready"
    fm_write_meta "$state/$id.meta" "window=test:fm-$id" \
      "worktree=$wt" "kind=ship" "mode=no-mistakes"
    case "$id" in
      held-nopr) publish "$wt" "$branch"
        printf 'done: implementation complete\n' > "$state/$id.status" ;;
      held-unverified) publish "$wt" "$branch"
        printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$state/$id.status" ;;
      held-closed) publish "$wt" "$branch"
        printf 'done: PR %s checks green\n' "$FAKE_PR_URL" > "$state/$id.status"
        PATH="$home/bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
          FM_FAKE_GH_STATE=CLOSED FM_FAKE_GH_HEAD=$branch "$GUARD" check "$id" >/dev/null \
          && fail "a closed PR was accepted online" ;;
      held-gerrit)
        printf 'done: PR %s published for review\n' "$FAKE_CHANGE_URL" > "$state/$id.status" ;;
    esac
    touch -d "@$old" "$state/$id.status"
  done
  out=$(PATH="$home/bin:$PATH" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$cfg" \
    FM_ROOT_OVERRIDE="$home/nogit" FM_DONE_GUARD_NO_FORGE=1 \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1) || fail "drain failed: $out"
  for id in held-nopr held-unverified held-closed held-gerrit; do
    case "$out" in
      *"$id done:"*) fail "the drain presented unaccepted completion $id: $out" ;;
    esac
  done
  pass "drain backstop holds no-PR, unverified, closed, and unverified-Gerrit dones"
}

test_unpushed_commit_refuses_done
test_pushed_without_pr_refuses_done
test_pushed_with_open_pr_accepts_done
test_pr_of_another_task_refuses_done
test_accepted_verdict_is_read_once_per_head
test_unpushed_branch_with_pr_url_refuses_done
test_pr_in_another_repository_refuses_done
test_closed_pr_refuses_done
test_unreachable_forge_refuses_done
test_scout_and_local_only_skip
test_non_checkout_worktree_skips
test_recorded_merge_accepts_done
test_recorded_merge_accepts_pruned_branch
test_merge_receipt_for_another_pr_refuses_done
test_gerrit_change_carrying_head_accepts_done
test_gerrit_change_without_head_refuses_done
test_span_drops_refused_done
test_apply_steers_on_refuse
test_watcher_keeps_false_done_out_of_the_wake_queue
test_watcher_steers_on_the_refused_done_line
test_drain_presents_completions_without_forge_reads
test_drain_holds_unaccepted_completions
