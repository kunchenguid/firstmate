#!/usr/bin/env bash
# Behavior tests for the shadow-only external-wait pipeline writer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="${FM_PIPELINE_TEST_SCRIPT:-$ROOT/bin/fm-pipeline.sh}"
TMP_ROOT=$(fm_test_tmproot fm-pipeline)

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

new_state() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/worktree"
  printf '%s\n' "$dir"
}

# --- real crew-state path fixtures (for the false-stale regression) ----------
# These drive the REAL bin/fm-crew-state.sh (no FM_PIPELINE_CREW_STATE_BIN fake)
# over a throwaway git worktree, a fake no-mistakes that reports no run, and a
# fake tmux pane, plus a real busy/idle record armed through bin/fm-busy-event.sh.
# This is the same hermetic machinery tests/fm-crew-state.test.sh uses, so the
# probe exercises the actual state-derivation the false-stale defect lives in.
fm_git_identity fmtest fmtest@example.invalid

make_crew_repo() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

make_crew_fakebin() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs) printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac ;;
  runs) printf '%s\n' "${FM_FAKE_RUNS_LIST:-}" ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

arm_busy_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

run_real_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-crew-state.sh" "$2"
}

test_line_format_and_unknown_preservation() {
  local root output line rc=0
  root=$(new_state unknown)
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  printf 'kind=ship\nspawn_gen=gen-unknown\nworktree=%s/worktree\nharness=tmux\n' "$root" > "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "probe should succeed for a declared wait"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'ts=' "every event must have a timestamp"
  assert_contains "$line" 'probe=unknown' "unreadable current state must remain unknown"
  assert_contains "$line" 'mode=shadow' "every event must be shadow-only"
  assert_contains "$line" 'wait=ext:vendor-release' "the keyed wait must be recorded"
  [ "$(printf '%s' "$line" | awk '{print NF}')" -eq 14 ] || fail "event line did not have 14 fields: $line"
  pass "fm-pipeline.sh: line format preserves probe=unknown"
}

test_would_heal_without_evidence_is_rejected() {
  local root output rc=0
  root=$(new_state invalid-evidence)
  output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
    'ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=stall rule=recheck-external action=would-heal mode=shadow evidence=- gen=1 attempt=- wait=ext:x snap=-' 2>&1) || rc=$?
  expect_code 1 "$rc" "a would-heal without evidence must be refused"
  assert_contains "$output" "inadmissible" "the refusal must identify inadmissible evidence"
  [ ! -e "$root/state/pipeline-events.log" ] || fail "invalid event was written"
  pass "fm-pipeline.sh: would-heal with evidence=- is inadmissible"
}

test_append_rejects_malformed_fields() {
  local root line bad_line output rc
  root=$(new_state malformed-event)
  line='ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=unknown rule=- action=none mode=shadow evidence=state/t1.status:1 gen=1 attempt=- wait=ext:x snap=-'
  for bad_line in \
    "${line/task=t1/task=../escape}" \
    "${line/since=10/since=-1}" \
    "${line/gen=1/gen=bad=value}" \
    "${line/attempt=-/attempt=bad value}" \
    "${line/wait=ext:x/wait=ext:}" \
    "${line/snap=-/snap=bad value}"; do
    rc=0
    output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append "$bad_line" 2>&1) || rc=$?
    expect_code 1 "$rc" "malformed event fields must be refused"
  done
  [ ! -e "$root/state/pipeline-events.log" ] || fail "malformed events were written"
  pass "fm-pipeline.sh: malformed event fields are rejected"
}

test_event_log_symlink_is_rejected() {
  local root outside output rc=0
  root=$(new_state log-safety)
  outside="$root/outside.log"
  printf 'sentinel\n' > "$outside"
  ln -s "$outside" "$root/state/pipeline-events.log"
  output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
    'ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=unknown rule=- action=none mode=shadow evidence=state/t1.status:1 gen=1 attempt=- wait=ext:x snap=-' 2>&1) || rc=$?
  expect_code 1 "$rc" "a symlinked event log must be refused"
  [ "$(cat "$outside")" = sentinel ] || fail "symlinked event log was followed"
  pass "fm-pipeline.sh: symlinked event logs are rejected"
}

test_stale_wait_is_shadow_only() {
  local root output line rc=0
  root=$(new_state stale)
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\nworktree=%s/worktree\nharness=tmux\n' "$root" > "$root/state/task.meta"
  # A declared wait is genuinely contradicted only by a state the existing
  # contract treats as positive disproof: done/blocked/failed. working and
  # parked are concurrent activity, not disproof (see
  # test_working_does_not_contradict_keyed_wait and
  # test_parked_does_not_contradict_keyed_wait), so this case uses done to keep
  # exercising the stall/would-heal shadow-only path under the corrected contract.
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: done · source: run-step · run passed'
EOF
  chmod +x "$root/fake-crew-state.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a contradicted declared wait should be observed successfully"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'probe=stall' "a positively contradicted wait must be a stall"
  assert_contains "$line" 'rule=recheck-external' "stale waits must identify the shadow rule"
  assert_contains "$line" 'action=would-heal' "stale waits must never execute a heal"
  assert_contains "$line" 'mode=shadow' "stale waits must remain shadow-only"
  assert_contains "$line" 'since=0' "first observations must start their lower-bound duration at zero"
  assert_contains "$line" 'gen=gen-1' "events must use the spawn incarnation"
  [ -f "$root/state/task.pipeline" ] || fail "the first observation was not recorded"
  pass "fm-pipeline.sh: contradicted waits log a would-heal without acting"
}

# An open keyed external wait remains live while the crew is concurrently
# working: the worker's busy pane is not evidence about the wait. The probe must
# map working to probe=unknown / rule=- / action=none, not stall/would-heal.
# Before the fix this fails red: working shares the stall arm and emits
# action=would-heal.
test_working_does_not_contradict_keyed_wait() {
  local d crew_state out line rc=0
  d=$(new_state working-live)
  make_crew_repo "$d/worktree" fm/feat-work
  make_crew_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-work.meta" "window=fm:fm-feat-work" "worktree=$d/worktree" "kind=ship" "spawn_gen=gen-work" "harness=claude"
  printf '%s\n' \
    'paused: [key=vendor-release] holding for the upstream vendor cut' \
    'working: [key=impl-slice] continuing the unrelated implementation slice' > "$d/state/feat-work.status"
  FM_FAKE_AXI_STATUS=""; FM_FAKE_RUNS_LIST=""; FM_FAKE_BUSY=1
  export FM_FAKE_AXI_STATUS FM_FAKE_RUNS_LIST FM_FAKE_BUSY
  arm_busy_record "$d/state" feat-work
  crew_state=$(run_real_crew_state "$d" feat-work)
  assert_contains "$crew_state" "state: working" "fixture must report working through the real crew-state path"
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "probe should succeed for a live keyed wait while the crew is working"
  line=$(tail -1 "$d/state/pipeline-events.log")
  assert_contains "$line" 'probe=unknown' "a concurrent working state must not contradict a keyed wait"
  assert_contains "$line" 'rule=-' "a non-contradicting state carries no rule"
  assert_contains "$line" 'action=none' "a live keyed wait must not be flagged for healing"
  assert_contains "$line" 'mode=shadow' "the probe must remain shadow-only"
  assert_contains "$line" 'wait=ext:vendor-release' "the keyed wait identity must be recorded"
  pass "fm-pipeline.sh: a working crew does not falsify a live keyed wait"
}

