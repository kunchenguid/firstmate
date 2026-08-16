#!/usr/bin/env bash
# Behavioral coverage for state-only task-record retirement.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETIRE="$ROOT/bin/fm-record-retire.sh"
RETIRE_LIB="$ROOT/bin/fm-record-retire-lib.sh"
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

write_retirement_marker() {  # <state> <id> <window> <digest> [<schema>]
  local state=$1 id=$2 window=$3 digest=$4 schema=${5:-fm-record-retired.v1}
  printf 'schema=%s\ntask_id=%s\nwindow=%s\nmeta_sha256=%s\n' \
    "$schema" "$id" "$window" "$digest" > "$state/.record-retired-$id"
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
  local home id window key prefix queue_before queue_after
  home=$(make_home ordinary)
  id=scout-ordinary
  window="firstmate:fm-$id"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  mkdir -p "$home/copies/task"
  printf 'copy bytes remain\n' > "$home/copies/task/sentinel"
  write_scout "$home" "$id" "$home/copies/task"
  {
    printf '1\t1\tsignal\t%s.status\tsignal: task\n' "$id"
    printf '1\t2\tstale\t%s\tstale: task\n' "$window"
    printf '1\t3\tcheck\t%s/%s.check.sh\tcheck: task\n' "$home/state" "$id"
    printf '1\t4\tsignal\t%s.status\n' "$id"
    printf '1\t5\theartbeat\theartbeat\theartbeat\n'
  } > "$home/state/.wake-queue"
  for prefix in hash count stale stale-since paused paused-rechecked paused-resurfaced wedge-escalations; do
    printf 'retired %s state\n' "$prefix" > "$home/state/.$prefix-$key"
  done

  run_retire "$home" "$id" --work-safety scout-report >/dev/null \
    || fail "ordinary record retirement refused"
  assert_retired "$home" "$id"
  assert_content "$home/copies/task/sentinel" "copy bytes remain" \
    "ordinary retirement touched the recorded copy"
  assert_content "$home/state/.wake-queue" \
    $'1\t4\tsignal\tscout-ordinary.status\n1\t5\theartbeat\theartbeat\theartbeat' \
    "ordinary retirement did not remove only this task's queued wake"
  for prefix in hash count stale stale-since paused paused-rechecked paused-resurfaced wedge-escalations; do
    assert_absent "$home/state/.$prefix-$key" \
      "ordinary retirement left collapsed runtime-slot state for $prefix"
  done
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

test_marker_requires_exact_line_count() {
  local home id digest
  home=$(make_home marker-line-count)
  id=retired-extra-line
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" "firstmate:fm-$id" "$digest"
  printf 'unexpected=fifth-line\n' >> "$home/state/.record-retired-$id"
  if bash -c '. "$1"; fm_record_retire_marker_valid "$2" "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "five-line retirement marker was accepted"
  fi
  pass "retirement markers require exactly four lines"
}

test_marker_requires_exact_schema() {
  local home id digest
  home=$(make_home marker-schema)
  id=retired-wrong-schema
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" "firstmate:fm-$id" "$digest" wrong-schema
  if bash -c '. "$1"; fm_record_retire_marker_valid "$2" "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "wrong-schema retirement marker was accepted"
  fi
  pass "retirement markers require the exact schema"
}

test_marker_requires_nonempty_window() {
  local home id digest
  home=$(make_home marker-empty-window)
  id=retired-empty-window
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" '' "$digest"
  if bash -c '. "$1"; fm_record_retire_marker_valid "$2" "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "empty-window retirement marker was accepted"
  fi
  pass "retirement markers require a nonempty runtime window"
}

test_marker_rejects_control_window() {
  local home id digest
  home=$(make_home marker-control-window)
  id=retired-control-window
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" $'firstmate:\tfm-task' "$digest"
  if bash -c '. "$1"; fm_record_retire_marker_valid "$2" "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "control-character retirement window was accepted"
  fi
  pass "retirement markers reject control characters in runtime windows"
}

test_marker_publish_rejects_invalid_id() {
  local home digest
  home=$(make_home publish-invalid-id)
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  if bash -c '. "$1"; fm_record_retire_marker_publish "$2" .hidden window "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$digest"; then
    fail "marker publication accepted an invalid task id"
  fi
  assert_absent "$home/state/.record-retired-.hidden" \
    "invalid task id published a retirement marker"
  pass "marker publication validates the task id"
}

test_marker_publish_rejects_empty_window() {
  local home id digest
  home=$(make_home publish-empty-window)
  id=retired-publish-empty-window
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  if bash -c '. "$1"; fm_record_retire_marker_publish "$2" "$3" "" "$4"' _ \
    "$RETIRE_LIB" "$home/state" "$id" "$digest"; then
    fail "marker publication accepted an empty runtime window"
  fi
  assert_absent "$home/state/.record-retired-$id" \
    "empty runtime window published a retirement marker"
  pass "marker publication requires a nonempty runtime window"
}

test_marker_publish_rejects_control_window() {
  local home id digest window
  home=$(make_home publish-control-window)
  id=retired-publish-control-window
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  window=$'firstmate:\tfm-task'
  if bash -c '. "$1"; fm_record_retire_marker_publish "$2" "$3" "$4" "$5"' _ \
    "$RETIRE_LIB" "$home/state" "$id" "$window" "$digest"; then
    fail "marker publication accepted a control-character runtime window"
  fi
  assert_absent "$home/state/.record-retired-$id" \
    "control-character runtime window published a retirement marker"
  pass "marker publication rejects control characters in runtime windows"
}

test_marker_publish_rejects_invalid_digest() {
  local home id
  home=$(make_home publish-invalid-digest)
  id=retired-publish-invalid-digest
  if bash -c '. "$1"; fm_record_retire_marker_publish "$2" "$3" window bad' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "marker publication accepted a malformed metadata digest"
  fi
  assert_absent "$home/state/.record-retired-$id" \
    "malformed metadata digest published a retirement marker"
  pass "marker publication requires a full lowercase SHA-256 digest"
}

test_marker_republish_requires_same_window() {
  local home id digest marker_before
  home=$(make_home republish-window)
  id=retired-republish-window
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" original-window "$digest"
  marker_before=$(shasum -a 256 "$home/state/.record-retired-$id")
  if bash -c '. "$1"; fm_record_retire_marker_publish "$2" "$3" changed-window "$4"' _ \
    "$RETIRE_LIB" "$home/state" "$id" "$digest"; then
    fail "marker republish accepted a different runtime window"
  fi
  [ "$marker_before" = "$(shasum -a 256 "$home/state/.record-retired-$id")" ] \
    || fail "different-window republish changed the existing marker"
  pass "marker republish requires the same runtime window"
}

test_marker_republish_requires_same_digest() {
  local home id original changed marker_before
  home=$(make_home republish-digest)
  id=retired-republish-digest
  original=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  changed=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  write_retirement_marker "$home/state" "$id" original-window "$original"
  marker_before=$(shasum -a 256 "$home/state/.record-retired-$id")
  if bash -c '. "$1"; fm_record_retire_marker_publish "$2" "$3" original-window "$4"' _ \
    "$RETIRE_LIB" "$home/state" "$id" "$changed"; then
    fail "marker republish accepted a different metadata digest"
  fi
  [ "$marker_before" = "$(shasum -a 256 "$home/state/.record-retired-$id")" ] \
    || fail "different-digest republish changed the existing marker"
  pass "marker republish requires the same metadata generation"
}

test_marker_publish_verifies_the_published_file() {
  local home id digest fakebin rc
  home=$(make_home publish-postverify)
  id=retired-publish-postverify
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fakebin="$home/noop-mv"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/mv"
  chmod +x "$fakebin/mv"
  set +e
  PATH="$fakebin:$PATH" bash -c \
    '. "$1"; fm_record_retire_marker_publish "$2" "$3" window "$4"' _ \
    "$RETIRE_LIB" "$home/state" "$id" "$digest"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "marker publication trusted a false-successful atomic move"
  assert_absent "$home/state/.record-retired-$id" \
    "false-successful atomic move unexpectedly published a marker"
  pass "marker publication verifies the exact file after atomic publication"
}

test_marker_clear_accepts_absent_marker() {
  local home
  home=$(make_home clear-absent-marker)
  bash -c '. "$1"; fm_record_retire_marker_clear_for_spawn "$2" fresh-task' _ \
    "$RETIRE_LIB" "$home/state" \
    || fail "fresh spawn refused when no retirement marker existed"
  pass "fresh spawn treats an absent retirement marker as already clear"
}

test_marker_clear_removes_valid_marker_and_restores_wakes() {
  local home id digest
  home=$(make_home clear-valid-marker)
  id=fresh-reused-task
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" "firstmate:fm-$id" "$digest"
  bash -c '. "$1"; fm_record_retire_marker_clear_for_spawn "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$id" \
    || fail "fresh spawn could not clear a valid inherited retirement marker"
  assert_absent "$home/state/.record-retired-$id" \
    "fresh spawn left a valid retirement marker in place"
  : > "$home/state/.wake-queue"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append signal "$2.status" "signal: fresh"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$id" \
    || fail "fresh incarnation could not append a wake after marker clearing"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 1 ] \
    || fail "fresh incarnation remained muted after valid marker clearing"
  pass "fresh spawn removes a valid marker and restores the new incarnation's wakes"
}

test_marker_does_not_mute_unrecognized_signal_key() {
  local home id digest
  home=$(make_home signal-key-scope)
  id=retired-plain-key
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" window "$digest"
  if bash -c '. "$1"; fm_record_retire_wake_muted "$2" signal "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "retirement marker muted an unrecognized signal key"
  fi
  pass "retirement markers mute only status and turn-end signal keys"
}

test_marker_does_not_mute_foreign_check_path() {
  local home id digest foreign
  home=$(make_home foreign-check-path)
  id=retired-foreign-check
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  foreign="$home/foreign/$id.check.sh"
  mkdir -p "${foreign%/*}"
  write_retirement_marker "$home/state" "$id" window "$digest"
  if bash -c '. "$1"; fm_record_retire_wake_muted "$2" check "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$foreign"; then
    fail "retirement marker muted a check path outside its state home"
  fi
  pass "retirement markers mute only state-home check paths"
}

test_marker_never_mutes_stale_wake() {
  local home id digest
  home=$(make_home stale-key-scope)
  id=retired-slot
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" "$id:window" "$digest"
  if bash -c '. "$1"; fm_record_retire_wake_muted "$2" stale "$3:window"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "retirement marker muted a slot-keyed stale wake"
  fi
  pass "retirement markers never mute slot-keyed stale wakes"
}

test_marker_does_not_mute_unknown_wake_kind() {
  local home id digest
  home=$(make_home unknown-wake-kind)
  id=retired-unknown-kind
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" window "$digest"
  if bash -c '. "$1"; fm_record_retire_wake_muted "$2" heartbeat "$3.status"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "retirement marker muted an unknown wake kind"
  fi
  pass "retirement markers fail open for unknown wake kinds"
}

test_retired_marker_hides_full_open_decision_scan() {
  local home id digest output
  home=$(make_home classify-full-retired)
  id=retired-full-scan
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf 'needs-decision: held work\n' > "$home/state/$id.status"
  write_retirement_marker "$home/state" "$id" window "$digest"
  output=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; scan_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$home/state")
  [ -z "$output" ] || fail "full decision scan resurfaced a retired task"
  pass "full open-decision scans omit validly retired tasks"
}

test_retired_marker_hides_incremental_open_decision_scan() {
  local home id digest output
  home=$(make_home classify-incremental-retired)
  id=retired-incremental-scan
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf 'needs-decision: held work\n' > "$home/state/$id.status"
  write_retirement_marker "$home/state" "$id" window "$digest"
  output=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; scan_open_decisions_incremental "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state")
  [ -z "$output" ] || fail "incremental decision scan resurfaced a retired task"
  pass "incremental open-decision scans omit validly retired tasks"
}

