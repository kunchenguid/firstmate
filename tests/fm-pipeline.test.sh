#!/usr/bin/env bash
# Behavior tests for the shadow-only external-wait pipeline writer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pipeline.sh"
TMP_ROOT=$(fm_test_tmproot fm-pipeline)

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

new_state() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/worktree"
  printf '%s\n' "$dir"
}

test_line_format_and_unknown_preservation() {
  local root output line rc=0
  root=$(new_state unknown)
  printf 'paused: [key=vendor-release] waiting on vendor\n' > "$root/state/task.status"
  printf 'kind=ship\nworktree=%s/worktree\nharness=tmux\n' "$root" > "$root/state/task.meta"
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
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
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
    output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append "$bad_line" 2>&1) || rc=$?
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
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
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
  cat > "$root/fake-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'state: working · source: pane · pane is active'
EOF
  chmod +x "$root/fake-crew-state.sh"
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" \
    FM_PIPELINE_CREW_STATE_BIN="$root/fake-crew-state.sh" "$SCRIPT" probe 2>&1) || rc=$?
  expect_code 0 "$rc" "a stale declared wait should be observed successfully"
  line=$(tail -1 "$root/state/pipeline-events.log")
  assert_contains "$line" 'probe=stall' "a non-paused authoritative state must be a stall"
  assert_contains "$line" 'rule=recheck-external' "stale waits must identify the shadow rule"
  assert_contains "$line" 'action=would-heal' "stale waits must never execute a heal"
  assert_contains "$line" 'mode=shadow' "stale waits must remain shadow-only"
  assert_contains "$line" 'since=0' "first observations must start their lower-bound duration at zero"
  assert_contains "$line" 'gen=gen-1' "events must use the spawn incarnation"
  [ -f "$root/state/task.pipeline" ] || fail "the first observation was not recorded"
  pass "fm-pipeline.sh: stale waits log a would-heal without acting"
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
  [ "$(grep -c '^wait=ext:' "$root/state/task.pipeline")" -eq 2 ] || fail "wait timings were not kept independently"
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
  output=$(FM_HOME="$root" FM_STATE_OVERRIDE="$root/state" "$SCRIPT" append \
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
  pass "fm-watch.sh: registered pipeline check reaches the probe"
}

test_line_format_and_unknown_preservation
test_would_heal_without_evidence_is_rejected
test_append_rejects_malformed_fields
test_event_log_symlink_is_rejected
test_stale_wait_is_shadow_only
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
