#!/usr/bin/env bash
# tests/fm-repository-intake.test.sh - daily GitHub intake checkpoint, evidence,
# authority, untrusted-input, pagination, and existing-watcher wake guarantees.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-repository-intake.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-repository-intake)

make_home() { # <fixture-name> <registry-mode> [project-name]
  local mode=$2 name=${3:-alpha} home="$TMP_ROOT/$1-home" repo
  repo="$home/projects/$name"
  mkdir -p "$home/data" "$home/state" "$home/config" "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "https://github.com/example/$name.git"
  printf -- '- %s [%s] - test project\n' "$name" "$mode" > "$home/data/projects.md"
  printf '%s\n' "$home"
}

make_fake_gh() { # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_GH_LOG:?}"
scenario=${FM_FAKE_SCENARIO:-base}
args=$*
kind=issue
case "$args" in *pullRequests*) kind=pr ;; esac

if [ "$scenario" = failure ] || { [ "$scenario" = partial ] && [[ "$args" == *name=alpha* ]]; }; then
  echo 'simulated unavailable response with ghp_abcdefghijklmnopqrstuvwxyz' >&2
  exit 1
fi

if [ "$scenario" = pr_failure ] && [[ "$args" == *name=alpha* ]] && [[ "$args" == *pullRequests* ]]; then
  echo 'simulated unavailable response with ghp_abcdefghijklmnopqrstuvwxyz' >&2
  exit 1
fi

page=false
case "$args" in *cursor=CURSOR_ONE*) page=true ;; esac

if [ "$scenario" = pagination ] && [ "$kind" = issue ] && [ "$page" = false ]; then
  cat <<'EOF'
data:
  repository:
    issues:
      nodes[1]:
        - number: 1
          title: "First page"
          updatedAt: "2026-07-20T00:00:00Z"
          url: "https://github.com/example/alpha/issues/1"
          labels:
            nodes: []
      pageInfo:
        hasNextPage: true
        endCursor: "CURSOR_ONE"
  rateLimit:
    remaining: 5000
    resetAt: "2026-07-23T00:00:00Z"
    cost: 1
EOF
  exit 0
fi

if [ "$scenario" = pagination ] && [ "$kind" = issue ]; then
  cat <<'EOF'
data:
  repository:
    issues:
      nodes[1]:
        - number: 2
          title: "Second page"
          updatedAt: "2026-07-20T01:00:00Z"
          url: "https://github.com/example/alpha/issues/2"
          labels:
            nodes: []
      pageInfo:
        hasNextPage: false
        endCursor: null
  rateLimit:
    remaining: 4999
    resetAt: "2026-07-23T00:00:00Z"
    cost: 1
EOF
  exit 0
fi

if [ "$scenario" = authority ] && [ "$kind" = issue ]; then
  cat <<'EOF'
data:
  repository:
    issues:
      nodes: []
      pageInfo:
        hasNextPage: false
        endCursor: null
  rateLimit:
    remaining: 5000
    resetAt: "2026-07-23T00:00:00Z"
    cost: 1
EOF
  exit 0
fi

if [ "$scenario" = authority ] && [ "$kind" = pr ]; then
  cat <<'EOF'
data:
  repository:
    pullRequests:
      nodes[2]:
        - number: 10
          title: "Routine copy change"
          updatedAt: "2026-07-20T02:00:00Z"
          url: "https://github.com/example/alpha/pull/10"
          isDraft: false
          headRefOid: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          baseRefName: "main"
          labels:
            nodes: []
          reviewDecision: "APPROVED"
        - number: 11
          title: "Deploy credential security fix"
          updatedAt: "2026-07-20T03:00:00Z"
          url: "https://github.com/example/alpha/pull/11"
          isDraft: false
          headRefOid: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
          baseRefName: "main"
          labels:
            nodes[1]:
              - name: "security"
          reviewDecision: "APPROVED"
      pageInfo:
        hasNextPage: false
        endCursor: null
  rateLimit:
    remaining: 4999
    resetAt: "2026-07-23T00:00:00Z"
    cost: 1
EOF
  exit 0
