#!/usr/bin/env bash
# Behavioral coverage for bin/fm-pr-review.sh's complete GitHub collection,
# evidence record, settling interval, readiness blockers, and private binding.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-pr-review.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review)
BASE_PATH=$PATH
URL=https://github.com/example/project/pull/17
HEAD=0123456789abcdef0123456789abcdef01234567


file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}
make_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data/task-a" "$dir/fakebin" "$dir/pages"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" "worktree=$dir/wt" "project=$dir/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=spawn-$name" \
    "pr=$URL" "pr_head=$HEAD"
  printf '%s\n' "$HEAD" > "$dir/head"
  printf '%s\n' null > "$dir/decision.json"
  cat > "$dir/checks.json" <<'JSON'
[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-09-15T12:00:00Z","completedAt":"2026-09-15T12:01:00Z","detailsUrl":"https://github.com/example/project/actions/runs/1"}]
JSON
  : > "$dir/gh.log"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    head=$(cat "$FM_TEST_CASE/head")
    jq -n --arg head "$head" \
      --argjson decision "$(cat "$FM_TEST_CASE/decision.json")" \
      --argjson checks "$(cat "$FM_TEST_CASE/checks.json")" \
      '{headRefOid:$head,reviewDecision:$decision,statusCheckRollup:$checks}'
    exit 0
    ;;
  "api graphql")
    query= cursor=first id=
    for arg in "$@"; do
      case "$arg" in
        query=*) query=${arg#query=} ;;
        cursor=*) cursor=${arg#cursor=} ;;
        id=*) id=${arg#id=} ;;
      esac
    done
    case "$query" in
      *ReviewCommentsPage*) op=comments ;;
      *ReviewsPage*) op=reviews ;;
      *ReviewThreadsPage*) op=threads ;;
      *ThreadCommentsPage*) op=thread-comments ;;
      *) exit 2 ;;
    esac
    if [ "$op" = thread-comments ]; then
      page="$FM_TEST_CASE/pages/$op.$id.$cursor.json"
    else
      page="$FM_TEST_CASE/pages/$op.$cursor.json"
    fi
    printf '%s %s %s\n' "$op" "$id" "$cursor" >> "$FM_TEST_CASE/gh.log"
    [ -z "${FM_TEST_MUTATE_HEAD_TO:-}" ] || if [ ! -e "$FM_TEST_CASE/head-mutated" ]; then
      printf '%s\n' "$FM_TEST_MUTATE_HEAD_TO" > "$FM_TEST_CASE/head"
      : > "$FM_TEST_CASE/head-mutated"
    fi
    [ -z "${FM_TEST_REBIND_META:-}" ] || if [ ! -e "$FM_TEST_CASE/meta-rebound" ]; then
      sed 's/^spawn_gen=.*/spawn_gen=replacement-generation/' "$FM_TEST_REBIND_META" > "$FM_TEST_REBIND_META.next"
      mv "$FM_TEST_REBIND_META.next" "$FM_TEST_REBIND_META"
      chmod 0600 "$FM_TEST_REBIND_META"
      : > "$FM_TEST_CASE/meta-rebound"
    fi
    [ -f "$page" ] || exit 1
    cat "$page"
    exit 0
    ;;
esac
exit 2
SH
  chmod +x "$dir/fakebin/gh"
  seed_empty_pages "$dir"
  printf '%s\n' "$dir"
}

configure_secondmate_parent() { # <case>
  local dir=$1 home="$1/home" parent="$1/parent"
  printf 'mate-x\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  mkdir -p "$parent/state" "$parent/data"
  fm_write_secondmate_meta "$parent/state/mate-x.meta" "$home"
  printf -- '- mate-x - fixture (home: %s; scope: fixture; projects: example; added 2026-09-15)\n' \
    "$home" > "$parent/data/secondmates.md"
}

