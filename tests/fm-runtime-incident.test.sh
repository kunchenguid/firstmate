#!/usr/bin/env bash
# Behavior coverage for the bounded runtime-incident fast path.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INCIDENT="$ROOT/bin/fm-runtime-incident.py"
FLEET="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-runtime-incident)
FIXED_NOW=2026-08-26T20:00:00Z
QUOTA_FIXTURE="$ROOT/tests/fixtures/runtime-incident/quota-exhaustion.json"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

git_identity() {  # <repo>
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name "FirstMate Test"
}

make_origin() {  # <name>
  local seed=$TMP_ROOT/$1-seed bare=$TMP_ROOT/$1-origin.git
  git init --quiet --initial-branch=main "$seed"
  git_identity "$seed"
  printf 'initial\n' > "$seed/app.txt"
  git -C "$seed" add app.txt
  GIT_AUTHOR_DATE=2026-08-20T12:00:00Z GIT_COMMITTER_DATE=2026-08-20T12:00:00Z \
    git -C "$seed" commit --quiet -m initial
  git clone --quiet --bare "$seed" "$bare"
  git -C "$seed" remote add origin "file://$bare"
  git -C "$seed" push --quiet -u origin main
  printf '%s\n' "$bare"
}

clone_origin() {  # <origin> <path>
  git clone --quiet "$1" "$2"
  git_identity "$2"
}

advance_origin() {  # <seed> <text> <date>
  printf '%s\n' "$2" >> "$1/app.txt"
  git -C "$1" add app.txt
  GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git -C "$1" commit --quiet -m "$2"
  git -C "$1" push --quiet origin main
}

run_triage() {  # <home> <id> <repo> <summary> [extra args...]
  local home=$1 id=$2 repo=$3 summary=$4
  shift 4
  FM_HOME="$home" FM_INCIDENT_NOW="$FIXED_NOW" \
    "$INCIDENT" triage --incident "$id" --repo "$repo" --summary "$summary" --json "$@"
}

