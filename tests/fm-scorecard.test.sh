#!/usr/bin/env bash
# tests/fm-scorecard.test.sh - the advisory outcome scorecard read over fixture
# fleet ledgers in two homes. docs/fleet-ledger.md owns the record contract and
# the scorecard column definitions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-scorecard)
SCORECARD="$ROOT/bin/fm-scorecard.sh"

rec() {  # <ts> <event> <task> [jq object members]
  printf '{"v":1,"ts":%s,"event":"%s","task":"%s"%s}\n' "$1" "$2" "$3" "${4:+,$4}"
}

# Main home: a merged ship, an abandoned ship that blocked, a relaunched ship
# still open on a default model, a secondmate dispatch, a task whose dispatch
# predates the ledger, and one malformed line.
# Second mate home: a landed scout, a merged ship, and a ship whose done status
# raced ahead of its dispatch record. The registry also names a remote mate and
# a mate whose home has no ledger yet.
make_homes() {
  MAIN="$TMP_ROOT/main"
  MATE="$TMP_ROOT/mate"
  mkdir -p "$MAIN/state" "$MAIN/data" "$MATE/state" "$TMP_ROOT/quiet/state"
  {
    rec 1000 task.dispatched t-merged '"kind":"ship","project":"p","harness":"claude","model":"opus"'
    rec 1100 task.status t-merged '"state":"done","key":null,"text":"pr ready"'
    rec 1100 task.status t-merged '"state":"done","key":null,"text":"pr ready"'
    rec 4600 task.pr_ready t-merged '"pr":"https://example.test/pr/1"'
    rec 4700 task.merged t-merged '"via":"pr","pr":"https://example.test/pr/1"'
    rec 4800 task.cleaned_up t-merged
    rec 2000 task.dispatched t-abandoned '"kind":"ship","project":"p","harness":"claude","model":"opus"'
    rec 2500 task.status t-abandoned '"state":"blocked","key":"k1","text":"needs a decision"'
    rec 5000 task.cleaned_up t-abandoned
    rec 3000 task.dispatched t-relaunched '"kind":"ship","project":"p","harness":"codex","model":null'
    rec 3500 task.relaunched t-relaunched '"harness":"codex","model":null'
    rec 10200 task.pr_ready t-relaunched '"pr":"https://example.test/pr/2"'
    rec 3000 task.dispatched mate-x '"kind":"secondmate","project":null,"harness":"claude","model":null'
    rec 900 task.status old-task '"state":"done","key":null,"text":"finished"'
    printf 'not json\n'
  } > "$MAIN/state/fleet-ledger.jsonl"
  {
    rec 1000 task.dispatched s-scout '"kind":"scout","project":"p","harness":"claude","model":"opus"'
    rec 2800 task.status s-scout '"state":"done","key":null,"text":"report written"'
    rec 2900 task.cleaned_up s-scout
    rec 4000 task.dispatched s-ship '"kind":"ship","project":"p","harness":"claude","model":"opus"'
    rec 4600 task.pr_ready s-ship '"pr":"https://example.test/pr/3"'
    rec 4700 task.merged s-ship '"via":"local","pr":null'
    rec 5300 task.status s-raced '"state":"done","key":null,"text":"ready"'
    rec 5000 task.dispatched s-raced '"kind":"ship","project":"p","harness":"claude","model":"opus"'
  } > "$MATE/state/fleet-ledger.jsonl"
  {
    printf '# Second mates\n\n'
    printf -- '- mate - fixture mate (home: %s; scope: fixture; projects: p; added 2026-10-31)\n' "$MATE"
    printf -- '- quiet - no ledger yet (home: %s; scope: fixture; projects: p; added 2026-10-31)\n' "$TMP_ROOT/quiet"
    printf -- '- far - a remote mate (host: far.example; root: /srv/fm; home: /srv/fm/home; scope: other; projects: p; added 2026-10-31)\n'
  } > "$MAIN/data/secondmates.md"
}

