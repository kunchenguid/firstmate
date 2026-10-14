#!/usr/bin/env bash
# Behavioral coverage for the head-keyed PR review ledger and its silent gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-pr-review.sh"
RISK="$ROOT/bin/fm-pr-risk.sh"
SNAPSHOTTER="$ROOT/bin/fm-pr-review-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review-tests)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
URL=https://github.com/o/r/pull/7
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
MERGED_SHA=cccccccccccccccccccccccccccccccccccccccc
POST_MERGE_FAKEBIN=$(fm_fakebin "$TMP_ROOT/post-merge-fake")
cat > "$POST_MERGE_FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-} ${2:-}" in
  "api /repos/o/r/pulls/7")
    head=${FM_TEST_PR_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
    if [ "${FM_TEST_PR_MERGED:-true}" = true ]; then
      printf '{"merged":true,"merge_commit_sha":"cccccccccccccccccccccccccccccccccccccccc","head":{"sha":"%s"}}\n' "$head"
    else
      printf '{"merged":false,"merge_commit_sha":null,"head":{"sha":"%s"}}\n' "$head"
    fi
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
chmod +x "$POST_MERGE_FAKEBIN/gh"

snapshot() { # path head pending-json comments-json checks-json files-json
  jq -n --arg url "$URL" --arg head "$2" \
    --argjson pending "$3" --argjson comments "$4" --argjson checks "$5" --argjson files "$6" '{
      schema:"firstmate-pr-review-snapshot.v1",url:$url,head:$head,collector_actor:"maintainer",
      pending_reviews:$pending,comments:$comments,checks:$checks,files:$files
    }' > "$1"
}

review() {
  FM_HOME="$HOME_DIR" FM_REVIEW_NOW="${FM_TEST_NOW_ISO:-2026-09-20T00:00:00Z}" \
    FM_REVIEW_NOW_EPOCH="${FM_TEST_NOW_EPOCH:-1000}" "$REVIEW" "$@"
}

post_merge_review() {
  PATH="$POST_MERGE_FAKEBIN:$PATH" review "$@"
}

ledger() {
  printf '%s/data/pr-review-ledger/github--o--r--7.json\n' "$HOME_DIR"
}

FINAL_DISPOSITION_SNAPSHOT=
bind_final_disposition() { # head evidence-url snapshot-without-final-post
  local head=$1 evidence=$2 source=$3 posted="$TMP_ROOT/final-disposition-observed.json"
  review final-disposition "$URL" "$head" "$evidence" >/dev/null
  jq --arg evidence "$evidence" --arg head "$head" '
    .collector_actor as $actor
    | .comments += [{kind:"top-level",id:"final-disposition",url:$evidence,author:$actor,
        body:"final disposition evidence",updated_at:"2026-09-20T00:30:00Z",head:$head}]
  ' "$source" > "$posted"
  FM_TEST_NOW_EPOCH=999999 review checkpoint "$URL" --snapshot "$posted" >/dev/null
  FINAL_DISPOSITION_SNAPSHOT=$posted
}

GREEN='[{"name":"ci","state":"SUCCESS","bucket":"pass","status":"COMPLETED","conclusion":"pass","required":true,"url":"https://example.test/ci"}]'
RED_LINT='[{"name":"lint","state":"FAILURE","bucket":"fail","status":"FAILURE","conclusion":"fail","required":true,"url":"https://example.test/lint"}]'
RED_LINT_AND_UNIT='[{"name":"lint","state":"FAILURE","bucket":"fail","status":"FAILURE","conclusion":"fail","required":true,"url":"https://example.test/lint"},{"name":"unit","state":"FAILURE","bucket":"fail","status":"FAILURE","conclusion":"fail","required":true,"url":"https://example.test/unit"}]'
LOW_FILES='[{"filename":"tests/widget.test.sh","status":"modified","additions":10,"deletions":2}]'
COMMENTS='[
  {"kind":"top-level","id":"10","url":"https://example.test/top","author":"sourcery","body":"consider the edge case","updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  {"kind":"review-submission","id":"11","url":"https://example.test/review","author":"codex","body":"one finding","updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  {"kind":"inline-thread","id":"THREAD_12","url":"https://example.test/thread","author":"sentry","body":"inline finding","updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","resolved":false}
]'

test_pending_review_retries_and_every_review_surface_needs_disposition() {
  local initial pending settled withdrawn out status=0 path
  initial="$TMP_ROOT/initial.json"; pending="$TMP_ROOT/pending.json"; settled="$TMP_ROOT/settled.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1000 review init task-x "$URL" --snapshot "$initial" >/dev/null \
    || fail 'ledger initialization failed'

  snapshot "$pending" "$HEAD_A" '["check:codex"]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1600 FM_TEST_NOW_ISO=2026-09-20T00:10:00Z \
    review checkpoint "$URL" --snapshot "$pending" >/dev/null || fail 'pending checkpoint failed'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].next_checkpoint_epoch' "$path")" = 1900 ] \
    || fail 'first pending review did not schedule the configured bounded retry'
  FM_TEST_NOW_EPOCH=1899 review poll > "$TMP_ROOT/poll-before"
  [ ! -s "$TMP_ROOT/poll-before" ] || fail 'watcher checkpoint fired before its backoff elapsed'
  FM_TEST_NOW_EPOCH=1900 review poll > "$TMP_ROOT/poll-due"
  assert_contains "$(cat "$TMP_ROOT/poll-due")" "$URL" 'due checkpoint did not wake through the existing watcher check'
  review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'an explicitly pending review counted as approval'

  snapshot "$settled" "$HEAD_A" '[]' "$COMMENTS" "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1900 FM_TEST_NOW_ISO=2026-09-20T00:15:00Z \
    review checkpoint "$URL" --snapshot "$settled" >/dev/null || fail 'settled checkpoint failed'
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'top-level, submitted, and inline review findings passed without dispositions'
  withdrawn="$TMP_ROOT/withdrawn.json"
  snapshot "$withdrawn" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=1901 review checkpoint "$URL" --snapshot "$withdrawn" >/dev/null \
    || fail 'withdrawn-comment checkpoint failed'
  [ "$(jq '.generations[-1].review_items | length' "$path")" -eq 3 ] \
    || fail 'review comments disappeared from the durable ledger when no longer returned by GitHub'
  [ "$(jq '[.generations[-1].review_items[] | select(.present == false)] | length' "$path")" -eq 3 ] \
    || fail 'review comments no longer returned by GitHub were not marked absent'
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a deleted reviewer comment escaped disposition'
  review disposition "$URL" "$HEAD_A" top-level 10 rejected 'not applicable: linked reproduction disproves it' >/dev/null
  review disposition "$URL" "$HEAD_A" review-submission 11 addressed 'fixed by commit deadbeef' >/dev/null
  review disposition "$URL" "$HEAD_A" inline-thread THREAD_12 addressed 'fixed and thread resolved' >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-101" "$withdrawn"
  review ready "$URL" "$HEAD_A" >/dev/null || fail 'fully dispositioned review surfaces did not become ready'
  pass 'pending reviews retry, and top-level comments, submissions, and inline threads all require dispositions'
}

