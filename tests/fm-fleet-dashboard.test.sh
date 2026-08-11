#!/usr/bin/env bash
# Behavior tests for the fleet cockpit renderer (terminal default, HTML --output).
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
TELEMETRY="$ROOT/bin/fm-model-telemetry.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-dashboard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TRUNCATION_ARTIFACT="(truncated, 90 chars total - use show decision-task --full to see complete text)"

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
target=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-t" ]; then target=$argument; fi
  previous=$argument
done
case "${1:-}" in
  list-windows)
    printf '%s\n' fm-progressing-task fm-decision-task fm-review-task fm-sm-relay fm-opaque-task
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *progressing-task*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

intake_payload() {
  jq -cn '{attemptClass:"real",source:"firstmate",taskRootId:null,parentAttemptId:null,projectRef:"project_0123456789abcdef",taskClass:"bounded-implementation-proven-root-fix",tuple:{harness:"codex",provider:"openai",model:"gpt-5.6-sol",effort:"high",modelVersion:null,cliVersion:null},selection:{matchedRule:"rule-1",configSha256:"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",fitReasons:["task-class"],candidateAssessments:[{tuple:{harness:"codex",provider:"openai",model:"gpt-5.6-sol",effort:"high",modelVersion:null,cliVersion:null},eligibility:"selected",reasons:["class-fit"]}],quota:{decision:"selected",headroom:"sufficient",runway:"sufficient",observedAt:"2026-08-02T00:00:00Z"}},neutralExecution:{correlation:null,capabilityProfile:"not-applicable",owner:"not-applicable",phase:null,behavioralResult:"not-applicable"},evaluation:{kind:"none",fixtureId:null,fixtureManifestSha256:null,oracleId:null,oracleSha256:null,sourceCommit:null},startedAt:"2026-08-02T00:00:00Z",privacy:{classification:"operational-minimized",contentPolicy:"ids-codes-hashes-bounded-evidence-only"}}'
}

write_live_fixture() {  # <home>
  local home=$1 intake attempt root generation decision_generation review_generation
  mkdir -p "$home/projects/progressing" "$home/projects/decision" "$home/projects/unhealthy" \
    "$home/projects/merged" "$home/projects/review" "$home/projects/paused" "$home/projects/opaque"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] progressing-task - Continue implementation (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] decision-task - Decide the public API (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] unhealthy-task - Recover missing endpoint (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] deploy-window - Approve deployment window (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the deployment window.) (hold-kind: captain)
- [ ] hold-oldest - Renew the signing certificate (repo: firstmate) (kind: captain) (since 2026-07-20) (hold: The certificate expires soon.) (hold-kind: captain)
- [ ] hold-two - Approve the pricing page copy (repo: artemis) (kind: captain) (since 2026-07-22) (hold: Marketing wants a yes.) (hold-kind: captain)
- [ ] hold-three - Choose the beta cohort size (repo: artemis) (kind: captain) (since 2026-07-24) (hold: Ten or fifty users.) (hold-kind: captain)
- [ ] hold-four - Confirm the data retention window (repo: artemis) (kind: captain) (since 2026-07-26) (hold: Legal asked for ninety days.) (hold-kind: captain)
- [ ] hold-five - Pick the demo dataset (repo: artemis) (kind: captain) (since 2026-07-28) (hold: Real or synthetic.) (hold-kind: captain)
- [ ] hold-six - Approve the changelog draft (repo: artemis) (kind: captain) (since 2026-07-30) (hold: One paragraph awaits review.) (hold-kind: captain)
- [ ] hold-seven - Sign off on the icon refresh (repo: artemis) (kind: captain) (since 2026-08-01) (hold: Two candidates shortlisted.) (hold-kind: captain)

- [ ] review-task - Ship the review branch (repo: firstmate) (kind: ship) (since 2026-08-01)
- [ ] paused-task - Wait out the vendor limit (repo: firstmate) (kind: ship) (since 2026-08-01)
- [ ] opaque-task - Push the hotfix (repo: firstmate) (kind: ship) (since 2026-08-01)

## Queued
- [ ] queued-task - Ship the follow-up blocked-by: decision-task (repo: firstmate) (kind: ship) (since 2026-07-30)

