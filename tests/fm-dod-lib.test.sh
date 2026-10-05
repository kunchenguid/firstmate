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
  [ "$rc" -eq 1 ] || fail "merge of recorded PR 7 accepted an unpushed done naming PR 9"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy") ;;
    *) fail "PR 9 refusal did not name the unpushed head: $reason" ;;
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
    [ "$rc" -eq 1 ] || fail "no-mistakes CI-ready variant skipped the gate: $line"
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
    [ "$rc" -eq 1 ] || fail "$mode done line skipped the gate: ${line#*|}"
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


# --- declared mechanical verification --------------------------------------
#
# The named-head gate proves a commit left the worker copy. These tests cover
# what it cannot see: whether the change actually works. Each one puts the task
# in the shape the structural gate already accepts - a reachable named head -
# so only the declared check can decide the done:.

landed_ship() {  # <name>; sets REPO WT
  REPO="$TMP_ROOT/$1-repo"
  WT="$TMP_ROOT/$1-wt"
  fm_git_worktree "$REPO" "$WT" "fm/$1"
  git -C "$WT" commit -q --allow-empty -m 'the fix'
  git -C "$WT" update-ref "refs/remotes/origin/fm/$1" "$(git -C "$WT" rev-parse HEAD)"
}

declare_checks() {  # <state> <id> <line>...
  local state=$1 id=$2
  shift 2
  mkdir -p "$state"
  printf '%s\n' "$@" > "$state/$id.verify"
  chmod 600 "$state/$id.verify"
}

serve_dir() {  # <dir>; sets SERVE_PORT SERVE_PID
  local dir=$1 log i
  log="$TMP_ROOT/serve-$$-$RANDOM.log"
  # -u so the port banner flushes immediately; Python 3.14 buffers a piped stdout.
  python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$dir" > "$log" 2>&1 &
  SERVE_PID=$!
  for i in $(seq 1 40); do
    SERVE_PORT=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$log" | head -1)
    [ -n "$SERVE_PORT" ] && return 0
    sleep 0.25
  done
  kill "$SERVE_PID" 2>/dev/null
  return 1
}

DONE_CI_READY='done: PR https://example.test/o/r/pull/9 checks green'

test_declared_http_check_decides_a_structurally_perfect_done() {
  local state reason rc port
  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    fail "python3 and curl are required to exercise the declared http check"
  fi
  landed_ship httpgate
  state="$TMP_ROOT/httpgate-state"
  mkdir -p "$TMP_ROOT/httpgate-site"
  printf 'the live fix is deployed\n' > "$TMP_ROOT/httpgate-site/index.html"
  serve_dir "$TMP_ROOT/httpgate-site" || fail "could not start the local site"
  port=$SERVE_PORT

  declare_checks "$state" httpgate "http: http://127.0.0.1:$port/ 200 the live fix is deployed"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" httpgate "$state/httpgate.meta") \
    || fail "a done: whose declared live check passes must be accepted: $reason"

  kill "$SERVE_PID" 2>/dev/null
  wait "$SERVE_PID" 2>/dev/null
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" httpgate "$state/httpgate.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a done: whose declared live check cannot reach the site was accepted (exit $rc)"
  case "$reason" in
    *"http: http://127.0.0.1:$port/ could not be fetched") ;;
    *) fail "the refusal did not report what happened: $reason" ;;
  esac
  pass "the declared http check accepts a live site and refuses a dead one"
}

test_declared_http_check_refuses_preview_only_content() {
  local state reason rc port
  if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    fail "python3 and curl are required to exercise the declared http check"
  fi
  landed_ship stale
  state="$TMP_ROOT/stale-state"
  mkdir -p "$TMP_ROOT/stale-site"
  printf 'the old broken copy\n' > "$TMP_ROOT/stale-site/index.html"
  serve_dir "$TMP_ROOT/stale-site" || fail "could not start the local site"
  port=$SERVE_PORT

  declare_checks "$state" stale "http: http://127.0.0.1:$port/ 200 the live fix is deployed"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" stale "$state/stale.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a live site still serving the old content was accepted (exit $rc)"
  case "$reason" in
    *"answered 200 without the live fix is deployed") ;;
    *) fail "the refusal did not report the served content: $reason" ;;
  esac

  declare_checks "$state" stale "http: http://127.0.0.1:$port/missing 200"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" stale "$state/stale.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a 404 on the declared URL was accepted (exit $rc)"
  case "$reason" in
    *"answered 404, not 200") ;;
    *) fail "the refusal did not report the status: $reason" ;;
  esac

  kill "$SERVE_PID" 2>/dev/null
  wait "$SERVE_PID" 2>/dev/null
  pass "a reachable site serving the wrong content or status still refuses the done:"
}