test_new_head_invalidates_old_checks_and_review_coverage() {
  local changed status=0 path
  changed="$TMP_ROOT/changed.json"
  snapshot "$changed" "$HEAD_B" '[]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=2000 FM_TEST_NOW_ISO=2026-09-20T00:20:00Z \
    review checkpoint "$URL" --snapshot "$changed" >/dev/null || fail 'new-head checkpoint failed'
  path=$(ledger)
  [ "$(jq '.generations | length' "$path")" -eq 2 ] || fail 'new head did not create a ledger generation'
  [ "$(jq '.generations[-1].review_items | length' "$path")" -eq 0 ] || fail 'prior review items leaked into the new generation'
  status=0; review ready "$URL" "$HEAD_B" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'green checks sampled before the new head review window satisfied the current head'
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a superseded head remained merge-ready'
  pass 'a new head invalidates prior checks and review coverage'
}

test_high_stakes_uses_configured_model_without_mandatory_independent_review() {
  local high_files initial checkpoint status=0 reason
  high_files='[{"filename":"bin/fm-teardown.sh","status":"modified","additions":5,"deletions":1}]'
  printf '%s\n' "$high_files" > "$TMP_ROOT/high-files.json"
  reason=$($RISK "$TMP_ROOT/high-files.json") || fail 'risk classifier failed'
  [ "$(printf '%s' "$reason" | jq -r .level)" = high ] || fail 'lifecycle surface was not high stakes'
  [ "$(jq -r '.high_stakes.no_mistakes_model' "$ROOT/.github/firstmate-review-policy.json")" = claude-opus-5-5 ] \
    || fail 'the fork review policy does not select Claude Opus 5.5'
  [ "$(jq -r '.high_stakes.independent_agent_reviews' "$ROOT/.github/firstmate-review-policy.json")" -eq 0 ] \
    || fail 'the fork review policy still requires an independent review'
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  initial="$TMP_ROOT/high-initial.json"; checkpoint="$TMP_ROOT/high-checkpoint.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' '[]' "$high_files"
  snapshot "$checkpoint" "$HEAD_A" '[]' '[]' '[]' "$high_files"
  FM_TEST_NOW_EPOCH=3000 review init task-high "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=3600 review checkpoint "$URL" --snapshot "$checkpoint" >/dev/null
  review attest "$URL" "$HEAD_A" no-mistakes claude-opus-5-4 'run old-model' >/dev/null
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'another model was silently substituted for Claude Opus 5.5'
  review attest "$URL" "$HEAD_A" no-mistakes claude-opus-5-5 'run configured-model' >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-102" "$checkpoint"
  review ready "$URL" "$HEAD_A" >/dev/null \
    || fail 'the configured high-stakes model did not satisfy the gate without an independent review'
  pass 'high-stakes readiness requires the configured model and no independent review when the policy count is zero'
}

test_risk_classifier_resolves_incomplete_evidence_high() {
  local result
  printf '%s\n' '[{"filename":"src/widget.sh","status":"modified","additions":2}]' \
    > "$TMP_ROOT/incomplete-risk.json"
  result=$($RISK "$TMP_ROOT/incomplete-risk.json") || fail 'risk classifier rejected incomplete evidence instead of classifying it'
  [ "$(printf '%s' "$result" | jq -r .level)" = high ] \
    || fail 'incomplete changed-surface evidence did not resolve to high stakes'
  assert_contains "$(printf '%s' "$result" | jq -r .reason)" uncertain \
    'incomplete changed-surface classification did not state its uncertainty'
  pass 'the risk classifier resolves incomplete changed-surface evidence to high stakes with a reason'
}

test_risk_classifier_treats_authentication_names_as_high() {
  local path result
  for path in src/authentication.ts src/authorization.go; do
    jq -n --arg path "$path" '[{filename:$path,status:"modified",additions:2,deletions:1}]' \
      > "$TMP_ROOT/auth-risk.json"
    result=$($RISK "$TMP_ROOT/auth-risk.json") || fail "risk classifier failed for $path"
    [ "$(printf '%s' "$result" | jq -r .level)" = high ] \
      || fail "authentication or authorization code was classified low: $path"
  done
  pass 'authentication and authorization filenames are high stakes'
}

test_risk_classifier_treats_migrate_directories_as_high() {
  local result
  jq -n '[{filename:"db/migrate/20260921_add_users.rb",status:"added",additions:8,deletions:0}]' \
    > "$TMP_ROOT/migrate-risk.json"
  result=$($RISK "$TMP_ROOT/migrate-risk.json") || fail 'risk classifier failed for db/migrate'
  [ "$(printf '%s' "$result" | jq -r .level)" = high ] \
    || fail 'a conventional db/migrate change was classified low'
  pass 'conventional migrate directories are high stakes'
}

test_risk_classifier_treats_public_api_and_infrastructure_as_high() {
  local path result
  for path in openapi.yaml api/public.ts k8s/deployment.yaml helm/service.yaml; do
    jq -n --arg path "$path" '[{filename:$path,status:"modified",additions:2,deletions:1}]' \
      > "$TMP_ROOT/public-infra-risk.json"
    result=$($RISK "$TMP_ROOT/public-infra-risk.json") || fail "risk classifier failed for $path"
    [ "$(printf '%s' "$result" | jq -r .level)" = high ] \
      || fail "a public API or conventional infrastructure surface was classified low: $path"
  done
  pass 'public API definitions and conventional production infrastructure paths are high stakes'
}

test_risk_classifier_treats_review_and_hold_guards_as_high() {
  local path result
  for path in \
    bin/fm-pr-review.sh \
    bin/fm-pr-merge.sh \
    bin/fm-pr-lib.sh \
    bin/fm-pr-review-snapshot.sh \
    bin/fm-pr-risk.sh \
    bin/fm-captain-hold.sh \
    .agents/skills/pr-review-policy/SKILL.md \
    .github/firstmate-review-policy.json
  do
    jq -n --arg path "$path" '[{filename:$path,status:"modified",additions:2,deletions:1}]' \
      > "$TMP_ROOT/review-guard-risk.json"
    result=$($RISK "$TMP_ROOT/review-guard-risk.json") || fail "risk classifier failed for $path"
    [ "$(printf '%s' "$result" | jq -r .level)" = high ] \
      || fail "a PR review or merge guard was classified low: $path"
  done
  pass 'PR review, merge, shared identity, captain-hold, snapshot, classifier, and policy surfaces are high stakes'
}

test_late_attestation_invalidates_final_disposition() {
  local high_files initial path status=0
  high_files='[{"filename":"bin/fm-teardown.sh","status":"modified","additions":2,"deletions":1}]'
  initial="$TMP_ROOT/late-attestation.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' '[]' "$high_files"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=3700 review init task-late-attestation "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=4300 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  review attest "$URL" "$HEAD_A" independent-agent-review codex 'review URL' >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-103" "$initial"
  review attest "$URL" "$HEAD_A" no-mistakes claude-opus-5-5 'run configured-model' >/dev/null
  path=$(ledger)
  [ "$(jq -r '.generations[-1].final_disposition' "$path")" = null ] \
    || fail 'a late high-stakes attestation left an earlier final disposition bound'
  review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'late attestation evidence made a stale final-disposition post merge-ready'
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-104" "$initial"
  review ready "$URL" "$HEAD_A" >/dev/null \
    || fail 'a fresh final disposition did not bind the complete attestation state'
  pass 'attestation changes invalidate and become part of the bound final disposition state'
}

