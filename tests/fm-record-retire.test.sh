#!/usr/bin/env bash
# Behavioral coverage for state-only task-record retirement.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETIRE="$ROOT/bin/fm-record-retire.sh"
TMP_ROOT=$(fm_test_tmproot fm-record-retire)

assert_content() {  # <file> <expected> <message>
  local file=$1 expected=$2 message=$3 actual
  actual=$(cat "$file" 2>/dev/null) || fail "$message"
  [ "$actual" = "$expected" ] || fail "$message: got '$actual'"
}

write_fake_tools() {  # <home>
  local home=$1 fakebin tool
  fakebin=$(fm_fakebin "$home")
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-} ${2:-}" in' \
    '  "hold --help") printf "%s\n" "--kind captain"; exit 0 ;;' \
    'esac' \
    'exit 97' > "$fakebin/tasks-axi"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "git %s\n" "$*" >> "${FM_COMMAND_LOG:?}"' \
    'case "${1:-}" in' \
    '  check-ref-format) exit 0 ;;' \
    '  ls-remote)' \
    '    [ -n "${FM_FAKE_REMOTE_SHA:-}" ] || exit 97' \
    '    printf "%s\t%s\n" "$FM_FAKE_REMOTE_SHA" "$FM_FAKE_REMOTE_REF"' \
    '    exit 0 ;;' \
    'esac' \
    'exit 97' > "$fakebin/git"
  for tool in treehouse tmux gh gh-axi no-mistakes lsof; do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      "printf '$tool %s\\n' \"\$*\" >> \"\${FM_COMMAND_LOG:?}\"" \
      'exit 97' > "$fakebin/$tool"
  done
  chmod +x "$fakebin"/*
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/copies"
  : > "$home/commands.log"
  write_fake_tools "$home"
  printf '%s\n' "$home"
}

write_scout() {  # <home> <id> <worktree>
  local home=$1 id=$2 worktree=$3
  mkdir -p "$home/data/$id"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$worktree" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "decisions_reviewed=1" \
    "decision_keys="
  printf '# %s report\n\nThe durable scout result is complete.\n' "$id" \
    > "$home/data/$id/report.md"
  printf 'done: report complete\n' > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
}

run_retire() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=1 \
    FM_COMMAND_LOG="$home/commands.log" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$RETIRE" "$@"
}

assert_retired() {  # <home> <id>
  local home=$1 id=$2
  assert_absent "$home/state/$id.meta" "retirement left task metadata"
  assert_absent "$home/state/$id.status" "retirement left task status"
  assert_absent "$home/state/$id.turn-ended" "retirement left task turn-end state"
  assert_present "$home/state/.record-retired-$id" "retirement marker is absent"
  assert_present "$home/data/$id/report.md" "retirement removed the durable report"
}

test_ordinary_retire() {
  local home id queue_before queue_after
  home=$(make_home ordinary)
  id=scout-ordinary
  mkdir -p "$home/copies/task"
  printf 'copy bytes remain\n' > "$home/copies/task/sentinel"
  write_scout "$home" "$id" "$home/copies/task"
  printf '1\t1\tsignal\t%s.status\tsignal: task\n' "$id" > "$home/state/.wake-queue"
  printf '1\t2\theartbeat\theartbeat\theartbeat\n' >> "$home/state/.wake-queue"

  run_retire "$home" "$id" --work-safety scout-report >/dev/null \
    || fail "ordinary record retirement refused"
  assert_retired "$home" "$id"
  assert_content "$home/copies/task/sentinel" "copy bytes remain" \
    "ordinary retirement touched the recorded copy"
  assert_content "$home/state/.wake-queue" $'1\t2\theartbeat\theartbeat\theartbeat' \
    "ordinary retirement did not remove only this task's queued wake"
  [ ! -s "$home/commands.log" ] \
    || fail "ordinary retirement invoked a copy, process, backend, or forge command: $(cat "$home/commands.log")"

  printf 'failed: late old-agent write\n' > "$home/state/$id.status"
  queue_before=$(sha256sum "$home/state/.wake-queue" 2>/dev/null || shasum -a 256 "$home/state/.wake-queue")
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append signal "$2.status" "late"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$id" || fail "late-wake mute call failed"
  queue_after=$(sha256sum "$home/state/.wake-queue" 2>/dev/null || shasum -a 256 "$home/state/.wake-queue")
  [ "$queue_before" = "$queue_after" ] || fail "late old-agent write recreated a queued wake"
  late=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; scan_captain_relevant_statuses "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state")
  [ -z "$late" ] || fail "late old-agent status re-entered captain-relevant supervision"
  pass "record retirement removes ordinary state and permanently mutes the untouched old agent"
}

test_aliased_copy_is_safe() {
  local home stale live shared
  home=$(make_home alias)
  stale=scout-stale
  live=scout-live
  shared="$home/copies/recycled-slot"
  mkdir -p "$shared"
  printf 'live lane owns these bytes\n' > "$shared/live-sentinel"
  write_scout "$home" "$stale" "$shared"
  fm_write_meta "$home/state/$live.meta" \
    "window=firstmate:fm-$live" \
    "endpoint_task_id=$live" \
    "worktree=$shared" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship"

  run_retire "$home" "$stale" --work-safety scout-report >/dev/null \
    || fail "aliased-copy record retirement refused"
  assert_retired "$home" "$stale"
  assert_present "$home/state/$live.meta" "aliased-copy retirement removed the live lane's record"
  assert_content "$shared/live-sentinel" "live lane owns these bytes" \
    "aliased-copy retirement touched the recycled live copy"
  [ ! -s "$home/commands.log" ] \
    || fail "aliased-copy retirement invoked an external lifecycle command"
  pass "record retirement is safe when the recorded copy is aliased by another live lane"
}

test_unprovable_safety_refuses_without_mutation() {
  local home id rc before
  home=$(make_home unprovable)
  id=scout-no-report
  mkdir -p "$home/copies/task"
  write_scout "$home" "$id" "$home/copies/task"
  rm -f "$home/data/$id/report.md"
  before=$(shasum -a 256 "$home/state/$id.meta" "$home/state/$id.status")
  set +e
  run_retire "$home" "$id" --work-safety scout-report \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unprovable scout safety was accepted"
  assert_grep "scout report is absent" "$home/err" "unprovable refusal did not name the missing report"
  [ "$before" = "$(shasum -a 256 "$home/state/$id.meta" "$home/state/$id.status")" ] \
    || fail "unprovable refusal changed task state"
  assert_absent "$home/state/.record-retired-$id" "unprovable refusal published a retirement marker"
  pass "record retirement refuses when off-copy work safety cannot be proved"
}

test_no_copy_touched_even_when_copy_is_hostile() {
  local home id rc
  home=$(make_home hostile-copy)
  id=scout-hostile-copy
  write_scout "$home" "$id" "$home/copies/does-not-exist/and-must-not-be-resolved"
  run_retire "$home" "$id" --work-safety scout-report >/dev/null \
    || fail "retirement tried to require or resolve the recorded copy"
  assert_retired "$home" "$id"
  [ ! -e "$home/copies/does-not-exist" ] \
    || fail "retirement created or opened the hostile recorded-copy path"
  [ ! -s "$home/commands.log" ] \
    || fail "retirement invoked a forbidden external command: $(cat "$home/commands.log")"
  pass "record retirement never resolves or touches the recorded copy"
}

test_ship_requires_clean_remote_tip_proof() {
  local home id sha rc
  home=$(make_home remote-proof)
  id=ship-custodied
  sha=0123456789abcdef0123456789abcdef01234567
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/copies/missing" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "record_retire_work_head=$sha" \
    "record_retire_worktree_clean=1"
  FM_FAKE_REMOTE_SHA=$sha FM_FAKE_REMOTE_REF=refs/pull/18/head \
    run_retire "$home" "$id" --work-safety remote-ref \
      --remote-url https://github.com/example/sample.git --remote-ref refs/pull/18/head >/dev/null \
    || fail "exact remote-tip custody proof was refused"
  assert_absent "$home/state/$id.meta" "remote-ref retirement left ship metadata"
  assert_present "$home/state/.record-retired-$id" "remote-ref retirement marker is absent"

  home=$(make_home remote-mismatch)
  id=ship-not-custodied
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/copies/missing" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "record_retire_work_head=$sha" \
    "record_retire_worktree_clean=1"
  set +e
  FM_FAKE_REMOTE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FM_FAKE_REMOTE_REF=refs/heads/main \
    run_retire "$home" "$id" --work-safety remote-ref \
      --remote-url https://github.com/example/sample.git --remote-ref refs/heads/main \
      > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mismatched remote tip was accepted"
  assert_grep "not attested work head" "$home/err" "remote mismatch refusal did not name exact inequality"
  assert_present "$home/state/$id.meta" "remote mismatch removed ship metadata"

  home=$(make_home local-remote)
  id=ship-local-only
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/copies/missing" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "record_retire_work_head=$sha" \
    "record_retire_worktree_clean=1"
  set +e
  FM_FAKE_REMOTE_SHA=$sha FM_FAKE_REMOTE_REF=refs/heads/main \
    run_retire "$home" "$id" --work-safety remote-ref \
      --remote-url https://localhost/sample.git --remote-ref refs/heads/main \
      > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "local remote was accepted as off-disk custody"
  assert_grep "explicit GitHub" "$home/err" "local remote refusal did not name the custody boundary"
  [ ! -s "$home/commands.log" ] || fail "local remote refusal contacted git"
  assert_present "$home/state/$id.meta" "local remote refusal removed ship metadata"
  pass "ship retirement requires a clean attested head at the exact remote tip"
}

test_unsafe_state_artifact_refuses() {
  local home id outside rc
  home=$(make_home unsafe-artifact)
  id=scout-unsafe-state
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-runtime-state"
  printf 'outside bytes\n' > "$outside"
  ln -s "$outside" "$home/state/$id.pi-ext.ts"
  set +e
  run_retire "$home" "$id" --work-safety scout-report \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe task-state symlink was accepted"
  assert_grep "unsafe task-state artifact" "$home/err" "unsafe artifact refusal was not concrete"
  assert_content "$outside" "outside bytes" "unsafe artifact refusal touched the symlink target"
  assert_present "$home/state/$id.meta" "unsafe artifact refusal removed metadata"
  pass "record retirement refuses unsafe state paths before removal"
}

test_explicit_safety_mode_is_mandatory() {
  local home id rc
  home=$(make_home explicit-mode)
  id=scout-explicit
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  run_retire "$home" "$id" > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing work-safety mode silently defaulted"
  assert_grep "--work-safety is required" "$home/err" "missing-mode refusal was not concrete"
  assert_present "$home/state/$id.meta" "missing-mode refusal removed metadata"
  pass "record retirement never defaults the unlanded-work proof"
}

test_task_binding_is_exact() {
  local home id rc
  home=$(make_home binding)
  id=scout-binding
  write_scout "$home" "$id" "$home/copies/missing"
  printf 'endpoint_task_id=another-lane\n' >> "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "ambiguous task binding was accepted"
  assert_grep "exactly one nonempty endpoint_task_id" "$home/err" \
    "task-binding refusal did not name the exact requirement"
  assert_present "$home/state/$id.meta" "task-binding refusal removed metadata"
  pass "record retirement requires one exact task binding"
}

test_decision_gate_is_mandatory_for_scouts() {
  local home id rc filtered
  home=$(make_home decision-gate)
  id=scout-unreviewed
  write_scout "$home" "$id" "$home/copies/missing"
  filtered="$home/state/$id.meta.filtered"
  awk '$0 != "decisions_reviewed=1"' "$home/state/$id.meta" > "$filtered"
  mv -f "$filtered" "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreviewed scout decision inventory was accepted"
  assert_grep "unresolved-decision completion gate" "$home/err" \
    "decision-gate refusal did not name the missing requirement"
  assert_present "$home/state/$id.meta" "decision-gate refusal removed metadata"
  pass "record retirement preserves the scout decision-hold completion gate"
}

test_busy_incarnation_must_be_bound() {
  local home id rc
  home=$(make_home busy-binding)
  id=scout-busy-unbound
  write_scout "$home" "$id" "$home/copies/missing"
  printf 'v1 gen=g1 seq=1 state=idle source=test event=test ts=1\n' \
    > "$home/state/$id.busy-state"
  printf 'g1\n' > "$home/state/$id.busy-gen"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unbound busy incarnation was retired"
  assert_grep "busy-state exists but metadata has no exact busy_gen" "$home/err" \
    "busy-incarnation refusal did not name the missing binding"
  assert_present "$home/state/$id.busy-state" "busy-incarnation refusal removed busy state"
  assert_present "$home/state/$id.meta" "busy-incarnation refusal removed metadata"
  pass "record retirement refuses an unbound busy-state incarnation"
}

test_runtime_binding_must_be_settled() {
  local home id rc
  home=$(make_home runtime-binding)
  id=scout-runtime-bound
  write_scout "$home" "$id" "$home/copies/missing"
  mkdir -p "$home/state/terminal-outcomes"
  printf 'schema=fm-terminal-outcome.v1\ntask_id=%s\n' "$id" \
    > "$home/state/terminal-outcomes/exact.pending"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "task-owned runtime binding was silently orphaned"
  assert_grep "still owns runtime binding" "$home/err" \
    "runtime-binding refusal did not name the exact record"
  assert_present "$home/state/$id.meta" "runtime-binding refusal removed metadata"
  pass "record retirement refuses task-owned runtime bindings"
}

test_public_followup_presence_refuses() {
  local home id rc
  home=$(make_home public-followup)
  id=scout-public-bound
  write_scout "$home" "$id" "$home/copies/missing"
  mkdir -p "$home/state/public-followup/registry"
  printf 'obligation_id=other\n' > "$home/state/public-followup/registry/other"
  set +e
  FMX_PAIRING_TOKEN=test-token \
    run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "active public-followup registrations were ignored"
  assert_grep "public-followup registrations exist" "$home/err" \
    "public-followup refusal did not name the unsettled subsystem"
  assert_present "$home/state/$id.meta" "public-followup refusal removed metadata"
  pass "record retirement refuses while public-followup state is active"
}

test_invalid_retirement_marker_refuses_before_mutation() {
  local home id outside rc
  home=$(make_home invalid-marker)
  id=scout-invalid-marker
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-marker"
  printf 'not a retirement marker\n' > "$outside"
  ln -s "$outside" "$home/state/.record-retired-$id"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe preexisting retirement marker was accepted"
  assert_grep "existing record-retirement marker is unsafe" "$home/err" \
    "marker refusal did not name the unsafe record"
  assert_present "$home/state/$id.status" "marker refusal removed status before refusing"
  assert_present "$home/state/$id.meta" "marker refusal removed metadata"
  assert_content "$outside" "not a retirement marker" "marker refusal touched the symlink target"
  pass "record retirement validates its mute marker before any retirement mutation"
}

run_test() {  # <test-function>
  [ -z "${FM_RECORD_RETIRE_TEST_ONLY:-}" ] \
    || [ "$FM_RECORD_RETIRE_TEST_ONLY" = "$1" ] \
    || return 0
  "$1"
}

run_test test_ordinary_retire
run_test test_aliased_copy_is_safe
run_test test_unprovable_safety_refuses_without_mutation
run_test test_no_copy_touched_even_when_copy_is_hostile
run_test test_ship_requires_clean_remote_tip_proof
run_test test_unsafe_state_artifact_refuses
run_test test_explicit_safety_mode_is_mandatory
run_test test_task_binding_is_exact
run_test test_decision_gate_is_mandatory_for_scouts
run_test test_busy_incarnation_must_be_bound
run_test test_runtime_binding_must_be_settled
run_test test_public_followup_presence_refuses
run_test test_invalid_retirement_marker_refuses_before_mutation
