#!/usr/bin/env bash
# Focused public-interface tests for captain holds over canonical task records.
set -u

# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold)

make_home() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' 'legacy backlog evidence must remain byte-stable' >"$home/data/backlog.md"
  printf '%s\n' "$home"
}

run_captain() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_tasks() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

run_progress() { # <home> <task> <json>
  local home=$1 task=$2 progress=$3
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-task-state.sh" update-progress "$task" --progress "$progress"
}

test_hold_answer_uses_one_canonical_record() {
  local home before after identity answer record rc
  home=$(make_home hold-answer)
  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')

  run_captain "$home" hold route-call --title 'Choose the route' \
    --reason 'captain route choice pending' --repo sample --origin route-review >/dev/null \
    || fail 'canonical captain hold failed'
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail 'captain hold rewrote legacy backlog evidence'
  [ -f "$home/data/route-call/task.json" ] || fail 'captain hold did not create its canonical task record'
  [ "$(find "$home/data/route-call" -maxdepth 1 -type f -printf '%f\n' | sort)" = task.json ] \
    || fail 'captain hold created a second live task-state file'
  jq -e '
    .id == "route-call" and .title == "Choose the route" and .state == "queued"
      and .kind == "captain" and .repo == "sample"
      and .hold.kind == "captain" and .hold.reason == "captain route choice pending"
      and (.body | contains("Origin: route-review"))
  ' "$home/data/route-call/task.json" >/dev/null || fail 'canonical hold fields are incomplete'

  identity=$(run_captain "$home" open route-call --identity) || fail 'open captain call was not readable'
  case "$identity" in
    20??-??-??T??:??:??Z#0) ;;
    *) fail "captain-call identity is malformed: $identity" ;;
  esac

  answer="$home/answer.txt"
  printf '%s' 'Use the north route.' >"$answer"
  run_captain "$home" answer route-call --decision-file "$answer" >/dev/null \
    || fail 'canonical captain answer failed'
  record=$(run_tasks "$home" show route-call --full) || fail 'answered task record disappeared'
  assert_contains "$record" 'state: done' 'answer did not close the captain call'
  assert_contains "$record" 'Captain decision:\nUse the north route.' 'answer did not preserve the exact decision'
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail 'captain answer rewrote legacy backlog evidence'
  rc=0
  run_captain "$home" open route-call --identity >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "answered captain call remained open with status $rc"
  pass 'captain hold and answer mutate one canonical task record without rewriting legacy backlog evidence'
}

test_release_resumes_existing_work() {
  local home answer
  home=$(make_home release)
  run_tasks "$home" add gated-work 'Apply the selected route' --kind ship --repo sample --start >/dev/null \
    || fail 'could not create canonical work fixture'
  run_captain "$home" hold gated-work --reason 'captain approval pending' >/dev/null \
    || fail 'could not hold existing canonical work'
  answer="$home/answer.txt"
  printf '%s' 'Proceed with the existing work.' >"$answer"
  run_captain "$home" answer gated-work --decision-file "$answer" --release >/dev/null \
    || fail 'release answer failed'
  jq -e '
    .state == "in_flight" and .hold == null
      and (.body | contains("Resolution mode: released"))
      and (.body | contains("Proceed with the existing work."))
  ' "$home/data/gated-work/task.json" >/dev/null \
    || fail 'release did not resume the same canonical work record'
  pass 'a release answer removes the captain hold without creating another task state'
}

test_completion_gate_keeps_open_call_authoritative() {
  local home
  home=$(make_home completion)
  run_tasks "$home" add route-review 'Review route behavior' --kind scout --repo sample --start >/dev/null \
    || fail 'could not create review fixture'
  fm_test_write_herdr_meta "$home/state/route-review.meta" \
    'window=fixture:route-review' \
    "worktree=$home/projects/route-review" \
    "project=$home/projects/sample" \
    'harness=codex' 'kind=scout' 'mode=scout' 'spawn_gen=fixture-route-review'
  cat >"$home/state/route-review.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose north or south
EOF
  run_captain "$home" hold route-call --title 'Choose north or south' \
    --reason 'route decision pending' --repo sample --origin route-review >/dev/null \
    || fail 'could not create the inventoried captain call'
  run_captain "$home" complete route-review route-call >/dev/null \
    || fail 'completion gate rejected its canonical captain-call inventory'
  assert_grep 'decisions_reviewed=1' "$home/state/route-review.meta" \
    'completion attestation is missing'
  assert_grep 'decision_keys=route-call' "$home/state/route-review.meta" \
    'completion inventory did not retain the canonical task id'
  run_captain "$home" open route-call --identity >/dev/null \
    || fail 'completion gate closed the still-open captain call'
  pass 'completion records the canonical captain-call inventory and leaves the call open'
}

test_ordinary_done_task_cannot_be_recast_as_a_captain_answer() {
  local home answer rc
  home=$(make_home ordinary-done)
  run_tasks "$home" add finished-work 'Already finished work' --kind ship --start >/dev/null \
    || fail 'could not create ordinary work fixture'
  run_progress "$home" finished-work \
    '{"acceptance":"The work is complete","current_state":"MAIN accepted the outcome","remaining_gap":"","next_step":""}' \
    >/dev/null || fail 'could not accept ordinary work fixture'
  run_tasks "$home" 'done' finished-work >/dev/null || fail 'could not close ordinary work fixture'
  answer="$home/answer.txt"
  printf '%s' 'Pretend this was a captain call.' >"$answer"
  rc=0
  run_captain "$home" answer finished-work --decision-file "$answer" \
    >"$home/answer.out" 2>"$home/answer.err" || rc=$?
  [ "$rc" -ne 0 ] || fail 'ordinary Done work was recast as an answered captain call'
  assert_grep 'was never held for the captain' "$home/answer.err" \
    'ordinary Done refusal did not name the missing captain-hold authority'
  jq -e '
    .state == "done" and .hold == null
      and (.body | contains("Pretend this was a captain call.") | not)
  ' "$home/data/finished-work/task.json" >/dev/null \
    || fail 'refused answer mutated ordinary Done work'
  pass 'ordinary Done work cannot be revived or relabeled through the captain-answer path'
}

test_hold_answer_uses_one_canonical_record
test_release_resumes_existing_work
test_completion_gate_keeps_open_call_authoritative
test_ordinary_done_task_cannot_be_recast_as_a_captain_answer