scorecard() {
  FM_HOME=$MAIN "$SCORECARD" "$@"
}

group() {  # <json> <profile> <kind> <jq expression over the group>
  printf '%s\n' "$1" | jq -c --arg p "$2" --arg k "$3" ".groups[] | select(.profile == \$p and .kind == \$k) | $4"
}

test_json_reports_every_group_from_every_default_home() {
  local out
  out=$(scorecard --json) || fail "scorecard --json exited nonzero"
  assert_equals true "$(printf '%s\n' "$out" | jq '.advisory')" "advisory flag"
  assert_equals '["this-home","14 records, 1 unreadable lines skipped","mate","8 records","quiet","no ledger","far","remote on far.example, not read"]' \
    "$(printf '%s\n' "$out" | jq -c '[.homes[] | .label, .status]')" "home list and statuses"
  assert_equals '[["claude/opus","scout"],["claude/opus","ship"],["codex/default","ship"]]' \
    "$(printf '%s\n' "$out" | jq -c '[.groups[] | [.profile, .kind]]')" "groups, secondmate dispatch excluded"
  # claude/opus ship: t-merged (3600s), t-abandoned (no ready), s-ship (600s),
  # s-raced (300s to its first done).
  assert_equals '[4,true,{"samples":3,"median":600,"p90":3600},null,1,0,2,1,1]' \
    "$(group "$out" claude/opus ship '[.tasks, .small_sample, .ready_seconds, .validation_rounds, .blocked, .relaunched, .landed, .abandoned, .open]')" \
    "claude/opus ship numbers"
  assert_equals '[1,{"samples":1,"median":7200,"p90":7200},0,1,0,0,1]' \
    "$(group "$out" codex/default ship '[.tasks, .ready_seconds, .blocked, .relaunched, .landed, .abandoned, .open]')" \
    "codex/default ship numbers"
  assert_equals '[1,{"samples":1,"median":1800,"p90":1800},1,0,0]' \
    "$(group "$out" claude/opus scout '[.tasks, .ready_seconds, .landed, .abandoned, .open]')" \
    "claude/opus scout numbers"
  assert_equals 1 "$(printf '%s\n' "$out" | jq '.undispatched_tasks')" "task with no dispatch record"
  pass "json: every default home is read and each group's numbers are computed"
}

test_text_table_is_compact_and_flags_small_groups() {
  local out
  out=$(scorecard | tr -s ' ') || fail "scorecard exited nonzero"
  assert_contains "$out" "advisory only; it never changes routing" "advisory header"
  assert_contains "$out" "remote on far.example, not read" "remote home listed"
  assert_contains "$out" "quiet no ledger" "missing ledger listed"
  assert_contains "$(printf '%s\n' "$out" | grep '^claude/opus ship')" "4* 10m 1h00m n/a 1 0 2 1 1" "claude/opus ship row"
  assert_contains "$(printf '%s\n' "$out" | grep '^codex/default')" "1* 2h00m 2h00m n/a 0 1 0 0 1" "codex/default row"
  assert_contains "$out" "* fewer than 5 tasks" "small-sample footnote"
  assert_contains "$out" "1 task(s) with no dispatch record were left out." "undispatched footnote"
  pass "text: compact table with small groups flagged"
}