test_retired_marker_hides_status_snapshot() {
  local home id digest output
  home=$(make_home classify-snapshot-retired)
  id=retired-status-snapshot
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf 'blocked: held work\n' > "$home/state/$id.status"
  write_retirement_marker "$home/state" "$id" window "$digest"
  output=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; status_presentation_snapshot "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state")
  [ -z "$output" ] || fail "status snapshot resurfaced a retired task"
  pass "status presentation snapshots omit validly retired tasks"
}

test_live_metadata_keeps_marker_consumers_audible() {
  local home id digest decisions snapshot queue
  home=$(make_home marker-with-live-metadata)
  id='live-after-marker-publication'
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf 'window=firstmate:fm-%s\nkind=ship\n' "$id" > "$home/state/$id.meta"
  printf 'needs-decision: [key=still-live] captain review remains open\n' \
    > "$home/state/$id.status"
  write_retirement_marker "$home/state" "$id" "firstmate:fm-$id" "$digest"
  : > "$home/state/.wake-queue"

  if bash -c '. "$1"; fm_record_retire_marker_active "$2" "$3"' _ \
    "$RETIRE_LIB" "$home/state" "$id"; then
    fail "a retirement marker became active while canonical metadata still existed"
  fi
  decisions=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; scan_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$home/state")
  printf '%s\n' "$decisions" | grep -q "$id" \
    || fail "full decision scan hid a live task after marker publication"
  snapshot=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; status_presentation_snapshot "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state")
  printf '%s\n' "$snapshot" | grep -q "$id" \
    || fail "status snapshot hid a live task after marker publication"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append check "$2" "check: still live"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/$id.check.sh" \
    || fail "live task check wake could not be appended"
  queue=$(cat "$home/state/.wake-queue")
  printf '%s\n' "$queue" | grep -q "$id.check.sh" \
    || fail "check wake was muted while canonical metadata still existed"
  pass "live metadata keeps full decisions, snapshots, and check wakes audible after marker publication"
}

