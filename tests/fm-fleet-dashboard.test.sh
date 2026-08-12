#!/usr/bin/env bash
# Behavior tests for the fleet cockpit: decisions ranked by importance, our
# PRs in review with gh-derived status, and the reviews domain's PR relationships.
set -u

# The managed sandbox denies the host ps call used by tests/lib.sh to identify
# its owner. Keep that safety check deterministic without weakening production.
TEST_BOOTSTRAP_BIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-dashboard-ps.XXXXXX")
cat > "$TEST_BOOTSTRAP_BIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=unknown
previous=""
for argument in "$@"; do
  if [ "$previous" = "-p" ]; then pid=$argument; fi
  previous=$argument
done
printf 'Mon Jan  1 00:00:00 2024 fm-test-process-%s\n' "$pid"
SH
chmod +x "$TEST_BOOTSTRAP_BIN/ps"
export PATH="$TEST_BOOTSTRAP_BIN:$PATH"

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
FM_TEST_CLEANUP_DIRS+=("$TEST_BOOTSTRAP_BIN")

DASHBOARD="$ROOT/bin/fm-fleet-dashboard.mjs"
TMP_ROOT=$(fm_test_tmproot fm-fleet-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TRUNCATION_ARTIFACT="(truncated, 90 chars total - use show decision-task --full to see complete text)"
OUR_PR="https://github.com/monalee/artemis/pull/4001"
FIRSTMATE_PR="https://github.com/pedromuller-del/firstmate/pull/4004"
MERGED_PR="https://github.com/pedromuller-del/firstmate/pull/3972"
THEIR_PR="https://github.com/monalee/artemis/pull/912"
MERGED_THEIR_PR="https://github.com/monalee/artemis/pull/999"

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

make_fakebin() {  # <home>
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    printf '%s\n' fm-decision-task fm-review-task fm-stuck-pr fm-mm-alpha fm-zz-zulu
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    printf 'all quiet\n> \n'
    ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "search" ]; then
  if [ -f "$FM_HOME/review-history-fixture" ]; then
    printf '[{"author":{"login":"colleague"},"createdAt":"2026-07-29T00:00:00Z","number":940,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Re-review the address refresh","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/940"},{"author":{"login":"colleague-two"},"createdAt":"2026-07-30T00:00:00Z","number":941,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Review the audit export","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/941"}]'
    exit 0
  fi
  printf '[{"author":{"login":"colleague"},"createdAt":"2026-07-20T00:00:00Z","number":930,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Tile cache manual validation required and outstanding","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/930"},{"author":{"login":"colleague-two"},"createdAt":"2026-07-31T00:00:00Z","number":912,"repository":{"name":"artemis","nameWithOwner":"monalee/artemis"},"title":"Payment refactor","updatedAt":"2026-08-02T00:00:00Z","url":"https://github.com/monalee/artemis/pull/912"}]'
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  case " $* " in
    *" user "*)
      printf 'pedromuller-del\n'
      ;;
    *" repos/monalee/artemis/issues/930/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-07-20T00:00:00Z","requested_team":{"name":"webdev","slug":"webdev"}}]'
      ;;
    *" repos/monalee/artemis/issues/912/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-07-31T00:00:00Z","requested_reviewer":{"login":"pedromuller-del"}}]'
      ;;
    *" repos/monalee/artemis/issues/940/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-07-29T00:00:00Z","requested_reviewer":{"login":"pedromuller-del"}}]'
      ;;
    *" repos/monalee/artemis/issues/941/timeline "*)
      printf '[{"event":"review_requested","created_at":"2026-07-30T00:00:00Z","requested_reviewer":{"login":"pedromuller-del"}}]'
      ;;
    *" repos/monalee/artemis/pulls/930/requested_reviewers "*)
      printf '{"users":[],"teams":[{"name":"webdev","slug":"webdev"}]}'
      ;;
    *" repos/monalee/artemis/pulls/912/requested_reviewers "*)
      printf '{"users":[{"login":"pedromuller-del"}],"teams":[]}'
      ;;
    *" repos/monalee/artemis/pulls/940/requested_reviewers "*|*" repos/monalee/artemis/pulls/941/requested_reviewers "*)
      printf '{"users":[{"login":"pedromuller-del"}],"teams":[]}'
      ;;
    *)
      printf '[]'
      ;;
  esac
  exit 0
fi
url=${3:-}
case "$url" in
  *pull/4001*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[{"author":{"login":"reviewer-one"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-01T01:00:00Z"},{"author":{"login":"reviewer-two"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-01T02:00:00Z"},{"author":{"login":"reviewer-one"},"state":"APPROVED","submittedAt":"2026-08-01T03:00:00Z"}],"reviewRequests":[]}'
    ;;
  *pull/4004*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}],"reviews":[],"reviewRequests":[{"login":"local-reviewer"}]}'
    ;;
  *pull/930*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[{"login":"pedromuller-del"}],"headRefOid":"d4d4d4d"}'
    ;;
  *pull/912*|*pull/4188*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[],"headRefOid":"b2b2b2b"}'
    ;;
  *pull/940*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[{"author":{"login":"pedromuller-del"},"state":"CHANGES_REQUESTED","submittedAt":"2026-07-28T00:00:00Z","commit":{"oid":"aaa111"}}],"reviewRequests":[{"login":"pedromuller-del"}],"headRefOid":"bbb222"}'
    ;;
  *pull/941*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"reviews":[],"reviewRequests":[{"login":"pedromuller-del"}],"headRefOid":"ccc333"}'
    ;;
  *pull/888*|*pull/999*)
    printf '{"state":"MERGED","isDraft":false,"mergeable":"UNKNOWN","reviewDecision":"APPROVED","statusCheckRollup":[],"reviews":[],"reviewRequests":[]}'
    ;;
  *)
    echo "no such pull request" >&2
    exit 1
    ;;
esac
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
printf '{"generatedAt":"2026-08-02T00:05:01Z","providers":[{"provider":"codex","label":"Codex","windows":[{"id":"weekly","label":"week","percentRemaining":73,"resetsAt":"2026-08-09T00:00:00Z"}],"state":{"status":"fresh"}}]}'
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux" "$fakebin/gh" "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

