#!/usr/bin/env bash
# Behavior tests for bin/fm-dod-lib.sh's named-head reachability gate on ship
# done: acceptance (issue 4768). The gate must test the commit the worker names,
# not merely that some remote-tracking branch exists or moved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dod-lib)
fm_git_identity fmtest fmtest@example.invalid

accept_done() {  # <kind> <mode> <worktree> <project> <line> [<state> <id> <meta>]
  fm_dod_accept_ship_done "$@"
}

write_merge_marker() {  # <state> <id> <provider> <host> <path> <number>
  printf '%s\n' fm-pr-poll-merge-notified-v1 "$3" "$4" "$5" "$6" > "$1/$2.pr-poll-merge-notified"
  chmod 600 "$1/$2.pr-poll-merge-notified"
}

file_mode() {  # the octal permission bits a path carries
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_scout_done_is_not_gated() {
  local repo wt
  repo="$TMP_ROOT/scout-repo"
  wt="$TMP_ROOT/scout-wt"
  fm_git_worktree "$repo" "$wt" fm/scout
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  accept_done scout no-mistakes "$wt" "$repo" 'done: report written' \
    || fail "scout done: must not require named-head reachability outside the copy"
  pass "scout done: is not gated"
}

test_unpushed_ship_done_is_refused() {
  local repo wt sha reason rc
  repo="$TMP_ROOT/unpushed-repo"
  wt="$TMP_ROOT/unpushed-wt"
  fm_git_worktree "$repo" "$wt" fm/unpushed
  git -C "$wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/1 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "unpushed ship done: was accepted (exit $rc)"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy") ;;
    *) fail "unpushed refusal did not name the commit: $reason" ;;
  esac
  pass "unpushed ship done: is refused"
}

test_remote_containing_named_head_is_accepted() {
  local repo wt sha
  repo="$TMP_ROOT/pushed-repo"
  wt="$TMP_ROOT/pushed-wt"
  fm_git_worktree "$repo" "$wt" fm/pushed
  git -C "$wt" commit -q --allow-empty -m 'fix on the branch'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/pushed "$sha"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/2 checks green" \
    || fail "named head on a remote-tracking ref was refused"
  pass "named head on a remote-tracking ref is accepted"
}

test_moved_branch_without_named_head_is_refused() {
  local repo wt main_sha fix_sha reason rc
  repo="$TMP_ROOT/moved-repo"
  wt="$TMP_ROOT/moved-wt"
  fm_git_worktree "$repo" "$wt" fm/moved
  main_sha=$(git -C "$repo" rev-parse main)
  git -C "$wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$wt" rev-parse HEAD)
  # The fork branch exists and moved, but only to a merge of the default
  # branch: reachability of that branch is not reachability of the named head.
  git -C "$wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/3 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "moved remote branch without the named head was accepted"
  case "$reason" in
    *"named head $fix_sha is unreachable outside the worker copy") ;;
    *) fail "moved-branch refusal did not name the fix commit: $reason" ;;
  esac
  pass "a moved remote branch that lacks the named head is refused"
}

test_no_mistakes_prevalidation_done_is_not_gated() {
  local repo wt
  repo="$TMP_ROOT/preval-repo"
  wt="$TMP_ROOT/preval-wt"
  fm_git_worktree "$repo" "$wt" fm/preval
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  accept_done ship no-mistakes "$wt" "$repo" 'done: implementation complete' \
    || fail "no-mistakes pre-validation done: must not require named-head reachability"
  pass "no-mistakes pre-validation done: is not gated"
}

test_local_only_linked_branch_is_accepted() {
  local repo wt
  repo="$TMP_ROOT/local-repo"
  wt="$TMP_ROOT/local-wt"
  fm_git_worktree "$repo" "$wt" fm/local
  git -C "$wt" commit -q --allow-empty -m 'local-only work'
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/local" \
    || fail "local-only named branch in a linked worktree was refused"
  pass "local-only linked named branch is reachable from the project clone"
}

test_local_only_detached_head_is_refused() {
  local repo wt sha rc
  repo="$TMP_ROOT/detach-repo"
  wt="$TMP_ROOT/detach-wt"
  fm_git_worktree "$repo" "$wt" fm/detach
  git -C "$wt" commit -q --allow-empty -m 'detached only'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q --detach HEAD
  git -C "$wt" branch -q -D fm/detach
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/detach" >/dev/null \
    && fail "detached local-only head whose branch was deleted was accepted"
  rc=0
  accept_done ship local-only "$wt" "$repo" "done: implementation complete" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "detached local-only HEAD was accepted as done"
  pass "local-only detached HEAD only in the disposable copy is refused"
}

