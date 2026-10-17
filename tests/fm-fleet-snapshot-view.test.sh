#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  # A working ship task proves it through its own semantic busy-state record
  # (bin/fm-busy-lib.sh), which is what the snapshot's current-state read
  # consults; rendered pane text is no longer a state source.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .paths.status_log.last_event
    | has("age_seconds") and .age_seconds == null
  ' >/dev/null || fail "legacy event must have an explicit unknown age"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"

  local line expected_age before after emitted epoch observed
  printf 'secondmate-task\n' > "$home/secondmate-home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" \
    > "$home/secondmate-home/.fm-secondmate-parent"
  before=$(date +%s)
  FM_HOME="$home/secondmate-home" "$ROOT/bin/fm-secondmate-report.sh" \
    'done' 0123456789abcdef 'audit complete' || fail "parent report failed"
  after=$(date +%s)
  emitted=$(tail -1 "$home/state/secondmate-task.status")
  # shellcheck source=bin/fm-classify-lib.sh
  . "$ROOT/bin/fm-classify-lib.sh"
  epoch=$(status_line_at_epoch "$emitted") || fail "new parent report has unknown time"
  [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ] \
    || fail "parent report did not record emission time"
  for line in "$emitted" 'working: legacy' 'working [at=1700000000]: timed' \
    'working [at=1700000200]: future' 'working [at=oops]: malformed'; do
    printf '%s\n\n' "$line" > "$home/state/secondmate-task.status"
    # Deliberately unrelated file age must never substitute for event age.
    touch -t 202001010000 "$home/state/secondmate-task.status"
    expected_age=null; observed=1700000100
    case "$line" in
      "$emitted") expected_age=100; observed=$((epoch + 100)) ;;
      *1700000000*) expected_age=100 ;;
    esac
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW_EPOCH=$observed "$SNAPSHOT" --json)
    printf '%s' "$out" | jq -e --argjson age "$expected_age" '
      .tasks[] | select(.id == "secondmate-task")
      | .paths.status_log.last_event
      | has("age_seconds") and .age_seconds == $age
        and (has("emitted_at_epoch") | not)
    ' >/dev/null || fail "event age came from something other than the record: $line"
    # parent_event age is the emission age; freshness is how old this snapshot's
    # own observation of the file is, so the 2020 mtime must show up there and
    # only there.
    printf '%s' "$out" | jq -e --argjson age "$expected_age" '
      .secondmate_current.records[] | select(.id == "secondmate-task")
      | .current.state == "unknown"
        and .parent_event.age_seconds == $age
        and (.parent_event | has("emitted_at_epoch") | not)
        and (.freshness.age_seconds | type) == "number"
        and .freshness.age_seconds > 100000000
    ' >/dev/null || fail "fallback confused event age, observation freshness, and current state: $line"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '$ touch -t 202001010000 %s\n' "$home/state/secondmate-task.status"
      printf '$ FM_HOME=%s FM_SNAPSHOT_NOW_EPOCH=%s bin/fm-fleet-snapshot.sh --json\n' "$home" "$observed"
      printf '%s' "$out" | jq '{
        last_event: (.tasks[] | select(.id == "secondmate-task") | .paths.status_log.last_event),
        secondmate: (.secondmate_current.records[] | select(.id == "secondmate-task")
          | {current, parent_event, freshness})
      }'
    fi
  done
  pass "fixture snapshot covers task rows, backlog rows, pointers, stable ordering, and emission-time event age"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_hold_buckets_are_total_and_text_blind() {
  local home fakebin out
  home=$(make_home hold-buckets)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] working-held - Held while working (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z

## Queued
- [ ] blocked-hold - Blocked call blocked-by: upstream-work (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] dated-hold - Dated call (repo: sample) (kind: captain) (hold: revisit later) (hold-kind: captain) (hold-until: 2026-12-01)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] aged-hold - Aged call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z
- [ ] live-hold - Live call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] opposite-word - Opposite wording (repo: sample) (kind: captain) (hold: non-deferred release choice) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] marker-prose - Marker prose (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
  SUPERSEDED - kept only to prove prose never classifies.
- [ ] upstream-work - Land the upstream change (repo: sample) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data"     FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.structured and .hold_kind == "captain")]
    | length == 7
      and all(.hold_bucket as $bucket
              | ["live", "blocked", "dated", "aged"] | index($bucket) != null)
  ' >/dev/null || fail "every captain hold must land in exactly one structured bucket: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "blocked-hold")][0].hold_bucket == "blocked")
      and ([.backlog.records[] | select(.id == "dated-hold")][0].hold_bucket == "dated")
      and ([.backlog.records[] | select(.id == "aged-hold")][0].hold_bucket == "aged")
      and ([.backlog.records[] | select(.id == "live-hold")][0].hold_bucket == "live")
  ' >/dev/null || fail "structured fields did not drive the bucket assignment: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "opposite-word")][0]) as $opposite
    | ([.backlog.records[] | select(.id == "marker-prose")][0]) as $prose
    | $opposite.hold_bucket == "live" and $opposite.captain_actionable == true
      and $prose.hold_bucket == "live" and $prose.captain_actionable == true
  ' >/dev/null || fail "hold reason or body prose must never reclassify a live decision: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "working-held")][0])
    | .hold_bucket == "live" and .captain_actionable == true
  ' >/dev/null || fail "a captain hold on a working task must still be bucketed: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "upstream-work")][0].hold_bucket) == null
  ' >/dev/null || fail "a row that is not a captain hold must carry no bucket: $out"
  pass "captain-hold buckets are total, mutually exclusive, and never decided by prose"
}

test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .captain_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out hint_gen
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-decision
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-blocked
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-decision)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-decision busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-blocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-blocked busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)
- [ ] dated-route - Deferred sample route (repo: sample) (kind: ship) (hold: captain sent this to later) (hold-kind: captain) (hold-until: 2026-09-01)
- [ ] captain-gated-work - Captain-gated ship work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] parked-prose - Parked captain call (repo: sample) (kind: ship) (hold: DEFERRED by captain) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" bold-task
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" \
    FM_SNAPSHOT_NOW=2026-07-14T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
      and .captain_actionable == true
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "dated-route")
    | .title == "Deferred sample route"
      and .hold_until == "2026-09-01"
      and .captain_actionable == false
      and .hold_bucket == "dated"
  ' >/dev/null || fail "a dated captain hold did not defer or strip its hold-until from the title"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-gated-work")
    | .kind == "ship" and .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "captain actionability must not depend on the row kind"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parked-prose")
    | .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "hold prose must never classify a captain hold"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | scout | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_undated_captain_hold_phrasing_and_aging() {
  local home fakebin out
  home=$(make_home undated-aging)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] parked-hold - Parked style call (repo: sample) (kind: ship) (hold: parked) (hold-kind: captain)