make_reviews_home() {  # <name>
  local reviews_home=$TMP_ROOT/$1
  mkdir -p "$reviews_home/data" "$reviews_home/state" "$reviews_home/config" "$reviews_home/projects"
  mkdir -p "$reviews_home/projects/artemis"
  git -C "$reviews_home/projects/artemis" init -q
  git -C "$reviews_home/projects/artemis" remote add origin https://github.com/monalee/artemis.git
  cat > "$reviews_home/data/backlog.md" <<EOF
## In flight
- [ ] review-pr-912-b2b2b2b - Review the payment refactor round 2 $THEIR_PR (repo: artemis) (kind: ship) (since 2026-07-31) (hold: waiting on their fixes) (hold-kind: external)
- [ ] review-pr-930-c3c3c3c - Review the tile cache https://github.com/monalee/artemis/pull/930 (repo: artemis) (kind: ship) (since 2026-08-01)

## Queued

## Done
- [x] review-pr-912-a1a1a1a - Review the payment refactor first pass $THEIR_PR (repo: artemis) (kind: scout) (reported 2026-07-30)
- [x] review-pr-4188-1a1a1a1 - Review PR 4188 first pass (repo: unknown-project) (kind: scout) (reported 2026-08-01)
- [x] review-pr-4188-2b2b2b2 - Review PR 4188 second pass (repo: unknown-project) (kind: scout) (reported 2026-08-02)
- [x] review-pr-888-e8e8e8e - Review merged PR 888 without a recorded link (repo: artemis) (kind: scout) (reported 2026-08-02)
- [x] review-pr-999-d4d4d4d - Review merged PR 999 $MERGED_THEIR_PR (repo: artemis) (kind: scout) (reported 2026-08-02)
EOF
  printf '%s\n' "$reviews_home"
}

write_live_fixture() {  # <home>
  local home=$1 reviews_home generation review_generation stuck_generation
  mkdir -p "$home/projects/decision" "$home/projects/review" "$home/projects/merged"
  reviews_home=$(make_reviews_home "reviews-home-$(basename "$home")")
  cat > "$home/data/secondmates.md" <<EOF
- reviews - Runs colleague PR review rounds (home: $reviews_home; scope: colleague PR review rounds; projects: ; added 2026-08-01)
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] decision-task - Decide the public API (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] review-task - Ship the review branch (repo: artemis) (kind: ship) (since 2026-08-01)
- [ ] local-ci-pr - PR 4004: Ship the Firstmate local CI branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] unregistered-pr - PR 4002: Ship the unregistered review branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] stuck-pr - PR 4003: Ship the stuck review branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] deploy-window - Approve deployment window (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the deployment window.) (hold-kind: captain)
- [ ] hold-oldest - Renew the signing certificate (repo: firstmate) (kind: captain) (since 2026-07-20) (hold: The certificate expires soon.) (hold-kind: captain)
- [ ] hold-answered - Pick the flake-fix destination (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: CAPTAIN DECIDED 2026-08-02: use a separate test-hardening PR.) (hold-kind: captain)
- [ ] hold-undecided - Decide whether to rotate the credential (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: This is not yet decided and still needs Pedro.) (hold-kind: captain)

## Queued
- [ ] launch-page - Ship the launch page blocked-by: deploy-window (repo: firstmate) (kind: ship) (since 2026-08-01)
- [ ] queued-pr-note - PR 3999: Prepare a follow-up after another PR lands (repo: firstmate) (kind: ship) (since 2026-08-02)

## Done
- [x] merged-task - Ship the merged thing (repo: firstmate) (kind: ship) (merged 2026-07-31)
EOF

  fm_write_meta "$home/state/decision-task.meta" \
    "window=firstmate:fm-decision-task" \
    "worktree=$home/projects/decision" \
    "project=$home/projects/firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'needs-decision [key=api-shape]: Choose the public API shape. %s\n' \
    "$TRUNCATION_ARTIFACT" > "$home/state/decision-task.status"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" decision-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" decision-task idle \
    --gen "$generation" --source claude-hook --event stop

  fm_write_meta "$home/state/review-task.meta" \
    "window=firstmate:fm-review-task" \
    "worktree=$home/projects/review" \
    "project=artemis" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=$OUR_PR"
  printf 'done: PR %s checks green\n' "$OUR_PR" > "$home/state/review-task.status"
  review_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" review-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" review-task idle \
    --gen "$review_generation" --source claude-hook --event stop

  fm_write_meta "$home/state/local-ci-pr.meta" \
    "window=firstmate:fm-local-ci-pr" \
    "worktree=$home/projects/local-ci" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=$FIRSTMATE_PR"
  mkdir -p "$home/projects/local-ci"
  printf 'done: local suite evidence was not recorded\n' > "$home/state/local-ci-pr.status"

  fm_write_meta "$home/state/merged-task.meta" \
    "window=firstmate:fm-merged-task" \
    "worktree=$home/projects/merged" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=$MERGED_PR"
  printf 'done: PR %s checks green\n' "$MERGED_PR" > "$home/state/merged-task.status"

  fm_write_meta "$home/state/unregistered-pr.meta" \
    "window=firstmate:fm-unregistered-pr" \
    "worktree=$home/projects/unregistered" \
    "project=wrong-project" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  mkdir -p "$home/projects/unregistered"
  printf 'paused: PR 4002 is ready for review but was never registered\n' \
    > "$home/state/unregistered-pr.status"

  fm_write_meta "$home/state/stuck-pr.meta" \
    "window=firstmate:fm-stuck-pr" \
    "worktree=$home/projects/stuck" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  mkdir -p "$home/projects/stuck"
  printf 'blocked [key=stuck-pr]: Worker stopped before PR registration.\n' > "$home/state/stuck-pr.status"
  stuck_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stuck-pr)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stuck-pr idle \
    --gen "$stuck_generation" --source claude-hook --event stop

  # Pin status mtimes so age-in-state is deterministic against FM_SNAPSHOT_NOW.
  TZ=UTC touch -t 202608020000 "$home/state/decision-task.status" \
    "$home/state/review-task.status" "$home/state/merged-task.status"
}

render_terminal() {  # <home> <fakebin> [extra args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" "$@"
}

line_number_of() {  # <haystack> <needle>
  printf '%s\n' "$1" | grep -n -F "$2" | head -1 | cut -d: -f1
}

