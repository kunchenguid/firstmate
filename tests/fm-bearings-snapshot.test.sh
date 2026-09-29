#!/usr/bin/env bash
# Behavioral coverage for the bounded single-home bearings projection.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$ROOT/tests/fixtures.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/ship" "$home/data/scout-done"
  printf '%s\n' "$home"
}

make_fakebin() {
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'status --json') echo '{"server":{"running":true}}' ;;
  'pane get')
    case "$3" in
      *missing*) echo '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
      *) jq -n --arg p "$3" '{result:{pane:{pane_id:$p}}}' ;;
    esac ;;
  'agent get')
    case "$3" in
      *missing*) echo '{"error":{"code":"agent_not_found"}}'; exit 1 ;;
      *idle*) echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
      *) echo '{"result":{"agent":{"agent_status":"working"}}}' ;;
    esac ;;
  'pane process-info')
    case "${4:-}" in
      *missing*) exit 1 ;;
      *) jq -n --arg p "${4:-}" '{result:{type:"pane_process_info",process_info:{pane_id:$p,shell_pid:101,foreground_processes:[{pid:102,name:"pi",argv0:"pi"}]}}}' ;;
    esac ;;
  'pane read')
    case "$3" in *missing*) exit 1 ;; *) printf 'working\n> \n' ;; esac ;;
  *) echo '{}' ;;
esac
SH
  for tool in gh gh-axi curl; do
    cat > "$fb/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "${NET_LOG:?}"
exit 1
SH
    chmod +x "$fb/$tool"
  done
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

write_fixture() {
  local home=$1
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since 2026-09-26)

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-09-27)

## Done
- [x] scout-done - Scout Report data/scout-done/report.md (repo: alpha) (kind: scout) (reported 2026-09-25)
- [x] ship-done - Shipped https://github.com/example/repo/pull/7 (repo: alpha) (kind: ship) (merged 2026-09-24)
EOF
  printf '# Report\n' > "$home/data/scout-done/report.md"
  fm_test_write_herdr_meta "$home/state/ship-task.meta" \
    "window=fmtest:w1:p1" "endpoint_task_id=ship-task" \
    "backend=herdr" "herdr_session=fmtest" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" \
    "worktree=$home/projects/ship" "project=alpha" "harness=pi" \
    "kind=ship" "mode=no-mistakes"
  printf 'working: implementing\n' > "$home/state/ship-task.status"
  fm_test_write_herdr_meta "$home/state/retired-home.meta" \
    "window=fmtest:w2:p1" "endpoint_task_id=retired-home" \
    "backend=herdr" "worktree=$home/retired" "project=retired" \
    "harness=pi" "kind=secondmate" "mode=secondmate" "home=$home/retired"
}

test_empty_projection() {
  local home out
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$BEARINGS" --json)
  printf '%s\n' "$out" | jq -e '
    .schema == "fm-bearings.v1"
      and .in_flight == []
      and .retained_record_count == 0
      and .retained_records == []
      and .landed == []
      and .reports == []
      and .decisions_open == []
  ' >/dev/null || fail "empty bearings projection has the wrong public shape: $out"
  pass "bearings renders an empty single-home projection"
}

test_main_home_projection_is_local_and_complete() {
  local home fakebin out net
  home=$(make_home fixture)
  fakebin=$(make_fakebin "$home")
  write_fixture "$home"
  net="$home/network.log"; : > "$net"
  out=$(PATH="$fakebin:$PATH" NET_LOG="$net" FM_HOME="$home" "$BEARINGS" --json --all-landed --all-reports)
  [ ! -s "$net" ] || fail "default bearings path made a network call: $(cat "$net")"
  printf '%s\n' "$out" | jq -e '
    (.in_flight | any(.id == "ship-task" and .kind == "ship"))
      and ([.in_flight[].id] | index("retired-home") | not)
      and (.landed | any(.id == "ship-done" and .owner == "(main)"))
      and (.landed | any(.id == "scout-done" and .owner == "(main)"))
      and (.reports | any(.id == "scout-done" and (.path | endswith("data/scout-done/report.md"))))
  ' >/dev/null || fail "bearings did not project the retained main-home surfaces correctly: $out"
  pass "bearings projects ordinary tasks, landed work, and reports without retired homes or network access"
}

test_removed_secondmate_flag_is_rejected() {
  local home rc
  home=$(make_home removed-flag)
  set +e
  FM_HOME="$home" "$BEARINGS" --json --all-secondmates > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "removed --all-secondmates flag still succeeded"
  assert_contains "$(cat "$home/err")" "usage:" "removed bearings flag did not fail through the CLI"
  pass "bearings rejects the removed secondmate expansion flag"
}

