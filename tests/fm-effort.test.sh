#!/usr/bin/env bash
# Behavior tests for bin/fm-effort.sh.
#
# These cases pin the first delivery-control-surface reducer slice:
#   (a) folding an append-only ledger returns the latest stage per effort.
#   (b) terminal transitions are compare-and-set protected.
#   (c) read-only ingest is idempotent by source content hash.
#   (d) stale in-flight backlog rows with no live meta are flagged.
#   (e) Lindy inventory rows are filtered and classified for the work board.
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EFFORT="$ROOT/bin/fm-effort.sh"
TMP_ROOT=$(fm_test_tmproot fm-effort)

run_effort() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_EFFORTS_DIR_OVERRIDE="$case_dir/data/efforts" \
    FM_EFFORT_NOW=2026-07-16T18:00:00Z \
    "$EFFORT" "$@"
}

make_fake_tasks_axi() {  # <case-dir>
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list)
    cat <<'EOF'
count: 2 of 2 total
tasks[2]{id,state,kind,repo,title,blocked,blocked_by,created,closed,links,priority}:
  live-task,in_flight,ship,firstmate,"live row",no,none,2026-07-16,"-",none,"-"
  stale-task,in_flight,ship,firstmate,"stale row",no,none,2026-07-16,"-",none,"-"
help[1]:
  - Run `tasks-axi show <id>` for full notes on a task
EOF
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

case_fold_latest_stage() {
  local d out stage count
  d="$TMP_ROOT/fold"
  mkdir -p "$d"
  run_effort "$d" emit --effort-id alpha --to-stage intake --note "accepted" >/dev/null
  run_effort "$d" emit --effort-id alpha --to-stage in_progress --note "started" >/dev/null
  out=$(run_effort "$d" list --json)
  stage=$(printf '%s\n' "$out" | jq -r '.[] | select(.effort_id=="alpha") | .stage')
  count=$(printf '%s\n' "$out" | jq -r '.[] | select(.effort_id=="alpha") | .events_count')
  [ "$stage" = in_progress ] || fail "fold returns latest stage"
  [ "$count" = 2 ] || fail "fold tracks event count"
  pass "fold returns current state per effort"
}

