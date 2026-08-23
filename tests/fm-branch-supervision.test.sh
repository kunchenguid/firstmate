#!/usr/bin/env bash
# Tests for the Pi supervision branch's fleet-record layer
# (docs/pi-supervision-branch.md): the byte-stable branch prompt generator
# (bin/fm-branch-prompt.sh), the append-only outcome store
# (bin/fm-branch-outcome.sh), the per-task lease contract (bin/fm-lease.sh,
# bin/fm-lease-lib.sh), the lease and role-partition guards wired into the
# mutating entrypoints, and the proof that a home which never runs the branch
# is untouched by all of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-supervision)

# --- byte-stable branch prompt ------------------------------------------------

test_branch_prompt_is_byte_stable_and_above_cache_floor() {
  local home_a home_b out_a out_b out_c size
  home_a="$TMP_ROOT/prompt-home-a"
  home_b="$TMP_ROOT/prompt-home-b"
  mkdir -p "$home_a/state" "$home_b/state"
  # Give the two homes deliberately different fleet state and clock context:
  # a byte-stable prompt must not absorb any of it.
  printf 'signal: task-1 done\n' > "$home_a/state/task-1.status"
  printf 'window=x\nharness=pi\n' > "$home_a/state/task-1.meta"

  out_a=$(cd "$TMP_ROOT" && FM_HOME="$home_a" TZ=UTC "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home A"
  out_b=$(cd / && FM_HOME="$home_b" TZ=Australia/Eucla "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home B"
  sleep 1
  out_c=$("$ROOT/bin/fm-branch-prompt.sh") || fail "branch prompt generator failed on re-run"

  [ "$out_a" = "$out_b" ] || fail "branch prompt differs across homes/cwd/timezone: prefix stability broken"
  [ "$out_a" = "$out_c" ] || fail "branch prompt differs across runs at different times: prefix stability broken"

  # Below the provider's 1024-token caching minimum a branch prompt gets no
  # cache reuse at all (measured in the feasibility evidence), so hold a
  # comfortable byte floor.
  size=${#out_a}
  [ "$size" -ge 5000 ] || fail "branch prompt is only $size bytes - below the provider caching minimum"
  case "$out_a" in
    "You are the SUPERVISION BRANCH"*) ;;
    *) fail "branch prompt lost its role preamble" ;;
  esac
  case "$out_a" in
    *"stuck-crewmate-recovery"*) ;;
    *) fail "branch prompt lost the inlined recovery playbook" ;;
  esac
  pass "branch prompt is byte-stable across homes, cwd, timezone, and time, above the cache floor"
}

# --- append-only outcome store ------------------------------------------------

test_outcome_store_is_append_only_with_cursor_reads() {
  local home store snapshot seq1 seq2 unread replay out status
  home="$TMP_ROOT/store-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"

  seq1=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'worker healthy, "quoted" text kept' --wake 'signal: working') \
    || fail "first append failed"
  [ "$seq1" = 1 ] || fail "first outcome seq was $seq1, not 1"
  seq2=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'PR https://example.com/pr/2 checks green') \
    || fail "second append failed"
  [ "$seq2" = 2 ] || fail "second outcome seq was $seq2, not 2"

  # The store is the owned durable contract: every line stays valid JSON.
  python3 - "$store" <<'PY' || fail "outcome store holds invalid JSON"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row["seq"] for row in rows] == [1, 2], rows
assert rows[0]["verdict"] == "routine" and rows[1]["verdict"] == "captain", rows
assert rows[0]["summary"] == 'worker healthy, "quoted" text kept', rows[0]
PY

  # mark-read moves only the cursor sidecar; the log bytes never change.
  snapshot=$(cat "$store")
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 || fail "mark-read failed"
  unread=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "unread failed"
  case "$unread" in
    '{"seq":2,'*) ;;
    *) fail "unread did not return exactly the records above the cursor: $unread" ;;
  esac
  [ "$(cat "$store")" = "$snapshot" ] || fail "mark-read rewrote the append-only store"

  # startup-replay surfaces the unread remainder once, then goes silent, and
  # later appends land strictly after the earlier bytes (append-only merge).
  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "startup-replay failed"
  assert_contains "$replay" "BRANCH OUTCOMES" "replay lost its section header"
  assert_contains "$replay" "https://example.com/pr/2" "replay lost the unread outcome"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay)" ] \
    || fail "startup-replay re-presented already-read outcomes"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-3 --verdict routine --summary 'later outcome' >/dev/null || fail "third append failed"
  case "$(cat "$store")" in
    "$snapshot"*) ;;
    *) fail "a later append disturbed earlier store bytes" ;;
  esac

  printf '{"seq":4,"epoch":' >> "$store"
  snapshot=$(cat "$store")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-5 --verdict captain --summary 'must remain unrecorded' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append accepted a malformed outcome-store tail"
  assert_contains "$out" "malformed final record" "torn-tail refusal lost its diagnostic"
  [ "$(cat "$store")" = "$snapshot" ] || fail "failed append changed the torn outcome store"
  pass "outcome store is append-only and refuses sequence reuse after a torn tail"
}