task_in() {  # <home> <tasks-axi arguments...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

write_task_meta() {  # <home> <id> <pane>
  local home=$1 id=$2 pane=$3
  fm_test_write_herdr_meta "$home/state/$id.meta" \
    "window=fixture:w1:$pane" "endpoint_task_id=$id" \
    "backend=herdr" "herdr_session=fixture" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=$pane" \
    "worktree=$home/projects/ship" "project=alpha" "harness=pi" \
    "kind=scout" "mode=no-mistakes" "spawn_gen=g-$id"
}

test_archived_and_parked_execution_records_are_not_underway() {
  local home fakebin fleet bearings
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped archived projection regression: tasks-axi not installed"
    return
  }
  home=$(make_home archive-projection)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/records"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "records/completed.md"
done_keep = 1
EOF

  task_in "$home" add parked-residual 'Parked residual' --kind scout --queue >/dev/null
  task_in "$home" hold parked-residual --reason 'synthetic archival disposition' --kind parked >/dev/null
  write_task_meta "$home" parked-residual p-active-stale-parked
  printf 'blocked [key=stale]: historical parked wait\n' > "$home/state/parked-residual.status"

  task_in "$home" add done-pruned 'Done pruned' --kind scout --start >/dev/null
  task_in "$home" 'done' done-pruned --report data/done-pruned/report.md --no-prune >/dev/null
  write_task_meta "$home" done-pruned p-active-stale-done
  printf 'needs-decision [key=stale]: historical completed decision\n' > "$home/state/done-pruned.status"
  task_in "$home" add prune-trigger 'Prune trigger' --kind scout --start >/dev/null
  task_in "$home" 'done' prune-trigger --report data/prune-trigger/report.md --keep 1 >/dev/null

  task_in "$home" add healthy-active 'Healthy active' --kind scout --start >/dev/null
  write_task_meta "$home" healthy-active p-active
  task_in "$home" add ambiguous-duplicate 'Ambiguous duplicate' --kind scout --queue >/dev/null
  sed -i '/ambiguous-duplicate/p' "$home/data/backlog.md"
  write_task_meta "$home" ambiguous-duplicate p-missing-ambiguous
  task_in "$home" add reused-active 'Old completed incarnation' --kind scout --start >/dev/null
  task_in "$home" 'done' reused-active --report data/reused-active/report.md --keep 0 >/dev/null
  task_in "$home" add reused-active 'Current active incarnation' --kind scout --start >/dev/null
  write_task_meta "$home" reused-active p-active-reused
  write_task_meta "$home" orphan-unknown p-missing-orphan

  fleet=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s\n' "$fleet" | jq -e '
    (.tasks[] | select(.id == "done-pruned")
      | .backlog == null and .record_disposition == "archive_done"
        and .current_state.state == "working" and .retained_record == false)
    and (.tasks[] | select(.id == "parked-residual")
      | .backlog.state == "queued" and .record_disposition == "parked"
        and .current_state.state == "working" and .retained_record == false)
    and (.tasks[] | select(.id == "healthy-active")
      | .backlog.state == "in_flight" and .record_disposition == "active"
        and .current_state.state == "working" and .retained_record == false)
    and (.tasks[] | select(.id == "ambiguous-duplicate")
      | .backlog.state == "queued" and .record_disposition == "ambiguous"
        and .retained_record == false)
    and (.tasks[] | select(.id == "reused-active")
      | .backlog.state == "in_flight" and .record_disposition == "active"
        and .current_state.state == "working" and .retained_record == false)
    and (.tasks[] | select(.id == "orphan-unknown")
      | .backlog == null and .record_disposition == "unknown" and .retained_record == false)
  ' >/dev/null || fail "fleet lost an authoritative archived, parked, active, or unknown disposition: $fleet"

  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-in-flight --all-queued --all-unhealthy)
  printf '%s\n' "$bearings" | jq -e '
    ([.in_flight[].id] | index("healthy-active") != null)
      and ([.in_flight[].id] | index("reused-active") != null)
      and ([.in_flight[].id] | index("parked-residual") == null)
      and ([.in_flight[].id] | index("done-pruned") == null)
      and ([.in_flight[].id] | index("ambiguous-duplicate") == null)
      and ([.in_flight[].id] | index("orphan-unknown") == null)
      and ([.retained_records[].id] | index("done-pruned") == null)
      and ([.gates[] | select(.id == "done-pruned" and .reason == "task record integrity")] | length == 1)
      and ([.gates[].id] | index("parked-residual") != null)
      and ([.gates[] | select(.id == "ambiguous-duplicate" and .reason == "task record integrity")] | length >= 1)
      and ([.gates[] | select(.id == "orphan-unknown" and .reason == "task record integrity")] | length == 1)
      and ([.unhealthy_endpoints[].id] | index("orphan-unknown") != null)
  ' >/dev/null || fail "bearings confused work identity, process identity, or an unknown orphan: $bearings"
  pass "archived and parked residual execution records stay out of Underway while active and unknown evidence remain visible"
}

