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
  local home=$1 fake
  fake=$home/fm-crew-state.sh
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

test_remote_worker_directory_remains_remote() {
  local home origin repo remote_path qualified crew_state out
  home=$(make_home remote-worker)
  origin=$(make_origin remote-worker)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  remote_path=$home/remote-host-only/titan
  mkdir -p "$(dirname "$remote_path")"
  clone_origin "$origin" "$remote_path"
  qualified=remote-mac:$remote_path
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] remote-worker - Restore Upstash quota after exhaustion (repo: titan) (kind: secondmate)

## Queued

## Done
EOF
  fm_write_meta "$home/state/remote-worker.meta" \
    "worktree=$remote_path" \
    "project=/srv/firstmate" \
    "home=$remote_path" \
    "remote_host=remote-mac" \
    "kind=secondmate"
  printf 'state: working · source: remote · repairing Upstash quota exhaustion\n' > \
    "$home/state/remote-worker.current-state"
  crew_state=$(make_crew_state_fake "$home")
  out=$(FM_CREW_STATE_BIN="$crew_state" run_triage "$home" remote-worker "$repo" \
    "Upstash quota exhaustion")
  printf '%s' "$out" | jq -e --arg qualified "$qualified" --arg remote_path "$remote_path" '
    (.workers.registry_entries[] | select(.id == "remote-worker")
      | .working_directory == $qualified
        and .remote_host == "remote-mac"
        and .active == true
        and .activity_matches_incident == true
        and .repository_match == null
        and .wrong_worktree == null)
      and ([.repository.copies[].path] | index($remote_path)) == null
      and ([.workers.active[].id] | index("remote-worker")) != null
      and ([.workers.stale_registry_entries[].id] | index("remote-worker")) == null
      and ([.workers.wrong_worktree[].id] | index("remote-worker")) == null
      and ([.workers.scope_drifted[].id] | index("remote-worker")) == null
  ' >/dev/null || fail "remote worker directory was evaluated as a local path: $out"
  pass "triage preserves remote worker directory authority"
}

test_git_triage_probes_disable_optional_locks() {
  local home origin repo fakebin real_git marker out
  home=$(make_home read-only-git)
  origin=$(make_origin read-only-git)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  fakebin=$home/fakebin
  real_git=$(command -v git)
  marker=$home/git-probe-used-optional-locks
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${GIT_OPTIONAL_LOCKS:-}" != 0 ]; then
  printf '%s\n' "$*" >> "${FM_GIT_PROBE_MARKER:?}"
fi
exec "${FM_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"
  out=$(GIT_OPTIONAL_LOCKS=1 FM_REAL_GIT="$real_git" FM_GIT_PROBE_MARKER="$marker" \
    PATH="$fakebin:$PATH" run_triage "$home" read-only-git "$repo" \
    "Unknown production failure")
  [ ! -e "$marker" ] || fail "triage Git probes allowed optional index locks"
  printf '%s' "$out" | jq -e '
    .repository.canonical_repository != null
      and .guardrails.project_code_edited_during_triage == false
  ' >/dev/null || fail "read-only Git probe enforcement broke triage: $out"
  pass "triage disables optional locks for every Git probe"
}

