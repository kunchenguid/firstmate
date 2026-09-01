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
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
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
      and .deferred_marker == false
  ' >/dev/null || fail "a dated captain hold did not defer or strip its hold-until from the title"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-gated-work")
    | .kind == "ship" and .captain_actionable == true and .deferred_marker == false
  ' >/dev/null || fail "captain actionability must not depend on the row kind"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parked-prose")
    | .captain_actionable == true and .deferred_marker == true
  ' >/dev/null || fail "a prose-deferred captain hold did not carry the presentation marker"
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
  local home fakebin out
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

test_compact_view_contract() {
  local home fakebin help raw explicit_raw snapshot_json view_json compact repeated raw_error compact_error raw_rc compact_rc
  local cmux_line decision_line scout_line secondmate_line ship_line recovery_line queued_line unstructured_line captain_line
  home=$(make_home compact-contract)
  write_fixture "$home"
  mkdir -p "$home/projects/decision-worktree"
  fm_write_meta "$home/state/decision-task.meta" \
    "window=firstmate:fm-decision-task" \
    "worktree=$home/projects/decision-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" decision-task
  printf 'needs-decision [key=route]: choose the release route\n' > "$home/state/decision-task.status"
  awk '
    /^## In flight/ {
      print
      print "unstructured in-flight recovery note"
      next
    }
    /^## Done/ {
      print "- [ ] captain-choice - Choose rollout (repo: alpha) (kind: captain) (hold: select blue or green) (hold-kind: captain)"
      print ""
    }
    { print }
  ' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  help=$("$VIEW" --help)
  assert_contains "$help" "usage: fm-fleet-view.sh [--raw|--compact|--json]" \
    "fleet view help did not publish the compact and full-detail modes"
  raw=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  explicit_raw=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --raw)
  [ "$raw" = "$explicit_raw" ] || fail "explicit --raw changed the default fleet view"
  snapshot_json=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 \
    "$SNAPSHOT" --json)
  view_json=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 \
    "$VIEW" --json)
  [ "$snapshot_json" = "$view_json" ] || fail "fleet view --json changed the complete snapshot escape hatch"

  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --compact)
  repeated=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --compact)
  [ "$compact" = "$repeated" ] || fail "compact fleet view was not deterministic across identical reads"

  assert_contains "$compact" "Rows shown/total: under-way=6/6; queued=3/3; done=0/1." \
    "compact view did not retain every live and queued row or account for Done"
  assert_contains "$compact" "Raw-view omissions: done detail rows=1; task path cells=5." \
    "compact view did not count every detail row and path cell omitted from raw mode"
  assert_contains "$compact" "Compact renderer truncation: none." "compact view did not make its no-truncation guarantee explicit"
  assert_contains "$compact" "Full human detail: FM_HOME='$home' '$VIEW' --raw" \
    "compact view omitted its exact raw-detail escape command"
  assert_contains "$compact" "Complete raw snapshot: FM_HOME='$home' '$VIEW' --json" \
    "compact view omitted its complete structured-detail escape command"
  assert_contains "$compact" "Full queued hold detail: tasks-axi show <id> --full, or '$home/data/backlog.md'." \
    "compact view omitted the full hold-detail escape hatch"
  assert_contains "$compact" "! inventory error:" "compact view did not preserve the unstructured-row inventory error"
  assert_contains "$compact" "! inventory item: unstructured in-flight: unstructured in-flight recovery note" \
    "compact view did not retain an unstructured in-flight inventory item"
  [ "$(printf '%s\n' "$compact" | grep -Fc '! inventory item: unstructured in-flight: unstructured in-flight recovery note')" -eq 1 ] \
    || fail "compact view duplicated an unstructured in-flight inventory item"
  assert_contains "$compact" "! cmux-task: unknown/none; ship alpha; cmux absent; detail=worktree gone (torn down?)" \
    "compact view did not retain a task error and its detail"
  assert_contains "$compact" "! decision decision-task[key=route]: needs-decision: choose the release route" \
    "compact view did not retain an actionable keyed decision"
  assert_contains "$compact" "! captain-choice: Choose rollout; alpha captain; hold=captain: select blue or green" \
    "compact view did not retain the reason for a captain-actionable queued row"
  assert_contains "$compact" "! unstructured: handoff note without canonical syntax" \
    "compact view did not retain an unstructured queued row"
  assert_not_contains "$compact" "done-task" "compact view leaked a Done detail row it says it omits"
  assert_contains "$compact" "peek = bin/fm-peek.sh fm-<row-id>" \
    "compact view dropped the exact ordinary-task action template"
  assert_contains "$compact" "return = bin/fm-send.sh fm-<row-id> '<request>'" \
    "compact view dropped the exact secondmate return action template"

  cmux_line=$(printf '%s\n' "$compact" | grep -n '^! cmux-task:' | cut -d: -f1)
  decision_line=$(printf '%s\n' "$compact" | grep -n '^! decision-task:' | cut -d: -f1)
  scout_line=$(printf '%s\n' "$compact" | grep -n '^! scout-task:' | cut -d: -f1)
  secondmate_line=$(printf '%s\n' "$compact" | grep -n '^- secondmate-task:' | cut -d: -f1)
  ship_line=$(printf '%s\n' "$compact" | grep -n '^- ship-task:' | cut -d: -f1)
  recovery_line=$(printf '%s\n' "$compact" | grep -n '^! inventory item: unstructured in-flight:' | cut -d: -f1)
  [ "$cmux_line" -lt "$decision_line" ] && [ "$decision_line" -lt "$scout_line" ] \
    && [ "$scout_line" -lt "$secondmate_line" ] && [ "$secondmate_line" -lt "$ship_line" ] \
    && [ "$ship_line" -lt "$recovery_line" ] \
    || fail "compact task rows did not preserve deterministic snapshot order"
  queued_line=$(printf '%s\n' "$compact" | grep -n '^- queued-task:' | cut -d: -f1)
  unstructured_line=$(printf '%s\n' "$compact" | grep -n '^! unstructured:' | cut -d: -f1)
  captain_line=$(printf '%s\n' "$compact" | grep -n '^! captain-choice:' | cut -d: -f1)
  [ "$queued_line" -lt "$unstructured_line" ] && [ "$unstructured_line" -lt "$captain_line" ] \
    || fail "compact queued rows did not preserve backlog order"

  raw_error=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_CREW_STATE_TIMEOUT=0 "$VIEW" --raw 2>&1)
  raw_rc=$?
  compact_error=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_CREW_STATE_TIMEOUT=0 "$VIEW" --compact 2>&1)
  compact_rc=$?
  [ "$raw_rc" -eq 2 ] && [ "$compact_rc" -eq "$raw_rc" ] \
    || fail "compact mode changed a snapshot validation error exit status"
  [ "$compact_error" = "$raw_error" ] \
    || fail "compact mode changed or suppressed a snapshot validation error: $compact_error"
  assert_contains "$compact_error" "FM_SNAPSHOT_CREW_STATE_TIMEOUT must be a positive integer" \
    "compact mode did not preserve the underlying snapshot error"
  pass "fleet view compact mode preserves raw output, rows, errors, ordering, omission counts, and escape hatches"
}