# An open keyed external wait remains live while the crew is gate-parked: a
# needs-decision on a different key is concurrent activity, not disproof of the
# wait. The probe must map parked to probe=unknown / rule=- / action=none.
# Before the fix this fails red: parked shares the stall arm and emits
# action=would-heal.
test_parked_does_not_contradict_keyed_wait() {
  local d crew_state out line rc=0
  d=$(new_state parked-live)
  make_crew_repo "$d/worktree" fm/feat-parked
  make_crew_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-parked.meta" "window=fm:fm-feat-parked" "worktree=$d/worktree" "kind=ship" "spawn_gen=gen-parked" "harness=claude"
  printf '%s\n' \
    'paused: [key=vendor-release] holding for the upstream vendor cut' \
    'needs-decision: [key=gate-question] which rollout order do we take' > "$d/state/feat-parked.status"
  FM_FAKE_AXI_STATUS=""; FM_FAKE_RUNS_LIST=""; FM_FAKE_BUSY=0
  export FM_FAKE_AXI_STATUS FM_FAKE_RUNS_LIST FM_FAKE_BUSY
  arm_idle_record "$d/state" feat-parked
  crew_state=$(run_real_crew_state "$d" feat-parked)
  assert_contains "$crew_state" "state: parked" "fixture must report parked through the real crew-state path"
  out=$(PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "probe should succeed for a live keyed wait while the crew is parked"
  line=$(tail -1 "$d/state/pipeline-events.log")
  assert_contains "$line" 'probe=unknown' "a concurrent parked state must not contradict a keyed wait"
  assert_contains "$line" 'rule=-' "a non-contradicting state carries no rule"
  assert_contains "$line" 'action=none' "a live keyed wait must not be flagged for healing"
  assert_contains "$line" 'mode=shadow' "the probe must remain shadow-only"
  assert_contains "$line" 'wait=ext:vendor-release' "the keyed wait identity must be recorded"
  pass "fm-pipeline.sh: a parked crew does not falsify a live keyed wait"
}

test_resumed_wait_is_not_reprobed() {
  local root output rc=0
  root=$(new_state resumed)
  printf '%s\n' \
    'paused: [key=vendor-release] waiting on vendor' \
    '' \
    'working: [key=vendor-release] resumed after vendor release' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a resumed wait should not be reprobed"
  [ ! -e "$root/state/pipeline-events.log" ] || fail "a later working transition was ignored"
  pass "fm-pipeline.sh: resumed waits are not selected from stale history"
}

test_note_preserves_active_wait() {
  local root output line rc=0
  root=$(new_state note)
  printf '%s\n' \
    'paused: [key=vendor-release] waiting on vendor' \
    'note: vendor contact recorded' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: working · source: pane · pane is active'
EOF
  chmod +x "$root/fake-crew-state.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "an informational note should preserve an active pause"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'wait=ext:vendor-release' "the active paused wait must survive a note"
  pass "fm-pipeline.sh: informational notes preserve active waits"
}

test_configured_pause_verb_is_supported() {
  local root output line rc=0
  root=$(new_state custom-pause)
  printf 'waiting: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: paused · source: pane · pane is idle'
EOF
  chmod +x "$root/fake-crew-state.sh"
  output=$(FM_CLASSIFY_PAUSED_VERB=waiting FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a configured pause verb should be probed"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'wait=ext:vendor-release' "configured pause verbs must preserve the wait key"
  pass "fm-pipeline.sh: configured pause verbs are supported"
}

test_all_active_waits_are_probed_independently() {
  local root output rc=0
  root=$(new_state multiple-waits)
  printf '%s\n' \
    'paused: [key=vendor-release] waiting on vendor' \
    'paused: [key=rate-limit] waiting on provider' > "$root/state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/task.meta"
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: paused · source: pane · pane is idle'
EOF
  chmod +x "$root/fake-crew-state.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "all active waits should be probed"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 2 ] || fail "only one active wait was probed"
  [ "$(grep -c 'wait=ext:vendor-release' "$root/state/pipeline-events.log")" -eq 1 ] || fail "vendor wait was not recorded"
  [ "$(grep -c 'wait=ext:rate-limit' "$root/state/pipeline-events.log")" -eq 1 ] || fail "rate-limit wait was not recorded"
  local cache="$root/state/task.pipeline-seen"
  [ -f "$cache" ] || cache="$root/state/task.pipeline"
  [ "$(rg -c '^wait=ext:' "$cache")" -eq 2 ] || fail "wait timings were not kept independently"
  pass "fm-pipeline.sh: all active waits receive independent observations"
}

test_pause_key_sentinels_remain_distinct() {
  local root output rc=0
  root=$(new_state pause-sentinels)
  printf '%s\n' \
    'paused: waiting on an external service' \
    'paused: [key=-] waiting on a literal hyphen key' \
    'paused: [key=bad key] malformed key' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "pause key sentinel probing should succeed"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 2 ] || fail "invalid pause key changed active wait count"
  grep -F 'wait=ext:-' "$root/state/pipeline-events.log" >/dev/null \
    || fail "unkeyed pause lost its wait identity"
  grep -F 'wait=ext:%2D' "$root/state/pipeline-events.log" >/dev/null \
    || fail "literal hyphen key collided with unkeyed pause"
  grep -F 'evidence=state/task.status:3' "$root/state/pipeline-events.log" >/dev/null \
    && fail "invalid pause key was treated as an active wait"
  pass "fm-pipeline.sh: pause key sentinels remain distinct"
}

test_valid_invalid_slug_remains_distinct() {
  local root output rc=0
  root=$(new_state invalid-slug)
  printf '%s\n' \
    'paused: [key=invalid] waiting on a valid key' \
    'paused: [key=bad key] malformed key' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "valid and malformed pause keys should be handled"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 1 ] || fail "malformed key changed the active wait count"
  grep -F 'wait=ext:invalid' "$root/state/pipeline-events.log" >/dev/null \
    || fail "valid key=invalid was treated as malformed"
  grep -F 'evidence=state/task.status:2' "$root/state/pipeline-events.log" >/dev/null \
    && fail "malformed key was treated as the valid key"
  pass "fm-pipeline.sh: valid invalid-slug keys remain distinct"
}