case_terminal_cas_rejects_double_terminal() {
  local d output code
  d="$TMP_ROOT/cas"
  mkdir -p "$d"
  run_effort "$d" emit --effort-id alpha --to-stage in_progress --note "started" >/dev/null
  run_effort "$d" emit --effort-id alpha --from-stage in_progress --to-stage "done" --note "complete" >/dev/null
  set +e
  output=$(run_effort "$d" emit --effort-id alpha --to-stage abandoned --note "second terminal" 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" "double terminal exits non-zero"
  assert_contains "$output" "terminal CAS rejected" "double terminal explains CAS rejection"
  pass "terminal transitions reject double-terminal writes"
}

case_state_ingest_idempotent() {
  local d home out lines
  d="$TMP_ROOT/ingest"
  home="$d/source-home"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/live-task.meta" \
    "window=firstmate:fm-live-task" \
    "worktree=$home/projects/live-task" \
    "harness=codex" \
    "kind=ship"
  printf 'working: implementation started\n' > "$home/state/live-task.status"
  out=$(run_effort "$d" ingest state --home "$home")
  assert_contains "$out" "emitted=1 skipped=0" "first ingest emits one event"
  out=$(run_effort "$d" ingest state --home "$home")
  assert_contains "$out" "emitted=0 skipped=1" "second ingest skips same content hash"
  lines=$(wc -l < "$d/data/efforts/ledger.jsonl" | tr -d '[:space:]')
  [ "$lines" = 1 ] || fail "idempotent ingest wrote $lines ledger lines, expected 1"
  pass "state ingest is idempotent by content hash"
}

case_reconcile_flags_missing_meta() {
  local d home fakebin out count effort
  d="$TMP_ROOT/reconcile"
  home="$d/source-home"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/live-task.meta" "window=firstmate:fm-live-task" "harness=codex"
  fakebin=$(make_fake_tasks_axi "$d")
  out=$(PATH="$fakebin:$PATH" run_effort "$d" reconcile --home "$home" --json)
  count=$(printf '%s\n' "$out" | jq 'length')
  effort=$(printf '%s\n' "$out" | jq -r '.[0].effort_id')
  [ "$count" = 1 ] || fail "expected one stale row, got $count: $out"
  [ "$effort" = stale-task ] || fail "expected stale-task, got $effort"
  assert_contains "$out" "missing $home/state/stale-task.meta" "reconcile includes missing-meta evidence"
  pass "reconcile flags in-flight rows with no live meta"
}

case_inventory_filters_and_classifies_work_board_rows() {
  local d inventory out rows ci_stage stale_stage landed_stage count
  d="$TMP_ROOT/inventory"
  mkdir -p "$d"
  inventory="$d/inventory.json"
  cat > "$inventory" <<'JSON'
{
  "items": [
    {
      "logicalId": "lindy-ai/lindy#ci-pending",
      "title": "CI pending PR",
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/1",
          "lifecycle": "open ready-for-review",
          "ci": {"state": "pending"}
        }
      ],
      "blockers": ["https://github.com/lindy-ai/lindy/pull/1: CI pending: Graphite / mergeability_check"],
      "exactCaptainAction": "Tim review requested; wait for pending checks/mergeability unless captain chooses early review"
    },
    {
      "logicalId": "REL-DONE",
      "title": "Completed Linear row",
      "linear": [
        {
          "url": "https://linear.app/getlindy/issue/REL-DONE/completed",
          "stateType": "completed"
        }
      ],
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/2",
          "lifecycle": "open ready-for-review"
        }
      ]
    },
    {
      "logicalId": "REL-DUP",
      "title": "Duplicate Linear row",
      "linear": [
        {
          "url": "https://linear.app/getlindy/issue/REL-DUP/duplicate",
          "stateType": "started",
          "state": {"name": "Duplicate", "type": "started"}
        }
      ],
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/20",
          "lifecycle": "open ready-for-review"
        }
      ]
    },
    {
      "logicalId": "lindy-ai/lindy#old-merged",
      "title": "Old merged PR",
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/3",
          "lifecycle": "merged 2026-07-01T00:00:00Z"
        }
      ]
    },
    {
      "logicalId": "lindy-ai/lindy#recent-merged",
      "title": "Recent merged PR",
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/4",
          "lifecycle": "merged 2026-07-16T17:00:00Z"
        }
      ]
    },
    {
      "logicalId": "lindy-ai/lindy#closed-unmerged",
      "title": "Closed unmerged PR",
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/5",
          "lifecycle": "closed unmerged 2026-07-16T17:00:00Z"
        }
      ]
    },
    {
      "logicalId": "twaldin/personal#1",
      "title": "Personal repo PR",
      "prs": [
        {
          "url": "https://github.com/twaldin/personal/pull/1",
          "lifecycle": "open ready-for-review"
        }
      ]
    },
    {
      "logicalId": "ONC-40",
      "title": "Stale requested changes",
      "linear": [
        {
          "url": "https://linear.app/getlindy/issue/ONC-40/review-fix",
          "stateType": "started"
        }
      ],
      "prs": [
        {
          "url": "https://github.com/lindy-ai/lindy/pull/7",
          "lifecycle": "open ready-for-review",
          "review": {"decision": "CHANGES_REQUESTED"}
        }
      ],
      "blockers": ["https://github.com/lindy-ai/lindy/pull/7: CHANGES_REQUESTED by marvtub"],
      "updatedAt": "2026-07-15T17:00:00Z"
    }
  ]
}
JSON
  out=$(run_effort "$d" ingest inventory --repo-allowlist "lindy-ai/*" "$inventory")
  assert_contains "$out" "emitted=3 skipped=0" "filtered inventory emits only live work rows"
  rows=$(run_effort "$d" list --json)
  ci_stage=$(printf '%s\n' "$rows" | jq -r '.[] | select(.effort_id=="lindy-ai/lindy#ci-pending") | .stage')
  stale_stage=$(printf '%s\n' "$rows" | jq -r '.[] | select(.effort_id=="ONC-40") | .stage')
  landed_stage=$(printf '%s\n' "$rows" | jq -r '.[] | select(.effort_id=="lindy-ai/lindy#recent-merged") | .stage')
  [ "$ci_stage" = in_review ] || fail "CI-pending row should be in_review, got $ci_stage"
  [ "$stale_stage" = blocked ] || fail "stale CHANGES_REQUESTED row should be blocked, got $stale_stage"
  [ "$landed_stage" = "done" ] || fail "recent merged PR should be kept as done, got $landed_stage"
  count=$(printf '%s\n' "$rows" | jq '[.[] | select(.effort_id=="REL-DONE")] | length')
  [ "$count" = 0 ] || fail "completed Linear row should be skipped"
  count=$(printf '%s\n' "$rows" | jq '[.[] | select(.effort_id=="REL-DUP")] | length')
  [ "$count" = 0 ] || fail "Duplicate Linear state-name row should be skipped"
  count=$(printf '%s\n' "$rows" | jq '[.[] | select(.effort_id=="lindy-ai/lindy#old-merged")] | length')
  [ "$count" = 0 ] || fail "old merged PR-only row should be skipped"
  count=$(printf '%s\n' "$rows" | jq '[.[] | select(.effort_id=="lindy-ai/lindy#closed-unmerged")] | length')
  [ "$count" = 0 ] || fail "closed-unmerged PR-only row should be skipped"
  count=$(printf '%s\n' "$rows" | jq '[.[] | select(.effort_id=="twaldin/personal#1")] | length')
  [ "$count" = 0 ] || fail "repo allowlist should skip personal repo rows"
  pass "inventory ingest filters and classifies work-board rows"
}

case_fold_latest_stage
case_terminal_cas_rejects_double_terminal
case_state_ingest_idempotent
case_reconcile_flags_missing_meta
case_inventory_filters_and_classifies_work_board_rows
