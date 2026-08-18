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
args=("$@")
i=0
while [ "$i" -lt "$#" ]; do
  case "${args[$i]}" in
    --repo) repo="${args[$((i+1))]}"; i=$((i+2)); continue ;;
    view) num="${args[$((i+1))]}"; i=$((i+2)); continue ;;
    owner=*) owner=${args[$i]#owner=}; i=$((i+1)); continue ;;
    name=*) name=${args[$i]#name=}; i=$((i+1)); continue ;;
    number=*) num=${args[$i]#number=}; i=$((i+1)); continue ;;
  esac
  i=$((i+1))
done
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  f="$FIX/open/${repo//\//__}.json"
  [ -f "$f" ] || printf '[]\n'
  [ -f "$f" ] && cat "$f"
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  case " $* " in
    *reviewThreads*) exit 98 ;;
  esac
  f="$FIX/view/${repo//\//__}-${num}.json"
  if [ -f "$f" ]; then jq -c 'del(.reviewThreads)' "$f"; exit 0; fi
  printf '{"state":"OPEN"}\n'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  f="$FIX/view/${owner}__${name}-${num}.json"
  [ -f "$f" ] || exit 99
  jq -c '{data:{repository:{pullRequest:{headRefOid,reviewThreads:(.reviewThreads // {nodes:[]})}}}}' "$f"
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
  local home=$1 fixture=$2 bare
  cat > "$home/data/projects.md" <<'EOF'