test_merge_decision_records_only_the_live_reviewed_head() {
  local exact moved status=0 path
  exact="$TMP_ROOT/exact.json"; moved="$TMP_ROOT/moved.json"
  snapshot "$exact" "$HEAD_A" '[]' '[]' "$GREEN" '[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]'
  snapshot "$moved" "$HEAD_B" '[]' '[]' "$GREEN" '[{"filename":"tests/x.test.sh","status":"modified","additions":3,"deletions":0}]'
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=4000 review init task-merge "$URL" --snapshot "$exact" >/dev/null
  FM_TEST_NOW_EPOCH=4600 review checkpoint "$URL" --snapshot "$exact" >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-105" "$exact"
  FM_TEST_NOW_EPOCH=4601 review merge-decision "$URL" --snapshot "$FINAL_DISPOSITION_SNAPSHOT" >/dev/null \
    || fail 'exact-head merge decision was refused'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].merge_decision.reviewed_head' "$path")" = "$HEAD_A" ] \
    || fail 'merge decision did not record the reviewed head'
  [ "$(jq -r '.generations[-1].merge_decision.verified_head' "$path")" = "$HEAD_A" ] \
    || fail 'merge decision did not record the immediately verified head'

  status=0
  FM_TEST_NOW_EPOCH=4700 review merge-decision "$URL" --snapshot "$moved" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a moved head retained the prior merge decision'
  [ "$(jq -r '.generations[-1].merge_decision' "$path")" = null ] \
    || fail 'the moved-head generation retained a merge decision from the old head'
  pass 'merge decisions bind the immediately verified head to the reviewed ledger generation'
}

test_live_collector_includes_submitted_reviews_and_inline_threads() {
  local fakebin out kinds
  fakebin=$(fm_fakebin "$TMP_ROOT/snapshot-fake")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "${1:-} ${2:-}" in
  "api user")
    printf '%s\n' '{"login":"maintainer"}'
    ;;
  "api /repos/o/r/pulls/7")
    printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"user":{"login":"maintainer"},"requested_reviewers":[{"login":"codex"}],"requested_teams":[]}'
    ;;
  "api /repos/o/r/pulls/7/files?per_page=100")
    printf '%s\n' '[[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]]'
    ;;
  "api /repos/o/r/issues/7/comments?per_page=100")
    printf '%s\n' '[[{"id":10,"html_url":"https://example.test/top","user":{"login":"sourcery"},"body":"top","updated_at":"2026-09-20T00:10:00Z"},{"id":13,"html_url":"https://example.test/final","user":{"login":"maintainer"},"body":"final disposition evidence","updated_at":"2026-09-20T00:11:00Z"}]]'
    ;;
  "api /repos/o/r/pulls/7/reviews?per_page=100")
    printf '%s\n' '[[{"id":11,"html_url":"https://example.test/review","user":{"login":"codex"},"body":"submitted","state":"COMMENTED","submitted_at":"2026-09-20T00:10:00Z","commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]]'
    ;;
  "api graphql")
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"THREAD_12","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":12,"url":"https://example.test/thread","body":"inline","updatedAt":"2026-09-20T00:10:00Z","author":{"login":"sentry"},"commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"databaseId":13,"url":"https://example.test/final","body":"final disposition evidence","updatedAt":"2026-09-20T00:11:00Z","author":{"login":"maintainer"},"commit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}}]}}}}}'
    ;;
  "pr checks")
    printf '%s\n' '[{"name":"ci","state":"FAILURE","bucket":"fail","link":"https://example.test/ci"}]'
    exit 1
    ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","statusCheckRollup":[{"__typename":"CheckRun","name":"codex","status":"IN_PROGRESS","conclusion":null},{"__typename":"StatusContext","context":"sourcery","state":"SUCCESS"}]}'
        ;;
      *) printf '%s\n' "$head" ;;
    esac
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
  chmod +x "$fakebin/gh"
  out="$TMP_ROOT/live-snapshot.json"
  PATH="$fakebin:$PATH" "$SNAPSHOTTER" "$URL" "$out" || fail 'live collector fixture failed'
  kinds=$(jq -r '.comments[].kind' "$out" | LC_ALL=C sort)
  assert_contains "$kinds" 'top-level' 'top-level comment was absent from the live snapshot'
  assert_contains "$kinds" 'review-submission' 'submitted review was missed by the live collector'
  assert_contains "$kinds" 'inline-thread' 'inline review thread was missed by the live collector'
  [ "$(jq '[.comments[] | select((.author | contains("maintainer")) and (.body | contains("final disposition evidence")))] | length' "$out")" -eq 2 ] \
    || fail 'authenticated maintainer review feedback was removed from the snapshot'
  [ "$(jq '.pending_reviews | length' "$out")" -eq 2 ] \
    || fail 'requested reviewer and pending reviewer check were not both retained'
  [ "$(jq -r '.checks[0].conclusion' "$out")" = fail ] \
    || fail 'a nonzero checks verdict discarded the complete required-check result'
  pass 'live collection reads top-level comments, submitted reviews, inline threads, and pending reviewers'
}

test_bound_final_disposition_excludes_only_its_exact_post() {
  local initial posted path status=0
  initial="$TMP_ROOT/operator-review-initial.json"
  posted="$TMP_ROOT/operator-review-posted.json"
  snapshot "$initial" "$HEAD_A" '[]' '[{
    "kind":"top-level","id":"20","url":"https://example.test/maintainer-review",
    "author":"maintainer","body":"real operator review finding",
    "updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }]' "$GREEN" "$LOW_FILES"
  snapshot "$posted" "$HEAD_A" '[]' '[{
    "kind":"top-level","id":"20","url":"https://example.test/maintainer-review",
    "author":"maintainer","body":"real operator review finding",
    "updated_at":"2026-09-20T00:10:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },{
    "kind":"top-level","id":"21","url":"https://github.com/o/r/pull/7#issuecomment-21",
    "author":"maintainer","body":"final disposition evidence",
    "updated_at":"2026-09-20T00:11:00Z","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }]' "$GREEN" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=6000 review init task-operator "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=6600 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  review disposition "$URL" "$HEAD_A" top-level 20 addressed 'fixed by commit abc123' >/dev/null
  status=0
  review final-disposition "$URL" "$HEAD_A" "$URL#arbitrary" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'an arbitrary PR fragment was accepted as final-disposition evidence'
  review final-disposition "$URL" "$HEAD_A" "$URL#issuecomment-21" >/dev/null
  FM_TEST_NOW_EPOCH=6601 review merge-decision "$URL" --snapshot "$posted" >/dev/null \
    || fail 'the exact bound final-disposition post blocked the fresh merge snapshot'
  path=$(ledger)
  [ "$(jq '.generations[-1].review_items | length' "$path")" -eq 1 ] \
    || fail 'the final-disposition filter removed too much or retained its own exact post'
  [ "$(jq -r '.generations[-1].review_items[0].id' "$path")" = 20 ] \
    || fail 'the final-disposition filter removed genuine operator review feedback'
  [ "$(jq -r '.generations[-1].final_disposition.observed_in_latest_snapshot' "$path")" = true ] \
    || fail 'the fresh snapshot did not record observation of the bound final-disposition post'
  FM_TEST_NOW_EPOCH=6602 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a deleted final-disposition post remained merge-ready'
  pass 'only an observed exact ledger-bound final-disposition post is excluded from reviewer input'
}

