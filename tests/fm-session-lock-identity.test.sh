#!/usr/bin/env bash
# tests/fm-session-lock-identity.test.sh - durable session-identity binding for
# the fleet lock (bin/fm-session-lock-lib.sh, bin/fm-lock.sh).
#
# The defect these cases pin: process ancestry is not a stable session identity.
# Claude Code serves one session's hooks and tool calls from more than one worker
# pool, and a pool whose top process has been reparented to init yields a
# contiguous harness run that never reaches the session's own lineage. The
# session that acquired the lock through a pool that COULD reach it can then
# never prove ownership again, and every mutating session-start step is skipped.
#
# Every case drives the library behind a deterministic fake ps, so the same two
# platform reporting semantics are covered from either host, and the end-to-end
# cases run the REAL bin/fm-lock.sh. The unit cases deliberately assert the
# DIVERGENCE - ancestry refusing while identity accepts - so a future change that
# quietly made ancestry succeed could not leave the case passing vacuously.
# shellcheck disable=SC2016 # single quotes are deliberate: expressions expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-identity)

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# A process table shaped exactly like the measured reparented pool:
#   this process -> claude bg-spare 27316 -> claude bg-pty-host 27305 -> init
# The session that owns the lock is 89187, a live claude that this ancestry
# never reaches. 4242 is a second, unrelated live claude session.
write_reparented_pool_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
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
  89187:comm=) printf '%s\n' claude ;;
  89187:args=) printf '%s\n' 'claude --dangerously-skip-permissions' ;;
  89187:ppid=) printf '%s\n' 82710 ;;
  4242:comm=) printf '%s\n' claude ;;
  4242:args=) printf '%s\n' 'claude' ;;
  4242:ppid=) printf '%s\n' 1 ;;
  5150:comm=) printf '%s\n' bash ;;
  5150:args=) printf '%s\n' bash ;;
  5150:ppid=) printf '%s\n' 1 ;;
  27316:comm=) printf '%s\n' 'claude bg-spare' ;;
  27316:args=) printf '%s\n' 'claude bg-spare --bg-spare /tmp/cc/spare/d6bfe5e1.claim.sock' ;;
  27316:ppid=) printf '%s\n' 27305 ;;
  27305:comm=) printf '%s\n' 'claude bg-pty-host' ;;
  27305:args=) printf '%s\n' 'claude bg-pty-host --bg-pty-host /tmp/cc/spare/d6bfe5e1.pty.sock 200 50' ;;
  27305:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-session-start.sh' ;;
  *:ppid=) printf '%s\n' 27316 ;;
esac
SH
  chmod +x "$1/ps"
}

# Run one library expression with <fakebin> shadowing ps, under session id $3
# and served-session pid $4 (default 27316, the pool process this fixture's
# ancestry really passes through). kill is stubbed so liveness is decided by the
# process table alone.
lib_eval() {  # <fakebin> <expression> [session-id] [claude-pid]
  local fakebin=$1 expr=$2 session=${3-} claude_pid=${4-27316}
  CLAUDE_CODE_SESSION_ID="$session" CLAUDE_PID="$claude_pid" PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

new_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s' "$dir"
}

bind_identity() {  # <state-dir> <pid> <session-id>
  printf 'pid=%s\nsession=%s\n' "$2" "$3" > "$1/.lock.session"
}

SESSION=bebaa84f-3b50-4abc-8d29-6c2751cc722c
OTHER_SESSION=a080589e-8fe8-41c3-bbb5-cd5a8b66a11d

test_owning_session_is_recognized_from_a_reparented_pool() {
  local dir fakebin
  dir=$(new_home reparented-owner)
  fakebin=$(fm_fakebin "$dir/bin")
  write_reparented_pool_ps "$fakebin"
  printf '89187\n' > "$dir/state/.lock"
  bind_identity "$dir/state" 89187 "$SESSION"

  # The divergence itself: ancestry cannot reach 89187 from this pool at all.
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" "$SESSION"; then
    fail "the fixture is vacuous: ancestry reached the lock owner across a reparented pool"
  fi
  lib_eval "$fakebin" "fm_harness_ancestry_pid" "$SESSION" | grep -qx 27305 \
    || fail "the fixture is vacuous: ancestry did not stop at the reparented pool host 27305"

  lib_eval "$fakebin" "fm_session_lock_owned_by_session_identity '$dir/state'" "$SESSION" \
    || fail "the session that acquired the lock was not recognized by its recorded identity"
  lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION" \
    || fail "the owning session was refused ownership from a reparented worker pool"
  pass "session-lock identity: the session that owns the lock is recognized from a reparented worker pool"
}