# --- lease contract -----------------------------------------------------------

test_lease_exclusivity_release_stale_and_sweep() {
  local home out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/lease-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"

  # Claim, exclusivity, same-actor refresh.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 --actor branch \
    || fail "branch claim failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1) || fail "check missed a held lease"
  case "$out" in
    "branch $$ "*" live") ;;
    *) fail "check misreported the lease: $out" ;;
  esac
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "cross-actor claim exited $status, not the lease refusal 6"
  assert_contains "$out" "leased to the branch supervision actor" "refusal did not name the holder"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 \
    || fail "same-actor refresh was refused"

  # Release by the calling holder; release of an unheld lease stays a silent no-op.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "release failed"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1 >/dev/null && fail "released lease still reported"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "idempotent release failed"

  # A lease held by a dead process is stale: claimable by the other actor and
  # removed by the sweep, while a live lease survives the sweep.
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-dead \
    || fail "stale lease blocked a live claim"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-dead)
  case "$out" in "main $$ "*) ;; *) fail "stale lease was not taken over: $out" ;; esac
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead2"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep failed"
  [ ! -e "$home/state/.lease-task-dead2" ] || fail "sweep left a provably stale lease"
  [ -e "$home/state/.lease-task-dead" ] || fail "sweep removed a live lease"

  # The reserved backlog resource claims like any task.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog --actor branch \
    || fail "backlog lease claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog 2>&1)
  [ $? -eq 6 ] || fail "backlog lease did not enforce exclusivity"
  pass "lease exclusivity, same-actor refresh, release, staleness, and sweep hold"
}

# --- guards in the mutating entrypoints ---------------------------------------

test_mutating_scripts_refuse_the_other_actors_lease() {
  local home root out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/guard-home"
  root="$TMP_ROOT/guard-root"
  mkdir -p "$home/state" "$root"
  printf '%s\n' "$$" > "$home/state/.lock"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-held --actor branch \
    || fail "fixture lease claim failed"

  # fm-control: refused while the branch holds the lease; the ordinary no-task
  # error (a different failure) proves pass-through once the lease is gone.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-held interrupt 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "leased fm-control exited $status, not 6: $out"
  assert_contains "$out" "leased to the branch supervision actor" "fm-control refusal lost the holder"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-unheld interrupt 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "unleased fm-control still hit the lease refusal"
  assert_contains "$out" "no task 'task-unheld'" "unleased fm-control lost its ordinary error"

  # fm-teardown: same refusal shape before any teardown work.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" task-held 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "leased fm-teardown exited $status, not 6: $out"
  assert_contains "$out" "teardown (fm-teardown) refused" "fm-teardown refusal lost its action label"

  # The same lease refuses the BRANCH actor when MAIN holds it - the guard is
  # symmetric, not a branch-only fence.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-held --actor branch
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-held --actor main \
    || fail "main fixture claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-control.sh" task-held interrupt 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch actor bypassed main's lease: $status: $out"
  assert_contains "$out" "leased to the main supervision actor" "symmetric refusal lost the holder"
  pass "fm-control and fm-teardown refuse the other actor's live lease and pass through otherwise"
}

test_main_owned_actions_refuse_the_branch_actor() {
  local home root out status
  home="$TMP_ROOT/partition-home"
  root="$TMP_ROOT/partition-root"
  mkdir -p "$home/state" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-pr-merge.sh" task-x https://github.com/o/r/pull/1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-pr-merge exited $status, not 6: $out"
  assert_contains "$out" "the supervision branch never performs this action" "pr-merge refusal lost the partition wording"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-merge-local.sh" task-x 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-merge-local exited $status, not 6: $out"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-spawn.sh" task-new --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch fm-spawn exited $status, not 6: $out"
  assert_contains "$out" "new-task spawn (fm-spawn) refused" "spawn refusal lost its action label"

  # The same calls as MAIN fail on their ORDINARY validation instead - the
  # partition guard never fires for the main actor.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-merge-local.sh" task-x 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "main fm-merge-local hit the partition refusal"
  assert_contains "$out" "no meta for task task-x" "main fm-merge-local lost its ordinary error"
  pass "PR merge, local landing, and new-task spawn refuse the branch actor and spare main"
}

