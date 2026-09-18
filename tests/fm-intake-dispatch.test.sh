#!/usr/bin/env bash
# Behavior tests for the one-command task intake and dispatch transaction.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-intake-dispatch.sh"
TMP_ROOT=$(fm_test_tmproot fm-intake-dispatch)

if ! command -v tasks-axi >/dev/null 2>&1; then
  echo "skip: tasks-axi not found"
  exit 0
fi

make_case() {  # <name> <brief-mode>; prints case|home|fake-root
  local name=$1 brief_mode=$2 case_dir home fake_root file base
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fake_root="$case_dir/root"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fake_root/bin"
  printf '## Queued\n\n## In flight\n\n## Done\n' > "$home/data/backlog.md"
  for file in "$ROOT"/bin/*; do
    base=${file##*/}
    case "$base" in
      fm-brief.sh|fm-spawn.sh) ;;
      *) ln -s "$file" "$fake_root/bin/$base" ;;
    esac
  done
  if [ "$brief_mode" = real ]; then
    ln -s "$ROOT/bin/fm-brief.sh" "$fake_root/bin/fm-brief.sh"
  else
    cat > "$fake_root/bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=$1
mkdir -p "$FM_HOME/data/tasks/$id"
if [ "${FM_FAKE_BRIEF_STATUS:-0}" -ne 0 ]; then
  printf 'fake brief diagnostic\n' >&2
  exit "$FM_FAKE_BRIEF_STATUS"
fi
sleep "${FM_FAKE_BRIEF_SLEEP:-0}"
printf '%s\n' "You are a crewmate." '' '# Task' "## Captain's intent" '{TASK}' '' '## Firstmate spec' '{FIRSTMATE_SPEC}' > "$FM_HOME/data/tasks/$id/brief.md"
SH
    chmod +x "$fake_root/bin/fm-brief.sh"
  fi
  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_SPAWN_LOG:?}"
sleep "${FM_FAKE_SPAWN_SLEEP:-0}"
if [ "${FM_FAKE_SPAWN_STATUS:-0}" -ne 0 ]; then
  printf 'fake spawn diagnostic\n' >&2
  exit "$FM_FAKE_SPAWN_STATUS"
fi
SH
  chmod +x "$fake_root/bin/fm-spawn.sh"
  printf '%s|%s|%s\n' "$case_dir" "$home" "$fake_root"
}

run_case() {  # <record> [extra env assignments are set by caller]
  local record=$1 case_dir home fake_root
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  shift
  FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_FAKE_SPAWN_LOG="$case_dir/spawn.log" "$INTAKE" "$@"
}

base_args() {  # <id>
  local id=$1
  BASE_ARGS=(
    --id "$id" --title 'Atomic intake' --project firstmate --kind ship
    --intent $'Captain line one\nCaptain line two'
    --spec $'Build line one\nBuild line two'
    --mode local-only --yolo off --harness pi --model default --effort default --backend tmux
  )
}