test_standalone_local_only_needs_project_ref() {
  local repo wt sha
  repo="$TMP_ROOT/stand-project"
  wt="$TMP_ROOT/stand-copy"
  fm_git_init_commit "$repo"
  git clone --quiet "$repo" "$wt"
  git -C "$wt" checkout -q -b fm/stand
  git -C "$wt" commit -q --allow-empty -m 'only in the standalone copy'
  sha=$(git -C "$wt" rev-parse HEAD)
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" >/dev/null \
    && fail "standalone local-only copy was accepted without the named head in the project clone"
  git -C "$repo" fetch -q "$wt" "fm/stand:fm/stand"
  [ "$(git -C "$repo" rev-parse fm/stand)" = "$sha" ] \
    || fail "project clone did not gain the named head"
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" \
    || fail "standalone local-only named head present in the project clone was refused"
  pass "standalone local-only done: requires the named head in the project clone"
}

test_free_text_sha_is_not_the_named_head() {
  local repo wt old new reason rc
  repo="$TMP_ROOT/hex-repo"
  wt="$TMP_ROOT/hex-wt"
  fm_git_worktree "$repo" "$wt" fm/hex
  old=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/main "$old"
  git -C "$wt" commit -q --allow-empty -m 'actual fix'
  new=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: reverted $old and fixed the retry")
  rc=$?
  [ "$rc" -eq 1 ] || fail "free-text SHA on origin/main made an unpushed HEAD accept"
  case "$reason" in
    *"named head $new is unreachable outside the worker copy") ;;
    *) fail "free-text SHA scan still selected the old commit: $reason" ;;
  esac
  pass "a 40-hex token in the note is not the named head"
}

test_recorded_merged_pr_is_landed_after_prune() {
  local repo wt meta state
  repo="$TMP_ROOT/merged-repo"
  wt="$TMP_ROOT/merged-wt"
  state="$TMP_ROOT/merged-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/merged
  git -C "$wt" commit -q --allow-empty -m 'fix, squash-merged and branch pruned'
  meta="$state/merged.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" merged github github.com o/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" merged "$meta" \
    || fail "recorded merged PR was refused after its remote-tracking ref was pruned"
  pass "a recorded merged PR satisfies the gate after prune"
}

test_merge_marker_binds_to_the_named_pr() {
  local repo wt meta state reason rc sha
  repo="$TMP_ROOT/bind-repo"
  wt="$TMP_ROOT/bind-wt"
  state="$TMP_ROOT/bind-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/bind
  git -C "$wt" commit -q --allow-empty -m 'second PR head, never pushed'
  sha=$(git -C "$wt" rev-parse HEAD)
  meta="$state/bind.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" bind github github.com o/r 7
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/9" "$state" bind "$meta")
  rc=$?
  [ "$rc" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ] \
    || fail "a merge marker for recorded PR 7 authorized a done naming PR 9 (exit $rc)"
  case "$reason" in
    *"waiting on the PR record for https://github.com/o/r/pull/9"*) ;;
    *) fail "the unrecorded PR 9 report did not name the record it waits on: $reason" ;;
  esac
  write_merge_marker "$state" bind github github.com other/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" bind "$meta" >/dev/null \
    && fail "merge marker for another repository's PR 7 was accepted"
  pass "the merged-PR short-circuit applies only to the recorded PR the done line names"
}

test_forge_recorded_head_is_accepted_without_local_object() {
  local repo wt meta state forge_head
  repo="$TMP_ROOT/forge-repo"
  wt="$TMP_ROOT/forge-wt"
  state="$TMP_ROOT/forge-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/forge
  git -C "$wt" commit -q --allow-empty -m 'worker head, not pushed from this copy'
  # The pipeline's own commit: on the forge and in the gate repo, never
  # fetched into the worker clone.
  forge_head=0123456789abcdef0123456789abcdef01234567
  meta="$state/forge.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$forge_head" > "$meta"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/5 checks green" \
    "$state" forge "$meta" \
    || fail "forge-recorded pr_head the worker clone never fetched was refused"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/6 checks green" \
    "$state" forge "$meta" >/dev/null \
    && fail "pr_head recorded for PR 5 was accepted for a done naming PR 6"
  pass "a forge-recorded head for the named PR is accepted without a local object"
}

