#!/usr/bin/env bash
# Behavioral coverage for bounded main-home PR delivery discovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DELIVERY="$ROOT/bin/fm-pr-delivery.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-delivery)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/shared-fakebin")

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fake_gh() {
  local fake
  fake="$FAKEBIN"
  cat > "$fake/gh" <<'SH'
#!/usr/bin/env bash
set -u
FIX="${FM_PR_DELIVERY_FIXTURE:?}"
repo=''
num=''
owner=''
name=''
query=''
limit=50
args=("$@")
i=0
while [ "$i" -lt "$#" ]; do
  case "${args[$i]}" in
    --repo) repo="${args[$((i+1))]}"; i=$((i+2)); continue ;;
    view) num="${args[$((i+1))]}"; i=$((i+2)); continue ;;
    owner=*) owner=${args[$i]#owner=}; i=$((i+1)); continue ;;
    name=*) name=${args[$i]#name=}; i=$((i+1)); continue ;;
    number=*) num=${args[$i]#number=}; i=$((i+1)); continue ;;
    query=*) query=${args[$i]#query=}; i=$((i+1)); continue ;;
    --limit) limit=${args[$((i+1))]}; i=$((i+2)); continue ;;
  esac
  i=$((i+1))
done
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  f="$FIX/open/${repo//\//__}.json"
  [ -f "$f" ] || printf '[]\n'
  [ -f "$f" ] && jq -c --argjson limit "$limit" '.[0:$limit]' "$f"
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  if case "$query" in *pullRequests*) true ;; *) false ;; esac; then
    f="$FIX/open/${owner}__${name}.json"
    [ -f "$f" ] || { printf '{"data":{"repository":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}\n'; exit 0; }
    jq -c '{data:{repository:{pullRequests:{nodes:(map({number})),pageInfo:{hasNextPage:false,endCursor:null}}}}}' "$f"
    exit 0
  fi
  f="$FIX/view/${owner}__${name}-${num}.json"
  if [ ! -f "$f" ] && [ -f "$FIX/auto-view-missing" ]; then
    printf '{"data":{"repository":{"pullRequest":{"number":%s,"url":"https://github.com/%s/%s/pull/%s","headRefName":"other/%s","headRefOid":"other-%s","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"pageInfo":{"hasNextPage":false}}}}}]},"reviews":{"nodes":[],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]}}}}}\n' "$num" "$owner" "$name" "$num" "$num" "$num"
    exit 0
  fi
  [ -f "$f" ] || exit 99
  delay="$FIX/delay/${owner}__${name}"
  [ ! -f "$delay" ] || sleep "$(cat "$delay")"
  jq -c '{data:{repository:{pullRequest:{
    number, url, headRefName, headRefOid, baseRefName, reviewDecision, mergeable, state,
    author:(.author // {login:"author"}),
    commits:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:(.statusCheckRollup // []),pageInfo:(.statusCheckRollupPageInfo // {hasNextPage:false})}}}}]},
    reviews:(.reviews // {nodes:[],pageInfo:{hasPreviousPage:false}}),
    comments:(.comments // {nodes:[],pageInfo:{hasPreviousPage:false}}),
    reviewThreads:(.reviewThreads // {nodes:[]})
  }}}}' "$f"
  after="$FIX/after-graphql/${owner}__${name}-${num}.json"
  if [ -f "$after" ]; then
    cp "$after" "$f"
    rm -f "$after"
  fi
  if [ -f "$FIX/fail-delivered-write" ]; then
    rm -rf "$FM_STATE_OVERRIDE/pr-delivery/delivered"
    : > "$FM_STATE_OVERRIDE/pr-delivery/delivered"
  fi
  exit 0
fi
exit 97
SH
  chmod +x "$fake/gh"
}

make_fake_gh

write_open() { # <fixture> <repo> <json>
  mkdir -p "$1/open"
  printf '%s' "$3" > "$1/open/${2//\//__}.json"
}

write_view() { # <fixture> <repo> <num> <json>
  mkdir -p "$1/view"
  printf '%s' "$4" > "$1/view/${2//\//__}-${3}.json"
}

make_world() { # <name>
  local world=$TMP_ROOT/$1
  mkdir -p "$world"/{state,data,config,projects/alpha}
  printf '%s\n' "$world"
}

setup_project() { # <home> <fixture>
  local home=$1 fixture=$2
  cat > "$home/data/projects.md" <<'EOF'
- alpha [direct-PR] - test project (added 2026-01-01)
EOF
  setup_named_project "$home" alpha acme/alpha
  mkdir -p "$fixture/open" "$fixture/view"
}

setup_named_project() { # <home> <project> <repo>
  local home=$1 project=$2 repo=$3 bare
  mkdir -p "$home/projects/$project"
  fm_git_init_commit "$home/projects/$project"
  bare="$home/projects/$project.origin.git"
  fm_git_add_origin "$home/projects/$project" "$bare"
  git -C "$home/projects/$project" remote set-url origin "https://github.com/$repo.git"
}