test_explicit_default_key_remains_distinct() {
  local root output rc=0
  root=$(new_state default-key)
  printf '%s\n' \
    'paused: waiting on an unkeyed wait' \
    'paused: [key=default] waiting on the default key' \
    'paused: [key=invalid] waiting on the invalid key' \
    'paused: [key=bad key] malformed key' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "explicit and unkeyed pause keys should be handled"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 3 ] \
    || fail "explicit default key changed the active wait count"
  grep -F 'wait=ext:-' "$root/state/pipeline-events.log" >/dev/null \
    || fail "unkeyed pause lost its wait identity"
  grep -F 'wait=ext:%64efault' "$root/state/pipeline-events.log" >/dev/null \
    || fail "literal default key collided with the unkeyed pause"
  grep -F 'wait=ext:invalid' "$root/state/pipeline-events.log" >/dev/null \
    || fail "literal invalid key lost its wait identity"
  grep -F 'evidence=state/task.status:4' "$root/state/pipeline-events.log" >/dev/null \
    && fail "malformed key was treated as an active wait"
  pass "fm-pipeline.sh: explicit default keys remain distinct"
}

test_stale_event_lock_is_recovered() {
  local root output rc=0
  root=$(new_state stale-lock)
  mkdir "$root/state/pipeline-events.log.lock"
  touch -t 202001010000 "$root/state/pipeline-events.log.lock"
  output=$(FM_PIPELINE_ALLOW_APPEND=1 FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
    'ts=2026-09-03T12:00:00Z task=t1 kind=ship step=working since=10 probe=stall rule=recheck-external action=would-heal mode=shadow evidence=state/t1.status:1 gen=1 attempt=- wait=ext:x snap=-' 2>&1) || rc=$?
  expect_code 0 "$rc" "a stale event lock should be recovered"
  [ "$(wc -l < "$root/state/pipeline-events.log")" -eq 1 ] || fail "event was not appended after stale lock recovery"
  [ ! -e "$root/state/pipeline-events.log.lock" ] || fail "recovered event lock remained"
  pass "fm-pipeline.sh: stale event locks recover through shared locking"
}

test_task_paths_are_confined() {
  local root outside output rc=0
  root=$(new_state path-safety)
  outside="$root/escape.status"
  printf 'sentinel\n' > "$outside"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe --task ../escape 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "task traversal was accepted"
  [ "$(cat "$outside")" = sentinel ] || fail "task traversal touched an outside file"

  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/link.status"
  ln -s "$outside" "$root/state/link.meta"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe --task link 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked metadata was accepted"
  [ ! -e "$root/state/pipeline-events.log" ] || fail "symlinked metadata produced an event"

  rm -f "$root/state/link.meta"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$root/state/link.meta"
  ln -s "$outside" "$root/state/link.pipeline"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe --task link 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked pipeline state was accepted"
  [ "$(cat "$outside")" = sentinel ] || fail "symlinked pipeline state was followed"
  pass "fm-pipeline.sh: task and state paths stay confined"
}

test_arm_preserves_existing_check_on_registration_failure() {
  local root check trust fakebin count shasum_count old old_trust output rc=0
  root=$(new_state arm-rollback)
  check="$root/state/pipeline-probe.check.sh"
  trust="$root/state/pipeline-probe.check-trust"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not create the expected pipeline probe check"
  old=$(cat "$check")
  old_trust=$(cat "$trust")
  fakebin="$root/fakebin"
  count="$root/fake-cat-count"
  shasum_count="$root/fake-shasum-count"
  mkdir -p "$fakebin"
  : > "$count"
  : > "$shasum_count"
  cat > "$fakebin/cat" <<'EOF'
#!/usr/bin/env bash
count=0
IFS= read -r count < "${FM_PIPELINE_FAKE_CAT_COUNT}" || true
count=$((count + 1))
printf '%s\n' "$count" > "$FM_PIPELINE_FAKE_CAT_COUNT"
if [ "$count" -eq 3 ]; then
  printf '%s\n' changed
else
  /bin/cat "$@"
  fi
EOF
  cat > "$fakebin/shasum" <<'EOF'
#!/usr/bin/env bash
count=0
IFS= read -r count < "${FM_PIPELINE_FAKE_SHASUM_COUNT}" || true
count=$((count + 1))
printf '%s\n' "$count" > "$FM_PIPELINE_FAKE_SHASUM_COUNT"
case "$count" in
  1) hash=$(sed -n '2p' "$FM_PIPELINE_EXPECTED_TRUST") ;;
  2) hash=0000000000000000000000000000000000000000000000000000000000000000 ;;
  *) hash=1111111111111111111111111111111111111111111111111111111111111111 ;;
esac
printf '%s  %s\n' "$hash" "${1-}"
EOF
  chmod +x "$fakebin/cat" "$fakebin/shasum"
  output=$(PATH="$fakebin:$PATH" FM_PIPELINE_FAKE_CAT_COUNT="$count" \
    FM_PIPELINE_FAKE_SHASUM_COUNT="$shasum_count" FM_PIPELINE_EXPECTED_TRUST="$trust" \
    FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "registration failure should fail arming"
  [ "$(cat "$check")" = "$old" ] || fail "registration rollback did not restore the existing check"
  [ -f "$trust" ] || fail "registration rollback removed the existing trust artifact"
  [ "$(cat "$trust")" = "$old_trust" ] || fail "registration rollback did not restore the existing trust artifact"
  pass "fm-pipeline.sh: registration rollback preserves check and trust"
}

test_relative_arm_embeds_absolute_state() {
  local root state output rc=0
  root=$(new_state relative-arm)
  state="$root/state"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: working · source: pane · pane is active'
EOF
  chmod +x "$root/fake-crew-state.sh"
  (cd "$TMP_ROOT" && FM_HOME=relative-arm FM_STATE_OVERRIDE=relative-arm/state "$SCRIPT" arm >/dev/null) \
    || fail "relative arming failed"
  output=$(cd / && FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" \
    "$state/pipeline-probe.check.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "an armed check should work from another directory"
  [ -s "$state/pipeline-events.log" ] || fail "relative arming did not preserve the absolute state"
  pass "fm-pipeline.sh: armed checks retain absolute state paths"
}

test_reconcile_ignores_status_testimony() {
  local root output record rc=0
  root=$(new_state reconcile-testimony)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf 'done: finished while a PR remains under review\n' > "$root/state/task.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "reconcile should derive dispatch from metadata"
  record=$(cat "$root/state/task.pipeline")
  assert_contains "$record" 'step=dispatched' "status testimony must not replace the artifact step"
  assert_not_contains "$record" 'status-log' "status-log must never enter the lifecycle record"
  pass "fm-pipeline.sh: reconcile ignores status testimony"
}

test_append_is_not_agent_facing() {
  local root output rc=0
  root=$(new_state append-guard)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append anything 2>&1) || rc=$?
  expect_code 1 "$rc" "append must be guarded from the agent-facing surface"
  assert_contains "$output" 'internal test-only' "append refusal did not name its boundary"
  pass "fm-pipeline.sh: append is guarded"
}

