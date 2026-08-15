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
    '  check-ref-format) [ "${2:-}" != "refs/heads/bad..name" ]; exit ;;' \
    '  ls-remote)' \
    '    [ -n "${FM_FAKE_REMOTE_SHA:-}" ] || exit 97' \
    '    printf "%s\t%s\n" "$FM_FAKE_REMOTE_SHA" "$FM_FAKE_REMOTE_REF"' \
    '    [ "${FM_FAKE_REMOTE_DUPLICATE:-0}" != 1 ] || printf "%s\t%s\n" "$FM_FAKE_REMOTE_SHA" "$FM_FAKE_REMOTE_REF"' \
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

test_recycled_runtime_slot_refuses() {  # <backend>
  local backend=$1 home stale live shared window key prefix rc queue_before queue_after
  home=$(make_home "runtime-alias-$backend")
  stale="scout-stale-$backend"
  live="ship-live-$backend"
  shared="$home/copies/recycled-slot"
  window="${backend}-session:%17"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  mkdir -p "$shared"
  printf 'live lane owns these bytes\n' > "$shared/live-sentinel"
  write_scout "$home" "$stale" "$shared"
  printf 'backend=%s\n' "$backend" >> "$home/state/$stale.meta"
  awk -v window="$window" '
    /^window=/ { print "window=" window; next }
    { print }
  ' "$home/state/$stale.meta" > "$home/state/$stale.meta.next"
  mv -f "$home/state/$stale.meta.next" "$home/state/$stale.meta"
  fm_write_meta "$home/state/$live.meta" \
    "window=$window" \
    "endpoint_task_id=$live" \
    "worktree=$shared" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=ship" \
    "backend=$backend"
  for prefix in hash count stale stale-since paused wedge-escalations; do
    printf 'live %s state\n' "$prefix" > "$home/state/.$prefix-$key"
  done
  printf '1\t1\tstale\t%s\tstale: live lane wedged\n' "$window" > "$home/state/.wake-queue"

  set +e
  run_retire "$home" "$stale" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$backend recycled runtime slot was accepted"
  assert_grep "runtime slot is also recorded by $live" "$home/err" \
    "$backend refusal did not name the live lane sharing the runtime slot"
  assert_present "$home/state/$stale.meta" "$backend refusal removed the stale record"
  assert_present "$home/state/$live.meta" "$backend refusal removed the live record"
  for prefix in hash count stale stale-since paused wedge-escalations; do
    assert_content "$home/state/.$prefix-$key" "live $prefix state" \
      "$backend refusal changed the live lane's $prefix state"
  done
  assert_content "$home/copies/recycled-slot/live-sentinel" "live lane owns these bytes" \
    "$backend refusal touched the aliased live copy"
  queue_before=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append stale "$2" "stale: live lane still wedged"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$window" \
    || fail "$backend live lane could not append a future wedge notification"
  queue_after=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  [ "$queue_after" -eq $((queue_before + 1)) ] \
    || fail "$backend live lane's future wedge notification was muted"
  pass "$backend retirement refuses a recycled runtime slot and preserves live wedge detection"
}

test_recycled_runtime_slot_refuses_herdr() {
  test_recycled_runtime_slot_refuses herdr
}

test_recycled_runtime_slot_refuses_zellij() {
  test_recycled_runtime_slot_refuses zellij
}

test_recycled_runtime_slot_refuses_cmux() {
  test_recycled_runtime_slot_refuses cmux
}

test_retired_runtime_slot_can_be_reused() {  # <backend>
  local backend=$1 home stale live window
  home=$(make_home "runtime-reuse-$backend")
  stale="scout-retired-$backend"
  live="ship-reusing-$backend"
  window="${backend}-session:%23"
  write_scout "$home" "$stale" "$home/copies/missing"
  printf 'backend=%s\n' "$backend" >> "$home/state/$stale.meta"
  awk -v window="$window" '
    /^window=/ { print "window=" window; next }
    { print }
  ' "$home/state/$stale.meta" > "$home/state/$stale.meta.next"
  mv -f "$home/state/$stale.meta.next" "$home/state/$stale.meta"
  run_retire "$home" "$stale" --work-safety scout-report >/dev/null \
    || fail "$backend record could not retire before later slot reuse"
  fm_write_meta "$home/state/$live.meta" \
    "window=$window" "endpoint_task_id=$live" "kind=ship" "backend=$backend"
  : > "$home/state/.wake-queue"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append stale "$2" "stale: reused live slot wedged"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$window" \
    || fail "$backend reused live slot could not append a wedge notification"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] \
    || fail "$backend retirement marker permanently muted a later live slot occupant"
  pass "$backend retired slot can be reused later without muting the new live lane"
}