test_external_quota_no_code_lifecycle_and_status() {
  local home origin repo out view bearings snapshot bypass_evidence invalid_kind invalid_request
  home=$(make_home quota-lifecycle)
  origin=$(make_origin quota-lifecycle)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  bypass_evidence=$home/quota-with-approval-bypass.json
  jq '.approval.required=false' "$QUOTA_FIXTURE" > "$bypass_evidence"
  invalid_kind=$home/quota-with-empty-approval-kind.json
  invalid_request=$home/quota-with-invalid-approval-request.json
  jq '.approval.kind=""' "$QUOTA_FIXTURE" > "$invalid_kind"
  jq '.approval.request=42' "$QUOTA_FIXTURE" > "$invalid_request"
  if run_triage "$home" invalid-approval-kind "$repo" \
    "Titan companion cannot read state" --evidence "$invalid_kind" >/dev/null 2>&1; then
    fail "empty approval kind was accepted"
  fi
  if run_triage "$home" invalid-approval-request "$repo" \
    "Titan companion cannot read state" --evidence "$invalid_request" >/dev/null 2>&1; then
    fail "non-string approval request was accepted"
  fi
  out=$(run_triage "$home" quota-lifecycle "$repo" \
    "Titan companion cannot read state" --evidence "$bypass_evidence")
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
      and .approval.required == true
      and .approval.kind == "paid_plan_change"
      and .approval.status == "pending"
      and .guardrails.new_worktree_allowed == false
      and .guardrails.code_validation_allowed == false
      and .guardrails.other_worker_mutation_authorized == false
  ' >/dev/null || fail "quota failure did not stay on the no-code fast path: $out"

  if run_triage "$home" quota-lifecycle "$repo" \
    "Titan companion cannot read state again" >/dev/null 2>&1; then
    fail "retriage erased a pending operational approval"
  fi
  out=$(FM_HOME="$home" "$INCIDENT" status --incident quota-lifecycle --json)
  printf '%s' "$out" | jq -e '
    .phase == "approval"
      and .approval.status == "pending"
      and .approval.kind == "paid_plan_change"
      and .repair.status == "pending"
      and .verification.status == "pending"
  ' >/dev/null || fail "pending approval was not monotonic: $out"

  if FM_HOME="$home" "$INCIDENT" repair --incident quota-lifecycle \
    --note "repair before approval" >/dev/null 2>&1; then
    fail "operational repair bypassed the explicit approval transition"
  fi

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
  cat > "$home/failed-verification.json" <<'EOF'
{
  "verification": {
    "runtime_path_ok": false,
    "checks": [
      {"name": "user status path", "status": "fail", "evidence": "state unavailable"}
    ]
  }
}
EOF
  if FM_HOME="$home" FM_INCIDENT_NOW=2026-08-26T20:06:30Z \
    "$INCIDENT" verify --incident quota-lifecycle \
    --evidence "$home/failed-verification.json" >/dev/null 2>&1; then
    fail "failed runtime verification was reported complete"
  fi
  cat > "$home/incomplete-verification.json" <<'EOF'
{
  "verification": {
    "runtime_path_ok": true,
    "companion_connectivity_required": false,
    "checks": [
      {
        "scope": "user_visible_path",
        "name": "user status path",
        "status": "pass",
        "evidence": "state visible"
      }
    ]
  }
}
EOF
  if FM_HOME="$home" FM_INCIDENT_NOW=2026-08-26T20:06:45Z \
    "$INCIDENT" verify --incident quota-lifecycle \
    --evidence "$home/incomplete-verification.json" >/dev/null 2>&1; then
    fail "incomplete passing checks closed the complete runtime path"
  fi
  bearings=$(FM_HOME="$home" "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    .runtime_incidents[]
    | select(.id == "quota-lifecycle")
    | .verification == "current"
      and .flow == "triage:complete → diagnosis:complete → approval:complete → repair:complete → verification:current"
  ' >/dev/null || fail "Bearings hid the failed verification lifecycle: $bearings"
  cat > "$home/verified.json" <<'EOF'
{
  "verification": {
    "runtime_path_ok": true,
    "companion_connectivity_required": true,
    "checks": [
      {"scope": "production_identity", "name": "production identity", "status": "pass", "evidence": "expected release"},
      {"scope": "repaired_component_health", "name": "upstash quota", "status": "healthy", "evidence": "commands accepted"},
      {"scope": "companion_connectivity", "name": "companion pairing", "status": "pass", "evidence": "paired"},
      {"scope": "user_visible_path", "name": "user status path", "status": "pass", "evidence": "state visible"}
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
      and .verification == "complete"
      and .flow == "triage:complete → diagnosis:complete → approval:complete → repair:complete → verification:complete"
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

test_stale_remote_never_wins_fallback_authority() {
  local home origin seed stale fresh fresh_head out
  home=$(make_home stale-authority)
  origin=$(make_origin stale-authority)
  seed=$TMP_ROOT/stale-authority-seed
  stale=$home/projects/titan-stale
  fresh=$home/projects/titan-fresh
  clone_origin "$origin" "$stale"
  advance_origin "$seed" "newer history with older timestamp" 2026-08-19T12:00:00Z
  clone_origin "$origin" "$fresh"
  printf 'local diagnostic\n' > "$fresh/untracked.txt"
  stale=$(cd "$stale" && pwd -P)
  fresh=$(cd "$fresh" && pwd -P)
  fresh_head=$(git -C "$fresh" rev-parse refs/remotes/origin/main)
  out=$(run_triage "$home" stale-authority "$stale" \
    "Unexplained production failure" --scan-root "$home/projects")
  printf '%s' "$out" | jq -e --arg stale "$stale" --arg fresh "$fresh" --arg head "$fresh_head" '
    .repository.authoritative_repository == $fresh
      and .repository.authoritative_worktree == null
      and .repository.authoritative_remote_head == $head
      and (.repository.copies[] | select(.path == $stale) | .stale_remote == true)
      and (.repository.copies[] | select(.path == $fresh) | .stale_remote == false)
      and (.repository.superseded_continuations | index($stale)) != null
  ' >/dev/null || fail "fallback authority selected a proven stale remote: $out"
  pass "fallback authority excludes every proven stale remote"
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
      and .diagnosis.code_change_required == "not yet proven"
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
  },
  "diagnosis": {
    "classification": "application code defect",
    "probable_root_cause": "The invalid cache-key branch rejects a valid account request.",
    "supporting_evidence": [
      "The production and local reproductions diverge from the proven valid-cache-key path at the same branch."
    ],
    "code_change_required": "yes"
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

test_raw_evidence_requires_agent_judgment() {
  local home origin repo out
  home=$(make_home agent-judgment)
  origin=$(make_origin agent-judgment)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"

  cat > "$home/raw-unadjudicated.json" <<'EOF'
{
  "runtime": {
    "errors": [
      {"source": "upstash", "kind": "quota", "code": "command_quota_exceeded"}
    ]
  },
  "external_providers": [
    {"name": "upstash", "status": "quota_exhausted", "code": "command_quota_exceeded"}
  ],
  "approval": {
    "kind": "paid_plan_change",
    "request": "Approve the Upstash plan upgrade only."
  }
}
EOF
  out=$(run_triage "$home" raw-unadjudicated "$repo" \
    "Status fails after an Upstash quota report" \
    --evidence "$home/raw-unadjudicated.json")
  printf '%s' "$out" | jq -e '
    .phase == "diagnosis"
      and .outcome == "more_evidence_required"
      and .diagnosis.classification == "unknown"
      and .diagnosis.code_change_required == "not yet proven"
      and .diagnosis.probable_root_cause == "agent diagnosis is pending; raw observations do not authorize a workflow"
      and .approval.required == false
      and .approval.status == "not_required"
      and .guardrails.new_worktree_allowed == false
      and .guardrails.code_validation_allowed == false
  ' >/dev/null || fail "raw evidence selected an authority-sensitive workflow without agent judgment: $out"
  pass "raw runtime evidence cannot replace agent diagnosis or authorize a workflow"
}

test_agent_adjudicated_categories() {
  local home origin repo out
  home=$(make_home categories)
  origin=$(make_origin categories)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"

  cat > "$home/deployment.json" <<'EOF'
{
  "production": {"routing_mismatch": true},
  "diagnosis": {
    "classification": "deployment/routing defect",
    "probable_root_cause": "Production routes requests to the wrong release.",
    "supporting_evidence": ["The production route identity differs from the expected release."],
    "code_change_required": "no"
  },
  "approval": {
    "kind": "production_route_change",
    "request": "Approve only the production route correction."
  }
}
EOF
  out=$(run_triage "$home" deployment "$repo" "Wrong production route" --evidence "$home/deployment.json")
  printf '%s' "$out" | jq -e '
    .diagnosis.classification == "deployment/routing defect"
      and .diagnosis.code_change_required == "no"
  ' >/dev/null || fail "agent-adjudicated deployment diagnosis failed: $out"

  cat > "$home/service.json" <<'EOF'
{
  "local_services": [{"name": "companion-relay", "status": "stopped"}],
  "diagnosis": {
    "classification": "local background-service failure",
    "probable_root_cause": "The local companion relay is stopped.",
    "supporting_evidence": ["The managed-service status reports the companion relay stopped."],
    "code_change_required": "no"
  },
  "approval": {
    "kind": "service_restart",
    "request": "Approve only the companion-relay restart."
  }
}
EOF
  out=$(run_triage "$home" service "$repo" "Local companion relay is unavailable" --evidence "$home/service.json")
  printf '%s' "$out" | jq -e '
    .diagnosis.classification == "local background-service failure"
      and .diagnosis.code_change_required == "no"
  ' >/dev/null || fail "agent-adjudicated local-service diagnosis failed: $out"

  printf '{"external_providers":[{"name":"upstash","status":"quota_available"}]}\n' > "$home/unknown.json"
  out=$(run_triage "$home" unknown "$repo" "Intermittent unexplained failure" --evidence "$home/unknown.json")
  printf '%s' "$out" | jq -e '
    .diagnosis.classification == "unknown"
      and .diagnosis.code_change_required == "not yet proven"
      and .guardrails.new_worktree_allowed == false
  ' >/dev/null || fail "unadjudicated observations did not fail closed: $out"
  out=$(FM_HOME="$home" FM_INCIDENT_STATUS_LIMIT=2 "$INCIDENT" status --json --compact)
  printf '%s' "$out" | jq -e '
    (.records | length) == 2 and .truncated == 1
  ' >/dev/null || fail "bounded incident status did not disclose truncation: $out"
  pass "agent-adjudicated deployment and service diagnoses retain a fail-closed unknown path"
}

test_repository_identity_normalizes_transports_and_relative_paths() {
  local home origin ssh_repo https_repo crew_state out expected repo_a repo_b port_a port_b
  home=$(make_home transport-identity)
  origin=$(make_origin transport-identity)
  ssh_repo=$home/projects/titan-ssh
  https_repo=$home/projects/titan-https
  clone_origin "$origin" "$ssh_repo"
  clone_origin "$origin" "$https_repo"
  git -C "$ssh_repo" remote set-url origin ssh://git@example.com:22/Acme/Titan.git
  git -C "$https_repo" remote set-url origin https://copy-token@example.com:443/Acme/Titan.git
  ssh_repo=$(cd "$ssh_repo" && pwd -P)
  https_repo=$(cd "$https_repo" && pwd -P)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] transport-worker - Restore repository identity after checkout mismatch (repo: titan) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/transport-worker.meta" \
    "window=firstmate:fm-transport-worker" \
    "worktree=$https_repo" \
    "project=$https_repo" \
    "harness=codex" \
    "kind=ship"
  printf 'state: working · source: pane · restoring repository identity\n' \
    > "$home/state/transport-worker.current-state"
  printf '{"production":{"origin":"https://deploy-token@example.com/Acme/Titan.git"}}\n' \
    > "$home/production.json"
  crew_state=$(make_crew_state_fake "$home")
  out=$(FM_CREW_STATE_BIN="$crew_state" run_triage "$home" transport-identity "$ssh_repo" \
    "Restore repository identity after checkout mismatch" \
    --evidence "$home/production.json" --scan-root "$home/projects")
  printf '%s' "$out" | jq -e --arg worker "$https_repo" '
    .repository.canonical_remote == "forge://example.com/Acme/Titan"
      and ([.repository.copies[].origin] | unique) == ["forge://example.com/Acme/Titan"]
      and (.repository.copies | length) == 2
      and .repository.multiple_copies_same_origin == true
      and .diagnosis.observations.production.origin == "forge://example.com/Acme/Titan"
      and .diagnosis.classification == "unknown"
      and (.workers.registry_entries[] | select(.id == "transport-worker")
        | .working_directory == $worker
          and .wrong_worktree == false
          and .activity_matches_incident == true)
      and ([.repository.copies[] | has("origin_raw")] | any | not)
  ' >/dev/null || fail "transport-independent repository identity diverged: $out"

  home=$(make_home port-identity)
  origin=$(make_origin port-identity)
  port_a=$home/projects/port-a
  port_b=$home/projects/port-b
  clone_origin "$origin" "$port_a"
  clone_origin "$origin" "$port_b"
  git -C "$port_a" remote set-url origin https://git.example:8443/acme/app.git
  git -C "$port_b" remote set-url origin https://git.example:9443/acme/app.git
  port_a=$(cd "$port_a" && pwd -P)
  port_b=$(cd "$port_b" && pwd -P)
  printf '{"production":{"origin":"ssh://git@git.example:8443/acme/app.git"}}\n' \
    > "$home/production.json"
  out=$(run_triage "$home" port-identity "$port_a" \
    "Unknown production failure" --evidence "$home/production.json" --scan-root "$home/projects")
  printf '%s' "$out" | jq -e --arg unrelated "$port_b" '
    .repository.canonical_remote == "forge://git.example:8443/acme/app"
      and .diagnosis.observations.production.origin == "forge://git.example:8443/acme/app"
      and (.repository.copies | length) == 1
      and ([.repository.copies[].path] | index($unrelated)) == null
  ' >/dev/null || fail "non-default forge ports collapsed to one identity: $out"

  home=$(make_home relative-identity)
  origin=$(make_origin relative-identity)
  mkdir -p "$home/projects/local-a" "$home/projects/local-b"
  repo_a=$home/projects/local-a/work
  repo_b=$home/projects/local-b/work
  clone_origin "$origin" "$repo_a"
  clone_origin "$origin" "$repo_b"
  git -C "$repo_a" remote set-url origin ../origin.git
  git -C "$repo_b" remote set-url origin ../origin.git
  repo_a=$(cd "$repo_a" && pwd -P)
  repo_b=$(cd "$repo_b" && pwd -P)
  expected=file://$(cd "$home/projects/local-a" && pwd -P)/origin.git
  out=$(run_triage "$home" relative-identity "$repo_a" \
    "Unknown production failure" --scan-root "$home/projects")
  printf '%s' "$out" | jq -e --arg expected "$expected" --arg unrelated "$repo_b" '
    .repository.canonical_remote == $expected
      and (.repository.copies | length) == 1
      and ([.repository.copies[].path] | index($unrelated)) == null
  ' >/dev/null || fail "relative remotes from unrelated checkouts collapsed to one identity: $out"
  pass "repository identity unifies transports and separates relative local remotes"
}

test_bounded_inventory_omissions_are_disclosed() {
  local home origin repo crew_state out human view bearings id i invalid_home invalid_human
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
  for i in $(seq -w 1 63); do
    id=bounded-copy-$i
    jq --arg id "$id" '.id=$id | .summary=$id' \
      "$home/state/incidents/bounded-base.json" > "$home/state/incidents/$id.json"
  done
  jq '.id="z-current" | .summary="z-current" | .updated_at="2026-08-27T20:00:00Z"' \
    "$home/state/incidents/bounded-base.json" > "$home/state/incidents/z-current.json"
  jq '.id="malformed" | .summary="malformed" | .workers.inventory.omitted="unknown"' \
    "$home/state/incidents/bounded-base.json" > "$home/state/incidents/malformed.json"
  out=$(FM_HOME="$home" FM_INCIDENT_STATUS_LIMIT=100 "$INCIDENT" status --json --compact)
  printf '%s' "$out" | jq -e '
    .input == {shown:64,omitted:1}
      and (.records | length) == 64
      and ([.records[].id] | index("z-current")) != null
      and (.invalid | length) == 1
      and (.invalid[0].path | endswith("/malformed.json"))
      and (.invalid[0].reason | contains("inventory.workers.omitted"))
      and .truncated == 0
  ' >/dev/null || fail "incident input bound hid omitted records: $out"
  human=$(FM_HOME="$home" FM_INCIDENT_STATUS_LIMIT=100 "$INCIDENT" status)
  assert_contains "$human" "Warning: 1 incident record(s) omitted by the input bound." \
    "human incident list hid input omissions"
  assert_contains "$human" "Warning: 1 invalid incident record(s) could not be read." \
    "human incident list hid its invalid-record count"
  assert_contains "$human" "/malformed.json:" \
    "human incident list hid invalid-record details"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "Warning: 1 incident record(s) are omitted by the input bound." \
    "fleet view hid incident input omissions"
  assert_contains "$view" "Warning: 1 incident record(s) could not be read." \
    "fleet view hid an independently invalid incident"
  bearings=$(FM_HOME="$home" "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    ([.runtime_incidents[].id] | index("z-current")) != null
      and (.omitted | any(.surface == "runtime incident records omitted by input bound: 1"))
      and (.omitted | any(.surface == "runtime incident record(s) unreadable: 1"))
  ' >/dev/null || fail "Bearings hid incident input omissions: $bearings"

  invalid_home=$(make_home invalid-only-status)
  mkdir -p "$invalid_home/state/incidents"
  printf '{"schema":"fm-runtime-incident.v1","id":"invalid-only"}\n' \
    > "$invalid_home/state/incidents/invalid-only.json"
  invalid_human=$(FM_HOME="$invalid_home" "$INCIDENT" status)
  assert_contains "$invalid_human" "No readable runtime incidents recorded." \
    "human status described an invalid-only ledger as empty"
  assert_contains "$invalid_human" "Warning: 1 invalid incident record(s) could not be read." \
    "human invalid-only status hid its invalid-record count"
  assert_contains "$invalid_human" "/invalid-only.json:" \
    "human invalid-only status hid record details"
  pass "bounded worker, repository, branch, and incident omissions stay visible"
}

test_scan_root_entry_budget_is_enforced() {
  local home origin repo scan_root_a scan_root_b out human
  home=$(make_home bounded-scan-root)
  origin=$(make_origin bounded-scan-root)
  repo=$home/projects/titan
  clone_origin "$origin" "$repo"
  scan_root_a=$home/large-scan-a
  scan_root_b=$home/large-scan-b
  python3 - "$scan_root_a" "$scan_root_b" <<'PY'
from pathlib import Path
import sys

for argument in sys.argv[1:]:
    root = Path(argument)
    root.mkdir(parents=True)
    for index in range(2050):
        (root / f"ordinary-{index:04d}").touch()
PY
  out=$(run_triage "$home" bounded-scan-root "$repo" \
    "Unexplained production failure" \
    --scan-root "$scan_root_a" --scan-root "$scan_root_b")
  printf '%s' "$out" | jq -e '
    .repository.inventory.scan_entries.truncated_roots == 1
      and .repository.inventory.scan_entries.visited == 4096
      and .repository.inventory.copies.complete == false
  ' >/dev/null || fail "scan-root entry bound or truncation disclosure failed: $out"
  human=$(FM_HOME="$home" "$INCIDENT" status --incident bounded-scan-root)
  assert_contains "$human" "Scan roots truncated by entry bound: 1" \
    "human incident status hid scan-root truncation"
  pass "scan-root traversal shares one entry budget and reports truncation"
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

test_aggregate_record_bounds_and_atomic_size_refusal() {
  local home origin repo copy record out bearings toon header json_fields toon_fields before after note i j size
  home=$(make_home aggregate-record)
  origin=$(make_origin aggregate-record)
  repo=$home/projects/titan-1
  clone_origin "$origin" "$repo"
  for i in 1 2 3; do
    copy=$home/projects/titan-$i
    if [ "$i" -ne 1 ]; then
      clone_origin "$origin" "$copy"
    fi
    for j in $(seq -w 1 100); do
      git -C "$copy" branch "inventory-$j"
    done
  done
  python3 - "$home/large-evidence.json" <<'PY'
import json
from pathlib import Path
import sys

providers = [
    {"name": f"provider-{index:05d}", "status": "quota_exhausted", "code": "quota_exhausted"}
    for index in range(7000)
]
evidence = {
    "external_providers": providers,
    "diagnosis": {
        "classification": "external dependency, quota, billing, credential, or configuration failure",
        "probable_root_cause": "The selected provider exhausted its command quota.",
        "supporting_evidence": ["The provider status reports quota exhaustion."],
        "code_change_required": "no",
    },
    "approval": {
        "kind": "operational_provider_change",
        "request": "Approve only the diagnosed provider quota change.",
    },
}
Path(sys.argv[1]).write_text(json.dumps(evidence, separators=(",", ":")))
PY
  out=$(run_triage "$home" aggregate-record "$repo" \
    "Provider quota exhaustion" --evidence "$home/large-evidence.json" \
    --scan-root "$home/projects")
  printf '%s' "$out" | jq -e '
    (.repository.branches | length) == 256
      and ([.repository.copies[].branches[]] | length) == 256
      and .repository.inventory.branches.shown == 256
      and .repository.inventory.branches.omitted_at_least >= 47
      and (.diagnosis.supporting_evidence | length) == 1
      and (.diagnosis.observations.external_providers | length) == 256
      and .diagnosis.observations.inventory.supporting_evidence == {shown:1,omitted:0}
      and .diagnosis.observations.inventory.external_providers == {shown:256,omitted:6744}
  ' >/dev/null || fail "aggregate record bounds or omission metadata were incomplete: $out"
  record=$home/state/incidents/aggregate-record.json
  size=$(wc -c < "$record")
  [ "$size" -le 1048576 ] || fail "bounded incident record exceeded the readable size limit"
  FM_HOME="$home" "$INCIDENT" status --incident aggregate-record --json >/dev/null || \
    fail "bounded incident record was not readable after triage"
  FM_HOME="$home" "$INCIDENT" approve --incident aggregate-record \
    --kind operational_provider_change --note "approved provider repair" >/dev/null
  FM_HOME="$home" "$INCIDENT" repair --incident aggregate-record \
    --note "provider repair complete" >/dev/null
  python3 - "$home/large-verification.json" <<'PY'
import json
from pathlib import Path
import sys

checks = [
    {
        "scope": (
            "production_identity" if index == 0
            else "repaired_component_health" if index == 1
            else "user_visible_path"
        ),
        "name": f"runtime-path-{index:03d}",
        "status": "pass",
        "evidence": "healthy",
    }
    for index in range(300)
]
Path(sys.argv[1]).write_text(json.dumps({"verification": {
    "runtime_path_ok": True,
    "companion_connectivity_required": False,
    "checks": checks,
}}))
PY
  FM_HOME="$home" "$INCIDENT" verify --incident aggregate-record \
    --evidence "$home/large-verification.json" >/dev/null
  out=$(FM_HOME="$home" "$INCIDENT" status --incident aggregate-record --json)
  printf '%s' "$out" | jq -e '
    .verification.status == "complete"
      and (.verification.checks | length) == 256
      and .verification.inventory.checks == {shown:256,omitted:44}
  ' >/dev/null || fail "verification checks were not bounded with omission metadata: $out"
  out=$(FM_HOME="$home" "$INCIDENT" status --json --compact)
  printf '%s' "$out" | jq -e '
    .records[] | select(.id == "aggregate-record")
      | .inventory.verification.checks == {shown:256,omitted:44}
  ' >/dev/null || fail "compact status hid verification omission metadata: $out"
  bearings=$(FM_HOME="$home" "$BEARINGS" --json)
  printf '%s' "$bearings" | jq -e '
    ([.runtime_incidents[] | select(.id == "aggregate-record")] | length) == 1
      and ([.runtime_incidents[] | select(.id == "aggregate-record" and has("inventory"))] | length) == 0
      and (.omitted | any(.surface == "runtime incident aggregate-record has bounded triage inventory omissions"))
  ' >/dev/null || fail "Bearings row leaked nested inventory or hid its omission warning: $bearings"
  toon=$(FM_HOME="$home" "$BEARINGS")
  header=$(printf '%s\n' "$toon" | grep -E '^runtime_incidents\[[0-9]+\]\{' || true)
  [ -n "$header" ] || fail "Bearings TOON omitted the runtime incident table"
  json_fields=$(printf '%s' "$bearings" | jq -r '.runtime_incidents[0] | keys_unsorted | join(",")')
  toon_fields=$(printf '%s' "$header" | sed -E 's/^[^{]*\{//; s/\}:.*$//; s/"//g')
  [ "$json_fields" = "$toon_fields" ] || \
    fail "Bearings runtime incident fields diverged between JSON and TOON"

  run_triage "$home" size-refusal "$repo" "Provider quota exhaustion" \
    --evidence "$QUOTA_FIXTURE" >/dev/null
  record=$home/state/incidents/size-refusal.json
  python3 - "$record" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
record = json.loads(path.read_text())
record["padding"] = ""
payload = json.dumps(record, indent=2, sort_keys=True) + "\n"
record["padding"] = "x" * (1048560 - len(payload))
path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
  before=$(cksum < "$record")
  note=$(python3 -c 'print("n" * 300)')
  if FM_HOME="$home" "$INCIDENT" approve --incident size-refusal \
    --kind paid_plan_change --note "$note" >/dev/null 2>&1; then
    fail "oversized lifecycle update replaced the readable incident ledger"
  fi
  after=$(cksum < "$record")
  [ "$before" = "$after" ] || fail "size refusal did not preserve the prior incident ledger"
  out=$(FM_HOME="$home" "$INCIDENT" status --incident size-refusal --json)
  printf '%s' "$out" | jq -e '
    .phase == "approval" and .approval.status == "pending"
  ' >/dev/null || fail "size refusal left the incident ledger unreadable or advanced: $out"
  pass "aggregate bounds disclose omissions and oversized writes preserve the ledger"
}

test_repository_and_worker_reconciliation
test_remote_worker_directory_remains_remote
test_git_triage_probes_disable_optional_locks
test_external_quota_no_code_lifecycle_and_status
test_lifecycle_transitions_read_and_write_under_one_lock
test_stale_remote_never_wins_fallback_authority
test_proposed_hotfix_already_deployed
test_proven_application_defect_escalates
test_raw_evidence_requires_agent_judgment
test_agent_adjudicated_categories
test_repository_identity_normalizes_transports_and_relative_paths
test_bounded_inventory_omissions_are_disclosed
test_scan_root_entry_budget_is_enforced
test_worktree_inventory_is_authority_bound_and_enrichment_is_capped
test_aggregate_record_bounds_and_atomic_size_refusal
