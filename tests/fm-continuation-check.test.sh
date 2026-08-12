#!/usr/bin/env bash
# Public-interface regressions for accepted-work continuation at turn end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-continuation-check)
fm_git_identity fmtest fmtest@example.invalid

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/data" "$dir/state" "$dir/docs"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-continuation-check.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/"
  chmod +x "$dir/bin/"*.sh
}

install_lock_owner_ps() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  700:comm=) printf '%s\n' codex ;;
  700:args=) printf '%s\n' codex ;;
  700:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash bin/fm-turnend-guard.sh' ;;
  *:ppid=) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

run_check() {
  local dir=$1 status
  set +e
  FM_HOME="$dir" "$dir/bin/fm-continuation-check.sh" 2>&1
  status=$?
  set -e
  return "$status"
}

run_guard() {
  local dir=$1 fakebin=$2 payload=${3:-'{"stop_hook_active":false,"session_id":"fixture"}'} status
  [ "$#" -le 3 ] && shift "$#" || shift 3
  set +e
  printf '%s' "$payload" | PATH="$fakebin:$PATH" FM_HOME="$dir" \
    "$dir/bin/fm-turnend-guard.sh" "$@" 2>&1
  status=$?
  set -e
  return "$status"
}

test_accepted_ready_work_forces_continuation() {
  local dir="$TMP_ROOT/ready" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

- [ ] accepted-work - Accepted unfinished work (repo: firstmate) (kind: ship)

## Done
EOF
  set +e
  out=$(run_guard "$dir" "$fakebin"); status=$?
  set -e
  [ "$status" -eq 2 ] || fail "eligible accepted work settled with status $status: $out"
  assert_contains "$out" 'continuation-required: ready=1 ids=accepted-work orphan=0' \
    "turn-end refusal did not identify dispatchable accepted work"
  pass "continuation check: an answer cannot silently settle while accepted work is dispatchable"
}

test_structured_waits_do_not_launch() {
  local dir="$TMP_ROOT/held" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

- [ ] approval - Waiting for Captain approval (repo: firstmate) (kind: ship) (hold: explicit release approval required) (hold-kind: captain)
- [ ] login - Waiting for interactive login (repo: firstmate) (kind: ship) (hold: Captain must complete browser login) (hold-kind: external)
- [ ] capacity - Waiting for worker capacity (repo: firstmate) (kind: ship) (hold: eligible slot unavailable) (hold-kind: load)
- [ ] scheduled - Waiting for date gate (repo: firstmate) (kind: ship) (hold: scheduled release window) (hold-kind: future) (hold-until: 2099-01-01)
- [ ] dependent - Waiting for login blocked-by: login (repo: firstmate) (kind: ship)

## Done
EOF
  set +e
  out=$(run_check "$dir"); status=$?
  set -e
  [ "$status" -eq 0 ] || fail "truthful held work became dispatchable: $out"
  set +e
  out=$(run_guard "$dir" "$fakebin"); status=$?
  set -e
  [ "$status" -eq 0 ] || fail "resource or approval hold forced a launch continuation: $out"
  [ ! -e "$dir/state/spawn-called" ] || fail "continuation check launched held work"
  pass "continuation check: dependency, resource, login, capacity, date, and approval gates remain held"
}

test_completed_work_settles() {
  local dir="$TMP_ROOT/done" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done

- [x] completed - Completed work (repo: firstmate) (kind: ship) (done 2026-08-12)
EOF
  set +e
  out=$(run_guard "$dir" "$fakebin"); status=$?
  set -e
  [ "$status" -eq 0 ] || fail "completed work kept the session alive: $out"
  pass "continuation check: completed work does not keep the session alive"
}

test_new_message_is_additive() {
  local dir="$TMP_ROOT/additive" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

- [ ] earlier-work - Earlier accepted work (repo: firstmate) (kind: ship)

## Done
EOF
  set +e
  out=$(run_guard "$dir" "$fakebin" '{"stop_hook_active":false,"session_id":"answer-one"}'); status=$?
  set -e
  [ "$status" -eq 2 ] || fail "first answer did not retain earlier accepted work: $out"
  set +e
  out=$(run_guard "$dir" "$fakebin" '{"stop_hook_active":false,"session_id":"unrelated-message"}'); status=$?
  set -e
  [ "$status" -eq 2 ] || fail "unrelated later message cancelled earlier accepted work: $out"
  assert_contains "$out" 'ids=earlier-work' "later turn lost the earlier durable item"
  pass "continuation check: a new unrelated Captain message does not cancel earlier accepted work"
}