test_success_and_multiline() {
  local record out case_dir home fake_root brief
  record=$(make_case success real ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  base_args intake-a1
  out=$(run_case "$record" "${BASE_ARGS[@]}" 2>&1) || fail "successful intake failed: $out"
  assert_equals 'intake-dispatch: dispatched id=intake-a1 kind=ship' "$out" \
    'success emitted more than the concise result'
  brief="$home/data/tasks/intake-a1/brief.md"
  assert_present "$brief" 'success did not create the canonical instructions'
  assert_grep 'Captain line one' "$brief" 'first captain-intent line was lost'
  assert_grep 'Captain line two' "$brief" 'multiline captain intent was lost'
  assert_grep 'Build line one' "$brief" 'first spec line was lost'
  assert_grep 'Build line two' "$brief" 'multiline Firstmate spec was lost'
  assert_grep 'intake-a1' "$home/data/backlog.md" 'success did not create the queued backlog item'
  assert_grep '--harness pi --model default --backend tmux' "$case_dir/spawn.log" \
    'concrete dispatch profile was not passed to fm-spawn'
  pass 'intake dispatch creates canonical instructions, preserves multiline text, and launches once'
}

test_scout_herdr_variant() {
  local record out case_dir home fake_root brief
  record=$(make_case scout real ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  out=$(run_case "$record" --id scout-a --title 'Scout task' --project firstmate --kind scout \
    --intent $'Investigate one\nInvestigate two' --spec $'Report one\nReport two' \
    --harness muse --model default --effort default --backend cmux --herdr-lab 2>&1) \
    || fail "scout intake failed: $out"
  assert_equals 'intake-dispatch: dispatched id=scout-a kind=scout' "$out" \
    'scout result was not concise'
  brief="$home/data/tasks/scout-a/brief.md"
  assert_grep '# Herdr isolation - HARD SAFETY CONTRACT' "$brief" \
    'scout --herdr-lab did not select the task-specific brief variant'
  assert_grep 'scout-a' "$home/data/backlog.md" 'scout intake did not create its backlog item'
  pass 'scout intake supports the Herdr brief variant independently of its selected backend'
}

test_existing_refusal() {
  local record out case_dir home fake_root status
  record=$(make_case existing real ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  tasks-axi add intake-existing 'Existing task' --kind ship --repo firstmate --file "$home/data/backlog.md" >/dev/null
  mkdir -p "$home/data/tasks/intake-existing"
  printf 'keep\n' > "$home/data/tasks/intake-existing/brief.md"
  base_args intake-existing
  out=$(run_case "$record" "${BASE_ARGS[@]}" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'existing task was accepted'
  assert_contains "$out" 'already exists' 'existing-task refusal was not actionable'
  assert_equals 'keep' "$(cat "$home/data/tasks/intake-existing/brief.md")" \
    'existing instructions were overwritten'
  pass 'existing task and directory are refused without mutation'
}

test_malformed_and_dependency_refusal() {
  local record out case_dir home fake_root status
  record=$(make_case malformed real ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  base_args '../escape'
  out=$(run_case "$record" "${BASE_ARGS[@]}" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'malformed id was accepted'
  assert_contains "$out" 'invalid task id' 'malformed id refusal was not actionable'
  assert_not_contains "$(cat "$home/data/backlog.md")" 'escape' 'malformed input mutated the backlog'

  base_args intake-dependency
  out=$(run_case "$record" "${BASE_ARGS[@]}" --blocked-by missing-dependency 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'missing dependency was accepted'
  assert_contains "$out" 'dependency missing-dependency is unavailable' 'dependency failure did not name the blocker'
  assert_not_contains "$(cat "$home/data/backlog.md")" 'intake-dependency' 'dependency failure mutated the backlog'
  pass 'malformed requests and unavailable dependencies stop before durable intake'
}

test_instruction_rollback() {
  local record out case_dir home fake_root status
  record=$(make_case rollback scaffold-fail)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  base_args rollback-a
  out=$(FM_FAKE_BRIEF_STATUS=9 run_case "$record" "${BASE_ARGS[@]}" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'scaffold failure was reported as success'
  assert_contains "$out" 'phase=instructions' 'scaffold failure did not name its phase'
  assert_contains "$out" 'fake brief diagnostic' 'scaffold diagnostic was lost'
  assert_not_contains "$(cat "$home/data/backlog.md")" 'rollback-a' 'scaffold failure left a backlog row'
  assert_absent "$home/data/tasks/rollback-a" 'scaffold failure left a newly created task directory'
  pass 'instruction-generation failure rolls back only the new row and directory'
}

test_spawn_failure_and_retry() {
  local record out case_dir home fake_root status
  record=$(make_case retry real ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  base_args retry-a
  out=$(FM_FAKE_SPAWN_STATUS=9 run_case "$record" "${BASE_ARGS[@]}" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'spawn failure was reported as success'
  assert_contains "$out" 'queued task and complete instructions preserved for retry' \
    'spawn failure did not promise retryable durable work'
  assert_contains "$out" 'fake spawn diagnostic' 'spawn diagnostic was lost'
  assert_grep 'retry-a' "$home/data/backlog.md" 'spawn failure lost the queued row'
  out=$(run_case "$record" --retry "${BASE_ARGS[@]}" 2>&1) \
    || fail "retry did not dispatch: $out"
  assert_equals 'intake-dispatch: dispatched id=retry-a kind=ship' "$out" 'retry result was not concise'
  pass 'launch failure preserves a valid queued task and the explicit retry path reuses it'
}

test_legacy_retry_and_rollback_boundary() {
  local record out case_dir home fake_root status
  record=$(make_case legacy real ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  tasks-axi add legacy-a 'Legacy task' --kind ship --repo firstmate --file "$home/data/backlog.md" >/dev/null
  mkdir -p "$home/data/legacy-a"
  cat > "$home/data/legacy-a/brief.md" <<'EOF'
You are a crewmate.

# Task
## Captain's intent
old intent

## Firstmate spec
old spec
EOF
  out=$(run_case "$record" --retry --id legacy-a --project firstmate --kind ship \
    --mode local-only --yolo off --harness pi --model default --effort default --backend tmux 2>&1) \
    || fail "legacy retry failed: $out"
  assert_equals 'intake-dispatch: dispatched id=legacy-a kind=ship' "$out" 'legacy retry result was not concise'
  assert_present "$home/data/legacy-a/brief.md" 'legacy instructions were removed by retry'

  record=$(make_case boundary real ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  mkdir -p "$home/data/boundary-a"
  printf 'do not remove\n' > "$home/data/boundary-a/brief.md"
  base_args boundary-a
  out=$(run_case "$record" "${BASE_ARGS[@]}" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail 'legacy existing directory was accepted'
  assert_contains "$out" 'task directory already exists' 'legacy existing directory refusal was unclear'
  assert_equals 'do not remove' "$(cat "$home/data/boundary-a/brief.md")" \
    'existing legacy instructions were removed'
  pass 'legacy reads remain bounded and existing directories are never rollback targets'
}

test_concurrent_same_id() {
  local record case_dir home fake_root out2 status1 status2
  record=$(make_case concurrent scaffold-ok)
  IFS='|' read -r case_dir home fake_root <<EOF
$record
EOF
  base_args concurrent-a
  FM_FAKE_BRIEF_SLEEP=1 run_case "$record" "${BASE_ARGS[@]}" >"$case_dir/one.out" 2>&1 &
  one=$!
  sleep 0.1
  out2=$(run_case "$record" "${BASE_ARGS[@]}" 2>&1); status2=$?
  wait "$one"; status1=$?
  [ "$status1" -eq 0 ] || fail "first concurrent intake failed: $(cat "$case_dir/one.out")"
  [ "$status2" -ne 0 ] || fail 'same-id concurrent intake was not refused'
  assert_contains "$out2" 'another intake is already handling this id' \
    'same-id concurrency refusal was not actionable'
  pass 'same-id concurrent calls serialize before backlog or instructions are published'
}

test_success_and_multiline
test_scout_herdr_variant
test_existing_refusal
test_malformed_and_dependency_refusal
test_instruction_rollback
test_spawn_failure_and_retry
test_legacy_retry_and_rollback_boundary
test_concurrent_same_id

pass 'fm-intake-dispatch: deterministic transaction coverage complete'
