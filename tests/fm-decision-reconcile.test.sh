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

test_resolve_hold_refuses_captain_escalation() {
  local home id show rc
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
  set +e
  run_reconcile "$home" resolve-hold "$id" --policy no-human-recording-library >/dev/null 2>&1
  rc=$?
  set -u
  [ "$rc" -ne 0 ] || fail "resolve-hold closed a captain-escalated duplicate hold"
  show=$(cd "$home" && tasks-axi show "$id" --full)
  assert_contains "$show" "held: yes" "captain-escalated hold was not left open"
  pass "resolve-hold leaves captain-escalated duplicate holds open"
}

test_resolve_hold_closes_non_escalated_duplicate_question() {
  local home id show
  home=$(make_home resolve-hold-none)
  id=sample-plan-m6-decision-standard-repo
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $id - Choose standard repository flow (repo: sample) (kind: captain) (hold: process) (hold-kind: captain)

## Done
EOF
  tasks_axi() { (cd "$home" && tasks-axi "$@"); }
  tasks_axi add "$id" "Choose standard repository flow" --kind captain --repo sample >/dev/null
  tasks_axi hold "$id" --reason "process" --kind captain >/dev/null
  run_reconcile "$home" resolve-hold "$id" --policy dotfiles-normal-repo >/dev/null \
    || fail "resolve-hold did not close a non-escalated duplicate captain hold"
  show=$(cd "$home" && tasks-axi show "$id" --full)
  assert_contains "$show" "Resolution recorded by fm-decision-hold" "resolved hold lost durable decision record"
  assert_contains "$show" "policy=dotfiles-normal-repo" "resolved hold is not linked to the policy id"
  pass "resolve-hold closes non-escalated duplicate holds with a durable policy link"
}

test_resolve_hold_leaves_open_when_policy_link_fails() {
  local home id show rc real_tasks_axi
  home=$(make_home resolve-link-fails)
  id=sample-plan-m6-decision-link-failure
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $id - Choose standard repository flow (repo: sample) (kind: captain) (hold: process) (hold-kind: captain)

## Done
EOF
  tasks_axi() { (cd "$home" && tasks-axi "$@"); }
  tasks_axi add "$id" "Choose standard repository flow" --kind captain --repo sample >/dev/null
  tasks_axi hold "$id" --reason "process" --kind captain >/dev/null
  mkdir -p "$home/tmp"
  real_tasks_axi=$(command -v tasks-axi)
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = update ]; then exit 1; fi
exec "$real_tasks_axi" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  set +e
  TMPDIR="$home/tmp" PATH="$home/fakebin:$PATH" run_reconcile "$home" resolve-hold "$id" --policy dotfiles-normal-repo >/dev/null 2>&1
  rc=$?
  set -u
  [ "$rc" -ne 0 ] || fail "resolve-hold closed a hold after its policy link failed"
  show=$(cd "$home" && tasks-axi show "$id" --full)
  assert_contains "$show" "held: yes" "policy-link failure did not leave the hold open"
  [ -z "$(find "$home/tmp" -type f -name 'fm-policy-decision.*' -print -quit)" ] \
    || fail "resolve-hold left a temporary decision copy after failure"
  pass "resolve-hold leaves the hold open when policy linking fails"
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
  run_reconcile "$home" retire sample-career-task --decision-file "$home/decision.txt" --policy career-retired >/dev/null \
    || fail "retire did not complete"
  show=$(cd "$home" && tasks-axi show sample-career-task --full)
  assert_contains "$show" "policy=career-retired" "retired task is not linked to its policy"
  assert_contains "$show" "state: done" "retire did not mark the task done"
  pass "retire records a durable retirement decision and closes the task"
}

test_retire_requires_explicit_policy_for_captain_hold() {
  local home id show rc
  home=$(make_home retire-held)
  id=sample-captain-decision-exception
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $id - Captain exception (repo: sample) (kind: captain) (hold: exception) (hold-kind: captain)

## Done
EOF
  tasks_axi() { (cd "$home" && tasks-axi "$@"); }
  tasks_axi add "$id" "Captain exception" --kind captain --repo sample >/dev/null
  tasks_axi hold "$id" --reason "exception" --kind captain >/dev/null
  printf 'Retired by policy reconciliation.\n' > "$home/decision.txt"
  set +e
  run_reconcile "$home" retire "$id" --decision-file "$home/decision.txt" >/dev/null 2>&1
  rc=$?
  set -u
  [ "$rc" -ne 0 ] || fail "retire closed a captain hold without an explicit policy"
  show=$(cd "$home" && tasks-axi show "$id" --full)
  assert_contains "$show" "held: yes" "retire did not leave the captain hold open"
  pass "retire requires an explicit policy for captain holds"
}

test_retire_closes_career_hold_with_explicit_policy() {
  local home id show
  home=$(make_home retire-career-held)
  id=sample-career-v1-decision-archive
  cat > "$home/data/backlog.md" <<EOF
## In flight

## Queued
- [ ] $id - Retire career item (repo: job-tracker) (kind: captain) (hold: retirement) (hold-kind: captain)

## Done
EOF
  tasks_axi() { (cd "$home" && tasks-axi "$@"); }
  tasks_axi add "$id" "Retire career item" --kind captain --repo job-tracker >/dev/null
  tasks_axi hold "$id" --reason "retirement" --kind captain >/dev/null
  printf 'Career work is retired.\n' > "$home/decision.txt"
  run_reconcile "$home" retire "$id" --decision-file "$home/decision.txt" --policy career-retired >/dev/null \
    || fail "retire did not close a career hold with its explicit policy"
  show=$(cd "$home" && tasks-axi show "$id" --full)
  assert_contains "$show" "policy=career-retired" "retired career hold is not linked to its policy"
  assert_contains "$show" "state: done" "retire did not close the career hold"
  pass "retire closes career holds only with an explicit non-escalated policy"
}

test_policy_list_includes_routine_completion
test_resolve_hold_refuses_captain_escalation
test_resolve_hold_closes_non_escalated_duplicate_question
test_resolve_hold_leaves_open_when_policy_link_fails
test_retire_marks_tasks_done
test_retire_requires_explicit_policy_for_captain_hold
test_retire_closes_career_hold_with_explicit_policy

echo "all decision reconciliation tests passed"