test_cockpit_shows_action_sections_and_full_inventory() {
  local home fakebin out decisions ours obligations theirs decide hold_blocking hold_oldest total_lines pr_num pr_shown review_num review_shown
  home=$(make_home three)
  write_live_fixture "$home"
  awk -v repo="(repo: $home/projects/firstmate)" \
    'NR == 2 { sub(/\(repo: firstmate\)/, repo) } { print }' \
    "$home/data/backlog.md" > "$home/data/backlog.md.tmp"
  mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 100 --all) || fail "terminal render failed"

  decisions=$(line_number_of "$out" "DECISIONS (6)")
  ours=$(line_number_of "$out" "OUR PRS IN REVIEW (4)")
  obligations=$(line_number_of "$out" "REVIEWS WAITING ON PEDRO (2)")
  theirs=$(line_number_of "$out" "REVIEWING (3)")
  [ -n "$decisions" ] || fail "no DECISIONS section counting all three items"
  [ -n "$ours" ] || fail "no OUR PRS IN REVIEW section"
  [ -n "$obligations" ] || fail "no requested-review obligation section"
  [ -n "$theirs" ] || fail "no REVIEWING section"
  { [ "$decisions" -lt "$ours" ] && [ "$ours" -lt "$obligations" ] && [ "$obligations" -lt "$theirs" ]; } \
    || fail "sections are not ordered decisions, ours, obligations, reviewing"
  assert_not_contains "$out" "UNDERWAY (" "a retired section is still rendered"
  assert_not_contains "$out" "UNHEALTHY (" "a retired section is still rendered"
  assert_not_contains "$out" "QUEUED (" "a retired section is still rendered"
  assert_not_contains "$out" "UNREADABLE (" "a retired section is still rendered"

  decide=$(line_number_of "$out" "◆ Decide the public API")
  hold_blocking=$(line_number_of "$out" "◆ Approve deployment window")
  hold_oldest=$(line_number_of "$out" "◆ Renew the signing certificate")
  [ -n "$decide" ] && [ -n "$hold_blocking" ] && [ -n "$hold_oldest" ] \
    || fail "a decision item is missing from the section"
  { [ "$decide" -lt "$hold_blocking" ] && [ "$hold_blocking" -lt "$hold_oldest" ]; } \
    || fail "importance order is broken: live ask, then delivery-blocking hold, then oldest"
  assert_contains "$out" " 1 d:decision-task-api~" \
    "rows do not colocate their position, stable id, marker, and title"

  assert_contains "$out" "PR 4002" "a current ship task in the PR stage was silently dropped"
  assert_contains "$out" "PR 4002 | local checks unknown | readiness unknown (unregistered)" \
    "an unregistered PR row implied established checks or readiness"
  assert_contains "$out" "project artemis" "mixed-project full inventory lacks an Artemis separator"
  assert_contains "$out" "project firstmate" "mixed-project full inventory lacks an internal-project separator"
  assert_not_contains "$out" "$home/projects/firstmate" \
    "an absolute project path leaked into the shareable cockpit"
  assert_contains "$out" "github status checked just now" "github data age is not printed"
  assert_not_contains "$out" "pull/3972" "a landed PR still renders as in review"

  pr_num=$(printf '%s\n' "$out" | grep -F "PR 4001 |" | tail -1 | awk '{print $1}')
  pr_shown=$(render_terminal "$home" "$fakebin" --show "$pr_num") || fail "our PR expansion failed"
  assert_contains "$pr_shown" "checks green" "green checks are missing from expanded status"
  assert_contains "$pr_shown" "changes requested by reviewer-two" \
    "review readiness is missing from expanded status"
  assert_contains "$pr_shown" "$OUR_PR" "expanded PR row lost its full link"

  assert_contains "$out" "PR 912" "review rounds were not grouped by PR"
  assert_contains "$out" "PR 4188" "completed review rounds were silently dropped"
  review_num=$(printf '%s\n' "$out" | grep -F "PR 912" | tail -1 | awk '{print $1}')
  review_shown=$(render_terminal "$home" "$fakebin" --show "$review_num") || fail "review expansion failed"
  assert_contains "$review_shown" "review x2" "expanded review lost its real round count"
  assert_contains "$review_shown" "waiting on their fixes" "expanded review lost its recorded status"
  assert_contains "$review_shown" "$THEIR_PR" "expanded review lost its full link"

  assert_contains "$out" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "fresh recap did not report only next-hour attention"
  assert_contains "$out" "? Pick the flake-fix destination" \
    "an answered-looking open hold was not marked uncertain"

  assert_not_contains "$out" "token spend not measured" "measurement inventory leaked onto the list surface"
  assert_not_contains "$out" "truncated, 90 chars" "CLI truncation artifact leaked into the cockpit"

  total_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$total_lines" -le 45 ] || fail "full inventory does not fit a 45-row terminal: $total_lines lines"
  pass "cockpit renders action sections and a reachable full inventory"
}