test_declared_run_and_file_checks_decide_the_done() {
  local state reason rc
  landed_ship runfile
  state="$TMP_ROOT/runfile-state"

  declare_checks "$state" runfile \
    "run: test 1 = 1" \
    "file: $WT/.git" \
    "# a comment and a blank line are ignored" \
    ''
  printf 'deployed marker\n' > "$TMP_ROOT/runfile-artifact"
  declare_checks "$state" runfile \
    "run: test -s $TMP_ROOT/runfile-artifact" \
    "file: $TMP_ROOT/runfile-artifact deployed marker"
  accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" runfile "$state/runfile.meta" \
    || fail "passing run: and file: checks must accept the done:"

  declare_checks "$state" runfile "run: exit 3"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" runfile "$state/runfile.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a failing run: check was accepted (exit $rc)"
  case "$reason" in
    *"run: exit 3 exited nonzero") ;;
    *) fail "the run: refusal did not name the command: $reason" ;;
  esac

  declare_checks "$state" runfile "file: $TMP_ROOT/runfile-artifact the text that never shipped"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" runfile "$state/runfile.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a file: check missing its required content was accepted (exit $rc)"
  case "$reason" in
    *"does not contain the text that never shipped") ;;
    *) fail "the file: refusal did not name the missing content: $reason" ;;
  esac
  pass "declared run: and file: checks decide the done: in both directions"
}

# A run: command gets no declaration bytes on its stdin: one stdin-reading
# check must not consume the lines that follow it out of the declaration.
test_stdin_reading_run_check_does_not_skip_later_checks() {
  local state reason rc
  landed_ship stdinread
  state="$TMP_ROOT/stdinread-state"
  printf 'artifact content\n' > "$TMP_ROOT/stdinread-artifact"
  declare_checks "$state" stdinread \
    'run: cat' \
    "run: grep -q artifact < $TMP_ROOT/stdinread-artifact" \
    'run: exit 7'
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" stdinread "$state/stdinread.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a stdin-reading run: consumed the checks after it and accepted the done: (exit $rc)"
  case "$reason" in
    *"run: exit 7 exited nonzero") ;;
    *) fail "a check after the stdin-reading run: never executed: $reason" ;;
  esac
  pass "a stdin-reading run: check cannot consume the declaration's later checks"
}

# The whole pass carries its own bound under the tightest consumer's read
# budget: a check that hangs past FM_VERIFY_PASS_TIMEOUT refuses the claim with
# a reason naming that bound instead of passing or stalling the read.
test_verification_pass_bound_refuses_a_hanging_check() {
  local state reason rc saved
  landed_ship passbound
  state="$TMP_ROOT/passbound-state"
  saved=$FM_VERIFY_PASS_TIMEOUT
  FM_VERIFY_PASS_TIMEOUT=2
  declare_checks "$state" passbound 'run: sleep 30'
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" passbound "$state/passbound.meta")
  rc=$?
  FM_VERIFY_PASS_TIMEOUT=$saved
  [ "$rc" -eq 1 ] || fail "a check hanging past the pass bound was accepted (exit $rc)"
  case "$reason" in
    *FM_VERIFY_PASS_TIMEOUT*) ;;
    *) fail "the refusal did not name the pass bound: $reason" ;;
  esac
  pass "the verification pass bound refuses a hanging check, naming the bound"
}