test_retired_runtime_slot_can_be_reused_herdr() {
  test_retired_runtime_slot_can_be_reused herdr
}

test_retired_runtime_slot_can_be_reused_zellij() {
  test_retired_runtime_slot_can_be_reused zellij
}

test_retired_runtime_slot_can_be_reused_cmux() {
  test_retired_runtime_slot_can_be_reused cmux
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

test_kind_and_remote_attestation_guards() {
  local home id sha rc filtered
  sha=0123456789abcdef0123456789abcdef01234567

  home=$(make_home scout-kind)
  id=ship-with-report
  write_scout "$home" "$id" "$home/copies/missing"
  filtered="$home/state/$id.meta.filtered"
  awk '{ sub(/^kind=scout$/, "kind=ship"); print }' "$home/state/$id.meta" > "$filtered"
  mv -f "$filtered" "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "scout-report accepted a ship record"
  assert_grep "scout-report safety requires kind=scout" "$home/err" \
    "scout kind refusal was not concrete"

  home=$(make_home remote-kind)
  id=scout-with-remote-proof
  write_scout "$home" "$id" "$home/copies/missing"
  printf 'record_retire_work_head=%s\nrecord_retire_worktree_clean=1\n' "$sha" \
    >> "$home/state/$id.meta"
  set +e
  FM_FAKE_REMOTE_SHA=$sha FM_FAKE_REMOTE_REF=refs/heads/main \
    run_retire "$home" "$id" --work-safety remote-ref \
      --remote-url https://github.com/example/sample.git --remote-ref refs/heads/main \
      > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "remote-ref accepted a scout record"
  assert_grep "remote-ref safety requires kind=ship" "$home/err" \
    "remote kind refusal was not concrete"

  home=$(make_home malformed-head)
  id=ship-malformed-head
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=0123456" "record_retire_worktree_clean=1"
  set +e
  run_retire "$home" "$id" --work-safety remote-ref \
    --remote-url https://github.com/example/sample.git --remote-ref refs/heads/main \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "abbreviated work head was accepted"
  assert_grep "not a full lowercase commit id" "$home/err" \
    "work-head format refusal was not concrete"

  home=$(make_home dirty-attestation)
  id=ship-dirty-attestation
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=$sha" "record_retire_worktree_clean=0"
  set +e
  run_retire "$home" "$id" --work-safety remote-ref \
    --remote-url https://github.com/example/sample.git --remote-ref refs/heads/main \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dirty worktree attestation was accepted"
  assert_grep "record_retire_worktree_clean must equal 1" "$home/err" \
    "clean-attestation refusal was not concrete"

  pass "work-safety modes enforce record kind, full head, and clean attestation"
}

test_remote_ref_shape_and_cardinality_guards() {
  local home id sha rc
  sha=0123456789abcdef0123456789abcdef01234567
  home=$(make_home bad-ref)
  id=ship-bad-ref
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=$sha" "record_retire_worktree_clean=1"
  set +e
  run_retire "$home" "$id" --work-safety remote-ref \
    --remote-url https://github.com/example/sample.git --remote-ref refs/heads/bad..name \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid full ref name was accepted"
  assert_grep "not a valid full ref name" "$home/err" "invalid-ref refusal was not concrete"

  home=$(make_home duplicate-ref)
  id=ship-duplicate-ref
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=$sha" "record_retire_worktree_clean=1"
  set +e
  FM_FAKE_REMOTE_SHA=$sha FM_FAKE_REMOTE_REF=refs/heads/main FM_FAKE_REMOTE_DUPLICATE=1 \
    run_retire "$home" "$id" --work-safety remote-ref \
      --remote-url https://github.com/example/sample.git --remote-ref refs/heads/main \
      > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate remote matches were accepted"
  assert_grep "exactly one match" "$home/err" "remote-cardinality refusal was not concrete"
  pass "remote custody requires a valid full ref and exactly one advertised match"
}

test_identity_and_task_kind_guards() {
  local home id rc
  home=$(make_home mismatched-binding)
  id=scout-mismatched-binding
  write_scout "$home" "$id" "$home/copies/missing"
  awk '{ sub(/^endpoint_task_id=.*/, "endpoint_task_id=another-task"); print }' \
    "$home/state/$id.meta" > "$home/state/$id.meta.next"
  mv -f "$home/state/$id.meta.next" "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "single mismatched task binding was accepted"
  assert_grep "metadata belongs to task another-task" "$home/err" \
    "mismatched task-binding refusal was not concrete"

  home=$(make_home secondmate-kind)
  id=secondmate-record
  write_scout "$home" "$id" "$home/copies/missing"
  awk '{ sub(/^kind=scout$/, "kind=secondmate"); print }' \
    "$home/state/$id.meta" > "$home/state/$id.meta.next"
  mv -f "$home/state/$id.meta.next" "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "secondmate record was accepted"
  assert_grep "secondmate homes require the dedicated teardown path" "$home/err" \
    "secondmate refusal was not concrete"
  pass "record retirement enforces exact task identity and excludes secondmates"
}

test_metadata_busy_and_quarantine_guards() {
  local home id outside rc
  home=$(make_home hardlinked-meta)
  id=scout-hardlinked-meta
  write_scout "$home" "$id" "$home/copies/missing"
  ln "$home/state/$id.meta" "$home/outside-meta-link"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "hardlinked metadata was accepted"
  assert_grep "metadata is not a regular single-link" "$home/err" \
    "metadata-link refusal was not concrete"

  home=$(make_home busy-writer-lock)
  id=scout-busy-writer
  write_scout "$home" "$id" "$home/copies/missing"
  mkdir "$home/state/$id.busy-state.lock"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "busy-state writer lock was ignored"
  assert_grep "busy-state writer lock exists" "$home/err" \
    "busy-writer refusal was not concrete"

  home=$(make_home unsafe-quarantine)
  id=scout-unsafe-quarantine
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-quarantine"
  printf 'outside bytes\n' > "$outside"
  mkdir -p "$home/state/.pr-check-quarantine"
  ln -s "$outside" "$home/state/.pr-check-quarantine/$id.legacy"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe quarantine entry was accepted"
  assert_grep "unsafe task quarantine entry" "$home/err" \
    "quarantine refusal was not concrete"
  assert_content "$outside" "outside bytes" "quarantine refusal touched the symlink target"
  pass "metadata, busy-writer, and quarantine artifacts fail closed"
}

test_task_set_and_directory_guards() {
  local home id rc real_state
  home=$(make_home task-set-lock)
  id=scout-task-set-lock
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  PATH="$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=1 \
    FM_COMMAND_LOG="$home/commands.log" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      . "$1"
      lock=$(fm_task_set_lock_path "$FM_STATE_OVERRIDE") || exit 80
      fm_lock_acquire_wait "$lock" || exit 81
      "$2" "$3" --work-safety scout-report
      rc=$?
      fm_lock_release "$lock"
      exit "$rc"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$RETIRE" "$id" > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "task-set lifecycle lock was ignored"
  assert_grep "task set is changing" "$home/err" "task-set lock refusal was not concrete"
  assert_present "$home/state/$id.meta" "task-set lock refusal removed metadata"

  home=$(make_home control-lock)
  id=scout-control-lock
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  PATH="$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=1 \
    FM_COMMAND_LOG="$home/commands.log" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      . "$1"
      lock="$FM_STATE_OVERRIDE/.control-$3.lock"
      fm_lock_acquire_wait "$lock" || exit 80
      "$2" "$3" --work-safety scout-report
      rc=$?
      fm_lock_release "$lock"
      exit "$rc"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$RETIRE" "$id" > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "task lifecycle control lock was ignored"
  assert_grep "another lifecycle action is already running" "$home/err" \
    "control-lock refusal was not concrete"
  assert_present "$home/state/$id.meta" "control-lock refusal removed metadata"

  home=$(make_home unsafe-state-dir)
  id=scout-unsafe-state-dir
  write_scout "$home" "$id" "$home/copies/missing"
  real_state="$home/state-real"
  mv "$home/state" "$real_state"
  ln -s "$real_state" "$home/state"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked state directory was accepted"
  assert_grep "state directory is absent or unsafe" "$home/err" \
    "state-directory refusal was not concrete"
  assert_present "$real_state/$id.meta" "state-directory refusal removed metadata"
  pass "task-set and state-directory boundaries refuse before mutation"
}

test_task_id_guard() {
  local home rc
  home=$(make_home invalid-task-id)
  set +e
  run_retire "$home" ../escape --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "invalid task id did not stop at usage validation (rc=$rc)"
  assert_absent "$home/state/.record-retired-../escape" "invalid task id published a marker"
  pass "task ids must be privacy-safe slugs before any path is composed"
}

test_marker_integrity_and_fail_open_guards() {
  local home id digest rc before after outside
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  home=$(make_home invalid-regular-marker)
  id=scout-invalid-regular-marker
  write_scout "$home" "$id" "$home/copies/missing"
  printf 'schema=fm-record-retired.v1\ntask_id=%s\nwindow=firstmate:fm-%s\nmeta_sha256=bad\n' \
    "$id" "$id" > "$home/state/.record-retired-$id"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid regular retirement marker was accepted"
  assert_grep "existing record-retirement marker is invalid" "$home/err" \
    "regular marker refusal was not concrete"

  home=$(make_home symlink-marker-mute)
  id='live-symlink-marker'
  outside="$home/outside-valid-marker"
  printf 'schema=fm-record-retired.v1\ntask_id=%s\nwindow=firstmate:fm-%s\nmeta_sha256=%s\n' \
    "$id" "$id" "$digest" > "$outside"
  ln -s "$outside" "$home/state/.record-retired-$id"
  : > "$home/state/.wake-queue"
  before=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append signal "$2.status" "signal: live"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$id" || fail "symlink-marker wake append failed"
  after=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  [ "$after" -eq $((before + 1)) ] || fail "symlink marker muted a live task"

  home=$(make_home foreign-marker-mute)
  id='live-foreign-marker'
  printf 'schema=fm-record-retired.v1\ntask_id=another-task\nwindow=firstmate:fm-%s\nmeta_sha256=%s\n' \
    "$id" "$digest" > "$home/state/.record-retired-$id"
  : > "$home/state/.wake-queue"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append signal "$2.status" "signal: live"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$id" || fail "foreign-marker wake append failed"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] \
    || fail "foreign task marker muted a live task"

  home=$(make_home spawn-invalid-marker)
  id=fresh-incarnation
  printf 'not a marker\n' > "$home/state/.record-retired-$id"
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_record_retire_marker_clear_for_spawn "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$id" > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fresh incarnation accepted an invalid inherited marker"
  assert_grep "invalid record-retirement marker" "$home/err" \
    "fresh-incarnation marker refusal was not concrete"
  assert_present "$home/state/.record-retired-$id" "spawn guard removed an invalid marker"
  pass "marker format, link identity, task binding, and fresh-spawn validation fail open or refuse"
}

test_partial_wake_library_fails_open() {
  local home id rc
  home=$(make_home partial-wake-library)
  id='live-with-partial-bin'
  mkdir -p "$home/partial-bin"
  cp "$ROOT/bin/fm-wake-lib.sh" "$home/partial-bin/fm-wake-lib.sh"
  : > "$home/state/.wake-queue"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append signal "$2.status" "signal: live"' _ \
    "$home/partial-bin/fm-wake-lib.sh" "$id" 2> "$home/partial.err" \
    || fail "partial wake library aborted without retirement support"
  [ ! -s "$home/partial.err" ] \
    || fail "partial wake library emitted a missing-dependency error: $(cat "$home/partial.err")"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] \
    || fail "partial wake library muted a live task"
  printf 'not a marker\n' > "$home/state/.record-retired-fresh-task"
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_record_retire_marker_clear_for_spawn "$2" fresh-task' _ \
    "$home/partial-bin/fm-wake-lib.sh" "$home/state" > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "partial wake library cleared a marker without validation support"
  assert_present "$home/state/.record-retired-fresh-task" \
    "partial wake library removed an unvalidated marker"
  pass "a partial wake-library copy surfaces work and refuses unvalidated marker clearing"
}