test_pr_truthfulness_regressions() {
  local home fakebin out registered_num registered_shown unknown_num unknown_shown local_ci_num local_ci_shown
  home=$(make_home pr-truth)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "truthfulness render failed"
  assert_contains "$out" "OUR PRS IN REVIEW (4)" "the PR review section contains a false or missing row"
  assert_not_contains "$out" "PR 3999" \
    "a queued backlog record that merely names a PR was misreported as our PR in review"
  assert_not_contains "$out" "github.com/pedromuller-del/firstmate/pull/4002" \
    "the cockpit fabricated a URL for an unregistered PR"
  registered_num=$(printf '%s\n' "$out" | grep -F "PR 4001 |" | tail -1 | awk '{print $1}')
  registered_shown=$(render_terminal "$home" "$fakebin" --show "$registered_num") \
    || fail "registered PR expansion failed"
  assert_contains "$registered_shown" "checks green · changes requested by reviewer-two" \
    "CI and review readiness are not independent dimensions"
  assert_contains "$registered_shown" "review: reviews recorded: reviewer-two (changes requested), reviewer-one (approved)" \
    "expanded PR does not say who reviewed it"
  assert_contains "$out" "PR 4001 | checks green | changes requested by reviewer-two" \
    "our PR line omits established check and review status"
  assert_not_contains "$out" "changes requested by reviewer-one" \
    "a superseded changes-requested review still names its author"
  assert_contains "$out" "PR 4004 | local checks unknown | waiting on local-reviewer" \
    "Firstmate PR line treated GitHub checks as local CI evidence"
  assert_contains "$out" "○ PR 4004 | local checks unknown | waiting on local-reviewer" \
    "structured waiting-review state became unknown after presentation rewriting"
  assert_not_contains "$out" "PR 4004 | checks red" \
    "Firstmate PR line reported a GitHub check as a signal"
  unknown_num=$(printf '%s\n' "$out" | grep -F "PR 4002" | tail -1 | awk '{print $1}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_num") \
    || fail "unregistered PR expansion failed"
  assert_contains "$unknown_shown" "local checks unknown · readiness unknown (unregistered)" \
    "missing registration was rendered as a false CI state"
  assert_contains "$unknown_shown" "was never registered" "missing registration has no visible reason"
  local_ci_num=$(printf '%s\n' "$out" | grep -F "PR 4004 |" | tail -1 | awk '{print $1}')
  local_ci_shown=$(render_terminal "$home" "$fakebin" --show "$local_ci_num") \
    || fail "registered Firstmate PR expansion failed"
  assert_contains "$local_ci_shown" "exact local-suite evidence" \
    "registered Firstmate PR recommendation dead-ends on another GitHub check"
  pass "PR rows preserve unknown registration and independent CI/readiness truth"
}

test_review_relationships_survive_completed_rounds() {
  local home fakebin out pr912_num pr912_shown pr4188_num pr4188_shown
  home=$(make_home review-relationships)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "review relationship render failed"
  assert_contains "$out" "REVIEWING (3)" "completed rounds disappeared from review relationships"
  assert_contains "$out" "PR 912" "two rounds for one PR were not grouped"
  assert_contains "$out" "PR 4188" "a completed current relationship was dropped"
  assert_not_contains "$out" "PR 999" "terminal GitHub evidence did not retire a merged review relationship"
  assert_not_contains "$out" "PR 888" \
    "a merged review relationship survived despite a verified project remote and fresh GitHub state"
  pr912_num=$(printf '%s\n' "$out" | grep -F "PR 912" | tail -1 | awk '{print $1}')
  pr912_shown=$(render_terminal "$home" "$fakebin" --show "$pr912_num") || fail "PR 912 expansion failed"
  assert_contains "$pr912_shown" "review x2" "distinct recorded review heads did not produce round two"
  pr4188_num=$(printf '%s\n' "$out" | grep -F "PR 4188" | tail -1 | awk '{print $1}')
  pr4188_shown=$(render_terminal "$home" "$fakebin" --show "$pr4188_num") || fail "PR 4188 expansion failed"
  assert_contains "$pr4188_shown" "waiting on author after review x2" \
    "a completed round was mistaken for a completed PR relationship"
  assert_contains "$out" "PR 912 | waiting on their fixes | review x2" \
    "reviewing line omits the recorded round state"
  pass "reviewing is grouped by PR and retains completed rounds until terminal evidence"
}

test_followup_review_without_round_history_stays_unknown() {
  local home reviews_home fakebin out num shown
  home=$(make_home unknown-review-round)
  write_live_fixture "$home"
  reviews_home="$TMP_ROOT/reviews-home-$(basename "$home")"
  cat >> "$reviews_home/data/backlog.md" <<'EOF'
- [x] review-pr-777-final-a7a7a7a - PR 777 final anchored recheck (repo: artemis) (kind: scout) (reported 2026-08-02)
EOF
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "unknown review-round render failed"
  assert_contains "$out" "PR 777" "a follow-up review with incomplete history was dropped"
  num=$(printf '%s\n' "$out" | grep -F "PR 777" | tail -1 | awk '{print $1}')
  shown=$(render_terminal "$home" "$fakebin" --show "$num") || fail "unknown round expansion failed"
  assert_contains "$shown" "review round unknown (1 head recorded)" \
    "a follow-up review with incomplete history fabricated round one"
  pass "incomplete follow-up history renders an unknown round instead of a false ordinal"
}

test_numberless_review_record_never_invents_a_waiting_party() {
  local home reviews_home fakebin out
  home=$(make_home numberless-review)
  write_live_fixture "$home"
  reviews_home="$TMP_ROOT/reviews-home-$(basename "$home")"
  cat >> "$reviews_home/data/backlog.md" <<'EOF'
- [x] refresh-review-checklist - Refresh the review checklist (repo: artemis) (kind: scout) (reported 2026-08-02)
EOF
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "numberless review render failed"
  assert_contains "$out" "? PR unknown: Refresh the review checklist" \
    "numberless review record lost its identity"
  assert_not_contains "$out" "PR unknown: Refresh the review checklist | waiting on author" \
    "numberless review record invented a waiting party"
  pass "numberless review records state only their known workflow and PR identity"
}

test_decision_projection_labels_answered_and_aged_open_holds() {
  local home fakebin out answered_num answered_shown aged_num aged_shown
  home=$(make_home decision-truth)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "decision truth render failed"
  assert_contains "$out" "DECISIONS (6)" "an open hold or blocker was silently removed"
  assert_contains "$out" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "decision recap included deferred holds"
  assert_contains "$out" "? Pick the flake-fix destination" \
    "explicit answer text was reported as needing a new answer"
  answered_num=$(printf '%s\n' "$out" | grep -F "Pick the flake-fix destination" | tail -1 | awk '{print $1}')
  answered_shown=$(render_terminal "$home" "$fakebin" --show "$answered_num") \
    || fail "answered-looking hold expansion failed"
  assert_contains "$answered_shown" "looks answered; hold still open" \
    "the conservative answer hint is not labelled"
  aged_num=$(printf '%s\n' "$out" | grep -F "Renew the signing certificate" | tail -1 | awk '{print $1}')
  aged_shown=$(render_terminal "$home" "$fakebin" --show "$aged_num") || fail "aged hold expansion failed"
  assert_contains "$aged_shown" "aged hold; still open" "the old open hold lost its lifecycle caveat"
  assert_contains "$out" "◆ Decide whether to rotate the credential" \
    "ordinary not-yet-decided prose was mistaken for an answer declaration"
  pass "decision projection keeps every hold while separating actionable, answered-looking, and aged rows"
}

test_clean_list_uses_truthful_markers_and_priority_order() {
  local home fakebin out colored escape yellow red blue green unknown yellow_line red_line unknown_line blue_line green_line
  home=$(make_home interaction-markers)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 130 --all) \
    || fail "marker render failed"
  yellow='◆'
  red='×'
  blue='○'
  green='●'
  unknown='?'
  assert_contains "$out" "$yellow Decide the public API" "needs-Pedro marker is absent without color"
  assert_contains "$out" "$red PR 4003: Ship the stuck review branch" "stuck marker is absent without color"
  assert_contains "$out" "$blue PR 912" "waiting-elsewhere marker is absent without color"
  assert_contains "$out" "$green PR 930" "progressing marker is absent without color"
  assert_contains "$out" "$unknown PR 4002" "unknown marker is absent without color"
  assert_contains "$out" "◆ needs Pedro | × stuck | ○ waiting elsewhere | ● progressing | ? unknown" \
    "the color-free legend does not distinguish every marker"

  yellow_line=$(line_number_of "$out" "$yellow Decide the public API")
  unknown_line=$(line_number_of "$out" "$unknown Pick the flake-fix destination")
  [ "$yellow_line" -lt "$unknown_line" ] || fail "unknown sorted ahead of needs-Pedro"
  red_line=$(line_number_of "$out" "$red PR 4003: Ship the stuck review branch")
  unknown_line=$(line_number_of "$out" "$unknown PR 4002")
  [ "$red_line" -lt "$unknown_line" ] || fail "unknown sorted ahead of stuck"
  assert_contains "$out" "$unknown PR 4001 | checks green | changes requested by reviewer-two" \
    "changes requested without fresh local stuck evidence was overreported as red"
  blue_line=$(line_number_of "$out" "$blue PR 912")
  green_line=$(line_number_of "$out" "$green PR 930")
  [ "$blue_line" -lt "$green_line" ] || fail "progressing sorted ahead of waiting-elsewhere"
  colored=$(NO_COLOR='' FORCE_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "colored marker render failed"
  escape=$(printf '\033')
  assert_contains "$colored" "${escape}[33m◆${escape}[0m ${escape}[2mRenew the signing certificate" \
    "aged decision title is not dimmed while preserving its yellow marker"
  pass "clean list markers survive NO_COLOR and follow attention priority"
}

test_default_rows_are_one_line_with_a_fresh_recap() {
  local home fakebin out title_line
  home=$(make_home interaction-list)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 130) \
    || fail "clean-list render failed"
  assert_contains "$out" "ATTENTION NOW" "fresh recap band is absent"
  assert_contains "$out" "3 need Pedro | 1 stuck | 2 reviews waiting" \
    "recap included deferred holds or omitted a review obligation"
  assert_contains "$out" "Decide the public API" "recap did not name a current need"
  assert_contains "$out" "+4 more below" "recap truncation hid its remaining-attention count"
  title_line=$(printf '%s\n' "$out" | grep -F "PR 4003 |" | tail -1)
  assert_not_contains "$title_line" "firstmate" "default row includes project detail"
  assert_not_contains "$title_line" "for " "default row includes age detail"
  assert_contains "$out" "PR 4003 | local checks unknown | readiness unknown (unregistered)" \
    "actionable PR row omits established status"
  assert_contains "$out" "PR 4001 | checks green | changes requested by reviewer-two" \
    "default screen hides established PR checks and review state"
  assert_contains "$out" "PR 4004 | local checks unknown | waiting on local-reviewer" \
    "default screen hides a PR waiting on review"
  assert_contains "$out" "PR 4002 | local checks unknown | readiness unknown (unregistered)" \
    "default screen hides a PR whose state remains unknown"
  assert_not_contains "$out" "other PRs" "default screen still collapses our PR status rows"
  assert_not_contains "$out" "$OUR_PR" "default list leaked a PR link"
  assert_contains "$out" "github status checked just now" "cached forge facts lost their explicit age"
  [ "${#title_line}" -le 80 ] || fail "fixed terminal measure exceeded 80 columns"
  pass "default view is a fixed-measure one-line list with fresh local recap"
}

