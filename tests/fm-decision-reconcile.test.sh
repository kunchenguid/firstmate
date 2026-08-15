#!/usr/bin/env bash
# Behavioral coverage for policy-to-task reconciliation mechanics.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILE="$ROOT/bin/fm-decision-reconcile.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-reconcile)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
python3 - <<'PY' >/dev/null 2>&1 || { echo "skip: tomllib not found"; exit 0; }
import tomllib
PY
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

run_reconcile() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_POLICIES_FILE="$ROOT/policies/operating-policies.toml" \
    FM_PACKAGES_FILE="$ROOT/policies/implementation-packages.toml" \
    "$RECONCILE" "$@"
}

test_policy_list_includes_routine_completion() {
  local out
  out=$(run_reconcile "$TMP_ROOT/list-home" policy-list)
  assert_contains "$out" $'routine-completion\t' "policy-list omitted routine-completion"
  pass "policy-list reads the tracked operating policy registry"
}

test_resolve_hold_closes_duplicate_question() {
  local home id show
  home=$(make_home resolve-hold)
  id=sample-plan-m6-decision-launch-library-tier
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $id - Choose launch library tier (repo: sample) (kind: captain) (hold: budget) (hold-kind: captain)

## Done
EOF
  tasks_axi() { (cd "$home" && tasks-axi "$@"); }
  tasks_axi add "$id" "Choose launch library tier" --kind captain --repo sample >/dev/null
  tasks_axi hold "$id" --reason "budget" --kind captain >/dev/null
  run_reconcile "$home" resolve-hold "$id" --policy no-human-recording-library >/dev/null \
    || fail "resolve-hold did not close the duplicate captain hold"
  show=$(cd "$home" && tasks-axi show "$id" --full)
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost durable decision record"
  assert_contains "$show" "policy=no-human-recording-library" "resolved hold is not linked to the policy id"
  pass "resolve-hold closes a duplicate captain hold with a durable policy link"
}

test_retire_marks_tasks_done() {
  local home show
  home=$(make_home retire)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-career-task - Retired career item (repo: job-tracker) (kind: captain)

## Done
EOF
  (cd "$home" && tasks-axi add sample-career-task "Retired career item" --kind captain --repo job-tracker) >/dev/null
  printf 'Career work is retired.\n' > "$home/decision.txt"
  run_reconcile "$home" retire sample-career-task --decision-file "$home/decision.txt" >/dev/null \
    || fail "retire did not complete"
  show=$(cd "$home" && tasks-axi show sample-career-task --full)
  assert_contains "$show" "state: done" "retire did not mark the task done"
  pass "retire records a durable retirement decision and closes the task"
}

test_policy_list_includes_routine_completion
test_resolve_hold_closes_duplicate_question
test_retire_marks_tasks_done

echo "all decision reconciliation tests passed"