test_surface_artifact_paths_are_producer_owned() {
  local home id window actual expected expected_path
  home=$(make_home producer-owned-surface-paths)
  id=task.a_b
  window='a:b:c/d/e.f.g'
  actual=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; fm_record_retire_artifact_paths "$2" "$3" "$4"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$id" "$window")
  expected=$(FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_signal_seen_path "$2" "$2/$3.status"
    printf "\n"
    fm_wake_signal_seen_path "$2" "$2/$3.turn-ended"
    printf "\n"
    fm_wake_hb_surfaced_path "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$id")
  while IFS= read -r expected_path; do
    [ -n "$expected_path" ] || continue
    printf '%s\n' "$actual" | grep -Fqx "$expected_path" \
      || fail "retirement surface-artifact inventory omitted producer path $expected_path"
  done <<EOF
$expected
EOF
  printf '%s\n' "$actual" | grep -q '/.seen-task_a_b_status$' \
    || fail "producer-owned status marker path did not collapse the dotted id"
  printf '%s\n' "$actual" | grep -q '/.seen-task_a_b_turn-ended$' \
    || fail "producer-owned turn-end marker path did not collapse the dotted id"
  printf '%s\n' "$actual" | grep -q '/.hb-surfaced-task_a_b$' \
    || fail "producer-owned heartbeat marker path did not collapse the dotted id"
  printf '%s\n' "$actual" | grep -q '/.hash-a_b_c_d_e_f_g$' \
    || fail "artifact inventory did not use the fully collapsed watcher key"
  printf '%s\n' "$actual" | grep -q '/.seen-task\.a_b_status$' \
    && fail "artifact inventory re-derived the raw dotted task id"
  pass "retirement obtains seen and heartbeat surface paths from their producers"
}

test_watcher_key_collapses_every_occurrence() {
  local actual collision
  actual=$(bash -c '. "$1"; fm_record_retire_watcher_state_key "$2"' _ \
    "$RETIRE_LIB" 'a:b:c/d/e.f.g')
  [ "$actual" = 'a_b_c_d_e_f_g' ] \
    || fail "watcher state key did not collapse every punctuation occurrence: $actual"
  collision=$(bash -c '. "$1"; fm_record_retire_window_collision "$2" "$3"' _ \
    "$RETIRE_LIB" 'a:b:c/d/e.f.g' 'a_b_c_d_e_f_g') \
    || fail "collapsed watcher-key collision was not detected"
  [ "$collision" = collapsed ] \
    || fail "collapsed watcher-key collision was misclassified: $collision"
  collision=$(bash -c '. "$1"; fm_record_retire_window_collision "$2" "$3"' _ \
    "$RETIRE_LIB" 'a_b_c_d_e_f_g' 'a:b:c/d/e.f.g') \
    || fail "reverse-direction collapsed watcher-key collision was not detected"
  [ "$collision" = collapsed ] \
    || fail "reverse-direction watcher-key collision was misclassified: $collision"
  collision=$(bash -c '. "$1"; fm_record_retire_window_collision "$2" "$3"' _ \
    "$RETIRE_LIB" 'same:window' 'same:window') \
    || fail "raw runtime-slot collision was not detected"
  [ "$collision" = raw ] || fail "raw runtime-slot collision was misclassified: $collision"
  if bash -c '. "$1"; fm_record_retire_window_collision "$2" "$3"' _ \
    "$RETIRE_LIB" 'different:one' 'different:two'; then
    fail "noncolliding runtime windows were classified as a collision"
  fi
  pass "watcher keys fully collapse and classify raw and collapsed runtime-slot collisions"
}