test_expansion_includes_evidence_derived_recommendation() {
  local home fakebin out num shown unknown_num unknown_shown
  home=$(make_home interaction-expansion)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "expansion list render failed"
  num=$(printf '%s\n' "$out" | grep -F "Decide the public API" | tail -1 | awk '{print $1}')
  shown=$(render_terminal "$home" "$fakebin" --show "$num") || fail "decision expansion failed"
  assert_contains "$shown" "row id: d:decision-task-api~" \
    "expanded row omitted its stable quotable id"
  assert_contains "$shown" "current state:" "expanded row omitted current state"
  assert_contains "$shown" "age:" "expanded row omitted age"
  assert_contains "$shown" "blockers:" "expanded row omitted concrete blocker or status"
  assert_contains "$shown" "context and recommendation: Answer the recorded decision" \
    "expanded decision omitted its evidence-derived recommendation"

  unknown_num=$(printf '%s\n' "$out" | grep -F "PR 4002" | tail -1 | awk '{print $1}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_num") \
    || fail "unknown PR expansion failed"
  assert_contains "$unknown_shown" "context and recommendation: Register PR 4002" \
    "unknown PR expansion invented a recommendation instead of naming missing registration"
  pass "expanded rows carry full context and evidence-derived recommendations"
}

test_show_expands_rows_with_full_context() {
  local home fakebin out all before num shown row_id id_shown pr_num pr_shown error rc
  home=$(make_home show)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 100) || fail "terminal render failed"
  num=$(printf '%s\n' "$out" | grep -F "Decide the public API" | tail -1 | awk '{print $1}')
  [ -n "$num" ] || fail "could not read the decision row's number"
  shown=$(render_terminal "$home" "$fakebin" --show "$num") || fail "--show $num failed"
  assert_contains "$shown" "DECISIONS | ◆ needs Pedro" "expanded row does not name its section and marker"
  assert_contains "$shown" "Choose the public API shape." "expanded row lost its full reason"
  assert_contains "$shown" "why here: open needs-decision in the keyed decision fold" \
    "expanded row does not explain its routing"
  assert_contains "$shown" "recent events" "expanded row does not show its status events"

  row_id=$(printf '%s\n' "$out" | grep -F "Decide the public API" | awk '{print $2}')
  id_shown=$(render_terminal "$home" "$fakebin" --show "$row_id") \
    || fail "stable row id did not resolve"
  assert_contains "$id_shown" "row id: $row_id" \
    "expanded row does not preserve its quotable id"

  before=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-26T00:00:00Z \
    "$DASHBOARD" --width 80 --all) || fail "pre-aging render failed"
  assert_contains "$before" "d:hold-oldest ◆ Renew the signing certificate" \
    "hold id before aging is missing"
  all=$(render_terminal "$home" "$fakebin" --width 80 --all) || fail "full render failed"
  assert_contains "$all" "d:hold-oldest ◆ Renew the signing certificate" \
    "hold id changed when its attention class aged"

  pr_num=$(printf '%s\n' "$all" | grep -F "PR 4001 |" | head -1 | awk '{print $1}')
  [ -n "$pr_num" ] || fail "could not read our PR row's number"
  pr_shown=$(render_terminal "$home" "$fakebin" --show "$pr_num") || fail "--show $pr_num failed"
  assert_contains "$pr_shown" "$OUR_PR" "expanded PR row lost its link"
  assert_contains "$pr_shown" "why here: our PR recorded in task metadata" \
    "expanded PR row does not explain its routing"

  set +e
  error=$(render_terminal "$home" "$fakebin" --show 99 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--show accepted an out-of-range row"
  assert_contains "$error" "no such row" "out-of-range --show refusal is not actionable"
  pass "numbered rows expand to full context and bad numbers refuse loudly"
}