test_home_without_branch_is_untouched() {
  local home out status
  home="$TMP_ROOT/untouched-home"
  mkdir -p "$home/state"

  # No lease files, no actor variable: the guard layer must be invisible - the
  # scripts fail (or succeed) exactly on their pre-existing logic, and nothing
  # branch-related appears in state/.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-control.sh" task-any interrupt 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "no-branch home hit a lease refusal in fm-control"
  assert_contains "$out" "no task 'task-any'" "no-branch fm-control lost its ordinary error"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-pr-merge.sh" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "no-branch fm-pr-merge usage error changed: $status: $out"
  [ -z "$(find "$home/state" -name '.lease-*' -o -name 'branch-outcomes*' -o -name '.branch-*' 2>/dev/null)" ] \
    || fail "guard layer created branch state in a home that never ran the branch"

  # A stale Pi marker and recycled-but-live lease pid cannot activate leases in
  # a no-lock Claude home; the guard removes the leftover and passes silently.
  printf 'harness=claude\n' > "$home/state/fake.meta"
  printf '%s\n' "$PPID" > "$home/state/.pi-branch-extension-loaded"
  printf 'branch\t%s\t123\n' "$PPID" > "$home/state/.lease-task-reused"
  out=$(STATE="$home/state" bash -c '. "$1"; fm_lease_guard task-reused "probe"; fm_lease_forbid_branch "probe"; echo silent-pass' _ "$ROOT/bin/fm-lease-lib.sh" 2>&1)
  [ "$out" = "silent-pass" ] || fail "guard helpers honored a leftover Pi lease in a no-lock Claude home: $out"
  [ ! -e "$home/state/.lease-task-reused" ] || fail "guard kept a leftover Pi lease without a session lock"

  printf '%s\n' "$PPID" > "$home/state/.lock"
  printf 'branch\t%s\t123\n' "$PPID" > "$home/state/.lease-task-reused"
  # The positional parameter belongs to the nested shell.
  # shellcheck disable=SC2016
  out=$(env -u PI_CODING_AGENT -u FM_SUPERVISION_ACTOR CLAUDECODE=1 STATE="$home/state" bash -c '. "$1"; fm_lease_guard task-reused "probe"; echo silent-pass' _ "$ROOT/bin/fm-lease-lib.sh" 2>&1)
  [ "$out" = "silent-pass" ] || fail "guard helpers honored a reused-pid Pi lease in a Claude context: $out"
  [ ! -e "$home/state/.lease-task-reused" ] || fail "Claude context kept a Pi lease whose old pid matched its current lock"
  pass "a non-Pi home ignores stale Pi leases even when the recycled pid owns its lock"
}

# --- session-bound staleness and the loud accidental-override guard ---------

test_lease_liveness_binds_to_the_session_lock() {
  local home out
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/lock-bound-home"
  mkdir -p "$home/state"

  # A lease recorded by a pid that is alive but is NOT the current session-lock
  # holder is stale: a Pi session exited and its pid was recycled, or a non-Pi
  # harness now owns this home. Either way the leftover lease must not bind.
  printf '%s\n' "$$" > "$home/state/.lock.other"
  printf 'branch\t%s\t123\n' "$PPID" > "$home/state/.lease-task-reused"
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-reused) || fail "check missed the leftover lease"
  case "$out" in
    *" stale") ;;
    *) fail "an alive non-lock-holder pid read as live: $out" ;;
  esac
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep failed"
  [ ! -e "$home/state/.lease-task-reused" ] || fail "sweep kept a lease whose pid is not the lock holder"

  # The same pid IS live while the lock names it.
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-current --actor main \
    || fail "claim under the current lock holder failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-current)
  case "$out" in
    "main $$ "*" live") ;;
    *) fail "the current lock holder's lease did not read live: $out" ;;
  esac

  printf '%sjunk\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-current) || fail "check missed the lease under a malformed lock"
  case "$out" in
    *" stale") ;;
    *) fail "a malformed lock proved lease liveness: $out" ;;
  esac
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep under malformed lock failed"
  [ ! -e "$home/state/.lease-task-current" ] || fail "sweep kept a lease proven only by a malformed lock"
  pass "lease liveness requires an exact valid session-lock pid"
}

