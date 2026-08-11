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
OUR_PR="https://github.com/pedromuller-del/firstmate/pull/4001"
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
    printf '%s\n' fm-decision-task fm-review-task fm-stuck-pr
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
url=${3:-}
case "$url" in
  *pull/4001*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"reviews":[{"author":{"login":"reviewer-one"},"state":"CHANGES_REQUESTED"}]}'
    ;;
  *pull/912*|*pull/930*|*pull/4188*)
    printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[]}'
    ;;
  *pull/888*|*pull/999*)
    printf '{"state":"MERGED","isDraft":false,"mergeable":"UNKNOWN","reviewDecision":"APPROVED","statusCheckRollup":[]}'
    ;;
  *)
    echo "no such pull request" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux" "$fakebin/gh"
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
- [ ] review-task - Ship the review branch (repo: firstmate) (kind: ship) (since 2026-08-01)
- [ ] unregistered-pr - PR 4002: Ship the unregistered review branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] stuck-pr - PR 4003: Ship the stuck review branch (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] deploy-window - Approve deployment window (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the deployment window.) (hold-kind: captain)
- [ ] hold-oldest - Renew the signing certificate (repo: firstmate) (kind: captain) (since 2026-07-20) (hold: The certificate expires soon.) (hold-kind: captain)
- [ ] hold-answered - Pick the flake-fix destination (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: CAPTAIN DECIDED 2026-08-02: use a separate test-hardening PR.) (hold-kind: captain)

## Queued
- [ ] launch-page - Ship the launch page blocked-by: deploy-window (repo: firstmate) (kind: ship) (since 2026-08-01)
- [ ] queued-pr-note - PR 3999: Prepare a follow-up after another PR lands (repo: firstmate) (kind: ship) (since 2026-08-02)

## Done
- [x] merged-task - Ship the merged thing (repo: firstmate) (kind: ship) (merged 2026-07-31)
EOF

  fm_write_meta "$home/state/decision-task.meta" \
    "window=firstmate:fm-decision-task" \
    "worktree=$home/projects/decision" \
    "project=firstmate" \
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
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=$OUR_PR"
  printf 'done: PR %s checks green\n' "$OUR_PR" > "$home/state/review-task.status"
  review_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" review-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" review-task idle \
    --gen "$review_generation" --source claude-hook --event stop

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

test_cockpit_shows_exactly_three_sections() {
  local home fakebin out decisions ours theirs decide hold_blocking hold_oldest total_lines pr_num pr_shown review_num review_shown
  home=$(make_home three)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 100) || fail "terminal render failed"

  decisions=$(line_number_of "$out" "DECISIONS (5)")
  ours=$(line_number_of "$out" "OUR PRS IN REVIEW (3)")
  theirs=$(line_number_of "$out" "REVIEWING (3)")
  [ -n "$decisions" ] || fail "no DECISIONS section counting all three items"
  [ -n "$ours" ] || fail "no OUR PRS IN REVIEW section"
  [ -n "$theirs" ] || fail "no REVIEWING section"
  { [ "$decisions" -lt "$ours" ] && [ "$ours" -lt "$theirs" ]; } \
    || fail "sections are not ordered decisions, ours, reviewing"
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
  assert_contains "$out" " 1 ◆ Decide the public API" "rows are not numbered and marked"

  assert_contains "$out" "PR 4002" "a current ship task in the PR stage was silently dropped"
  assert_contains "$out" "PR 4002: Ship the unregistered review branch" \
    "an unregistered PR row lost its backlog title"
  assert_contains "$out" "github status checked just now" "github data age is not printed"
  assert_not_contains "$out" "pull/3972" "a landed PR still renders as in review"

  pr_num=$(printf '%s\n' "$out" | grep -F "Ship the review branch" | tail -1 | awk '{print $1}')
  pr_shown=$(render_terminal "$home" "$fakebin" --show "$pr_num") || fail "our PR expansion failed"
  assert_contains "$pr_shown" "CI green" "green CI is missing from expanded status"
  assert_contains "$pr_shown" "changes requested" "review readiness is missing from expanded status"
  assert_contains "$pr_shown" "$OUR_PR" "expanded PR row lost its full link"

  assert_contains "$out" "PR 912" "review rounds were not grouped by PR"
  assert_contains "$out" "PR 4188" "completed review rounds were silently dropped"
  review_num=$(printf '%s\n' "$out" | grep -F "PR 912" | tail -1 | awk '{print $1}')
  review_shown=$(render_terminal "$home" "$fakebin" --show "$review_num") || fail "review expansion failed"
  assert_contains "$review_shown" "review x2" "expanded review lost its real round count"
  assert_contains "$review_shown" "waiting on their fixes" "expanded review lost its recorded status"
  assert_contains "$review_shown" "$THEIR_PR" "expanded review lost its full link"

  assert_contains "$out" "3 need Pedro | 1 stuck" "fresh recap did not count actionable local attention"
  assert_contains "$out" "? Pick the flake-fix destination" \
    "an answered-looking open hold was not marked uncertain"

  assert_contains "$out" "token spend not measured" "unreported spend was not explicit"
  assert_not_contains "$out" "truncated, 90 chars" "CLI truncation artifact leaked into the cockpit"

  total_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$total_lines" -le 40 ] || fail "cockpit does not fit a 40-row terminal: $total_lines lines"
  pass "cockpit renders exactly three sections, importance-ranked with live PR status"
}