test_live_collector_keeps_unreported_required_checks_pending() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/unreported-required-fake")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-} ${2:-}" in
  "api user")
    printf '%s\n' '{"login":"maintainer"}'
    ;;
  "api /repos/o/r/pulls/7")
    printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"user":{"login":"author"},"requested_reviewers":[],"requested_teams":[]}'
    ;;
  "api /repos/o/r/pulls/7/files?per_page=100")
    printf '%s\n' '[[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]]'
    ;;
  "api /repos/o/r/issues/7/comments?per_page=100"|"api /repos/o/r/pulls/7/reviews?per_page=100")
    printf '%s\n' '[[]]'
    ;;
  "api graphql")
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
    ;;
  "pr checks")
    printf "%s\n" "no required checks reported on the 'topic' branch" >&2
    exit 1
    ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","statusCheckRollup":[]}'
        ;;
      *) printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    esac
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
  chmod +x "$fakebin/gh"
  out="$TMP_ROOT/unreported-required.json"
  PATH="$fakebin:$PATH" "$SNAPSHOTTER" "$URL" "$out" \
    || fail 'live collector refused the known unreported-required-check state'
  [ "$(jq '[.checks[] | select(.status != "COMPLETED")] | length' "$out")" -eq 1 ] \
    || fail 'an unreported required check was normalized to an empty green check set'
  pass 'unreported required checks remain pending instead of satisfying readiness'
}

# A forge whose `gh pr checks --required` prints the one message gh uses both
# when the base requires no checks and when required checks have not reported
# yet; the base branch's protection summary and rules read are what tell the two
# apart. FM_TEST_BRANCH_JSON is the branch payload, FM_TEST_RULES_JSON the rules
# payload, or with FM_TEST_RULES_PLAN_GATED=1 the rules read fails with GitHub's
# plan-gated 403. FM_TEST_FILES_JSON overrides the changed-file page.
write_required_set_fake_gh() { # fakebin
  cat > "$1/gh" <<'SH'
#!/usr/bin/env bash
set -eu
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "${1:-} ${2:-}" in
  "api user")
    printf '%s\n' '{"login":"maintainer"}'
    ;;
  "api /repos/o/r/pulls/7")
    printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"base":{"ref":"main"},"user":{"login":"author"},"requested_reviewers":[],"requested_teams":[]}'
    ;;
  "api /repos/o/r/pulls/7/files?per_page=100")
    files='[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]'
    printf '[%s]\n' "${FM_TEST_FILES_JSON:-$files}"
    ;;
  "api /repos/o/r/issues/7/comments?per_page=100"|"api /repos/o/r/pulls/7/reviews?per_page=100")
    printf '%s\n' '[[]]'
    ;;
  "api repos/o/r/branches/main")
    cat "$FM_TEST_BRANCH_JSON"
    ;;
  "api --paginate")
    [ "${3:-}" = repos/o/r/rules/branches/main ] || { printf 'unexpected gh call: %s\n' "$*" >&2; exit 91; }
    if [ "${FM_TEST_RULES_PLAN_GATED:-0}" = 1 ]; then
      printf '%s\n' 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' >&2
      exit 1
    fi
    cat "$FM_TEST_RULES_JSON"
    ;;
  "api graphql")
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
    ;;
  "pr checks")
    printf "%s\n" "no required checks reported on the 'topic' branch" >&2
    exit 1
    ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","statusCheckRollup":[]}'
        ;;
      *) printf '%s\n' "$head" ;;
    esac
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
  chmod +x "$1/gh"
}

UNPROTECTED_BRANCH='{"name":"main","protected":false}'
VALIDATE_REQUIRED_BRANCH='{"name":"main","protected":true,"protection":{"enabled":true,"required_status_checks":{"enforcement_level":"non_admins","contexts":["validate"],"checks":[{"context":"validate","app_id":null}]}}}'

test_live_collector_reads_an_empty_required_set_as_no_required_checks() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/empty-required-set-fake")
  write_required_set_fake_gh "$fakebin"
  printf '%s\n' "$UNPROTECTED_BRANCH" > "$TMP_ROOT/unprotected-branch.json"
  printf '%s\n' "$VALIDATE_REQUIRED_BRANCH" > "$TMP_ROOT/validate-required-branch.json"

  # An unprotected base whose plan cannot expose branch rules requires nothing.
  out="$TMP_ROOT/empty-required-set.json"
  PATH="$fakebin:$PATH" FM_TEST_BRANCH_JSON="$TMP_ROOT/unprotected-branch.json" FM_TEST_RULES_PLAN_GATED=1 \
    "$SNAPSHOTTER" "$URL" "$out" || fail 'live collector refused a base branch that requires no checks'
  [ "$(jq -c '.checks' "$out")" = '[]' ] \
    || fail "a base branch that provably requires no checks gained a pending required check: $(jq -c '.checks' "$out")"

  # The same message over a base that does require a check is that check not
  # having reported yet, so it stays pending.
  out="$TMP_ROOT/validate-required-set.json"
  PATH="$fakebin:$PATH" FM_TEST_BRANCH_JSON="$TMP_ROOT/validate-required-branch.json" FM_TEST_RULES_PLAN_GATED=1 \
    "$SNAPSHOTTER" "$URL" "$out" || fail 'live collector refused a base branch with an unreported required check'
  [ "$(jq '[.checks[] | select(.status != "COMPLETED")] | length' "$out")" -eq 1 ] \
    || fail 'a required check that has not reported was dropped from the snapshot'

  # A ruleset requirement counts the same as classic protection.
  printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"}]}}]' \
    > "$TMP_ROOT/validate-required-rules.json"
  out="$TMP_ROOT/ruleset-required-set.json"
  PATH="$fakebin:$PATH" FM_TEST_BRANCH_JSON="$TMP_ROOT/unprotected-branch.json" \
    FM_TEST_RULES_JSON="$TMP_ROOT/validate-required-rules.json" \
    "$SNAPSHOTTER" "$URL" "$out" || fail 'live collector refused a ruleset-required check that has not reported'
  [ "$(jq '[.checks[] | select(.status != "COMPLETED")] | length' "$out")" -eq 1 ] \
    || fail 'a ruleset-required check that has not reported was dropped from the snapshot'
  pass 'the collector records no required checks only when the base branch provably requires none'
}