test_legacy_cache_migrates_without_reinterpretation() {
  local root output record cache rc=0
  root=$(new_state legacy-cache)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf 'wait=ext:old step=- gen=- evidence=state/task.status:1 observed_at=1\n' > "$root/state/task.pipeline"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "legacy cache should be migrated on first owner touch"
  [ -f "$root/state/task.pipeline-seen" ] || fail "legacy cache was not moved to pipeline-seen"
  cache=$(cat "$root/state/task.pipeline-seen")
  assert_contains "$cache" 'wait=ext:old' "legacy cache bytes were not preserved"
  record=$(cat "$root/state/task.pipeline")
  assert_contains "$record" 'schema=fm-pipeline.v3' "lifecycle record header was not created"
  assert_not_contains "$record" 'wait=ext:old' "legacy cache was reinterpreted as lifecycle state"
  assert_contains "$output" 'migrated legacy observation cache' "migration was not logged"
  pass "fm-pipeline.sh: legacy observation cache is migrated, not reinterpreted"
}

test_board_json_does_not_migrate_legacy_cache() {
  local root board
  root=$(new_state board-legacy-cache)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf '%s\n' 'wait=ext:old step=- gen=- evidence=state/task.status:1 observed_at=1' > "$root/state/task.pipeline"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[0].record_state == "refused:legacy-cache" and .tasks[0].initialized == false' >/dev/null \
    || fail "board-json did not project an unmigrated legacy cache"
  [ -e "$root/state/task.pipeline" ] || fail "board-json moved the legacy cache"
  [ ! -e "$root/state/task.pipeline-seen" ] || fail "board-json created a cache migration"
  pass "fm-pipeline.sh: board-json does not mutate legacy cache"
}

test_legacy_cache_migration_collision_refuses() {
  local root output before after rc=0
  root=$(new_state migration-collision)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf 'legacy\n' > "$root/state/task.pipeline"
  printf 'existing\n' > "$root/state/task.pipeline-seen"
  before=$(cat "$root/state/task.pipeline")
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "ambiguous cache migration must refuse"
  assert_contains "$output" 'refused:migration-collision' "migration collision was not named"
  after=$(cat "$root/state/task.pipeline")
  [ "$before" = "$after" ] || fail "migration collision changed the legacy file"
  pass "fm-pipeline.sh: migration collision preserves both files"
}

test_probe_reads_owner_record_not_meta_step_claim() {
  local root output line rc=0
  root=$(new_state record-probe)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" "step=merged" "attempt=caller-claim"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the owner record"
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" "step=merged" "attempt=changed-claim"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "probe should use the owner record"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'step=dispatched' "probe trusted the metadata step claim"
  assert_contains "$line" 'gen=gen-1' "probe lost the record generation"
  assert_contains "$line" 'attempt=caller-claim' "probe read attempt from outside the owner record"
  assert_not_contains "$line" 'attempt=changed-claim' "probe trusted the metadata attempt claim"
  pass "fm-pipeline.sh: probe uses lifecycle record fields"
}

test_reconcile_absent_meta_refuses_without_writing() {
  local root output rc=0
  root=$(new_state absent-meta)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "reconcile must refuse absent metadata"
  assert_contains "$output" 'refused:absent-meta-not-cleaned' "absent metadata needs the explicit refusal"
  [ ! -e "$root/state/task.pipeline" ] || fail "absent metadata created a lifecycle record"
  pass "fm-pipeline.sh: absent metadata is not cleaned"
}

test_record_reader_rejects_unproven_hand_append() {
  local root output before after board rc=0
  root=$(new_state unproven-record)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the proven dispatch record"
  {
    cat "$root/state/task.pipeline"
    printf '%s\n' 'rev=2 ts=2026-09-05T00:00:00Z step=merged evidence=forge:x gen=gen-1 head=unknown attempt=-'
  } > "$root/state/task.pipeline.tmp"
  mv "$root/state/task.pipeline.tmp" "$root/state/task.pipeline"
  before=$(cat "$root/state/task.pipeline")
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "unproven hand-written lifecycle lines must refuse"
  assert_contains "$output" 'refused:unproven-step' "the refusal must name the unsupported step"
  after=$(cat "$root/state/task.pipeline")
  [ "$before" = "$after" ] || fail "unproven lifecycle bytes changed"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[0].step_proven == false and .tasks[0].record_state == "refused:unproven-step"' >/dev/null \
    || fail "board-json did not project the refused record"
  pass "fm-pipeline.sh: unproven record lines are refused and projected"
}

test_foreign_generation_is_refused() {
  local root output before after rc=0
  root=$(new_state foreign-generation)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=current"
  printf '%s\n' 'schema=fm-pipeline.v3 task=task kind=ship gen=old' > "$root/state/task.pipeline"
  before=$(cat "$root/state/task.pipeline")
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "foreign generations must refuse"
  assert_contains "$output" 'refused:foreign-gen' "the refusal must name the foreign generation"
  after=$(cat "$root/state/task.pipeline")
  [ "$before" = "$after" ] || fail "foreign-generation bytes changed"
  pass "fm-pipeline.sh: foreign generations are fenced"
}

test_pr_registration_and_merge_artifacts() {
  local root output record rc=0 head
  root=$(new_state pr-artifacts)
  head=0123456789012345678901234567890123456789
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" \
    "pr=https://github.com/example/project/pull/7"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "canonical PR identity should prove registration"
  record=$(cat "$root/state/task.pipeline")
  assert_contains "$record" 'step=pr-registered' "pr registration should be recorded"
  assert_contains "$record" 'head=unknown' "missing PR head must remain unknown"
  assert_not_contains "$record" 'pr-open' "registration must not claim a remote open state"
  printf '%s\n' "pr_head=$head" >> "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "a later PR head must not invalidate an honest unknown receipt"
  fm_write_meta "$root/state/task2.meta" "kind=ship" "spawn_gen=gen-2" \
    "pr=https://github.com/example/project/pull/8" "pr_head=$head"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task2 2>&1) || rc=$?
  expect_code 0 "$rc" "a recorded PR head should be retained"
  assert_contains "$(cat "$root/state/task2.pipeline")" "head=$head" "recorded PR head was lost"
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_poll_merge_mark_notified "$root/state" task2 github github.com example/project 8 \
    || fail "could not create the merge receipt fixture"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task2 2>&1) || rc=$?
  expect_code 0 "$rc" "the merge receipt should prove merge"
  assert_contains "$(cat "$root/state/task2.pipeline")" 'step=merged' "merge receipt was not reconciled"
  pass "fm-pipeline.sh: registration and merge use artifact receipts"
}

test_steps_print_ordered_graph() {
  local root output rc=0
  root=$(new_state steps)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" steps ship-nm 2>&1) || rc=$?
  expect_code 0 "$rc" "steps should print the ship graph"
  assert_contains "$output" 'nodes=dispatched ingress working validating pr-registered checks merge-wait merged' \
    "ship graph nodes are not ordered"
  assert_contains "$output" 'edges=dispatched>ingress' "ship graph edges are missing"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" steps secondmate 2>&1) || rc=$?
  expect_code 0 "$rc" "steps should print the recurring graph"
  assert_contains "$output" 'nodes=session-live inbox-current queue-current reporting' "secondmate graph is incomplete"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" steps unknown 2>&1) || rc=$?
  expect_code 1 "$rc" "unknown pipeline kinds must refuse"
  assert_contains "$output" 'unknown pipeline kind' "unknown pipeline kind was not named"
  pass "fm-pipeline.sh: steps owns ordered nodes and edges"
}