# A direct-PR worker pushes from its own copy: a commit made after the PR's
# recorded head, never pushed, is the named head and is refused.
test_direct_pr_recorded_head_does_not_cover_unpushed_commit() {
  local repo wt meta state pushed later reason rc
  repo="$TMP_ROOT/postopen-repo"
  wt="$TMP_ROOT/postopen-wt"
  state="$TMP_ROOT/postopen-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/postopen
  git -C "$wt" commit -q --allow-empty -m 'pushed when the PR opened'
  pushed=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/postopen "$pushed"
  git -C "$wt" commit -q --allow-empty -m 'the fix, only in the worktree'
  later=$(git -C "$wt" rev-parse HEAD)
  meta="$state/postopen.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$pushed" > "$meta"
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/5" "$state" postopen "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "direct-PR recorded pr_head accepted an unpushed later commit"
  case "$reason" in
    *"named head $later is unreachable outside the worker copy") ;;
    *) fail "direct-PR refusal did not name the unpushed commit: $reason" ;;
  esac
  pass "a direct-PR recorded head does not cover a later unpushed commit"
}

test_ci_ready_variants_are_gated() {
  local repo wt line rc
  repo="$TMP_ROOT/variant-repo"
  wt="$TMP_ROOT/variant-wt"
  fm_git_worktree "$repo" "$wt" fm/variant
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'done: PR https://github.com/o/r/pull/5 checks green, risk low' \
    'done: PR https://github.com/o/r/pull/5 - checks green' \
    'done: PR https://github.com/o/r/pull/5 checks green.' \
    'done: PR https://github.com/o/r/pull/5 (checks green)'; do
    rc=0
    accept_done ship no-mistakes "$wt" "$repo" "$line" >/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "no-mistakes CI-ready variant skipped the gate: $line"
  done
  pass "no-mistakes CI-ready done: with extra text is gated"
}

test_keyed_and_spaced_done_lines_are_gated() {
  local repo wt line mode rc
  repo="$TMP_ROOT/keyed-repo"
  wt="$TMP_ROOT/keyed-wt"
  fm_git_worktree "$repo" "$wt" fm/keyed
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'no-mistakes|done [key=fix]: PR https://github.com/o/r/pull/5 checks green' \
    'no-mistakes|done : PR https://github.com/o/r/pull/5 checks green' \
    'direct-PR|done [key=fix]: PR https://github.com/o/r/pull/5' \
    'direct-PR|done: [key=fix] PR https://github.com/o/r/pull/5'; do
    mode=${line%%|*}
    rc=0
    accept_done ship "$mode" "$wt" "$repo" "${line#*|}" >/dev/null || rc=$?
    [ "$rc" -ne 0 ] || fail "$mode done line skipped the gate: ${line#*|}"
  done
  pass "keyed and spaced ship done: lines are gated"
}

test_non_done_lines_are_not_gated() {
  local repo wt
  repo="$TMP_ROOT/nongate-repo"
  wt="$TMP_ROOT/nongate-wt"
  fm_git_worktree "$repo" "$wt" fm/nongate
  git -C "$wt" commit -q --allow-empty -m 'unpushed'
  accept_done ship no-mistakes "$wt" "$repo" 'working: still implementing' \
    || fail "working: line was gated"
  accept_done ship no-mistakes "$wt" "$repo" 'blocked: waiting on a credential' \
    || fail "blocked: line was gated"
  pass "non-done lines are not gated"
}