# The shape of a fully ready high-stakes pull request on a base with no branch
# protection and plan-gated rules: every review gate passes on the live
# snapshot, and only an unreadable required set keeps it from merging.
test_ready_passes_a_complete_review_on_a_base_that_requires_no_checks() {
  local fakebin live unreadable err status=0
  fakebin=$(fm_fakebin "$TMP_ROOT/no-required-ready-fake")
  write_required_set_fake_gh "$fakebin"
  printf '%s\n' "$UNPROTECTED_BRANCH" > "$TMP_ROOT/no-required-ready-branch.json"
  live="$TMP_ROOT/no-required-ready.json"
  unreadable="$TMP_ROOT/no-required-unreadable.json"
  err="$TMP_ROOT/no-required-ready.err"
  PATH="$fakebin:$PATH" FM_TEST_FILES_JSON='[{"filename":"bin/fm-teardown.sh","status":"modified","additions":5,"deletions":1}]' \
    FM_TEST_BRANCH_JSON="$TMP_ROOT/no-required-ready-branch.json" FM_TEST_RULES_PLAN_GATED=1 \
    "$SNAPSHOTTER" "$URL" "$live" || fail 'live collector refused the ready fixture'
  PATH="$fakebin:$PATH" FM_TEST_FILES_JSON='[{"filename":"bin/fm-teardown.sh","status":"modified","additions":5,"deletions":1}]' \
    FM_TEST_BRANCH_JSON="$TMP_ROOT/absent-branch.json" FM_TEST_RULES_PLAN_GATED=1 \
    "$SNAPSHOTTER" "$URL" "$unreadable" || fail 'live collector refused an unreadable required set'

  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=8000 review init task-ready "$URL" --snapshot "$live" >/dev/null
  FM_TEST_NOW_EPOCH=8600 review checkpoint "$URL" --snapshot "$live" >/dev/null
  [ "$(jq -r '.generations[-1].risk.level' "$(ledger)")" = high ] || fail 'the ready fixture was not high stakes'
  review attest "$URL" "$HEAD_A" no-mistakes claude-opus-5-5 'run configured-model' >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-218" "$live"
  review ready "$URL" "$HEAD_A" >/dev/null 2>"$err" \
    || fail "a complete review on a base that requires no checks was not ready: $(cat "$err")"

  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=8000 review init task-ready "$URL" --snapshot "$unreadable" >/dev/null
  FM_TEST_NOW_EPOCH=8600 review checkpoint "$URL" --snapshot "$unreadable" >/dev/null
  review attest "$URL" "$HEAD_A" no-mistakes claude-opus-5-5 'run configured-model' >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-219" "$unreadable"
  review ready "$URL" "$HEAD_A" >/dev/null 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'an unreadable required set let the review pass as ready'
  assert_grep 'a required check is not green on this head' "$err" \
    'the unreadable required set did not block readiness as a pending required check'
  pass 'a complete review is ready on a base that requires no checks, and an unreadable required set still blocks it'
}

test_imported_ledgers_keep_holds_and_null_dispositions_blocking() {
  local fixtures="$ROOT/tests/fixtures/pr-review-ledger" snap path err status
  snap="$TMP_ROOT/imported-ledger.json"; err="$TMP_ROOT/imported-ledger.err"
  snapshot "$snap" "$HEAD_A" '[]' "$(jq -c '[.[0]]' <<<"$COMMENTS")" "$GREEN" "$LOW_FILES"
  path=$(ledger)

  rm -rf "$HOME_DIR/data/pr-review-ledger"; mkdir -p "$HOME_DIR/data/pr-review-ledger"
  cp "$fixtures/held.json" "$path"
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'an imported hold did not block readiness'
  grep -Fq 'pull request is held: synthetic hold awaiting a captain decision' "$err" \
    || fail 'readiness did not name the imported hold reason'
  status=0; FM_TEST_NOW_EPOCH=2000 review merge-decision "$URL" --snapshot "$snap" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'merge-decision recorded a merge over an imported hold'
  [ "$(jq -r '.generations[-1].merge_decision | "\(.decision)|\(.reason)"' "$path")" = 'hold|synthetic hold awaiting a captain decision' ] \
    || fail 'merge-decision replaced the imported hold'

  rm -rf "$HOME_DIR/data/pr-review-ledger"; mkdir -p "$HOME_DIR/data/pr-review-ledger"
  cp "$fixtures/undispositioned.json" "$path"
  status=0; review ready "$URL" "$HEAD_A" >/dev/null 2>"$err" || status=$?
  [ "$status" -ne 0 ] || fail 'an imported null disposition did not block readiness'
  grep -Fq 'lacks a disposition with evidence' "$err" \
    || fail 'readiness did not name the undispositioned imported finding'
  ! grep -Fq 'pull request is held' "$err" || fail 'an unheld imported ledger was reported as held'
  status=0; FM_TEST_NOW_EPOCH=2000 review merge-decision "$URL" --snapshot "$snap" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'merge-decision recorded a merge over an undispositioned imported finding'
  [ "$(jq -r '.generations[-1].merge_decision' "$path")" = null ] \
    || fail 'merge-decision recorded a decision over an undispositioned imported finding'
  [ "$(jq -r '.generations[-1].review_items[] | select(.id == "10") | .disposition' "$path")" = null ] \
    || fail 'an imported null disposition was defaulted'
  pass 'imported ledgers keep holds and null dispositions blocking ready and merge-decision'
}

test_human_hold_survives_head_change_until_evidenced_release() {
  local first changed path status=0
  first="$TMP_ROOT/hold-first.json"; changed="$TMP_ROOT/hold-changed.json"
  snapshot "$first" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  snapshot "$changed" "$HEAD_B" '[]' '[]' "$GREEN" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=5000 review init task-hold "$URL" --snapshot "$first" >/dev/null
  review hold "$URL" "$HEAD_A" 'unresolved rights decision' >/dev/null
  FM_TEST_NOW_EPOCH=5100 review checkpoint "$URL" --snapshot "$changed" >/dev/null
  path=$(ledger)
  [ "$(jq -r '.generations[-1].merge_decision.decision' "$path")" = hold ] \
    || fail 'a human hold disappeared when the head changed'
  status=0; review ready "$URL" "$HEAD_B" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a current human hold did not block readiness'
  review release-hold "$URL" "$HEAD_B" 'https://example.test/rights-decision' >/dev/null
  [ "$(jq -r '.generations[-1].merge_decision' "$path")" = null ] \
    || fail 'an evidenced hold release did not clear the current hold'
  pass 'human holds survive head changes and require an evidenced release'
}