test_probe_cost_fixture_preserves_sensor_call_count() {
  local root check fake count output rc=0 i start elapsed
  root=$(new_state probe-cost)
  fake="$root/fake-crew-state.sh"
  count="$root/crew-state-calls"
  : > "$count"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_PIPELINE_TEST_CREW_COUNT:?}"
printf '%s\n' 'state: paused · source: pane · fixture'
EOF
  chmod +x "$fake"
  i=1
  while [ "$i" -le 40 ]; do
    fm_write_meta "$root/state/task-$i.meta" "kind=ship" "spawn_gen=gen-$i"
    printf 'paused: [key=fixture] waiting on the fixture\n' > "$root/state/task-$i.status"
    i=$((i + 1))
  done
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_CREW_STATE_BIN="$fake" \
    FM_PIPELINE_TEST_CREW_COUNT="$count" "$SCRIPT" probe >/dev/null \
    || fail "could not initialize the 40-task probe fixture"
  : > "$count"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm the cost fixture"
  check="$root/state/pipeline-probe.check.sh"
  start=$(date +%s)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_CREW_STATE_BIN="$fake" \
    FM_PIPELINE_TEST_CREW_COUNT="$count" "$check" 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "the 40-task check fixture should succeed"
  [ -z "$output" ] || fail "the steady-state fixture emitted output: $output"
  [ "$(wc -l < "$count" | tr -d ' ')" -eq 40 ] || fail "the steady-state probe did not make exactly 40 sensor calls"
  [ "$elapsed" -lt 20 ] || fail "the 40-task check fixture exceeded its smoke bound"
  printf 'pr=https://github.com/example/project/pull/7\n' >> "$root/state/task-1.meta"
  : > "$count"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_CREW_STATE_BIN="$fake" \
    FM_PIPELINE_TEST_CREW_COUNT="$count" "$check" 2>&1) || rc=$?
  expect_code 0 "$rc" "the changed-artifact fixture should succeed"
  [ "$(wc -l < "$count" | tr -d ' ')" -eq 40 ] || fail "the changed-artifact probe did not make exactly 40 sensor calls"
  assert_contains "$(cat "$root/state/task-1.pipeline")" 'step=pr-registered' \
    "changed artifact did not advance the owner record"
  pass "fm-pipeline.sh: 40-task reconcile preserves sensor call count"
}

test_board_json_fixture_inventory_and_bound() {
  local root output start elapsed i rc=0
  root=$(new_state board-fixture)
  i=1
  while [ "$i" -le 40 ]; do
    fm_write_meta "$root/state/task-$i.meta" "kind=ship" "spawn_gen=gen-$i"
    i=$((i + 1))
  done
  start=$(date +%s)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "board-json should scan the fixture"
  [ "$elapsed" -lt 20 ] || fail "board-json exceeded the 20 second fixture bound"
  printf '%s' "$output" | jq -e '.generated_epoch > 0 and (.tasks | length) == 40 and all(.tasks[]; .initialized == false and .crew_state == {verb:"unavailable",source:"-",ts:"-"}) and (.tasks[0].steps.nodes | length) == 8' >/dev/null \
    || fail "board-json did not include the complete uninitialized inventory"
  pass "fm-pipeline.sh: board-json covers 40 tasks within the smoke bound"
}

test_quiet_registered_probe_and_refusal_projection() {
  local root check output board err rc=0
  root=$(new_state quiet-probe)
  fm_write_meta "$root/state/good.meta" "kind=ship" "spawn_gen=good-gen"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile good >/dev/null \
    || fail "could not initialize the healthy fixture"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" arm >/dev/null \
    || fail "could not arm the real probe shim"
  check="$root/state/pipeline-probe.check.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$check" 2>&1) || rc=$?
  expect_code 0 "$rc" "a healthy registered probe should succeed"
  [ -z "$output" ] || fail "an unchanged probe emitted actionable stdout: $output"
  fm_write_meta "$root/state/bad.meta" "kind=ship" "spawn_gen=bad-gen"
  {
    printf '%s\n' 'schema=fm-pipeline.v3 task=bad kind=ship gen=bad-gen'
    printf '%s\n' broken
  } > "$root/state/bad.pipeline"
  printf 'paused: [key=bad-wait] waiting on the bad record\n' > "$root/state/bad.status"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$check" 2>&1) || rc=$?
  expect_code 0 "$rc" "a refusal in the probe should not wake the watcher"
  [ -z "$output" ] || fail "a refused probe emitted actionable stdout: $output"
  [ ! -e "$root/state/pipeline-events.log" ] || fail "a refused probe wrote a lifecycle event"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "bad") | .record_state == "refused:malformed-record-line"' >/dev/null \
    || fail "board-json did not expose the malformed record"
  err=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile bad 2>&1) || rc=$?
  assert_contains "$err" 'refused:malformed-record-line' "direct reconcile did not expose the refusal"
  assert_contains "$err" 'repair:' "direct reconcile omitted the repair path"
  pass "fm-pipeline.sh: registered probe stays quiet while board-json exposes refusal"
}

test_retire_owner_records() {
  local root output rc=0
  root=$(new_state retire-record)
  printf '%s\n' legacy > "$root/state/task.pipeline-seen"
  printf '%s\n' legacy > "$root/state/task.pipeline"
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" retire task 2>&1) || rc=$?
  expect_code 1 "$rc" "retire must refuse a live metadata row"
  [ -e "$root/state/task.pipeline" ] && [ -e "$root/state/task.pipeline-seen" ] \
    || fail "live metadata refusal removed owner records"
  rm -f "$root/state/task.meta"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" retire task 2>&1) || rc=$?
  expect_code 0 "$rc" "retire should remove stale owner records"
  [ ! -e "$root/state/task.pipeline" ] && [ ! -e "$root/state/task.pipeline-seen" ] \
    || fail "retire left owner records behind"
  pass "fm-pipeline.sh: retire is generation-safe"
}