test_absent_sources_and_unreachable_reviews_stay_honest() {
  local home out output html
  home=$(make_home absent)

  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z "$DASHBOARD" --width 80) \
    || fail "absent-source terminal render failed"
  assert_contains "$out" "backlog absent" "missing backlog was not disclosed"
  assert_not_contains "$out" "telemetry absent" "source inventory leaked onto the default screen"
  assert_not_contains "$out" "token spend not measured" "measurement inventory leaked onto the default screen"
  assert_contains "$out" "captain holds unknown" "absent backlog rendered as an empty decisions list"
  assert_contains "$out" "unavailable - no secondmates registered" \
    "an unreachable reviews domain was not disclosed with its reason"

  output="$home/fleet-dashboard.html"
  FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "absent-source dashboard render failed"
  html=$(<"$output")
  assert_contains "$html" "Backlog source</span><strong>Absent</strong>" "missing backlog rendered as zero"
  assert_contains "$html" "Model telemetry</span><strong>Absent</strong>" "missing telemetry rendered as zero"
  assert_contains "$html" "Token spend</span><strong>Not measured</strong>" "missing telemetry implied zero spend"
  pass "missing sources and the unreachable reviews domain render as absent with reasons"
}

test_html_page_renders_minimal_sections_with_reachable_detail() {
  local home fakebin output html
  home=$(make_home html)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  output="$home/fleet-dashboard.html"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "dashboard render failed"
  html=$(<"$output")

  assert_contains "$html" 'id="decisions"' "page omitted the decisions section"
  assert_contains "$html" 'id="ours-in-review"' "page omitted our PRs section"
  assert_contains "$html" 'id="reviewing"' "page omitted the reviewing section"
  assert_contains "$html" 'id="review-obligations"' "page omitted requested-review obligations"
  assert_contains "$html" 'aria-label="needs Pedro"' "page omitted marker semantics"
  assert_contains "$html" 'aria-label="unknown"' "page omitted the unknown marker"
  assert_contains "$html" "Attention now" "page omitted the recap band"
  assert_contains "$html" "github status checked" "github data age missing from the page"
  assert_contains "$html" "PR 4001 | checks green | changes requested by reviewer-two" \
    "HTML PR row omits established status"
  assert_contains "$html" 'class="row row-aged"' "HTML list does not distinguish aged holds"
  assert_not_contains "$html" "truncated, 90 chars" "CLI truncation artifact leaked into the page"
  assert_not_contains "$html" "https://cdn" "dashboard depends on a CDN"
  pass "HTML page renders minimal sections with gh status and reachable detail"
}

test_help_describes_the_fixed_terminal_measure() {
  local help
  help=$("$DASHBOARD" --help) || fail "dashboard help failed"
  assert_contains "$help" "terminal frame width request (minimum 40; output capped at 80)" \
    "--width help still claims an uncapped override"
  pass "help describes the fixed terminal measure"
}

test_watch_flag_needs_a_terminal_and_stays_exclusive() {
  local home fakebin error rc
  home=$(make_home watch)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  set +e
  error=$(render_terminal "$home" "$fakebin" --watch 2>&1 < /dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--watch ran without a terminal"
  assert_contains "$error" "requires a terminal" "non-tty watch refusal is not actionable"

  set +e
  error=$(render_terminal "$home" "$fakebin" --watch --output "$home/x.html" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--watch combined with --output"
  assert_contains "$error" "cannot be combined" "watch/output exclusivity is not enforced"
  pass "watch mode refuses non-terminals and stays exclusive with file output"
}

test_ignored_operational_directories_are_never_output_targets() {
  local home directory output error rc
  home=$(make_home forbidden-output)
  for directory in data state config; do
    output="$home/$directory/fleet-dashboard.html"
    set +e
    error=$(FM_HOME="$home" "$DASHBOARD" --output "$output" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "dashboard accepted a $directory/ output path"
    [ ! -e "$output" ] || fail "dashboard wrote into the ignored $directory directory"
    assert_contains "$error" "refusing dashboard output" "unsafe-output refusal was not actionable"
  done
  pass "dashboard refuses data, state, and config output roots"
}

test_default_screen_collapses_deferred_rows_without_hiding_our_prs() {
  local home fakebin out all
  home=$(make_home minimal-default)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80) || fail "minimal render failed"
  assert_contains "$out" "2 deferred decisions" "aged and answered-looking holds have no counted affordance"
  assert_contains "$out" "3 review relationships" "review work in progress has no counted affordance"
  assert_contains "$out" "PR 4001 | checks green | changes requested by reviewer-two" \
    "default minimalism hid the PR checks Pedro uses to avoid a GitHub trip"
  assert_contains "$out" "PR 4004 | local checks unknown | waiting on local-reviewer" \
    "default minimalism hid what an open PR is waiting on"
  assert_not_contains "$out" "other PRs" "our PR rows remain behind a collapsed affordance"
  assert_not_contains "$out" "Renew the signing certificate" "aged hold stayed on the default screen"
  assert_not_contains "$out" "Pick the flake-fix destination" "answered-looking hold stayed on the default screen"
  assert_not_contains "$out" "sources backlog" "non-actionable source inventory stayed on the default screen"

  all=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "expanded list render failed"
  assert_contains "$all" "Renew the signing certificate" "--all cannot reach an aged hold"
  assert_contains "$all" "Pick the flake-fix destination" "--all cannot reach an answered-looking hold"
  assert_contains "$all" "PR 4188" "--all cannot reach a collapsed review relationship"
  pass "default screen collapses deferred work without hiding our PR status"
}

test_readable_ids_survive_colliding_rows_and_support_prefix_lookup() {
  local home fakebin out first_id with_collision survivor_id shown updated error rc
  home=$(make_home readable-ids)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '/^## Queued$/ { print "- [ ] toolsmith-endpoint-collision - Decide how endpoint collisions are reported (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the collision wording.) (hold-kind: captain)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "readable-id render failed"
  first_id=$(printf '%s\n' "$out" | grep -F "endpoint collisions are reported" | awk '{print $2}')
  case "$first_id" in
    d:toolsmith-endpoint*) ;;
    *) fail "long record id became opaque: $first_id" ;;
  esac

  awk '/^## Queued$/ { print "- [ ] toolsmith-endpoint-copy - Decide how endpoint copies are reported (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the copy wording.) (hold-kind: captain)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  with_collision=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "collision render failed"
  survivor_id=$(printf '%s\n' "$with_collision" | grep -F "endpoint collisions are reported" | awk '{print $2}')
  [ "$first_id" = "$survivor_id" ] || fail "another row changed a survivor id: $first_id -> $survivor_id"
  set +e
  error=$(render_terminal "$home" "$fakebin" --show "${first_id%?}" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an implicit prefix could make a stale id resolve to another row"
  assert_contains "$error" "no row has that id" "stale exact-id refusal is not explicit"
  shown=$(render_terminal "$home" "$fakebin" --show "${first_id%?}*") || fail "explicit unambiguous id prefix did not resolve"
  assert_contains "$shown" "endpoint collisions are reported" "prefix lookup resolved the wrong row"
  pass "readable row ids depend only on their own stable record identity"
}

test_detail_contract_uses_report_evidence_and_slow_quota_without_fabrication() {
  local home fakebin out id shown output html
  home=$(make_home detail-contract)
  write_live_fixture "$home"
  mkdir -p "$home/data/decision-task"
  cat > "$home/data/decision-task/report.md" <<'EOF'
# Decision task report

## What this affects

People choosing the API will see one stable method instead of two competing entry points.

## Manual test script

1. Open the API preview.
2. Call the documented method.
Expected: the documented method succeeds.
Failure: either competing entry point remains visible.

### Credentials

Login: `captain@example.test` / `secret-test-password`
EOF
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "detail list render failed"
  id=$(printf '%s\n' "$out" | grep -F "Decide the public API" | awk '{print $2}')
  shown=$(render_terminal "$home" "$fakebin" --show "$id") || fail "detail expansion failed"
  assert_contains "$shown" "token usage: not measured" "detail implied per-task token usage exists"
  assert_contains "$shown" "quota: Codex week 73% remaining; resets in 6d 23h" "quota and reset are absent from detail"
  assert_contains "$shown" "quota data: checked just now" "freshly fetched quota was rendered with an impossible age"
  assert_contains "$shown" "what this affects: People choosing the API" "report-backed impact is absent"
  assert_contains "$shown" "manual test script (task report):" "manual script source is not identified"
  assert_contains "$shown" "secret-test-password" "interactive detail omitted recorded credentials"

  output="$home/cockpit.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" >/dev/null || fail "HTML detail render failed"
  html=$(<"$output")
  assert_contains "$html" "manual test script: omitted from shareable HTML" \
    "HTML does not explain its fail-safe script omission"
  assert_not_contains "$html" "Open the API preview" "shareable HTML retained a manual script body"
  assert_not_contains "$html" "secret-test-password" "shareable HTML leaked credentials"
  pass "detail carries sourced impact, manual validation, honest token status, and quota"
}

test_review_obligations_are_distinct_and_oldest_first() {
  local home fakebin out obligation reviewing oldest newer id shown
  home=$(make_home review-obligations)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80) || fail "review-obligation render failed"
  obligation=$(line_number_of "$out" "REVIEWS WAITING ON PEDRO")
  reviewing=$(line_number_of "$out" "REVIEWING")
  [ -n "$obligation" ] || fail "requested-review obligation section is absent"
  [ -n "$reviewing" ] || fail "review work-in-progress affordance is absent"
  [ "$obligation" -lt "$reviewing" ] || fail "obligations are buried under our review process"
  oldest=$(line_number_of "$out" "PR 930 [artemis] | waiting 13d")
  newer=$(line_number_of "$out" "PR 912 [artemis] | waiting 2d")
  [ -n "$oldest" ] && [ -n "$newer" ] && [ "$oldest" -lt "$newer" ] \
    || fail "requested reviews are not sorted by longest wait"
  assert_contains "$out" "PR 930 [artemis] | waiting 13d" "waiting time is not prominent"
  assert_contains "$out" "re-review 2" "review round is absent"
  id=$(printf '%s\n' "$out" | grep -F "PR 930 [artemis] | waiting 13d" | awk '{print $2}')
  shown=$(render_terminal "$home" "$fakebin" --show "$id") || fail "review obligation expansion failed"
  assert_contains "$shown" "author pushed since review" "head change did not reuse recorded review heads"
  assert_contains "$shown" "manual validation outstanding" "manual validation obligation is absent"
  pass "review obligations are a distinct longest-wait-first action queue"
}