test_compact_view_relative_home_escape_hatches() {
  local home relative_home canonical_home fakebin compact raw snapshot raw_command json_command escaped_raw escaped_json
  home="$TMP_ROOT/relative-escape-home"
  relative_home="relative-escape-home"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$TMP_ROOT/elsewhere"
  canonical_home=$(cd "$home" && pwd -P)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")

  raw=$(cd "$TMP_ROOT" && PATH="$fakebin:$PATH" FM_HOME="$relative_home" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$VIEW" --raw)
  snapshot=$(cd "$TMP_ROOT" && PATH="$fakebin:$PATH" FM_HOME="$relative_home" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$SNAPSHOT" --json)
  compact=$(cd "$TMP_ROOT" && PATH="$fakebin:$PATH" FM_HOME="$relative_home" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$VIEW" --compact)
  raw_command=$(printf '%s\n' "$compact" | sed -n 's/^Full human detail: //p')
  json_command=$(printf '%s\n' "$compact" | sed -n 's/^Complete raw snapshot: //p')

  escaped_raw=$(cd "$TMP_ROOT/elsewhere" && PATH="$fakebin:$PATH" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 sh -c "$raw_command")
  escaped_json=$(cd "$TMP_ROOT/elsewhere" && PATH="$fakebin:$PATH" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 sh -c "$json_command")
  [ "$escaped_raw" = "$raw" ] \
    || fail "relative FM_HOME raw escape command did not recover the original complete fleet view"
  [ "$escaped_json" = "$snapshot" ] \
    || fail "relative FM_HOME JSON escape command did not recover the original complete snapshot"
  assert_contains "$compact" "or '$canonical_home/data/backlog.md'." \
    "relative FM_HOME queued-hold escape hatch was not canonicalized"
  assert_compact_view_absolute_home_escape_hatches
  pass "compact view preserves relative and absolute FM_HOME escape hatches"
}

test_compact_view_relative_root_override_escape_hatches() {
  local home relative_root canonical_home fakebin compact raw snapshot raw_command json_command queued_hold_path escaped_raw escaped_json escaped_backlog
  home="$TMP_ROOT/relative-root-override-home"
  relative_root="relative-root-override-home"
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$TMP_ROOT/elsewhere"
  canonical_home=$(cd "$home" && pwd -P)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")

  raw=$(cd "$TMP_ROOT" && PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$relative_root" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$VIEW" --raw)
  snapshot=$(cd "$TMP_ROOT" && PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$relative_root" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$SNAPSHOT" --json)
  compact=$(cd "$TMP_ROOT" && PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$relative_root" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$VIEW" --compact)
  raw_command=$(printf '%s\n' "$compact" | sed -n 's/^Full human detail: //p')
  json_command=$(printf '%s\n' "$compact" | sed -n 's/^Complete raw snapshot: //p')
  queued_hold_path=$(printf '%s\n' "$compact" | sed -n "s|^Full queued hold detail: tasks-axi show <id> --full, or '\(.*\)'\.$|\1|p")

  escaped_raw=$(cd "$TMP_ROOT/elsewhere" && PATH="$fakebin:$PATH" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 sh -c "$raw_command")
  escaped_json=$(cd "$TMP_ROOT/elsewhere" && PATH="$fakebin:$PATH" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 sh -c "$json_command")
  escaped_backlog=$(cd "$TMP_ROOT/elsewhere" && sed -n '1p' "$queued_hold_path")
  [ "$escaped_raw" = "$raw" ] \
    || fail "relative FM_ROOT_OVERRIDE raw escape command did not recover the original complete fleet view"
  [ "$escaped_json" = "$snapshot" ] \
    || fail "relative FM_ROOT_OVERRIDE JSON escape command did not recover the original complete snapshot"
  [ "$queued_hold_path" = "$canonical_home/data/backlog.md" ] && [ "$escaped_backlog" = "## In flight" ] \
    || fail "relative FM_ROOT_OVERRIDE queued-hold escape path did not resolve to the fixture backlog from another directory"
  pass "compact view preserves relative FM_ROOT_OVERRIDE escape hatches"
}

test_compact_view_combined_override_escape_hatches() {
  local home root fakebin compact snapshot json_command escaped_json
  home=$(make_home compact-combined-override-home)
  root="$TMP_ROOT/compact-combined-override-root"
  mkdir -p "$root" "$TMP_ROOT/elsewhere"
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")

  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$SNAPSHOT" --json)
  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$VIEW" --compact)
  json_command=$(printf '%s\n' "$compact" | sed -n 's/^Complete raw snapshot: //p')
  escaped_json=$(cd "$TMP_ROOT/elsewhere" && PATH="$fakebin:$PATH" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 sh -c "$json_command")

  [ "$escaped_json" = "$snapshot" ] \
    || fail "combined FM_HOME and FM_ROOT_OVERRIDE JSON escape command did not recover the original complete snapshot"
  pass "compact view preserves combined FM_HOME and FM_ROOT_OVERRIDE escape hatches"
}

assert_compact_view_absolute_home_escape_hatches() {
  local home alias_home fakebin compact
  home=$(make_home compact-absolute-escape)
  alias_home="$TMP_ROOT/compact-absolute-escape-alias"
  write_fixture "$home"
  ln -s "$home" "$alias_home"
  fakebin=$(make_fakebin "$home")

  compact=$(PATH="$fakebin:$PATH" FM_HOME="$alias_home" \
    FM_SNAPSHOT_NOW=2026-08-30T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1788091200 "$VIEW" --compact)

  assert_contains "$compact" "Full human detail: FM_HOME='$alias_home' '$VIEW' --raw" \
    "absolute FM_HOME raw escape command did not retain its supplied path"
  assert_contains "$compact" "Complete raw snapshot: FM_HOME='$alias_home' '$VIEW' --json" \
    "absolute FM_HOME JSON escape command did not retain its supplied path"
  assert_contains "$compact" "or '$alias_home/data/backlog.md'." \
    "absolute FM_HOME queued-hold escape path did not retain its supplied path"
}

test_compact_view_unmatched_in_flight_records() {
  local home fakebin compact observation_line observation_rows worker_rows unstructured_rows busy_gen
  home=$(make_home compact-unmatched-in-flight)
  mkdir -p "$home/projects/observation" "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Watch production (repo: alpha) (kind: scout) (hold: wait for metrics) (hold-kind: external) (hold-until: 2026-09-01)
- [ ] worker - Active worker (repo: alpha) (kind: ship)
recovery note without canonical syntax

## Queued

## Done
EOF
  fm_write_meta "$home/state/observation.meta" \
    "window=firstmate:fm-observation" \
    "worktree=$home/projects/observation" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'working: watching metrics\n' > "$home/state/observation.status"
  busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" observation)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" observation busy --gen "$busy_gen" \
    --source codex-hook --event user-prompt-submit
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" \
    "worktree=$home/projects/worker" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: active\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")

  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --compact)
  assert_contains "$compact" "Rows shown/total: under-way=4/4; queued=0/0; done=0/0." \
    "compact view did not count every unmatched in-flight record"
  assert_contains "$compact" "- program: Aggregate program; alpha program" \
    "compact view omitted an unmatched program record"
  observation_line=$(printf '%s\n' "$compact" | grep -E '^[-!] observation:')
  assert_contains "$observation_line" "; hold=external: wait for metrics until 2026-09-01; action=peek" \
    "compact view omitted a matched held record's identifying hold detail"
  observation_rows=$(printf '%s\n' "$compact" | grep -Ec '^[-!] observation:')
  [ "$observation_rows" -eq 1 ] || fail "compact view duplicated a task-backed held record"
  worker_rows=$(printf '%s\n' "$compact" | grep -Ec '^[-!] worker:')
  [ "$worker_rows" -eq 1 ] || fail "compact view duplicated a task-backed in-flight record"
  assert_contains "$compact" "! inventory item: unstructured in-flight: recovery note without canonical syntax" \
    "compact view omitted an unmatched unstructured in-flight record"
  unstructured_rows=$(printf '%s\n' "$compact" | grep -Fc '! inventory item: unstructured in-flight: recovery note without canonical syntax')
  [ "$unstructured_rows" -eq 1 ] || fail "compact view duplicated an unmatched unstructured in-flight record"
  pass "compact view retains every unmatched in-flight record without duplicates"
}

test_compact_view_missing_backlog_error() {
  local home compact
  home=$(make_home compact-missing-backlog)

  compact=$(FM_HOME="$home" "$VIEW" --compact)
  assert_contains "$compact" "! inventory error: backlog missing: $home/data/backlog.md" \
    "compact view did not surface a missing backlog inventory error"
  pass "compact view surfaces a missing backlog inventory error"
}

test_compact_view_discloses_incomplete_secondmate_evidence() {
  local home partial unavailable omitted fakebin compact
  home=$(make_home compact-secondmate-evidence)
  partial="$TMP_ROOT/compact-partial-home"
  unavailable="$TMP_ROOT/compact-unavailable-home"
  omitted="$TMP_ROOT/compact-omitted-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  mkdir -p "$partial/state" "$partial/data" "$partial/config" "$partial/projects" "$partial/bin"
  printf '# Firstmate fixture\n' > "$partial/AGENTS.md"
  printf 'a-partial\n' > "$partial/.fm-secondmate-home"
  cat > "$partial/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-child - Missing child metadata (repo: alpha) (kind: ship)

## Queued

## Done
EOF
  mkdir -p "$omitted/state" "$omitted/data" "$omitted/config" "$omitted/projects" "$omitted/bin"
  printf '# Firstmate fixture\n' > "$omitted/AGENTS.md"
  printf 'c-omitted\n' > "$omitted/.fm-secondmate-home"
  cat > "$omitted/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  cat > "$home/data/secondmates.md" <<EOF
- a-partial - fixture (home: $partial; scope: fixture; projects: alpha; added 2026-08-30)
- b-unavailable - fixture (home: $unavailable; scope: fixture; projects: alpha; added 2026-08-30)
- c-omitted - fixture (home: $omitted; scope: fixture; projects: alpha; added 2026-08-30)
EOF
  fakebin=$(make_fakebin "$home")

  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_SECONDMATES=2 "$VIEW" --compact)
  assert_contains "$compact" "Compact renderer truncation: none." \
    "compact view did not distinguish renderer completeness from snapshot bounds"
  assert_contains "$compact" "! secondmate evidence: bounded records omitted=1; shown=2/3" \
    "compact view hid a bounded secondmate record"
  assert_contains "$compact" '! secondmate evidence a-partial: partial; home=' \
    "compact view hid partial structured secondmate evidence"
  assert_contains "$compact" 'reason=structured home state invalid: in-flight backlog item has no child metadata: orphan-child' \
    "compact view hid the partial secondmate reason"
  assert_contains "$compact" "! secondmate evidence b-unavailable: unavailable; home=$unavailable; reason=invalid home: not a directory" \
    "compact view hid unavailable secondmate evidence"
  pass "compact view discloses bounded, unavailable, and partial secondmate evidence"
}