- alpha [direct-PR] - test project (added 2026-01-01)
EOF
  fm_git_init_commit "$home/projects/alpha"
  bare="$home/projects/alpha.origin.git"
  fm_git_add_origin "$home/projects/alpha" "$bare"
  git -C "$home/projects/alpha" remote set-url origin "https://github.com/acme/alpha.git"
  mkdir -p "$fixture/open" "$fixture/view"
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
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "discovery did not find merge-eligible PR from registry+gh alone"
  pass "discovery without secondmate status"
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
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "review-issue PR should not be actionable yet"
  run_delivery "$home" "$fixture" show | grep -Fq 'review-issue' \
    || fail "blocked queue missing review-issue"
  write_view "$fixture" acme/alpha 3 '{"number":3,"url":"https://github.com/acme/alpha/pull/3","headRefName":"fm/review3","headRefOid":"ccc","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  write_open "$fixture" acme/alpha '[{"number":3,"url":"https://github.com/acme/alpha/pull/3","headRefName":"fm/review3","headRefOid":"ccc","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "cleared review did not become eligible"
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
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
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
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  write_view "$fixture" acme/alpha 5 '{"number":5,"url":"https://github.com/acme/alpha/pull/5","headRefName":"fm/base5","headRefOid":"eee","baseRefName":"release","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  write_open "$fixture" acme/alpha '[{"number":5,"url":"https://github.com/acme/alpha/pull/5","headRefName":"fm/base5","headRefOid":"eee","baseRefName":"release","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "baseRefName change did not trigger re-eval"
  pass "base-branch race triggers re-evaluation"
}

test_head_change_during_review_fetch() {
  local home fixture out
  home=$(make_world headrace)
  fixture="$TMP_ROOT/fix-headrace"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":11,"url":"https://github.com/acme/alpha/pull/11","headRefName":"fm/head11","headRefOid":"old","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 11 '{"number":11,"url":"https://github.com/acme/alpha/pull/11","headRefName":"fm/head11","headRefOid":"old","baseRefName":"main","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  mkdir -p "$fixture/after-graphql"
  printf '%s' '{"number":11,"url":"https://github.com/acme/alpha/pull/11","headRefName":"fm/head11","headRefOid":"new","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}' \
    > "$fixture/after-graphql/acme__alpha-11.json"
  fm_write_meta "$home/state/head11.meta" \
    'window=fm-head11' "worktree=$home/projects/head11" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  [ -z "$out" ] || fail "head race mixed passing evidence from the previous head"
  run_delivery "$home" "$fixture" show | grep -Fq 'checks-pending' \
    || fail "head race did not classify the revalidated current head"
  pass "head change retries review evidence for the current head"
}

test_optional_review_silence() {
  local home fixture out
  home=$(make_world optional)
  fixture="$TMP_ROOT/fix-optional"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":6,"url":"https://github.com/acme/alpha/pull/6","headRefName":"fm/opt6","headRefOid":"fff","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 6 '{"number":6,"url":"https://github.com/acme/alpha/pull/6","headRefName":"fm/opt6","headRefOid":"fff","baseRefName":"main","reviewDecision":"REVIEW_REQUIRED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/opt6.meta" \
    'window=fm-opt6' "worktree=$home/projects/opt6" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "REVIEW_REQUIRED without threads should be eligible"
  pass "optional-review silence allows eligible when checks green"
}

test_post_merge_routing() {
  local home fixture out fp
  home=$(make_world merged)
  fixture="$TMP_ROOT/fix-merged"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":8,"url":"https://github.com/acme/alpha/pull/8","headRefName":"fm/merge8","headRefOid":"ggg","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]'
  write_view "$fixture" acme/alpha 8 '{"number":8,"url":"https://github.com/acme/alpha/pull/8","headRefName":"fm/merge8","headRefOid":"ggg","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/merge8.meta" \
    'window=fm-merge8' "worktree=$home/projects/merge8" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on' \
    'pr=https://github.com/acme/alpha/pull/8'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  write_open "$fixture" acme/alpha '[]'
  write_view "$fixture" acme/alpha 8 '{"state":"MERGED","mergedAt":"2026-08-18T00:00:00Z"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'post-merge:' \
    || fail "merged PR did not trigger post-merge actionable"
  pass "post-merge monitoring routes merged PR"
}

test_closed_pr_state_retires_and_reopens() {
  local home fixture out
  home=$(make_world closed)
  fixture="$TMP_ROOT/fix-closed"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":13,"url":"https://github.com/acme/alpha/pull/13","headRefName":"fm/closed13","headRefOid":"lll","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 13 '{"number":13,"url":"https://github.com/acme/alpha/pull/13","headRefName":"fm/closed13","headRefOid":"lll","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/closed13.meta" \
    'window=fm-closed13' "worktree=$home/projects/closed13" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  write_open "$fixture" acme/alpha '[]'
  write_view "$fixture" acme/alpha 13 '{"state":"CLOSED","mergedAt":null}'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  [ -z "$(find "$home/state/pr-delivery/fingerprints" -type f -name '*.fp' -print -quit)" ] \
    || fail "closed PR retained its observation fingerprint"
  [ -z "$(find "$home/state/pr-delivery/delivered" -type f -name '*.delivered' -print -quit)" ] \
    || fail "closed PR retained its delivered marker"
  write_open "$fixture" acme/alpha '[{"number":13,"url":"https://github.com/acme/alpha/pull/13","headRefName":"fm/closed13","headRefOid":"lll","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 13 '{"number":13,"url":"https://github.com/acme/alpha/pull/13","headRefName":"fm/closed13","headRefOid":"lll","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "unchanged reopened PR remained suppressed"
  pass "closed PR state retires and unchanged reopen re-evaluates"
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
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
  run_delivery "$home" "$fixture" _scan-locked 1 >/dev/null
  out=$(run_delivery "$home" "$fixture" _scan-locked 0)
  [ -z "$out" ] || fail "repeat scan without change should be silent"
  run_delivery "$home" "$fixture" accelerate 'https://github.com/acme/alpha/pull/9'
  out=$(run_delivery "$home" "$fixture" _scan-locked 0)
  printf '%s\n' "$out" | grep -Fq 'merge-eligible:' \
    || fail "accelerate marker did not speed re-eval"
  pass "accelerate marker speeds eval but scan still discovers without it"
}

test_show_blocked_queue() {
  local home fixture
  home=$(make_world showq)
  fixture="$TMP_ROOT/fix-show"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":2,"url":"https://github.com/acme/alpha/pull/2","headRefName":"fm/hold2","headRefOid":"iii","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[]}]'
  write_view "$fixture" acme/alpha 2 '{"number":2,"url":"https://github.com/acme/alpha/pull/2","headRefName":"fm/hold2","headRefOid":"iii","baseRefName":"main","reviewDecision":"","mergeable":"CONFLICTING","statusCheckRollup":[],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
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
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
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

test_post_wake_commit_failure_preserves_tracking() {
  local home fixture fp rc out
  home=$(make_world wakefail)
  fixture="$TMP_ROOT/fix-wakefail"
  setup_project "$home" "$fixture"
  write_open "$fixture" acme/alpha '[{"number":10,"url":"https://github.com/acme/alpha/pull/10","headRefName":"fm/wake10","headRefOid":"jjj","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]'
  write_view "$fixture" acme/alpha 10 '{"number":10,"url":"https://github.com/acme/alpha/pull/10","headRefName":"fm/wake10","headRefOid":"jjj","baseRefName":"main","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}],"reviewThreads":{"nodes":[]},"state":"OPEN"}'
  fm_write_meta "$home/state/wake10.meta" \
    'window=fm-wake10' "worktree=$home/projects/wake10" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=direct-PR' 'yolo=on'
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
  rm -f "$fixture/fail-delivered-write" "$home/state/pr-delivery/delivered"
  mkdir "$home/state/pr-delivery/delivered"
  write_open "$fixture" acme/alpha '[]'
  write_view "$fixture" acme/alpha 10 '{"state":"MERGED","mergedAt":"2026-08-18T00:00:00Z"}'
  out=$(run_delivery "$home" "$fixture" _scan-locked 1)
  printf '%s\n' "$out" | grep -Fq 'post-merge:' \
    || fail "observation fingerprint did not preserve post-merge routing"
  pass "post-wake commit failure preserves post-merge tracking"
}

test_discovery_without_secondmate
test_review_issue_then_clearance
test_migration_hold_clears
test_base_branch_race
test_head_change_during_review_fetch
test_optional_review_silence
test_post_merge_routing
test_closed_pr_state_retires_and_reopens
test_accelerate_marker
test_show_blocked_queue
test_secondmate_refuses_scan
test_wake_failure_remains_retryable
test_post_wake_commit_failure_preserves_tracking

echo "all pr-delivery tests passed"