test_partial_classify_library_fails_open() {
  local home id digest output
  home=$(make_home partial-classify-library)
  id='live-with-partial-classify'
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  mkdir -p "$home/partial-bin"
  cp "$ROOT/bin/fm-classify-lib.sh" "$home/partial-bin/fm-classify-lib.sh"
  printf 'needs-decision: live task needs review\n' > "$home/state/$id.status"
  printf 'schema=fm-record-retired.v1\ntask_id=%s\nwindow=firstmate:fm-%s\nmeta_sha256=%s\n' \
    "$id" "$id" "$digest" > "$home/state/.record-retired-$id"
  output=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; scan_captain_relevant_statuses "$2"' _ \
    "$home/partial-bin/fm-classify-lib.sh" "$home/state" 2> "$home/partial.err") \
    || fail "partial classify library aborted without retirement support"
  [ ! -s "$home/partial.err" ] \
    || fail "partial classify library emitted a missing-dependency error: $(cat "$home/partial.err")"
  printf '%s\n' "$output" | grep -q "$id" \
    || fail "partial classify library trusted a marker it could not validate"
  pass "a partial classify-library copy fails toward surfacing without marker support"
}

test_watcher_key_collision_refuses() {
  local home stale live shared rc
  home=$(make_home watcher-key-collision)
  stale=scout-a-dot-b
  live=ship-a-underscore-b
  shared="$home/copies/recycled-slot"
  mkdir -p "$shared"
  write_scout "$home" "$stale" "$shared"
  awk '{ sub(/^window=.*/, "window=firstmate:fm-a.b"); print }' \
    "$home/state/$stale.meta" > "$home/state/$stale.meta.next"
  mv -f "$home/state/$stale.meta.next" "$home/state/$stale.meta"
  fm_write_meta "$home/state/$live.meta" \
    "window=firstmate:fm-a_b" "endpoint_task_id=$live" "kind=ship"
  printf 'live watcher state\n' > "$home/state/.hash-firstmate_fm-a_b"
  set +e
  run_retire "$home" "$stale" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "colliding watcher-state key was accepted"
  assert_grep "watcher state key is also recorded by $live" "$home/err" \
    "watcher-key collision refusal was not concrete"
  assert_content "$home/state/.hash-firstmate_fm-a_b" "live watcher state" \
    "watcher-key collision changed live state"
  pass "nonidentical windows that collapse to one watcher key refuse safely"
}

run_test() {  # <test-function>
  [ -z "${FM_RECORD_RETIRE_TEST_ONLY:-}" ] \
    || [ "$FM_RECORD_RETIRE_TEST_ONLY" = "$1" ] \
    || return 0
  "$1"
}

run_test test_ordinary_retire
run_test test_aliased_copy_is_safe
run_test test_recycled_runtime_slot_refuses_herdr
run_test test_recycled_runtime_slot_refuses_zellij
run_test test_recycled_runtime_slot_refuses_cmux
run_test test_retired_runtime_slot_can_be_reused_herdr
run_test test_retired_runtime_slot_can_be_reused_zellij
run_test test_retired_runtime_slot_can_be_reused_cmux
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
run_test test_kind_and_remote_attestation_guards
run_test test_remote_ref_shape_and_cardinality_guards
run_test test_identity_and_task_kind_guards
run_test test_metadata_busy_and_quarantine_guards
run_test test_task_set_and_directory_guards
run_test test_task_id_guard
run_test test_marker_integrity_and_fail_open_guards
run_test test_partial_wake_library_fails_open
run_test test_partial_classify_library_fails_open
run_test test_watcher_key_collision_refuses
