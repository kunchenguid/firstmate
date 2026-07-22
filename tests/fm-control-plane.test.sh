#!/usr/bin/env bash
# Behavior tests for the registered-source operating control plane.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROL="$ROOT/bin/fm-control-plane.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-plane)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

HOME_FIXTURE="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
TASK_WORKTREE="$TMP_ROOT/task-worktree"
EXTRA_WORKTREE="$TMP_ROOT/extra-worktree"
TRANSCRIPTS="$TMP_ROOT/transcripts"
SNAPSHOT_FIXTURE="$TMP_ROOT/snapshot.json"
REGISTRY="$TMP_ROOT/sources.json"
NOW=2026-07-20T10:00:00Z
SESSION_ID=11111111-1111-4111-8111-111111111111

mkdir -p "$HOME_FIXTURE/data/active-task" "$HOME_FIXTURE/state" "$HOME_FIXTURE/config" "$TRANSCRIPTS"
fm_git_init_commit "$PROJECT"
git -C "$PROJECT" worktree add --quiet -b active-task "$TASK_WORKTREE"
git -C "$PROJECT" worktree add --quiet -b extra-task "$EXTRA_WORKTREE"
cat > "$PROJECT/state.md" <<'EOF'
## Position
updated: 2026-07-19T08:00:00Z
EOF
mkdir -p "$PROJECT/.ai"
printf '# Handoff\n' > "$PROJECT/.ai/HANDOFF-old.md"
touch -t 202607190800 "$PROJECT/.ai/HANDOFF-old.md"

cat > "$TRANSCRIPTS/$SESSION_ID.jsonl" <<EOF
{"sessionId":"$SESSION_ID","cwd":"$TASK_WORKTREE","timestamp":"2026-07-20T09:30:00Z"}
EOF
cat > "$TRANSCRIPTS/22222222-2222-4222-8222-222222222222.jsonl" <<EOF
{"sessionId":"22222222-2222-4222-8222-222222222222","cwd":"$EXTRA_WORKTREE","timestamp":"2026-07-20T09:40:00Z"}
EOF
cat > "$TRANSCRIPTS/33333333-3333-4333-8333-333333333333.jsonl" <<EOF
{"sessionId":"33333333-3333-4333-8333-333333333333","cwd":"$PROJECT","timestamp":"2026-01-01T00:00:00Z"}
EOF
touch -t 202601010000 "$TRANSCRIPTS/33333333-3333-4333-8333-333333333333.jsonl"

cat > "$SNAPSHOT_FIXTURE" <<EOF
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "$NOW",
  "fm_home": "$HOME_FIXTURE",
  "backlog": {
    "records": [
      {"structured":true,"id":"active-task","state":"in_flight","title":"Active Task","repo":"sample","kind":"ship"},
      {"structured":true,"id":"missing-task","state":"queued","title":"Missing Contract","repo":"sample","kind":"ship"},
      {"structured":true,"id":"done-task","state":"done","title":"Claimed Done","repo":"sample","kind":"ship","pr_url":"https://example.invalid/pull/1"}
    ]
  },
  "tasks": [
    {
      "id":"active-task",
      "kind":"ship",
      "project":"sample",
      "mode":"no-mistakes",
      "yolo":"off",
      "current_state":{"state":"working","source":"pane","detail":"active","freshness":"fresh"},
      "endpoint":{"status":"present","observed_at":"$NOW","freshness":"fresh"},
      "paths":{"worktree":{"path":"$TASK_WORKTREE","present":true}},
      "pr":{"url":null,"source":"absent"},
      "hints":{"open_decisions":[],"last_event_text":"working: token=sk-abcdefghijklmnopqrstuvwxyz"},
      "backlog":{"structured":true,"id":"active-task","state":"in_flight","title":"Active Task","repo":"sample","kind":"ship"}
    }
  ]
}
EOF