## Done
- [x] merged-task - Ship the merged thing (repo: firstmate) (kind: ship) (merged 2026-07-31)
EOF

  intake=$(FM_HOME="$home" "$TELEMETRY" intake --state "$home/state" \
    --task progressing-task --payload "$(intake_payload)") || fail "telemetry fixture intake failed"
  attempt=$(printf '%s' "$intake" | jq -r .attemptId)
  root=$(printf '%s' "$intake" | jq -r .taskRootId)

  fm_write_meta "$home/state/progressing-task.meta" \
    "window=firstmate:fm-progressing-task" \
    "worktree=$home/projects/progressing" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "telemetry_attempt=$attempt" \
    "telemetry_task_root=$root"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" progressing-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" progressing-task busy \
    --gen "$generation" --source claude-hook --event user-prompt-submit

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
  decision_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" decision-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" decision-task idle \
    --gen "$decision_generation" --source claude-hook --event stop

  fm_write_meta "$home/state/unhealthy-task.meta" \
    "worktree=$home/projects/unhealthy" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'failed: endpoint disappeared\n' > "$home/state/unhealthy-task.status"

  # Terminal-state and declared-wait workers whose endpoints are legitimately
  # gone: none of the three windows below exist in the fake tmux list.
  fm_write_meta "$home/state/merged-task.meta" \
    "window=firstmate:fm-merged-task" \
    "worktree=$home/projects/merged" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/pedromuller-del/firstmate/pull/3972"
  printf 'done: PR https://github.com/pedromuller-del/firstmate/pull/3972 checks green\n' \
    > "$home/state/merged-task.status"

  fm_write_meta "$home/state/review-task.meta" \
    "window=firstmate:fm-review-task" \
    "worktree=$home/projects/review" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/pedromuller-del/firstmate/pull/4001"
  printf 'done: PR https://github.com/pedromuller-del/firstmate/pull/4001 checks green\n' \
    > "$home/state/review-task.status"
  review_generation=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" review-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" review-task idle \
    --gen "$review_generation" --source claude-hook --event stop

  fm_write_meta "$home/state/paused-task.meta" \
    "window=firstmate:fm-paused-task" \
    "worktree=$home/projects/paused" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'paused: vendor rate limit resets tomorrow\n' > "$home/state/paused-task.status"

  # A live worker whose harness state the reader cannot verify: not evidence
  # of sickness, so it must fold into the quiet unreadable line.
  fm_write_meta "$home/state/opaque-task.meta" \
    "window=firstmate:fm-opaque-task" \
    "worktree=$home/projects/opaque" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: pushing the fix\n' > "$home/state/opaque-task.status"

  # A secondmate's multiplexed log mentioning a historical PR must never mint
  # a review ask: the URL below exists only in status prose, not in metadata.
  fm_write_meta "$home/state/sm-relay.meta" \
    "window=firstmate:fm-sm-relay" \
    "project=firstmate" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=ship" \
    "yolo=off"
  printf 'done: PR https://github.com/pedromuller-del/firstmate/pull/5555 checks green\n' \
    > "$home/state/sm-relay.status"

  # Pin status mtimes so age-in-state is deterministic against FM_SNAPSHOT_NOW.
  TZ=UTC touch -t 202608020000 "$home/state/decision-task.status" "$home/state/unhealthy-task.status" \
    "$home/state/merged-task.status" "$home/state/review-task.status" "$home/state/paused-task.status" \
    "$home/state/sm-relay.status" "$home/state/opaque-task.status"
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