fi

if [ "$kind" = issue ]; then
  issue_title='Issue one'
  issue_updated='2026-07-20T00:00:00Z'
  if [ "$scenario" = changed ]; then
    issue_title='Issue one changed'
    issue_updated='2026-07-21T00:00:00Z'
  elif [ "$scenario" = untrusted ]; then
    issue_title='$(touch /tmp/must-not-run) token=sk-abcdefghijklmnopqrstuvwxyz'
  fi
  printf '%s\n' \
    'data:' \
    '  repository:' \
    '    issues:' \
    '      nodes[1]:' \
    '        - number: 1' \
    "          title: \"$issue_title\"" \
    "          updatedAt: \"$issue_updated\"" \
    '          url: "https://github.com/example/alpha/issues/1"' \
    '          labels:' \
    '            nodes[1]:' \
    '              - name: "bug"' \
    '      pageInfo:' \
    '        hasNextPage: false' \
    '        endCursor: null' \
    '  rateLimit:' \
    '    remaining: 5000' \
    '    resetAt: "2026-07-23T00:00:00Z"' \
    '    cost: 1'
else
  head='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  updated='2026-07-20T02:00:00Z'
  if [ "$scenario" = changed ]; then
    head='cccccccccccccccccccccccccccccccccccccccc'
    updated='2026-07-21T02:00:00Z'
  fi
  printf '%s\n' \
    'data:' \
    '  repository:' \
    '    pullRequests:' \
    '      nodes[1]:' \
    '        - number: 10' \
    '          title: "Routine change"' \
    "          updatedAt: \"$updated\"" \
    '          url: "https://github.com/example/alpha/pull/10"' \
    '          isDraft: false' \
    "          headRefOid: \"$head\"" \
    '          baseRefName: "main"' \
    '          labels:' \
    '            nodes: []' \
    '          reviewDecision: null' \
    '      pageInfo:' \
    '        hasNextPage: false' \
    '        endCursor: null' \
    '  rateLimit:' \
    '    remaining: 4999' \
    '    resetAt: "2026-07-23T00:00:00Z"' \
    '    cost: 1'
fi
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

run_intake() { # <home> <fakebin> <scenario> <now> [args...]
  local home=$1 fakebin=$2 scenario=$3 now=$4
  shift 4
  FM_HOME="$home" FM_GH_AXI="$fakebin/gh-axi" FM_FAKE_GH_LOG="$home/gh.log" \
    FM_FAKE_SCENARIO="$scenario" "$INTAKE" --now "$now" "$@"
}

test_kolkata_rollover_and_restart_dedup() {
  local home fakebin out calls
  home=$(make_home rollover 'no-mistakes')
  fakebin=$(make_fake_gh "$home")
  out=$(run_intake "$home" "$fakebin" base '2026-07-21T18:29:59Z' --json) || fail "first daily intake failed"
  printf '%s' "$out" | jq -e '.calendar_day == "2026-07-21" and .source_scope.observed_projects == 1' >/dev/null || fail "first Kolkata day was incorrect"
  calls=$(wc -l < "$home/gh.log" | tr -d ' ')
  [ "$calls" -eq 2 ] || fail "first run should make one issue and one PR request"

  run_intake "$home" "$fakebin" base '2026-07-21T18:29:59Z' --json >/dev/null || fail "same-day restart failed"
  [ "$(wc -l < "$home/gh.log" | tr -d ' ')" -eq 2 ] || fail "same-day restart duplicated GitHub discovery"

  out=$(run_intake "$home" "$fakebin" base '2026-07-21T18:30:00Z' --json) || fail "Kolkata rollover refresh failed"
  printf '%s' "$out" | jq -e '.calendar_day == "2026-07-22" and .checkpoint.last_success.day == "2026-07-22"' >/dev/null || fail "Kolkata midnight did not trigger the next daily run"
  [ "$(wc -l < "$home/gh.log" | tr -d ' ')" -eq 4 ] || fail "Kolkata rollover did not make exactly one new daily discovery"
  pass "Asia/Kolkata rollover refreshes once and duplicate processes reuse the durable checkpoint"
}