test_orphan_active_claim_forces_reconciliation() {
  local dir="$TMP_ROOT/orphan" out status
  make_primary "$dir"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

- [ ] claimed-active - Claimed active without a worker (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  set +e
  out=$(run_check "$dir"); status=$?
  set -e
  [ "$status" -eq 2 ] || fail "orphan In flight claim settled with status $status: $out"
  assert_contains "$out" 'ready=0 orphan=1 ids=claimed-active' \
    "orphan active claim was not identified"
  pass "continuation check: an In flight claim without a durable worker owner cannot settle"
}

test_current_progress_must_be_verified() {
  local dir="$TMP_ROOT/current-progress" out status
  make_primary "$dir"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

- [ ] owned-work - Work with worker metadata (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  : > "$dir/state/owned-work.meta"
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'state: unknown · source: none · worker is not active'
SH
  chmod +x "$dir/bin/fm-crew-state.sh"
  set +e
  out=$(run_check "$dir"); status=$?
  set -e
  [ "$status" -eq 2 ] || fail "inactive worker metadata settled as progress: $out"
  assert_contains "$out" 'inactive=1 ids=owned-work' "inactive current state was not identified"

  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'state: working · source: pane · semantic worker progress'
SH
  chmod +x "$dir/bin/fm-crew-state.sh"
  set +e
  out=$(run_check "$dir"); status=$?
  set -e
  [ "$status" -eq 0 ] || fail "verified current worker progress did not settle: $out"
  pass "continuation check: worker metadata counts only with verified current progress"
}

test_lock_refusal_stays_inert() {
  local dir="$TMP_ROOT/foreign-lock" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '999\n' > "$dir/state/.lock"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

- [ ] accepted-work - Accepted unfinished work (repo: firstmate) (kind: ship)

## Done
EOF
  set +e
  out=$(run_guard "$dir" "$fakebin"); status=$?
  set -e
  [ "$status" -eq 0 ] || fail "foreign-lock session competed for continuation: $out"
  pass "continuation check: a lock-refused session remains inert"
}

# Watcher recovery strictly outranks accepted-work continuation. A continuation
# prompt must never preempt the blind-turn block nor let its bounded
# stop_hook_active allowance settle a turn that supervision would refuse
# (docs/turnend-guard.md, 2026-07-21 blind window).
queued_backlog() {
  cat > "$1/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

- [ ] accepted-work - Accepted unfinished work (repo: firstmate) (kind: ship)

## Done
EOF
}

assert_blind_turn_block() {
  local out=$1 status=$2 label=$3
  [ "$status" -eq 2 ] || fail "$label settled with status $status: $out"
  assert_contains "$out" 'TURN WOULD END BLIND - SUPERVISION IS OFF' \
    "$label did not emit the supervision block"
  case "$out" in
    *'ACCEPTED WORK STILL NEEDS RECONCILIATION'*)
      fail "$label emitted the continuation banner instead of the supervision block"
      ;;
  esac
}

test_supervision_outranks_continuation_when_suppressed() {
  local dir="$TMP_ROOT/blind-suppressed" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  : > "$dir/state/task1.meta"
  queued_backlog "$dir"
  set +e
  out=$(run_guard "$dir" "$fakebin" '{"stop_hook_active":true,"session_id":"fixture"}' --claude)
  status=$?
  set -e
  assert_blind_turn_block "$out" "$status" \
    "a Claude stop with stop_hook_active=true, work in flight and no live watcher"
  pass "turn-end guard: continuation cannot suppress the blind-turn block via stop_hook_active"
}

test_supervision_outranks_continuation_when_not_suppressed() {
  local dir="$TMP_ROOT/blind-open" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  : > "$dir/state/task1.meta"
  queued_backlog "$dir"
  set +e
  out=$(run_guard "$dir" "$fakebin" '{"stop_hook_active":false,"session_id":"fixture"}' --claude)
  status=$?
  set -e
  assert_blind_turn_block "$out" "$status" \
    "a Claude stop with a dead watcher and dispatchable accepted work"
  pass "turn-end guard: continuation cannot preempt the watcher-repair instruction"
}

test_continuation_still_fires_once_supervision_resolves() {
  local dir="$TMP_ROOT/supervised" fakebin out status
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  queued_backlog "$dir"
  set +e
  out=$(run_guard "$dir" "$fakebin" '{"stop_hook_active":false,"session_id":"fixture"}' --claude)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail "accepted work settled once supervision resolved: $out"
  assert_contains "$out" 'ACCEPTED WORK STILL NEEDS RECONCILIATION' \
    "continuation did not fire on a path where supervision is satisfied"
  pass "turn-end guard: accepted-work continuation still blocks once supervision resolves"
}

# `tasks-axi ready` reports delivery-ready public-followup obligations in a
# separate ready_public_followups group and documents them as never
# dispatchable; its `count:` line excludes them. The continuation line must
# therefore draw its ids from the ordinary ready group only, or it names an item
# the tool refuses to dispatch under a banner telling Firstmate to dispatch it.
# The obligation here is built through the real tasks-axi CLI, so this asserts
# against the tool's genuine output rather than a hand-written imitation.
build_delivery_ready_obligation() { # <dir>
  local dir=$1
  cat > "$dir/ctx.json" <<'EOF'
{"request_id":"req-1","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_demo"},"public_safe_summary":"demo obligation","received_at":"2026-08-13T00:00:00Z","followup_expires_at":"2099-01-01T00:00:00Z","reservation_expires_at":"2099-01-01T00:00:00Z"}
EOF
  cat > "$dir/final.json" <<'EOF'
{"type":"pr-merged","project":"demo","required_deliverables":["pr_url"],"completion_policy":"all-required"}
EOF
  cat > "$dir/rel.json" <<'EOF'
{"relation_id":"rel-1","work_ref":{"home_id":"main","task_id":"q1"},"role":"fulfills","required":true,"generation":1}
EOF
  cat > "$dir/ev.json" <<'EOF'
{"schema_version":1,"event_id":"ev-1","obligation_id":"pf-1","relation_id":"rel-1","source_home_id":"main","work_id":"q1","generation":1,"outcome_type":"pr-merged","public_safe_outcome":"merged","deliverables":{"pr_url":"https://github.com/o/r/pull/1"},"successor":null,"occurred_at":"2026-08-13T00:00:00Z"}
EOF
  tasks-axi public-followup add pf-1 --file "$dir/data/backlog.md" \
    --request-context-file "$dir/ctx.json" --purpose promised-final \
    --expected-final-file "$dir/final.json" --expires-at 2099-01-01T00:00:00Z >/dev/null 2>&1 || return 1
  tasks-axi public-followup bind-work pf-1 --file "$dir/data/backlog.md" \
    --relation-file "$dir/rel.json" >/dev/null 2>&1 || return 1
  tasks-axi public-followup work-event pf-1 --file "$dir/data/backlog.md" \
    --event-file "$dir/ev.json" >/dev/null 2>&1 || return 1
  tasks-axi ready --file "$dir/data/backlog.md" 2>/dev/null | grep -q '^ready_public_followups\[' || return 1
}