test_terminal_cockpit_opens_on_needs_pedro() {
  local home fakebin out all_out needs underway unhealthy queued decide first_hold total_lines
  home=$(make_home terminal)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 100) || fail "terminal render failed"

  needs=$(line_number_of "$out" "NEEDS PEDRO (10)")
  underway=$(line_number_of "$out" "UNDERWAY (1)")
  unhealthy=$(line_number_of "$out" "UNHEALTHY (1)")
  queued=$(line_number_of "$out" "QUEUED (2)")
  [ -n "$needs" ] || fail "terminal output has no NEEDS PEDRO section counting all ten items"
  [ -n "$underway" ] || fail "terminal output has no UNDERWAY section"
  [ -n "$unhealthy" ] || fail "terminal output has no UNHEALTHY section"
  [ -n "$queued" ] || fail "terminal output has no QUEUED section"
  { [ "$needs" -lt "$underway" ] && [ "$underway" -lt "$unhealthy" ] && [ "$unhealthy" -lt "$queued" ]; } \
    || fail "sections are not ordered Needs Pedro, Underway, Unhealthy, Queued"

  assert_contains "$out" " 1 DECIDE" "rows are not numbered"
  assert_contains "$out" "Choose the public API shape." "open decision was not rendered"
  assert_contains "$out" "[api-shape]" "decision key was not rendered"
  assert_contains "$out" "Decide the public API · firstmate · for 5m" "decision was not rendered under its readable name with age"
  decide=$(line_number_of "$out" "Decide the public API")
  first_hold=$(line_number_of "$out" "Renew the signing certificate")
  [ -n "$decide" ] && [ -n "$first_hold" ] && [ "$decide" -lt "$first_hold" ] \
    || fail "live-worker decision does not outrank the oldest hold"
  assert_contains "$out" "⚠ for 13d" "a 13-day hold got no age warning weight"
  assert_contains "$out" "The certificate expires soon." "oldest hold reason was not rendered"
  assert_contains "$out" "PR (unverified): https://github.com/pedromuller-del/firstmate/pull/4001" \
    "a metadata-recorded PR was not surfaced as an unverified review ask"
  assert_not_contains "$out" "PR ready" "the cockpit asserted PR readiness it cannot verify locally"
  assert_not_contains "$out" "pull/3972" "a merged PR was surfaced as a live review ask"
  assert_not_contains "$out" "Ship the merged thing" "a landed task still occupies a bucket"
  assert_not_contains "$out" "pull/5555" \
    "a PR URL parsed from secondmate status prose minted a review ask"
  assert_contains "$out" "declared wait, worker gone: vendor" \
    "a declared pause with a gone worker was not rendered as a wait"
  assert_contains "$out" "UNREADABLE (1)" "unverifiable harness state did not get its own quiet section"
  assert_contains "$out" "nothing evidences them as bad" "the unreadable fold line does not disclaim sickness"
  assert_not_contains "$out" "Push the hotfix" "an unreadable worker rendered as a full row by default"
  assert_contains "$out" "5 more" "hidden Needs Pedro items were not counted"
  assert_contains "$out" "rule: live asks, PRs, holds, oldest first" "selection rule is not printed on screen"
  assert_contains "$out" "--all shows all" "expansion hint is not printed"
  assert_not_contains "$out" "Sign off on the icon refresh" "low-priority hold leaked past the section cap"
  assert_not_contains "$out" "Pedro must choose the deployment window." "capped-out hold detail still rendered"
  assert_contains "$out" "Recover missing endpoint · firstmate · for 5m" "unhealthy item lost its readable name or age"
  assert_contains "$out" "Continue implementation · firstmate" "working item lost its readable name"
  assert_contains "$out" "codex/gpt-5.6-sol/high" "model tuple was not rendered on the working task"
  assert_contains "$out" "endpoint disappeared" "unhealthy reason was not rendered"
  assert_contains "$out" "Ship the follow-up · firstmate" "queued item lost its readable name"
  assert_contains "$out" "waits on decision-task" "queued blocker was not rendered"
  assert_contains "$out" "for 3d" "queued item age was not rendered"
  assert_contains "$out" "token spend not measured" "unreported spend was not explicit"
  assert_not_contains "$out" "truncated, 90 chars" "CLI truncation artifact leaked into the cockpit"

  total_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$total_lines" -le 40 ] || fail "cockpit does not fit a 40-row terminal: $total_lines lines"

  all_out=$(render_terminal "$home" "$fakebin" --width 100 --all) || fail "terminal --all render failed"
  assert_contains "$all_out" "Sign off on the icon refresh" "--all does not list capped-out items"
  assert_contains "$all_out" "Pedro must choose the deployment window." "--all does not list capped-out hold detail"
  assert_contains "$all_out" "Push the hotfix" "--all does not list unreadable workers"
  assert_not_contains "$all_out" "more · --all shows all" "--all still hides items behind a count line"

  # shellcheck disable=SC2016  # the ${...} below is a node template literal, not shell
  printf '%s' "$out" | node -e '
    let data = "";
    process.stdin.on("data", (chunk) => { data += chunk; });
    process.stdin.on("end", () => {
      const wide = data.split("\n").filter((line) => [...line].length > 100);
      if (wide.length > 0) {
        console.error(`line exceeds width: ${wide[0]}`);
        process.exit(1);
      }
    });
  ' || fail "terminal output overflows the requested width"
  pass "terminal cockpit opens on Needs Pedro with aged, bucketed, artifact-free items"
}

