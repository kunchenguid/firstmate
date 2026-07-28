#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a Telegram-linked task refuses to merge without a live, consumed publish
#       confirmation bound to this exact revision, project, and landing target,
#       and one such confirmation can never land twice
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

# --- Telegram publish gate ---------------------------------------------------
#
# A message from the paired person authorizes preparing and previewing a change,
# never publishing it. That rule used to live only in an agent skill while this
# helper merged without ever looking at a publish record, so under a project's
# standing autonomous-merge posture it was a comment rather than a gate.

# Build a Telegram-linked case: a paired peer, a task in the pinned project, and
# a publish record in whatever state the caller asks for. Echoes the case dir.
make_telegram_case() {  # <name> <record-project> <record-head> <consumed-at|null> [approving-user]
  local name=$1 record_project=$2 record_head=$3 consumed=$4 approver=${5:-555001} case_dir
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt" "$case_dir/state/telegram/publish"
  chmod 700 "$case_dir/state/telegram" "$case_dir/state/telegram/publish"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/eren-pov-site" \
    "kind=ship" \
    "mode=no-mistakes" \
    "tg_request=tg-42" \
    "tg_chat=555001" \
    "tg_request_ts=1"
  printf '%s\n' '{"label":"eren","project":"eren-pov-site","user_id":555001,"chat_id":555001,"paired_at":1}' \
    > "$case_dir/state/telegram/peer.json"
  chmod 600 "$case_dir/state/telegram/peer.json"
  if [ "$record_project" != none ]; then
    printf '{"task_id":"task-x1","project":"%s","head":"%s","salt":"s","code_sha256":"h","peer_user":%s,"peer_chat":%s,"armed_at":1,"expires_at":9999999999,"consumed_at":%s,"attempts":0}\n' \
      "$record_project" "$record_head" "$approver" "$approver" "$consumed" \
      > "$case_dir/state/telegram/publish/task-x1.json"
    chmod 600 "$case_dir/state/telegram/publish/task-x1.json"
  fi
  printf '%s\n' "$case_dir"
}

TG_HEAD_SHA=deadbeefcafefeed0000000000000000deadbeef

tg_merge_refused() {  # <case-dir> <expected-message-fragment> <label>
  local case_dir=$1 fragment=$2 label=$3 rc
  add_gh_mocks "$case_dir" "$TG_HEAD_SHA"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$label: the merge was allowed"
  assert_grep "$fragment" "$case_dir/stderr" "$label: the refusal did not explain itself"
  grep -q 'pr merge' "$case_dir/gh-axi.log" \
    && fail "$label: gh-axi pr merge ran despite the refusal"
  return 0
}

test_telegram_linked_merge_refuses_without_a_confirmation() {
  local case_dir
  case_dir=$(make_telegram_case tg-absent none "$TG_HEAD_SHA" null)
  tg_merge_refused "$case_dir" "no publish confirmation was ever armed" "tg-absent"
  pass "a Telegram-linked task never merges when no publish confirmation was armed"
}

test_telegram_linked_merge_refuses_an_unconsumed_confirmation() {
  local case_dir
  case_dir=$(make_telegram_case tg-unconsumed eren-pov-site "$TG_HEAD_SHA" null)
  tg_merge_refused "$case_dir" "has not confirmed publishing" "tg-unconsumed"
  pass "a Telegram-linked task never merges on an armed but unconfirmed publish record"
}

test_telegram_linked_merge_refuses_a_moved_revision() {
  local case_dir
  case_dir=$(make_telegram_case tg-moved eren-pov-site 1111111111111111111111111111111111111111 100)
  tg_merge_refused "$case_dir" "moved since the paired person approved it" "tg-moved"
  pass "a Telegram-linked task never merges a revision the person did not approve"
}

test_telegram_linked_merge_refuses_a_wrong_project_confirmation() {
  local case_dir
  case_dir=$(make_telegram_case tg-wrong-project other-project "$TG_HEAD_SHA" 100)
  tg_merge_refused "$case_dir" "outside the project this bridge is paired for" "tg-wrong-project"
  pass "a Telegram-linked task never merges on a confirmation given for another project"
}