test_merge_forwards_guarded_options_to_the_merge_parser() {
  local fakebin initial rc=0
  fakebin=$(fm_fakebin "$TMP_ROOT/merge-forward-fake")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
case "${1:-} ${2:-}" in
  "api user")
    printf '%s\n' '{"login":"maintainer"}'
    ;;
  "api /repos/o/r/pulls/7")
    printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"user":{"login":"author"},"requested_reviewers":[],"requested_teams":[]}'
    ;;
  "api /repos/o/r/pulls/7/files?per_page=100")
    printf '%s\n' '[[{"filename":"tests/x.test.sh","status":"modified","additions":2,"deletions":0}]]'
    ;;
  "api /repos/o/r/issues/7/comments?per_page=100")
    printf '[[{"id":106,"html_url":"%s","user":{"login":"maintainer"},"body":"final disposition evidence","updated_at":"2026-09-20T00:30:00Z"}]]\n' "$FM_TEST_FINAL_URL"
    ;;
  "api /repos/o/r/pulls/7/reviews?per_page=100")
    printf '%s\n' '[[]]'
    ;;
  "api graphql")
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
    ;;
  "pr checks")
    if [ "${FM_TEST_EXTRA_RED:-false}" = true ]; then
      printf '%s\n' '[{"name":"lint","state":"FAILURE","bucket":"fail","link":"https://example.test/lint"},{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://example.test/unit"}]'
    else
      printf '%s\n' '[{"name":"lint","state":"FAILURE","bucket":"fail","link":"https://example.test/lint"}]'
    fi
    exit 1
    ;;
  "pr view")
    case "$*" in
      *statusCheckRollup*)
        printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","statusCheckRollup":[]}'
        ;;
      *) printf '%s\n' "$head" ;;
    esac
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
  chmod +x "$fakebin/gh"

  initial="$TMP_ROOT/merge-forward-initial.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' "$RED_LINT" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=7000 review init task-forward "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=7600 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-106" "$initial"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_FINAL_URL="$URL#issuecomment-106" FM_TEST_NOW_EPOCH=7601 \
    review merge task-forward "$URL" --allow-red lint --attended-override=bad \
      > "$TMP_ROOT/merge-forward.stdout" 2> "$TMP_ROOT/merge-forward.stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" 'merge forwarding: guarded option parser should reject the invalid value'
  assert_grep 'error: --attended-override takes no value' "$TMP_ROOT/merge-forward.stderr" \
    'merge forwarding: the wrapper blocked or hid guarded options before the merge parser'
  [ "$(jq -r '.generations[-1].merge_decision.allowed_red_check' "$(ledger)")" = lint ] \
    || fail 'merge forwarding: the ledger did not record the exact waived check'

  initial="$TMP_ROOT/merge-forward-two-red.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' "$RED_LINT_AND_UNIT" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=7000 review init task-forward "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=7600 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-107" "$initial"
  rc=0
  set +e
  PATH="$fakebin:$PATH" FM_TEST_FINAL_URL="$URL#issuecomment-107" \
    FM_TEST_EXTRA_RED=true FM_TEST_NOW_EPOCH=7601 \
    review merge task-forward "$URL" --allow-red lint --attended-override=bad \
      > "$TMP_ROOT/merge-forward-two-red.stdout" 2> "$TMP_ROOT/merge-forward-two-red.stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" 'merge forwarding: an unwaived red check must block before the merge parser'
  assert_grep 'review gate: a required check is not green on this head' \
    "$TMP_ROOT/merge-forward-two-red.stderr" \
    'merge forwarding: naming one red check also waived another red check'
  pass 'the review wrapper applies one named red-check waiver and forwards guarded options'
}

test_merge_rejects_a_task_that_does_not_own_the_ledger() {
  local initial path status=0
  initial="$TMP_ROOT/task-binding.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=7000 review init task-owner "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=7600 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-108" "$initial"
  set +e
  review merge task-other "$URL" > "$TMP_ROOT/task-binding.stdout" \
    2> "$TMP_ROOT/task-binding.stderr"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'a task that does not own the review ledger reached the merge path'
  assert_grep 'merge task does not match the review ledger task' "$TMP_ROOT/task-binding.stderr" \
    'the task-binding refusal did not identify the ledger mismatch'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].merge_decision' "$path")" = null ] \
    || fail 'a mismatched task recorded a merge decision in another task ledger'
  pass 'the merge wrapper binds its task id to the task recorded in the review ledger'
}

test_arm_reuses_the_authenticated_watcher_check() {
  review arm > "$TMP_ROOT/arm.out" || fail 'review checkpoint check did not arm'
  assert_present "$HOME_DIR/state/review-policy.check.sh" \
    'arming did not publish the watcher check shim'
  assert_present "$HOME_DIR/state/review-policy.check-trust" \
    'arming did not register the watcher check through the trust facility'
  [ "$(stat -c '%a' "$HOME_DIR/state/review-policy.check.sh" 2>/dev/null \
      || stat -f '%Lp' "$HOME_DIR/state/review-policy.check.sh")" = 700 ] \
    || fail 'review checkpoint check did not use the required private executable mode'
  FM_HOME="$HOME_DIR" FM_REVIEW_NOW_EPOCH=7601 \
    "$HOME_DIR/state/review-policy.check.sh" > "$TMP_ROOT/armed-poll.out" \
    || fail 'the registered review checkpoint check was not executable'
  review disarm >/dev/null || fail 'review checkpoint check did not disarm'
  assert_absent "$HOME_DIR/state/review-policy.check.sh" \
    'disarming left the watcher check shim behind'
  assert_absent "$HOME_DIR/state/review-policy.check-trust" \
    'disarming left the watcher trust binding behind'
  pass 'review checkpoints reuse the authenticated watcher check without another monitor'
}

prepare_post_merge_ledger() {
  local initial="$TMP_ROOT/post-merge-initial.json"
  snapshot "$initial" "$HEAD_A" '[]' '[]' "$GREEN" "$LOW_FILES"
  rm -rf "$HOME_DIR/data/pr-review-ledger"
  FM_TEST_NOW_EPOCH=8000 review init task-post-merge "$URL" --snapshot "$initial" >/dev/null
  FM_TEST_NOW_EPOCH=8600 review checkpoint "$URL" --snapshot "$initial" >/dev/null
  bind_final_disposition "$HEAD_A" "$URL#issuecomment-109" "$initial"
  FM_TEST_NOW_EPOCH=8601 review merge-decision "$URL" --snapshot "$FINAL_DISPOSITION_SNAPSHOT" >/dev/null \
    || fail 'post-merge fixture could not record its merge decision'
}

browser_evidence() { # path outcome running-sha bug-json
  jq -n --arg head "$HEAD_A" --arg running_sha "$3" --arg outcome "$2" \
    --arg merged_sha "$MERGED_SHA" --arg posted "$URL#issuecomment-100" --argjson bug "$4" '{
      schema:"firstmate-post-merge-verification.v1",
      applicability:"browser",head:$head,outcome:$outcome,
      merged_sha:$merged_sha,running_sha:$running_sha,running_url:"https://app.example.test/",
      browser:{mode:"local",profile_scope:"task-post-merge",fresh_profile:true,personal_cookies_imported:false,
        paid_browser_use:false,jev_cloud:false},
      destructive_production_actions:false,
      journeys:[{name:"sign in and open dashboard",result:(if $outcome == "passed" then "passed" else "failed" end),
        evidence:"https://evidence.example.test/journey"}],
      data_checks:[{name:"persisted dashboard row",result:"passed",
        evidence:"https://evidence.example.test/data"}],
      api_checks:[{name:"dashboard API payload",result:"passed",
        evidence:"https://evidence.example.test/api"}],
      console_errors:(if $outcome == "passed" then [] else ["Uncaught dashboard error"] end),
      network_errors:(if $outcome == "passed" then [] else ["GET /api/dashboard 500"] end),
      desktop:{checked:true,evidence:"https://evidence.example.test/desktop"},
      mobile:{relevant:true,checked:true,reason:"",evidence:"https://evidence.example.test/mobile"},
      screenshot_url:"https://evidence.example.test/screenshot.png",
      posted_evidence_url:$posted,
      bug:$bug
    }' > "$1"
}