# A check killed at its bound is reported as a bound expiry, distinct from a
# command that failed on its own.
test_check_killed_at_the_bound_is_reported_distinctly() {
  local state reason rc saved
  landed_ship checkbound
  state="$TMP_ROOT/checkbound-state"
  saved=$FM_VERIFY_TIMEOUT
  FM_VERIFY_TIMEOUT=2
  declare_checks "$state" checkbound 'run: sleep 30'
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" checkbound "$state/checkbound.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a check killed at the bound was accepted (exit $rc)"
  case "$reason" in
    *"check bound"*) ;;
    *) fail "a check killed at the bound was not reported as a bound expiry: $reason" ;;
  esac

  declare_checks "$state" checkbound 'run: exit 7'
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" checkbound "$state/checkbound.meta")
  rc=$?
  FM_VERIFY_TIMEOUT=$saved
  [ "$rc" -eq 1 ] || fail "a failing run: check was accepted (exit $rc)"
  case "$reason" in
    *"exited nonzero"*) ;;
    *) fail "an instant nonzero exit lost its wording: $reason" ;;
  esac
  pass "a bound expiry is reported distinctly from an instant nonzero exit"
}

# A bound status (124) that the bound mechanism produces before the command
# runs is not evidence the command timed out, so it keeps the plain failure
# wording on every host, whatever mechanism fm-timeout-lib.sh selects there.
test_bound_mechanism_failure_is_not_reported_as_a_timeout() {
  local state reason rc
  landed_ship tmpbroken
  state="$TMP_ROOT/tmpbroken-state"
  declare_checks "$state" tmpbroken 'run: true'
  reason=$(
    # shellcheck disable=SC2329  # reached indirectly through fm_dod_verify_run
    fm_run_timed() { return 124; }
    accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" tmpbroken "$state/tmpbroken.meta"
  )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a check whose bound mechanism failed before running was accepted (exit $rc)"
  case "$reason" in
    *"check bound"* | *"pass bound"*) fail "a fast bound-mechanism failure was reported as a timeout: $reason" ;;
    *"run: true exited nonzero"*) ;;
    *) fail "the bound-mechanism refusal lost its wording: $reason" ;;
  esac
  pass "a bound mechanism failure before the command runs is not reported as a timeout"
}

# The file: kind honors the same per-check bound as run: and http:: a check
# that cannot complete inside the bound refuses naming the bound instead of
# hanging or reporting an ordinary failure.
test_file_check_runs_under_the_per_check_bound() {
  local state reason rc saved
  landed_ship filebound
  state="$TMP_ROOT/filebound-state"
  printf 'deployed marker\n' > "$TMP_ROOT/filebound-target"
  saved=$FM_VERIFY_TIMEOUT
  FM_VERIFY_TIMEOUT=2
  declare_checks "$state" filebound "file: $TMP_ROOT/filebound-target deployed marker"
  reason=$(
    # shellcheck disable=SC2329  # reached indirectly through fm_dod_verify_file_check
    fm_run_timed() { sleep "$1"; return 124; }
    accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" filebound "$state/filebound.meta"
  )
  rc=$?
  FM_VERIFY_TIMEOUT=$saved
  [ "$rc" -eq 1 ] || fail "a file: check that could not finish inside the bound was accepted (exit $rc)"
  case "$reason" in
    *"file: $TMP_ROOT/filebound-target hit the 2s check bound"*) ;;
    *) fail "the file: bound expiry was not reported as a bound expiry: $reason" ;;
  esac
  pass "a file: check runs under the per-check bound and names its expiry"
}

# A file: target that exists but cannot be read is reported as unreadable, not
# as missing the required text, so the refusal names what the operator must fix.
test_unreadable_file_check_target_is_named_unreadable() {
  local state reason rc target
  landed_ship fileunread
  state="$TMP_ROOT/fileunread-state"
  target="$TMP_ROOT/fileunread-target"
  printf 'deployed marker\n' > "$target"
  chmod 000 "$target"
  if [ -r "$target" ]; then
    chmod 600 "$target"
    pass "unreadable file: target case skipped (running with read override)"
    return 0
  fi
  declare_checks "$state" fileunread "file: $target deployed marker"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" fileunread "$state/fileunread.meta")
  rc=$?
  chmod 600 "$target"
  [ "$rc" -eq 1 ] || fail "an unreadable file: target was accepted (exit $rc)"
  case "$reason" in
    *"file: $target could not be read") ;;
    *) fail "an unreadable file: target was not named unreadable: $reason" ;;
  esac
  pass "an unreadable file: target is refused as unreadable, not as missing text"
}