test_foreign_session_still_fails_closed() {
  local dir fakebin
  dir=$(new_home foreign-session)
  fakebin=$(fm_fakebin "$dir/bin")
  write_reparented_pool_ps "$fakebin"
  printf '89187\n' > "$dir/state/.lock"
  bind_identity "$dir/state" 89187 "$SESSION"

  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$OTHER_SESSION"; then
    fail "a foreign session claimed a home whose lock is bound to another session"
  fi
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" ''; then
    fail "a process carrying no session identity claimed a bound home"
  fi
  pass "session-lock identity: a foreign session and an identity-less process still fail closed"
}

test_inherited_session_environment_never_proves_ownership() {
  local dir fakebin
  dir=$(new_home inherited-environment)
  fakebin=$(fm_fakebin "$dir/bin")
  write_reparented_pool_ps "$fakebin"
  printf '89187\n' > "$dir/state/.lock"
  bind_identity "$dir/state" 89187 "$SESSION"

  # A session identity travels down every child of a tool call, so a process
  # launched by the owning session - a crewmate on a harness that does not
  # overwrite these variables, or any unrelated command started from the same
  # environment - carries the owner's session id without being that session.
  # Its own ancestry names its own harness, so the served-session process the
  # environment claims is nowhere inside it.
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION" 89187; then
    fail "a process that merely inherited the owning session's environment claimed the home"
  fi
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION" ''; then
    fail "an uncorroborated session identity claimed the home"
  fi
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION" 5150; then
    fail "a session identity corroborated by a non-harness process claimed the home"
  fi

  # And such a process must never BIND the home to the identity it inherited.
  command rm -f -- "$dir/state/.lock.session"
  lib_eval "$fakebin" "fm_session_lock_publish_identity '$dir/state' 89187" "$SESSION" 89187 \
    || fail "publishing from an inherited environment reported failure instead of declining"
  [ -e "$dir/state/.lock.session" ] \
    && fail "a process with an inherited session environment bound the home to that session"
  pass "session-lock identity: an inherited session environment neither proves nor binds ownership"
}

test_absent_malformed_and_unbound_locks_fail_closed() {
  local dir fakebin
  dir=$(new_home unbound-locks)
  fakebin=$(fm_fakebin "$dir/bin")
  write_reparented_pool_ps "$fakebin"

  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION"; then
    fail "an absent lock was claimed as owned"
  fi

  # An OLD lock, carrying only a pid and no binding: today's behavior exactly.
  printf '89187\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION"; then
    fail "a legacy pid-only lock naming another live session was claimed as owned"
  fi

  bind_identity "$dir/state" 89187 "$SESSION"
  printf 'not-a-pid\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION"; then
    fail "a malformed lock was claimed as owned"
  fi

  # A binding left behind by a previous owner cannot speak for the current lock.
  printf '4242\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION"; then
    fail "a stale binding naming a different pid was accepted for the current lock"
  fi

  # A dead owner is never owned; it is reclaimed through the acquire path.
  printf '5150\n' > "$dir/state/.lock"
  bind_identity "$dir/state" 5150 "$SESSION"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION"; then
    fail "a lock whose owner is not a live harness was claimed as owned"
  fi
  pass "session-lock identity: absent, malformed, legacy, stale-bound, and dead-owner locks all fail closed"
}

