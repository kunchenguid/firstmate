#!/usr/bin/env bash
# End-to-end tests for the fm-decision-hold.sh compatibility shim's `resolve`
# command: durable resolution against a routed task whose blocked_by is a
# tasks-axi-quoted multi-entry list, and the no-routed-work path.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-hold)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# A routed task blocked by three tasks, with the decision hold's identity at a
# given position in that comma list. tasks-axi renders a multi-entry
# blocked_by as one double-quoted CSV value; resolve must strip that wrapper
# regardless of where in the list the hold's own id sits.
setup_positioned_routed_task() {  # <home> <hold-id> <routed-id> <position: first|middle|last|only>
  local home=$1 hold=$2 routed=$3 position=$4
  tasks_in "$home" add "$routed" "routed work" --kind ship --repo sample >/dev/null
  tasks_in "$home" add "sample-other-blocker-1" "other blocker" --kind ship --repo sample >/dev/null 2>&1 || true
  tasks_in "$home" add "sample-other-blocker-2" "other blocker" --kind ship --repo sample >/dev/null 2>&1 || true
  case "$position" in
    first)
      tasks_in "$home" block "$routed" --by "$hold" >/dev/null
      tasks_in "$home" block "$routed" --by sample-other-blocker-1 >/dev/null
      tasks_in "$home" block "$routed" --by sample-other-blocker-2 >/dev/null
      ;;
    middle)
      tasks_in "$home" block "$routed" --by sample-other-blocker-1 >/dev/null
      tasks_in "$home" block "$routed" --by "$hold" >/dev/null
      tasks_in "$home" block "$routed" --by sample-other-blocker-2 >/dev/null
      ;;
    last)
      tasks_in "$home" block "$routed" --by sample-other-blocker-1 >/dev/null
      tasks_in "$home" block "$routed" --by sample-other-blocker-2 >/dev/null
      tasks_in "$home" block "$routed" --by "$hold" >/dev/null
      ;;
    only)
      tasks_in "$home" block "$routed" --by "$hold" >/dev/null
      ;;
  esac
}

test_resolve_handles_quoted_blocker_at_each_position() {
  local home hold routed position show
  home=$(make_home quoted-blocker-positions)
  for position in first middle last only; do
    routed="sample-routed-$position"
    hold=$(run_shim "$home" hold sample "$position" \
      --title "Pick $position" --reason "captain choice pending" --repo sample) \
      || fail "the shim hold path failed for position $position"
    setup_positioned_routed_task "$home" "$hold" "$routed" "$position"
    printf 'Use route %s.\n' "$position" > "$home/route-$position.txt"
    run_shim "$home" resolve sample "$position" \
      --decision-file "$home/route-$position.txt" --routed-to "$routed" >/dev/null \
      || fail "resolve rejected a quoted blocker with the decision id $position in the list"
    show=$(tasks_in "$home" show "$hold" --full)
    assert_contains "$show" "state: done" "resolve did not close the $position-position hold"
    show=$(tasks_in "$home" show "$routed" --full | grep '^  blocked_by:')
    assert_not_contains "$show" "$hold" "resolve left the $position-position routed task blocked by the closed hold"
  done
  pass "resolve strips the quoted blocked_by wrapper for first, middle, last, and only blockers"
}

test_resolve_no_action_records_a_decision_with_no_routed_work() {
  local home hold show
  home=$(make_home no-action)
  hold=$(run_shim "$home" hold sample skip-it \
    --title "Skip it" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  printf 'Do nothing for now.\n' > "$home/no-action.txt"

  if run_shim "$home" resolve sample skip-it --decision-file "$home/no-action.txt" \
    --no-action --routed-to sample-unrelated-work \
    > "$home/mutex.out" 2> "$home/mutex.err"; then
    fail "resolve accepted --no-action combined with --routed-to"
  fi
  assert_grep "cannot be combined" "$home/mutex.err" \
    "the refusal must explain the --no-action/--routed-to conflict"

  run_shim "$home" resolve sample skip-it --decision-file "$home/no-action.txt" \
    --no-action >/dev/null \
    || fail "resolve --no-action failed to record a routeless captain decision"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "resolve --no-action did not close the hold"
  assert_contains "$show" "Do nothing for now." "resolve --no-action lost the captain decision text"

  run_shim "$home" resolve sample skip-it --decision-file "$home/no-action.txt" \
    --no-action >/dev/null \
    || fail "replaying the same resolve --no-action call was rejected"
  pass "resolve --no-action records a durable decision with no routed follow-up work"
}

test_resolve_still_requires_routed_to_or_no_action() {
  local home
  home=$(make_home routed-required)
  run_shim "$home" hold sample undecided \
    --title "Undecided" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "the shim hold path failed"
  printf 'placeholder\n' > "$home/placeholder.txt"
  if run_shim "$home" resolve sample undecided --decision-file "$home/placeholder.txt" \
    > "$home/missing.out" 2> "$home/missing.err"; then
    fail "resolve accepted neither --routed-to nor --no-action"
  fi
  assert_grep "--no-action" "$home/missing.err" \
    "the refusal must point at --no-action as the routeless path"
  pass "resolve still refuses when neither --routed-to nor --no-action is given"
}

test_resolve_handles_quoted_blocker_at_each_position
test_resolve_no_action_records_a_decision_with_no_routed_work
test_resolve_still_requires_routed_to_or_no_action
