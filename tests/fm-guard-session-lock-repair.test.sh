#!/usr/bin/env bash
# tests/fm-guard-session-lock-repair.test.sh - fm-guard.sh repairs a missing
# state/.lock while a harness is plainly still active, but never touches an
# existing one (successor-gap-decision Option B: leave beginArm/sessionOwnsLock
# untouched; the guard is the repair point instead).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-session-lock-repair)

# A `ps` stub that answers every comm=/args= query as a harness process
# ("opencode"), so fm-lock.sh's ancestry walk - run from inside a real
# fm-guard.sh subprocess whose pid cannot be known ahead of time - finds a
# match on its very first hop and stops there (non-Claude harnesses never
# extend past their own match). ppid= is never consulted after that first
# match, so its value is immaterial.
make_harness_ps_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) printf '%s\n' opencode ;;
  args=) printf '%s\n' opencode ;;
  ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_guard_repairs_missing_session_lock() {
  local dir home root fakebin
  dir="$TMP_ROOT/repair"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fakebin=$(make_harness_ps_fakebin "$dir")

  [ ! -e "$home/state/.lock" ] || fail "setup: state/.lock must start absent"

  PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=999 \
    "$ROOT/bin/fm-guard.sh" >/dev/null 2>&1

  [ -f "$home/state/.lock" ] || fail "a missing state/.lock was not repaired by fm-guard.sh"
  [ ! -L "$home/state/.lock" ] || fail "the repaired state/.lock must be a regular file, not a symlink"
  grep -qE '^[0-9]+$' "$home/state/.lock" || fail "the repaired state/.lock must hold a plain pid, got: $(cat "$home/state/.lock" 2>/dev/null)"
  pass "fm-guard: repairs a missing state/.lock while a harness is plainly still active"
}

test_guard_read_only_never_repairs_missing_session_lock() {
  local dir home root fakebin
  dir="$TMP_ROOT/read-only"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fakebin=$(make_harness_ps_fakebin "$dir")

  PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=999 \
    FM_GUARD_READ_ONLY=1 \
    "$ROOT/bin/fm-guard.sh" >/dev/null 2>&1

  [ ! -e "$home/state/.lock" ] || fail "a read-only guard call must never repair state/.lock (ownership was never verified this call)"
  pass "fm-guard: a read-only call leaves a missing state/.lock alone"
}

test_guard_never_touches_an_existing_foreign_lock() {
  local dir home root fakebin before after
  dir="$TMP_ROOT/foreign-owner"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$home/config" "$root"
  fakebin=$(make_harness_ps_fakebin "$dir")

  # A lock recorded by some other, unrelated live session. sleep is a real,
  # live process this test controls, so fm_harness_pid_alive-style liveness
  # checks elsewhere in the tree cannot mistake it for gone.
  sleep 300 &
  local foreign_pid=$!
  trap 'kill "$foreign_pid" 2>/dev/null || true' RETURN
  printf '%s\n' "$foreign_pid" > "$home/state/.lock"
  before=$(cat "$home/state/.lock")

  PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$root" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=999 \
    "$ROOT/bin/fm-guard.sh" >/dev/null 2>&1

  after=$(cat "$home/state/.lock" 2>/dev/null || true)
  [ "$before" = "$after" ] || fail "fm-guard.sh must never rewrite an existing state/.lock, foreign or not; was '$before', now '$after'"
  kill "$foreign_pid" 2>/dev/null || true
  pass "fm-guard: an existing lock (foreign live owner) is left completely alone, so its refusal keeps failing exactly as fast as before"
}

test_guard_repairs_missing_session_lock
test_guard_read_only_never_repairs_missing_session_lock
test_guard_never_touches_an_existing_foreign_lock