cat > "$HOME_FIXTURE/data/active-task/control.json" <<EOF
{
  "schema":"fm-control-item.v1",
  "id":"active-task",
  "title":"Active Task",
  "purpose":"Prove durable custody",
  "business_outcome":"A user-visible outcome can eventually be verified",
  "capability":"sample-capability",
  "owner":{"type":"firstmate-task","id":"active-task","source":"fleet-home"},
  "next_action":{"description":"Run the bounded validation","capability":"worker.validate"},
  "authority":{"level":"worker","source":"task-brief","delivery":"no-mistakes"},
  "updated_at":"2026-07-20T09:00:00Z",
  "freshness_seconds":7200,
  "proof_requirements":{
    "implemented":{"required":true},
    "validated":{"required":true},
    "release_ready":{"required":true},
    "in_production":{"required":true},
    "real_users":{"required":true},
    "revenue":{"required":true}
  },
  "proofs":[
    {"stage":"implemented","kind":"git_commit","project_source_id":"sample-project","ref":"HEAD","source":"git","observed_at":"2026-07-20T09:00:00Z","freshness_seconds":7200}
  ]
}
EOF

write_registry() {  # <runtime-endpoint>
  cat > "$REGISTRY" <<EOF
{
  "schema":"fm-control-plane-sources.v1",
  "scope":{"id":"test-software","description":"test scope","trust_domain":"software"},
  "capabilities":[{"id":"observe.reconcile","access":"read-only"}],
  "sources":[
    {"id":"fleet-home","kind":"firstmate-home","path":"$HOME_FIXTURE","snapshot_path":"$SNAPSHOT_FIXTURE","backend_observation":false,"trust_domain":"software-operations","access":"read-only","retention":"metadata-only","freshness_seconds":900,"capabilities":["observe.reconcile"]},
    {"id":"sample-project","kind":"git-project","path":"$PROJECT","trust_domain":"software-source","access":"read-only","retention":"pointers-only","freshness_seconds":900,"capabilities":["observe.reconcile"]},
    {"id":"active-session","kind":"claude-session","path":"$TRANSCRIPTS/$SESSION_ID.jsonl","session_id":"$SESSION_ID","project_source_id":"sample-project","work_item_id":"active-task","runtime_observation":{"state":"idle","source":"runtime-fixture","observed_at":"2026-07-20T09:45:00Z","endpoint":"$1"},"trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":7200,"capabilities":["observe.reconcile"]},
    {"id":"duplicate-native-session","kind":"claude-session","path":"$TRANSCRIPTS/$SESSION_ID.jsonl","session_id":"$SESSION_ID","project_source_id":"sample-project","work_item_id":"active-task","runtime_observation":{"state":"idle","source":"runtime-fixture","observed_at":"2026-07-20T09:45:00Z","endpoint":"$1"},"trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":7200,"capabilities":["observe.reconcile"]},
    {"id":"stale-session","kind":"claude-session","path":"$TRANSCRIPTS/33333333-3333-4333-8333-333333333333.jsonl","session_id":"33333333-3333-4333-8333-333333333333","project_source_id":"sample-project","trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":60,"capabilities":["observe.reconcile"]},
    {"id":"missing-session","kind":"codex-session","path":"$TRANSCRIPTS/missing.jsonl","session_id":"44444444-4444-4444-8444-444444444444","project_source_id":"sample-project","trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":60,"capabilities":["observe.reconcile"]},
    {"id":"claude-discovery","kind":"claude-transcript-root","path":"$TRANSCRIPTS","project_source_ids":["sample-project"],"lookback_seconds":31536000,"max_files":20,"trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":900,"capabilities":["observe.reconcile"]}
  ],
  "connectors":[{"id":"revenue-system","kind":"business-system","status":"unregistered","trust_domain":"finance","capabilities":[],"reason":"No authorized connector"}]
}
EOF
}

control_json() {  # <registry>
  FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" "$CONTROL" --sources "$1" --snapshot "$SNAPSHOT_FIXTURE" --now "$NOW" --json
}