test_pipeline_pure_function_units() {
  local root output
  root=$(new_state pure-units)
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" FM_PIPELINE_SOURCE_ONLY=1 \
    bash -c '
      set -u
      source "$1"
      state=$2
      cat > "$state/task.pipeline" <<EOF
schema=fm-pipeline.v3 task=task kind=ship gen=gen-1
EOF
      valid="rev=1 ts=2026-09-05T00:00:00Z step=dispatched evidence=meta:state/task.meta gen=gen-1 head=unknown attempt=-"
      pipeline_record_reset
      good_rc=0
      pipeline_record_line_load "$valid" "$state/task.pipeline" 2 gen-1 || good_rc=$?
      bad_rc=0
      pipeline_record_line_load "rev=2 ts=2026-09-05T00:00:00Z step=unknown evidence=meta:state/task.meta gen=gen-1 head=unknown attempt=-" "$state/task.pipeline" 3 gen-1 || bad_rc=$?
      header_rc=0
      pipeline_record_header_valid "$state/task.pipeline" task ship gen-2 || header_rc=$?
      printf "%s\n" "record_rc=$good_rc step=$PIPELINE_RECORD_STEP" "bad_rc=$bad_rc header_rc=$header_rc"
      printf "%s\n" kind=ship spawn_gen=gen-1 > "$state/task.meta"
      pipeline_meta_cache_load "$state/task.meta" 1
      dispatched_rc=0
      pipeline_predicate_dispatched "$state/task.meta" || dispatched_rc=$?
      printf "predicate_dispatched_rc=%s\n" "$dispatched_rc"
      printf "derived=%s\n" "$(pipeline_derived_step task "$state/task.meta" ship)"
      printf "%s\n" pr=https://github.com/example/project/pull/7 >> "$state/task.meta"
      pipeline_meta_cache_load "$state/task.meta" 1
      registered_rc=0
      pipeline_predicate_pr_registered "$state/task.meta" || registered_rc=$?
      printf "predicate_registered_rc=%s\n" "$registered_rc"
      printf "derived=%s\n" "$(pipeline_derived_step task "$state/task.meta" ship)"
      fm_pr_poll_merge_mark_notified "$state" task github github.com example/project 7
      merged_rc=0
      pipeline_predicate_merged task "$state/task.meta" || merged_rc=$?
      printf "predicate_merged_rc=%s\n" "$merged_rc"
      printf "derived=%s\n" "$(pipeline_derived_step task "$state/task.meta" ship)"
      tsv=$(pipeline_kind_steps ship)
      tab=$(printf "\\t")
      IFS="$tab" read -r nodes edges <<EOF
$tsv
EOF
      printf "tsv=%s|%s\n" "$nodes" "$edges"
      printf "kind=ship\tinvented\nspawn_gen=actual\n" > "$state/tab.meta"
      tab_rc=0
      pipeline_meta_cache_load "$state/tab.meta" 1 || tab_rc=$?
      printf "tab_rc=%s\n" "$tab_rc"
    ' _ "$SCRIPT" "$root/state")
  assert_contains "$output" 'record_rc=0 step=dispatched' "record parser unit did not accept the valid line"
  assert_contains "$output" 'bad_rc=1 header_rc=2' "record/header unit refusals were not exercised"
  assert_contains "$output" 'derived=dispatched' "step derivation unit missed dispatch"
  assert_contains "$output" 'predicate_dispatched_rc=0' "dispatched predicate unit failed"
  assert_contains "$output" 'predicate_registered_rc=0' "PR predicate unit failed"
  assert_contains "$output" 'predicate_merged_rc=0' "merge predicate unit failed"
  assert_contains "$output" 'derived=pr-registered' "step derivation unit missed PR registration"
  assert_contains "$output" 'derived=merged' "step derivation unit missed merge proof"
  assert_contains "$output" 'tsv=dispatched ingress working validating pr-registered checks merge-wait merged|dispatched>ingress ingress>working working>validating validating>pr-registered pr-registered>checks checks>merge-wait merge-wait>merged' "TSV step graph unit did not preserve both fields"
  assert_contains "$output" 'tab_rc=2' "scalar parser unit did not reject a tab"
  pass "fm-pipeline.sh: pure record, derivation, header, and scalar units pass"
}