test_unsupported_backend_never_infers_terminal_disposition() {
  local home fakebin fleet bearings
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped unsupported-backend projection regression: tasks-axi not installed"
    return
  }
  home=$(make_home unsupported-backend)
  fakebin=$(make_fakebin "$home")
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/completed.md"
done_keep = 10
EOF
  task_in "$home" add backend-unknown 'Backend unknown' --kind scout --start >/dev/null
  task_in "$home" 'done' backend-unknown --report data/backend-unknown/report.md --no-prune >/dev/null
  write_task_meta "$home" backend-unknown p-missing-backend
  printf 'backend = "github"\n' > "$home/.tasks.toml"

  fleet=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s\n' "$fleet" | jq -e '
    .tasks[] | select(.id == "backend-unknown")
      | .backlog.state == "done" and .record_disposition == "unknown"
        and .retained_record == false
  ' >/dev/null || fail "an unsupported backend was treated as terminal evidence: $fleet"

  bearings=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --all-queued --all-unhealthy)
  printf '%s\n' "$bearings" | jq -e '
    ([.in_flight[].id] | index("backend-unknown") == null)
      and ([.retained_records[].id] | index("backend-unknown") == null)
      and ([.gates[] | select(.id == "backend-unknown" and .reason == "task record integrity")] | length == 1)
  ' >/dev/null || fail "an unsupported backend disappeared instead of remaining an integrity gate: $bearings"
  pass "unsupported task backends preserve terminal-looking execution records as unknown integrity evidence"
}

test_mixed_history_stays_compact_and_long_decision_has_targeted_read() {
  local home fakebin default expanded targeted targeted_toon missing rc gen
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped targeted task projection regression: tasks-axi not installed"
    return
  }
  home=$(make_home targeted-context)
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/records" "$home/data/actionable-choice"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "records/completed.md"
done_keep = 1
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] actionable-choice - Choose the exact TikTok recovery input (repo: alpha) (kind: scout) (since 2026-09-29) (hold: Choose either option A: restore the authenticated read-only GUI session, or option B: provide the complete timestamped campaign-level export for all twenty-two named groups; an older snapshot is not current-state evidence.) (hold-kind: captain)
  Option A requires a restored authenticated read-only GUI session.
  Option B requires a timestamped campaign-level export for all twenty-two named groups.
  Evidence: data/actionable-choice/report.md.

## Done
EOF
  cat > "$home/records/completed.md" <<'EOF'