- [ ] awaiting-go - Awaiting go call (repo: sample) (kind: ship) (hold: awaiting captain go) (hold-kind: captain)
- [ ] no-dispatch - No dispatch call (repo: sample) (kind: ship) (hold: do not dispatch) (hold-kind: captain)
- [ ] no-auto - No auto-dispatch call (repo: sample) (kind: ship) (hold: do not auto-dispatch) (hold-kind: captain)
- [ ] not-urgent - Not urgent call (repo: sample) (kind: ship) (hold: not urgent) (hold-kind: captain)
- [ ] deprior - Deprioritized call (repo: sample) (kind: ship) (hold: de-prioritized) (hold-kind: captain)
- [ ] queued-opp - Queued opportunity call (repo: sample) (kind: ship) (hold: queued opportunity) (hold-kind: captain)
- [ ] gated-hold - Captain-gated phrasing (repo: sample) (kind: ship) (hold: captain-gated) (hold-kind: captain)
- [ ] aged-call - Aged genuine call (repo: sample) (kind: captain) (since 2026-07-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-01T00:00:00Z
- [ ] recent-call - Recent genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] legacy-old-hold - Legacy unstamped hold (repo: sample) (kind: ship) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Historical notes remain ordinary task content.
  Captain hold set: 2026-07-24T00:00:00Z
- [ ] boundary-call - Almost aged genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-11T00:01:00Z
- [ ] live-gated - Live captain-gated work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] unparked-call - Newly unparked decision (repo: sample) (kind: captain) (hold: unparked; choose a sample route) (hold-kind: captain)
- [ ] contextual-call - Context is not a deferral (repo: sample) (kind: captain) (hold: choose whether to pursue this queued opportunity) (hold-kind: captain)
  This is not urgent context, but the captain decision is current.
- [ ] contextual-not-urgent - Leading context is not a deferral (repo: sample) (kind: captain) (hold: not urgent but choose the route now) (hold-kind: captain)
- [ ] contextual-comma - Comma context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, choose the launch route now) (hold-kind: captain)
- [ ] metadata-context - Metadata-like context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, priority: decide P1 or P2) (hold-kind: captain)
- [ ] contextual-opportunity - Leading opportunity is not a deferral (repo: sample) (kind: captain) (hold: queued opportunity: choose whether to proceed) (hold-kind: captain)
- [ ] contextual-gated - Leading gate is not a deferral (repo: sample) (kind: captain) (hold: captain-gated decision needs current approval) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "parked-hold" or .id == "awaiting-go" or .id == "no-dispatch"
        or .id == "no-auto" or .id == "not-urgent" or .id == "deprior" or .id == "queued-opp"
        or .id == "gated-hold")]
     | all(.captain_actionable == true and .hold_bucket == "live"))
  ' >/dev/null || fail "parked-style wording must never classify a fresh undated hold: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .captain_actionable == false
      and .hold_bucket == "aged"
      and .hold_age_days == 24
  ' >/dev/null || fail "an undated captain hold older than the default 14-day threshold must age: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "recent-call")][0]) as $recent
    | ([.backlog.records[] | select(.id == "legacy-old-hold")][0]) as $legacy
    | $recent.captain_actionable == true
      and $recent.hold_bucket == "live"
      and $recent.hold_age_days == 5
      and $legacy.captain_actionable == false
      and $legacy.hold_set == null
      and $legacy.hold_bucket == "aged"
      and $legacy.hold_age_days == 54
  ' >/dev/null || fail "recent stamped and legacy unstamped hold ages are wrong: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "boundary-call")
    | .hold_set == "2026-07-11T00:01:00Z"
      and .hold_age_days == 13 and .hold_bucket == "live"
  ' >/dev/null || fail "a hold one minute short of 14 days must not age early: $out"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.id == "live-gated" or .id == "unparked-call" or .id == "contextual-call"
        or .id == "contextual-not-urgent" or .id == "contextual-comma" or .id == "metadata-context"
        or .id == "contextual-opportunity" or .id == "contextual-gated")]
    | length == 8
      and all(.captain_actionable == true and .hold_bucket == "live")
      and (map(select(.id == "contextual-comma" and .hold_reason == "not urgent, choose the launch route now")) | length == 1)
      and (map(select(.id == "metadata-context" and .hold_reason == "not urgent, priority: decide P1 or P2")) | length == 1)
  ' >/dev/null || fail "contextual parked-style wording must not hide current decisions: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=30 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .hold_bucket == "live" and .hold_age_days == 24
  ' >/dev/null || fail "raising the age threshold must leave a 24-day hold unaged: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=5 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "recent-call")
    | .hold_bucket == "aged" and .hold_age_days == 5
  ' >/dev/null || fail "lowering the age threshold to 5 must age a 5-day hold: $out"
  pass "undated captain holds age after a configurable threshold, decided only from structured fields"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log | secondmate | $home/secondmate-home | tmux | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_captain_hold() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    "window=firstmate:fm-transferred-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "captain-held transfer must close only the duplicate status copy: $out"
  pass "durable captain-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out kind terminal id phase single mate single_state mate_state
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" lavish-103
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"

  # Same terminal-supersession contract across ship/scout/secondmate, both snapshot
  # modes, and reopen/resolve after cleanup.
  home=$(make_home terminal-cleanup)
  mkdir -p "$home/projects/task"
  fakebin=$(make_fakebin "$home")
  for kind in ship scout secondmate; do
    for terminal in 'done' failed; do
      id="$kind-$terminal"
      fm_write_meta "$home/state/$id.meta" \
        "window=firstmate:fm-$id" "worktree=$home/projects/task" \
        "kind=$kind" "harness=claude"
      record_claude_idle "$home/state" "$id"
      printf 'blocked [key=access]: waiting\nneeds-decision [key=choice]: choose a route\n%s: final outcome\nnote: cleanup complete\n' \
        "$terminal" > "$home/state/$id.status"
    done
  done
  for phase in terminal reopened resolved; do
    case "$phase" in
      terminal) single='[]'; mate='["access","choice"]'; single_state=unknown; mate_state=parked ;;
      reopened) single='["access","new-choice"]'; mate='["access","choice","new-choice"]'; single_state=parked; mate_state=parked ;;
      resolved) single='[]'; mate='["choice"]'; single_state=unknown; mate_state=parked ;;
    esac
    for kind in ship scout secondmate; do
      for terminal in 'done' failed; do
        id="$kind-$terminal"
        case "$phase" in
          reopened) printf 'blocked [key=access]: reopened access\nneeds-decision [key=new-choice]: a new choice\nnote: more cleanup\n' >> "$home/state/$id.status" ;;
          resolved) printf 'resolved [key=access]: access granted\nresolved [key=new-choice]: answered\nnote: final cleanup\n' >> "$home/state/$id.status" ;;
        esac
      done
    done
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
    printf '%s' "$out" | jq -e --argjson single "$single" --argjson mate "$mate" \
      --arg single_state "$single_state" --arg mate_state "$mate_state" '
      .tasks | length == 6 and all(.[];
        (.kind == "secondmate") as $persistent
        | (.hints.open_decisions | map(.key) | sort) == (if $persistent then $mate else $single end)
          and .current_state.state == (if $persistent then $mate_state else $single_state end)
          and .hints.blocked_event == (if $persistent then $mate else $single end | index("access") != null)
          and .hints.pending_decision == (if $persistent then $mate else $single end | any(. != "access")))
    ' >/dev/null || fail "$phase snapshot revived a completed decision or lost a current one: $out"
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
    printf '%s' "$out" | jq -e --argjson single "$single" --argjson mate "$mate" '
      (.decisions_open | map({id,key}) | sort_by(.id,.key)) ==
        (([ ("ship-done","ship-failed","scout-done","scout-failed") as $id | $single[] | {id:$id,key:.} ]
          + [ ("secondmate-done","secondmate-failed") as $id | $mate[] | {id:$id,key:.} ]) | sort_by(.id,.key))
    ' >/dev/null || fail "$phase home summary revived a completed decision or lost a current one: $out"
  done
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" parked-scout
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