test_post_merge_non_browser_records_not_applicable() {
  local changed evidence path status=0
  prepare_post_merge_ledger
  evidence="$TMP_ROOT/post-merge-na.json"
  jq -n --arg head "$HEAD_A" '{
    schema:"firstmate-post-merge-verification.v1",applicability:"not-applicable",
    head:$head,reason:"shell-only ledger maintenance with no browser-facing behavior"
  }' > "$evidence"
  post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null \
    || fail 'non-browser post-merge verification did not record its N/A reason'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].post_merge_verifications[-1].applicability' "$path")" = not-applicable ] \
    || fail 'non-browser post-merge record was not retained on the current head'
  [ -n "$(jq -r '.generations[-1].post_merge_verifications[-1].reason' "$path")" ] \
    || fail 'non-browser post-merge record lost its reason'
  review ready-for-qa "$URL" "$HEAD_A" >/dev/null \
    || fail 'an evidenced non-browser N/A record did not satisfy the Ready for QA gate'
  changed="$TMP_ROOT/post-merge-new-head.json"
  snapshot "$changed" "$HEAD_B" '[]' '[]' "$GREEN" "$LOW_FILES"
  FM_TEST_NOW_EPOCH=9000 review checkpoint "$URL" --snapshot "$changed" >/dev/null
  [ "$(jq '.generations[-1].post_merge_verifications | length' "$path")" -eq 0 ] \
    || fail 'a new head inherited the old head post-merge verification'
  status=0; review ready-for-qa "$URL" "$HEAD_B" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a new head reused the old head Ready for QA decision'
  pass 'non-browser changes record a head-keyed N/A reason that a new head invalidates'
}

test_post_merge_requires_confirmed_forge_merge() {
  local evidence status=0
  prepare_post_merge_ledger
  evidence="$TMP_ROOT/post-merge-unmerged.json"
  jq -n --arg head "$HEAD_A" '{
    schema:"firstmate-post-merge-verification.v1",applicability:"not-applicable",
    head:$head,reason:"shell-only ledger maintenance with no browser-facing behavior"
  }' > "$evidence"
  FM_TEST_PR_MERGED=false post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" \
    > /dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] \
    || fail 'a recorded merge intent allowed post-merge verification before the forge confirmed landing'
  status=0
  FM_TEST_PR_HEAD="$HEAD_B" post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" \
    > /dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] \
    || fail 'a merge of an unreviewed replacement head satisfied the reviewed generation'
  pass 'post-merge verification requires a forge merge of the reviewed source head'
}

test_post_merge_rejects_multiple_json_documents() {
  local evidence path status=0
  prepare_post_merge_ledger
  evidence="$TMP_ROOT/post-merge-multiple.json"
  printf '%s\n' \
    '{"schema":"firstmate-post-merge-verification.v1","applicability":"not-applicable","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reason":""}' \
    '{"schema":"firstmate-post-merge-verification.v1","applicability":"not-applicable","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reason":"valid second document"}' \
    > "$evidence"
  post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'multiple JSON evidence documents were accepted'
  path=$(ledger)
  [ "$(jq '.generations[-1].post_merge_verifications | length' "$path")" -eq 0 ] \
    || fail 'post-merge recorded a different evidence document than the one it validated'
  pass 'post-merge validation and recording use one exact JSON document'
}

test_post_merge_validates_the_immutable_staged_evidence() {
  local evidence replacement fakebin marker real_jq path status=0
  prepare_post_merge_ledger
  evidence="$TMP_ROOT/post-merge-swap-source.json"
  replacement="$TMP_ROOT/post-merge-swap-replacement.json"
  marker="$TMP_ROOT/post-merge-swap.marker"
  real_jq=$(command -v jq) || fail 'post-merge evidence swap test requires jq'
  jq -n --arg head "$HEAD_A" '{
    schema:"firstmate-post-merge-verification.v1",applicability:"not-applicable",
    head:$head,reason:""
  }' > "$evidence"
  jq -n --arg head "$HEAD_A" '{
    schema:"firstmate-post-merge-verification.v1",applicability:"not-applicable",
    head:$head,reason:"valid replacement that must not be substituted after staging"
  }' > "$replacement"
  fakebin=$(fm_fakebin "$TMP_ROOT/post-merge-swap-fake")
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -cse ] && [ ! -e "$FM_TEST_JQ_SWAP_MARKER" ]; then
  "$FM_TEST_REAL_JQ" "$@"
  cp "$FM_TEST_EVIDENCE_REPLACEMENT" "$FM_TEST_EVIDENCE_SOURCE"
  : > "$FM_TEST_JQ_SWAP_MARKER"
  exit 0
fi
exec "$FM_TEST_REAL_JQ" "$@"
SH
  chmod +x "$fakebin/jq"

  PATH="$fakebin:$POST_MERGE_FAKEBIN:$PATH" \
    FM_TEST_REAL_JQ="$real_jq" FM_TEST_EVIDENCE_SOURCE="$evidence" \
    FM_TEST_EVIDENCE_REPLACEMENT="$replacement" FM_TEST_JQ_SWAP_MARKER="$marker" \
    review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'post-merge accepted a source replacement after staging'
  path=$(ledger)
  [ "$(jq '.generations[-1].post_merge_verifications | length' "$path")" -eq 0 ] \
    || fail 'post-merge recorded evidence other than the immutable object it validated'
  pass 'post-merge validates and records the same immutable staged evidence object'
}

test_post_merge_browser_pass_requires_full_local_evidence() {
  local evidence linear_evidence path
  prepare_post_merge_ledger
  evidence="$TMP_ROOT/post-merge-pass.json"
  browser_evidence "$evidence" passed "$MERGED_SHA" null
  post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null \
    || fail 'complete local-browser post-merge evidence was refused'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].post_merge_verifications[-1].running_sha' "$path")" = "$MERGED_SHA" ] \
    || fail 'post-merge record did not retain the running merged SHA'
  [ "$(jq -r '.generations[-1].post_merge_verifications[-1].forge_merge_sha' "$path")" = "$MERGED_SHA" ] \
    || fail 'post-merge record did not retain the forge-confirmed merge SHA separately'
  [ "$(jq -r '.generations[-1].post_merge_verifications[-1].ready_for_qa' "$path")" = allowed ] \
    || fail 'a complete passing smoke did not record an allowed Ready for QA decision'
  review ready-for-qa "$URL" "$HEAD_A" >/dev/null \
    || fail 'complete passing browser evidence did not satisfy the Ready for QA gate'
  linear_evidence="$TMP_ROOT/post-merge-pass-linear.json"
  jq '.posted_evidence_url="https://linear.app/example/issue/TES-79"' "$evidence" > "$linear_evidence"
  post_merge_review post-merge "$URL" "$HEAD_A" "$linear_evidence" >/dev/null \
    || fail 'a concrete Linear issue evidence URL was refused'
  pass 'browser changes require journeys, data and API checks, clean errors, viewport coverage, and posted screenshot evidence'
}