test_stable_identity_and_reconciliation() {
  local first second stable_first stable_second fingerprint_first fingerprint_second
  write_registry pane-old
  first=$(control_json "$REGISTRY") || fail "first reconciliation failed"
  write_registry pane-new
  second=$(control_json "$REGISTRY") || fail "second reconciliation failed"
  stable_first=$(printf '%s' "$first" | jq -r --arg id "$SESSION_ID" '.inventory.sessions[] | select(.session_id == $id) | .stable_id')
  stable_second=$(printf '%s' "$second" | jq -r --arg id "$SESSION_ID" '.inventory.sessions[] | select(.session_id == $id) | .stable_id')
  [ "$stable_first" = "native-session:claude:$SESSION_ID" ] || fail "native session identity did not use the durable UUID"
  [ "$stable_first" = "$stable_second" ] || fail "pane change changed the durable session identity"
  printf '%s' "$second" | jq -e --arg id "$SESSION_ID" '[.inventory.sessions[] | select(.session_id == $id)] | length == 1' >/dev/null \
    || fail "duplicate registrations duplicated one native session"
  printf '%s' "$second" | jq -e '[.inventory.tasks[] | select(.task_id == "active-task")] | length == 1' >/dev/null \
    || fail "reconciliation duplicated a task"
  fingerprint_first=$(printf '%s' "$first" | jq -r '.attention.fingerprint')
  fingerprint_second=$(printf '%s' "$second" | jq -r '.attention.fingerprint')
  [ "$fingerprint_first" = "$fingerprint_second" ] || fail "ephemeral endpoint change changed the stable attention fingerprint"
  pass "durable session and task identities survive endpoint change and repeated reconciliation"
}

test_freshness_conflict_and_invariants() {
  local out codes
  write_registry pane-new
  out=$(control_json "$REGISTRY") || fail "invariant reconciliation failed"
  codes=$(printf '%s' "$out" | jq -r '[.invariants.violations[].code] | unique | join(",")')
  for code in \
    TRANSCRIPT_NEWER_THAN_POSITION TRANSCRIPT_NEWER_THAN_HANDOFF SESSION_IDLE_INCOMPLETE \
    COMPLETION_CONFLICT WORK_ITEM_OWNER_MISSING WORK_ITEM_NEXT_ACTION_MISSING \
    WORK_ITEM_PROOF_REQUIREMENT_MISSING WORK_ITEM_AUTHORITY_MISSING WORK_ITEM_FRESHNESS_MISSING \
    SOURCE_UNAVAILABLE SOURCE_STALE UNREGISTERED_SESSION UNREGISTERED_WORKTREE; do
    assert_contains "$codes" "$code" "control plane missed invariant $code"
  done
  printf '%s' "$out" | jq -e '
    .work_items[] | select(.task_id == "active-task")
    | .outcome.furthest_proved_stage == "implemented"
      and ([.outcome.stages[] | select(.stage == "in_production" or .stage == "real_users" or .stage == "revenue") | .status] | all(. == "unknown"))
  ' >/dev/null || fail "implemented work was collapsed into production, users, or revenue"
  printf '%s' "$out" | jq -e '.attention.no_proof[] | select(.subject_id | startswith("task:")) | .reason | contains("in_production, real_users, revenue")' >/dev/null \
    || fail "captain view did not expose missing production, user, and revenue proof"
  printf '%s' "$out" | grep -F 'sk-abcdefghijklmnopqrstuvwxyz' >/dev/null && fail "secret-like status material escaped redaction"
  assert_contains "$out" 'token=[REDACTED]' "secret-like status material was not visibly redacted"
  pass "freshness, conflicts, incomplete idle work, missing contracts, unknown outcomes, and discovery gaps fail closed"
}

test_malformed_position_marker_still_triggers_freshness() {
  local out codes
  cat > "$PROJECT/state.md" <<'EOF'
## Position
updated: definitely-not-a-timestamp
EOF
  touch -t 202607200800 "$PROJECT/state.md"
  write_registry pane-new
  out=$(control_json "$REGISTRY") || fail "reconciliation with malformed position marker failed"
  codes=$(printf '%s' "$out" | jq -r '[.invariants.violations[].code] | unique | join(",")')
  assert_contains "$codes" TRANSCRIPT_NEWER_THAN_POSITION "malformed position marker failed open"
  pass "malformed position markers no longer suppress transcript freshness checks"
}

