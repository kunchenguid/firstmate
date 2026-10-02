#!/usr/bin/env bash
# tests/fm-guard-session-lock-repair.test.sh - a missing state/.lock is
# repaired only on the verified-owner path (bin/fm-lock.sh, the session-start
# LOCK step), never by fm-guard.sh, which runs from guarded commands that never
# checked ownership; an existing foreign live lock is never rewritten.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-session-lock-repair)

# A `ps` stub that names only the pids listed in $FM_TEST_HARNESS_PIDS as a
# harness ("opencode") and defers every other query to the real ps, so
# fm-lock.sh's ancestry walk must climb its real process tree to a live harness
# ancestor rather than match its own short-lived shell.
make_harness_ps_fakebin() {
  local dir=$1 fakebin real_ps
  fakebin=$(fm_fakebin "$dir")
  real_ps=$(command -v ps)
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
field= pid=
args=("\$@")
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) field=\$2; shift 2 ;;
    -p) pid=\$2; shift 2 ;;
    *) shift ;;
  esac
done
case "\$field" in
  comm=|args=)
    if [ -n "\$pid" ] && grep -qx "\$pid" "\${FM_TEST_HARNESS_PIDS:-/dev/null}" 2>/dev/null; then
      printf '%s\\n' opencode
      exit 0
    fi
    ;;
esac
exec "$real_ps" "\${args[@]}"
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# Run bin/fm-lock.sh as a child of a live harness process that outlives it.
# Sets HARNESS_PID and LOCK_RC. The harness waits until its pid is registered
# in the harness list before running fm-lock.sh, then stays alive.
run_lock_under_harness() {
  local home=$1 fakebin=$2 pids=$3 dir=$4 i
  rm -f "$dir/lock.rc"
  # shellcheck disable=SC2016 # expanded by the harness shell, not here
  env PATH="$fakebin:$PATH" FM_HOME="$home" FM_TEST_HARNESS_PIDS="$pids" \
    LOCK="$ROOT/bin/fm-lock.sh" RC="$dir/lock.rc" bash -c '
      while ! grep -qx "$$" "$FM_TEST_HARNESS_PIDS" 2>/dev/null; do sleep 0.05; done
      "$LOCK" >/dev/null 2>&1
      printf "%s\n" "$?" > "$RC"
      exec sleep 300
    ' &
  HARNESS_PID=$!
  printf '%s\n' "$HARNESS_PID" >> "$pids"
  i=0
  while [ ! -s "$dir/lock.rc" ] && [ "$i" -lt 400 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  LOCK_RC=$(cat "$dir/lock.rc" 2>/dev/null || echo timeout)
}

run_guard() {
  local home=$1 root=$2 fakebin=$3
  shift 3
  env PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=999 \
    "$@" "$ROOT/bin/fm-guard.sh" >/dev/null 2>&1
}

setup_home() {
  local dir=$1
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/root"
}

test_guard_never_repairs_missing_session_lock() {
  local dir fakebin mode
  for mode in main read-only branch; do
    dir="$TMP_ROOT/guard-$mode"
    setup_home "$dir"
    fakebin=$(make_harness_ps_fakebin "$dir")
    case "$mode" in
      main) run_guard "$dir/home" "$dir/root" "$fakebin" ;;
      read-only) run_guard "$dir/home" "$dir/root" "$fakebin" FM_GUARD_READ_ONLY=1 ;;
      branch) run_guard "$dir/home" "$dir/root" "$fakebin" FM_SUPERVISION_ACTOR=branch ;;
    esac
    [ ! -e "$dir/home/state/.lock" ] || fail "fm-guard.sh ($mode) must never write state/.lock; guarded callers never verified ownership"
  done
  pass "fm-guard: never repairs a missing state/.lock (main, read-only, or supervision-branch caller)"
}

test_owner_path_repairs_missing_session_lock() {
  local dir home fakebin pids lock_pid
  dir="$TMP_ROOT/owner-repair"
  setup_home "$dir"
  home="$dir/home"
  fakebin=$(make_harness_ps_fakebin "$dir")
  pids="$dir/harness-pids"
  : > "$pids"

  run_lock_under_harness "$home" "$fakebin" "$pids" "$dir"
  trap 'kill "$HARNESS_PID" 2>/dev/null || true' RETURN
  [ "$LOCK_RC" = 0 ] || fail "fm-lock.sh must acquire an absent state/.lock for a live harness (rc=$LOCK_RC)"

  [ -f "$home/state/.lock" ] || fail "a missing state/.lock was not repaired by the owner path"
  [ ! -L "$home/state/.lock" ] || fail "the repaired state/.lock must be a regular file, not a symlink"
  lock_pid=$(head -n 1 "$home/state/.lock" 2>/dev/null || true)
  [ "$lock_pid" = "$HARNESS_PID" ] || fail "the repaired state/.lock must record the live harness pid $HARNESS_PID, got: $lock_pid"
  kill -0 "$lock_pid" 2>/dev/null || fail "the repaired state/.lock records pid $lock_pid, which is not alive"
  kill "$HARNESS_PID" 2>/dev/null || true
  pass "fm-lock: the verified-owner path repairs a missing state/.lock with the live harness pid"
}

test_owner_path_refuses_an_existing_foreign_lock() {
  local dir home fakebin pids before after
  dir="$TMP_ROOT/foreign-owner"
  setup_home "$dir"
  home="$dir/home"
  fakebin=$(make_harness_ps_fakebin "$dir")
  pids="$dir/harness-pids"

  sleep 300 &
  local foreign_pid=$!
  trap 'kill "$foreign_pid" "${HARNESS_PID:-}" 2>/dev/null || true' RETURN
  printf '%s\n' "$foreign_pid" > "$pids"
  printf '%s\n' "$foreign_pid" > "$home/state/.lock"
  before=$(cat "$home/state/.lock")

  run_lock_under_harness "$home" "$fakebin" "$pids" "$dir"
  FM_TEST_HARNESS_PIDS="$pids" run_guard "$home" "$dir/root" "$fakebin"

  after=$(cat "$home/state/.lock" 2>/dev/null || true)
  [ "$LOCK_RC" != timeout ] || fail "fm-lock.sh under the harness never finished"
  [ "$LOCK_RC" -ne 0 ] || fail "fm-lock.sh must refuse a lock held by another live session"
  [ "$before" = "$after" ] || fail "an existing foreign state/.lock must never be rewritten; was '$before', now '$after'"
  kill "$foreign_pid" "$HARNESS_PID" 2>/dev/null || true
  pass "fm-lock/fm-guard: an existing foreign live lock is refused and left untouched"
}

test_guard_never_repairs_missing_session_lock
test_owner_path_repairs_missing_session_lock
test_owner_path_refuses_an_existing_foreign_lock
