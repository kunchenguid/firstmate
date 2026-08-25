#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
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
case "$target" in
  *11-secondmate*) exit 1 ;;
esac
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta | sed '/^fm-11-secondmate$/d'
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*|*10-secondmate*) printf 'zsh\n' ;;
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

test_large_backlog_crosses_argv_limit_via_public_interface() {
  local home out payload payload_bytes
  home=$(make_home large-backlog)
  payload=$(LC_ALL=C awk 'BEGIN { for (i = 0; i < 196608; i++) printf "x" }')
  payload_bytes=$(printf '%s' "$payload" | LC_ALL=C wc -c | tr -d ' ')
  [ "$payload_bytes" -gt 131072 ] \
    || fail "large-backlog fixture must exceed the ordinary Linux per-argument limit"
  printf '## Done\n%s\n' "$payload" > "$home/data/backlog.md"

  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --argjson payload_bytes "$payload_bytes" '
    .schema == "fm-fleet-snapshot.v1"
      and (.tasks | length) == 0
      and (.backlog.records | length) == 1
      and .backlog.records[0].structured == false
      and (.backlog.records[0].raw | length) == $payload_bytes
  ' >/dev/null || fail "public snapshot must return valid complete JSON above argv limits"
  pass "public snapshot transports a backlog larger than ordinary Linux argv limits"
}

test_large_task_status_crosses_argv_limit_via_public_interface() {
  local home fakebin out payload payload_bytes prefix prefix_bytes status_value status_bytes
  home=$(make_home large-task-status)
  mkdir -p "$home/projects/large-task-status"
  fm_write_meta "$home/state/large-task-status.meta" \
    "window=firstmate:fm-large-task-status" \
    "worktree=$home/projects/large-task-status" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" large-task-status
  prefix='needs-decision [key=oversize]: '
  payload=$(LC_ALL=C awk 'BEGIN { for (i = 0; i < 196608; i++) printf "s" }')
  payload_bytes=$(printf '%s' "$payload" | LC_ALL=C wc -c | tr -d ' ')
  prefix_bytes=$(printf '%s' "$prefix" | LC_ALL=C wc -c | tr -d ' ')
  [ "$payload_bytes" -gt 131072 ] \
    || fail "large-status fixture must exceed the ordinary Linux per-argument limit"
  status_value="https://$payload/pull/1"
  status_bytes=$(printf '%s' "$status_value" | LC_ALL=C wc -c | tr -d ' ')
  printf '%s%s\n' "$prefix" "$status_value" > "$home/state/large-task-status.status"

  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e \
    --argjson status_bytes "$status_bytes" \
    --argjson prefix_bytes "$prefix_bytes" '
    .schema == "fm-fleet-snapshot.v1"
      and (.tasks | length) == 1
      and (.tasks[0].id == "large-task-status")
      and (.tasks[0].current_state.state == "parked")
      and (.tasks[0].current_state.source == "status-log")
      and ((.tasks[0].current_state.detail | length) == $status_bytes)
      and ((.tasks[0].paths.status_log.last_event.raw | length) == ($prefix_bytes + $status_bytes))
      and ((.tasks[0].paths.status_log.last_event.note | length) == $status_bytes)
      and ((.tasks[0].hints.open_decisions[0].summary | length) == $status_bytes)
      and ((.tasks[0].pr.url | length) == $status_bytes)
      and (.tasks[0].pr.source == "status_event")
  ' >/dev/null || fail "public snapshot must preserve complete task status above argv limits"
  pass "public snapshot transports task status above ordinary Linux argv limits"
}

