#!/usr/bin/env bash
# Behavior tests for the canonical private durable-memory owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MEMORY="$ROOT/bin/fm-memory.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory)
fm_git_identity fmtest fmtest@example.invalid

new_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$home"
}

run_memory() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$MEMORY" "$@"
}

checkpoint_json() {
  local objective=${1:-"Recover durable work"}
  jq -cn --arg objective "$objective" '{objective:$objective,completed:[],pending:["verify"],decisions:["captain approved bounded local files"],constraints:["memory never overrides authority"],blockers:[],active_tasks:[],evidence:[],next_safe_action:"Run bounded recovery",provenance:["authority:data/backlog.md"],sensitivity:"private"}'
}

test_concurrent_idempotent_events_and_malformed_recovery() {
  local home count unique i out
  home=$(new_home concurrent)
  for i in $(seq 1 40); do
    run_memory "$home" event --type task-transition --runtime codex --session session-a --writer writer-a \
      --task task-a --project firstmate --idempotency-key "event-$i" --payload-file - >/dev/null <<EOF &
{"summary":"transition $i"}
EOF
  done
  wait
  count=$(find "$home/data/memory/events" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 40 ] || fail "concurrent writes produced $count events, expected 40"

  run_memory "$home" event --type task-transition --runtime codex --session session-a --writer writer-a \
    --task task-a --project firstmate --idempotency-key event-1 --payload-file - <<<'{"summary":"transition 1"}' >/dev/null
  unique=$(find "$home/data/memory/events" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$unique" -eq 40 ] || fail "idempotent retry created a duplicate event"

  printf '{"truncated":' > "$home/data/memory/events/writer-a/truncated.json"
  out=$(checkpoint_json | run_memory "$home" checkpoint --reason test --runtime codex --session session-a --input -)
  [ -f "$out" ] || fail "checkpoint was not written after malformed event recovery"
  out=$(run_memory "$home" recover)
  assert_contains "$out" "checkpoint:" "recovery failed after a truncated event record"
  pass "durable memory: concurrent appends, retry idempotency, and malformed event recovery"
}

test_checkpoint_atomic_validation_and_immutable_history() {
  local home first second status
  home=$(new_home checkpoints)
  first=$(checkpoint_json first | run_memory "$home" checkpoint --reason manual --runtime claude --session one --input -)
  second=$(checkpoint_json second | run_memory "$home" checkpoint --reason turn-end --runtime claude --session one --input -)
  [ "$first" != "$second" ] || fail "immutable checkpoint history reused one path"
  [ -f "$first.sha256" ] && [ -f "$second.sha256" ] || fail "checkpoint hash sidecars missing"
  run_memory "$home" validate "$first" >/dev/null || fail "fresh checkpoint did not validate"
  printf '\nmodified\n' >> "$first"
  status=0
  run_memory "$home" validate "$first" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "modified checkpoint must fail validation"
  run_memory "$home" validate "$second" >/dev/null || fail "newer immutable checkpoint was damaged by older tamper"
  pass "durable memory: atomic validation and immutable checkpoint history"
}

test_high_water_replay_has_no_duplicate_or_loss() {
  local home cp out later_count
  home=$(new_home replay)
  run_memory "$home" event --type objective --runtime codex --session replay --writer replay --idempotency-key before --payload-file - <<<'{"summary":"before"}' >/dev/null
  cp=$(checkpoint_json replay | run_memory "$home" checkpoint --reason test --runtime codex --session replay --input -)
  [ -f "$cp" ] || fail "replay checkpoint missing"
  run_memory "$home" event --type test --runtime codex --session replay --writer replay --idempotency-key after --payload-file - <<<'{"summary":"after passed"}' >/dev/null
  out=$(run_memory "$home" recover --max-events 20)
  assert_contains "$out" "later event evidence (shown 1 of 1):" "recovery did not replay the later semantic event"
  later_count=$(printf '%s\n' "$out" | grep '^later event evidence' | grep -o 'ev_[a-f0-9]*' | sort -u | wc -l | tr -d ' ')
  [ "$later_count" -eq 1 ] || fail "recovery replay duplicated or lost later semantic events: $out"
  assert_contains "$out" "after passed" "recovery replay omitted the later event payload"
  pass "durable memory: high-water replay has no duplicate or lost events"
}

test_recovery_marks_changed_git_and_task_evidence() {
  local home repo old input out
  home=$(new_home reconcile)
  repo="$TMP_ROOT/reconcile-repo"
  git init -q -b main "$repo"
  : > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -q -m first
  old=$(git -C "$repo" rev-parse HEAD)
  : > "$home/state/gone-task.meta"
  input=$(jq -cn --arg root "$repo" --arg head "$old" '{objective:"Reconcile changed authority",completed:[],pending:[],decisions:[],constraints:[],blockers:[],active_tasks:["gone-task"],evidence:[{kind:"git",ref:$root,expected:{head:$head,dirty:false}},{kind:"task",ref:"gone-task",expected:{meta_present:true}}],next_safe_action:"Inspect contradictions",provenance:["authority:git","authority:state/gone-task.meta"],sensitivity:"private"}')
  printf '%s\n' "$input" | FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" "$MEMORY" checkpoint --reason test --runtime codex --session reconcile --input - >/dev/null
  rm "$home/state/gone-task.meta"
  printf 'changed\n' >> "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -q -m second
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" "$MEMORY" recover)
  assert_contains "$out" "disputed: Git HEAD changed" "changed Git evidence was not disputed"
  assert_contains "$out" "stale: task gone-task" "missing task evidence was not marked stale"
  printf '{"session_id":"reconcile"}\n' | FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" "$MEMORY" boundary --reason turn-end --runtime codex >/dev/null
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" "$MEMORY" validate >/dev/null || fail "a new boundary could not supersede stale local evidence"
  pass "durable memory: changed Git and task evidence becomes disputed or stale"
}

test_lock_refusal_and_home_isolation() {
  local one two out status
  one=$(new_home home-one)
  two=$(new_home home-two)
  printf '1\n' > "$one/state/.lock"
  out=$(printf '{}' | run_memory "$one" boundary --reason turn-end --runtime codex)
  assert_contains "$out" "skipped: session lock not owned" "foreign lock did not suppress mutation"
  status=0
  checkpoint_json refused | run_memory "$one" checkpoint --reason manual --runtime codex --session refused --input - >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lock-refused direct checkpoint mutated memory"
  status=0
  run_memory "$one" event --type objective --runtime codex --session refused --payload-file - <<<'{"summary":"refused"}' >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lock-refused direct event mutated memory"
  status=0
  run_memory "$one" transcript-ref --runtime codex --session refused >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lock-refused transcript reference mutated memory"
  [ ! -e "$one/data/memory" ] || fail "lock-refused boundary mutated memory"

  run_memory "$two" event --type objective --runtime codex --session two --writer two --idempotency-key isolated --payload-file - <<<'{"summary":"home two only"}' >/dev/null
  out=$(run_memory "$one" search --query "home two only")
  assert_contains "$out" '"count":0' "one home searched another home's memory"
  out=$(run_memory "$two" search --query "home two only")
  assert_contains "$out" '"count":1' "own-home search did not find its event"
  pass "durable memory: lock refusal is read-only and homes stay isolated"
}

test_search_bounds_sensitivity_and_provenance() {
  local home out
  home=$(new_home search)
  run_memory "$home" event --type decision --runtime opencode --session s --writer w --sensitivity private --source authority:data/backlog.md --idempotency-key visible --payload-file - <<<'{"summary":"visible needle"}' >/dev/null
  run_memory "$home" event --type decision --runtime opencode --session s --writer w --sensitivity restricted --source authority:data/captain.md --idempotency-key restricted --payload-file - <<<'{"summary":"restricted needle"}' >/dev/null
  out=$(run_memory "$home" search --query needle --kind events --limit 1)
  assert_contains "$out" '"count":1' "bounded search did not respect limit"
  assert_contains "$out" '"truncated":false' "restricted result should be filtered before limit accounting"
  assert_contains "$out" 'authority:data/backlog.md' "search omitted provenance"
  assert_not_contains "$out" 'restricted needle' "default search exposed restricted evidence"
  out=$(run_memory "$home" search --query "restricted needle" --include-sensitive)
  assert_contains "$out" '"count":1' "explicit sensitive search did not find restricted evidence"
  pass "durable memory: bounded search filters sensitivity and returns provenance"
}

test_secret_path_and_transcript_guards() {
  local home status payload symlink projects
  home=$(new_home guards)
  status=0
  run_memory "$home" event --type objective --runtime codex --session s --writer w --payload-file - <<<'{"password":"supersecret123"}' >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "secret-like payload was accepted"

  payload="$home/payload.json"
  printf '{"summary":"safe"}\n' > "$payload"
  symlink="$home/payload-link.json"
  ln -s "$payload" "$symlink"
  status=0
  run_memory "$home" event --type objective --runtime codex --session s --writer w --payload-file "$symlink" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "symlink payload input was accepted"

  projects="$home/projects/demo"
  mkdir -p "$projects"
  printf 'opaque transcript\n' > "$projects/session.jsonl"
  status=0
  run_memory "$home" transcript-ref --runtime codex --session s --path "$projects/session.jsonl" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "transcript-ref read under projects/"

  rm -rf "$home/data/memory"
  mkdir -p "$home/escape"
  ln -s "$home/escape" "$home/data/memory"
  status=0
  run_memory "$home" event --type objective --runtime codex --session s --writer w --payload-file - <<<'{"summary":"escape"}' >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "symlinked memory parent accepted a write"
  [ -z "$(find "$home/escape" -mindepth 1 -print -quit)" ] || fail "symlinked memory parent escaped the active data root"
  pass "durable memory: secret, symlink, and project-path guards"
}

test_boundary_preserves_uncaptured_semantic_events() {
  local home out lineage_count
  home=$(new_home boundary-events)
  printf '{"session_id":"codex-session","turn_id":"turn-one"}\n' | run_memory "$home" boundary --reason turn-end --runtime codex >/dev/null
  run_memory "$home" event --type decision --runtime codex --session codex-session --idempotency-key captain-choice --payload-file - <<<'{"summary":"keep the approved route"}' >/dev/null
  printf '{"session_id":"codex-session","turn_id":"turn-two"}\n' | run_memory "$home" boundary --reason pre-compact --runtime codex >/dev/null
  out=$(run_memory "$home" recover --max-events 20)
  assert_contains "$out" "keep the approved route" "automatic boundary swallowed an uncaptured semantic event"
  printf '{"session_id":"codex-session","turn_id":"turn-two"}\n' | run_memory "$home" boundary --reason pre-compact --runtime codex >/dev/null
  lineage_count=$(find "$home/data/memory/events" -type f -name '*.json' -exec jq -r 'select(.type == "session-lineage" and .payload.reason == "pre-compact") | .event_id' {} + | sort -u | wc -l | tr -d ' ')
  [ "$lineage_count" -eq 1 ] || fail "identical boundary retry created $lineage_count lineage events"
  pass "durable memory: automatic boundaries preserve events and retry identity"
}

test_concurrent_capacity_is_strict() {
  local home dir first second count first_status second_status
  home=$(new_home capacity)
  dir="$home/data/memory/events/seed"
  mkdir -p "$dir"
  EVENT_DIR="$dir" node <<'EOF'
import fs from "node:fs";
for (let i = 0; i < 4999; i += 1) {
  const id = `seed-${String(i).padStart(4, "0")}`;
  fs.writeFileSync(`${process.env.EVENT_DIR}/${id}.json`, JSON.stringify({ schema: "fm.memory.event.v1", event_id: id, sequence: id, created_at: "2026-01-01T00:00:00.000Z" }));
}
EOF
  run_memory "$home" event --type test --runtime codex --session capacity --writer one --idempotency-key one --payload-file - <<<'{"summary":"one"}' >/dev/null 2>&1 &
  first=$!
  run_memory "$home" event --type test --runtime codex --session capacity --writer two --idempotency-key two --payload-file - <<<'{"summary":"two"}' >/dev/null 2>&1 &
  second=$!
  first_status=0
  second_status=0
  wait "$first" || first_status=$?
  wait "$second" || second_status=$?
  count=$(find "$home/data/memory/events" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 5000 ] || fail "concurrent capacity writers produced $count events"
  [ "$first_status" -ne 0 ] || [ "$second_status" -ne 0 ] || fail "both concurrent capacity writers succeeded"
  pass "durable memory: concurrent event capacity remains strict"
}

test_codex_compaction_hook_bridge() {
  local home pre_count post bytes
  home=$(new_home codex-compact)
  printf '{"session_id":"codex-hook-session","turn_id":"compact-turn","hook_event_name":"PreCompact","trigger":"auto"}\n' |
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-memory-codex-hook.sh" pre
  pre_count=$(find "$home/data/memory/checkpoints" -type f -name '*.md' | wc -l | tr -d ' ')
  [ "$pre_count" -eq 1 ] || fail "Codex PreCompact bridge did not create one checkpoint"
  post=$(printf '{"session_id":"codex-hook-session","turn_id":"compact-turn","hook_event_name":"PostCompact","trigger":"auto"}\n' |
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-memory-codex-hook.sh" post)
  assert_contains "$post" '"continue":true' "Codex PostCompact bridge did not preserve compaction"
  assert_contains "$post" 'RECOVERY CAPSULE' "Codex PostCompact bridge did not return bounded recovery"
  bytes=$(printf '%s' "$post" | jq -r '.systemMessage' | wc -c | tr -d ' ')
  [ "$bytes" -le 12000 ] || fail "Codex PostCompact recovery exceeded 12000 bytes: $bytes"
  jq -e '.hooks.PreCompact[0].hooks[0].command | contains("fm-memory-codex-hook.sh")' "$ROOT/.codex/hooks.json" >/dev/null || fail "Codex PreCompact hook is not tracked"
  jq -e '.hooks.PostCompact[0].hooks[0].command | contains("fm-memory-codex-hook.sh")' "$ROOT/.codex/hooks.json" >/dev/null || fail "Codex PostCompact hook is not tracked"
  pass "durable memory: Codex automatic compaction bridge checkpoints and recovers"
}

test_all_runtime_turn_fallbacks_share_boundary_owner() {
  local runtime home count
  for runtime in claude codex opencode pi grok; do
    home=$(new_home "runtime-$runtime")
    printf '%s\n' "$$" > "$home/state/.lock"
    printf '{"session_id":"%s-session"}\n' "$runtime" | run_memory "$home" boundary --reason turn-end --runtime "$runtime" >/dev/null
    count=$(find "$home/data/memory/checkpoints" -type f -name '*.md' | wc -l | tr -d ' ')
    [ "$count" -eq 1 ] || fail "$runtime fallback did not create one turn checkpoint"
    run_memory "$home" validate >/dev/null || fail "$runtime checkpoint did not validate: $runtime"
  done
  pass "durable memory: all five supported runtimes use the verified turn-boundary fallback"
}

test_recovery_capsule_is_bounded() {
  local home objective input out bytes
  home=$(new_home capsule-bound)
  objective=$(printf '%06000d' 0 | sed 's/0/🧭/g')
  input=$(jq -cn --arg objective "$objective" '{objective:$objective,completed:[],pending:[],decisions:[],constraints:[],blockers:[],active_tasks:[],evidence:[],next_safe_action:"bounded",provenance:[],sensitivity:"private"}')
  printf '%s\n' "$input" | run_memory "$home" checkpoint --reason test --runtime codex --session bounded --input - >/dev/null
  out=$(run_memory "$home" recover)
  bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
  [ "$bytes" -le 12000 ] || fail "recovery capsule exceeded 12000 bytes: $bytes"
  assert_contains "$out" "recovery capsule truncated" "oversized recovery content did not report truncation"
  pass "durable memory: recovery capsule output stays bounded"
}

test_concurrent_idempotent_events_and_malformed_recovery
test_checkpoint_atomic_validation_and_immutable_history
test_high_water_replay_has_no_duplicate_or_loss
test_recovery_marks_changed_git_and_task_evidence
test_lock_refusal_and_home_isolation
test_search_bounds_sensitivity_and_provenance
test_secret_path_and_transcript_guards
test_boundary_preserves_uncaptured_semantic_events
test_concurrent_capacity_is_strict
test_codex_compaction_hook_bridge
test_all_runtime_turn_fallbacks_share_boundary_owner
test_recovery_capsule_is_bounded