test_compact_view_discloses_bounded_secondmate_holds() {
  local home secondmate fakebin snapshot compact
  home=$(make_home compact-bounded-secondmate-holds)
  secondmate="$TMP_ROOT/compact-bounded-holds-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  mkdir -p "$secondmate/state" "$secondmate/data" "$secondmate/config" "$secondmate/projects" "$secondmate/bin"
  printf '# Firstmate fixture\n' > "$secondmate/AGENTS.md"
  printf 'bounded-holds\n' > "$secondmate/.fm-secondmate-home"
  cat > "$secondmate/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-child - Missing child metadata (repo: gamma) (kind: ship)

## Queued
- [ ] first-hold - Wait for first dependency (repo: alpha) (kind: ship) (hold: first external dependency) (hold-kind: external)
- [ ] second-hold - Wait for second dependency (repo: beta) (kind: scout) (hold: second external dependency) (hold-kind: external)

## Done
EOF
  cat > "$home/data/secondmates.md" <<EOF
- bounded-holds - fixture (home: $secondmate; scope: fixture; projects: alpha; added 2026-08-30)
EOF
  fm_write_meta "$home/state/bounded-holds.meta" \
    "window=firstmate:fm-bounded-holds" \
    "worktree=$secondmate" \
    "project=$secondmate" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$secondmate" \
    "projects=alpha"
  printf 'needs-decision [key=stale]: old parent question\n' > "$home/state/bounded-holds.status"
  fakebin=$(make_fakebin "$home")

  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_SECONDMATE_QUEUED=1 "$SNAPSHOT" --json)
  printf '%s' "$snapshot" | jq -e '
    .secondmate_current.records[] | select(.id == "bounded-holds")
    | .provenance.trust == "partial-structured"
      and .contradiction == true
      and .counts.holds == 2
      and (.holds | length) == 1
      and any(.omitted[]; .surface == "holds" and .count == 1)
  ' >/dev/null || fail "snapshot did not disclose contradictory evidence and the exact bounded hold count: $snapshot"

  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_SECONDMATE_QUEUED=1 "$VIEW" --compact)
  assert_contains "$compact" "! secondmate evidence bounded-holds: partial; home=" \
    "compact view hid partial structured secondmate evidence"
  assert_contains "$compact" "! secondmate evidence bounded-holds: contradictory; home=" \
    "compact view hid contradictory parent evidence alongside partial structured evidence"
  assert_contains "$compact" "! secondmate evidence bounded-holds: bounded holds omitted=1" \
    "compact view hid a bounded secondmate hold"
  assert_contains "$compact" "! secondmate evidence bounded-holds: bounded queued omitted=1" \
    "compact view hid the corresponding bounded queued row"

  awk '
    /^## Done/ { print "unstructured queued recovery note"; print "" }
    { print }
  ' "$secondmate/data/backlog.md" > "$secondmate/data/backlog.next"
  mv "$secondmate/data/backlog.next" "$secondmate/data/backlog.md"

  snapshot=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_SECONDMATE_QUEUED=1 "$SNAPSHOT" --json)
  printf '%s' "$snapshot" | jq -e '
    .secondmate_current.records[] | select(.id == "bounded-holds")
    | .provenance.selected == "parent-event-fallback"
      and .current.state == "unknown"
      and any(.omitted[]; .surface == "holds" and .count == 1)
      and any(.omitted[]; .surface == "queued" and .count == 1)
  ' >/dev/null || fail "snapshot fallback did not preserve exact bounded hold and queued counts: $snapshot"

  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_SECONDMATE_QUEUED=1 "$VIEW" --compact)
  assert_contains "$compact" "! secondmate evidence bounded-holds: unavailable; home=" \
    "compact view hid unavailable fallback secondmate evidence"
  assert_contains "$compact" "! secondmate evidence bounded-holds: bounded holds omitted=1" \
    "compact fallback hid a bounded secondmate hold"
  assert_contains "$compact" "! secondmate evidence bounded-holds: bounded queued omitted=1" \
    "compact fallback hid the corresponding bounded queued row"
  pass "compact view discloses bounded secondmate rows through structured and fallback records"
}