run_delivery() { # <home> <fixture> <cmd> [args...]
  local home=$1 fixture=$2 cmd=$3
  shift 3
  FM_ROOT_OVERRIDE="$TMP_ROOT/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_PR_DELIVERY_SECS=60 FM_PR_DELIVERY_FIXTURE="$fixture" \
    GH_BIN=gh PATH="$FAKEBIN:$PATH" \
    "$DELIVERY" "$cmd" "$@"
}

test_discovery_without_secondmate() {
  local home fixture out
  home=$(make_world discovery)
  fixture="$TMP_ROOT/fix-discovery"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":7,"url":"https://github.com/acme/alpha/pull/7","headRefName":"fm/ship7","headRefOid":"aaa","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 7 '{"number":7,"url":"https://github.com/acme/alpha/pull/7","headRefName":"fm/ship7","headRefOid":"aaa","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/ship7.meta" \
    'window=fm-ship7' "worktree=$home/projects/ship7" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/7'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "discovery did not find merge-eligible PR from registry+gh alone"
  pass "discovery without secondmate status"
}

test_unrecorded_branch_cannot_impersonate_task() {
  local home fixture out
  home=$(make_world impersonation)
  fixture="$TMP_ROOT/fix-impersonation"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":8,"url":"https://github.com/acme/alpha/pull/8","headRefName":"fm/ship7","headRefOid":"attacker","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 8 '{"number":8,"url":"https://github.com/acme/alpha/pull/8","headRefName":"fm/ship7","headRefOid":"attacker","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/ship7.meta" \
    'window=fm-ship7' "worktree=$home/projects/ship7" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/7'

  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "unrecorded matching branch became merge-eligible"
  run_delivery "$home" "$fixture" show | grep -Fq $'acme/alpha\t8\t' \
    || fail "unrecorded matching branch was not retained in the blocked queue"
  run_delivery "$home" "$fixture" show | grep -Fq 'no-task' \
    || fail "unrecorded matching branch did not require recorded PR identity"
  pass "unrecorded branches cannot impersonate delivery tasks"
}