test_pipeline_restart_recovery() {
  local root fakebin ready hold target writer pgid lock_pid before after event_size event_tmp temp candidate orphan_before orphan_after header revs board output rc=0 i=0
  root=$(new_state restart-recovery)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the complete pre-crash record"
  before=$(shasum -a 256 "$root/state/task.pipeline")
  printf '%s\n' 'pr=https://github.com/example/project/pull/7' >> "$root/state/task.meta"
  fakebin="$root/fake-bin"
  ready="$root/mv-ready"
  hold="$root/mv-hold"
  target="$root/state/task.pipeline"
  mkdir -p "$fakebin"
  : > "$ready"
  mkfifo "$hold" || fail "could not create the writer barrier"
  cat > "$fakebin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "${4:-}" = "${FM_PIPELINE_TEST_RECORD_TARGET:-}" ]; then
  awk 'NR == 3 { sub(/ts=[^ ]+/, "ts=2099-01-01T00:00:00Z") } { print }' "$3" > "$3.changed"
  /bin/mv -- "$3.changed" "$3"
  printf '%s\n' ready > "$FM_PIPELINE_TEST_MV_READY"
  cat "$FM_PIPELINE_TEST_MV_HOLD" >/dev/null
fi
exec /bin/mv "$@"
EOF
  chmod +x "$fakebin/mv"
  set -m
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" PATH="$fakebin:$PATH" \
    FM_PIPELINE_TEST_RECORD_TARGET="$target" FM_PIPELINE_TEST_MV_READY="$ready" \
    FM_PIPELINE_TEST_MV_HOLD="$hold" "$SCRIPT" reconcile task >"$root/writer.out" 2>"$root/writer.err" &
  writer=$!
  pgid=$(ps -o pgid= -p "$writer" 2>/dev/null | tr -d '[:space:]')
  [ "$pgid" = "$writer" ] || fail "writer did not get a dedicated process group"
  while [ ! -s "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -s "$ready" ] || fail "writer never reached the temp-to-record barrier"
  [ -d "$root/state/pipeline-events.log.lock" ] || fail "writer lock was absent before restart"
  lock_pid=$(cat "$root/state/pipeline-events.log.lock/pid")
  [ "$lock_pid" = "$writer" ] || fail "writer lock did not name the fixture writer"
  kill -KILL -- "-$pgid" 2>/dev/null || fail "could not kill the fixture writer process group"
  wait "$writer" 2>/dev/null || true
  set +m
  after=$(shasum -a 256 "$target")
  [ "$after" = "$before" ] || fail "killed writer changed the canonical record"
  temp=
  for candidate in "$root/state"/.fm-pipeline-record.*; do
    [ -f "$candidate" ] || continue
    temp=$candidate
    break
  done
  [ -n "$temp" ] || fail "killed writer did not leave its private temp"
  orphan_before=$(shasum -a 256 "$temp" | awk '{print $1}')
  assert_contains "$(cat "$temp")" 'ts=2099-01-01T00:00:00Z' "the abandoned temp was not a valid distinguishable record"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 0 "$rc" "reconcile should recover after the writer process tree was killed"
  assert_contains "$output" 'step=pr-registered rev=2' "restart recovery did not append the intended next step"
  assert_not_contains "$(cat "$target")" 'ts=2099-01-01T00:00:00Z' "the orphan timestamp reached the canonical record"
  orphan_after=$(shasum -a 256 "$temp" | awk '{print $1}')
  [ "$orphan_after" = "$orphan_before" ] || fail "recovery consumed or changed the abandoned temp"
  header=$(head -n 1 "$target")
  [ "$header" = 'schema=fm-pipeline.v3 task=task kind=ship gen=gen-1' ] || fail "restart recovery changed the canonical header"
  revs=$(awk 'NR > 1 { print $1 }' "$target")
  [ "$revs" = $'rev=1\nrev=2' ] || fail "restart recovery did not preserve the exact rev sequence"
  [ "$(wc -l < "$target" | tr -d ' ')" -eq 3 ] || fail "restart recovery produced duplicate or missing record lines"
  [ ! -d "$root/state/pipeline-events.log.lock" ] || fail "stale owner lock was not reclaimed"

  root=$(new_state restart-corruption)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the corruption-control record"
  printf '%s' 'rev=2 ts=2026-09-05T00:00:00Z step=dispatched evidence=meta:' >> "$root/state/task.pipeline"
  before=$(shasum -a 256 "$root/state/task.pipeline")
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "a truncated canonical record must refuse"
  assert_contains "$output" 'refused:malformed-record-line' "truncated record refusal was not named"
  assert_contains "$output" 'repair:' "truncated record refusal omitted repair guidance"
  [ "$(shasum -a 256 "$root/state/task.pipeline")" = "$before" ] \
    || fail "malformed record refusal changed canonical bytes"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[] | select(.id == "task") | .record_state == "refused:malformed-record-line" and .step_proven == false' >/dev/null \
    || fail "board-json did not project the corruption refusal"

  root=$(new_state restart-event-tail)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf '%s\n' 'paused: [key=tail] waiting for the fixture' > "$root/state/task.status"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe >/dev/null \
    || fail "could not create the event-tail fixture"
  before=$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')
  [ "$before" -gt 0 ] || fail "event-tail fixture did not create an event"
  event_size=$(wc -c < "$root/state/pipeline-events.log" | tr -d ' ')
  event_tmp="$root/state/pipeline-events.log.partial"
  head -c $((event_size - 8)) "$root/state/pipeline-events.log" > "$event_tmp"
  mv -- "$event_tmp" "$root/state/pipeline-events.log"
  rc=0
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a partial event tail should not stop the next append"
  assert_contains "$output" 'malformed shadow event' "partial event tail was not reported by name"
  after=$(wc -l < "$root/state/pipeline-events.log" | tr -d ' ')
  [ "$after" -eq $((before + 1)) ] || fail "next event merged into the partial log tail"
  [ "$(tail -c 1 "$root/state/pipeline-events.log" | od -An -tx1 | tr -d '[:space:]')" = 0a ] \
    || fail "event log did not end on a complete line"

  root=$(new_state restart-tail-read)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  printf '%s\n' 'paused: [key=tail] waiting for the fixture' > "$root/state/task.status"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" probe >/dev/null \
    || fail "could not create the tail-read fixture"
  before=$(shasum -a 256 "$root/state/pipeline-events.log")
  fakebin="$root/fake-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tail" <<'EOF'
#!/usr/bin/env bash
exit 23
EOF
  chmod +x "$fakebin/tail"
  rc=0
  output=$(PATH="$fakebin:$PATH" FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 1 "$rc" "a tail read failure must refuse the append"
  assert_contains "$output" 'cannot append event log' "tail read failure was not surfaced"
  [ "$(shasum -a 256 "$root/state/pipeline-events.log")" = "$before" ] \
    || fail "tail read failure changed the event log"
  pass "fm-pipeline.sh: killed-writer restart, corruption refusal, and partial-log recovery pass"
}

test_reconcile_serializes_owner_transaction() {
  local root gate second_ready p1 p2 rc1 rc2
  root=$(new_state reconcile-transaction)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the initial dispatch record"
  printf '%s\n' 'pr=https://github.com/example/project/pull/7' >> "$root/state/task.meta"
  gate="$root/reconcile-gate"
  : > "$gate"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/first.out" 2>"$root/first.err") &
  p1=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "first reconcile did not reach the owner gate"
  second_ready="$root/second.ready"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_BEFORE_LOCK_READY="$second_ready" \
    "$SCRIPT" reconcile task >"$root/second.out" 2>"$root/second.err") &
  p2=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$second_ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$second_ready" ] || fail "second reconcile did not reach the lock boundary"
  rm -f "$gate"
  rc1=0; rc2=0
  wait "$p1" || rc1=$?
  wait "$p2" || rc2=$?
  expect_code 0 "$rc1" "the first serialized reconcile should succeed"
  expect_code 0 "$rc2" "the second serialized reconcile should succeed"
  [ "$(rg -c '^rev=' "$root/state/task.pipeline")" -eq 2 ] \
    || fail "serialized reconciles did not produce exactly one new revision"
  assert_contains "$(cat "$root/second.out")" 'unchanged: task step=pr-registered rev=2' \
    "the losing reconcile did not observe the committed revision"
  pass "fm-pipeline.sh: reconcile serializes load, derive, and append"
}

test_reconcile_rechecks_metadata_inside_owner_transaction() {
  local root gate output pid rc=0 lines
  root=$(new_state reconcile-meta-race)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the initial record"
  gate="$root/reconcile-gate"
  : > "$gate"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/race.out" 2>&1) &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "metadata race did not reach the owner gate"
  printf '%s\n' 'kind=ship' 'spawn_gen=gen-2' > "$root/state/task.meta.next"
  mv "$root/state/task.meta.next" "$root/state/task.meta"
  rm -f "$gate"
  wait "$pid" || rc=$?
  expect_code 1 "$rc" "a generation replacement must refuse"
  assert_contains "$(cat "$root/race.out")" 'refused:foreign-gen' \
    "generation replacement was not fenced"
  lines=$(rg -c '^rev=' "$root/state/task.pipeline")
  [ "$lines" -eq 1 ] || fail "generation replacement appended a stale revision"

  rm -f "$root/state/task.meta"
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1"
  rm -f "$root/state/task.pipeline"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not reset the metadata race fixture"
  gate="$root/reconcile-remove-gate"
  rm -f "$gate.ready"
  : > "$gate"
  rc=0
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/remove.out" 2>&1) &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "metadata removal did not reach the owner gate"
  rm -f "$root/state/task.meta" "$gate"
  wait "$pid" || rc=$?
  expect_code 1 "$rc" "metadata removal must refuse"
  assert_contains "$(cat "$root/remove.out")" 'refused:absent-meta-not-cleaned' \
    "metadata removal was not fenced"
  [ "$(rg -c '^rev=' "$root/state/task.pipeline")" -eq 1 ] \
    || fail "metadata removal appended a stale revision"
  pass "fm-pipeline.sh: reconcile rechecks metadata under the owner lock"
}

test_reconcile_refuses_same_generation_artifact_change() {
  local root gate output pid rc=0
  root=$(new_state reconcile-artifact-race)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-1" \
    "pr=https://github.com/example/project/pull/7"
  FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task >/dev/null \
    || fail "could not create the registered record"
  gate="$root/reconcile-gate"
  : > "$gate"
  (FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_TEST_RECONCILE_GATE="$gate" "$SCRIPT" reconcile task >"$root/race.out" 2>&1) &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$gate.ready" ]; do sleep 0.01; i=$((i + 1)); done
  [ -e "$gate.ready" ] || fail "artifact race did not reach the refresh boundary"
  printf '%s\n' 'kind=ship' 'spawn_gen=gen-1' > "$root/state/task.meta.next"
  mv "$root/state/task.meta.next" "$root/state/task.meta"
  rm -f "$gate"
  wait "$pid" || rc=$?
  expect_code 1 "$rc" "a same-generation artifact removal must refuse"
  assert_contains "$(cat "$root/race.out")" 'refused:unproven-step' \
    "artifact removal was not checked before record proof"
  [ "$(rg -c '^rev=' "$root/state/task.pipeline")" -eq 1 ] \
    || fail "same-generation artifact removal appended a regressed step"
  pass "fm-pipeline.sh: reconcile proves records against refreshed artifacts"
}

test_meta_scalar_tabs_refuse_before_cache_parse() {
  local root output rc=0
  root=$(new_state scalar-tabs)
  printf 'kind=ship\tinvented\nspawn_gen=actual\n' > "$root/state/task.meta"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile task 2>&1) || rc=$?
  expect_code 1 "$rc" "a tabbed metadata scalar must refuse"
  assert_contains "$output" 'refused:malformed-meta-artifact' \
    "tabbed metadata did not name the malformed scalar"
  [ ! -e "$root/state/task.pipeline" ] || fail "tabbed metadata invented a lifecycle record"
  pass "fm-pipeline.sh: metadata scalar tabs fail before serialization"
}

