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

test_repository_and_worker_reconciliation() {
  local home origin seed stale current out before after
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
  before=$(git -C "$current" worktree list --porcelain | rg -c '^worktree ')
  out=$(run_triage "$home" quota-exhaustion "$current" \
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
      and ([.workers.registry_entries[].id] | index("quota-worker")) != null
      and ([.workers.stale_registry_entries[].id] | index("quota-worker")) != null
      and ([.workers.wrong_worktree[].id] | index("quota-worker")) != null
      and ([.workers.scope_drifted[].id] | index("quota-worker")) != null
      and (.workers.active[] | select(.id == "quota-worker")
        | .working_directory == $stale
          and .objective == "Restore Titan companion after quota incident"
          and (.age_seconds | type) == "number"
          and .activity_matches_incident == false)
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
  out=$(FM_HOME="$home" "$INCIDENT" status --incident quota-lifecycle --json)
  printf '%s' "$out" | jq -e '
    .verification.status == "complete"
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

test_repository_and_worker_reconciliation
test_external_quota_no_code_lifecycle_and_status
test_proposed_hotfix_already_deployed
test_proven_application_defect_escalates
test_remaining_classifier_categories
test_remote_credentials_are_not_recorded