run_pr_check() { # <case> <epoch> [--register-only]
  local dir=$1 epoch=$2
  shift 2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_ROOT_OVERRIDE="$ROOT" FM_TEST_CASE="$dir" FM_PR_REVIEW_NOW_EPOCH="$epoch" \
    FM_PR_REVIEW_NOW_ISO="2026-09-15T12:00:00Z" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@" task-a "$URL"
}

seed_empty_pages() {
  local dir=$1
  cat > "$dir/pages/comments.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/reviews.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/threads.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
}

seed_one_of_each() {
  local dir=$1
  cat > "$dir/pages/comments.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[{"id":"C1","url":"https://github.com/example/project/pull/17#issuecomment-1","body":"Unknown bot summary: finding A and finding B","createdAt":"2026-09-15T12:02:00Z","updatedAt":"2026-09-15T12:03:00Z","isMinimized":true,"minimizedReason":"OUTDATED","author":{"login":"unknown-review-bot","__typename":"Bot"},"authorAssociation":"NONE"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/reviews.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"id":"R1","url":"https://github.com/example/project/pull/17#pullrequestreview-1","body":"Submitted review body","state":"COMMENTED","submittedAt":"2026-09-15T12:04:00Z","updatedAt":"2026-09-15T12:04:30Z","author":null,"authorAssociation":"NONE","commit":{"oid":"0123456789abcdef0123456789abcdef01234567"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/threads.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":true,"isOutdated":true,"path":"src/a.ts","line":null,"originalLine":7,"startLine":null,"originalStartLine":null,"diffSide":"RIGHT","startDiffSide":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/thread-comments.T1.first.json" <<'JSON'
{"data":{"node":{"__typename":"PullRequestReviewThread","id":"T1","comments":{"nodes":[{"id":"TC1","url":"https://github.com/example/project/pull/17#discussion_r1","body":"Inline finding","createdAt":"2026-09-15T12:05:00Z","updatedAt":"2026-09-15T12:05:30Z","isMinimized":false,"minimizedReason":null,"author":{"login":"reviewer","__typename":"User"},"authorAssociation":"MEMBER","path":"src/a.ts","line":null,"originalLine":7,"diffHunk":"@@ -7 +7 @@","pullRequestReview":{"id":"R1","commit":{"oid":"0123456789abcdef0123456789abcdef01234567"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
JSON
}

run_review() { # <case> <epoch> <command>...
  local dir=$1 epoch=$2
  shift 2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_TEST_CASE="$dir" FM_PR_REVIEW_NOW_EPOCH="$epoch" \
    FM_PR_REVIEW_NOW_ISO="2026-09-15T12:00:00Z" PATH="$dir/fakebin:$BASE_PATH" \
    "$REVIEW" "$@"
}

make_assessment() { # <case> <output> <all-fixed|mixed|needs-action|incomplete>
  local dir=$1 out=$2 kind=$3 snapshot="$dir/home/data/task-a/pr-review-snapshot.json"
  case "$kind" in
    all-fixed)
      jq '{schema:"fm-pr-review-assessment.v1",task_id:.task_id,spawn_gen:.spawn_gen,pr_url:.pr_url,head:.head,snapshot_fingerprint:.fingerprint,
        sources:[.sources[]|{id,source_fingerprint:.fingerprint,disposition:"fixed",rationale:"Finding addressed on the current head",evidence:{head:$head,behavior:"Observed corrected behavior",verification:"Focused smoke passed"}}]}' \
        --arg head "$HEAD" "$snapshot" > "$out"
      ;;
    mixed)
      jq '{schema:"fm-pr-review-assessment.v1",task_id:.task_id,spawn_gen:.spawn_gen,pr_url:.pr_url,head:.head,snapshot_fingerprint:.fingerprint,
        sources:[.sources[]|if .kind=="review-thread" then {id,source_fingerprint:.fingerprint,disposition:"fixed",rationale:"Inline issue corrected",evidence:{head:$head,behavior:"Current line handles the boundary",verification:"Boundary smoke passed"}} else {id,source_fingerprint:.fingerprint,disposition:"not-actionable",rationale:"Informational summary or evidenced duplicate; both listed findings were checked",evidence:"Compared each stated finding with current behavior"} end]}' \
        --arg head "$HEAD" "$snapshot" > "$out"
      ;;
    needs-action)
      jq '{schema:"fm-pr-review-assessment.v1",task_id:.task_id,spawn_gen:.spawn_gen,pr_url:.pr_url,head:.head,snapshot_fingerprint:.fingerprint,
        sources:[.sources[]|{id,source_fingerprint:.fingerprint,disposition:"needs-action",rationale:"Valid finding still requires a fix",evidence:null}]}' \
        "$snapshot" > "$out"
      ;;
    incomplete)
      jq '{schema:"fm-pr-review-assessment.v1",task_id:.task_id,spawn_gen:.spawn_gen,pr_url:.pr_url,head:.head,snapshot_fingerprint:.fingerprint,sources:[]}' \
        "$snapshot" > "$out"
      ;;
  esac
}

settle_record_verify() { # <case> <assessment-kind> [expected-verify-rc]
  local dir=$1 kind=$2 expected=${3:-0} assessment="$dir/assessment.json" rc=0 out
  run_review "$dir" 1000 snapshot task-a "$URL" >/dev/null \
    || fail "initial snapshot failed"
  make_assessment "$dir" "$assessment" "$kind"
  out=$(run_review "$dir" 1120 record task-a "$URL" "$assessment" 2>&1) \
    || fail "assessment record failed: $out"
  set +e
  out=$(run_review "$dir" 1121 verify task-a "$URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq "$expected" ] || fail "verify rc=$rc, expected $expected: $out"
  printf '%s' "$out"
}

test_full_nested_pagination_and_retention() {
  local dir snapshot
  dir=$(make_case full-pagination)
  cat > "$dir/pages/comments.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[{"id":"C1","url":"https://github.com/example/project/pull/17#issuecomment-1","body":"first","createdAt":"2026-09-15T12:00:00Z","updatedAt":"2026-09-15T12:00:00Z","isMinimized":false,"minimizedReason":null,"author":{"login":"mystery-bot","__typename":"Bot"},"authorAssociation":"NONE"}],"pageInfo":{"hasNextPage":true,"endCursor":"c2"}}}}}}
JSON
  cat > "$dir/pages/comments.c2.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[{"id":"C2","url":"https://github.com/example/project/pull/17#issuecomment-2","body":"edited summary","createdAt":"2026-09-15T12:00:00Z","updatedAt":"2026-09-15T12:01:00Z","isMinimized":true,"minimizedReason":"OUTDATED","author":null,"authorAssociation":"NONE"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/reviews.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"id":"R1","url":"https://github.com/example/project/pull/17#pullrequestreview-1","body":"one","state":"COMMENTED","submittedAt":"2026-09-15T12:00:00Z","updatedAt":null,"author":null,"authorAssociation":"NONE","commit":null}],"pageInfo":{"hasNextPage":true,"endCursor":"r2"}}}}}}
JSON
  cat > "$dir/pages/reviews.r2.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[{"id":"R2","url":"https://github.com/example/project/pull/17#pullrequestreview-2","body":"two","state":"APPROVED","submittedAt":"2026-09-15T12:02:00Z","updatedAt":"2026-09-15T12:02:00Z","author":{"login":"human","__typename":"User"},"authorAssociation":"MEMBER","commit":{"oid":"0123456789abcdef0123456789abcdef01234567"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/threads.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"isOutdated":false,"path":"a","line":1,"originalLine":1,"startLine":null,"originalStartLine":null,"diffSide":"RIGHT","startDiffSide":null}],"pageInfo":{"hasNextPage":true,"endCursor":"t2"}}}}}}
JSON
  cat > "$dir/pages/threads.t2.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T2","isResolved":true,"isOutdated":true,"path":"b","line":null,"originalLine":2,"startLine":null,"originalStartLine":null,"diffSide":"RIGHT","startDiffSide":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  cat > "$dir/pages/thread-comments.T1.first.json" <<'JSON'
{"data":{"node":{"__typename":"PullRequestReviewThread","id":"T1","comments":{"nodes":[{"id":"TC1","url":"https://github.com/example/project/pull/17#discussion_r1","body":"one","createdAt":"2026-09-15T12:00:00Z","updatedAt":"2026-09-15T12:00:00Z","isMinimized":false,"minimizedReason":null,"author":null,"authorAssociation":"NONE","path":"a","line":1,"originalLine":1,"diffHunk":"x","pullRequestReview":null}],"pageInfo":{"hasNextPage":true,"endCursor":"tc2"}}}}}
JSON
  cat > "$dir/pages/thread-comments.T1.tc2.json" <<'JSON'
{"data":{"node":{"__typename":"PullRequestReviewThread","id":"T1","comments":{"nodes":[{"id":"TC2","url":"https://github.com/example/project/pull/17#discussion_r2","body":"two","createdAt":"2026-09-15T12:01:00Z","updatedAt":"2026-09-15T12:01:00Z","isMinimized":true,"minimizedReason":"RESOLVED","author":{"login":"bot-two","__typename":"Bot"},"authorAssociation":"NONE","path":"a","line":1,"originalLine":1,"diffHunk":"y","pullRequestReview":{"id":"R1","commit":{"oid":"0123456789abcdef0123456789abcdef01234567"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
JSON
  cat > "$dir/pages/thread-comments.T2.first.json" <<'JSON'
{"data":{"node":{"__typename":"PullRequestReviewThread","id":"T2","comments":{"nodes":[{"id":"TC3","url":"https://github.com/example/project/pull/17#discussion_r3","body":"three","createdAt":"2026-09-15T12:02:00Z","updatedAt":"2026-09-15T12:02:00Z","isMinimized":false,"minimizedReason":null,"author":null,"authorAssociation":"NONE","path":"b","line":null,"originalLine":2,"diffHunk":"z","pullRequestReview":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}
JSON
  run_review "$dir" 1000 snapshot task-a "$URL" >/dev/null \
    || fail "fully paginated snapshot failed"
  snapshot="$dir/home/data/task-a/pr-review-snapshot.json"
  [ "$(jq '.sources|length' "$snapshot")" -eq 6 ] || fail "snapshot omitted a top-level source"
  [ "$(jq '[.sources[]|select(.id=="thread:T1")|.comments[]]|length' "$snapshot")" -eq 2 ] \
    || fail "snapshot omitted a nested thread-comment page"
  jq -e '.sources[]|select(.id=="comment:C1")|.author.type=="Bot"' "$snapshot" >/dev/null \
    || fail "unknown bot source was filtered"
  jq -e '.sources[]|select(.id=="comment:C2")|.minimized==true and .body=="edited summary"' "$snapshot" >/dev/null \
    || fail "edited/minimized top-level summary was not retained"
  for expected in 'comments  c2' 'reviews  r2' 'threads  t2' 'thread-comments T1 tc2'; do
    grep -Fq "$expected" "$dir/gh.log" || fail "missing pagination call: $expected"
  done
  [ "$(file_mode "$snapshot")" = 600 ] || fail "snapshot is not mode 0600"
  pass "review collection fully paginates every connection and retains unknown/minimized content"
}

test_later_page_failure_is_unavailable() {
  local dir rc=0 out
  dir=$(make_case later-page-failure)
  cat > "$dir/pages/comments.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"missing"}}}}}}
JSON
  set +e
  out=$(run_review "$dir" 1000 snapshot task-a "$URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "later-page failure rc=$rc: $out"
  [ ! -e "$dir/home/data/task-a/pr-review-snapshot.json" ] || fail "partial pagination published a snapshot"
  assert_contains "$out" 'not completely paginated' "later-page failure did not name incomplete proof"
  pass "a failed later page cannot become empty or complete review evidence"
}

test_late_feedback_and_edits_reset_settling() {
  local dir snapshot first second
  dir=$(make_case late-feedback)
  seed_one_of_each "$dir"
  run_review "$dir" 1000 snapshot task-a "$URL" >/dev/null || fail "first snapshot failed"
  snapshot="$dir/home/data/task-a/pr-review-snapshot.json"
  first=$(jq -r .fingerprint "$snapshot")
  sed 's/Unknown bot summary: finding A and finding B/Edited bot summary: finding A and finding C/' \
    "$dir/pages/comments.first.json" > "$dir/pages/comments.first.next"
  mv "$dir/pages/comments.first.next" "$dir/pages/comments.first.json"
  run_review "$dir" 1120 snapshot task-a "$URL" >/dev/null || fail "edited snapshot failed"
  second=$(jq -r .fingerprint "$snapshot")
  [ "$first" != "$second" ] || fail "edited top-level summary did not change fingerprint"
  jq -e '.settling.matching_samples==1 and .settling.settled==false' "$snapshot" >/dev/null \
    || fail "edited source did not reset settling"
  # Replace cleanly: two comments at the same head.
  jq '.data.repository.pullRequest.comments.nodes += [{"id":"C2","url":"https://github.com/example/project/pull/17#issuecomment-2","body":"same-head late finding","createdAt":"2026-09-15T12:06:00Z","updatedAt":"2026-09-15T12:06:00Z","isMinimized":false,"minimizedReason":null,"author":null,"authorAssociation":"NONE"}]' \
    "$dir/pages/comments.first.json" > "$dir/pages/comments.first.next"
  mv "$dir/pages/comments.first.next" "$dir/pages/comments.first.json"
  run_review "$dir" 1240 snapshot task-a "$URL" >/dev/null || fail "late finding snapshot failed"
  jq -e '.settling.matching_samples==1 and .settling.settled==false and any(.sources[];.id=="comment:C2")' "$snapshot" >/dev/null \
    || fail "same-head late finding did not reset settling"
  pass "edited summaries and same-head late findings reset the semantic settling interval"
}

test_head_change_and_task_rebind_refuse_publication() {
  local dir new_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa rc=0 out external
  dir=$(make_case head-change)
  set +e
  out=$(FM_TEST_MUTATE_HEAD_TO="$new_head" run_review "$dir" 1000 snapshot task-a "$URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "head-change collection rc=$rc: $out"
  assert_contains "$out" 'head changed during collection' "head race was not reported"
  [ ! -e "$dir/home/data/task-a/pr-review-snapshot.json" ] || fail "head race published evidence"

  dir=$(make_case task-rebind)
  set +e
  out=$(FM_TEST_REBIND_META="$dir/home/state/task-a.meta" run_review "$dir" 1000 snapshot task-a "$URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "task-rebind collection rc=$rc: $out"
  [ ! -e "$dir/home/data/task-a/pr-review-snapshot.json" ] || fail "replacement task received prior incarnation evidence"

  dir=$(make_case snapshot-symlink)
  external="$dir/external"
  printf 'sentinel\n' > "$external"
  ln -s "$external" "$dir/home/data/task-a/pr-review-snapshot.json"
  set +e
  run_review "$dir" 1000 snapshot task-a "$URL" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "symlink snapshot destination was accepted"
  [ "$(cat "$external")" = sentinel ] || fail "symlink target was modified"
  pass "head races, task replacement, and unsafe destinations refuse evidence publication"
}

test_assessment_coverage_and_dispositions() {
  local dir assessment rc=0 out
  dir=$(make_case incomplete)
  seed_one_of_each "$dir"
  run_review "$dir" 1000 snapshot task-a "$URL" >/dev/null || fail "coverage snapshot failed"
  assessment="$dir/incomplete.json"
  make_assessment "$dir" "$assessment" incomplete
  set +e
  out=$(run_review "$dir" 1120 record task-a "$URL" "$assessment" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "incomplete source coverage rc=$rc: $out"
  [ ! -e "$dir/home/data/task-a/pr-review.json" ] || fail "incomplete assessment was published"

  dir=$(make_case mixed-valid)
  seed_one_of_each "$dir"
  out=$(settle_record_verify "$dir" mixed 0) || fail "mixed evidenced dispositions did not verify: $out"
  assert_contains "$out" 'ready:' "valid fixed/not-actionable assessment did not become ready"
  [ "$(file_mode "$dir/home/data/task-a/pr-review.json")" = 600 ] || fail "assessment is not mode 0600"

  dir=$(make_case needs-action)
  seed_one_of_each "$dir"
  out=$(settle_record_verify "$dir" needs-action 1) || fail "needs-action helper failed"
  assert_contains "$out" 'feedback needs action:' "needs-action disposition did not name its source"
  pass "coverage is exact, evidenced dispositions can pass, and needs-action cannot"
}

test_check_and_review_decision_readiness() {
  local dir out
  dir=$(make_case pending-check)
  cat > "$dir/checks.json" <<'JSON'
[{"__typename":"CheckRun","name":"review-bot","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-09-15T12:00:00Z","completedAt":null,"detailsUrl":"https://github.com/example/project/actions/runs/2"}]
JSON
  out=$(settle_record_verify "$dir" all-fixed 1) || fail "pending check fixture failed"
  assert_contains "$out" 'review-bot' "pending visible review check was not reported"

  dir=$(make_case failed-check)
  cat > "$dir/checks.json" <<'JSON'
[{"__typename":"StatusContext","context":"unknown-review","state":"FAILURE","targetUrl":"https://checks.example/1","startedAt":"2026-09-15T12:00:00Z"}]
JSON
  out=$(settle_record_verify "$dir" all-fixed 1) || fail "failed check fixture failed"
  assert_contains "$out" 'unknown-review' "failed visible review check was not reported"

  dir=$(make_case changes-requested)
  printf '%s\n' '"CHANGES_REQUESTED"' > "$dir/decision.json"
  out=$(settle_record_verify "$dir" all-fixed 1) || fail "changes-requested fixture failed"
  assert_contains "$out" 'CHANGES_REQUESTED' "active changes request was not reported"

  dir=$(make_case review-required)
  printf '%s\n' '"REVIEW_REQUIRED"' > "$dir/decision.json"
  out=$(settle_record_verify "$dir" all-fixed 0) || fail "REVIEW_REQUIRED alone blocked presentation: $out"
  assert_contains "$out" 'ready:' "REVIEW_REQUIRED fixture did not become presentable"
  pass "visible checks and changes requests block readiness while REVIEW_REQUIRED alone does not"
}

test_empty_feedback_settles_and_stale_assessment_fails() {
  local dir assessment out rc=0 new_head=89abcdef0123456789abcdef0123456789abcdef
  dir=$(make_case empty-feedback)
  run_review "$dir" 1000 snapshot task-a "$URL" >/dev/null || fail "empty first snapshot failed"
  assessment="$dir/empty.json"
  make_assessment "$dir" "$assessment" all-fixed
  run_review "$dir" 1120 record task-a "$URL" "$assessment" >/dev/null \
    || fail "empty assessment record failed"
  out=$(run_review "$dir" 1121 verify task-a "$URL" 2>&1) \
    || fail "genuinely empty assessment was not ready: $out"
  assert_contains "$out" 'ready:' "empty assessment had no ready result"

  cat > "$dir/pages/comments.first.json" <<'JSON'
{"data":{"repository":{"pullRequest":{"comments":{"nodes":[{"id":"LATE","url":"https://github.com/example/project/pull/17#issuecomment-late","body":"late finding","createdAt":"2026-09-15T12:10:00Z","updatedAt":"2026-09-15T12:10:00Z","isMinimized":false,"minimizedReason":null,"author":null,"authorAssociation":"NONE"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON
  set +e
  out=$(run_review "$dir" 1240 verify task-a "$URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "same-head stale assessment rc=$rc: $out"
  assert_contains "$out" '#issuecomment-late' "late source URL was not reported"
  jq -e '.settling.matching_samples==1 and .settling.settled==false' \
    "$dir/home/data/task-a/pr-review-snapshot.json" >/dev/null \
    || fail "late source did not reset persisted settling state"
  dir=$(make_case stale-head)
  seed_one_of_each "$dir"
  run_review "$dir" 1000 snapshot task-a "$URL" >/dev/null || fail "stale-head snapshot failed"
  assessment="$dir/stale-head.json"
  make_assessment "$dir" "$assessment" all-fixed
  run_review "$dir" 1120 record task-a "$URL" "$assessment" >/dev/null \
    || fail "stale-head assessment record failed"
  printf '%s\n' "$new_head" > "$dir/head"
  sed "s/^pr_head=.*/pr_head=$new_head/" "$dir/home/state/task-a.meta" > "$dir/home/state/task-a.meta.next"
  mv "$dir/home/state/task-a.meta.next" "$dir/home/state/task-a.meta"
  chmod 0600 "$dir/home/state/task-a.meta"
  set +e
  out=$(run_review "$dir" 1240 verify task-a "$URL" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "stale-head assessment rc=$rc: $out"
  assert_contains "$out" 'review assessment is stale' \
    "a valid assessment for the prior head was misclassified as invalid evidence"
  pass "no-feedback evidence can settle, while a later source invalidates it live"
}

test_pr_check_registers_before_ready_publication() {
  local dir channel assessment rc=0 out
  dir=$(make_case pr-check-readiness)
  configure_secondmate_parent "$dir"
  channel="$dir/parent/state/mate-x.status"
  set +e
  out=$(run_pr_check "$dir" 1000 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "default PR check without assessment rc=$rc: $out"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "nonready default check did not preserve the merge poll"
  grep -qxF "pr=$URL" "$dir/home/state/task-a.meta" || fail "nonready default check did not preserve PR metadata"
  [ ! -e "$channel" ] || fail "nonready default check published a parent-ready event"

  assessment="$dir/empty-assessment.json"
  make_assessment "$dir" "$assessment" all-fixed
  run_review "$dir" 1120 record task-a "$URL" "$assessment" >/dev/null \
    || fail "could not record the empty settled assessment"
  out=$(run_pr_check "$dir" 1121 2>&1) || fail "ready default PR check failed: $out"
  grep -Fq "child task-a PR ready: $URL mode=no-mistakes" "$channel" \
    || fail "successful review verification did not publish the parent-ready event"
  run_pr_check "$dir" 1122 >/dev/null 2>&1 || fail "repeated ready PR check failed"
  [ "$(grep -c 'child-pr-task-a' "$channel")" -eq 1 ] \
    || fail "repeated ready verification duplicated the parent event"

  dir=$(make_case pr-check-register-only)
  configure_secondmate_parent "$dir"
  run_pr_check "$dir" 1000 --register-only >/dev/null \
    || fail "register-only PR check failed"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "register-only did not arm the poll"
  [ ! -e "$dir/parent/state/mate-x.status" ] || fail "register-only published readiness"
  pass "fm-pr-check registers first and publishes readiness only after live verification"
}

test_full_nested_pagination_and_retention
test_pr_check_registers_before_ready_publication
test_later_page_failure_is_unavailable
test_late_feedback_and_edits_reset_settling
test_head_change_and_task_rebind_refuse_publication
test_assessment_coverage_and_dispositions
test_check_and_review_decision_readiness
test_empty_feedback_settles_and_stale_assessment_fails