test_absent_home_reconcile_does_not_recreate_state() {
  local root output rc=0 verb
  root="$TMP_ROOT/missing-home"
  for verb in reconcile retire board-json; do
    rc=0
    if [ "$verb" = board-json ]; then
      output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" "$verb" 2>&1) || rc=$?
    else
      output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" "$verb" task 2>&1) || rc=$?
    fi
    expect_code 1 "$rc" "$verb must refuse a missing home"
    [ ! -e "$root" ] || fail "absent-home $verb recreated the home"
  done
  pass "fm-pipeline.sh: absent-home non-creating verbs preserve state"
}

test_board_filters_observations_by_generation() {
  local root board
  root=$(new_state board-generation)
  fm_write_meta "$root/state/task.meta" "kind=ship" "spawn_gen=gen-new"
  printf '%s\n' \
    'ts=2026-09-05T00:00:00Z task=task kind=ship step=dispatched since=1 probe=stall rule=recheck-external action=would-heal mode=shadow evidence=state/task.status:1 gen=gen-old attempt=- wait=ext:old snap=-' \
    > "$root/state/pipeline-events.log"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks[0].waits == [] and .tasks[0].probe_last == null' >/dev/null \
    || fail "board-json projected an old-generation observation as current"
  pass "fm-pipeline.sh: board observations are generation-fenced"
}

test_board_projects_unknown_and_kind_inconsistent_tasks() {
  local root board output rc=0
  root=$(new_state board-kinds)
  fm_write_meta "$root/state/good.meta" "kind=ship" "spawn_gen=good-gen"
  fm_write_meta "$root/state/bad.meta" "kind=unrecognized" "spawn_gen=bad-gen"
  board=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" board-json)
  printf '%s' "$board" | jq -e '.tasks | length == 2 and any(.[]; .id == "bad" and .record_state == "refused:unknown-pipeline-kind" and .steps.nodes == [])' >/dev/null \
    || fail "board-json did not preserve the unknown kind per task"
  fm_write_meta "$root/state/mate.meta" "kind=secondmate" "spawn_gen=mate-gen"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" reconcile mate 2>&1) || rc=$?
  expect_code 1 "$rc" "secondmate must not invent a dispatched lifecycle step"
  assert_contains "$output" 'refused:no-proven-artifact' "secondmate refusal was not explicit"
  [ ! -e "$root/state/mate.pipeline" ] || fail "secondmate received a ship lifecycle record"
  pass "fm-pipeline.sh: board and reconcile honor per-kind lifecycle graphs"
}

test_registered_check_reaches_watcher() {
  local dir state fakebin out pid i
  dir=$(make_case pipeline-watcher)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$state/task.status"
  printf 'kind=ship\nstep=working\nspawn_gen=gen-1\n' > "$state/task.meta"
  prime_status_seen "$state" "$state/task.status" || fail "could not prime the task status marker"

  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_PIPELINE_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$state/pipeline-events.log" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -s "$state/pipeline-events.log" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not invoke the registered pipeline check"
  fi
  [ -f "$state/pipeline-probe.check.sh" ] || fail "watcher did not create the pipeline check"
  [ -f "$state/pipeline-probe.check-trust" ] || fail "watcher did not register the pipeline check"
  printf 'done: finished\n' >> "$state/task.status"
  wait_for_exit "$pid" 40 || fail "watcher did not exit after the integration signal"
  grep -F 'wait=ext:vendor-release' "$state/pipeline-events.log" >/dev/null \
    || fail "watcher invocation did not produce a pipeline event"
  rg -F 'step=dispatched' "$state/task.pipeline" >/dev/null \
    || fail "watcher invocation did not reconcile the lifecycle record"
  pass "fm-watch.sh: registered pipeline check reaches the probe and reconciles"
}

test_line_format_and_unknown_preservation
test_would_heal_without_evidence_is_rejected
test_append_rejects_malformed_fields
test_event_log_symlink_is_rejected
test_stale_wait_is_shadow_only
test_working_does_not_contradict_keyed_wait
test_parked_does_not_contradict_keyed_wait
test_resumed_wait_is_not_reprobed
test_note_preserves_active_wait
test_configured_pause_verb_is_supported
test_all_active_waits_are_probed_independently
test_pause_key_sentinels_remain_distinct
test_valid_invalid_slug_remains_distinct
test_explicit_default_key_remains_distinct
test_stale_event_lock_is_recovered
test_task_paths_are_confined
test_arm_preserves_existing_check_on_registration_failure
test_relative_arm_embeds_absolute_state
test_registered_check_reaches_watcher
 test_reconcile_ignores_status_testimony
 test_append_is_not_agent_facing
 test_legacy_cache_migrates_without_reinterpretation
 test_board_json_does_not_migrate_legacy_cache
 test_legacy_cache_migration_collision_refuses
 test_probe_reads_owner_record_not_meta_step_claim
 test_reconcile_absent_meta_refuses_without_writing
 test_record_reader_rejects_unproven_hand_append
 test_foreign_generation_is_refused
 test_pr_registration_and_merge_artifacts
 test_steps_print_ordered_graph
 test_probe_cost_fixture_preserves_sensor_call_count
 test_board_json_fixture_inventory_and_bound
 test_quiet_registered_probe_and_refusal_projection
 test_retire_owner_records
 test_pipeline_pure_function_units
 test_pipeline_restart_recovery
 test_reconcile_serializes_owner_transaction
 test_reconcile_rechecks_metadata_inside_owner_transaction
 test_reconcile_refuses_same_generation_artifact_change
 test_meta_scalar_tabs_refuse_before_cache_parse
 test_absent_home_reconcile_does_not_recreate_state
 test_board_filters_observations_by_generation
 test_board_projects_unknown_and_kind_inconsistent_tasks