# Issue 3608: a legacy `# Task` body's provenance marker must be read the way
# bin/fm-brief-heading-lib.sh reads headings - outside fenced blocks and never
# from an indented example - or a fenced `Captain:` sample becomes the ship
# contract's intent while the real ask is dropped.
test_fenced_and_indented_captain_lines_are_not_intent() {
  local home id meta out status words
  home="$TMP_ROOT/fenced-home"
  mkdir -p "$home/state" "$home/data"
  words=$(fm_brief_marked_captain_words 'Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
[captain] Neither must this one.
```

~~~
Captain: Nor this tilde-fenced one.
~~~

    Captain: An indented example is not the ask either.
	[captain] Nor a tab-indented one.
Keep this Firstmate constraint out of captain intent.')
  assert_equals "" "$words" "fenced or indented Captain lines were extracted as authorized intent"

  words=$(fm_brief_marked_captain_words '```
Captain: fenced example
```
  [captain] Preserve the real ask after the fence closes.
````
Captain: a longer fence that a shorter closer must not end
```
Captain: still fenced
````')
  assert_equals "Preserve the real ask after the fence closes." "$words" \
    "the marker after a closed fence, or inside a longer fence, was misread"

  id=promote-fenced-captain
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
```

    Captain: An indented example is not the ask either.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion whose only Captain lines are fenced or indented examples should fail"
  assert_contains "$out" "has no provenance-marked Captain's intent" \
    "fenced-example promotion did not refuse like an unmarked legacy brief"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "fenced-example promotion published a fenced sample as captain intent"
  assert_grep 'kind=scout' "$meta" "fenced-example promotion changed the task record"
  pass "fenced and indented Captain lines are not authorized intent"
}

# A ship done: naming the pull request the review gate just pushed can arrive
# while bin/fm-pr-check.sh, the separate step that writes pr= and pr_head=, has
# not run: that push routinely outruns the remote-tracking refs either copy can
# see. The window waits on the recording step instead of claiming lost work.
test_unrecorded_pr_done_waits_for_the_recording_step() {
  local repo wt state meta reason rc
  repo="$TMP_ROOT/wait-repo"
  wt="$TMP_ROOT/wait-wt"
  state="$TMP_ROOT/wait-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/wait
  git -C "$wt" commit -q --allow-empty -m 'the fix, in no ref either copy can read'
  meta="$state/wait.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\n' "$wt" "$repo" > "$meta"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" \
    "done [at=$(date +%s)]: PR https://github.com/o/r/pull/20 checks green" \
    "$state" wait "$meta")
  rc=$?
  [ "$rc" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ] \
    || fail "a done naming an unrecorded PR did not read as the wait (exit $rc)"
  case "$reason" in
    *'PR record for https://github.com/o/r/pull/20'*) ;;
    *) fail "the wait did not name the pull request it waits on: $reason" ;;
  esac
  case "$reason" in
    *'carries no pr='*) ;;
    *) fail "the wait did not name what is missing: $reason" ;;
  esac
  case "$reason" in
    *'unreachable outside the worker copy'*) fail "the timing window raised the lost-work alarm: $reason" ;;
  esac
  pass "a ship done: naming an unrecorded PR waits on the recording step"
}

# The wait is re-derived from the task's own record on every read, so the same
# report is accepted as soon as the recording step writes the URL and its head.
test_recording_the_pr_accepts_the_same_done() {
  local repo wt state meta line rc
  repo="$TMP_ROOT/recorded-repo"
  wt="$TMP_ROOT/recorded-wt"
  state="$TMP_ROOT/recorded-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/recorded
  git -C "$wt" commit -q --allow-empty -m 'the fix, pushed by the review gate'
  meta="$state/recorded.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\n' "$wt" "$repo" > "$meta"
  line="done [at=$(date +%s)]: PR https://github.com/o/r/pull/20 checks green"
  accept_done ship no-mistakes "$wt" "$repo" "$line" "$state" recorded "$meta" >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ] \
    || fail "the unrecorded report did not reach the gate as the wait (exit $rc)"
  printf 'pr=https://github.com/o/r/pull/20\npr_head=%s\n' "$(git -C "$wt" rev-parse HEAD)" >> "$meta"
  accept_done ship no-mistakes "$wt" "$repo" "$line" "$state" recorded "$meta" \
    || fail "the same report stayed refused after pr= and pr_head= were written"
  pass "recording the PR accepts the done that was waiting on it"
}

# The recording step's own refusal, not a timer, restores the alarm: its reason
# comes back with the lost-work claim, and only for the pull request it named.
test_recorded_recording_refusal_restores_the_alarm() {
  local repo wt state meta reason rc url other
  repo="$TMP_ROOT/refused-repo"
  wt="$TMP_ROOT/refused-wt"
  state="$TMP_ROOT/refused-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/refused
  git -C "$wt" commit -q --allow-empty -m 'the fix, never pushed'
  meta="$state/refused.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\n' "$wt" "$repo" > "$meta"
  url=https://github.com/o/r/pull/20
  other=https://github.com/o/r/pull/21
  fm_dod_pr_refusal_write "$state" refused "$url" "$url is a draft pull request" \
    || fail "the recording refusal could not be written"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" \
    "done [at=$(date +%s)]: PR $url checks green" "$state" refused "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a refused recording did not read as the lost-work alarm (exit $rc)"
  case "$reason" in
    *'unreachable outside the worker copy'*) ;;
    *) fail "the refused recording lost the alarm: $reason" ;;
  esac
  case "$reason" in
    *'is a draft pull request'*) ;;
    *) fail "the alarm lost the recording refusal's own reason: $reason" ;;
  esac
  reason=$(accept_done ship no-mistakes "$wt" "$repo" \
    "done [at=$(date +%s)]: PR $other checks green" "$state" refused "$meta")
  rc=$?
  [ "$rc" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ] \
    || fail "a refusal naming PR 20 was applied to a done naming PR 21 (exit $rc)"
  case "$reason" in
    *'unreachable outside the worker copy'*) fail "a refusal for another PR raised the alarm: $reason" ;;
  esac
  fm_dod_pr_refusal_remove "$state" refused "$url" || fail "the recording refusal could not be cleared"
  accept_done ship no-mistakes "$wt" "$repo" \
    "done [at=$(date +%s)]: PR $url checks green" "$state" refused "$meta" >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ] \
    || fail "a cleared refusal still answered the gate (exit $rc)"
  pass "the recording step's refusal restores the alarm for its own pull request"
}

# One task can carry reports naming two pull requests. Recording one spends only
# the refusal naming it, so a report naming the other still reads as the refusal
# that was recorded for it.
test_recording_one_pull_request_leaves_another_pull_request_s_refusal_intact() {
  local state url_a url_b reason
  state="$TMP_ROOT/two-pr-state"
  mkdir -p "$state"
  url_a=https://github.com/o/r/pull/20
  url_b=https://github.com/o/r/pull/21
  fm_dod_pr_refusal_write "$state" two_prs "$url_a" "$url_a is a draft pull request" \
    || fail "the refusal for the first pull request could not be recorded"
  fm_dod_pr_refusal_remove "$state" two_prs "$url_b" \
    && fail "recording the second pull request cleared the first one's refusal"
  reason=$(fm_dod_pr_refusal_reason "$state" two_prs "$url_a") \
    || fail "the first refusal stopped being readable"
  [ "$reason" = "$url_a is a draft pull request" ] \
    || fail "the surviving refusal lost its cause: $reason"
  fm_dod_pr_refusal_remove "$state" two_prs "$url_a" \
    || fail "recording the refused pull request did not clear its own refusal"
  if fm_dod_pr_refusal_reason "$state" two_prs "$url_a" >/dev/null; then
    fail "the cleared refusal still reads back"
  fi
  pass "recording one pull request leaves another pull request's refusal intact"
}

# A forge resolves an owner and repository without case, so one pull request keeps
# one identity whichever spelling a report or a recording run arrived with.
test_one_pull_request_keeps_one_refusal_identity_in_another_spelling() {
  local state stored reported reason
  state="$TMP_ROOT/spelling-state"
  mkdir -p "$state"
  stored=https://github.com/Owner/Repo/pull/20
  reported=https://github.com/owner/repo/pull/20
  fm_dod_pr_refusal_write "$state" spelled "$stored" "$stored is a draft pull request" \
    || fail "the refusal could not be recorded under the spelling it arrived with"
  reason=$(fm_dod_pr_refusal_reason "$state" spelled "$reported") \
    || fail "a report in the other spelling found no refusal to read"
  [ "$reason" = "$stored is a draft pull request" ] \
    || fail "the refusal read in the other spelling lost its cause: $reason"
  fm_dod_pr_refusal_remove "$state" spelled "$reported" \
    || fail "recording the pull request in the other spelling could not clear the refusal"
  if fm_dod_pr_refusal_reason "$state" spelled "$stored" >/dev/null; then
    fail "the refusal outlived the record made in the other spelling"
  fi
  pass "one pull request keeps one refusal identity in another spelling"
}

# The wait states only what the reader can see. Nothing here measures elapsed
# time, so a named pull request the record does not carry waits whether or not the
# report carries a time tag, and the reason says what the record lacks instead of
# reasoning about a step it cannot observe.
test_the_wait_names_only_what_the_record_lacks() {
  local repo wt state meta reason rc note
  repo="$TMP_ROOT/unstamped-repo"
  wt="$TMP_ROOT/unstamped-wt"
  state="$TMP_ROOT/unstamped-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/unstamped
  git -C "$wt" commit -q --allow-empty -m 'the fix, never pushed'
  meta="$state/unstamped.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\n' "$wt" "$repo" > "$meta"
  for note in \
    "done [at=$(date +%s)]: PR https://github.com/o/r/pull/20 checks green" \
    'done: PR https://github.com/o/r/pull/20 checks green'; do
    reason=$(accept_done ship no-mistakes "$wt" "$repo" "$note" "$state" unstamped "$meta")
    rc=$?
    [ "$rc" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ] \
      || fail "[$note] did not wait on the missing record (exit $rc)"
    case "$reason" in
      *'waiting on the PR record for https://github.com/o/r/pull/20'*) ;;
      *) fail "[$note] did not name the pull request it waits on: $reason" ;;
    esac
    case "$reason" in
      *'carries no pr='*) ;;
      *) fail "[$note] did not say what the record lacks: $reason" ;;
    esac
    case "$reason" in
      *'unreachable outside the worker copy'*) fail "[$note] raised the lost-work alarm: $reason" ;;
    esac
    case "$reason" in
      *'within '*|*'elapsed'*|*'not run'*|*'never ran'*) \
        fail "[$note] reasoned from elapsed time or claimed a cause: $reason" ;;
    esac
  done
  pass "the wait names only the missing record, stamped or not, and never a clock"
}

# The record holds the one cause the last recording run stated. A later run
# replaces it instead of accumulating onto it, and it stays a single bounded line,
# because the reader quotes it inside the captain-facing lost-work alarm.
test_a_re_recorded_refusal_keeps_only_this_runs_cause() {
  local repo wt state meta reason stored url line rc cause quotes
  repo="$TMP_ROOT/rerun-repo"
  wt="$TMP_ROOT/rerun-wt"
  state="$TMP_ROOT/rerun-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/rerun
  git -C "$wt" commit -q --allow-empty -m 'the fix, never pushed'
  meta="$state/rerun.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\n' "$wt" "$repo" > "$meta"
  url=https://github.com/o/r/pull/20
  line="done [at=$(date +%s)]: PR $url checks green"
  fm_dod_pr_refusal_write "$state" rerun "$url" \
    'watching a GitLab merge request requires glab on PATH' \
    || fail "the first refusal could not be written"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "$line" "$state" rerun "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a recorded refusal did not read as the alarm (exit $rc)"
  case "$reason" in
    *'was refused: watching a GitLab merge request requires glab on PATH'*) ;;
    *) fail "the alarm lost the refusal it recorded: $reason" ;;
  esac
  cause="$url is a draft pull request; mark it ready for review and arm again"
  fm_dod_pr_refusal_write "$state" rerun "$url" "$cause" \
    || fail "the second refusal could not be recorded"
  stored=$(fm_dod_pr_refusal_reason "$state" rerun "$url") \
    || fail "the second refusal left an unreadable record"
  [ "$stored" = "$cause" ] \
    || fail "a re-run did not record only its own cause: $stored"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "$line" "$state" rerun "$meta")
  case "$reason" in
    *glab*) fail "the superseded cause still reached the alarm: $reason" ;;
  esac
  quotes=$(printf '%s\n' "$reason" | grep -o 'is a draft pull request' | wc -l | tr -d ' ')
  [ "$quotes" = 1 ] || fail "the alarm quoted the stored cause $quotes times: $reason"
  fm_dod_pr_refusal_write "$state" rerun "$url" "$(printf 'x%.0s' $(seq 1 900))" \
    || fail "an over-long refusal reason could not be recorded"
  stored=$(fm_dod_pr_refusal_reason "$state" rerun "$url") \
    || fail "an over-long refusal reason broke the record's six-line format"
  [ "${#stored}" -le 512 ] || fail "the stored reason grew past its cap: ${#stored}"
  pass "a re-recorded refusal keeps only this run's cause inside one bounded line"
}

# The marker writer borrows a private mask to create its file, and a mask is
# process-wide, so the only question a reader can act on is whether the caller
# gets back the mask it handed in. The suite chooses its own mask, calls the writer
# in its own shell the way a sourced caller does, and reads the mode a later write
# produces on both sides of the call.
test_a_refusal_write_returns_the_mask_its_caller_came_in_with() {
  local state url marker before after probe_before probe_after mode_before mode_after
  state="$TMP_ROOT/caller-mask-state"
  mkdir -p "$state"
  url=https://github.com/o/r/pull/20
  # A mask of the caller's own choosing: a writer that merely reset the mask on the
  # way out would still fail this check.
  umask 002
  before=$(umask)
  probe_before="$TMP_ROOT/caller-mask-probe-before"
  : > "$probe_before"
  mode_before=$(file_mode "$probe_before")
  fm_dod_pr_refusal_write "$state" masky "$url" "$url is a draft pull request" \
    || fail "the refusal could not be recorded"
  after=$(umask)
  marker="$state/masky.pr-record-refused"
  umask "$before"
  [ "$before" = "$after" ] \
    || fail "the writer left the caller holding mask $after instead of $before"
  [ "$(file_mode "$marker")" = 600 ] \
    || fail "the returned mask cost the marker its own privacy: $(file_mode "$marker")"
  probe_after="$TMP_ROOT/caller-mask-probe-after"
  : > "$probe_after"
  mode_after=$(file_mode "$probe_after")
  [ "$mode_before" = "$mode_after" ] \
    || fail "a file the caller wrote after the refusal came out $mode_after, not $mode_before"
  pass "a refusal write returns the mask its caller came in with and keeps its marker private"
}

# Only the named-but-unrecorded window changed. A note naming no pull request, a
# URL that is not a canonical pull request, a local-only lane, and a recorded URL
# whose head disagrees all keep today's refusal byte-for-byte, and no report that
# names a pipeline status is ever consulted.
test_every_other_unreachable_claim_still_refuses() {
  local repo wt state meta reason rc now note mode claim
  repo="$TMP_ROOT/boundary-repo"
  wt="$TMP_ROOT/boundary-wt"
  state="$TMP_ROOT/boundary-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/boundary
  git -C "$wt" commit -q --allow-empty -m 'the fix, never pushed'
  git -C "$wt" checkout -q --detach HEAD
  git -C "$wt" branch -q -D fm/boundary
  meta="$state/boundary.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\n' "$wt" "$repo" > "$meta"
  now=$(date +%s)
  for claim in \
    'no-mistakes|PR https://github.com/o/r/pull/not-a-number checks green' \
    'no-mistakes|PR https://example.test/o/r/pull/20 checks green' \
    'no-mistakes|PR ready to merge, checks green' \
    'direct-PR|implementation complete' \
    'local-only|PR https://github.com/o/r/pull/20'; do
    mode=${claim%%|*}
    note="done [at=$now]: ${claim#*|}"
    reason=$(accept_done ship "$mode" "$wt" "$repo" "$note" "$state" boundary "$meta")
    rc=$?
    [ "$rc" -eq 1 ] || fail "$mode claim [$note] waited instead of refusing (exit $rc)"
    case "$reason" in
      *'unreachable outside the worker copy') ;;
      *) fail "$mode claim [$note] lost today's refusal: $reason" ;;
    esac
  done
  # The pipeline's own verdict proves nothing about where the commit is saved: a
  # passed run for this very copy cannot turn the wait into an acceptance.
  local fakebin
  fakebin="$TMP_ROOT/boundary-fakebin"
  mkdir -p "$fakebin"
  { printf '#!/usr/bin/env bash\n'
    printf 'printf "run: 1\\noutcome: passed\\nhead_sha: %s\\n" \n' "$(git -C "$wt" rev-parse HEAD)"
  } > "$fakebin/no-mistakes"
  chmod +x "$fakebin/no-mistakes"
  reason=$(PATH="$fakebin:$PATH" accept_done ship no-mistakes "$wt" "$repo" \
    "done [at=$now]: PR https://github.com/o/r/pull/20 checks green" "$state" boundary "$meta")
  rc=$?
  [ "$rc" -eq "$FM_DOD_RC_WAIT_PR_RECORD" ] \
    || fail "a passed no-mistakes run was trusted as proof the head is saved (exit $rc)"

  printf 'pr=https://github.com/o/r/pull/20\n' >> "$meta"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" \
    "done [at=$now]: PR https://github.com/o/r/pull/20 checks green" \
    "$state" boundary "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a recorded pr= whose head was never proven was accepted (exit $rc)"
  case "$reason" in
    *'unreachable outside the worker copy') ;;
    *) fail "a recorded headless pr= lost today's refusal: $reason" ;;
  esac
  pass "every unreachable claim but the named-but-unrecorded window still refuses"
}

# The draft check the DoD hands a worker must be the gh-axi path that rule 3 of
# every ship brief requires for GitHub operations, never raw gh (issue 5325).
test_pr_based_dod_draft_check_uses_gh_axi() {
  local mode out
  for mode in direct-PR no-mistakes; do
    out="$TMP_ROOT/dod-$mode.md"
    fm_dod_block "$mode" dod-draft-task > "$out"
    assert_no_grep 'gh pr view' "$out" "$mode: DoD must not document a raw gh draft check"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`' "$out" \
      "$mode: DoD must read the draft state through gh-axi"
  done
  pass "PR-based DoD draft check uses gh-axi"
}

# A scout spawned on a named base keeps that base through promotion: the ship
# instructions start from it and the PR targets it; local-only cannot carry it.
test_promotion_keeps_the_recorded_base_branch() {
  local home id meta out status mode
  home="$TMP_ROOT/promote-base-home"
  for mode in direct-PR local-only; do
    id="promote-base-$mode"
    meta="$home/state/$id.meta"
    mkdir -p "$home/state" "$home/data/$id"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nbase_branch=feature/hub\n' "$id" > "$meta"
    cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the hub bug.

## Firstmate spec
Reproduce it first.

# Setup
You are in a disposable git worktree of proj, at a detached HEAD on a clean copy of its base branch.
Base branch: feature/hub
EOF
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" --mode "$mode" --yolo off 2>&1)
    status=$?
    if [ "$mode" = direct-PR ]; then
      expect_code 0 "$status" "promoting a scout with a recorded base should succeed"$'\n'"$out"
      # shellcheck disable=SC2016  # literal backticks in rendered prose must stay unexpanded
      assert_grep 'Return to a clean copy of the base branch `feature/hub`' "$home/data/$id/ship-instructions.md" \
        "promotion did not start the ship from the recorded base"
      # shellcheck disable=SC2016
      assert_grep 'against the base branch `feature/hub`' "$home/data/$id/ship-instructions.md" \
        "promotion did not target the PR at the recorded base"
      assert_grep 'base_branch=feature/hub' "$meta" "promotion dropped the recorded base"
    else
      [ "$status" -ne 0 ] || fail "promoting a based scout to local-only should be refused"
      assert_contains "$out" "mode=local-only" "the local-only promotion refusal did not explain itself"
      assert_grep 'kind=scout' "$meta" "a refused promotion changed the task record"
    fi
  done
  pass "promotion keeps a scout's recorded base branch and refuses local-only for it"
}

test_scout_done_is_not_gated
test_unpushed_ship_done_is_refused
test_no_mistakes_prevalidation_done_is_not_gated
test_remote_containing_named_head_is_accepted
test_moved_branch_without_named_head_is_refused
test_free_text_sha_is_not_the_named_head
test_recorded_merged_pr_is_landed_after_prune
test_merge_marker_binds_to_the_named_pr
test_forge_recorded_head_is_accepted_without_local_object
test_direct_pr_recorded_head_does_not_cover_unpushed_commit
test_ci_ready_variants_are_gated
test_keyed_and_spaced_done_lines_are_gated
test_local_only_linked_branch_is_accepted
test_local_only_detached_head_is_refused
test_standalone_local_only_needs_project_ref
test_non_done_lines_are_not_gated
test_unrecorded_pr_done_waits_for_the_recording_step
test_recording_the_pr_accepts_the_same_done
test_recorded_recording_refusal_restores_the_alarm
test_the_wait_names_only_what_the_record_lacks
test_a_re_recorded_refusal_keeps_only_this_runs_cause
test_a_refusal_write_returns_the_mask_its_caller_came_in_with
test_recording_one_pull_request_leaves_another_pull_request_s_refusal_intact
test_one_pull_request_keeps_one_refusal_identity_in_another_spelling
test_every_other_unreachable_claim_still_refuses
test_fenced_and_indented_captain_lines_are_not_intent
test_pr_based_dod_draft_check_uses_gh_axi
test_promotion_keeps_the_recorded_base_branch

# The launch role is the generated text a worker receives. It must keep the
# skill name, so a session that registers the skill loads it by name, and must
# name the skill file as the fallback for a session where the name does not
# resolve.
test_worker_role_names_skill_and_fallback_file() {
  local role_file path
  role_file="$TMP_ROOT/worker-role.txt"
  path="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
  [ -f "$path" ] || fail "Firstmate skill file is missing at $path"
  fm_brief_worker_role "$TMP_ROOT/state" upstream-4751 "$ROOT" >"$role_file"
  assert_grep "\`CONTRIBUTING.md\` and \`firstmate-coding-guidelines\` for Firstmate changes" "$role_file" \
    "worker role did not name the skill"
  assert_grep "If the \`firstmate-coding-guidelines\` skill name does not resolve in this session, read \`$path\` instead." "$role_file" \
    "worker role did not name the skill file as the fallback"
  assert_no_grep "Skill tool cannot resolve" "$role_file" \
    "worker role claims the Skill tool never resolves the skill"
  pass "worker role names the skill and its fallback skill file"
}

test_worker_role_names_skill_and_fallback_file

echo "all fm-dod-lib tests passed"