make_crew_state_fake() {  # <home>
  local home=$1 fake=$home/fm-crew-state.sh
  cat > "$fake" <<'SH'
#!/usr/bin/env bash
state_file=${FM_STATE_OVERRIDE:?}/${1:?}.current-state
if [ -f "$state_file" ]; then
  cat "$state_file"
else
  printf 'state: unknown · source: none · no current-state fixture\n'
fi
SH
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

test_repository_and_worker_reconciliation() {
  local home origin seed stale current out before after crew_state
  home=$(make_home reconcile)
  origin=$(make_origin reconcile)
  seed=$TMP_ROOT/reconcile-seed
  stale=$home/projects/titan-old
  current=$home/projects/titan-current
  clone_origin "$origin" "$stale"
  advance_origin "$seed" "current incident baseline" 2026-08-22T12:00:00Z
  clone_origin "$origin" "$current"
  stale=$(cd "$stale" && pwd -P)
  current=$(cd "$current" && pwd -P)
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] quota-worker - Restore Titan companion after quota incident (repo: titan) (kind: ship)
- [ ] semantic-worker - Restore Redis provider limits (repo: titan) (kind: ship)
- [ ] historical-worker - Tune Redis provider capacity (repo: titan) (kind: ship)
- [ ] finished-worker - Completed unrelated maintenance (repo: titan) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/quota-worker.meta" \
    "window=firstmate:fm-quota-worker" \
    "worktree=$stale" \
    "project=$stale" \
    "harness=codex" \
    "kind=ship" \
    "spawn_gen=s1787770800.1.1"
  printf 'working: building unrelated pilot fallback architecture\n' > "$home/state/quota-worker.status"
  printf 'state: working · source: run-step · validating the quota repair\n' > "$home/state/quota-worker.current-state"
  fm_write_meta "$home/state/semantic-worker.meta" \
    "window=firstmate:fm-semantic-worker" \
    "worktree=$current" \
    "project=$current" \
    "harness=codex" \
    "kind=ship"
  printf 'working: coordinating unrelated provider capacity\n' > "$home/state/semantic-worker.status"
  printf 'state: working · source: pane · repairing Upstash quota exhaustion\n' > "$home/state/semantic-worker.current-state"
  fm_write_meta "$home/state/historical-worker.meta" \
    "window=firstmate:fm-historical-worker" \
    "worktree=$current" \
    "project=$current" \
    "harness=codex" \
    "kind=ship"
  printf 'working: repairing Upstash quota exhaustion\n' > "$home/state/historical-worker.status"
  printf 'state: working · source: pane · coordinating provider capacity\n' > "$home/state/historical-worker.current-state"
  fm_write_meta "$home/state/finished-worker.meta" \
    "window=firstmate:fm-finished-worker" \
    "worktree=$current" \
    "project=$current" \
    "harness=codex" \
    "kind=ship"
  printf 'state: done · source: run-step · validation complete\n' > "$home/state/finished-worker.current-state"
  crew_state=$(make_crew_state_fake "$home")
  before=$(git -C "$current" worktree list --porcelain | rg -c '^worktree ')
  out=$(FM_CREW_STATE_BIN="$crew_state" run_triage "$home" quota-exhaustion "$current" \
    "Titan companion unavailable after Upstash quota exhaustion" \
    --evidence "$QUOTA_FIXTURE" --scan-root "$home/projects")
  after=$(git -C "$current" worktree list --porcelain | rg -c '^worktree ')
  [ "$before" = "$after" ] || fail "triage created a worktree"
  printf '%s' "$out" | jq -e --arg stale "$stale" --arg current "$current" '
    .repository.multiple_copies_same_origin == true
      and .repository.authoritative_repository == $current
      and (.repository.canonical_remote | startswith("file://"))
      and ([.repository.branches[].name] | index("main")) != null
      and (.repository.superseded_continuations | index($stale)) != null
      and .repository.worktrees[0].path == $current
      and .repository.inventory.worktrees.repository == $current
      and ([.workers.registry_entries[].id] | index("quota-worker")) != null
      and ([.workers.stale_registry_entries[].id] | index("quota-worker")) != null
      and ([.workers.wrong_worktree[].id] | index("quota-worker")) != null
      and ([.workers.scope_drifted[].id] | index("quota-worker")) != null
      and (.workers.active[] | select(.id == "quota-worker")
        | .working_directory == $stale
          and .objective == "Restore Titan companion after quota incident"
          and (.age_seconds | type) == "number"
          and .current_state.state == "working"
          and .current_state.source == "run-step"
          and .latest_reported_event.historical == true
          and .latest_reported_event.line == "working: building unrelated pilot fallback architecture"
          and .activity_matches_incident == false)
      and (.workers.registry_entries[] | select(.id == "semantic-worker")
        | .active == true
          and .activity_matches_incident == true
          and (.match_reason | contains("upstash")))
      and ([.workers.scope_drifted[].id] | index("semantic-worker")) == null
      and (.workers.registry_entries[] | select(.id == "historical-worker")
        | .active == true
          and .latest_reported_event.historical == true
          and .activity_matches_incident == null
          and .match_reason == "no lexical overlap; semantic relevance is unknown")
      and ([.workers.scope_drifted[].id] | index("historical-worker")) == null
      and (.workers.registry_entries[] | select(.id == "finished-worker")
        | .active == false
          and .current_state.state == "done"
          and .latest_reported_event.available == false)
      and ([.workers.active[].id] | index("finished-worker")) == null
  ' >/dev/null || fail "repository or worker reconciliation was incomplete: $out"
  pass "triage detects stale registry paths, duplicate clones, wrong working copies, and scope drift"
}