# A declaration past the size cap is refused before it is loaded.
test_oversized_declaration_is_refused() {
  local state reason rc
  landed_ship bigdecl
  state="$TMP_ROOT/bigdecl-state"
  declare_checks "$state" bigdecl 'run: true'
  head -c $((FM_VERIFY_MAX_BYTES + 1)) /dev/zero | tr '\0' '#' >> "$state/bigdecl.verify"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" bigdecl "$state/bigdecl.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "an oversized declaration was accepted (exit $rc)"
  case "$reason" in
    *"larger than $FM_VERIFY_MAX_BYTES bytes"*) ;;
    *) fail "the oversized refusal did not name the cap: $reason" ;;
  esac
  pass "an oversized declaration is refused"
}

# NUL padding is dropped by command substitution, so the cap must count the
# file's bytes: a small passing check padded past the cap with NULs is refused.
test_nul_padded_oversized_declaration_is_refused() {
  local state reason rc
  landed_ship nuldecl
  state="$TMP_ROOT/nuldecl-state"
  declare_checks "$state" nuldecl 'run: true'
  head -c $((FM_VERIFY_MAX_BYTES + 1)) /dev/zero >> "$state/nuldecl.verify"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" nuldecl "$state/nuldecl.meta" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a NUL-padded oversized declaration was accepted (exit $rc)"
  case "$reason" in
    *"larger than $FM_VERIFY_MAX_BYTES bytes"*) ;;
    *) fail "the NUL-padded refusal did not name the cap: $reason" ;;
  esac
  pass "a NUL-padded oversized declaration is refused"
}

# A configured pass bound above the ceiling is held to it, so the pass still
# finishes inside the fleet snapshot's default crew-state read.
test_configured_pass_bound_is_used_unchanged() {
  local state reason rc
  landed_ship passcfg
  state="$TMP_ROOT/passcfg-state"
  declare_checks "$state" passcfg 'run: sleep 30'
  reason=$(
    FM_VERIFY_PASS_TIMEOUT=2
    # shellcheck source=bin/fm-dod-lib.sh
    . "$ROOT/bin/fm-dod-lib.sh"
    accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" passcfg "$state/passcfg.meta"
  )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a check hanging past the configured pass bound was accepted (exit $rc)"
  case "$reason" in
    *"FM_VERIFY_PASS_TIMEOUT pass bound (2s)"*) ;;
    *) fail "the configured pass bound was not the one bounding the pass: $reason" ;;
  esac
  pass "a configured pass bound below the maximum bounds the pass unchanged"
}

test_pass_bound_at_the_maximum_is_used_unchanged() {
  local state reason rc
  landed_ship passmax
  state="$TMP_ROOT/passmax-state"
  declare_checks "$state" passmax 'run: sleep 30'
  reason=$(
    FM_VERIFY_PASS_TIMEOUT=5
    # shellcheck source=bin/fm-dod-lib.sh
    . "$ROOT/bin/fm-dod-lib.sh"
    accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" passmax "$state/passmax.meta"
  )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a check hanging past the pass bound was accepted (exit $rc)"
  case "$reason" in
    *"FM_VERIFY_PASS_TIMEOUT pass bound (5s)"*) ;;
    *) fail "a pass bound at the maximum was not used as configured: $reason" ;;
  esac
  pass "a pass bound at the maximum bounds the pass unchanged"
}

test_pass_bound_above_the_maximum_is_refused() {
  local state reason rc
  landed_ship passover
  state="$TMP_ROOT/passover-state"
  declare_checks "$state" passover 'run: true'
  reason=$(
    FM_VERIFY_PASS_TIMEOUT=6
    # shellcheck source=bin/fm-dod-lib.sh
    . "$ROOT/bin/fm-dod-lib.sh"
    accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" passover "$state/passover.meta"
  )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a pass bound above the maximum was accepted (exit $rc)"
  case "$reason" in
    *"FM_VERIFY_PASS_TIMEOUT=6s exceeds the 5s maximum"*"crew-state read budget"*) ;;
    *) fail "the refusal did not name the configured value and the maximum: $reason" ;;
  esac
  pass "a pass bound above the maximum refuses and names both numbers"
}