test_decision_ids_bind_task_key_and_verb_across_membership_changes() {
  local home fakebin updated before alpha_id after alpha_after zulu_id shown generation
  home=$(make_home decision-id-membership)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '/^## Queued$/ { print "- [ ] mm-alpha - Fix the alpha ingest (repo: firstmate) (kind: ship) (since 2026-08-02)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fm_write_meta "$home/state/mm-alpha.meta" \
    "window=firstmate:fm-mm-alpha" "worktree=$home/projects/mm-alpha" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  mkdir -p "$home/projects/mm-alpha"
  printf 'needs-decision [key=rotate-cert]: Choose alpha rotation.\n' > "$home/state/mm-alpha.status"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" mm-alpha)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" mm-alpha idle \
    --gen "$generation" --source claude-hook --event stop
  fakebin=$(make_fakebin "$home")

  before=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "single-key render failed"
  alpha_id=$(printf '%s\n' "$before" | grep -F "Fix the alpha ingest" | awk '{print $2}')
  case "$alpha_id" in
    d:mm-alpha-rotate-cert-ask*) ;;
    *) fail "decision id omits task, key, or verb: $alpha_id" ;;
  esac

  awk '/^## Queued$/ { print "- [ ] zz-zulu - Fix the zulu exporter (repo: firstmate) (kind: ship) (since 2026-08-02)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fm_write_meta "$home/state/zz-zulu.meta" \
    "window=firstmate:fm-zz-zulu" "worktree=$home/projects/zz-zulu" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off"
  mkdir -p "$home/projects/zz-zulu"
  printf 'needs-decision [key=rotate-cert]: Choose zulu rotation.\n' > "$home/state/zz-zulu.status"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" zz-zulu)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" zz-zulu idle \
    --gen "$generation" --source claude-hook --event stop

  after=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "colliding-key render failed"
  alpha_after=$(printf '%s\n' "$after" | grep -F "Fix the alpha ingest" | awk '{print $2}')
  zulu_id=$(printf '%s\n' "$after" | grep -F "Fix the zulu exporter" | awk '{print $2}')
  [ "$alpha_id" = "$alpha_after" ] || fail "unrelated membership changed an existing decision id"
  [ "$alpha_id" != "$zulu_id" ] || fail "two tasks sharing a decision key received one id"
  shown=$(render_terminal "$home" "$fakebin" --show "$alpha_id") || fail "stale decision id stopped resolving"
  assert_contains "$shown" "Fix the alpha ingest" "stale decision id silently resolved to a different row"
  pass "decision ids bind task, key, and verb independently of list membership"
}

test_registered_pr_number_comes_from_registered_url() {
  local home fakebin updated out
  home=$(make_home registered-pr-number)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '{ gsub("review-task - Ship the review branch", "review-task - PR 4999: Ship the review branch"); print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "registered-number render failed"
  assert_contains "$out" "PR 4001 | checks green" "registered URL number was not rendered"
  assert_not_contains "$out" "PR 4999 | checks green" "title number mislabeled status fetched for another PR"
  pass "registered PR URL outranks a conflicting title number"
}