test_pr_truthfulness_regressions() {
  local home fakebin out registered_num registered_shown unknown_num unknown_shown
  home=$(make_home pr-truth)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "truthfulness render failed"
  assert_contains "$out" "OUR PRS IN REVIEW (3)" "the PR review section contains a false or missing row"
  assert_not_contains "$out" "PR 3999" \
    "a queued backlog record that merely names a PR was misreported as our PR in review"
  assert_not_contains "$out" "github.com/pedromuller-del/firstmate/pull/4002" \
    "the cockpit fabricated a URL for an unregistered PR"
  registered_num=$(printf '%s\n' "$out" | grep -F "Ship the review branch" | tail -1 | awk '{print $1}')
  registered_shown=$(render_terminal "$home" "$fakebin" --show "$registered_num") \
    || fail "registered PR expansion failed"
  assert_contains "$registered_shown" "CI green · changes requested" \
    "CI and review readiness are not independent dimensions"
  assert_contains "$registered_shown" "review: reviews recorded: reviewer-one (changes requested)" \
    "expanded PR does not say who reviewed it"
  unknown_num=$(printf '%s\n' "$out" | grep -F "PR 4002" | tail -1 | awk '{print $1}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_num") \
    || fail "unregistered PR expansion failed"
  assert_contains "$unknown_shown" "CI unknown · readiness unknown" \
    "missing registration was rendered as a false CI state"
  assert_contains "$unknown_shown" "was never registered" "missing registration has no visible reason"
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

test_decision_projection_labels_answered_and_aged_open_holds() {
  local home fakebin out answered_num answered_shown aged_num aged_shown
  home=$(make_home decision-truth)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 130 --all) || fail "decision truth render failed"
  assert_contains "$out" "DECISIONS (5)" "an open hold or blocker was silently removed"
  assert_contains "$out" "3 need Pedro | 1 stuck" "decision recap omitted local attention"
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
  pass "decision projection keeps every hold while separating actionable, answered-looking, and aged rows"
}

test_clean_list_uses_truthful_markers_and_priority_order() {
  local home fakebin out yellow red blue green unknown yellow_line red_line unknown_line blue_line green_line
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
  assert_contains "$out" "$unknown Ship the review branch" \
    "changes requested without fresh local stuck evidence was overreported as red"
  blue_line=$(line_number_of "$out" "$blue PR 912")
  green_line=$(line_number_of "$out" "$green PR 930")
  [ "$blue_line" -lt "$green_line" ] || fail "progressing sorted ahead of waiting-elsewhere"
  pass "clean list markers survive NO_COLOR and follow attention priority"
}

test_default_rows_are_one_line_with_a_fresh_recap() {
  local home fakebin out title_line
  home=$(make_home interaction-list)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(NO_COLOR=1 render_terminal "$home" "$fakebin" --width 130 --all) \
    || fail "clean-list render failed"
  assert_contains "$out" "ATTENTION NOW" "fresh recap band is absent"
  assert_contains "$out" "3 need Pedro | 1 stuck" "recap did not count fresh local attention"
  assert_contains "$out" "Decide the public API" "recap did not name a current need"
  assert_contains "$out" "+2 more below" "recap truncation hid its remaining-attention count"
  title_line=$(printf '%s\n' "$out" | grep -F "Ship the review branch" | tail -1)
  assert_not_contains "$title_line" "firstmate" "default row includes project detail"
  assert_not_contains "$title_line" "for " "default row includes age detail"
  assert_not_contains "$out" "CI green" "default list leaked status prose"
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
  assert_contains "$shown" "identity: decisions/decision-task/api-shape" \
    "expanded row omitted its stable identity"
  assert_contains "$shown" "current state:" "expanded row omitted current state"
  assert_contains "$shown" "age:" "expanded row omitted age"
  assert_contains "$shown" "blocker/status:" "expanded row omitted concrete blocker or status"
  assert_contains "$shown" "recommendation: Answer the recorded decision" \
    "expanded decision omitted its evidence-derived recommendation"

  unknown_num=$(printf '%s\n' "$out" | grep -F "PR 4002" | tail -1 | awk '{print $1}')
  unknown_shown=$(render_terminal "$home" "$fakebin" --show "$unknown_num") \
    || fail "unknown PR expansion failed"
  assert_contains "$unknown_shown" "recommendation: Register PR 4002" \
    "unknown PR expansion invented a recommendation instead of naming missing registration"
  pass "expanded rows carry full context and evidence-derived recommendations"
}

test_show_expands_rows_with_full_context() {
  local home fakebin out num shown pr_num pr_shown error rc
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

  pr_num=$(printf '%s\n' "$out" | grep -F "Ship the review branch" | head -1 | awk '{print $1}')
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
  assert_contains "$out" "telemetry absent" "missing telemetry was not disclosed"
  assert_contains "$out" "token spend not measured" "missing telemetry implied zero spend"
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

test_html_page_renders_three_sections() {
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
  assert_contains "$html" 'aria-label="needs Pedro"' "page omitted marker semantics"
  assert_contains "$html" 'aria-label="unknown"' "page omitted the unknown marker"
  assert_contains "$html" "Attention now" "page omitted the recap band"
  assert_contains "$html" "github status checked" "github data age missing from the page"
  assert_not_contains "$html" "changes requested" "default HTML list leaked expanded status prose"
  assert_not_contains "$html" "truncated, 90 chars" "CLI truncation artifact leaked into the page"
  assert_not_contains "$html" "https://cdn" "dashboard depends on a CDN"
  pass "HTML page renders the same three sections with gh status and its age"
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

test_cockpit_shows_exactly_three_sections
test_pr_truthfulness_regressions
test_review_relationships_survive_completed_rounds
test_followup_review_without_round_history_stays_unknown
test_decision_projection_labels_answered_and_aged_open_holds
test_clean_list_uses_truthful_markers_and_priority_order
test_default_rows_are_one_line_with_a_fresh_recap
test_expansion_includes_evidence_derived_recommendation
test_show_expands_rows_with_full_context
test_absent_sources_and_unreachable_reviews_stay_honest
test_html_page_renders_three_sections
test_watch_flag_needs_a_terminal_and_stays_exclusive
test_ignored_operational_directories_are_never_output_targets