test_public_followups_are_not_listed_as_dispatchable() {
  local dir="$TMP_ROOT/public-followup" fakebin out status
  if ! command -v tasks-axi >/dev/null 2>&1; then
    pass "continuation check: public-followup fixture skipped (tasks-axi unavailable)"
    return 0
  fi
  make_primary "$dir"
  fakebin=$(install_lock_owner_ps "$dir")
  printf '700\n' > "$dir/state/.lock"
  cat > "$dir/data/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

- [ ] q1 - Ordinary queued work (repo: demo) (kind: ship)

## Done
EOF
  if ! build_delivery_ready_obligation "$dir"; then
    fail "could not build a delivery-ready public-followup obligation via tasks-axi"
  fi

  set +e
  out=$(run_guard "$dir" "$fakebin"); status=$?
  set -e
  [ "$status" -eq 2 ] || fail "ordinary queued work settled with status $status: $out"
  assert_contains "$out" 'ready=1 ids=q1 orphan=0' \
    "continuation line did not report exactly the ordinary dispatchable item"
  case "$out" in
    *pf-1*) fail "continuation line named a never-dispatchable public-followup obligation: $out" ;;
  esac
  pass "continuation check: delivery-ready public-followup obligations stay out of the dispatch list"
}

test_accepted_ready_work_forces_continuation
test_structured_waits_do_not_launch
test_completed_work_settles
test_new_message_is_additive
test_orphan_active_claim_forces_reconciliation
test_current_progress_must_be_verified
test_lock_refusal_stays_inert
test_supervision_outranks_continuation_when_suppressed
test_supervision_outranks_continuation_when_not_suppressed
test_continuation_still_fires_once_supervision_resolves
test_public_followups_are_not_listed_as_dispatchable