test_our_pr_ids_keep_the_pr_number_through_an_engineered_collision() {
  local home fakebin updated out first_shown second_shown duplicates
  home=$(make_home duplicate-our-pr)
  write_live_fixture "$home"
  updated="$home/data/backlog.md.updated"
  awk '/^## Queued$/ { print "- [ ] collision-a-14 - Follow up on the review branch (repo: artemis) (kind: ship) (since 2026-08-02)"; print "- [ ] collision-a-20 - Recheck the review branch (repo: artemis) (kind: ship) (since 2026-08-02)" } { print }' \
    "$home/data/backlog.md" > "$updated"
  mv "$updated" "$home/data/backlog.md"
  mkdir -p "$home/projects/collision-a-14" "$home/projects/collision-a-20"
  fm_write_meta "$home/state/collision-a-14.meta" \
    "window=firstmate:fm-collision-a-14" "worktree=$home/projects/collision-a-14" "project=artemis" \
    "harness=claude" "kind=ship" "mode=ship" "yolo=off" "pr=$OUR_PR"
  fm_write_meta "$home/state/collision-a-20.meta" \
    "window=firstmate:fm-collision-a-20" "worktree=$home/projects/collision-a-20" "project=artemis" \
    "harness=claude" "kind=ship" "mode=ship" "yolo=off" "pr=$OUR_PR"
  printf 'working: addressing follow-up findings on %s\n' "$OUR_PR" > "$home/state/collision-a-14.status"
  printf 'working: rechecking follow-up findings on %s\n' "$OUR_PR" > "$home/state/collision-a-20.status"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) \
    || fail "engineered two-hex collision refused the complete render"
  assert_contains "$out" "o:4001~bf59" "first engineered-collision row lost its readable PR identity"
  assert_contains "$out" "o:4001~bf3f" "second engineered-collision row lost its readable PR identity"
  duplicates=$(printf '%s\n' "$out" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[dorv]:/) print $i }' | sort | uniq -d)
  [ -z "$duplicates" ] || fail "dashboard emitted duplicate row identities: $duplicates"
  first_shown=$(render_terminal "$home" "$fakebin" --show o:4001~bf59) || fail "first collision row id did not resolve"
  second_shown=$(render_terminal "$home" "$fakebin" --show o:4001~bf3f) || fail "second collision row id did not resolve"
  assert_contains "$first_shown" "Follow up on the review branch" "first collision id resolved to the wrong task"
  assert_contains "$second_shown" "Recheck the review branch" "second collision id resolved to the wrong task"
  pass "our PR ids keep the PR number and survive an engineered digest collision"
}

test_obligation_round_uses_viewer_review_history_or_stays_unknown() {
  local home fakebin out reviewed_id reviewed_shown unknown_id unknown_shown
  home=$(make_home obligation-review-history)
  write_live_fixture "$home"
  touch "$home/review-history-fixture"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "review-history obligation render failed"
  reviewed_id=$(printf '%s\n' "$out" | grep -F "PR 940 [artemis]" | awk '{print $2}')
  reviewed_shown=$(render_terminal "$home" "$fakebin" --show "$reviewed_id") \
    || fail "viewer-reviewed obligation detail failed"
  assert_contains "$reviewed_shown" "re-review 2+ · author pushed since review" \
    "viewer-authored GitHub review did not establish the round floor and head change"
  unknown_id=$(printf '%s\n' "$out" | grep -F "PR 941 [artemis]" | awk '{print $2}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_id") \
    || fail "unknown-history obligation detail failed"
  assert_contains "$unknown_shown" "round unknown · head change unknown" \
    "absent local and GitHub review history became a positive round claim"
  assert_not_contains "$reviewed_shown$unknown_shown" "first pass" "absent review history still renders as first pass"
  pass "review obligations derive a round floor from GitHub or render unknown"
}

test_shareable_html_omits_unstructured_manual_scripts_by_default() {
  local home fakebin out id shown output html
  home=$(make_home inline-credentials)
  write_live_fixture "$home"
  mkdir -p "$home/data/decision-task"
  cat > "$home/data/decision-task/report.md" <<'EOF'
# Decision task report

## Manual test script

1. Open the API preview.
2. Log in with buyer@example.test / hunter2-inline-password.
Expected: the documented method succeeds.
EOF
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 80 --all) || fail "inline-credential list render failed"
  id=$(printf '%s\n' "$out" | grep -F "Decide the public API" | awk '{print $2}')
  shown=$(render_terminal "$home" "$fakebin" --show "$id") || fail "inline-credential terminal detail failed"
  assert_contains "$shown" "hunter2-inline-password" "interactive terminal omitted the recorded credential"

  output="$home/cockpit.html"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" >/dev/null || fail "inline-credential HTML render failed"
  html=$(<"$output")
  assert_not_contains "$html" "hunter2-inline-password" "shareable HTML leaked an inline credential"
  assert_not_contains "$html" "Open the API preview" "shareable HTML included an unstructured manual script body"
  assert_contains "$html" "manual test script: omitted from shareable HTML" \
    "shareable HTML did not explain the fail-safe script omission"
  pass "shareable HTML omits unstructured manual scripts while terminal detail retains them"
}

test_shareable_html_omits_unstructured_manual_scripts_by_default
test_obligation_round_uses_viewer_review_history_or_stays_unknown
test_our_pr_ids_keep_the_pr_number_through_an_engineered_collision
test_cockpit_shows_action_sections_and_full_inventory
test_pr_truthfulness_regressions
test_review_relationships_survive_completed_rounds
test_followup_review_without_round_history_stays_unknown
test_numberless_review_record_never_invents_a_waiting_party
test_decision_projection_labels_answered_and_aged_open_holds
test_clean_list_uses_truthful_markers_and_priority_order
test_default_rows_are_one_line_with_a_fresh_recap
test_expansion_includes_evidence_derived_recommendation
test_show_expands_rows_with_full_context
test_absent_sources_and_unreachable_reviews_stay_honest
test_html_page_renders_minimal_sections_with_reachable_detail
test_help_describes_the_fixed_terminal_measure
test_watch_flag_needs_a_terminal_and_stays_exclusive
test_ignored_operational_directories_are_never_output_targets
test_default_screen_collapses_deferred_rows_without_hiding_our_prs
test_readable_ids_survive_colliding_rows_and_support_prefix_lookup
test_detail_contract_uses_report_evidence_and_slow_quota_without_fabrication
test_review_obligations_are_distinct_and_oldest_first
test_decision_ids_bind_task_key_and_verb_across_membership_changes
test_registered_pr_number_comes_from_registered_url