test_pagination_and_changed_issue_pr() {
  local home fakebin out
  home=$(make_home changed 'no-mistakes')
  fakebin=$(make_fake_gh "$home")
  out=$(run_intake "$home" "$fakebin" pagination '2026-07-22T00:00:00Z' --json) || fail "paginated discovery failed"
  printf '%s' "$out" | jq -e '.categories.newly_discovered | map(select(.type == "issue")) | length == 2' >/dev/null || fail "all paginated issues were not discovered"
  grep -F 'cursor=CURSOR_ONE' "$home/gh.log" >/dev/null || fail "pagination cursor was not followed"

  rm -f "$home/data/repository-intake/checkpoint.json"
  : > "$home/gh.log"
  run_intake "$home" "$fakebin" base '2026-07-22T00:00:00Z' --json >/dev/null || fail "baseline discovery failed"
  out=$(run_intake "$home" "$fakebin" changed '2026-07-22T01:00:00Z' --refresh --json) || fail "changed discovery failed"
  printf '%s' "$out" | jq -e '
    ([.categories.newly_discovered[] | select(.attention_reason == "source_changed")] | length) == 2
    and ([.categories.newly_discovered[] | select(.type == "pr") | .source_fingerprint] | length) == 1
  ' >/dev/null || fail "changed issue and PR did not reset to evidence-required attention"
  pass "pagination is exhaustive and changed issue/PR evidence invalidates stale judgments"
}

test_api_failure_fails_closed() {
  local home fakebin out
  home=$(make_home failure 'no-mistakes')
  fakebin=$(make_fake_gh "$home")
  run_intake "$home" "$fakebin" base '2026-07-21T00:00:00Z' --json >/dev/null || fail "baseline discovery failed"
  out=$(run_intake "$home" "$fakebin" failure '2026-07-22T00:00:00Z' --json) || fail "failed source should still emit structured unknown state"
  printf '%s' "$out" | jq -e '
    .checkpoint.last_attempt.status == "failed"
    and .checkpoint.last_attempt.error_code == "API_UNAVAILABLE"
    and .checkpoint.freshness == "stale"
    and .attention.highest_severity == "critical"
    and (.categories.newly_discovered | length) == 2
  ' >/dev/null || fail "API failure erased prior evidence or claimed freshness"
  grep -F 'ghp_abcdefghijklmnopqrstuvwxyz' "$home/data/repository-intake/checkpoint.json" >/dev/null && fail "API stderr secret escaped into the checkpoint"
  pass "source failure preserves prior evidence and fails closed as stale critical attention"
}

test_pr_failure_retains_issue_observations() {
  local home fakebin out
  home=$(make_home pr-failure 'no-mistakes')
  fakebin=$(make_fake_gh "$home")
  out=$(run_intake "$home" "$fakebin" pr_failure '2026-07-22T00:00:00Z' --json) || fail "PR-side failure should still emit structured state"
  printf '%s' "$out" | jq -e '
    .checkpoint.last_attempt.status == "failed"
    and ([.categories.newly_discovered[] | select(.type == "issue")] | length == 1)
  ' >/dev/null || fail "issue observations were dropped when the PR request failed"
  pass "issue observations survive PR-side GraphQL failure"
}

test_one_repository_failure_does_not_hide_the_rest() {
  local home fakebin out project repo
  home="$TMP_ROOT/multi-home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  for project in alpha beta; do
    repo="$home/projects/$project"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" remote add origin "https://github.com/example/$project.git"
  done
  printf '%s\n' \
    '- alpha [no-mistakes] - first project' \
    '- beta [no-mistakes] - second project' > "$home/data/projects.md"
  fakebin=$(make_fake_gh "$home")
  out=$(run_intake "$home" "$fakebin" partial '2026-07-22T00:00:00Z' --json) || fail "partial source run did not emit structured state"
  printf '%s' "$out" | jq -e '
    .checkpoint.last_attempt.status == "failed"
    and (.source_scope.projects[] | select(.id == "alpha") | .status) == "unavailable"
    and (.source_scope.projects[] | select(.id == "beta") | .status) == "observed"
  ' >/dev/null || fail "one repository failure hid a later registered repository"
  grep -F 'name=alpha' "$home/gh.log" >/dev/null || fail "failed repository was not attempted"
  grep -F 'name=beta' "$home/gh.log" >/dev/null || fail "later registered repository was not attempted"
  pass "one repository failure remains loud without preventing observation of later registered repositories"
}