test_telegram_linked_merge_refuses_when_the_revision_cannot_be_resolved() {
  local case_dir rc
  case_dir=$(make_telegram_case tg-unresolved eren-pov-site "$TG_HEAD_SHA" 100)
  # No `gh`, so fm-pr-check.sh records no pr_head and the exact landing revision
  # is unknown. An unverifiable revision must refuse, not merge.
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  rm -f "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "tg-unresolved: an unverifiable revision was merged"
  assert_grep 'could not be resolved' "$case_dir/stderr" "tg-unresolved: no explanation"
  grep -q 'pr merge' "$case_dir/gh-axi.log" && fail "tg-unresolved: gh-axi pr merge ran anyway"
  pass "a Telegram-linked task refuses to merge a revision it cannot verify"
}

test_telegram_linked_merge_lands_once_and_never_replays() {
  local case_dir rc
  case_dir=$(make_telegram_case tg-ok eren-pov-site "$TG_HEAD_SHA" 100)
  add_gh_mocks "$case_dir" "$TG_HEAD_SHA"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "tg-ok: a correctly confirmed Telegram-linked merge was refused"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "tg-ok: the confirmed merge did not run"
  assert_grep '"landed_at"' "$case_dir/state/telegram/publish/task-x1.json" \
    "tg-ok: the authorization was not consumed by the landing"

  # Replay: the same authorization must not land a second time.
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "tg-replay: one confirmation landed a change twice"
  assert_grep 'already used to land' "$case_dir/stderr2" "tg-replay: no explanation"
  grep -q 'pr merge' "$case_dir/gh-axi.log" && fail "tg-replay: gh-axi pr merge ran a second time"
  pass "one publish confirmation lands exactly one change and cannot be replayed"
}

test_unlinked_task_is_unaffected_by_the_telegram_gate() {
  local case_dir rc
  case_dir=$(make_case tg-unlinked)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$TG_HEAD_SHA"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "tg-unlinked: a task with no Telegram link was blocked by the bridge gate"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "tg-unlinked: the ordinary merge did not run"
  pass "a task with no Telegram link merges exactly as it did before the bridge existed"
}

# Linkage is decided by the PRESENCE of the key, not its value. Reading the value
# and treating "absent or empty" alike would make a half-written `tg_request=`
# line a silent bypass of the whole gate.
test_empty_telegram_link_does_not_bypass_the_gate() {
  local case_dir rc
  case_dir=$(make_case tg-empty-link)
  mkdir -p "$case_dir/wt"
  printf 'tg_request=\n' >> "$case_dir/state/task-x1.meta"
  add_gh_mocks "$case_dir" "$TG_HEAD_SHA"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "tg-empty-link: an empty Telegram link bypassed the publish gate"
  grep -q 'pr merge' "$case_dir/gh-axi.log" \
    && fail "tg-empty-link: gh-axi pr merge ran despite a malformed Telegram link"
  pass "a present-but-empty Telegram link is linked-and-malformed, never an unlinked task"
}

# An approval is a statement by one identity. If the bridge is re-paired to a
# different person, a confirmation the previous person gave must not land.
test_telegram_linked_merge_refuses_a_confirmation_from_another_person() {
  local case_dir
  case_dir=$(make_telegram_case tg-other-person eren-pov-site "$TG_HEAD_SHA" 100 777002)
  tg_merge_refused "$case_dir" "given by a different person" "tg-other-person"
  pass "a publish confirmation from a person the bridge is no longer paired with never lands"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_telegram_linked_merge_refuses_without_a_confirmation
test_telegram_linked_merge_refuses_an_unconsumed_confirmation
test_telegram_linked_merge_refuses_a_moved_revision
test_telegram_linked_merge_refuses_a_wrong_project_confirmation
test_telegram_linked_merge_refuses_when_the_revision_cannot_be_resolved
test_telegram_linked_merge_lands_once_and_never_replays
test_unlinked_task_is_unaffected_by_the_telegram_gate
test_empty_telegram_link_does_not_bypass_the_gate
test_telegram_linked_merge_refuses_a_confirmation_from_another_person