test_large_task_metadata_crosses_argv_limit_via_public_interface() {
  local home fakebin out payload payload_bytes
  home=$(make_home large-task-metadata)
  mkdir -p "$home/projects/large-task-metadata"
  payload=$(LC_ALL=C awk 'BEGIN { for (i = 0; i < 196608; i++) printf "m" }')
  payload_bytes=$(printf '%s' "$payload" | LC_ALL=C wc -c | tr -d ' ')
  [ "$payload_bytes" -gt 131072 ] \
    || fail "large-metadata fixture must exceed the ordinary Linux per-argument limit"
  fm_write_meta "$home/state/large-task-metadata.meta" \
    "window=firstmate:fm-large-task-metadata" \
    "worktree=$home/projects/large-task-metadata" \
    "project=$payload" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" large-task-metadata
  printf 'working: bounded status\n' > "$home/state/large-task-metadata.status"

  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --argjson payload_bytes "$payload_bytes" '
    .schema == "fm-fleet-snapshot.v1"
      and (.tasks | length) == 1
      and (.tasks[0].id == "large-task-metadata")
      and ((.tasks[0].project | length) == $payload_bytes)
  ' >/dev/null || fail "public snapshot must preserve complete task metadata above argv limits"
  pass "public snapshot transports task metadata above ordinary Linux argv limits"
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

# Production-scale regression for snapshot-local reuse of raw no-mistakes
# queries. Eleven task records preserve the observed 7 ship / 1 scout /
# 3 secondmate mix. Five branched ships reduce to three exact
# common-dir/branch/HEAD identities: scale-a and scale-b each have a duplicate,
# while scale-c has one task. The fake returns heads absent from the repository
# for both query forms, so the unchanged fail-closed head proof must reject every
# row before each task independently falls back to its own status and endpoint.
test_snapshot_reuses_raw_no_mistakes_queries_per_identity() {
  local home repo wt_b wt_c wt_detached mate fakebin calls stderr_file expected_raw actual_raw
  local before_manifest after_manifest out first_out second_out primary_calls coarse_calls total_calls branch branch_calls
  home=$(make_home snapshot-query-reuse)
  repo="$home/projects/scale-repo"
  wt_b="$home/projects/scale-b"
  wt_c="$home/projects/scale-c"
  wt_detached="$home/projects/scale-detached"
  mate="$TMP_ROOT/snapshot-query-reuse-mate"
  calls="$TMP_ROOT/private-scale-call-ledger"
  stderr_file="$TMP_ROOT/private-scale-stderr"
  expected_raw="$TMP_ROOT/scale-expected-current-state"
  actual_raw="$TMP_ROOT/scale-actual-current-state"
  first_out="$TMP_ROOT/scale-first.json"
  second_out="$TMP_ROOT/scale-second.json"

  fm_git_init_commit "$repo"
  git -C "$repo" branch -M scale-a
  git -C "$repo" worktree add -q -b scale-b "$wt_b"
  git -C "$repo" worktree add -q -b scale-c "$wt_c"
  git -C "$repo" worktree add -q --detach "$wt_detached"
  mkdir -p "$home/projects/plain" "$home/projects/scout"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf '09-mate\n' > "$mate/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  printf -- '- 09-mate - scale fixture (home: %s; scope: scale fixture; projects: firstmate; added 2026-08-11)\n' \
    "$mate" > "$home/data/secondmates.md"

  fm_write_meta "$home/state/01-ship-a-blocked.meta" \
    "window=firstmate:fm-01-ship-a-blocked" "worktree=$repo" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/02-ship-a-done.meta" \
    "window=firstmate:fm-02-ship-a-done" "worktree=$repo" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/03-ship-b-decision.meta" \
    "window=firstmate:fm-03-ship-b-decision" "worktree=$wt_b" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/04-ship-b-failed.meta" \
    "window=firstmate:fm-04-ship-b-failed" "worktree=$wt_b" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/05-ship-c-working.meta" \
    "window=firstmate:fm-05-ship-c-working" "worktree=$wt_c" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/06-ship-detached.meta" \
    "window=firstmate:fm-06-ship-detached" "worktree=$wt_detached" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/07-ship-plain.meta" \
    "window=firstmate:fm-07-ship-plain" "worktree=$home/projects/plain" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/08-scout.meta" \
    "window=firstmate:fm-08-scout" "worktree=$home/projects/scout" "project=firstmate" \
    "harness=claude" "kind=scout" "mode=scout"
  fm_write_meta "$home/state/09-mate.meta" \
    "window=firstmate:fm-09-mate" "worktree=$mate" "project=$mate" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "home=$mate" "projects=firstmate"
  fm_write_meta "$home/state/10-secondmate.meta" \
    "window=firstmate:fm-10-secondmate" "worktree=$home/projects/plain" "project=firstmate" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "home=$home/projects/plain"
  fm_write_meta "$home/state/11-secondmate.meta" \
    "window=firstmate:fm-11-secondmate" "worktree=$home/projects/scout" "project=firstmate" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "home=$home/projects/scout"

  for branch in \
    01-ship-a-blocked 02-ship-a-done 03-ship-b-decision 04-ship-b-failed \
    05-ship-c-working 06-ship-detached 07-ship-plain 08-scout; do
    record_claude_idle "$home/state" "$branch"
  done
  printf 'blocked [key=network]: task a remains independently blocked\n' > "$home/state/01-ship-a-blocked.status"
  printf 'done: task a duplicate is independently complete\n' > "$home/state/02-ship-a-done.status"
  printf 'needs-decision [key=shape]: task b awaits its own decision\n' > "$home/state/03-ship-b-decision.status"
  printf 'working: task b continued unrelated setup\n' >> "$home/state/03-ship-b-decision.status"
  printf 'failed: task b duplicate failed independently\n' > "$home/state/04-ship-b-failed.status"
  printf 'working: task c keeps its own current event\n' > "$home/state/05-ship-c-working.status"
  printf 'paused: detached task keeps its own external wait\n' > "$home/state/06-ship-detached.status"
  printf 'done: plain task keeps its own terminal state\n' > "$home/state/07-ship-plain.status"
  printf 'done: scout report complete\n' > "$home/state/08-scout.status"
  printf 'working: registered mate remains independently current\n' > "$home/state/09-mate.status"
  printf 'blocked [key=mate-block]: secondmate block stays task-local\n' > "$home/state/10-secondmate.status"
  printf 'done: secondmate terminal event stays task-local\n' > "$home/state/11-secondmate.status"

  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
common=$(git rev-parse --path-format=absolute --git-common-dir)
case "${1:-}" in
  axi)
    [ "${2:-}" = status ] || exit 0
    branch=$(git symbolic-ref --quiet --short HEAD)
    head=$(git rev-parse HEAD)
    printf 'primary\t%s\t%s\t%s\n' "$common" "$branch" "$head" >> "${FM_FAKE_NM_CALLS:?}"
    sleep "${FM_FAKE_NM_LATENCY:-0.04}"
    printf 'branch: %s\nhead: %s\nstatus: running\n' "$branch" "${FM_FAKE_NM_UNPROVABLE_HEAD:?}"
    ;;
  runs)
    printf 'coarse\t%s\t%s\n' "$common" "${3:-}" >> "${FM_FAKE_NM_CALLS:?}"
    sleep "${FM_FAKE_NM_LATENCY:-0.04}"
    printf 'running scale-a %s 2026-08-11\n' "${FM_FAKE_NM_UNPROVABLE_HEAD:?}"
    printf 'running scale-b %s 2026-08-11\n' "${FM_FAKE_NM_UNPROVABLE_HEAD:?}"
    printf 'running scale-c %s 2026-08-11\n' "${FM_FAKE_NM_UNPROVABLE_HEAD:?}"
    ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  : > "$calls"

  snapshot_home_manifest() {  # <home> [<additional-home>]
    local manifest_home
    for manifest_home in "$@"; do
      printf 'HOME %s\n' "$manifest_home"
      (
        cd "$manifest_home" || exit 1
        find . -type d -print | LC_ALL=C sort
        find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
          cksum "$file"
        done
      )
    done
  }
  before_manifest=$(snapshot_home_manifest "$home" "$mate")

  export FM_FAKE_NM_CALLS="$calls"
  export FM_FAKE_NM_LATENCY=0.04
  export FM_FAKE_NM_UNPROVABLE_HEAD=ffffffffffffffffffffffffffffffffffffffff
  if git -C "$repo" rev-parse --verify "${FM_FAKE_NM_UNPROVABLE_HEAD}^{commit}" >/dev/null 2>&1; then
    fail "scale fixture's rejected no-mistakes head unexpectedly exists in the repository"
  fi
  : > "$expected_raw"
  for branch in \
    01-ship-a-blocked 02-ship-a-done 03-ship-b-decision 04-ship-b-failed \
    05-ship-c-working 06-ship-detached 07-ship-plain 08-scout 09-mate \
    10-secondmate 11-secondmate; do
    PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$CREW_STATE" "$branch" >> "$expected_raw"
  done

  : > "$calls"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-11T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1786449600 \
    "$SNAPSHOT" --json 2> "$stderr_file") \
    || fail "scale snapshot public read failed"
  [ ! -s "$stderr_file" ] || fail "scale snapshot leaked private diagnostics: $(cat "$stderr_file")"
  printf '%s' "$out" > "$first_out"
  printf '%s' "$out" | jq -r '.tasks[].current_state.raw' > "$actual_raw"
  cmp -s "$expected_raw" "$actual_raw" \
    || fail "snapshot-local query reuse changed task-local public current-state bytes"

  primary_calls=$(awk -F '\t' '$1 == "primary" {n++} END {print n+0}' "$calls")
  coarse_calls=$(awk -F '\t' '$1 == "coarse" && $3 == "200" {n++} END {print n+0}' "$calls")
  total_calls=$(wc -l < "$calls" | tr -d ' ')
  [ "$primary_calls" -eq 3 ] \
    || fail "expected one primary query per exact identity, got $primary_calls: $(cat "$calls")"
  [ "$coarse_calls" -eq 1 ] \
    || fail "expected one coarse query per canonical repository, got $coarse_calls: $(cat "$calls")"
  [ "$total_calls" -eq 4 ] || fail "unexpected no-mistakes query shape: $(cat "$calls")"
  for branch in scale-a scale-b scale-c; do
    branch_calls=$(awk -F '\t' -v branch="$branch" '$1 == "primary" && $3 == branch {n++} END {print n+0}' "$calls")
    [ "$branch_calls" -eq 1 ] || fail "primary identity $branch was queried $branch_calls times"
  done

  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    .schema == "fm-fleet-snapshot.v1"
      and ([.tasks[].id] == [
        "01-ship-a-blocked", "02-ship-a-done", "03-ship-b-decision",
        "04-ship-b-failed", "05-ship-c-working", "06-ship-detached",
        "07-ship-plain", "08-scout", "09-mate", "10-secondmate", "11-secondmate"
      ])
      and ([.tasks[].kind] | map(select(. == "ship")) | length) == 7
      and ([.tasks[].kind] | map(select(. == "scout")) | length) == 1
      and ([.tasks[].kind] | map(select(. == "secondmate")) | length) == 3
      and ([.tasks[] | {id, state:.current_state.state, source:.current_state.source}] == [
        {id:"01-ship-a-blocked", state:"blocked", source:"status-log"},
        {id:"02-ship-a-done", state:"done", source:"status-log"},
        {id:"03-ship-b-decision", state:"working", source:"status-log"},
        {id:"04-ship-b-failed", state:"failed", source:"status-log"},
        {id:"05-ship-c-working", state:"working", source:"status-log"},
        {id:"06-ship-detached", state:"paused", source:"status-log"},
        {id:"07-ship-plain", state:"done", source:"status-log"},
        {id:"08-scout", state:"done", source:"status-log"},
        {id:"09-mate", state:"working", source:"status-log"},
        {id:"10-secondmate", state:"blocked", source:"status-log"},
        {id:"11-secondmate", state:"unknown", source:"none"}
      ])
      and ([.tasks[] | {id, exists:.endpoint.exists, agent_alive:.endpoint.agent_alive}] == [
        {id:"01-ship-a-blocked", exists:true, agent_alive:"not_checked"},
        {id:"02-ship-a-done", exists:true, agent_alive:"not_checked"},
        {id:"03-ship-b-decision", exists:true, agent_alive:"not_checked"},
        {id:"04-ship-b-failed", exists:true, agent_alive:"not_checked"},
        {id:"05-ship-c-working", exists:true, agent_alive:"not_checked"},
        {id:"06-ship-detached", exists:true, agent_alive:"not_checked"},
        {id:"07-ship-plain", exists:true, agent_alive:"not_checked"},
        {id:"08-scout", exists:true, agent_alive:"not_checked"},
        {id:"09-mate", exists:true, agent_alive:"alive"},
        {id:"10-secondmate", exists:true, agent_alive:"dead"},
        {id:"11-secondmate", exists:false, agent_alive:"dead"}
      ])
      and task("01-ship-a-blocked").hints.open_decisions == [
        {key:"network", verb:"blocked", summary:"task a remains independently blocked"}
      ]
      and task("03-ship-b-decision").paths.status_log.last_event == {
        state:"working", note:"task b continued unrelated setup",
        raw:"working: task b continued unrelated setup"
      }
      and task("03-ship-b-decision").hints.open_decisions == [
        {key:"shape", verb:"needs-decision", summary:"task b awaits its own decision"}
      ]
      and task("10-secondmate").hints.open_decisions == [
        {key:"mate-block", verb:"blocked", summary:"secondmate block stays task-local"}
      ]
      and all(.tasks[] | select(.id != "01-ship-a-blocked"
        and .id != "03-ship-b-decision" and .id != "10-secondmate");
        .hints.open_decisions == [])
      and task("01-ship-a-blocked").hints.blocked_event == true
      and task("03-ship-b-decision").hints.pending_decision == true
      and (.secondmate_current.records[] | select(.id == "09-mate")
        | .registered == true and .provenance.summary_valid == true)
  ' >/dev/null || fail "scale snapshot changed ordering, task truth, endpoint truth, decisions, or registered-home validity: $out"
  printf '%s' "$out" | jq -e --arg private "$calls" '
    [.. | strings | select(contains($private) or contains("FM_FAKE_NM_LATENCY"))] | length == 0
  ' >/dev/null || fail "snapshot exposed private query or performance state"

  : > "$calls"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-08-11T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1786449600 \
    "$SNAPSHOT" --json 2> "$stderr_file") \
    || fail "repeat scale snapshot public read failed"
  [ ! -s "$stderr_file" ] || fail "repeat scale snapshot leaked private diagnostics: $(cat "$stderr_file")"
  printf '%s' "$out" > "$second_out"
  cmp -s "$first_out" "$second_out" \
    || fail "separate public snapshots with identical inputs were not byte-for-byte equivalent"
  [ "$(awk -F '\t' '$1 == "primary" {n++} END {print n+0}' "$calls")" -eq 3 ] \
    || fail "a later snapshot reused primary query data from an earlier snapshot"
  [ "$(awk -F '\t' '$1 == "coarse" && $3 == "200" {n++} END {print n+0}' "$calls")" -eq 1 ] \
    || fail "a later snapshot reused coarse query data from an earlier snapshot"

  : > "$calls"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_CREW_STATE_RUNS_LIMIT=50 \
    FM_SNAPSHOT_NOW=2026-08-11T12:00:00Z FM_SNAPSHOT_NOW_EPOCH=1786449600 \
    "$SNAPSHOT" --json 2> "$stderr_file") \
    || fail "alternate-limit scale snapshot public read failed"
  [ ! -s "$stderr_file" ] || fail "alternate-limit snapshot leaked private diagnostics: $(cat "$stderr_file")"
  printf '%s' "$out" | cmp -s "$first_out" - \
    || fail "alternate coarse query limit changed task-local public snapshot bytes"
  [ "$(awk -F '\t' '$1 == "primary" {n++} END {print n+0}' "$calls")" -eq 3 ] \
    || fail "alternate limit changed exact-identity primary reuse: $(cat "$calls")"
  [ "$(awk -F '\t' '$1 == "coarse" && $3 == "50" {n++} END {print n+0}' "$calls")" -eq 5 ] \
    || fail "non-200 coarse queries were reused or skipped: $(cat "$calls")"
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 8 ] \
    || fail "alternate-limit query shape was not task-local: $(cat "$calls")"

  after_manifest=$(snapshot_home_manifest "$home" "$mate")
  [ "$before_manifest" = "$after_manifest" ] \
    || fail "public crew-state or fleet snapshot reads wrote to an operational home"
  pass "fleet snapshot reuses only raw no-mistakes queries while preserving every task and home verdict"
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

test_empty_fleet_json
test_large_backlog_crosses_argv_limit_via_public_interface
test_large_task_status_crosses_argv_limit_via_public_interface
test_large_task_metadata_crosses_argv_limit_via_public_interface
test_fixture_snapshot_json
test_snapshot_reuses_raw_no_mistakes_queries_per_identity
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