## Archived 2026-09
- [x] archive-old - Historical completed task (repo: alpha) (kind: scout) (reported 2026-09-01)
- [x] archive-quiet - Historical completed task without open work (repo: alpha) (kind: scout) (reported 2026-09-02)
EOF
  printf '# exact evidence\n' > "$home/data/actionable-choice/report.md"
  write_task_meta "$home" actionable-choice p-idle-choice
  printf 'yolo=off\n' >> "$home/state/actionable-choice.meta"
  printf 'kind=secondmate\nproject=alpha\n' > "$home/state/archive-old.meta"
  printf 'kind=secondmate\nproject=alpha\n' > "$home/state/archive-quiet.meta"
  printf '%s\n' \
    'needs-decision [key=retained-choice]: choose whether to retain the archived evidence' \
    'working: later unrelated archival bookkeeping' > "$home/state/archive-old.status"
  printf '%s\n' \
    'needs-decision [key=active-choice]: choose the current recovery input' \
    'working: later unrelated evidence indexing' > "$home/state/actionable-choice.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" actionable-choice)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" actionable-choice idle --gen "$gen" \
    --source pi-ext --event stop

  default=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-09-29T12:00:00Z "$BEARINGS" --json) \
    || fail "default mixed-history projection failed"
  printf '%s\n' "$default" | jq -e '
    .retained_record_count == 2
      and (.retained_records | any(.id == "archive-old"
        and (.open_decisions | any(.key == "retained-choice" and .verb == "needs-decision"))))
      and ([.retained_records[].id] | index("archive-quiet") == null)
      and ([.in_flight[].id] | index("archive-old") == null)
      and ([.decisions_open[].id] | index("archive-old") == null)
      and (.decisions_open | any(.id == "actionable-choice"
        and .retrieve == "--task actionable-choice"
        and (.summary | endswith("…"))))
      and (.omitted | any(.surface == "retained records omitted: 1" and .reveal == "--all-retained"))
  ' >/dev/null || fail "routine projection did not prioritize the actionable decision over retained detail: $default"

  expanded=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-09-29T12:00:00Z "$BEARINGS" --json --all-retained) \
    || fail "retained-record drill-down failed"
  printf '%s\n' "$expanded" | jq -e '
    .retained_record_count == 2
      and (.retained_records | any(.id == "archive-old"))
      and (.retained_records | any(.id == "archive-quiet"))
  ' >/dev/null || fail "archived evidence was not discoverable through its exact drill-down: $expanded"

  targeted=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-09-29T12:00:00Z "$BEARINGS" --json --task actionable-choice) \
    || fail "targeted task read failed"
  printf '%s\n' "$targeted" | jq -e '
    .schema == "fm-task-context.v1" and .id == "actionable-choice"
      and .title == "Choose the exact TikTok recovery input"
      and .delivery_mode == "no-mistakes" and .merge_posture == "off"
      and (.remaining_request | contains("option A: restore the authenticated read-only GUI session"))
      and (.remaining_request | contains("option B: provide the complete timestamped campaign-level export"))
      and (.open_decisions | any(.key == "active-choice" and .verb == "needs-decision"
        and .summary == "choose the current recovery input"))
      and (.current_detail | contains("later unrelated evidence indexing"))
      and (.backlog_body | any(.line | contains("all twenty-two named groups")))
      and (.report_path | endswith("data/actionable-choice/report.md"))
      and .omitted[0].surface == "other fleet tasks and history"
  ' >/dev/null || fail "targeted read lost exact action, authority, or evidence pointers: $targeted"
  targeted_toon=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-09-29T12:00:00Z "$BEARINGS" --task actionable-choice) \
    || fail "targeted TOON task read failed"
  assert_contains "$targeted_toon" "schema: fm-task-context.v1" "targeted TOON lost its schema"
  assert_contains "$targeted_toon" "Option B requires a timestamped campaign-level export" \
    "targeted TOON lost the complete second option"

  sed -i 's/an older snapshot is not current-state evidence/a newly supplied export must still be read back before acceptance/' "$home/data/backlog.md"
  targeted=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-09-29T12:01:00Z "$BEARINGS" --json --task actionable-choice) \
    || fail "refreshed targeted task read failed"
  printf '%s\n' "$targeted" | jq -e '
    (.remaining_request | contains("a newly supplied export must still be read back before acceptance"))
      and (.remaining_request | contains("an older snapshot is not current-state evidence") | not)
  ' >/dev/null || fail "targeted read reused stale task requirements after the backlog changed: $targeted"

  set +e
  missing=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$BEARINGS" --json --task missing-task 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "targeted read fabricated a missing task"
  assert_contains "$missing" "task not found: missing-task" "missing targeted evidence did not fail by identity"
  pass "mixed history stays compact while exact actionable task context remains retrievable"
}

test_targeted_task_requires_a_value() {
  local home out rc
  home=$(make_home malformed-target)
  for arg in --task --task= --task=-other; do
    set +e
    out=$(FM_HOME="$home" "$BEARINGS" "$arg" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$arg silently fell back to a broad bearings snapshot"
    assert_contains "$out" "--task requires" "$arg did not report its missing task id"
  done
  set +e
  out=$(FM_HOME="$home" "$BEARINGS" --task --json 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "--task consumed another option and ran a broad bearings snapshot"
  assert_contains "$out" "--task requires a non-option task id" "--task accepted an option as its task id"
  pass "bearings rejects malformed targeted reads before broad fallback"
}

test_empty_projection
test_main_home_projection_is_local_and_complete
test_removed_secondmate_flag_is_rejected
test_archived_and_parked_execution_records_are_not_underway
test_unsupported_backend_never_infers_terminal_disposition
test_mixed_history_stays_compact_and_long_decision_has_targeted_read
test_targeted_task_requires_a_value