test_two_homes_on_one_machine_stay_independent() {
  local mine theirs fakebin
  mine=$(new_home home-mine)
  theirs=$(new_home home-theirs)
  fakebin=$(fm_fakebin "$mine/bin")
  write_reparented_pool_ps "$fakebin"

  printf '89187\n' > "$mine/state/.lock"
  bind_identity "$mine/state" 89187 "$SESSION"
  printf '4242\n' > "$theirs/state/.lock"
  bind_identity "$theirs/state" 4242 "$OTHER_SESSION"

  lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$mine/state'" "$SESSION" \
    || fail "this session lost ownership of its own home"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$theirs/state'" "$SESSION"; then
    fail "one session claimed a second firstmate home bound to a different session"
  fi
  pass "session-lock identity: two firstmate homes on one machine stay independent"
}

test_binding_is_replaced_not_inherited() {
  local dir fakebin
  dir=$(new_home binding-replaced)
  fakebin=$(fm_fakebin "$dir/bin")
  write_reparented_pool_ps "$fakebin"
  printf '89187\n' > "$dir/state/.lock"
  bind_identity "$dir/state" 89187 "$OTHER_SESSION"

  # A harness that exposes no session identity must leave NO binding behind, so
  # a later recycled pid can never meet a previous owner's session id.
  lib_eval "$fakebin" "fm_session_lock_publish_identity '$dir/state' 89187" '' 27316 \
    || fail "publishing a binding for an identity-less harness reported failure"
  [ -e "$dir/state/.lock.session" ] \
    && fail "an identity-less acquisition left a previous owner's binding in place"

  lib_eval "$fakebin" "fm_session_lock_publish_identity '$dir/state' 89187" "$SESSION" \
    || fail "publishing this session's binding failed"
  lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$SESSION" \
    || fail "the freshly published binding did not prove ownership"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_current_session '$dir/state'" "$OTHER_SESSION"; then
    fail "the replaced binding still spoke for the previous owner"
  fi
  pass "session-lock identity: publishing replaces any previous binding instead of inheriting it"
}

# --- end-to-end layer: the real bin/fm-lock.sh -------------------------------

# Run the REAL acquire path with <fakebin> shadowing ps, under session id $3.
lock_sh() {  # <home> <fakebin> <session-id> <claude-pid> [arg]
  local home=$1 fakebin=$2 session=$3 claude_pid=$4
  shift 4
  CLAUDE_CODE_SESSION_ID="$session" CLAUDE_PID="$claude_pid" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" bash "$ROOT/bin/fm-lock.sh" "$@" 2>&1
}

# The end-to-end layer runs the REAL bin/fm-lock.sh, which does NOT stub kill,
# so every pid it is asked about must be a genuinely live process on this host.
# These are real background processes whose pids the generated ps then describes
# as the session and its pool; using invented numbers would make the case pass
# or fail on whatever happened to occupy those pids on the machine running it.
# LIVE_PID carries the result rather than stdout: a command substitution would
# run this in a subshell, losing the pid list this file must reap, and would
# also block until the backgrounded process closed the captured stdout.
E2E_PIDS=
LIVE_PID=
spawn_live_pid() {  # -> sets LIVE_PID to a fresh long-lived process
  sleep 300 >/dev/null 2>&1 &
  LIVE_PID=$!
  E2E_PIDS="$E2E_PIDS $LIVE_PID"
}
reap_live_pids() {
  local pid
  for pid in $E2E_PIDS; do kill "$pid" 2>/dev/null || true; done
  E2E_PIDS=
}

# A ps that reports <session> as the lock-owning claude session and every other
# process as an ordinary shell parented by <parent>.
write_direct_ps() {  # <fakebin> <session-pid> <parent-pid>
  cat > "$1/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  $2:comm=) printf '%s\n' claude ;;
  $2:args=) printf '%s\n' 'claude --dangerously-skip-permissions' ;;
  $2:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-session-start.sh' ;;
  *:ppid=) printf '%s\n' $3 ;;
esac
SH
  chmod +x "$1/ps"
}