# Home-summary validity treats persistent secondmates as registered homes, not
# in-flight children. They have no backlog rows, so they must not produce
# unowned_current or terminal_in_flight. Ordinary crew/ship metas still do.
test_home_summary_excludes_secondmate_from_child_inventory() {
  local home fakebin out
  home=$(make_home summary-secondmate-only)
  mkdir -p "$home/secondmate-home" "$home/projects/unowned" "$home/projects/terminal"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/mate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .schema == "fm-secondmate-home-summary.v1"
      and .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "unowned_current")
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "secondmate-only home with a clean backlog must be VALID: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] mate - Registered secondmate home (repo: alpha) (kind: secondmate) (since 2026-07-11)

## Queued

## Done
EOF
  printf 'done: delegated scope complete\n' > "$home/state/mate.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "terminal secondmate with a matching in-flight row must not produce terminal_in_flight: $out"

  fm_write_meta "$home/state/unowned-ship.meta" \
    "window=firstmate:fm-unowned-ship" \
    "worktree=$home/projects/unowned" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_idle "$home/state" unowned-ship
  printf 'needs-decision [key=unowned-ship]: choose a route\n' > "$home/state/unowned-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"unowned_current",ids:["unowned-ship"]}
      and (.reason | contains("unowned-ship=parked"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary unowned ship must still produce unowned_current without listing the secondmate: $out"

  rm -f "$home/state/unowned-ship.meta" "$home/state/unowned-ship.status"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] terminal-ship - Done child still in flight (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fm_write_meta "$home/state/terminal-ship.meta" \
    "window=firstmate:fm-terminal-ship" \
    "worktree=$home/projects/terminal" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_idle "$home/state" terminal-ship
  printf 'done: complete\n' > "$home/state/terminal-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"terminal_in_flight",ids:["terminal-ship"]}
      and (.reason | contains("terminal-ship=done"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary terminal in-flight ship must still produce terminal_in_flight without listing the secondmate: $out"
  pass "home-summary excludes kind=secondmate from unowned_current and terminal_in_flight"
}

# --- Backlogs kept by a non-markdown tasks-axi backend ----------------------------------
# The structured snapshot must show the configured backend's work, never the empty
# shadow data/backlog.md beside it, and an adapter that cannot be read is a
# diagnostic rather than an empty valid inventory. The real installed tasks-axi and
# br (Beads) are exercised in isolated fixture homes behind a guarded br and
# refusing endpoint stubs; captured real output and edited copies of it cover the
# shapes a real adapter cannot be made to emit on demand.

ADAPTER_CAPTURES="$ROOT/tests/captures/tasks-axi-0.2.5"

real_adapter_available() {  # prints the explicit not-run line when tasks-axi or br is absent
  if command -v tasks-axi >/dev/null 2>&1 && command -v br >/dev/null 2>&1; then
    return 0
  fi
  printf 'skip: real tasks-axi and br (Beads) are not installed; adapter checks not run\n'
  return 1
}

adapter_guard() {  # <name> - a fixture directory with a guarded br and refusing endpoint stubs
  local guard=$TMP_ROOT/$1 tool real_br
  mkdir -p "$guard/guard-bin"
  real_br=$(command -v br 2>/dev/null || printf '%s' /nonexistent/br)
  cat > "$guard/guard-bin/br" <<SH
#!/usr/bin/env bash
# Guarded: only inside this test's temporary root and never with an explicit database path.
case "\$PWD/" in "$TMP_ROOT"/*) ;; *) echo "guarded br: refusing cwd \$PWD" >&2; exit 90 ;; esac
for arg in "\$@"; do case "\$arg" in --db|--db=*) echo "guarded br: refusing --db" >&2; exit 91 ;; esac; done
exec "$real_br" "\$@"
SH
  for tool in gh gh-axi curl ssh; do
    cat > "$guard/guard-bin/$tool" <<SH
#!/usr/bin/env bash
echo "\$0 \$*" >> "$guard/endpoint-calls"
echo "fixture refuses endpoint tool $tool" >&2
exit 91
SH
  done
  chmod +x "$guard/guard-bin"/*
  make_fakebin "$guard" > /dev/null
  printf '%s\n' "$guard"
}

adapter_run() {  # <home> <guard> <command...> - one command against one fixture home only
  local home=$1 guard=$2
  shift 2
  env -u TASKS_AXI_FILE PATH="$guard/guard-bin:$guard/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_SNAPSHOT_NOW=2026-10-02T00:00:00Z "$@"
}

adapter_axi() {  # <home> <guard> <tasks-axi arguments...>
  local home=$1 guard=$2
  shift 2
  (cd "$home" && adapter_run "$home" "$guard" tasks-axi "$@" > /dev/null) \
    || fail "fixture tasks-axi $* failed in $home"
}

adapter_home() {  # <name> <guard> beads|markdown|shim [br-binary] - a fixture home with its own addressing root
  local home guard=$2 kind=$3 binary=${4:-$2/guard-bin/br}
  home=$(make_home "$1")
  case "$kind" in
    beads)
      mkdir -p "$home/backend/.beads"
      printf 'backend="beads"\n[beads]\npath="%s"\nbinary="%s"\nactor="fixture"\n' "$home/backend" "$binary" > "$home/.tasks.toml"
      (cd "$home/backend" && PATH="$guard/guard-bin:$PATH" br init --prefix fx --json > /dev/null 2>&1) \
        || fail "br init failed for $home"
      ;;
    markdown)
      printf 'backend="markdown"\n[markdown]\npath="data/backlog.md"\n' > "$home/.tasks.toml"
      ;;
    shim)
      printf 'backend="beads"\n[beads]\npath="%s"\nbinary="br"\nactor="fixture"\n' "$home/backend" > "$home/.tasks.toml"
      ;;
  esac
  printf '%s\n' "$home"
}

adapter_populate() {  # <home> <guard> - the same logical rows whichever backend keeps them
  local home=$1 guard=$2 reason
  reason="Fixture decision pending, with a comma and a long reason $(printf 'abcdefghij%.0s' $(seq 1 32))"
  mkdir -p "$home/data/done-report"
  printf '# Report\n' > "$home/data/done-report/report.md"
  adapter_axi "$home" "$guard" add in-flight-work "Fixture underway" --kind ship --repo fixture --start
  adapter_axi "$home" "$guard" add queued-work 'Fixture queued, with comma and "quote" and unicode äö' --kind ship --repo fixture \
    --blocked-by in-flight-work --pr https://github.com/o/r/pull/339
  adapter_axi "$home" "$guard" add held-choice "Fixture captain decision" --kind captain --repo fixture
  adapter_axi "$home" "$guard" hold held-choice --reason "$reason" --kind captain
  adapter_axi "$home" "$guard" add dated-hold "Fixture deferred decision" --kind captain --repo fixture
  adapter_axi "$home" "$guard" hold dated-hold --reason "Deferred to later" --kind captain --until 2099-01-01
  adapter_axi "$home" "$guard" add done-work "Fixture landed" --kind ship --repo fixture
  adapter_axi "$home" "$guard" "done" done-work --pr https://github.com/o/r/pull/338 --no-prune
  adapter_axi "$home" "$guard" add done-report "Fixture scout" --kind scout --repo fixture
  adapter_axi "$home" "$guard" "done" done-report --report data/done-report/report.md --no-prune
  adapter_axi "$home" "$guard" add done-local "Fixture local landing local main" --kind ship --repo fixture
  adapter_axi "$home" "$guard" "done" done-local --no-prune
  adapter_axi "$home" "$guard" add resolved-blocker "Fixture blocker" --kind ship --repo fixture
  adapter_axi "$home" "$guard" add after-blocker "Fixture waits on a finished blocker" --kind ship --repo fixture --blocked-by resolved-blocker
  adapter_axi "$home" "$guard" "done" resolved-blocker --no-prune
}

adapter_snapshot() {  # <home> <guard>
  adapter_run "$1" "$2" "$SNAPSHOT" --json
}

test_adapter_backlog_reaches_snapshot_view_and_bearings() {
  real_adapter_available || return 0
  local guard beads markdown shadow_data snap md_snap view bearings listed total pad n encoded
  guard=$(adapter_guard adapter-real-guard)
  beads=$(adapter_home adapter-beads "$guard" beads)
  markdown=$(adapter_home adapter-markdown "$guard" markdown)
  adapter_populate "$beads" "$guard"
  adapter_populate "$markdown" "$guard"
  # A captain hold stores its reason as fm-hold-v1 text (bin/fm-captain-hold.sh); the snapshot decodes it like markdown does.
  encoded=$(. "$ROOT/bin/fm-hold-reason-lib.sh" && fm_hold_reason_encode $'Pick (A) or (B)\n100% sure?')
  adapter_axi "$beads" "$guard" add encoded-hold "Fixture encoded decision" --kind captain --repo fixture
  adapter_axi "$beads" "$guard" hold encoded-hold --reason "$encoded" --kind captain
  adapter_axi "$beads" "$guard" add long-title "Long title $(printf 'x%.0s' $(seq 1 200))" --kind ship --repo fixture
  # More rows than any small page, plus a stale Markdown shadow that must not mask the adapter.
  for n in $(seq 1 24); do
    adapter_axi "$beads" "$guard" add "bulk-$(printf '%02d' "$n")" "Bulk row $n" --kind ship --repo fixture
  done
  printf '## Queued\n- [ ] shadow-only - Stale shadow row (repo: fixture) (kind: ship)\n' > "$beads/data/backlog.md"

  snap=$(adapter_snapshot "$beads" "$guard") || fail "adapter-backed snapshot failed"
  md_snap=$(adapter_snapshot "$markdown" "$guard") || fail "markdown control snapshot failed"
  listed=$(cd "$beads" && adapter_run "$beads" "$guard" tasks-axi list --fields links | sed -n 's/^count: \([0-9][0-9]*\)$/\1/p')
  [ -n "$listed" ] && [ "$listed" -ge 30 ] || fail "fixture should hold more than a small page of rows, got '$listed'"
  total=$(printf '%s' "$snap" | jq '.backlog.records | length')
  [ "$total" = "$listed" ] || fail "snapshot has $total records but tasks-axi lists $listed"
  printf '%s' "$snap" | jq -e '
    .backlog.source == "tasks-axi" and .backlog.present == true and .backlog.error == null
    and ([.backlog.records[].id] | index("shadow-only") | not)
    and (.main_inventory.backlog_error == null)
  ' > /dev/null || fail "adapter backlog was masked by the stale shadow file or flagged unavailable"
  printf '%s' "$snap" | jq -e --arg reason "Fixture decision pending, with a comma and a long reason $(printf 'abcdefghij%.0s' $(seq 1 32))" '
    def rec($id): .backlog.records[] | select(.id == $id);
    (rec("in-flight-work") | .state == "in_flight" and .structured == true and .repo == "fixture" and .kind == "ship")
    and (rec("queued-work") | .state == "queued" and .blocked_by_ids == ["in-flight-work"]
         and .unresolved_blocker_ids == ["in-flight-work"]
         and .pr_url == "https://github.com/o/r/pull/339" and .links == ["https://github.com/o/r/pull/339"]
         and (.title | startswith("Fixture queued, with comma and \"quote\" and unicode äö")))
    and (rec("held-choice") | .hold_kind == "captain" and .hold_reason == $reason and .hold_bucket == "live"
         and .captain_actionable == true)
    and (rec("dated-hold") | .hold_bucket == "dated" and .hold_until == "2099-01-01" and .captain_actionable == false)
    and (rec("done-work") | .state == "done" and .completion.verb == null and .merged == null
         and .completion.date != null and .closed == .completion.date and .pr_url == "https://github.com/o/r/pull/338")
    and (rec("done-report") | .state == "done" and .kind == "scout" and .completion.verb == "reported"
         and .report_path == "data/done-report/report.md")
    and (rec("done-local") | .completion.verb == "done" and .local_note == "local main")
    and (rec("after-blocker") | .blocked_by_ids == ["resolved-blocker"] and .unresolved_blocker_ids == [])
  ' > /dev/null || fail "adapter rows did not keep their states, holds, dependencies, links or long values"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "encoded-hold") | .hold_reason == "Pick (A) or (B)\n100% sure?"
  ' > /dev/null || fail "an fm-hold-v1 hold reason on the adapter backend must be decoded: $(printf '%s' "$snap" | jq -c '.backlog.records[] | select(.id == "encoded-hold") | .hold_reason')"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "long-title")
    | .title_truncated == true and (.title | endswith("…")) and ((.title | contains("--full")) | not)
      and ((.title | contains("tasks-axi")) | not) and (.title_raw | contains("(truncated, "))
      and .title_chars_total == 211
  ' > /dev/null || fail "a truncated title must render with an ellipsis and keep the raw cell and its length"
  # The same logical rows classify identically under either backend.
  jq -n --argjson a "$snap" --argjson b "$md_snap" '
    def pick($s; $id): $s.backlog.records[] | select(.id == $id)
      | {state,current_role,hold_bucket,captain_actionable,unresolved_blocker_ids,kind,repo};
    ["in-flight-work","queued-work","held-choice","dated-hold","done-work","after-blocker"]
    | all(.[]; . as $id | pick($a; $id) == pick($b; $id))
  ' | grep -qx true || fail "markdown control and adapter-backed rows should classify identically"
  printf '%s' "$snap" | jq -e '
    .main_inventory.valid == false and .main_inventory.orphan_in_flight == ["in-flight-work"]
    and .main_inventory.reason == "in-flight backlog item has no child metadata"
  ' > /dev/null || fail "an adapter in-flight row without child metadata must disclose the orphan"

  view=$(adapter_run "$beads" "$guard" "$VIEW") || fail "fleet view failed on the adapter-backed home"
  assert_contains "$view" "| queued-work | Fixture queued, with comma and \"quote\" and unicode äö… | fixture | ship | in-flight-work | https://github.com/o/r/pull/339 |" \
    "view should render the adapter queued row with its blocker and artifact"
  assert_contains "$view" "| done-work | Fixture landed | fixture | ship | - | https://github.com/o/r/pull/338 |" \
    "view should render the adapter done row"
  assert_not_contains "$view" "No queued backlog records found." "view must not call a populated adapter backlog empty"
  assert_not_contains "$view" "shadow-only" "view must not render the stale shadow row"
  assert_not_contains "$view" "tasks-axi show" "view must not print backend help text inside a title"

  bearings=$(adapter_run "$beads" "$guard" "$ROOT/bin/fm-bearings-snapshot.sh" --json --all-queued --all-landed) \
    || fail "bearings failed on the adapter-backed home"
  printf '%s' "$bearings" | jq -e '
    ([.decisions_open[].id] | index("held-choice") != null)
    and ([.decisions_open[].id] | index("dated-hold") == null)
    and ([.gates[].id] | index("dated-hold") != null)
    and ([.gates[].id] | index("queued-work") != null)
    and ([.gates[].id] | index("(main-inventory)") != null)
    and ([.landed[].id] | index("done-work") == null)
    and ([.landed[].id] | index("done-report") != null)
    and ([.omitted[].surface] | map(select(startswith("main in-flight backlog item(s) have no child metadata"))) | length == 1)
  ' > /dev/null || fail "bearings should surface the adapter held call, dated gate and orphan disclosure, and must not report a PR-linked closed row as landed"
  # tasks-axi records no merge state, so a closed row with a PR link is closed work with an unverified merge; explicit Markdown merged metadata still lands.
  printf '%s' "$md_snap" | jq -e '
    .backlog.records[] | select(.id == "done-work") | .completion.verb == "merged" and .pr_url == "https://github.com/o/r/pull/338"
  ' > /dev/null || fail "the Markdown control should still report its explicitly merged row as merged"
  [ ! -e "$guard/endpoint-calls" ] || fail "fixture homes must never reach an endpoint tool: $(cat "$guard/endpoint-calls")"
  pass "a real tasks-axi/Beads backlog reaches the snapshot, view and bearings, ignoring a stale shadow file"
}

test_adapter_unavailable_unreadable_and_empty_backlogs() {
  real_adapter_available || return 0
  local guard missing unreadable empty snap view bearings
  guard=$(adapter_guard adapter-failure-guard)
  missing=$(adapter_home adapter-missing-binary "$guard" beads /nonexistent/fleet-test-br)
  unreadable=$(adapter_home adapter-unreadable "$guard" markdown)
  rm -f "$unreadable/.tasks.toml"
  mkdir "$unreadable/.tasks.toml"
  empty=$(adapter_home adapter-empty "$guard" beads)
  printf '## Queued\n- [ ] shadow-only - Stale shadow row (repo: fixture) (kind: ship)\n' > "$missing/data/backlog.md"

  snap=$(adapter_snapshot "$missing" "$guard") || fail "snapshot must report an unavailable adapter, not fail"
  printf '%s' "$snap" | jq -e '
    .backlog.present == false and .backlog.records == [] and (.backlog.error | contains("is not on PATH"))
    and .main_inventory.valid == false and (.main_inventory.reason | startswith("Backlog unavailable: "))
  ' > /dev/null || fail "an unavailable adapter must be a diagnostic, not an empty valid backlog"
  view=$(adapter_run "$missing" "$guard" "$VIEW") || fail "fleet view must render an unavailable adapter"
  assert_contains "$view" "Backlog unavailable: " "view should say the backlog is unavailable"
  assert_not_contains "$view" "No queued backlog records found." "an unavailable backlog is not an empty queue"
  assert_not_contains "$view" "shadow-only" "the shadow file must not stand in for an unavailable adapter"
  bearings=$(adapter_run "$missing" "$guard" "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "bearings failed on an unavailable adapter"
  printf '%s' "$bearings" | jq -e '
    .gates[] | select(.id == "(main-inventory)") | (.title | startswith("Backlog unavailable"))
  ' > /dev/null || fail "bearings should gate on the unavailable backlog through the main inventory"

  snap=$(adapter_snapshot "$unreadable" "$guard") || fail "snapshot must report an unreadable configuration, not fail"
  printf '%s' "$snap" | jq -e '
    .backlog.present == false and (.backlog.error | contains("configuration cannot be read"))
    and .main_inventory.valid == false and (.main_inventory.reason | startswith("Backlog unavailable: "))
  ' > /dev/null || fail "an unreadable tasks-axi configuration must be a diagnostic"

  snap=$(adapter_snapshot "$empty" "$guard") || fail "snapshot failed on an empty initialized adapter"
  printf '%s' "$snap" | jq -e '
    .backlog.present == true and .backlog.source == "tasks-axi" and .backlog.error == null and .backlog.records == []
    and .main_inventory.valid == true
  ' > /dev/null || fail "a genuinely empty initialized adapter stays a valid empty inventory"
  view=$(adapter_run "$empty" "$guard" "$VIEW")
  assert_contains "$view" "No queued backlog records found." "an empty initialized adapter is an honest empty queue"
  pass "unavailable, unreadable and empty adapter backlogs are told apart"
}

test_adapter_link_values_parse_faithfully_with_the_adapter_grammar() {
  real_adapter_available || return 0
  local guard home snap
  guard=$(adapter_guard adapter-links-guard)
  home=$(adapter_home adapter-links "$guard" beads)
  adapter_axi "$home" "$guard" add pr-comma "PR with comma path" --kind ship --repo fixture --pr 'https://github.com/o/a,b/pull/7'
  adapter_axi "$home" "$guard" add report-comma "Report with commas" --kind scout --repo fixture --report 'data/a,report:b/report.md'
  adapter_axi "$home" "$guard" add pair "PR and report" --kind ship --repo fixture --pr https://github.com/o/r/pull/4 --report data/pair/report.md
  adapter_axi "$home" "$guard" add two-prs "Two PRs" --kind ship --repo fixture
  adapter_axi "$home" "$guard" update two-prs --pr https://github.com/o/r/pull/1
  adapter_axi "$home" "$guard" update two-prs --pr https://github.com/o/r/pull/2
  adapter_axi "$home" "$guard" add two-reports "Two reports" --kind scout --repo fixture --report data/two-reports/report.md
  adapter_axi "$home" "$guard" update two-reports --report data/other/report.md
  adapter_axi "$home" "$guard" add quote-report "Report with a quote" --kind scout --repo fixture --report 'data/we"ird/report.md'
  adapter_axi "$home" "$guard" add generic-urls "See https://example.com/a,b and https://example.org/c" --kind ship --repo fixture
  snap=$(adapter_snapshot "$home" "$guard") || fail "adapter-backed snapshot failed"
  printf '%s' "$snap" | jq -e '
    def rec($id): .backlog.records[] | select(.id == $id);
    (rec("pr-comma") | .links_ambiguous == false and .pr_url == "https://github.com/o/a,b/pull/7")
    and (rec("report-comma") | .links_ambiguous == false and .report_path == "data/a,report:b/report.md")
    and (rec("pair") | .pr_url == "https://github.com/o/r/pull/4" and .report_path == "data/pair/report.md")
    and (rec("two-prs") | .links == ["https://github.com/o/r/pull/1", "https://github.com/o/r/pull/2"])
    and (rec("two-reports") | .report_path == "data/two-reports/report.md" and .links_ambiguous == false)
    and (rec("quote-report") | .report_path == "data/we\"ird/report.md")
    and (rec("generic-urls") | .links_ambiguous == true and .pr_url == null and .report_path == null and .links == []
         and (.links_raw | contains("doc:https://example.com/a,b,doc:https://example.org/c")))
    and .main_inventory.valid == false
    and (.main_inventory.reason | contains("links ambiguous or unparseable") and contains("generic-urls"))
    and .main_inventory.links_ambiguous_ids == ["generic-urls"]
  ' > /dev/null || fail "link values must parse with the adapter grammar and an unprovable cell must withhold its artifacts"
  pass "real adapter link cells parse faithfully, and an unprovable doc-link cell is withheld with a disclosure"
}

# A tasks-axi stand-in that replays captured real output, for the shapes a real adapter
# cannot be made to emit on demand. It logs every call so reads can be counted.
adapter_shim() {  # <guard>
  local guard=$1
  cat > "$guard/guard-bin/tasks-axi" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$guard/shim-calls"
echo "TASKS_AXI_FILE=\${TASKS_AXI_FILE-unset}" > "$guard/shim-env"
if [ "\${1:-}" != list ]; then echo "shim: only list is replayed" >&2; exit 90; fi
mode=\$(cat "$guard/shim-mode")
case "\$mode" in
  sleep) sleep 5 ;;
esac
case "\$*" in
  *--limit*) cat "$guard/shim-limited" 2>/dev/null || cat "$guard/shim-out" ;;
  *) cat "$guard/shim-out" ;;
esac
case "\$mode" in
  stderr-only) echo "shim: backend configuration cannot be read" >&2; exit 2 ;;
esac
exit "\$(cat "$guard/shim-exit" 2>/dev/null || echo 0)"
SH
  chmod +x "$guard/guard-bin/tasks-axi"
  : > "$guard/shim-calls"
}

shim_set() {  # <guard> <mode> <stdout-file|-> [exit-status]
  printf '%s\n' "$2" > "$1/shim-mode"
  if [ "$3" = - ]; then : > "$1/shim-out"; else cp "$3" "$1/shim-out"; fi
  printf '%s\n' "${4:-0}" > "$1/shim-exit"
  rm -f "$1/shim-limited"
  : > "$1/shim-calls"
}

test_adapter_reads_are_bounded_complete_and_strictly_decoded() {
  local guard home snap variant out calls start end
  guard=$(adapter_guard adapter-shim-guard)
  adapter_shim "$guard"
  home=$(adapter_home adapter-shim "$guard" shim)

  shim_set "$guard" ok "$ADAPTER_CAPTURES/list-all-states.toon"
  snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot failed on captured adapter output"
  printf '%s' "$snap" | jq -e '
    (.backlog.records | length) == 7 and .backlog.present == true
    and (.backlog.records[] | select(.id == "odd-links") | .pr_url == "https://github.com/o/a,b/pull/7"
         and .report_path == "data/a,report:b/report.md")
    and (.backlog.records[] | select(.id == "two-prs") | .links | length == 2)
    and (.backlog.records[] | select(.id == "long-title") | .title_truncated and (.title | endswith("…")))
  ' > /dev/null || fail "captured real list output should decode into records"
  [ "$(wc -l < "$guard/shim-calls" | tr -d ' ')" = 1 ] || fail "a complete read is exactly one list call"
  grep -q ' show ' "$guard/shim-calls" && fail "the reader must not issue per-row show reads"

  # An explicit count marker is incomplete: one bounded re-read with the reported total, never a loop.
  # The first call (no --limit) answers with the limited capture, the re-read (--limit 7) with the full one.
  shim_set "$guard" ok "$ADAPTER_CAPTURES/list-limited.toon"
  cp "$ADAPTER_CAPTURES/list-all-states.toon" "$guard/shim-limited"
  snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot failed on an incomplete first read"
  printf '%s' "$snap" | jq -e '.backlog.present == true and (.backlog.records | length) == 7' > /dev/null \
    || fail "an incomplete first read should be completed by one --limit re-read"
  [ "$(wc -l < "$guard/shim-calls" | tr -d ' ')" = 2 ] || fail "incomplete read should cost exactly two list calls: $(cat "$guard/shim-calls")"
  sed -n '2p' "$guard/shim-calls" | grep -q -- '--limit 7' || fail "the re-read must ask for the reported total"

  rm -f "$guard/shim-limited"
  shim_set "$guard" ok "$ADAPTER_CAPTURES/list-limited.toon"
  snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot failed on persistently incomplete output"
  printf '%s' "$snap" | jq -e '
    .backlog.present == false and .backlog.records == [] and (.backlog.error | contains("incomplete adapter output: 3 of 7 rows"))
    and .main_inventory.valid == false and (.main_inventory.reason | startswith("Backlog unavailable: "))
  ' > /dev/null || fail "a persistently incomplete read must be a diagnostic, not a partial inventory"
  [ "$(wc -l < "$guard/shim-calls" | tr -d ' ')" = 2 ] || fail "incomplete reads must stop after one re-read"

  # Malformed envelopes are unavailable, never an empty or partial backlog.
  for variant in count header columns short extra quote state duplicate id help; do
    out=$TMP_ROOT/shim-malformed-$variant.toon
    case "$variant" in
      count) sed '1s/^count: 7$/count: 6/' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      header) sed 's/^tasks\[7\]/tasks[8]/' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      columns) sed '2s/,priority}/,priority,extra}/' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      short) sed '9d' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      extra) { sed -n '1,9p' "$ADAPTER_CAPTURES/list-all-states.toon"; printf '  stray,queued,ship,fixture,Stray\n'; sed -n '10,$p' "$ADAPTER_CAPTURES/list-all-states.toon"; } > "$out" ;;
      quote) sed '3s/"Odd links/"Odd "links/' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      state) sed '9s/,in_flight,/,flying,/' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      duplicate) sed '9s/^  in-flight-work,/  odd-links,/' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      id) sed '9s/^  in-flight-work,/  in flight work,/' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
      help) sed '/^help\[/,$d' "$ADAPTER_CAPTURES/list-all-states.toon" > "$out" ;;
    esac
    shim_set "$guard" ok "$out"
    snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot must survive malformed output ($variant)"
    printf '%s' "$snap" | jq -e '
      .backlog.present == false and .backlog.records == [] and (.backlog.error | startswith("malformed adapter output"))
      and .main_inventory.valid == false
    ' > /dev/null || fail "malformed adapter output ($variant) must be a diagnostic, got: $(printf '%s' "$snap" | jq -c '.backlog.error')"
  done

  # A link cell the grammar cannot consume entirely never fabricates an artifact.
  sed '3s#"pr:https://github.com/o/a,b/pull/7,report:data/a,report:b/report.md"#"pr:https://h/pull/1,pr:https://h/pull/2/pull/3"#' \
    "$ADAPTER_CAPTURES/list-all-states.toon" > "$TMP_ROOT/shim-ambiguous.toon"
  shim_set "$guard" ok "$TMP_ROOT/shim-ambiguous.toon"
  snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot failed on an unparseable link cell"
  printf '%s' "$snap" | jq -e '
    (.backlog.records[] | select(.id == "odd-links")
       | .links_ambiguous == true and .links_raw == "pr:https://h/pull/1,pr:https://h/pull/2/pull/3"
         and .pr_url == null and .report_path == null and .links == [] and .state == "queued" and .kind == "ship")
    and (.backlog.records[] | select(.id == "done-work") | .pr_url == "https://github.com/o/r/pull/338")
    and .main_inventory.valid == false and .main_inventory.links_ambiguous_ids == ["odd-links"]
  ' > /dev/null || fail "an unconsumable link cell must keep raw evidence and withhold parsed artifacts"
  view=$(adapter_run "$home" "$guard" "$VIEW")
  assert_contains "$view" "links ambiguous: pr:https://h/pull/1,pr:https://h/pull/2/pull/3" "view should show the raw ambiguous cell"

  # Failure shapes: TOON diagnostic on stdout, text on stderr only, and a read past its bound.
  shim_set "$guard" ok "$ADAPTER_CAPTURES/error-unavailable.toon" 1
  snap=$(adapter_snapshot "$home" "$guard")
  printf '%s' "$snap" | jq -e '.backlog.present == false and (.backlog.error | contains("is not on PATH (UNSUPPORTED)"))' > /dev/null \
    || fail "a TOON error on stdout should become the diagnostic"
  shim_set "$guard" stderr-only - 2
  snap=$(adapter_snapshot "$home" "$guard")
  printf '%s' "$snap" | jq -e '.backlog.present == false and (.backlog.error | length > 0)' > /dev/null \
    || fail "an empty failing read should still be a diagnostic"
  shim_set "$guard" sleep "$ADAPTER_CAPTURES/list-all-states.toon"
  start=$(date +%s)
  snap=$(FM_BACKLOG_ROWS_TIMEOUT_SECS=1 adapter_snapshot "$home" "$guard")
  end=$(date +%s)
  printf '%s' "$snap" | jq -e '.backlog.present == false and (.backlog.error | contains("exceeded its 1s backlog read bound"))' > /dev/null \
    || fail "a wedged adapter read must be bounded and reported"
  [ $((end - start)) -lt 5 ] || fail "the read bound must cut a wedged adapter short"

  # A markdown home never calls tasks-axi at all.
  home=$(make_home adapter-shim-markdown)
  printf '## Queued\n- [ ] only-row - Only row (repo: fixture) (kind: ship)\n' > "$home/data/backlog.md"
  : > "$guard/shim-calls"
  snap=$(adapter_snapshot "$home" "$guard") || fail "markdown home snapshot failed"
  printf '%s' "$snap" | jq -e '.backlog.records | length == 1' > /dev/null || fail "markdown home should keep its file"
  [ ! -s "$guard/shim-calls" ] || fail "a markdown backlog must not call tasks-axi: $(cat "$guard/shim-calls")"
  pass "adapter reads are bounded, complete or diagnosed, strictly decoded, and markdown homes are untouched"
}

test_adapter_hold_reasons_decode_like_markdown() {
  real_adapter_available || return 0
  local guard beads markdown home owner reason encoded stored snap md_snap view bearings
  reason=$'Pick (A) or (B)\n100% sure?'
  guard=$(adapter_guard adapter-hold-guard)
  beads=$(adapter_home adapter-hold-beads "$guard" beads)
  markdown=$(adapter_home adapter-hold-markdown "$guard" markdown)
  # bin/fm-captain-hold.sh is the owner of the stored form and needs a tasks-axi at or above
  # FM_TASKS_AXI_MIN; below it the owner's encoder and the real tasks-axi hold write the same stored value.
  owner=encoder
  if (. "$ROOT/bin/fm-tasks-axi-lib.sh" && PATH="$guard/guard-bin:$PATH" fm_tasks_axi_compatible); then
    owner=script
  fi
  for home in "$beads" "$markdown"; do
    if [ "$owner" = script ]; then
      adapter_run "$home" "$guard" bash "$ROOT/bin/fm-captain-hold.sh" hold encoded-call \
        --title "Fixture encoded call" --repo fixture --reason "$reason" > /dev/null \
        || fail "fm-captain-hold.sh hold failed for the encoded reason in $home"
      adapter_run "$home" "$guard" bash "$ROOT/bin/fm-captain-hold.sh" hold plain-call \
        --title "Fixture plain call" --repo fixture --reason "Plain reason, with a comma" > /dev/null \
        || fail "fm-captain-hold.sh hold failed for the plain reason in $home"
    else
      encoded=$(. "$ROOT/bin/fm-hold-reason-lib.sh" && fm_hold_reason_encode "$reason")
      adapter_axi "$home" "$guard" add encoded-call "Fixture encoded call" --kind captain --repo fixture
      adapter_axi "$home" "$guard" hold encoded-call --reason "$encoded" --kind captain
      adapter_axi "$home" "$guard" add plain-call "Fixture plain call" --kind captain --repo fixture
      adapter_axi "$home" "$guard" hold plain-call --reason "Plain reason, with a comma" --kind captain
    fi
  done
  # The reason really is stored encoded on the adapter backend, so a decode that never ran cannot pass.
  stored=$(cd "$beads" && adapter_run "$beads" "$guard" tasks-axi list --fields hold_reason | grep '^  encoded-call,')
  case "$stored" in
    *fm-hold-v1:*) ;;
    *) fail "the adapter backend should store the encoded reason, got: $stored" ;;
  esac
  snap=$(adapter_snapshot "$beads" "$guard") || fail "adapter-backed snapshot failed"
  md_snap=$(adapter_snapshot "$markdown" "$guard") || fail "markdown control snapshot failed"
  printf '%s' "$snap" | jq -e --arg reason "$reason" '
    def rec($id): .backlog.records[] | select(.id == $id);
    (rec("encoded-call") | .hold_reason == $reason and .hold_kind == "captain" and .hold_bucket == "live"
       and .captain_actionable == true)
    and (rec("plain-call") | .hold_reason == "Plain reason, with a comma" and .captain_actionable == true)
  ' > /dev/null || fail "adapter hold reasons should be decoded once and plain reasons left alone: $(printf '%s' "$snap" | jq -c '[.backlog.records[] | {id,hold_reason}]')"
  jq -n --argjson a "$snap" --argjson b "$md_snap" '
    def pick($s; $id): $s.backlog.records[] | select(.id == $id) | {hold_reason,hold_kind,hold_bucket,captain_actionable};
    all(["encoded-call","plain-call"][]; . as $id | pick($a; $id) == pick($b; $id))
  ' | grep -qx true || fail "adapter and markdown homes should expose identical hold reasons"
  view=$(adapter_run "$beads" "$guard" "$VIEW") || fail "fleet view failed on the adapter-backed home"
  assert_not_contains "$view" "fm-hold-v1:" "the fleet view must not show the stored hold encoding"
  bearings=$(adapter_run "$beads" "$guard" "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "bearings failed on the adapter-backed home"
  printf '%s' "$bearings" | jq -e '
    ([.decisions_open[] | select(.id == "encoded-call") | .summary | contains("Pick (A) or (B)") and (contains("fm-hold-v1") | not)] == [true])
    and ([.decisions_open[] | select(.id == "plain-call") | .summary | contains("Plain reason, with a comma")] == [true])
  ' > /dev/null || fail "bearings should show the decoded reason in its open decisions"
  pass "captain hold reasons on a real tasks-axi/Beads home decode like markdown, plain reasons unchanged (owner: $owner)"
}

test_adapter_fixtures_ignore_an_inherited_tasks_axi_file() {
  real_adapter_available || return 0
  local guard home decoy decoy_before snap
  guard=$(adapter_guard adapter-axi-file-guard)
  home=$(adapter_home adapter-axi-file "$guard" markdown)
  decoy=$TMP_ROOT/adapter-axi-file-decoy.md
  printf '## Queued\n- [ ] decoy-row - Decoy row (repo: decoy) (kind: ship)\n' > "$decoy"
  decoy_before=$(cat "$decoy")

  # A markdown fixture is where an inherited override would redirect a write.
  export TASKS_AXI_FILE="$decoy"
  adapter_axi "$home" "$guard" add fixture-row "Fixture row" --kind ship --repo fixture
  snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot failed with an inherited TASKS_AXI_FILE"
  unset TASKS_AXI_FILE
  [ "$(cat "$decoy")" = "$decoy_before" ] || fail "fixture helpers must not write through an inherited TASKS_AXI_FILE"
  printf '%s' "$snap" | jq -e '[.backlog.records[].id] == ["fixture-row"]' > /dev/null \
    || fail "fixture helpers should write the fixture backlog, got: $(printf '%s' "$snap" | jq -c '[.backlog.records[].id]')"
  pass "an inherited TASKS_AXI_FILE does not redirect the fixture helpers"
}

test_adapter_list_clears_an_inherited_tasks_axi_file() {
  local guard home snap
  guard=$(adapter_guard adapter-list-axi-file-guard)
  adapter_shim "$guard"
  home=$(adapter_home adapter-list-axi-file "$guard" shim)
  shim_set "$guard" ok "$ADAPTER_CAPTURES/list-all-states.toon"
  snap=$(adapter_run "$home" "$guard" env TASKS_AXI_FILE="$TMP_ROOT/adapter-list-decoy.md" "$SNAPSHOT" --json) \
    || fail "snapshot failed with a decoy TASKS_AXI_FILE"
  printf '%s' "$snap" | jq -e '.backlog.present == true and (.backlog.records | length) == 7' > /dev/null \
    || fail "the snapshot should show the adapter rows"
  [ "$(cat "$guard/shim-env")" = "TASKS_AXI_FILE=unset" ] \
    || fail "tasks-axi list must run with TASKS_AXI_FILE cleared, saw: $(cat "$guard/shim-env")"
  pass "the adapter read runs with an inherited TASKS_AXI_FILE cleared"
}

test_adapter_empty_backlog_requires_the_complete_response() {
  local guard home snap variant out
  guard=$(adapter_guard adapter-empty-shim-guard)
  adapter_shim "$guard"
  home=$(adapter_home adapter-empty-shim "$guard" shim)

  shim_set "$guard" ok "$ADAPTER_CAPTURES/list-empty.toon"
  snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot failed on the captured empty response"
  printf '%s' "$snap" | jq -e '.backlog.present == true and .backlog.error == null and .backlog.records == [] and .main_inventory.valid == true' > /dev/null \
    || fail "the complete captured empty response stays a valid empty inventory"

  for variant in count-only no-help bad-help trailing-garbage bad-help-line; do
    out=$TMP_ROOT/shim-empty-$variant.toon
    case "$variant" in
      count-only) sed -n '1p' "$ADAPTER_CAPTURES/list-empty.toon" > "$out" ;;
      no-help) sed -n '1,2p' "$ADAPTER_CAPTURES/list-empty.toon" > "$out" ;;
      bad-help) { sed -n '1,2p' "$ADAPTER_CAPTURES/list-empty.toon"; printf 'garbage\n'; } > "$out" ;;
      trailing-garbage) { cat "$ADAPTER_CAPTURES/list-empty.toon"; printf 'garbage\n'; } > "$out" ;;
      bad-help-line) { cat "$ADAPTER_CAPTURES/list-empty.toon"; printf 'tasks: 0 tasks in this backlog\n'; } > "$out" ;;
    esac
    shim_set "$guard" ok "$out"
    snap=$(adapter_snapshot "$home" "$guard") || fail "snapshot must survive a bad empty response ($variant)"
    printf '%s' "$snap" | jq -e '
      .backlog.present == false and .backlog.records == [] and (.backlog.error | startswith("malformed adapter output"))
      and .main_inventory.valid == false and (.main_inventory.reason | startswith("Backlog unavailable: "))
    ' > /dev/null || fail "an incomplete empty response ($variant) must be Backlog unavailable, got: $(printf '%s' "$snap" | jq -c '[.backlog.present, .backlog.error]')"
  done
  pass "only the complete captured empty response is a valid empty backlog"
}

test_view_escapes_pipes_in_ambiguous_link_values() {
  local guard home view row cells
  guard=$(adapter_guard adapter-pipe-guard)
  adapter_shim "$guard"
  home=$(adapter_home adapter-pipe "$guard" shim)
  sed '3s#"pr:https://github.com/o/a,b/pull/7,report:data/a,report:b/report.md"#"pr:https://h/pull/1|x,pr:https://h/pull/2/pull/3"#' \
    "$ADAPTER_CAPTURES/list-all-states.toon" > "$TMP_ROOT/shim-pipe.toon"
  shim_set "$guard" ok "$TMP_ROOT/shim-pipe.toon"
  view=$(adapter_run "$home" "$guard" "$VIEW") || fail "fleet view failed on an ambiguous link value with a pipe"
  row=$(printf '%s\n' "$view" | grep '^| odd-links |')
  [ -n "$row" ] || fail "view should render the odd-links row"
  assert_contains "$row" 'links ambiguous: pr:https://h/pull/1\|x,' "the raw ambiguous value should keep its pipe, escaped"
  cells=$(printf '%s' "$row" | sed 's/\\|//g' | tr -cd '|' | wc -c | tr -d ' ')
  [ "$cells" = 7 ] || fail "an ambiguous value with a pipe must keep the six-column table row, got $((cells - 1)) cells: $row"
  pass "a pipe in an ambiguous link value does not add a table column"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_home_summary_excludes_secondmate_from_child_inventory
test_undated_captain_hold_phrasing_and_aging
test_hold_buckets_are_total_and_text_blind
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_transfers_to_captain_hold
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
test_adapter_reads_are_bounded_complete_and_strictly_decoded
test_adapter_backlog_reaches_snapshot_view_and_bearings
test_adapter_unavailable_unreadable_and_empty_backlogs
test_adapter_link_values_parse_faithfully_with_the_adapter_grammar
test_adapter_hold_reasons_decode_like_markdown
test_adapter_fixtures_ignore_an_inherited_tasks_axi_file
test_adapter_list_clears_an_inherited_tasks_axi_file
test_adapter_empty_backlog_requires_the_complete_response
test_view_escapes_pipes_in_ambiguous_link_values