test_external_quota_no_code_lifecycle_and_status() {
  local home origin repo out view bearings snapshot
  home=$(make_home quota-lifecycle)
  origin=$(make_origin quota-lifecycle)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  out=$(run_triage "$home" quota-lifecycle "$repo" \
    "Titan companion cannot read state" --evidence "$QUOTA_FIXTURE")
  printf '%s' "$out" | jq -e '
    .phase == "approval"
      and .outcome == "operational_repair"
      and .diagnosis.classification == "external dependency, quota, billing, credential, or configuration failure"
      and .diagnosis.code_change_required == "no"
      and .diagnosis.operational_repair_ready == true
      and .diagnosis.observations.runtime_errors[0].code == "command_quota_exceeded"
      and .diagnosis.observations.production.health == "degraded"
      and .diagnosis.observations.external_providers[0].status == "quota_exhausted"
      and (.diagnosis.supporting_evidence | length) == 1
      and .approval.kind == "paid_plan_change"
      and .guardrails.new_worktree_allowed == false
      and .guardrails.code_validation_allowed == false
      and .guardrails.other_worker_mutation_authorized == false
  ' >/dev/null || fail "quota failure did not stay on the no-code fast path: $out"

  if FM_HOME="$home" "$INCIDENT" approve --incident quota-lifecycle \
    --kind service_restart --note wrong >/dev/null 2>&1; then
    fail "mismatched approval kind was accepted"
  fi
  FM_HOME="$home" FM_INCIDENT_NOW=2026-08-26T20:05:00Z \
    "$INCIDENT" approve --incident quota-lifecycle --kind paid_plan_change \
    --note "Captain approved the Upstash plan upgrade." >/dev/null
  FM_HOME="$home" FM_INCIDENT_NOW=2026-08-26T20:06:00Z \
    "$INCIDENT" repair --incident quota-lifecycle \
    --note "Upstash plan upgraded and companion re-paired." >/dev/null
  cat > "$home/verified.json" <<'EOF'
{
  "verification": {
    "runtime_path_ok": true,
    "checks": [
      {"name": "production identity", "status": "pass", "evidence": "expected release"},
      {"name": "upstash quota", "status": "healthy", "evidence": "commands accepted"},
      {"name": "companion pairing", "status": "pass", "evidence": "paired"},
      {"name": "user status path", "status": "pass", "evidence": "state visible"}
    ]
  }
}
EOF
  FM_HOME="$home" FM_INCIDENT_NOW=2026-08-26T20:07:00Z \
    "$INCIDENT" verify --incident quota-lifecycle --evidence "$home/verified.json" >/dev/null
  if FM_HOME="$home" "$INCIDENT" repair --incident quota-lifecycle \
    --note "repeat repair" >/dev/null 2>&1; then
    fail "repeated repair regressed completed verification"
  fi
  if FM_HOME="$home" "$INCIDENT" verify --incident quota-lifecycle \
    --evidence "$home/verified.json" >/dev/null 2>&1; then
    fail "repeated verification rewrote a completed incident"
  fi
  if run_triage "$home" quota-lifecycle "$repo" \
    "Titan companion cannot read state again" --evidence "$QUOTA_FIXTURE" >/dev/null 2>&1; then
    fail "retriage regressed an advanced incident lifecycle"
  fi
  out=$(FM_HOME="$home" "$INCIDENT" status --incident quota-lifecycle --json)
  printf '%s' "$out" | jq -e '
    .verification.status == "complete"
      and .repair.status == "complete"
      and .approval.status == "approved"
      and .updated_at == "2026-08-26T20:07:00Z"
      and ([.flow[].status] | all(. == "complete" or . == "not_required"))
  ' >/dev/null || fail "quota repair lifecycle did not finish verification: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "triage → diagnosis → approval → repair → verification" \
    "fleet status should show the incident flow"
  assert_contains "$view" "quota-lifecycle" "fleet status should show the incident"
  snapshot=$(FM_HOME="$home" "$FLEET" --json)
  printf '%s' "$snapshot" | jq -e '
    .runtime_incidents.truncated == 0
      and (.runtime_incidents.records[0] | has("repository") | not)
      and .runtime_incidents.records[0].diagnosis.code_change_required == "no"
  ' >/dev/null || fail "fleet snapshot did not use the bounded incident projection: $snapshot"
  bearings=$(FM_HOME="$home" "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    .runtime_incidents[]
    | select(.id == "quota-lifecycle")
    | .phase == "verification"
      and .code_change_required == "no"
      and .flow == "triage → diagnosis → approval → repair → verification"
  ' >/dev/null || fail "bearings omitted the runtime-incident fast path: $bearings"
  pass "external quota failure requests one approval, records the narrow repair, and verifies the full path"
}

test_lifecycle_transitions_read_and_write_under_one_lock() {
  local home origin repo record lock pending advanced ready release holder approver out i
  home=$(make_home lifecycle-lock)
  origin=$(make_origin lifecycle-lock)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  run_triage "$home" lock-race "$repo" "Titan companion cannot read state" \
    --evidence "$QUOTA_FIXTURE" >/dev/null
  record=$home/state/incidents/lock-race.json
  lock=$home/state/incidents/lock-race.lock
  pending=$home/pending.json
  advanced=$home/advanced.json
  ready=$home/lock-ready
  release=$home/lock-release
  cp "$record" "$pending"
  FM_HOME="$home" "$INCIDENT" approve --incident lock-race --kind paid_plan_change \
    --note "Captain approved the Upstash plan upgrade." >/dev/null
  FM_HOME="$home" "$INCIDENT" repair --incident lock-race \
    --note "Upstash plan upgraded." >/dev/null
  cp "$record" "$advanced"
  cp "$pending" "$record"

  python3 - "$lock" "$ready" "$release" <<'PY' &
import fcntl
from pathlib import Path
import sys
import time

lock_path, ready_path, release_path = map(Path, sys.argv[1:])
with lock_path.open("a+") as lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    ready_path.touch()
    while not release_path.exists():
        time.sleep(0.01)
PY
  holder=$!
  for i in $(seq 1 100); do
    [ -e "$ready" ] && break
    kill -0 "$holder" 2>/dev/null || fail "incident lock holder exited early"
    sleep 0.01
  done
  [ -e "$ready" ] || fail "incident lock holder did not become ready"
  FM_HOME="$home" "$INCIDENT" approve --incident lock-race --kind paid_plan_change \
    --note "stale concurrent approval" >"$home/approve.out" 2>"$home/approve.err" &
  approver=$!
  sleep 0.2
  kill -0 "$approver" 2>/dev/null || fail "concurrent approval did not wait for the incident lock"
  cp "$advanced" "$record"
  : > "$release"
  wait "$holder" || fail "incident lock holder failed"
  if wait "$approver"; then
    fail "stale approval overwrote a repaired incident"
  fi
  out=$(FM_HOME="$home" "$INCIDENT" status --incident lock-race --json)
  printf '%s' "$out" | jq -e '
    .phase == "verification"
      and .approval.status == "approved"
      and .repair.status == "complete"
      and .verification.status == "pending"
  ' >/dev/null || fail "locked transition did not preserve the advanced incident: $out"
  pass "incident transitions read, validate, mutate, and write under one lock"
}

test_proposed_hotfix_already_deployed() {
  local home origin seed repo hotfix deployed before after out
  home=$(make_home already-deployed)
  origin=$(make_origin already-deployed)
  seed=$TMP_ROOT/already-deployed-seed
  advance_origin "$seed" "hotfix" 2026-08-21T12:00:00Z
  hotfix=$(git -C "$seed" rev-parse HEAD)
  advance_origin "$seed" "later release" 2026-08-22T12:00:00Z
  deployed=$(git -C "$seed" rev-parse HEAD)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  jq -n --arg deployed "$deployed" --arg hotfix "$hotfix" '
    {production:{commit:$deployed,proposed_hotfix_commit:$hotfix,health:"degraded"}}
  ' > "$home/deployed.json"
  before=$(git -C "$repo" worktree list --porcelain | rg -c '^worktree ')
  out=$(run_triage "$home" already-deployed "$repo" \
    "Production still fails after the proposed hotfix" --evidence "$home/deployed.json")
  after=$(git -C "$repo" worktree list --porcelain | rg -c '^worktree ')
  [ "$before" = "$after" ] || fail "already-deployed diagnosis created a duplicate worktree"
  printf '%s' "$out" | jq -e '
    .diagnosis.hotfix_already_deployed == true
      and .diagnosis.code_change_required == "no"
      and .diagnosis.classification == "unknown"
      and .diagnosis.operational_repair_ready == false
      and .phase == "diagnosis"
      and .outcome == "more_evidence_required"
      and .guardrails.new_worktree_allowed == false
  ' >/dev/null || fail "deployed hotfix did not block duplicate code work: $out"
  if FM_HOME="$home" "$INCIDENT" repair --incident already-deployed \
    --note "should not run" >/dev/null 2>&1; then
    fail "already-deployed diagnosis allowed an unproven operational repair"
  fi
  pass "a hotfix already present in production blocks duplicate code work"
}

test_proven_application_defect_escalates() {
  local home origin repo out
  home=$(make_home code-defect)
  origin=$(make_origin code-defect)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  cat > "$home/defect.json" <<'EOF'
{
  "runtime": {
    "defect_proven": true,
    "defect_evidence": [
      "A production request and the same local request both enter the invalid cache-key branch."
    ],
    "reproduction": "status request returns 500",
    "proven_path": "same request succeeds with a valid cache key"
  }
}
EOF
  out=$(run_triage "$home" code-defect "$repo" \
    "Status endpoint returns 500 for one valid account" --evidence "$home/defect.json")
  printf '%s' "$out" | jq -e '
    .diagnosis.classification == "application code defect"
      and .diagnosis.code_change_required == "yes"
      and .outcome == "escalate_to_code_change"
      and .guardrails.new_worktree_allowed == true
      and .guardrails.code_validation_allowed == true
      and .repository.authoritative_worktree != null
      and .approval.required == false
  ' >/dev/null || fail "proven application defect did not escalate cleanly: $out"
  if run_triage "$home" code-defect "$repo" \
    "Status endpoint failure needs another look" >/dev/null 2>&1; then
    fail "retriage erased a proven code escalation"
  fi
  out=$(FM_HOME="$home" "$INCIDENT" status --incident code-defect --json)
  printf '%s' "$out" | jq -e '
    .diagnosis.code_change_required == "yes"
      and .outcome == "escalate_to_code_change"
      and .guardrails.new_worktree_allowed == true
  ' >/dev/null || fail "proven code escalation was not monotonic: $out"
  pass "runtime evidence proving an application defect escalates to one current-main code workflow"
}

test_remaining_classifier_categories() {
  local home origin repo out
  home=$(make_home categories)
  origin=$(make_origin categories)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"

  printf '{"production":{"routing_mismatch":true}}\n' > "$home/deployment.json"
  out=$(run_triage "$home" deployment "$repo" "Wrong production route" --evidence "$home/deployment.json")
  printf '%s' "$out" | jq -e '
    .diagnosis.classification == "deployment/routing defect"
      and .diagnosis.code_change_required == "no"
  ' >/dev/null || fail "deployment classifier failed: $out"

  printf '{"local_services":[{"name":"companion-relay","status":"stopped"}]}\n' > "$home/service.json"
  out=$(run_triage "$home" service "$repo" "Local companion relay is unavailable" --evidence "$home/service.json")
  printf '%s' "$out" | jq -e '
    .diagnosis.classification == "local background-service failure"
      and .diagnosis.code_change_required == "no"
  ' >/dev/null || fail "local-service classifier failed: $out"

  printf '{"external_providers":[{"name":"upstash","status":"quota_available"}]}\n' > "$home/unknown.json"
  out=$(run_triage "$home" unknown "$repo" "Intermittent unexplained failure" --evidence "$home/unknown.json")
  printf '%s' "$out" | jq -e '
    .diagnosis.classification == "unknown"
      and .diagnosis.code_change_required == "not yet proven"
      and .guardrails.new_worktree_allowed == false
  ' >/dev/null || fail "unknown classifier failed closed: $out"
  out=$(FM_HOME="$home" FM_INCIDENT_STATUS_LIMIT=2 "$INCIDENT" status --json --compact)
  printf '%s' "$out" | jq -e '
    (.records | length) == 2 and .truncated == 1
  ' >/dev/null || fail "bounded incident status did not disclose truncation: $out"
  pass "deployment, local-service, and unknown incidents stay in their bounded categories"
}

test_remote_credentials_are_not_recorded() {
  local home origin repo out
  home=$(make_home credential-redaction)
  origin=$(make_origin credential-redaction)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  git -C "$repo" remote set-url origin https://secret-token@example.com/acme/titan.git
  out=$(run_triage "$home" credential-redaction "$repo" "Unknown production failure")
  printf '%s' "$out" | jq -e '
    .repository.canonical_remote == "https://example.com/acme/titan"
      and ([.repository.copies[] | has("origin_raw")] | any | not)
  ' >/dev/null || fail "incident record retained remote credentials: $out"
  pass "repository identity is normalized without persisting remote credentials"
}

test_bounded_inventory_omissions_are_disclosed() {
  local home origin repo crew_state out human view bearings id i
  home=$(make_home bounded-omissions)
  origin=$(make_origin bounded-omissions)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  for i in $(seq 1 100); do
    git -C "$repo" branch "inventory-$i"
  done
  crew_state=$(make_crew_state_fake "$home")
  for i in $(seq -w 1 65); do
    mkdir -p "$home/registered-$i"
    fm_write_meta "$home/state/worker-$i.meta" \
      "window=firstmate:fm-worker-$i" \
      "worktree=$home/registered-$i" \
      "project=$home/registered-$i" \
      "harness=codex" \
      "kind=ship"
  done
  out=$(FM_CREW_STATE_BIN="$crew_state" run_triage "$home" bounded-base "$repo" \
    "Unexplained production failure")
  printf '%s' "$out" | jq -e '
    .workers.inventory == {shown:64,omitted:1}
      and .repository.inventory.registered_worker_metadata == {shown:64,omitted:1}
      and .repository.inventory.candidate_paths.omitted >= 1
      and .repository.inventory.branches.omitted_at_least >= 1
  ' >/dev/null || fail "bounded triage inventories hid omissions: $out"
  human=$(FM_HOME="$home" "$INCIDENT" status --incident bounded-base)
  assert_contains "$human" "Workers omitted by bound: 1" "human incident status hid worker omissions"
  assert_contains "$human" "Repository candidates omitted by bound: 1" "human incident status hid repository omissions"
  assert_contains "$human" "Branches omitted by bound: at least 1" "human incident status hid branch omissions"

  rm -f "$home/state"/*.meta
  for i in $(seq -w 1 64); do
    id=bounded-copy-$i
    jq --arg id "$id" '.id=$id | .summary=$id' \
      "$home/state/incidents/bounded-base.json" > "$home/state/incidents/$id.json"
  done
  out=$(FM_HOME="$home" FM_INCIDENT_STATUS_LIMIT=100 "$INCIDENT" status --json --compact)
  printf '%s' "$out" | jq -e '
    .input == {shown:64,omitted:1}
      and (.records | length) == 64
      and .truncated == 0
  ' >/dev/null || fail "incident input bound hid omitted records: $out"
  human=$(FM_HOME="$home" FM_INCIDENT_STATUS_LIMIT=100 "$INCIDENT" status)
  assert_contains "$human" "Warning: 1 incident record(s) omitted by the input bound." \
    "human incident list hid input omissions"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "Warning: 1 incident record(s) are omitted by the input bound." \
    "fleet view hid incident input omissions"
  bearings=$(FM_HOME="$home" "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    .omitted | any(.surface == "runtime incident records omitted by input bound: 1")
  ' >/dev/null || fail "Bearings hid incident input omissions: $bearings"
  pass "bounded worker, repository, branch, and incident omissions stay visible"
}

test_worktree_inventory_is_authority_bound_and_enrichment_is_capped() {
  local home origin repo fakebin fixture marker omitted real_git head out i suffix
  home=$(make_home worktree-bound)
  origin=$(make_origin worktree-bound)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  repo=$(cd "$repo" && pwd -P)
  fakebin=$home/fakebin
  fixture=$home/worktrees.porcelain
  marker=$home/omitted-probed
  real_git=$(command -v git)
  head=$(git -C "$repo" rev-parse HEAD)
  mkdir -p "$fakebin"
  {
    printf 'worktree %s\nHEAD %s\nbranch refs/heads/main\n\n' "$repo" "$head"
    for i in $(seq 1 65); do
      printf -v suffix '%03d' "$i"
      mkdir -p "$home/linked-$suffix"
      printf 'worktree %s\nHEAD %s\nbranch refs/heads/linked-%s\n\n' \
        "$home/linked-$suffix" "$head" "$suffix"
    done
  } > "$fixture"
  omitted=$(cd "$home/linked-065" && pwd -P)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_FAKE_WORKTREE_REPO" ] &&
  [ "${3:-}" = worktree ] && [ "${4:-}" = list ]; then
  cat "$FM_FAKE_WORKTREE_FIXTURE"
  exit 0
fi
if [ "${1:-}" = -C ] && [ "${2:-}" = "$FM_FAKE_WORKTREE_OMITTED" ]; then
  : > "$FM_FAKE_WORKTREE_MARKER"
  exit 1
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  out=$(
    export PATH="$fakebin:$PATH"
    export FM_REAL_GIT="$real_git"
    export FM_FAKE_WORKTREE_REPO="$repo"
    export FM_FAKE_WORKTREE_FIXTURE="$fixture"
    export FM_FAKE_WORKTREE_OMITTED="$omitted"
    export FM_FAKE_WORKTREE_MARKER="$marker"
    run_triage "$home" worktree-bound "$repo" "Unexplained production failure"
  )
  [ ! -e "$marker" ] || fail "worktree enrichment probed beyond its disclosed cap"
  printf '%s' "$out" | jq -e --arg repo "$repo" '
    (.repository.worktrees | length) == 64
      and .repository.inventory.candidate_worktrees == {repository:$repo,shown:64,omitted:2}
      and .repository.inventory.worktrees == {repository:$repo,shown:64,omitted:2}
  ' >/dev/null || fail "worktree authority or omission accounting was incorrect: $out"
  pass "worktree inventory follows selected authority and caps per-copy enrichment"
}

test_repository_and_worker_reconciliation
test_external_quota_no_code_lifecycle_and_status
test_lifecycle_transitions_read_and_write_under_one_lock
test_proposed_hotfix_already_deployed
test_proven_application_defect_escalates
test_remaining_classifier_categories
test_remote_credentials_are_not_recorded
test_bounded_inventory_omissions_are_disclosed
test_worktree_inventory_is_authority_bound_and_enrichment_is_capped