test_invalid_control_timestamp_is_rejected() {
  local home project task_worktree transcripts snapshot registry now session_id out codes
  home="$TMP_ROOT/invalid-updated-at-home"
  project="$TMP_ROOT/invalid-updated-at-project"
  task_worktree="$TMP_ROOT/invalid-updated-at-worktree"
  transcripts="$TMP_ROOT/invalid-updated-at-transcripts"
  snapshot="$TMP_ROOT/invalid-updated-at-snapshot.json"
  registry="$TMP_ROOT/invalid-updated-at-sources.json"
  now=2026-07-20T10:00:00Z
  session_id=55555555-5555-4555-8555-555555555555

  mkdir -p "$home/data/invalid-task" "$home/state" "$home/config" "$project/.ai" "$transcripts"
  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet -b invalid-task "$task_worktree"
  cat > "$project/state.md" <<'EOF'
## Position
updated: 2026-07-20T09:45:00Z
EOF
  printf '# Handoff\n' > "$project/.ai/HANDOFF-old.md"
  touch -t 202607200900 "$project/.ai/HANDOFF-old.md"
  cat > "$transcripts/$session_id.jsonl" <<EOF
{"sessionId":"$session_id","cwd":"$task_worktree","timestamp":"2026-07-20T09:30:00Z"}
EOF
  cat > "$snapshot" <<EOF
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "$now",
  "fm_home": "$home",
  "backlog": {
    "records": [
      {"structured":true,"id":"invalid-task","state":"in_flight","title":"Invalid Task","repo":"sample","kind":"ship"}
    ]
  },
  "tasks": [
    {
      "id":"invalid-task",
      "kind":"ship",
      "project":"sample",
      "mode":"no-mistakes",
      "yolo":"off",
      "current_state":{"state":"working","source":"pane","detail":"active","freshness":"fresh"},
      "endpoint":{"status":"present","observed_at":"$now","freshness":"fresh"},
      "paths":{"worktree":{"path":"$task_worktree","present":true}},
      "pr":{"url":null,"source":"absent"},
      "hints":{"open_decisions":[],"last_event_text":"working"},
      "backlog":{"structured":true,"id":"invalid-task","state":"in_flight","title":"Invalid Task","repo":"sample","kind":"ship"}
    }
  ]
}
EOF
  cat > "$home/data/invalid-task/control.json" <<EOF
{
  "schema":"fm-control-item.v1",
  "id":"invalid-task",
  "title":"Invalid Task",
  "purpose":"Prove durable custody",
  "business_outcome":"A user-visible outcome can eventually be verified",
  "capability":"sample-capability",
  "owner":{"type":"firstmate-task","id":"invalid-task","source":"fleet-home"},
  "next_action":{"description":"Run the bounded validation","capability":"worker.validate"},
  "authority":{"level":"worker","source":"task-brief","delivery":"no-mistakes"},
  "updated_at":"2026-12",
  "freshness_seconds":7200,
  "proof_requirements":{
    "implemented":{"required":true},
    "validated":{"required":true},
    "release_ready":{"required":true},
    "in_production":{"required":true},
    "real_users":{"required":true},
    "revenue":{"required":true}
  },
  "proofs":[
    {"stage":"implemented","kind":"git_commit","project_source_id":"sample-project","ref":"HEAD","source":"git","observed_at":"2026-07-20T09:45:00Z","freshness_seconds":7200}
  ]
}
EOF
  cat > "$registry" <<EOF
{
  "schema":"fm-control-plane-sources.v1",
  "scope":{"id":"test-software","description":"test scope","trust_domain":"software"},
  "capabilities":[{"id":"observe.reconcile","access":"read-only"}],
  "sources":[
    {"id":"fleet-home","kind":"firstmate-home","path":"$home","snapshot_path":"$snapshot","backend_observation":false,"trust_domain":"software-operations","access":"read-only","retention":"metadata-only","freshness_seconds":900,"capabilities":["observe.reconcile"]},
    {"id":"sample-project","kind":"git-project","path":"$project","trust_domain":"software-source","access":"read-only","retention":"pointers-only","freshness_seconds":900,"capabilities":["observe.reconcile"]},
    {"id":"invalid-session","kind":"claude-session","path":"$transcripts/$session_id.jsonl","session_id":"$session_id","project_source_id":"sample-project","work_item_id":"invalid-task","runtime_observation":{"state":"idle","source":"runtime-fixture","observed_at":"2026-07-20T09:50:00Z","endpoint":"pane"},"trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":7200,"capabilities":["observe.reconcile"]}
  ]
}
EOF

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CONTROL" --sources "$registry" --snapshot "$snapshot" --now "$now" --json) || fail "invalid control timestamp unexpectedly failed to parse"
  codes=$(printf '%s' "$out" | jq -r '[.invariants.violations[].code] | unique | join(",")')
  assert_contains "$codes" CONTROL_RECORD_INVALID "invalid updated_at was not rejected explicitly"
  pass "malformed control timestamps fail closed"
}

