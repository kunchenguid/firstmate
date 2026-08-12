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
  set +e
  printf '%s' "$payload" | PATH="$fakebin:$PATH" FM_HOME="$dir" \
    "$dir/bin/fm-turnend-guard.sh" 2>&1
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

test_accepted_ready_work_forces_continuation
test_structured_waits_do_not_launch
test_completed_work_settles
test_new_message_is_additive
test_orphan_active_claim_forces_reconciliation
test_current_progress_must_be_verified
test_lock_refusal_stays_inert