test_compact_view_representative_reduction() {
  local home fakebin raw compact raw_bytes compact_bytes raw_tokens compact_tokens i id busy_gen
  home=$(make_home compact-measurement)
  mkdir -p "$home/projects"
  {
    printf '## In flight\n'
    i=1
    while [ "$i" -le 12 ]; do
      id=$(printf 'representative-worker-%02d-with-stable-identity' "$i")
      mkdir -p "$home/projects/$id"
      fm_write_meta "$home/state/$id.meta" \
        "window=firstmate:fm-$id" \
        "worktree=$home/projects/$id" \
        "project=representative-project" \
        "harness=claude" \
        "kind=scout" \
        "mode=scout"
      printf 'working: representative supervision activity %02d\n' "$i" > "$home/state/$id.status"
      busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
      "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" busy --gen "$busy_gen" \
        --source claude-hook --event user-prompt-submit
      printf -- '- [ ] %s - Representative active task %02d (repo: representative-project) (kind: scout)\n' "$id" "$i"
      i=$((i + 1))
    done
    printf '\n## Queued\n'
    i=1
    while [ "$i" -le 24 ]; do
      id=$(printf 'representative-queued-%02d-with-stable-identity' "$i")
      printf -- '- [ ] %s - Representative queued task %02d with bounded acceptance criteria (repo: representative-project) (kind: ship)\n' "$id" "$i"
      i=$((i + 1))
    done
    printf '\n## Done\n'
    i=1
    while [ "$i" -le 8 ]; do
      id=$(printf 'representative-done-%02d-with-stable-identity' "$i")
      printf -- '- [x] %s - Representative completed task %02d https://github.com/kunchenguid/firstmate/pull/%d (repo: representative-project) (kind: ship) (merged 2026-08-30)\n' "$id" "$i" "$i"
      i=$((i + 1))
    done
  } > "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")

  raw=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --raw)
  compact=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW" --compact)
  raw_bytes=$(printf '%s' "$raw" | LC_ALL=C wc -c | tr -d ' ')
  compact_bytes=$(printf '%s' "$compact" | LC_ALL=C wc -c | tr -d ' ')
  [ $((compact_bytes * 100)) -le $((raw_bytes * 75)) ] \
    || fail "representative compact view saved less than 25%: raw=$raw_bytes compact=$compact_bytes"
  raw_tokens=$(((raw_bytes + 3) / 4))
  compact_tokens=$(((compact_bytes + 3) / 4))
  pass "compact fleet view representative fixture: $raw_bytes -> $compact_bytes bytes (~$raw_tokens -> ~$compact_tokens tokens at four bytes/token)"
}

test_empty_fleet_json
test_fixture_snapshot_json
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
test_compact_view_contract
test_compact_view_relative_home_escape_hatches
test_compact_view_relative_root_override_escape_hatches
test_compact_view_combined_override_escape_hatches
test_compact_view_unmatched_in_flight_records
test_compact_view_missing_backlog_error
test_compact_view_discloses_incomplete_secondmate_evidence
test_compact_view_discloses_bounded_secondmate_holds
test_compact_view_representative_reduction