test_since_and_explicit_homes() {
  local out empty="$TMP_ROOT/empty"
  mkdir -p "$empty/state"
  : > "$empty/state/fleet-ledger.jsonl"
  out=$(scorecard --since 3000 --json) || fail "--since epoch exited nonzero"
  assert_equals '[["claude/opus","ship",2],["codex/default","ship",1]]' \
    "$(printf '%s\n' "$out" | jq -c '[.groups[] | [.profile, .kind, .tasks]]')" "--since keeps tasks dispatched at or after it"
  out=$(scorecard --since 2026-10-01) || fail "--since date exited nonzero"
  assert_contains "$out" "No dispatched tasks in range." "--since date filters out 1970 fixtures"
  out=$(scorecard --home "$MATE" --home "$empty" --json) || fail "--home exited nonzero"
  assert_equals "[\"$MATE\",\"8 records\",\"$empty\",\"empty\"]" \
    "$(printf '%s\n' "$out" | jq -c '[.homes[] | .label, .status]')" "--home replaces the default homes"
  assert_equals 3 "$(printf '%s\n' "$out" | jq '[.groups[].tasks] | add')" "only the named homes' tasks"
  pass "--since filters by dispatch time and --home replaces the default set"
}

test_reused_task_id_keeps_early_status_with_the_new_task() {
  local reuse="$TMP_ROOT/reuse" out
  mkdir -p "$reuse/state"
  {
    rec 1000 task.dispatched r-ship '"kind":"ship","project":"p","harness":"claude","model":"opus"'
    rec 1500 task.merged r-ship '"via":"pr","pr":"https://example.test/pr/9"'
    rec 1600 task.cleaned_up r-ship
    rec 2300 task.status r-ship '"state":"blocked","key":"k2","text":"needs a decision"'
    rec 2000 task.dispatched r-ship '"kind":"ship","project":"p","harness":"claude","model":"sonnet"'
    rec 1000 task.dispatched r-scout '"kind":"scout","project":"p","harness":"claude","model":"opus"'
    rec 1100 task.status r-scout '"state":"done","key":null,"text":"report written"'
    rec 1200 task.cleaned_up r-scout
    rec 2300 task.status r-scout '"state":"done","key":null,"text":"report written"'
    rec 2000 task.dispatched r-scout '"kind":"scout","project":"p","harness":"claude","model":"opus"'
  } > "$reuse/state/fleet-ledger.jsonl"
  out=$(scorecard --home "$reuse" --json) || fail "--home reuse exited nonzero"
  assert_equals '[1,0,1,0]' \
    "$(group "$out" claude/opus ship '[.tasks, .blocked, .landed, .open]')" "cleaned-up ship is not blocked by the next task's early status"
  assert_equals '[1,1,0,1]' \
    "$(group "$out" claude/sonnet ship '[.tasks, .blocked, .landed, .open]')" "reused ship id carries its early blocked status"
  assert_equals '[2,2,1,1]' \
    "$(group "$out" claude/opus scout '[.tasks, .ready_seconds.samples, .landed, .open]')" "reused scout id contributes a readiness sample"
  assert_equals 0 "$(printf '%s\n' "$out" | jq '.undispatched_tasks')" "no stray pending task"
  pass "reused task id: an early status belongs to the new dispatch, not the cleaned-up task"
}

test_help_usage_and_read_only() {
  local out before after code=0
  out=$("$SCORECARD" --help) || fail "--help exited nonzero"
  assert_contains "$out" "Advisory" "help says advisory"
  "$SCORECARD" --bogus >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "unknown option"
  code=0
  scorecard --since yesterday >/dev/null 2>&1 || code=$?
  expect_code 2 "$code" "bad --since"
  before=$(cd "$TMP_ROOT" && find . -type f -exec cksum {} + | sort)
  scorecard >/dev/null || fail "scorecard runs"
  scorecard --json >/dev/null || fail "scorecard --json runs"
  after=$(cd "$TMP_ROOT" && find . -type f -exec cksum {} + | sort)
  assert_equals "$before" "$after" "homes unchanged after a run"
  pass "help says advisory, bad usage exits 2, and a run writes nothing"
}

make_homes
fm_test_run test_json_reports_every_group_from_every_default_home \
  test_text_table_is_compact_and_flags_small_groups \
  test_since_and_explicit_homes \
  test_reused_task_id_keeps_early_status_with_the_new_task \
  test_help_usage_and_read_only