test_post_merge_rejects_superficial_or_unsafe_browser_evidence() {
  local evidence mutation status
  prepare_post_merge_ledger
  evidence="$TMP_ROOT/post-merge-superficial.json"
  jq -n --arg head "$HEAD_A" '{
    schema:"firstmate-post-merge-verification.v1",applicability:"browser",head:$head,
    outcome:"passed",http_status:200,worker_done:true
  }' > "$evidence"
  status=0; post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'HTTP 200 and a worker done marker counted as a post-merge QA pass'

  browser_evidence "$evidence" passed "$MERGED_SHA" null
  for mutation in remote-browser reused-profile wrong-scope personal-cookies destructive-action paid-browser jev-cloud missing-data missing-api unchecked-mobile stale-sha wrong-merge-sha root-linear arbitrary-pr-fragment bare-files; do
    case "$mutation" in
      remote-browser) jq '.browser.mode="remote"' "$evidence" > "$evidence.tmp" ;;
      reused-profile) jq '.browser.fresh_profile=false' "$evidence" > "$evidence.tmp" ;;
      wrong-scope) jq '.browser.profile_scope="another-task"' "$evidence" > "$evidence.tmp" ;;
      personal-cookies) jq '.browser.personal_cookies_imported=true' "$evidence" > "$evidence.tmp" ;;
      destructive-action) jq '.destructive_production_actions=true' "$evidence" > "$evidence.tmp" ;;
      paid-browser) jq '.browser.paid_browser_use=true' "$evidence" > "$evidence.tmp" ;;
      jev-cloud) jq '.browser.jev_cloud=true' "$evidence" > "$evidence.tmp" ;;
      missing-data) jq '.data_checks=[]' "$evidence" > "$evidence.tmp" ;;
      missing-api) jq '.api_checks=[]' "$evidence" > "$evidence.tmp" ;;
      unchecked-mobile) jq '.mobile.checked=false' "$evidence" > "$evidence.tmp" ;;
      stale-sha) jq --arg stale "$HEAD_B" '.running_sha=$stale' "$evidence" > "$evidence.tmp" ;;
      wrong-merge-sha) jq --arg stale "$HEAD_B" '.merged_sha=$stale' "$evidence" > "$evidence.tmp" ;;
      root-linear) jq '.posted_evidence_url="https://linear.app/"' "$evidence" > "$evidence.tmp" ;;
      arbitrary-pr-fragment) jq --arg url "$URL" '.posted_evidence_url=($url + "#arbitrary")' "$evidence" > "$evidence.tmp" ;;
      bare-files) jq --arg url "$URL" '.posted_evidence_url=($url + "/files")' "$evidence" > "$evidence.tmp" ;;
    esac
    status=0; post_merge_review post-merge "$URL" "$HEAD_A" "$evidence.tmp" >/dev/null 2>&1 || status=$?
    [ "$status" -ne 0 ] || fail "unsafe or incomplete post-merge evidence was accepted: $mutation"
  done
  pass 'post-merge QA rejects superficial evidence, unsafe production actions, remote profiles, personal cookies, and paid cloud claims'
}

test_failed_post_merge_smoke_requires_bug_and_blocks_ready_for_qa() {
  local evidence na_evidence path status=0
  prepare_post_merge_ledger
  evidence="$TMP_ROOT/post-merge-failed.json"
  browser_evidence "$evidence" failed "$HEAD_B" null
  status=0; post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a failed post-merge smoke recorded without creating or reopening its owning bug'

  browser_evidence "$evidence" failed "$HEAD_B" \
    '{"url":"https://linear.app/","action":"created"}'
  status=0; post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'the Linear root was accepted as an owning bug URL'
  browser_evidence "$evidence" failed "$HEAD_B" \
    '{"url":"https://linear.app/example/team/not-an-issue","action":"reopened"}'
  status=0; post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'an unrelated Linear path was accepted as an owning bug URL'

  browser_evidence "$evidence" failed "$HEAD_B" \
    '{"url":"https://linear.app/example/issue/BUG-1","action":"created"}'
  post_merge_review post-merge "$URL" "$HEAD_A" "$evidence" >/dev/null \
    || fail 'failed post-merge evidence with an owning bug was not recorded'
  path=$(ledger)
  [ "$(jq -r '.generations[-1].post_merge_verifications[-1].ready_for_qa' "$path")" = blocked ] \
    || fail 'a failed smoke did not record the Ready for QA block'
  status=0; review ready-for-qa "$URL" "$HEAD_A" > "$TMP_ROOT/ready-failed.out" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'a failed post-merge smoke allowed the Ready for QA label'
  assert_grep 'https://linear.app/example/issue/BUG-1' "$TMP_ROOT/ready-failed.out" \
    'the Ready for QA refusal did not name the owning bug'
  na_evidence="$TMP_ROOT/post-merge-na-after-failure.json"
  jq -n --arg head "$HEAD_A" '{
    schema:"firstmate-post-merge-verification.v1",applicability:"not-applicable",
    head:$head,reason:"reclassified after the browser smoke failed"
  }' > "$na_evidence"
  status=0
  post_merge_review post-merge "$URL" "$HEAD_A" "$na_evidence" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] \
    || fail 'a not-applicable record cleared a failed browser smoke on the same head'
  pass 'a failed post-merge smoke requires an owning bug and blocks Ready for QA'
}

test_pending_review_retries_and_every_review_surface_needs_disposition
test_new_head_invalidates_old_checks_and_review_coverage
test_high_stakes_uses_configured_model_without_mandatory_independent_review
test_risk_classifier_resolves_incomplete_evidence_high
test_risk_classifier_treats_authentication_names_as_high
test_risk_classifier_treats_migrate_directories_as_high
test_risk_classifier_treats_public_api_and_infrastructure_as_high
test_risk_classifier_treats_review_and_hold_guards_as_high
test_late_attestation_invalidates_final_disposition
test_merge_decision_records_only_the_live_reviewed_head
test_live_collector_includes_submitted_reviews_and_inline_threads
test_bound_final_disposition_excludes_only_its_exact_post
test_live_collector_keeps_unreported_required_checks_pending
test_live_collector_reads_an_empty_required_set_as_no_required_checks
test_ready_passes_a_complete_review_on_a_base_that_requires_no_checks
test_imported_ledgers_keep_holds_and_null_dispositions_blocking
test_human_hold_survives_head_change_until_evidenced_release
test_merge_forwards_guarded_options_to_the_merge_parser
test_merge_rejects_a_task_that_does_not_own_the_ledger
test_arm_reuses_the_authenticated_watcher_check
test_post_merge_non_browser_records_not_applicable
test_post_merge_requires_confirmed_forge_merge
test_post_merge_rejects_multiple_json_documents
test_post_merge_validates_the_immutable_staged_evidence
test_post_merge_browser_pass_requires_full_local_evidence
test_post_merge_rejects_superficial_or_unsafe_browser_evidence
test_failed_post_merge_smoke_requires_bug_and_blocks_ready_for_qa