test_untrusted_content_is_data_and_secrets_are_redacted() {
  local home fakebin out checkpoint
  home=$(make_home untrusted 'no-mistakes')
  fakebin=$(make_fake_gh "$home")
  rm -f /tmp/must-not-run
  out=$(run_intake "$home" "$fakebin" untrusted '2026-07-22T00:00:00Z' --json) || fail "untrusted-content discovery failed"
  checkpoint="$home/data/repository-intake/checkpoint.json"
  [ ! -e /tmp/must-not-run ] || fail "untrusted issue title was executed"
  grep -F 'sk-abcdefghijklmnopqrstuvwxyz' "$checkpoint" >/dev/null && fail "secret-like issue text was retained"
  printf '%s' "$out" | jq -e '.categories.newly_discovered[] | select(.type == "issue") | .title | contains("[REDACTED]")' >/dev/null || fail "secret-like issue text was not visibly redacted"
  grep -F 'body' "$home/gh.log" >/dev/null && fail "GitHub request asked for untrusted body content"
  pass "issue text remains inert allowlisted data and secret-like values are redacted"
}

write_pr_outcome() { # <file> <item-json>
  local file=$1 item_json=$2
  jq -n --arg id "$(printf '%s' "$item_json" | jq -r .id)" \
    --arg fingerprint "$(printf '%s' "$item_json" | jq -r .source_fingerprint)" \
    '{schema:"fm-repository-intake-outcome.v1",item_id:$id,source_fingerprint:$fingerprint,status:"pr_ready_or_merged",disposition:"pr_ready",checks_green:true,evidence:[{source:"GitHub checks",pointer:"https://github.com/example/alpha/actions/runs/1",observed_at:"2026-07-22T00:01:00Z",claim:"required checks passed"}],risk:{}}' > "$file"
}

test_yolo_is_routine_only() {
  local home fakebin out safe sensitive
  home=$(make_home authority 'no-mistakes +yolo')
  fakebin=$(make_fake_gh "$home")
  out=$(run_intake "$home" "$fakebin" authority '2026-07-22T00:00:00Z' --json) || fail "authority fixture discovery failed"
  safe=$(printf '%s' "$out" | jq -c '.categories.newly_discovered[] | select(.number == 10)')
  sensitive=$(printf '%s' "$out" | jq -c '.categories.newly_discovered[] | select(.number == 11)')
  write_pr_outcome "$home/safe.json" "$safe"
  write_pr_outcome "$home/sensitive.json" "$sensitive"
  run_intake "$home" "$fakebin" authority '2026-07-22T00:02:00Z' --record-outcome "$home/safe.json" --json >/dev/null || fail "safe PR outcome failed"
  out=$(run_intake "$home" "$fakebin" authority '2026-07-22T00:03:00Z' --record-outcome "$home/sensitive.json" --json) || fail "sensitive PR outcome failed"
  printf '%s' "$out" | jq -e '
    (.categories.pr_ready_or_merged[] | select(.number == 10) | .authority) == "routine_autonomy"
    and (.categories.pr_ready_or_merged[] | select(.number == 11) | .authority) == "captain_required"
    and (.categories.pr_ready_or_merged[] | select(.number == 11) | .sensitive) == true
  ' >/dev/null || fail "+yolo granted sensitive authority or withheld routine authority"
  pass "+yolo permits only routine green handling and sensitive metadata can only restrict authority"
}