test_muted_wake_releases_queue_lock() {
  local home id digest
  home=$(make_home muted-wake-lock-release)
  id=retired-lock-release
  digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  write_retirement_marker "$home/state" "$id" "firstmate:fm-$id" "$digest"
  : > "$home/state/.wake-queue"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append signal "$2.status" "signal: late"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$id" || fail "muted wake append failed"
  [ ! -e "$home/state/.wake-queue.lock" ] && [ ! -L "$home/state/.wake-queue.lock" ] \
    || fail "muted wake returned while still owning the queue lock"
  [ ! -s "$home/state/.wake-queue" ] || fail "muted wake was appended to the queue"
  pass "muted wakes release the queue lock before returning"
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

test_unsupported_safety_mode_refuses() {
  local home id rc
  home=$(make_home unsupported-safety)
  id=scout-unsupported-safety
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  run_retire "$home" "$id" --work-safety guessed-safe > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsupported work-safety mode was accepted"
  assert_grep "unsupported --work-safety value" "$home/err" \
    "unsupported work-safety refusal was not concrete"
  assert_present "$home/state/$id.meta" "unsupported work-safety mode removed metadata"
  pass "record retirement rejects unsupported work-safety modes"
}

test_scout_report_rejects_remote_arguments() {
  local home id rc
  home=$(make_home scout-remote-args)
  id=scout-with-remote-args
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  run_retire "$home" "$id" --work-safety scout-report \
    --remote-url https://github.com/example/sample.git --remote-ref refs/heads/main \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "scout-report accepted remote custody arguments"
  assert_grep "scout-report safety does not accept remote-ref arguments" "$home/err" \
    "scout remote-argument refusal was not concrete"
  assert_present "$home/state/$id.meta" "scout remote-argument refusal removed metadata"
  pass "scout-report safety rejects remote custody arguments"
}

test_remote_ref_requires_both_arguments() {
  local home id sha rc
  sha=0123456789abcdef0123456789abcdef01234567

  home=$(make_home remote-missing-url)
  id=ship-missing-url
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=$sha" "record_retire_worktree_clean=1"
  set +e
  run_retire "$home" "$id" --work-safety remote-ref --remote-ref refs/heads/main \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "remote-ref safety accepted a missing remote URL"
  assert_grep "requires --remote-url" "$home/err" \
    "missing remote URL refusal was not concrete"

  home=$(make_home remote-missing-ref)
  id=ship-missing-ref
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=$sha" "record_retire_worktree_clean=1"
  set +e
  run_retire "$home" "$id" --work-safety remote-ref \
    --remote-url https://github.com/example/sample.git > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "remote-ref safety accepted a missing full ref"
  assert_grep "requires --remote-ref" "$home/err" \
    "missing remote ref refusal was not concrete"
  pass "remote-ref safety requires both explicit custody arguments"
}

test_symlinked_data_directory_refuses() {
  local home id real_data rc
  home=$(make_home unsafe-data-dir)
  id=scout-unsafe-data-dir
  write_scout "$home" "$id" "$home/copies/missing"
  real_data="$home/data-real"
  mv "$home/data" "$real_data"
  ln -s "$real_data" "$home/data"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked data directory was accepted"
  assert_grep "data directory is absent or unsafe" "$home/err" \
    "data-directory refusal was not concrete"
  assert_present "$home/state/$id.meta" "data-directory refusal removed metadata"
  pass "record retirement refuses a symlinked data directory"
}

test_gate_agent_refuses_before_retirement() {
  local home id rc
  home=$(make_home gate-agent)
  id=scout-gate-agent
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS='' \
    run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "gate-agent retirement did not refuse with exit 3 (rc=$rc)"
  assert_grep "NO_MISTAKES_GATE set" "$home/err" \
    "gate-agent refusal did not name its authority boundary"
  assert_present "$home/state/$id.meta" "gate-agent refusal removed metadata"
  pass "no-mistakes gate agents cannot drive record retirement"
}

test_task_set_lock_path_must_resolve() {
  local home id rc
  home=$(make_home $'task-set-path\tcontrol')
  id=scout-task-set-path
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unresolvable task-set lock path was accepted"
  assert_grep "task-set lock cannot be resolved" "$home/err" \
    "task-set lock path refusal was not concrete"
  assert_present "$home/state/$id.meta" "task-set lock path refusal removed metadata"
  pass "record retirement requires a resolvable task-set lock path"
}

test_symlinked_metadata_refuses_before_locking() {
  local home id outside rc
  home=$(make_home symlinked-metadata)
  id=scout-symlinked-metadata
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-meta"
  mv "$home/state/$id.meta" "$outside"
  ln -s "$outside" "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked metadata was accepted"
  assert_grep "has no regular metadata" "$home/err" \
    "pre-lock metadata refusal was not concrete"
  assert_present "$outside" "symlinked metadata refusal removed its target"
  pass "record retirement rejects symlinked metadata before taking its lock"
}

test_metadata_is_rechecked_after_lock_wait() {
  local home id rc
  home=$(make_home metadata-lock-recheck)
  id=scout-metadata-lock-recheck
  write_scout "$home" "$id" "$home/copies/missing"
  set +e
  PATH="$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=1 \
    FM_COMMAND_LOG="$home/commands.log" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      . "$1"
      lock=$(fm_meta_lock_path "$FM_STATE_OVERRIDE/$3.meta") || exit 80
      fm_lock_acquire_wait "$lock" || exit 81
      "$2" "$3" --work-safety scout-report > "$4/out" 2> "$4/err" &
      child=$!
      ready=0
      attempts=0
      while [ "$attempts" -lt 100 ]; do
        if [ -e "$FM_STATE_OVERRIDE/.control-$3.lock" ] \
          || [ -L "$FM_STATE_OVERRIDE/.control-$3.lock" ]; then
          ready=1
          break
        fi
        attempts=$((attempts + 1))
        sleep 0.01
      done
      [ "$ready" -eq 1 ] || { kill "$child"; wait "$child"; exit 82; }
      sleep 0.1
      mv "$FM_STATE_OVERRIDE/$3.meta" "$FM_STATE_OVERRIDE/$3.meta.removed"
      fm_lock_release "$lock"
      wait "$child"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$RETIRE" "$id" "$home"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "metadata disappearance during lock wait was accepted"
  assert_grep "metadata disappeared before retirement" "$home/err" \
    "post-lock metadata refusal was not concrete"
  assert_present "$home/state/$id.meta.removed" \
    "post-lock metadata refusal changed the removed record bytes"
  pass "record retirement rechecks metadata after waiting for its lifecycle lock"
}

test_metadata_window_rejects_control_characters() {
  local home id rc
  home=$(make_home metadata-control-window)
  id=scout-metadata-control-window
  write_scout "$home" "$id" "$home/copies/missing"
  awk -v window=$'firstmate:\tfm-task' '
    /^window=/ { print "window=" window; next }
    { print }
  ' "$home/state/$id.meta" > "$home/state/$id.meta.next"
  mv -f "$home/state/$id.meta.next" "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "metadata accepted a control-character runtime window"
  assert_grep "metadata window contains a control character" "$home/err" \
    "metadata control-character refusal was not concrete"
  assert_present "$home/state/$id.meta" "metadata control-character refusal removed metadata"
  pass "record retirement rejects control characters in metadata windows"
}

test_state_artifact_device_boundary_refuses() {
  local home id artifact rc
  home=$(make_home artifact-device)
  id=scout-foreign-device-artifact
  artifact="$home/state/$id.pi-ext.ts"
  write_scout "$home" "$id" "$home/copies/missing"
  printf 'regular artifact bytes\n' > "$artifact"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$*" = "-f %d $FM_FOREIGN_DEVICE_ARTIFACT" ]; then' \
    '  printf "999999999\n"' \
    '  exit 0' \
    'fi' \
    'exec /usr/bin/stat "$@"' > "$home/fakebin/stat"
  chmod +x "$home/fakebin/stat"
  set +e
  FM_FOREIGN_DEVICE_ARTIFACT="$artifact" \
    run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "regular task artifact from another device was accepted"
  assert_grep "unsafe task-state artifact" "$home/err" \
    "cross-device task-artifact refusal was not concrete"
  assert_present "$artifact" "cross-device task-artifact refusal removed the artifact"
  assert_present "$home/state/$id.meta" "cross-device task-artifact refusal removed metadata"
  pass "record retirement rejects regular task artifacts from another device"
}

test_unsupported_task_kind_refuses() {
  local home id rc
  home=$(make_home unsupported-kind)
  id=unsupported-kind-record
  write_scout "$home" "$id" "$home/copies/missing"
  awk '{ sub(/^kind=scout$/, "kind=crew"); print }' \
    "$home/state/$id.meta" > "$home/state/$id.meta.next"
  mv -f "$home/state/$id.meta.next" "$home/state/$id.meta"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsupported task kind was accepted"
  assert_grep "unsupported task kind" "$home/err" \
    "unsupported task-kind refusal was not concrete"
  assert_present "$home/state/$id.meta" "unsupported task-kind refusal removed metadata"
  pass "record retirement rejects unsupported task kinds"
}

test_unsafe_other_metadata_refuses() {
  local home id other outside rc
  home=$(make_home unsafe-other-metadata)
  id=scout-target-safe
  other=ship-other-unsafe
  write_scout "$home" "$id" "$home/copies/missing"
  fm_write_meta "$home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" "kind=ship"
  outside="$home/outside-other-meta-link"
  ln "$home/state/$other.meta" "$outside"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "hardlinked foreign metadata was accepted"
  assert_grep "metadata is unsafe" "$home/err" \
    "unsafe foreign metadata refusal was not concrete"
  assert_present "$home/state/$id.meta" "unsafe foreign metadata refusal removed target metadata"
  pass "runtime-slot proof rejects unsafe foreign metadata"
}

test_locked_other_metadata_refuses() {
  local home id other rc
  home=$(make_home locked-other-metadata)
  id=scout-target-locked-other
  other=ship-changing-other
  write_scout "$home" "$id" "$home/copies/missing"
  fm_write_meta "$home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" "kind=ship"
  set +e
  PATH="$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=1 \
    FM_COMMAND_LOG="$home/commands.log" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      . "$1"
      lock=$(fm_meta_lock_path "$FM_STATE_OVERRIDE/$4.meta") || exit 80
      fm_lock_acquire_wait "$lock" || exit 81
      set +e
      "$2" "$3" --work-safety scout-report > "$5/out" 2> "$5/err"
      rc=$?
      set -e
      fm_lock_release "$lock"
      exit "$rc"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$RETIRE" "$id" "$other" "$home"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "changing foreign metadata was accepted"
  assert_grep "metadata is changing" "$home/err" \
    "changing foreign metadata refusal was not concrete"
  assert_present "$home/state/$id.meta" "changing foreign metadata refusal removed target metadata"
  pass "runtime-slot proof refuses while foreign metadata is locked"
}

test_other_metadata_is_rechecked_after_lock() {
  local home id other target fakebin rc
  home=$(make_home other-metadata-recheck)
  id=scout-target-other-recheck
  other=ship-other-recheck
  write_scout "$home" "$id" "$home/copies/missing"
  fm_write_meta "$home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" "kind=ship"
  target="$home/other-meta-target"
  fm_write_meta "$target" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" "kind=ship"
  fakebin="$home/swap-bin"
  mkdir -p "$fakebin"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    '/bin/ln "$@"' \
    'rc=$?' \
    'for arg in "$@"; do' \
    '  if [ "$arg" = "$FM_SWAP_LOCK" ]; then' \
    '    /bin/mv "$FM_SWAP_META" "$FM_SWAP_META.regular"' \
    '    /bin/ln -s "$FM_SWAP_TARGET" "$FM_SWAP_META"' \
    '  fi' \
    'done' \
    'exit "$rc"' > "$fakebin/ln"
  chmod +x "$fakebin/ln"
  set +e
  FM_SWAP_LOCK="$home/state/.meta-$other.lock" \
    FM_SWAP_META="$home/state/$other.meta" FM_SWAP_TARGET="$target" \
    PATH="$fakebin:$home/fakebin:$PATH" FM_TASKS_AXI_COMPATIBLE=1 \
    FM_COMMAND_LOG="$home/commands.log" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$RETIRE" "$id" --work-safety scout-report \
    > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign metadata replacement after locking was accepted"
  assert_grep "metadata changed" "$home/err" \
    "foreign metadata post-lock refusal was not concrete"
  assert_present "$home/state/$id.meta" "foreign metadata post-lock refusal removed target metadata"
  pass "runtime-slot proof rechecks foreign metadata after taking its lock"
}

test_other_metadata_requires_exact_task_binding() {
  local home id other rc
  home=$(make_home other-binding)
  id=scout-target-other-binding
  other=ship-other-binding
  write_scout "$home" "$id" "$home/copies/missing"
  fm_write_meta "$home/state/$other.meta" "window=firstmate:fm-$other" "kind=ship"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign metadata without an exact task binding was accepted"
  assert_grep "requires one exact endpoint_task_id" "$home/err" \
    "foreign task-binding refusal was not concrete"
  assert_present "$home/state/$id.meta" "foreign task-binding refusal removed target metadata"
  pass "runtime-slot proof requires exact foreign task bindings"
}

test_other_metadata_filename_must_match_binding() {
  local home id other rc
  home=$(make_home other-filename-binding)
  id=scout-target-filename-binding
  other=ship-other-filename
  write_scout "$home" "$id" "$home/copies/missing"
  fm_write_meta "$home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=different-task" "kind=ship"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign metadata with a mismatched filename binding was accepted"
  assert_grep "mismatched task binding" "$home/err" \
    "foreign filename-binding refusal was not concrete"
  assert_present "$home/state/$id.meta" "foreign filename-binding refusal removed target metadata"
  pass "runtime-slot proof binds every foreign record to its filename"
}

test_other_metadata_requires_exact_window() {
  local home id other rc
  home=$(make_home other-window)
  id=scout-target-other-window
  other=ship-other-window
  write_scout "$home" "$id" "$home/copies/missing"
  fm_write_meta "$home/state/$other.meta" "endpoint_task_id=$other" "kind=ship"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign metadata without an exact runtime window was accepted"
  assert_grep "requires one exact window" "$home/err" \
    "foreign window refusal was not concrete"
  assert_present "$home/state/$id.meta" "foreign window refusal removed target metadata"
  pass "runtime-slot proof requires an exact window for every foreign record"
}

test_remote_ref_requires_full_namespace() {
  local home id sha rc
  home=$(make_home remote-short-ref)
  id=ship-short-ref
  sha=0123456789abcdef0123456789abcdef01234567
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=$sha" "record_retire_worktree_clean=1"
  set +e
  FM_FAKE_REMOTE_SHA=$sha FM_FAKE_REMOTE_REF=main \
    run_retire "$home" "$id" --work-safety remote-ref \
      --remote-url https://github.com/example/sample.git --remote-ref main \
      > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "short remote ref was accepted"
  assert_grep "must be a full refs/... name" "$home/err" \
    "short remote-ref refusal was not concrete"
  assert_present "$home/state/$id.meta" "short remote-ref refusal removed metadata"
  pass "remote custody requires a full refs namespace"
}

test_runtime_binding_directory_must_be_safe() {
  local home id outside rc
  home=$(make_home runtime-binding-dir)
  id=scout-runtime-binding-dir
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-terminal-outcomes"
  mkdir -p "$outside"
  ln -s "$outside" "$home/state/terminal-outcomes"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked runtime-binding directory was accepted"
  assert_grep "runtime binding directory is unsafe" "$home/err" \
    "runtime-binding directory refusal was not concrete"
  assert_present "$home/state/$id.meta" "runtime-binding directory refusal removed metadata"
  pass "record retirement rejects unsafe runtime-binding directories"
}

test_runtime_binding_record_must_be_safe() {
  local home id outside rc
  home=$(make_home runtime-binding-record)
  id=scout-runtime-binding-record
  write_scout "$home" "$id" "$home/copies/missing"
  mkdir -p "$home/state/terminal-outcomes"
  outside="$home/outside-terminal-record"
  printf 'task_id=another-task\n' > "$outside"
  ln -s "$outside" "$home/state/terminal-outcomes/foreign.pending"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked runtime-binding record was accepted"
  assert_grep "runtime binding record is unsafe" "$home/err" \
    "runtime-binding record refusal was not concrete"
  assert_present "$home/state/$id.meta" "runtime-binding record refusal removed metadata"
  pass "record retirement rejects unsafe runtime-binding records"
}

test_procevent_binding_must_be_settled() {
  local home id rc
  home=$(make_home procevent-binding)
  id=scout-procevent-bound
  write_scout "$home" "$id" "$home/copies/missing"
  mkdir -p "$home/state/procevent"
  printf 'task_id=%s\n' "$id" > "$home/state/procevent/exact.source"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "task-owned process-event binding was orphaned"
  assert_grep "still owns runtime binding" "$home/err" \
    "process-event binding refusal was not concrete"
  assert_present "$home/state/$id.meta" "process-event binding refusal removed metadata"
  pass "record retirement refuses task-owned process-event bindings"
}

test_pending_reply_binding_must_be_settled() {
  local home id rc
  home=$(make_home pending-reply-binding)
  id=scout-pending-reply-bound
  write_scout "$home" "$id" "$home/copies/missing"
  mkdir -p "$home/state/pending-replies"
  printf 'task_id=%s\n' "$id" > "$home/state/pending-replies/exact.pending"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "task-owned pending-reply binding was orphaned"
  assert_grep "still owns runtime binding" "$home/err" \
    "pending-reply binding refusal was not concrete"
  assert_present "$home/state/$id.meta" "pending-reply binding refusal removed metadata"
  pass "record retirement refuses task-owned pending-reply bindings"
}

test_quarantine_directory_must_be_safe() {
  local home id outside rc
  home=$(make_home quarantine-directory)
  id=scout-quarantine-directory
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-quarantine-directory"
  mkdir -p "$outside"
  ln -s "$outside" "$home/state/.pr-check-quarantine"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked PR-check quarantine was accepted"
  assert_grep "PR-check quarantine path is unsafe" "$home/err" \
    "quarantine-directory refusal was not concrete"
  assert_present "$home/state/$id.meta" "quarantine-directory refusal removed metadata"
  pass "record retirement rejects an unsafe PR-check quarantine directory"
}

test_marker_digest_requires_sha256_support() {
  local home id work_head nohash tool rc
  home=$(make_home missing-sha256)
  id=ship-missing-sha256
  work_head=0123456789abcdef0123456789abcdef01234567
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "kind=ship" \
    "record_retire_work_head=$work_head" "record_retire_worktree_clean=1"
  nohash="$home/nohash-bin"
  mkdir -p "$nohash"
  for tool in awk basename bash cat chmod cut date dirname grep head ln mkdir mktemp mv od ps \
    readlink rm rmdir sed sleep stat touch tr uname wc; do
    ln -s "$(command -v "$tool")" "$nohash/$tool"
  done
  set +e
  PATH="$nohash" FM_FAKE_REMOTE_SHA=$work_head FM_FAKE_REMOTE_REF=refs/heads/main \
    run_retire "$home" "$id" --work-safety remote-ref \
      --remote-url https://github.com/example/sample.git --remote-ref refs/heads/main \
      > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "retirement proceeded without a metadata SHA-256 digest"
  assert_grep "SHA-256 support is required" "$home/err" \
    "missing SHA-256 refusal was not concrete: $(cat "$home/err")"
  assert_present "$home/state/$id.meta" "missing SHA-256 refusal removed metadata"
  assert_absent "$home/state/.record-retired-$id" \
    "missing SHA-256 refusal published a marker"
  pass "record retirement requires a verified metadata SHA-256 digest"
}

test_existing_marker_requires_same_window() {
  local home id digest rc
  home=$(make_home existing-marker-window)
  id=scout-existing-marker-window
  write_scout "$home" "$id" "$home/copies/missing"
  digest=$(shasum -a 256 "$home/state/$id.meta" | awk '{print $1}')
  write_retirement_marker "$home/state" "$id" different-window "$digest"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "existing marker for a different runtime target was accepted"
  assert_grep "names a different runtime target" "$home/err" \
    "existing-marker window refusal was not concrete"
  assert_present "$home/state/$id.meta" "existing-marker window refusal removed metadata"
  pass "record retirement binds an existing marker to the same runtime target"
}

test_existing_marker_requires_same_metadata_generation() {
  local home id digest rc
  home=$(make_home existing-marker-generation)
  id=scout-existing-marker-generation
  write_scout "$home" "$id" "$home/copies/missing"
  digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  write_retirement_marker "$home/state" "$id" "firstmate:fm-$id" "$digest"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "existing marker for a different metadata generation was accepted"
  assert_grep "names a different metadata generation" "$home/err" \
    "existing-marker generation refusal was not concrete"
  assert_present "$home/state/$id.meta" "existing-marker generation refusal removed metadata"
  pass "record retirement binds an existing marker to the same metadata generation"
}

test_status_presentation_failure_refuses_before_marker() {
  local home id outside rc
  home=$(make_home status-presentation-failure)
  id=scout-status-presentation-failure
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-status-cursor"
  printf 'other\tident\t0\n' > "$outside"
  ln -s "$outside" "$home/state/.status-presentation-cursor"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unsafe status-presentation state was ignored"
  assert_grep "status presentation state could not be retired safely" "$home/err" \
    "status-presentation refusal was not concrete"
  assert_present "$home/state/$id.meta" "status-presentation refusal removed metadata"
  assert_absent "$home/state/.record-retired-$id" \
    "status-presentation refusal published a retirement marker"
  pass "status-presentation retirement must succeed before marker publication"
}

test_busy_generation_mismatch_refuses() {
  local home id rc
  home=$(make_home busy-generation-mismatch)
  id=scout-busy-generation-mismatch
  write_scout "$home" "$id" "$home/copies/missing"
  printf 'busy_gen=metadata-gen\n' >> "$home/state/$id.meta"
  printf 'sidecar-gen\n' > "$home/state/$id.busy-gen"
  printf 'v1 gen=sidecar-gen seq=1 state=idle source=test event=test ts=1\n' \
    > "$home/state/$id.busy-state"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mismatched busy-state incarnation was retired"
  assert_grep "busy-state incarnation could not be retired safely" "$home/err" \
    "busy-generation refusal was not concrete"
  assert_present "$home/state/$id.meta" "busy-generation refusal removed metadata"
  assert_present "$home/state/$id.busy-state" "busy-generation refusal removed busy state"
  pass "record retirement refuses a mismatched busy-state incarnation"
}

test_marker_publication_failure_refuses() {
  local home id rc
  home=$(make_home marker-publication-failure)
  id=scout-marker-publication-failure
  write_scout "$home" "$id" "$home/copies/missing"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for arg in "$@"; do' \
    '  case "$arg" in *.record-retired-*) exit 75 ;; esac' \
    'done' \
    'exec /bin/mv "$@"' > "$home/fakebin/mv"
  chmod +x "$home/fakebin/mv"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed retirement-marker publication was ignored"
  assert_grep "record-retirement marker could not be published safely" "$home/err" \
    "marker-publication refusal was not concrete"
  assert_present "$home/state/$id.meta" "marker-publication refusal removed metadata"
  assert_absent "$home/state/.record-retired-$id" \
    "failed marker publication left a retirement marker"
  pass "record retirement refuses when its marker cannot be published"
}

