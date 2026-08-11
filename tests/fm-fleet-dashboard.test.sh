#!/usr/bin/env bash
# Behavior tests for the generated self-contained fleet dashboard.
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
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

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
    printf '%s\n' fm-progressing-task fm-decision-task
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
  local home=$1 intake attempt root generation decision_generation
  mkdir -p "$home/projects/progressing" "$home/projects/decision" "$home/projects/unhealthy"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] progressing-task - Continue implementation (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] decision-task - Decide the public API (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] unhealthy-task - Recover missing endpoint (repo: firstmate) (kind: ship) (since 2026-08-02)
- [ ] deploy-window - Approve deployment window (repo: firstmate) (kind: captain) (since 2026-08-02) (hold: Pedro must choose the deployment window.) (hold-kind: captain)

## Queued

## Done
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
  printf 'needs-decision [key=api-shape]: Choose the public API shape.\n' > "$home/state/decision-task.status"
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
}

test_dashboard_answers_the_four_fleet_questions() {
  local home fakebin output html
  home=$(make_home live)
  write_live_fixture "$home"
  fakebin=$(make_fakebin "$home")
  output="$home/fleet-dashboard.html"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "dashboard render failed"
  html=$(<"$output")

  assert_contains "$html" 'id="needs-pedro"' "dashboard omitted the Pedro-action section"
  assert_contains "$html" "Approve deployment window" "tasks-axi captain hold was not rendered"
  assert_contains "$html" "Choose the public API shape." "classified status decision was not rendered"
  assert_contains "$html" 'id="progressing"' "dashboard omitted the autonomous-progress section"
  assert_contains "$html" "progressing-task" "working task was not rendered as progressing"
  assert_contains "$html" 'id="unhealthy"' "dashboard omitted the unhealthy section"
  assert_contains "$html" "unhealthy-task" "unknown task was not rendered as unhealthy"
  assert_contains "$html" 'id="runtime"' "dashboard omitted the runtime section"
  assert_contains "$html" "Running for 5m" "telemetry start time was not used for runtime"
  assert_contains "$html" "Token spend</span><strong>Not measured</strong>" "unreported spend was not explicit"
  assert_not_contains "$html" "Estimated spend" "dashboard estimated token spend"
  assert_not_contains "$html" "https://cdn" "dashboard depends on a CDN"
  pass "dashboard answers Pedro, progress, health, and runtime from live-source fixtures"
}

test_absent_sources_stay_absent() {
  local home output html
  home=$(make_home absent)
  output="$home/fleet-dashboard.html"

  FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-02T00:05:00Z \
    "$DASHBOARD" --output "$output" || fail "absent-source dashboard render failed"
  html=$(<"$output")

  assert_contains "$html" "Backlog source</span><strong>Absent</strong>" "missing backlog rendered as zero"
  assert_contains "$html" "Model telemetry</span><strong>Absent</strong>" "missing telemetry rendered as zero"
  assert_contains "$html" "Token spend</span><strong>Not measured</strong>" "missing telemetry implied zero spend"
  pass "missing backlog and telemetry render as absent rather than zero"
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

test_dashboard_answers_the_four_fleet_questions
test_absent_sources_stay_absent
test_ignored_operational_directories_are_never_output_targets