test_concurrent_stale_lease_claims_have_one_winner() {
  local home fakebin real_mv branch_pid main_pid branch_status main_status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/concurrent-lease-home"
  fakebin="$TMP_ROOT/concurrent-lease-bin"
  mkdir -p "$home/state" "$fakebin"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-race"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_LEASE_PATH" ] && mkdir "$FM_TEST_GATE.once" 2>/dev/null; then
  : > "$FM_TEST_GATE.ready"
  while [ ! -e "$FM_TEST_GATE.release" ]; do sleep 0.01; done
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    FM_TEST_REAL_MV="$real_mv" FM_TEST_LEASE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor branch >/dev/null 2>&1 &
  branch_pid=$!
  while [ ! -e "$home/state/gate.ready" ]; do sleep 0.01; done
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ \
    FM_TEST_REAL_MV="$real_mv" FM_TEST_LEASE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor main >/dev/null 2>&1 &
  main_pid=$!
  sleep 0.1
  : > "$home/state/gate.release"
  wait "$branch_pid"; branch_status=$?
  wait "$main_pid"; main_status=$?
  [ "$branch_status" -eq 0 ] || fail "first serialized lease claim failed with $branch_status"
  [ "$main_status" -eq 6 ] || fail "concurrent lease claim also succeeded or returned $main_status"
  pass "concurrent stale-lease claims serialize so exactly one actor succeeds"
}

test_guard_stale_clear_cannot_delete_a_new_claim() {
  local home fakebin real_rm guard_pid claim_pid guard_status claim_status out
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/guard-claim-race-home"
  fakebin="$TMP_ROOT/guard-claim-race-bin"
  mkdir -p "$home/state" "$fakebin"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'main\t999999\t123\n' > "$home/state/.lease-task-race"
  real_rm=$(command -v rm)
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_STALE_PATH" ] && mkdir "$FM_TEST_GATE.once" 2>/dev/null; then
  : > "$FM_TEST_GATE.ready"
  while [ ! -e "$FM_TEST_GATE.release" ]; do sleep 0.01; done
fi
exec "$FM_TEST_REAL_RM" "$@"
SH
  chmod +x "$fakebin/rm"

  PATH="$fakebin:$PATH" STATE="$home/state" FM_TEST_REAL_RM="$real_rm" \
    FM_TEST_STALE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    bash -c '. "$1"; fm_lease_guard task-race "probe"' _ "$ROOT/bin/fm-lease-lib.sh" &
  guard_pid=$!
  while [ ! -e "$home/state/gate.ready" ]; do sleep 0.01; done
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    FM_TEST_REAL_RM="$real_rm" FM_TEST_STALE_PATH="$home/state/.lease-task-race" FM_TEST_GATE="$home/state/gate" \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor branch >/dev/null 2>&1 &
  claim_pid=$!
  sleep 0.1
  : > "$home/state/gate.release"
  wait "$guard_pid"; guard_status=$?
  wait "$claim_pid"; claim_status=$?
  [ "$guard_status" -eq 0 ] || fail "guard stale cleanup failed with $guard_status"
  [ "$claim_status" -eq 0 ] || fail "serialized claim failed with $claim_status"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-race) || fail "guard deleted the newer lease claim"
  case "$out" in
    "branch $$ "*" live") ;;
    *) fail "newer claim was not preserved as live: $out" ;;
  esac
  pass "guard stale cleanup cannot race with or delete a newer lease claim"
}