test_issue_outcomes_reject_pr_only_status() {
  local home fakebin out issue file err status=0
  home=$(make_home issue-status 'no-mistakes')
  fakebin=$(make_fake_gh "$home")
  out=$(run_intake "$home" "$fakebin" base '2026-07-22T00:00:00Z' --json) || fail "issue discovery failed"
  issue=$(printf '%s' "$out" | jq -c '.categories.newly_discovered[] | select(.type == "issue")')
  file="$home/issue-outcome.json"
  err="$home/issue-outcome.err"
  jq -n --arg id "$(printf '%s' "$issue" | jq -r .id)" \
    --arg fingerprint "$(printf '%s' "$issue" | jq -r .source_fingerprint)" \
    '{schema:"fm-repository-intake-outcome.v1",item_id:$id,source_fingerprint:$fingerprint,status:"pr_ready_or_merged",disposition:"pr_ready",checks_green:true,evidence:[{source:"GitHub checks",pointer:"https://github.com/example/alpha/actions/runs/1",observed_at:"2026-07-22T00:01:00Z",claim:"required checks passed"}],risk:{}}' > "$file"
  run_intake "$home" "$fakebin" base '2026-07-22T00:02:00Z' --record-outcome "$file" --json > /dev/null 2> "$err" || status=$?
  [ "$status" -ne 0 ] || fail "issue outcome accepted a PR-only status"
  assert_contains "$(cat "$err")" 'pr_ready_or_merged only applies to pull requests' "issue outcome rejection did not explain the PR-only guard"
  pass "issue outcomes reject PR-only terminal status"
}

wait_for_exit() { # <pid> <ticks>
  local pid=$1 ticks=$2 i=0
  while [ "$i" -lt "$ticks" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_existing_watcher_wake_is_restart_safe() {
  local home fakebin out1 out2 pid1 pid2 count before
  home=$(make_home watcher 'no-mistakes')
  fakebin=$(make_fake_gh "$home")
  out1="$home/watch-one.out"
  out2="$home/watch-two.out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_GH_AXI="$fakebin/gh-axi" FM_FAKE_GH_LOG="$home/gh.log" FM_FAKE_SCENARIO=base FM_REPOSITORY_INTAKE_NOW='2026-07-22T00:00:00Z' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 "$WATCH" > "$out1" &
  pid1=$!
  wait_for_exit "$pid1" 80 || { kill "$pid1" 2>/dev/null || true; fail "repository intake did not wake the existing watcher"; }
  wait "$pid1" 2>/dev/null || true
  assert_contains "$(cat "$out1")" 'check: repository-intake:' "watcher did not name repository intake"
  count=$(awk -F '\t' '$3 == "check" && $4 == "repository-intake" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$count" -eq 1 ] || fail "first discovery should enqueue exactly one intake wake"
  before=$(wc -l < "$home/gh.log" | tr -d ' ')

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_GH_AXI="$fakebin/gh-axi" FM_FAKE_GH_LOG="$home/gh.log" FM_FAKE_SCENARIO=base FM_REPOSITORY_INTAKE_NOW='2026-07-22T00:00:00Z' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 "$WATCH" > "$out2" &
  pid2=$!
  if wait_for_exit "$pid2" 30; then
    wait "$pid2" 2>/dev/null || true
    fail "watcher restart re-surfaced unchanged repository intake"
  fi
  kill "$pid2" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  count=$(awk -F '\t' '$3 == "check" && $4 == "repository-intake" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$count" -eq 1 ] || fail "watcher restart duplicated the intake wake"
  [ "$(wc -l < "$home/gh.log" | tr -d ' ')" -eq "$before" ] || fail "watcher restart duplicated same-day GitHub requests"
  [ ! -e "$home/state/alpha.meta" ] || fail "repository intake dispatched work instead of waking Firstmate"
  pass "existing watcher queues one durable attention event without duplicate discovery or dispatch"
}

test_kolkata_rollover_and_restart_dedup
test_pagination_and_changed_issue_pr
test_api_failure_fails_closed
test_pr_failure_retains_issue_observations
test_one_repository_failure_does_not_hide_the_rest
test_untrusted_content_is_data_and_secrets_are_redacted
test_yolo_is_routine_only
test_issue_outcomes_reject_pr_only_status
test_existing_watcher_wake_is_restart_safe