test_review_issue_then_clearance() {
  local home fixture out
  home=$(make_world review)
  fixture="$TMP_ROOT/fix-review"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":3,"url":"https://github.com/acme/alpha/pull/3","headRefName":"fm/review3","headRefOid":"bbb","baseRefName":"main","reviewDecision":"CHANGES_REQUESTED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 3 '{"number":3,"url":"https://github.com/acme/alpha/pull/3","headRefName":"fm/review3","headRefOid":"bbb","baseRefName":"main","reviewDecision":"CHANGES_REQUESTED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[{"isResolved":false}]},"state":"OPEN"}'
  fm_write_meta "$home/state/review3.meta" \
    'window=fm-review3' "worktree=$home/projects/review3" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/3'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "review-issue PR should not be actionable yet"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "blocked queue missing review-issue"
  write_view "$fixture" acme/alpha 3 '{"number":3,"url":"https://github.com/acme/alpha/pull/3","headRefName":"fm/review3","headRefOid":"ccc","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  write_open "$fixture" acme/alpha '[{"number":3,"url":"https://github.com/acme/alpha/pull/3","headRefName":"fm/review3","headRefOid":"ccc","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "cleared review did not become eligible"
  run_delivery "$home" "$fixture" show | grep -Fq $'acme/alpha\t3\t' \
    && fail "eligible PR remained in the blocked queue"
  pass "review-issue hold clears after head/review change"
}

test_migration_hold_clears() {
  local home fixture out
  home=$(make_world migration)
  fixture="$TMP_ROOT/fix-migration"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":4,"url":"https://github.com/acme/alpha/pull/4","headRefName":"fm/mig4","headRefOid":"ddd","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 4 '{"number":4,"url":"https://github.com/acme/alpha/pull/4","headRefName":"fm/mig4","headRefOid":"ddd","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/mig4.meta" \
    'window=fm-mig4' "worktree=$home/projects/mig4" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/4'
  printf 'needs-decision [key=migration-gate]: await migration evidence\n' > "$home/state/mig4.status"
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "migration hold should block merge"
  run_delivery "$home" "$fixture" show | grep -Fq 'migration-hold' \
    || fail "blocked queue missing migration-hold"
  printf 'resolved [key=migration-gate]: migration applied\n' >> "$home/state/mig4.status"
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "migration clearance did not re-evaluate to eligible"
  pass "migration hold and re-evaluation when status clears"
}

test_base_branch_race() {
  local home fixture out
  home=$(make_world base)
  fixture="$TMP_ROOT/fix-base"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":5,"url":"https://github.com/acme/alpha/pull/5","headRefName":"fm/base5","headRefOid":"eee","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 5 '{"number":5,"url":"https://github.com/acme/alpha/pull/5","headRefName":"fm/base5","headRefOid":"eee","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/base5.meta" \
    'window=fm-base5' "worktree=$home/projects/base5" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/5'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  write_view "$fixture" acme/alpha 5 '{"number":5,"url":"https://github.com/acme/alpha/pull/5","headRefName":"fm/base5","headRefOid":"eee","baseRefName":"release","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  write_open "$fixture" acme/alpha '[{"number":5,"url":"https://github.com/acme/alpha/pull/5","headRefName":"fm/base5","headRefOid":"eee","baseRefName":"release","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "baseRefName change did not trigger re-eval"
  pass "base-branch race triggers re-evaluation"
}

test_review_evidence_uses_single_snapshot() {
  local home fixture out
  home=$(make_world reviewsnapshot)
  fixture="$TMP_ROOT/fix-reviewsnapshot"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":11,"url":"https://github.com/acme/alpha/pull/11","headRefName":"fm/head11","headRefOid":"same","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}]}]'
  write_view "$fixture" acme/alpha 11 '{"number":11,"url":"https://github.com/acme/alpha/pull/11","headRefName":"fm/head11","headRefOid":"same","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  mkdir -p "$fixture/after-graphql"
  printf '%s' '{"number":11,"url":"https://github.com/acme/alpha/pull/11","headRefName":"fm/head11","headRefOid":"same","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}' \
    > "$fixture/after-graphql/acme__alpha-11.json"
  fm_write_meta "$home/state/head11.meta" \
    'window=fm-head11' "worktree=$home/projects/head11" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "review snapshot mixed later passing fields with earlier evidence"
  run_delivery "$home" "$fixture" show | grep -Fq 'checks-pending' \
    || fail "review snapshot did not preserve the captured pending check"
  pass "review evidence uses one GraphQL snapshot"
}

test_optional_review_silence() {
  local home fixture out
  home=$(make_world optional)
  fixture="$TMP_ROOT/fix-optional"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":6,"url":"https://github.com/acme/alpha/pull/6","headRefName":"fm/opt6","headRefOid":"fff","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 6 '{"number":6,"url":"https://github.com/acme/alpha/pull/6","headRefName":"fm/opt6","headRefOid":"fff","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"author":{"login":"author"},"reviews":{"nodes":[{"state":"COMMENTED","body":"I verified this on staging.","submittedAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"comments":{"nodes":[{"body":"FYI.","createdAt":"2026-08-19T00:00:01Z","author":{"login":"reviewer"}},{"body":"I verified this on staging.","createdAt":"2026-08-19T00:00:02Z","author":{"login":"reviewer"}},{"body":"Can this be merged?","createdAt":"2026-08-19T00:00:03Z","author":{"login":"reviewer"}},{"body":"Can we ship this?","createdAt":"2026-08-19T00:00:04Z","author":{"login":"reviewer"}},{"body":"API response looks good.","createdAt":"2026-08-19T00:00:05Z","author":{"login":"reviewer"}},{"body":"Test suite looks good.","createdAt":"2026-08-19T00:00:06Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/opt6.meta" \
    'window=fm-opt6' "worktree=$home/projects/opt6" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/6'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "neutral review comments should not block eligibility"
  pass "optional-review silence allows eligible when checks green"
}

test_comment_review_then_clearance() {
  local home fixture out
  home=$(make_world commentreview)
  fixture="$TMP_ROOT/fix-commentreview"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":17,"url":"https://github.com/acme/alpha/pull/17","headRefName":"fm/comment17","headRefOid":"qqq","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 17 '{"number":17,"url":"https://github.com/acme/alpha/pull/17","headRefName":"fm/comment17","headRefOid":"qqq","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviews":{"nodes":[{"state":"COMMENTED","body":"Can we make this simpler?","submittedAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/comment17.meta" \
    'window=fm-comment17' "worktree=$home/projects/comment17" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/17'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "commented review requesting a change should hold delivery"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "commented review did not produce a review-issue hold"
  write_view "$fixture" acme/alpha 17 '{"number":17,"url":"https://github.com/acme/alpha/pull/17","headRefName":"fm/comment17","headRefOid":"qqq","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviews":{"nodes":[{"state":"COMMENTED","body":"Can we make this simpler?","submittedAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}},{"state":"COMMENTED","body":"FYI.","submittedAt":"2026-08-19T00:00:30Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "benign follow-up must not clear a reviewer request"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "benign follow-up removed the reviewer request hold"
  write_view "$fixture" acme/alpha 17 '{"number":17,"url":"https://github.com/acme/alpha/pull/17","headRefName":"fm/comment17","headRefOid":"qqq","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviews":{"nodes":[{"state":"COMMENTED","body":"Can we make this simpler?","submittedAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}},{"state":"COMMENTED","body":"The concern has been addressed.","submittedAt":"2026-08-19T00:01:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "resolved commented review did not become eligible"
  pass "commented review blocks until clearance"
}

test_pr_comment_then_clearance() {
  local home fixture out
  home=$(make_world prcomment)
  fixture="$TMP_ROOT/fix-prcomment"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":22,"url":"https://github.com/acme/alpha/pull/22","headRefName":"fm/comment22","headRefOid":"ttt","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 22 '{"number":22,"url":"https://github.com/acme/alpha/pull/22","headRefName":"fm/comment22","headRefOid":"ttt","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"author":{"login":"author"},"reviews":{"nodes":[],"pageInfo":{"hasPreviousPage":false}},"comments":{"nodes":[{"body":"Can this use the shared helper here?","createdAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/comment22.meta" \
    'window=fm-comment22' "worktree=$home/projects/comment22" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/22'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "ordinary PR comment requesting a change should hold delivery"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "ordinary PR comment did not produce a review-issue hold"
  write_view "$fixture" acme/alpha 22 '{"number":22,"url":"https://github.com/acme/alpha/pull/22","headRefName":"fm/comment22","headRefOid":"ttt","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"author":{"login":"author"},"reviews":{"nodes":[],"pageInfo":{"hasPreviousPage":false}},"comments":{"nodes":[{"body":"Can this use the shared helper here?","createdAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}},{"body":"FYI.","createdAt":"2026-08-19T00:00:30Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "benign PR-comment follow-up must not clear a reviewer request"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "benign PR-comment follow-up removed the reviewer request hold"
  write_view "$fixture" acme/alpha 22 '{"number":22,"url":"https://github.com/acme/alpha/pull/22","headRefName":"fm/comment22","headRefOid":"ttt","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"author":{"login":"author"},"reviews":{"nodes":[{"state":"APPROVED","body":"","submittedAt":"2026-08-19T00:01:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"comments":{"nodes":[{"body":"Can this use the shared helper here?","createdAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "approved ordinary PR comment request did not become eligible"
  pass "ordinary PR comments block until clearance"
}

test_imperative_pr_comment_holds() {
  local home fixture out
  home=$(make_world imperativecomment)
  fixture="$TMP_ROOT/fix-imperativecomment"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":25,"url":"https://github.com/acme/alpha/pull/25","headRefName":"fm/comment25","headRefOid":"www","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 25 '{"number":25,"url":"https://github.com/acme/alpha/pull/25","headRefName":"fm/comment25","headRefOid":"www","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"author":{"login":"author"},"reviews":{"nodes":[],"pageInfo":{"hasPreviousPage":false}},"comments":{"nodes":[{"body":"Please use the shared helper here.","createdAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/comment25.meta" \
    'window=fm-comment25' "worktree=$home/projects/comment25" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/25'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "imperative PR comment requesting code work should hold delivery"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "imperative PR comment did not produce a review-issue hold"
  write_view "$fixture" acme/alpha 25 '{"number":25,"url":"https://github.com/acme/alpha/pull/25","headRefName":"fm/comment25","headRefOid":"www","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"author":{"login":"author"},"reviews":{"nodes":[],"pageInfo":{"hasPreviousPage":false}},"comments":{"nodes":[{"body":"Please use the shared helper here.","createdAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}},{"body":"This is now resolved.","createdAt":"2026-08-19T00:01:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "explicit PR-comment resolution did not become eligible"
  pass "imperative PR comments block delivery"
}

test_recommendation_pr_comment_holds() {
  local home fixture out
  home=$(make_world recommendationcomment)
  fixture="$TMP_ROOT/fix-recommendationcomment"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":26,"url":"https://github.com/acme/alpha/pull/26","headRefName":"fm/comment26","headRefOid":"xxx","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 26 '{"number":26,"url":"https://github.com/acme/alpha/pull/26","headRefName":"fm/comment26","headRefOid":"xxx","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"author":{"login":"author"},"reviews":{"nodes":[],"pageInfo":{"hasPreviousPage":false}},"comments":{"nodes":[{"body":"Consider using the shared helper here.","createdAt":"2026-08-19T00:00:00Z","author":{"login":"reviewer"}}],"pageInfo":{"hasPreviousPage":false}},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/comment26.meta" \
    'window=fm-comment26' "worktree=$home/projects/comment26" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "recommendation PR comment requesting code work should hold delivery"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "recommendation PR comment did not produce a review-issue hold"
  pass "recommendation PR comments block delivery"
}

test_closed_snapshot_holds_delivery() {
  local home fixture out
  home=$(make_world closedsnapshot)
  fixture="$TMP_ROOT/fix-closedsnapshot"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":24,"url":"https://github.com/acme/alpha/pull/24","headRefName":"fm/closed24","headRefOid":"vvv","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 24 '{"number":24,"url":"https://github.com/acme/alpha/pull/24","headRefName":"fm/closed24","headRefOid":"vvv","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"CLOSED"}'
  fm_write_meta "$home/state/closed24.meta" \
    'window=fm-closed24' "worktree=$home/projects/closed24" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "closed snapshot should not queue delivery"
  run_delivery "$home" "$fixture" show | grep -Fq 'not-open' \
    || fail "closed snapshot did not produce an explicit hold"
  pass "closed snapshots never queue delivery"
}

test_review_thread_revalidation() {
  local home fixture out
  home=$(make_world threadrace)
  fixture="$TMP_ROOT/fix-threadrace"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":23,"url":"https://github.com/acme/alpha/pull/23","headRefName":"fm/thread23","headRefOid":"uuu","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 23 '{"number":23,"url":"https://github.com/acme/alpha/pull/23","headRefName":"fm/thread23","headRefOid":"uuu","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[{"id":"thread-23","isResolved":true}]},"state":"OPEN"}'
  mkdir -p "$fixture/after-graphql"
  printf '%s' '{"number":23,"url":"https://github.com/acme/alpha/pull/23","headRefName":"fm/thread23","headRefOid":"uuu","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[{"id":"thread-23","isResolved":false}]},"state":"OPEN"}' \
    > "$fixture/after-graphql/acme__alpha-23.json"
  fm_write_meta "$home/state/thread23.meta" \
    'window=fm-thread23' "worktree=$home/projects/thread23" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "reopened review thread should not queue delivery"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "review-thread revalidation missed a reopened thread"
  pass "review-thread evidence is revalidated"
}

test_check_evidence_requires_success() {
  local home fixture out
  home=$(make_world checkevidence)
  fixture="$TMP_ROOT/fix-checkevidence"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":18,"url":"https://github.com/acme/alpha/pull/18","headRefName":"fm/check18","headRefOid":"rrr","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]'
  write_view "$fixture" acme/alpha 18 '{"number":18,"url":"https://github.com/acme/alpha/pull/18","headRefName":"fm/check18","headRefOid":"rrr","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/check18.meta" \
    'window=fm-check18' "worktree=$home/projects/check18" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "missing checks should not become eligible"
  run_delivery "$home" "$fixture" show | grep -Fq 'checks-missing' \
    || fail "missing checks did not produce an explicit hold"
  write_view "$fixture" acme/alpha 18 '{"number":18,"url":"https://github.com/acme/alpha/pull/18","headRefName":"fm/check18","headRefOid":"rrr","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"statusCheckRollupPageInfo":{"hasNextPage":true},"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "truncated check evidence should not become eligible"
  run_delivery "$home" "$fixture" show | grep -Fq 'checks-incomplete' \
    || fail "truncated check evidence did not produce an explicit hold"
  write_view "$fixture" acme/alpha 18 '{"number":18,"url":"https://github.com/acme/alpha/pull/18","headRefName":"fm/check18","headRefOid":"rrr","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"STALE","status":"COMPLETED"},{"conclusion":"STARTUP_FAILURE","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "non-green check conclusions should not become eligible"
  run_delivery "$home" "$fixture" show | grep -Fq 'checks-failing' \
    || fail "non-green check conclusions did not produce a failing hold"
  pass "check evidence requires complete success"
}

test_generic_authority_hold_ignores_yolo() {
  local home fixture out
  home=$(make_world authority)
  fixture="$TMP_ROOT/fix-authority"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":19,"url":"https://github.com/acme/alpha/pull/19","headRefName":"fm/authority19","headRefOid":"sss","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 19 '{"number":19,"url":"https://github.com/acme/alpha/pull/19","headRefName":"fm/authority19","headRefOid":"sss","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/authority19.meta" \
    'window=fm-authority19' "worktree=$home/projects/authority19" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/19'
  printf 'needs-decision [key=security-review]: await security approval\n' > "$home/state/authority19.status"
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "generic authority decision should hold even with yolo"
  run_delivery "$home" "$fixture" show | grep -Fq 'authority-hold' \
    || fail "generic authority decision did not produce an authority hold"
  printf 'resolved [key=security-review]: approved\n' >> "$home/state/authority19.status"
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "resolved authority decision did not re-evaluate"
  pass "generic authority holds override yolo"
}

test_open_pr_inventory_paginates() {
  local home fixture out open key
  home=$(make_world inventory)
  fixture="$TMP_ROOT/fix-inventory"
  setup_project "$home" "$fixture"
  open=$(jq -nc '[range(1; 52) | {number: ., url: ("https://github.com/acme/alpha/pull/" + tostring), headRefName: ("other/" + tostring), headRefOid: ("head-" + tostring), baseRefName: "main", reviewDecision: "", mergeable: "MERGEABLE", statusCheckRollup: [{conclusion: "SUCCESS", status: "COMPLETED"}]}] | .[50].headRefName = "fm/page51"')
  write_open "$fixture" acme/alpha "$open"
  : > "$fixture/auto-view-missing"
  write_view "$fixture" acme/alpha 51 '{"number":51,"url":"https://github.com/acme/alpha/pull/51","headRefName":"fm/page51","headRefOid":"head-51","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/page51.meta" \
    'window=fm-page51' "worktree=$home/projects/page51" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/51'
  key=$(printf '%s' acme/alpha | shasum -a 256 | awk '{print substr($1, 1, 32)}')
  mkdir -p "$home/state/pr-delivery/pr-cursors"
  printf '49\n' > "$home/state/pr-delivery/pr-cursors/$key.cursor"
  out=$(FM_PR_DELIVERY_BUDGET_SECS=5 run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'pr=51' \
    || fail "open PR after the first page was not discovered"
  pass "open PR inventory paginates beyond fifty"
}

test_partial_scan_preserves_blocked_queue() {
  local home fixture
  home=$(make_world queuepartial)
  fixture="$TMP_ROOT/fix-queuepartial"
  cat > "$home/data/projects.md" <<'EOF'
- alpha [direct-PR] - first queue project (added 2026-01-01)
- beta [direct-PR] - delayed queue project (added 2026-01-01)
EOF
  setup_named_project "$home" alpha acme/alpha
  setup_named_project "$home" beta acme/beta
  mkdir -p "$fixture/open" "$fixture/view" "$fixture/delay"
  write_open "$fixture" acme/alpha '[{"number":20,"url":"https://github.com/acme/alpha/pull/20","headRefName":"other/20","headRefOid":"ttt","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 20 '{"number":20,"url":"https://github.com/acme/alpha/pull/20","headRefName":"other/20","headRefOid":"ttt","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  write_open "$fixture" acme/beta '[{"number":21,"url":"https://github.com/acme/beta/pull/21","headRefName":"other/21","headRefOid":"uuu","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/beta 21 '{"number":21,"url":"https://github.com/acme/beta/pull/21","headRefName":"other/21","headRefOid":"uuu","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  FM_PR_DELIVERY_BUDGET_SECS=5 run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  printf '1.2\n' > "$fixture/delay/acme__beta"
  FM_PR_DELIVERY_BUDGET_SECS=1 run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  run_delivery "$home" "$fixture" show | grep -Fq $'acme/beta\t21\t' \
    || fail "partial scan discarded the unvisited blocked PR"
  pass "partial scan preserves blocked queue rows"
}

test_repository_state_keys_do_not_alias() {
  local home fixture count
  home=$(make_world repokeys)
  fixture="$TMP_ROOT/fix-repokeys"
  cat > "$home/data/projects.md" <<'EOF'
- alpha [direct-PR] - collision one (added 2026-01-01)
- beta [direct-PR] - collision two (added 2026-01-01)
EOF
  setup_named_project "$home" alpha a_b/c
  setup_named_project "$home" beta a/b_c
  mkdir -p "$fixture/open" "$fixture/view"
  write_open "$fixture" a_b/c '[{"number":14,"url":"https://github.com/a_b/c/pull/14","headRefName":"fm/key14a","headRefOid":"mmm","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[]}]'
  write_view "$fixture" a_b/c 14 '{"number":14,"url":"https://github.com/a_b/c/pull/14","headRefName":"fm/key14a","headRefOid":"mmm","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  write_open "$fixture" a/b_c '[{"number":14,"url":"https://github.com/a/b_c/pull/14","headRefName":"fm/key14b","headRefOid":"nnn","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[]}]'
  write_view "$fixture" a/b_c 14 '{"number":14,"url":"https://github.com/a/b_c/pull/14","headRefName":"fm/key14b","headRefOid":"nnn","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  count=$(find "$home/state/pr-delivery/fingerprints" -type f -name '*.fp' | wc -l | tr -d ' ')
  [ "$count" -eq 2 ] || fail "distinct repositories aliased to one persisted PR state key"
  pass "repository state keys remain distinct"
}

test_task_authority_stays_with_its_project() {
  local home fixture out
  home=$(make_world taskproject)
  fixture="$TMP_ROOT/fix-taskproject"
  cat > "$home/data/projects.md" <<'EOF'
- alpha [direct-PR] - task owner (added 2026-01-01)
- beta [direct-PR] - unrelated PR (added 2026-01-01)
EOF
  setup_named_project "$home" alpha acme/alpha
  setup_named_project "$home" beta acme/beta
  mkdir -p "$fixture/open" "$fixture/view"
  write_open "$fixture" acme/alpha '[]'
  write_open "$fixture" acme/beta '[{"number":16,"url":"https://github.com/acme/beta/pull/16","headRefName":"fm/shared16","headRefOid":"ppp","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/beta 16 '{"number":16,"url":"https://github.com/acme/beta/pull/16","headRefName":"fm/shared16","headRefOid":"ppp","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/shared16.meta" \
    'window=fm-shared16' "worktree=$home/projects/shared16" "project=$home/projects/alpha" \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "task authority crossed into an unrelated project"
  run_delivery "$home" "$fixture" show | grep -Fq 'no-task' \
    || fail "cross-project branch was not held as unlinked"
  fm_write_meta "$home/state/shared16.meta" \
    'window=fm-shared16' "worktree=$home/projects/shared16" "project=$home/projects/beta" \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/beta/pull/16'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "same-project task did not become eligible"
  pass "task authority remains scoped to its project"
}

test_deadline_retries_incomplete_repository() {
  local home fixture out
  home=$(make_world cursor)
  fixture="$TMP_ROOT/fix-cursor"
  cat > "$home/data/projects.md" <<'EOF'
- alpha [direct-PR] - cursor start (added 2026-01-01)
- beta [direct-PR] - deadline target (added 2026-01-01)
- gamma [direct-PR] - cursor tail (added 2026-01-01)
EOF
  setup_named_project "$home" alpha acme/alpha
  setup_named_project "$home" beta acme/beta
  setup_named_project "$home" gamma acme/gamma
  mkdir -p "$fixture/open" "$fixture/view" "$fixture/delay"
  write_open "$fixture" acme/alpha '[]'
  write_open "$fixture" acme/beta '[{"number":15,"url":"https://github.com/acme/beta/pull/15","headRefName":"fm/cursor15","headRefOid":"ooo","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/beta 15 '{"number":15,"url":"https://github.com/acme/beta/pull/15","headRefName":"fm/cursor15","headRefOid":"ooo","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  write_open "$fixture" acme/gamma '[]'
  fm_write_meta "$home/state/cursor15.meta" \
    'window=fm-cursor15' "worktree=$home/projects/cursor15" 'project=beta' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/beta/pull/15'
  mkdir -p "$home/state/pr-delivery"
  printf 'epoch=1\ncursor=alpha\n' > "$home/state/pr-delivery/.scan-marker"
  printf '1.2\n' > "$fixture/delay/acme__beta"
  FM_PR_DELIVERY_BUDGET_SECS=1 run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  grep -qxF 'cursor=alpha' "$home/state/pr-delivery/.scan-marker" \
    || fail "deadline committed the incomplete repository as cursor"
  rm -f "$fixture/delay/acme__beta"
  out=$(FM_PR_DELIVERY_BUDGET_SECS=5 run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'repo=acme/beta' \
    || fail "deadline advanced past an incomplete repository"
  pass "deadline retries the incomplete repository"
}

test_accelerate_marker() {
  local home fixture out
  home=$(make_world accel)
  fixture="$TMP_ROOT/fix-accel"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":9,"url":"https://github.com/acme/alpha/pull/9","headRefName":"fm/accel9","headRefOid":"hhh","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 9 '{"number":9,"url":"https://github.com/acme/alpha/pull/9","headRefName":"fm/accel9","headRefOid":"hhh","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/accel9.meta" \
    'window=fm-accel9' "worktree=$home/projects/accel9" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/9'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  out=$(run_delivery "$home" "$fixture" _scan-locked 0)
  [ -z "$out" ] || fail "repeat scan without change should be silent"
  run_delivery "$home" "$fixture" accelerate 'https://github.com/acme/alpha/pull/9'
  out=$(run_delivery "$home" "$fixture" _scan-locked 0)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "accelerate marker did not speed re-eval"
  pass "accelerate marker speeds eval but scan still discovers without it"
}

test_blocked_accelerate_marker_is_consumed() {
  local home fixture marker
  home=$(make_world accelblocked)
  fixture="$TMP_ROOT/fix-accelblocked"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":28,"url":"https://github.com/acme/alpha/pull/28","headRefName":"other/28","headRefOid":"blocked","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 28 '{"number":28,"url":"https://github.com/acme/alpha/pull/28","headRefName":"other/28","headRefOid":"blocked","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  run_delivery "$home" "$fixture" accelerate 'https://github.com/acme/alpha/pull/28'
  marker=$(find "$home/state/pr-delivery/accelerate" -type f -name '*.marker' -print -quit)
  [ -n "$marker" ] || fail "accelerate did not create a marker"
  run_delivery "$home" "$fixture" _scan-locked 0 >/dev/null
  [ ! -e "$marker" ] || fail "completed blocked scan did not consume the marker"
  pass "completed blocked scans consume acceleration markers"
}

test_show_blocked_queue() {
  local home fixture
  home=$(make_world showq)
  fixture="$TMP_ROOT/fix-show"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":2,"url":"https://github.com/acme/alpha/pull/2","headRefName":"fm/hold2","headRefOid":"iii","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 2 '{"number":2,"url":"https://github.com/acme/alpha/pull/2","headRefName":"fm/hold2","headRefOid":"iii","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/hold2.meta" \
    'window=fm-hold2' "worktree=$home/projects/hold2" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  run_delivery "$home" "$fixture" show | grep -Fq 'not-mergeable' \
    || fail "show did not print blocked queue with reason code"
  pass "show prints blocked queue with reason codes"
}

test_secondmate_refuses_scan() {
  local home fixture rc
  home=$(make_world mate)
  fixture="$TMP_ROOT/fix-mate"
  setup_project "$home" "$fixture"
  printf 'mate\n' > "$home/.fm-secondmate-home"
  set +e
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null 2>"$TMP_ROOT/mate.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "secondmate home should refuse scan"
  grep -Fq 'main home only' "$TMP_ROOT/mate.err" \
    || fail "secondmate refusal missing expected message"
  pass "secondmate home refuses scan"
}

test_wake_failure_remains_retryable() {
  local home fixture delivered marker rc out
  home=$(make_world wakepublish)
  fixture="$TMP_ROOT/fix-wakepublish"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":12,"url":"https://github.com/acme/alpha/pull/12","headRefName":"fm/wake12","headRefOid":"kkk","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 12 '{"number":12,"url":"https://github.com/acme/alpha/pull/12","headRefName":"fm/wake12","headRefOid":"kkk","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/wake12.meta" \
    'window=fm-wake12' "worktree=$home/projects/wake12" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/12'
  run_delivery "$home" "$fixture" accelerate 'https://github.com/acme/alpha/pull/12'
  marker=$(find "$home/state/pr-delivery/accelerate" -type f -name '*.marker' -print -quit)
  mkdir "$home/state/wake-target"
  set +e
  FM_WAKE_QUEUE="$home/state/wake-target" run_delivery "$home" "$fixture" _scan-locked 1 \
    >"$TMP_ROOT/wakepublish.out" 2>"$TMP_ROOT/wakepublish.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "wake publication failure should fail the scan"
  delivered=$(find "$home/state/pr-delivery/delivered" -type f -name '*.delivered' -print -quit)
  [ -z "$delivered" ] || fail "failed wake publication committed delivered marker"
  [ -f "$marker" ] || fail "failed wake publication removed acceleration marker"
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "failed wake publication was not retried"
  pass "wake publication failure remains retryable"
}

test_post_wake_commit_failure_preserves_observation() {
  local home fixture fp rc
  home=$(make_world wakefail)
  fixture="$TMP_ROOT/fix-wakefail"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":10,"url":"https://github.com/acme/alpha/pull/10","headRefName":"fm/wake10","headRefOid":"jjj","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 10 '{"number":10,"url":"https://github.com/acme/alpha/pull/10","headRefName":"fm/wake10","headRefOid":"jjj","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/wake10.meta" \
    'window=fm-wake10' "worktree=$home/projects/wake10" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/10'
  : > "$fixture/fail-delivered-write"
  set +e
  run_delivery "$home" "$fixture" _scan-locked 1 \
    >"$TMP_ROOT/wakefail.out" 2>"$TMP_ROOT/wakefail.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "delivered-marker failure should fail the scan"
  grep -Fq $'\tcheck\tpr-delivery\tmerge-eligible:' "$home/state/.wake-queue" \
    || fail "merge wake was not durable before delivered-marker failure"
  fp=$(find "$home/state/pr-delivery/fingerprints" -type f -name '*.fp' -print -quit)
  [ -n "$fp" ] || fail "published wake lacked independent observation fingerprint"
  pass "post-wake commit failure preserves observation"
}

test_discovery_without_secondmate
test_unrecorded_branch_cannot_impersonate_task
test_review_issue_then_clearance
test_migration_hold_clears
test_base_branch_race
test_review_evidence_uses_single_snapshot
test_optional_review_silence
test_comment_review_then_clearance
test_pr_comment_then_clearance
test_imperative_pr_comment_holds
test_recommendation_pr_comment_holds
test_closed_snapshot_holds_delivery
test_review_thread_revalidation
test_check_evidence_requires_success
test_generic_authority_hold_ignores_yolo
test_open_pr_inventory_paginates
test_partial_scan_preserves_blocked_queue
test_repository_state_keys_do_not_alias
test_task_authority_stays_with_its_project
test_deadline_retries_incomplete_repository
test_accelerate_marker
test_blocked_accelerate_marker_is_consumed
test_show_blocked_queue
test_secondmate_refuses_scan
test_wake_failure_remains_retryable
test_post_wake_commit_failure_preserves_observation

echo "all pr-delivery tests passed"