test_guard_holds_exclusivity_through_mutation() {
  local home operation_pid claim_pid claim_status
  home="$TMP_ROOT/guard-mutation-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"

  PI_CODING_AGENT=true STATE="$home/state" FM_TEST_READY="$home/operation-ready" \
    FM_TEST_RELEASE="$home/operation-release" bash -c '
      . "$1"
      fm_lease_guard task-race "probe"
      trap "fm_lease_guard_release" EXIT
      : > "$FM_TEST_READY"
      while [ ! -e "$FM_TEST_RELEASE" ]; do sleep 0.01; done
    ' _ "$ROOT/bin/fm-lease-lib.sh" &
  operation_pid=$!
  while [ ! -e "$home/operation-ready" ]; do sleep 0.01; done

  PI_CODING_AGENT=true FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$ROOT/bin/fm-lease.sh" claim task-race --actor branch >/dev/null 2>&1 &
  claim_pid=$!
  sleep 0.2
  kill -0 "$claim_pid" 2>/dev/null \
    || fail "the other actor claimed while the guarded mutation was still running"
  [ ! -e "$home/state/.lease-task-race" ] \
    || fail "the concurrent claim published a lease before the guarded mutation ended"

  : > "$home/operation-release"
  wait "$operation_pid" || fail "guarded mutation fixture failed"
  wait "$claim_pid"; claim_status=$?
  [ "$claim_status" -eq 0 ] || fail "claim did not proceed after guarded mutation ended: $claim_status"
  pass "lease guard excludes a concurrent actor for the complete mutation"
}

test_claim_refuses_the_other_actors_name_loudly() {
  local home out status
  home="$TMP_ROOT/claim-guard-home"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ \
    "$ROOT/bin/fm-lease.sh" claim task-z --actor main 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "cross-actor claim exited $status, not 6: $out"
  assert_contains "$out" "cannot claim a lease as main" "accidental-override refusal lost its wording"
  [ ! -e "$home/state/.lease-task-z" ] || fail "refused claim still created a lease"
  pass "a claim naming the other actor fails loudly instead of silently impersonating it"
}

test_release_actor_drops_only_that_actors_leases() {
  local home out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/release-actor-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-a --actor branch \
    || fail "branch claim failed"
  FM_HOME="$home" FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-b --actor main \
    || fail "main claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-b --actor main 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch release of main lease exited $status, not 6: $out"
  assert_contains "$out" "cannot release a lease as main" "cross-actor release refusal lost its diagnostic"
  [ -e "$home/state/.lease-task-b" ] || fail "refused release removed main's lease"

  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release-actor --actor main 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch release-actor of main leases exited $status, not 6: $out"
  assert_contains "$out" "cannot release leases as main" "cross-actor bulk release refusal lost its diagnostic"
  [ -e "$home/state/.lease-task-b" ] || fail "refused bulk release removed main's lease"

  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release-actor --actor branch || fail "release-actor failed"
  [ ! -e "$home/state/.lease-task-a" ] || fail "release-actor kept the branch lease"
  [ -e "$home/state/.lease-task-b" ] || fail "release-actor dropped main's lease"
  pass "release commands authorize the caller and bulk release drops only that actor's leases"
}

# --- role-partition refinements ----------------------------------------------

test_branch_cannot_force_teardown_or_directly_relaunch() {
  local home root out status
  home="$TMP_ROOT/partition2-home"
  root="$TMP_ROOT/partition2-root"
  mkdir -p "$home/state" "$root"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  ln -s "$ROOT/bin" "$root/bin"

  # Forced teardown discards work; the branch never discards anything.
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-teardown.sh" task-x --force 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "branch forced teardown exited $status, not 6: $out"
  assert_contains "$out" "cannot discard work" "forced-teardown refusal lost its wording"
  # An ORDINARY branch teardown is not blocked by this guard (it fails later
  # on its ordinary no-task validation instead).
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-teardown.sh" task-x 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "ordinary branch teardown hit the forced-discard refusal: $out"

  # A branch relaunch is legal only through fm-control's owned transaction,
  # never by direct fm-spawn invocation.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SUPERVISION_ACTOR=branch \
    "$ROOT/bin/fm-spawn.sh" task-x --relaunch 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "direct branch relaunch exited $status, not 6: $out"
  assert_contains "$out" "must relaunch through fm-control" "relaunch refusal lost its wording"
  pass "the branch cannot force a teardown or bypass fm-control for a relaunch"
}

test_branch_prompt_is_byte_stable_and_above_cache_floor
test_outcome_store_is_append_only_with_cursor_reads
test_lease_exclusivity_release_stale_and_sweep
test_mutating_scripts_refuse_the_other_actors_lease
test_main_owned_actions_refuse_the_branch_actor
test_home_without_branch_is_untouched
test_lease_liveness_binds_to_the_session_lock
test_concurrent_stale_lease_claims_have_one_winner
test_guard_stale_clear_cannot_delete_a_new_claim
test_guard_holds_exclusivity_through_mutation
test_claim_refuses_the_other_actors_name_loudly
test_release_actor_drops_only_that_actors_leases
test_branch_cannot_force_teardown_or_directly_relaunch