test_wake_queue_must_be_regular() {
  local home id outside rc
  home=$(make_home unsafe-wake-queue)
  id=scout-unsafe-wake-queue
  write_scout "$home" "$id" "$home/copies/missing"
  outside="$home/outside-wake-queue"
  printf '1\t1\theartbeat\theartbeat\theartbeat\n' > "$outside"
  ln -s "$outside" "$home/state/.wake-queue"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked wake queue was accepted"
  assert_grep "task wake rows could not be retired safely" "$home/err" \
    "wake-queue identity refusal was not concrete"
  assert_present "$home/state/$id.meta" "wake-queue identity refusal removed metadata"
  assert_content "$outside" $'1\t1\theartbeat\theartbeat\theartbeat' \
    "wake-queue identity refusal changed the symlink target"
  pass "record retirement requires a regular single-link wake queue"
}

test_wake_queue_rewrite_failure_refuses() {
  local home id rc output
  home=$(make_home wake-queue-rewrite-failure)
  id=scout-wake-queue-rewrite-failure
  write_scout "$home" "$id" "$home/copies/missing"
  printf '1\t1\theartbeat\theartbeat\theartbeat\n' > "$home/state/.wake-queue"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'last=' \
    'for arg in "$@"; do last=$arg; done' \
    'case "$last" in */.wake-queue) exit 75 ;; esac' \
    'exec /usr/bin/awk "$@"' > "$home/fakebin/awk"
  chmod +x "$home/fakebin/awk"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "failed wake-queue rewrite was ignored"
  assert_grep "task wake rows could not be retired safely" "$home/err" \
    "wake-queue rewrite refusal was not concrete"
  assert_present "$home/state/$id.meta" "wake-queue rewrite refusal removed metadata"
  assert_present "$home/state/.record-retired-$id" \
    "wake-queue rewrite failure did not exercise post-publication recovery"
  assert_content "$home/state/.wake-queue" $'1\t1\theartbeat\theartbeat\theartbeat' \
    "failed wake-queue rewrite changed the queue"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    bash -c '. "$1"; fm_wake_append signal "$2.status" "signal: still live"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$id" \
    || fail "post-publication refusal could not queue the still-live task wake"
  [ "$(wc -l < "$home/state/.wake-queue" | tr -d ' ')" -eq 2 ] \
    || fail "post-publication marker suppressed a task whose metadata remains"
  printf 'failed: still-live task reported after retirement refusal\n' \
    > "$home/state/$id.status"
  output=$(FM_STATE_OVERRIDE="$home/state" bash -c \
    '. "$1"; scan_captain_relevant_statuses "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state") \
    || fail "post-publication refusal could not scan captain-relevant status"
  printf '%s\n' "$output" | grep -q "$id" \
    || fail "post-publication marker hid status while canonical metadata remains"
  pass "post-publication failure keeps the live task visible while metadata remains"
}

test_pr_poll_recovery_failure_refuses() {
  local home id rc
  home=$(make_home pr-poll-recovery-failure)
  id=scout-pr-poll-recovery-failure
  write_scout "$home" "$id" "$home/copies/missing"
  printf 'invalid retirement receipt\n' > "$home/state/$id.pr-poll-retirement"
  set +e
  run_retire "$home" "$id" --work-safety scout-report > "$home/out" 2> "$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unreconciled PR-poll retirement state was ignored"
  assert_grep "PR-poll retirement state could not be reconciled safely" "$home/err" \
    "PR-poll recovery refusal was not concrete"
  assert_present "$home/state/$id.meta" "PR-poll recovery refusal removed metadata"
  pass "record retirement refuses unreconciled PR-poll retirement state"
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
run_test test_marker_requires_exact_line_count
run_test test_marker_requires_exact_schema
run_test test_marker_requires_nonempty_window
run_test test_marker_rejects_control_window
run_test test_marker_publish_rejects_invalid_id
run_test test_marker_publish_rejects_empty_window
run_test test_marker_publish_rejects_control_window
run_test test_marker_publish_rejects_invalid_digest
run_test test_marker_republish_requires_same_window
run_test test_marker_republish_requires_same_digest
run_test test_marker_publish_verifies_the_published_file
run_test test_marker_clear_accepts_absent_marker
run_test test_marker_clear_removes_valid_marker_and_restores_wakes
run_test test_marker_does_not_mute_unrecognized_signal_key
run_test test_marker_does_not_mute_foreign_check_path
run_test test_marker_never_mutes_stale_wake
run_test test_marker_does_not_mute_unknown_wake_kind
run_test test_retired_marker_hides_full_open_decision_scan
run_test test_retired_marker_hides_incremental_open_decision_scan
run_test test_retired_marker_hides_status_snapshot
run_test test_live_metadata_keeps_marker_consumers_audible
run_test test_surface_artifact_paths_are_producer_owned
run_test test_watcher_key_collapses_every_occurrence
run_test test_muted_wake_releases_queue_lock
run_test test_partial_wake_library_fails_open
run_test test_partial_classify_library_fails_open
run_test test_watcher_key_collision_refuses
run_test test_unsupported_safety_mode_refuses
run_test test_scout_report_rejects_remote_arguments
run_test test_remote_ref_requires_both_arguments
run_test test_symlinked_data_directory_refuses
run_test test_gate_agent_refuses_before_retirement
run_test test_task_set_lock_path_must_resolve
run_test test_symlinked_metadata_refuses_before_locking
run_test test_metadata_is_rechecked_after_lock_wait
run_test test_metadata_window_rejects_control_characters
run_test test_state_artifact_device_boundary_refuses
run_test test_unsupported_task_kind_refuses
run_test test_unsafe_other_metadata_refuses
run_test test_locked_other_metadata_refuses
run_test test_other_metadata_is_rechecked_after_lock
run_test test_other_metadata_requires_exact_task_binding
run_test test_other_metadata_filename_must_match_binding
run_test test_other_metadata_requires_exact_window
run_test test_remote_ref_requires_full_namespace
run_test test_runtime_binding_directory_must_be_safe
run_test test_runtime_binding_record_must_be_safe
run_test test_procevent_binding_must_be_settled
run_test test_pending_reply_binding_must_be_settled
run_test test_quarantine_directory_must_be_safe
run_test test_marker_digest_requires_sha256_support
run_test test_existing_marker_requires_same_window
run_test test_existing_marker_requires_same_metadata_generation
run_test test_status_presentation_failure_refuses_before_marker
run_test test_busy_generation_mismatch_refuses
run_test test_marker_publication_failure_refuses
run_test test_wake_queue_must_be_regular
run_test test_wake_queue_rewrite_failure_refuses
run_test test_pr_poll_recovery_failure_refuses