test_show_expands_a_row_with_full_context() {
  local home fakebin out all_out num hidden_num shown hidden_shown error rc
  home=$(make_home show)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")

  out=$(render_terminal "$home" "$fakebin" --width 100) || fail "terminal render failed"
  num=$(printf '%s\n' "$out" | grep -F "Decide the public API" | head -1 | awk '{print $1}')
  [ -n "$num" ] || fail "could not read the decision row's number from the default view"

  shown=$(render_terminal "$home" "$fakebin" --show "$num") || fail "--show $num failed"
  assert_contains "$shown" "NEEDS PEDRO · DECIDE" "expanded row does not name its bucket and tag"
  assert_contains "$shown" "Decide the public API" "expanded row lost its full title"
  assert_contains "$shown" "Choose the public API shape." "expanded row lost its full reason"
  assert_contains "$shown" "age: for 5m" "expanded row lost its age"
  assert_contains "$shown" "why here: open needs-decision in the keyed decision fold" \
    "expanded row does not explain why it landed in its bucket"
  assert_contains "$shown" "task decision-task · project firstmate" "expanded row lost its identity"
  assert_contains "$shown" "recent events" "expanded row does not show its status events"
  assert_contains "$shown" "needs-decision [key=api-shape]" "expanded row lost the recorded event"

  all_out=$(render_terminal "$home" "$fakebin" --width 100 --all) || fail "terminal --all render failed"
  hidden_num=$(printf '%s\n' "$all_out" | grep -F "Sign off on the icon refresh" | head -1 | awk '{print $1}')
  [ -n "$hidden_num" ] || fail "could not read a capped-out row's number from --all"
  hidden_shown=$(render_terminal "$home" "$fakebin" --show "$hidden_num") || fail "--show $hidden_num failed"
  assert_contains "$hidden_shown" "Two candidates shortlisted." "a capped-out hold cannot be expanded"
  assert_contains "$hidden_shown" "captain hold with no unresolved blockers" \
    "a hold's expansion does not explain its routing"

  set +e
  error=$(render_terminal "$home" "$fakebin" --show 99 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--show accepted an out-of-range row"
  assert_contains "$error" "no such row" "out-of-range --show refusal is not actionable"
  pass "any numbered row expands to its full context and bad numbers refuse loudly"
}

test_html_page_renders_four_buckets() {
  local home fakebin output html
  home=$(make_home html)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  output="$home/fleet-dashboard.html"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "dashboard render failed"
  html=$(<"$output")

  assert_contains "$html" 'id="needs-pedro"' "page omitted the Needs Pedro section"
  assert_contains "$html" 'id="underway"' "page omitted the Underway section"
  assert_contains "$html" 'id="unhealthy"' "page omitted the Unhealthy section"
  assert_contains "$html" 'id="queued"' "page omitted the Queued section"
  assert_contains "$html" "Approve deployment window" "captain hold was not rendered"
  assert_contains "$html" "Choose the public API shape." "classified status decision was not rendered"
  assert_contains "$html" "for 5m" "age-in-state was not rendered"
  assert_contains "$html" "Token spend</span><strong>Not measured</strong>" "unreported spend was not explicit"
  assert_not_contains "$html" "truncated, 90 chars" "CLI truncation artifact leaked into the page"
  assert_not_contains "$html" "Estimated spend" "dashboard estimated token spend"
  assert_not_contains "$html" "https://cdn" "dashboard depends on a CDN"
  pass "HTML page renders the same four buckets with ages from live-source fixtures"
}

test_absent_sources_stay_absent() {
  local home out output html
  home=$(make_home absent)

  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z "$DASHBOARD" --width 80) \
    || fail "absent-source terminal render failed"
  assert_contains "$out" "backlog absent" "missing backlog was not disclosed in the cockpit"
  assert_contains "$out" "telemetry absent" "missing telemetry was not disclosed in the cockpit"
  assert_contains "$out" "token spend not measured" "missing telemetry implied zero spend"
  assert_contains "$out" "captain holds unknown" "absent backlog rendered as an empty Needs Pedro"

  output="$home/fleet-dashboard.html"
  FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "absent-source dashboard render failed"
  html=$(<"$output")

  assert_contains "$html" "Backlog source</span><strong>Absent</strong>" "missing backlog rendered as zero"
  assert_contains "$html" "Model telemetry</span><strong>Absent</strong>" "missing telemetry rendered as zero"
  assert_contains "$html" "Token spend</span><strong>Not measured</strong>" "missing telemetry implied zero spend"
  pass "missing backlog and telemetry render as absent rather than zero in both outputs"
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

test_terminal_cockpit_opens_on_needs_pedro
test_show_expands_a_row_with_full_context
test_html_page_renders_four_buckets
test_absent_sources_stay_absent
test_ignored_operational_directories_are_never_output_targets