test_idle_session_accepts_not_applicable_revenue() {
  local home project task_worktree transcripts snapshot registry now session_id out codes
  home="$TMP_ROOT/not-applicable-home"
  project="$TMP_ROOT/not-applicable-project"
  task_worktree="$TMP_ROOT/not-applicable-worktree"
  transcripts="$TMP_ROOT/not-applicable-transcripts"
  snapshot="$TMP_ROOT/not-applicable-snapshot.json"
  registry="$TMP_ROOT/not-applicable-sources.json"
  now=2026-07-20T10:00:00Z
  session_id=44444444-4444-4444-8444-444444444444

  mkdir -p "$home/data/idle-task" "$home/state" "$home/config" "$home/.ai" "$project/.ai" "$transcripts"
  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet -b idle-task "$task_worktree"
  cat > "$project/state.md" <<'EOF'
## Position
updated: 2026-07-20T09:45:00Z
EOF
  printf '# Handoff\n' > "$project/.ai/HANDOFF-old.md"
  touch -t 202607200900 "$project/.ai/HANDOFF-old.md"
  cat > "$transcripts/$session_id.jsonl" <<EOF
{"sessionId":"$session_id","cwd":"$task_worktree","timestamp":"2026-07-20T09:30:00Z"}
EOF
  cat > "$snapshot" <<EOF
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "$now",
  "fm_home": "$home",
  "backlog": {
    "records": [
      {"structured":true,"id":"idle-task","state":"in_flight","title":"Idle Task","repo":"sample","kind":"ship"}
    ]
  },
  "tasks": [
    {
      "id":"idle-task",
      "kind":"ship",
      "project":"sample",
      "mode":"no-mistakes",
      "yolo":"off",
      "current_state":{"state":"working","source":"pane","detail":"active","freshness":"fresh"},
      "endpoint":{"status":"present","observed_at":"$now","freshness":"fresh"},
      "paths":{"worktree":{"path":"$task_worktree","present":true}},
      "pr":{"url":null,"source":"absent"},
      "hints":{"open_decisions":[],"last_event_text":"working"},
      "backlog":{"structured":true,"id":"idle-task","state":"in_flight","title":"Idle Task","repo":"sample","kind":"ship"}
    }
  ]
}
EOF
  cat > "$home/data/idle-task/control.json" <<EOF
{
  "schema":"fm-control-item.v1",
  "id":"idle-task",
  "title":"Idle Task",
  "purpose":"Prove durable custody",
  "business_outcome":"A user-visible outcome can eventually be verified",
  "capability":"sample-capability",
  "owner":{"type":"firstmate-task","id":"idle-task","source":"fleet-home"},
  "next_action":{"description":"Run the bounded validation","capability":"worker.validate"},
  "authority":{"level":"worker","source":"task-brief","delivery":"no-mistakes"},
  "updated_at":"2026-07-20T09:45:00Z",
  "freshness_seconds":7200,
  "proof_requirements":{
    "implemented":{"required":true},
    "validated":{"required":true},
    "release_ready":{"required":true},
    "in_production":{"required":true},
    "real_users":{"required":true},
    "revenue":{"required":false,"reason":"not applicable"}
  },
  "proofs":[
    {"stage":"implemented","kind":"git_commit","project_source_id":"sample-project","ref":"HEAD","source":"git","observed_at":"2026-07-20T09:45:00Z","freshness_seconds":7200},
    {"stage":"validated","kind":"git_commit","project_source_id":"sample-project","ref":"HEAD","source":"git","observed_at":"2026-07-20T09:45:00Z","freshness_seconds":7200},
    {"stage":"release_ready","kind":"git_commit","project_source_id":"sample-project","ref":"HEAD","source":"git","observed_at":"2026-07-20T09:45:00Z","freshness_seconds":7200},
    {"stage":"in_production","kind":"git_commit","project_source_id":"sample-project","ref":"HEAD","source":"git","observed_at":"2026-07-20T09:45:00Z","freshness_seconds":7200},
    {"stage":"real_users","kind":"git_commit","project_source_id":"sample-project","ref":"HEAD","source":"git","observed_at":"2026-07-20T09:45:00Z","freshness_seconds":7200}
  ]
}
EOF
  cat > "$registry" <<EOF
{
  "schema":"fm-control-plane-sources.v1",
  "scope":{"id":"test-software","description":"test scope","trust_domain":"software"},
  "capabilities":[{"id":"observe.reconcile","access":"read-only"}],
  "sources":[
    {"id":"fleet-home","kind":"firstmate-home","path":"$home","snapshot_path":"$snapshot","backend_observation":false,"trust_domain":"software-operations","access":"read-only","retention":"metadata-only","freshness_seconds":900,"capabilities":["observe.reconcile"]},
    {"id":"sample-project","kind":"git-project","path":"$project","trust_domain":"software-source","access":"read-only","retention":"pointers-only","freshness_seconds":900,"capabilities":["observe.reconcile"]},
    {"id":"idle-session","kind":"claude-session","path":"$transcripts/$session_id.jsonl","session_id":"$session_id","project_source_id":"sample-project","work_item_id":"idle-task","runtime_observation":{"state":"idle","source":"runtime-fixture","observed_at":"2026-07-20T09:50:00Z","endpoint":"pane"},"trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":7200,"capabilities":["observe.reconcile"]}
  ]
}
EOF

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$CONTROL" --sources "$registry" --snapshot "$snapshot" --now "$now" --json) || fail "not-applicable control-plane reconciliation failed"
  codes=$(printf '%s' "$out" | jq -r '[.invariants.violations[].code] | unique | join(",")')
  assert_not_contains "$codes" SESSION_IDLE_INCOMPLETE "not-applicable revenue still counted as incomplete"
  printf '%s' "$out" | jq -e '
    .work_items[] | select(.task_id == "idle-task")
    | .outcome.furthest_proved_stage == "real_users"
      and ([.outcome.stages[] | select(.stage == "revenue") | .status] | .[0]) == "not_applicable"
  ' >/dev/null || fail "not-applicable revenue stage was not preserved"
  pass "idle sessions ignore explicitly not-applicable revenue stages"
}