# The measured reparented pool, over real live pids:
#   this process -> claude bg-spare <spare> -> claude bg-pty-host <host> -> init
# and <session>, the lock owner, is live but unreachable from that chain.
write_live_pool_ps() {  # <fakebin> <session-pid> <spare-pid> <host-pid>
  cat > "$1/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$pid:\$field" in
  $2:comm=) printf '%s\n' claude ;;
  $2:args=) printf '%s\n' 'claude --dangerously-skip-permissions' ;;
  $2:ppid=) printf '%s\n' 1 ;;
  $3:comm=) printf '%s\n' 'claude bg-spare' ;;
  $3:args=) printf '%s\n' 'claude bg-spare --bg-spare /tmp/cc/spare/d6bfe5e1.claim.sock' ;;
  $3:ppid=) printf '%s\n' $4 ;;
  $4:comm=) printf '%s\n' 'claude bg-pty-host' ;;
  $4:args=) printf '%s\n' 'claude bg-pty-host --bg-pty-host /tmp/cc/spare/d6bfe5e1.pty.sock 200 50' ;;
  $4:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-session-start.sh' ;;
  *:ppid=) printf '%s\n' $3 ;;
esac
SH
  chmod +x "$1/ps"
}

test_e2e_acquire_records_the_binding_and_readmits_the_pool() {
  local dir fakebin out session_pid spare_pid host_pid
  dir=$(new_home e2e-acquire)
  fakebin=$(fm_fakebin "$dir/bin")
  spawn_live_pid; session_pid=$LIVE_PID
  spawn_live_pid; spare_pid=$LIVE_PID
  spawn_live_pid; host_pid=$LIVE_PID

  # First, the acquisition itself, through a pool that DOES reach the session -
  # exactly like the pool that wrote the measured lock.
  write_direct_ps "$fakebin" "$session_pid" "$session_pid"
  out=$(lock_sh "$dir" "$fakebin" "$SESSION" "$session_pid") \
    || fail "the first acquisition failed: $out"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session_pid" ] \
    || fail "the lock did not record the session pid"
  grep -qx "pid=$session_pid" "$dir/state/.lock.session" \
    || fail "the acquisition did not bind the lock pid: $(cat "$dir/state/.lock.session" 2>&1)"
  grep -qx "session=$SESSION" "$dir/state/.lock.session" \
    || fail "the acquisition did not bind this session's identity"

  # Now the same session comes back through the REPARENTED pool.
  write_live_pool_ps "$fakebin" "$session_pid" "$spare_pid" "$host_pid"
  out=$(lock_sh "$dir" "$fakebin" "$SESSION" "$spare_pid") \
    || fail "the owning session was refused read-only from a reparented pool: $out"
  case "$out" in
    *"lock acquired: harness pid $session_pid"*) ;;
    *) fail "expected ownership of pid $session_pid to be confirmed, got: $out" ;;
  esac
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session_pid" ] \
    || fail "the lock moved off the session onto the reparented pool host"

  # A foreign session through the same pool must still be told to stay read-only.
  out=$(lock_sh "$dir" "$fakebin" "$OTHER_SESSION" "$spare_pid") \
    && fail "a foreign session acquired the lock: $out"
  case "$out" in
    *"another live firstmate session holds the lock (pid $session_pid)"*) ;;
    *) fail "expected the read-only refusal for a foreign session, got: $out" ;;
  esac

  # And a process that only INHERITED the owner's session id, whose own ancestry
  # names its own harness instead of the pool, must stay read-only too.
  out=$(lock_sh "$dir" "$fakebin" "$SESSION" "$session_pid") \
    && fail "a process with an inherited session environment acquired the lock: $out"
  case "$out" in
    *"another live firstmate session holds the lock (pid $session_pid)"*) ;;
    *) fail "expected the read-only refusal for an inherited environment, got: $out" ;;
  esac

  reap_live_pids
  pass "session-lock identity e2e: acquire binds the session, readmits it from a reparented pool, and still refuses a foreign or inherited one"
}

test_owning_session_is_recognized_from_a_reparented_pool
test_foreign_session_still_fails_closed
test_inherited_session_environment_never_proves_ownership
test_absent_malformed_and_unbound_locks_fail_closed
test_two_homes_on_one_machine_stay_independent
test_binding_is_replaced_not_inherited
test_e2e_acquire_records_the_binding_and_readmits_the_pool
