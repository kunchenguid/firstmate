#!/usr/bin/env bash
# tests/fm-guard-session-lock-repair.test.sh - a missing state/.lock is
# repaired only on the verified-owner path (bin/fm-lock.sh, the session-start
# LOCK step), never by fm-guard.sh, which runs from guarded commands that never
# checked ownership; an existing foreign live lock is never rewritten.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-session-lock-repair)

# A `ps` stub that answers every comm=/args= query as a harness process
# ("opencode"), so fm-lock.sh's ancestry walk - run from inside a real
# subprocess whose pid cannot be known ahead of time - finds a
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
  local dir home fakebin
  dir="$TMP_ROOT/owner-repair"
  setup_home "$dir"
  home="$dir/home"
  fakebin=$(make_harness_ps_fakebin "$dir")

  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1 \
    || fail "fm-lock.sh must acquire an absent state/.lock for a live harness"

  [ -f "$home/state/.lock" ] || fail "a missing state/.lock was not repaired by the owner path"
  [ ! -L "$home/state/.lock" ] || fail "the repaired state/.lock must be a regular file, not a symlink"
  grep -qE '^[0-9]+$' "$home/state/.lock" || fail "the repaired state/.lock must hold a plain pid, got: $(cat "$home/state/.lock" 2>/dev/null)"
  pass "fm-lock: the verified-owner path repairs a missing state/.lock"
}

test_owner_path_refuses_an_existing_foreign_lock() {
  local dir home fakebin before after rc
  dir="$TMP_ROOT/foreign-owner"
  setup_home "$dir"
  home="$dir/home"
  fakebin=$(make_harness_ps_fakebin "$dir")

  sleep 300 &
  local foreign_pid=$!
  trap 'kill "$foreign_pid" 2>/dev/null || true' RETURN
  printf '%s\n' "$foreign_pid" > "$home/state/.lock"
  before=$(cat "$home/state/.lock")

  PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-lock.sh" >/dev/null 2>&1
  rc=$?
  run_guard "$home" "$dir/root" "$fakebin"

  after=$(cat "$home/state/.lock" 2>/dev/null || true)
  [ "$rc" -ne 0 ] || fail "fm-lock.sh must refuse a lock held by another live session"
  [ "$before" = "$after" ] || fail "an existing foreign state/.lock must never be rewritten; was '$before', now '$after'"
  kill "$foreign_pid" 2>/dev/null || true
  pass "fm-lock/fm-guard: an existing foreign live lock is refused and left untouched"
}

test_guard_never_repairs_missing_session_lock
test_owner_path_repairs_missing_session_lock
test_owner_path_refuses_an_existing_foreign_lock