test_secret_registry_rejected() {
  local bad err status=0
  bad="$TMP_ROOT/secret-sources.json"
  err="$TMP_ROOT/secret-sources.err"
  cat > "$bad" <<'EOF'
{"schema":"fm-control-plane-sources.v1","scope":{"id":"bad"},"api_key":"sk-abcdefghijklmnopqrstuvwxyz","sources":[]}
EOF
  FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" "$CONTROL" --sources "$bad" --json > /dev/null 2> "$err" || status=$?
  [ "$status" -eq 3 ] || fail "secret-like registry must be rejected with exit 3, got $status"
  assert_contains "$(cat "$err")" 'source registry contains secret-like material at api_key' "secret rejection did not identify the offending field"
  assert_not_contains "$(cat "$err")" 'sk-abcdefghijklmnopqrstuvwxyz' "secret rejection echoed the secret value"
  pass "secret-like source configuration is rejected without retaining or echoing its value"
}

test_metadata_only_snapshot() {
  local home out
  home="$TMP_ROOT/metadata-only-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/worktree"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] opaque-task - Opaque Task (repo: sample) (kind: ship)
EOF
  fm_write_meta "$home/state/opaque-task.meta" \
    "backend=herdr" \
    "window=default:opaque:target" \
    "worktree=$home/worktree" \
    "project=sample" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  out=$(HERDR_ENV=1 FM_HOME="$home" FM_SNAPSHOT_NO_BACKEND=1 "$SNAPSHOT" --json) || fail "metadata-only snapshot failed"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "opaque-task")
    | .current_state.state == "unknown"
      and .current_state.source == "observation-disabled"
      and .current_state.detail == "runtime endpoint observation disabled by source policy"
      and .endpoint.exists == null
      and .endpoint.agent_alive == "not_checked"
  ' >/dev/null || fail "metadata-only mode guessed or queried runtime state"
  pass "metadata-only fleet reconciliation leaves runtime custody explicitly unknown"
}