# A declaration that passes the private-file check but then fails to read is
# refused, never treated as an empty declaration that gates nothing.
test_declaration_read_failure_is_refused() {
  local state reason rc
  landed_ship readfail
  state="$TMP_ROOT/readfail-state"
  declare_checks "$state" readfail 'run: false'
  reason=$(
    # shellcheck disable=SC2329
    head() { if [[ "${!#}" == *.verify ]]; then return 1; fi; command head "$@"; }
    accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" readfail "$state/readfail.meta"
  )
  rc=$?
  [ "$rc" -eq 1 ] || fail "a declaration that failed to read was accepted (exit $rc)"
  case "$reason" in
    *"declared verification cannot be read: $state/readfail.verify"*) ;;
    *) fail "the read failure did not name the unreadable declaration: $reason" ;;
  esac
  pass "a declaration that fails to read refuses the done:"
}

test_absent_declaration_leaves_the_done_ungated() {
  local state
  landed_ship nodecl
  state="$TMP_ROOT/nodecl-state"
  mkdir -p "$state"
  accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" nodecl "$state/nodecl.meta" \
    || fail "a task that declares no verification must behave exactly as before"
  pass "no declaration is no gate"
}

test_untrusted_or_unreadable_declaration_is_refused() {
  local state reason rc
  landed_ship untrusted
  state="$TMP_ROOT/untrusted-state"

  declare_checks "$state" untrusted 'run: true'
  chmod 644 "$state/untrusted.verify"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" untrusted "$state/untrusted.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a world-readable declaration was trusted (exit $rc)"
  case "$reason" in
    *"is not a firstmate-private file"*) ;;
    *) fail "the refusal did not name the untrusted declaration: $reason" ;;
  esac

  rm -f "$state/untrusted.verify"
  ln -s /dev/null "$state/untrusted.verify"
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" untrusted "$state/untrusted.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a symlinked declaration was trusted (exit $rc)"
  rm -f "$state/untrusted.verify"
  pass "a declaration that is not a firstmate-private file refuses the done:"
}

test_malformed_declared_check_is_refused() {
  local state reason rc
  landed_ship malformed
  state="$TMP_ROOT/malformed-state"

  declare_checks "$state" malformed 'browser: open the page and look at it'
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" malformed "$state/malformed.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "an unknown declared check was accepted (exit $rc)"
  case "$reason" in
    *"unknown check: browser") ;;
    *) fail "the refusal did not name the unknown check: $reason" ;;
  esac

  declare_checks "$state" malformed 'http: http://127.0.0.1:1/'
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" malformed "$state/malformed.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "an http: check with no expected status was accepted (exit $rc)"
  case "$reason" in
    *"names no expected status"*) ;;
    *) fail "the refusal did not name the missing status: $reason" ;;
  esac

  declare_checks "$state" malformed 'run:'
  reason=$(accept_done ship no-mistakes "$WT" "$REPO" "$DONE_CI_READY" "$state" malformed "$state/malformed.meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a check naming no target was accepted (exit $rc)"
  pass "a malformed declared check refuses the done: rather than being skipped"
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
test_fenced_and_indented_captain_lines_are_not_intent
test_pr_based_dod_draft_check_uses_gh_axi
test_declared_http_check_decides_a_structurally_perfect_done
test_declared_http_check_refuses_preview_only_content
test_declared_run_and_file_checks_decide_the_done
test_stdin_reading_run_check_does_not_skip_later_checks
test_verification_pass_bound_refuses_a_hanging_check
test_check_killed_at_the_bound_is_reported_distinctly
test_bound_mechanism_failure_is_not_reported_as_a_timeout
test_file_check_runs_under_the_per_check_bound
test_unreadable_file_check_target_is_named_unreadable
test_oversized_declaration_is_refused
test_nul_padded_oversized_declaration_is_refused
test_configured_pass_bound_is_used_unchanged
test_pass_bound_at_the_maximum_is_used_unchanged
test_pass_bound_above_the_maximum_is_refused
test_declaration_read_failure_is_refused
test_absent_declaration_leaves_the_done_ungated
test_untrusted_or_unreadable_declaration_is_refused
test_malformed_declared_check_is_refused

echo "all fm-dod-lib tests passed"