wait_for_exit() {  # <pid> <ticks>
  local pid=$1 ticks=$2 i=0
  while [ "$i" -lt "$ticks" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_attention_wake_restart_deduplication() {
  local home missing registry out1 out2 pid1 pid2 count
  home="$TMP_ROOT/wake-home"
  missing="$home/missing.jsonl"
  registry="$home/config/control-plane-sources.json"
  out1="$home/watch-one.out"
  out2="$home/watch-two.out"
  mkdir -p "$home/state" "$home/data" "$home/config"
  cat > "$registry" <<EOF
{
  "schema":"fm-control-plane-sources.v1",
  "scope":{"id":"wake-test","trust_domain":"software"},
  "sources":[
    {"id":"home","kind":"firstmate-home","path":"$home","backend_observation":false,"trust_domain":"software-operations","access":"read-only","retention":"metadata-only","freshness_seconds":900,"capabilities":["observe.reconcile"]},
    {"id":"missing","kind":"codex-session","path":"$missing","session_id":"55555555-5555-4555-8555-555555555555","trust_domain":"software-agent-metadata","access":"metadata-read-only","retention":"native-id-path-time-cwd-only","freshness_seconds":60,"capabilities":["observe.reconcile"]}
  ]
}
EOF
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 "$WATCH" > "$out1" &
  pid1=$!
  wait_for_exit "$pid1" 80 || { kill "$pid1" 2>/dev/null || true; fail "changed control-plane attention did not wake the watcher"; }
  wait "$pid1" 2>/dev/null || true
  assert_contains "$(cat "$out1")" 'check: control-plane:' "watcher did not name the control-plane wake"
  count=$(awk -F '\t' '$3 == "check" && $4 == "control-plane" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$count" -eq 1 ] || fail "first reconciliation should enqueue one control-plane wake, got $count"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 "$WATCH" > "$out2" &
  pid2=$!
  if wait_for_exit "$pid2" 30; then
    wait "$pid2" 2>/dev/null || true
    fail "watcher restart re-surfaced unchanged attention"
  fi
  kill "$pid2" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  count=$(awk -F '\t' '$3 == "check" && $4 == "control-plane" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$count" -eq 1 ] || fail "restart duplicated the durable control-plane wake"
  [ ! -s "$out2" ] || fail "restart emitted an unchanged control-plane wake"
  pass "restart preserves one attention wake and one watcher cycle for an unchanged fingerprint"
}

test_documented_examples_are_valid() {
  jq -e '.schema == "fm-control-plane-sources.v1"' "$ROOT/docs/examples/control-plane-sources.json" >/dev/null \
    || fail "source registration example is invalid"
  jq -e '.schema == "fm-control-item.v1"' "$ROOT/docs/examples/control-item.json" >/dev/null \
    || fail "control item example is invalid"
  pass "tracked source and work-item contracts are valid JSON"
}

test_stable_identity_and_reconciliation
test_freshness_conflict_and_invariants
test_malformed_position_marker_still_triggers_freshness
test_invalid_control_timestamp_is_rejected
test_idle_session_accepts_not_applicable_revenue
test_secret_registry_rejected
test_metadata_only_snapshot
test_attention_wake_restart_deduplication
test_documented_examples_are_valid
