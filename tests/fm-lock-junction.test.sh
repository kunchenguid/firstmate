#!/usr/bin/env bash
# tests/fm-lock-junction.test.sh - the Windows junction fallback inside
# fm_lock_try_create. Git Bash without Developer Mode turns `ln -s` into a
# silent directory copy, which fails fm_lock_points_to_owner and leaves a
# stray copy behind; on such hosts `cmd.exe /c mklink /J` makes a real
# directory junction that Cygwin reads as a symlink, no privileges needed.
# These cases pin the contract: the fallback runs only after the normal
# symlink path already failed to verify, creation is always re-verified
# through the same points-to-owner check, teardown removes only the link,
# and a host that cannot make junctions fails closed with no stray left.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
REAL_LN=$(command -v ln)

TMP_ROOT=$(fm_test_tmproot fm-lock-junction)

lib_eval() {  # <fakebin> <expression> [args...]
  local fakebin=$1 expr=$2
  shift 2
  env PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    $expr
  " "$LIB" "$@"
}

# An ln that mimics the MSYS copy fallback: accepts -s but produces a real
# directory copy, exactly like Git Bash here when no symlink primitive is
# available.
write_copying_ln() {  # <fakebin>
  cat > "$1/ln" <<'SH'
#!/usr/bin/env bash
set -u
src= dst=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -* ) shift ;;
    *) if [ -z "$src" ]; then src=$1; else dst=$1; fi; shift ;;
  esac
done
[ -n "$src" ] && [ -n "$dst" ] || exit 1
cp -r "$src" "$dst"
SH
  chmod +x "$1/ln"
}

# An ln that honors -s with a real symlink on any host: plain ln on POSIX,
# MSYS=winsymlinks:lnk (a privilege-free shortcut symlink) on Cygwin/MSYS.
write_symlinking_ln() {  # <fakebin>
  cat > "$1/ln" <<SH
#!/usr/bin/env bash
MSYS=winsymlinks:lnk "$REAL_LN" "\$@"
SH
  chmod +x "$1/ln"
}

# A cmd.exe that only records being called, then fails - an unavailable
# junction capability.
write_failing_cmd() {  # <fakebin> <marker>
  cat > "$1/cmd.exe" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "$2"
exit 1
SH
  chmod +x "$1/cmd.exe"
}

have_junction_capability() {
  command -v cmd.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1
}

test_posix_symlink_never_consults_junction() {
  local dir fakebin marker
  dir="$TMP_ROOT/posix-clean"
  fakebin=$(fm_fakebin "$dir")
  marker="$dir/cmd-was-called"
  write_symlinking_ln "$fakebin"
  write_failing_cmd "$fakebin" "$marker"

  lib_eval "$fakebin" 'fm_lock_try_create "$1/lock"' "$dir" \
    || fail "a working ln -s did not create the lock"
  [ -L "$dir/lock" ] || fail "the lock is not a link after a successful ln -s"
  [ ! -e "$marker" ] || fail "cmd.exe ran even though the normal symlink already held"
  pass "lock-junction: a working ln -s never consults the junction fallback"
}

test_junction_fallback_claims_the_lock() {
  local dir fakebin ownerpid
  dir="$TMP_ROOT/junction-claim"
  fakebin=$(fm_fakebin "$dir")
  have_junction_capability \
    || { pass "lock-junction: junction fallback claims the lock (skipped - no cmd.exe/cygpath here)"; return; }
  write_copying_ln "$fakebin"

  lib_eval "$fakebin" 'fm_lock_try_create "$1/lock"' "$dir" \
    || fail "the junction fallback did not claim the lock after ln -s copied"
  [ -L "$dir/lock" ] || fail "the junction lock is not link-shaped for test -L"
  ownerpid=$(cat "$dir/lock/pid" 2>/dev/null || true)
  [ -n "$ownerpid" ] || fail "the junction lock carries no owner pid file"

  # Removing the link must not touch the owner directory it points at: the
  # exact rm -f fm_lock_remove_path performs, asserted against the owner
  # still holding its pid file afterwards.
  local ownerdir
  ownerdir=$(readlink "$dir/lock")
  printf 'keep\n' > "$ownerdir/keep-me"
  rm -f "$dir/lock"
  [ ! -e "$dir/lock" ] || fail "rm -f left the junction in place"
  [ "$(cat "$ownerdir/keep-me")" = keep ] \
    || fail "removing the junction destroyed the owner directory contents"
  pass "lock-junction: the junction fallback claims a verified lock and removal touches only the link"
}

test_junction_unavailable_fails_closed() {
  local dir fakebin marker
  dir="$TMP_ROOT/junction-off"
  fakebin=$(fm_fakebin "$dir")
  marker="$dir/cmd-was-called"
  write_copying_ln "$fakebin"
  write_failing_cmd "$fakebin" "$marker"

  if lib_eval "$fakebin" 'fm_lock_try_create "$1/lock"' "$dir"; then
    fail "a lock was created with no working symlink or junction primitive"
  fi
  [ ! -e "$dir/lock" ] || fail "a stray lock dir was left behind after the closed failure"
  if compgen -G "$dir/lock.owner.*" >/dev/null; then
    fail "the failed junction attempt left owner dirs behind"
  fi
  pass "lock-junction: with no junction primitive the create fails closed and leaves nothing"
}

test_junction_failure_latches_per_process() {
  local dir fakebin marker
  dir="$TMP_ROOT/junction-latch"
  fakebin=$(fm_fakebin "$dir")
  marker="$dir/cmd-was-called"
  write_copying_ln "$fakebin"
  write_failing_cmd "$fakebin" "$marker"

  # Two attempts inside one shell process: a failed junction capability is
  # latched, so cmd.exe is spawned once no matter how many creates follow.
  lib_eval "$fakebin" \
    'fm_lock_try_create "$1/lock"; fm_lock_try_create "$1/lock"; true' "$dir" >/dev/null
  [ "$(wc -l < "$marker" | tr -d ' ')" = 1 ] \
    || fail "cmd.exe was spawned $(wc -l < "$marker" | tr -d ' ') times across two failed creates"
  pass "lock-junction: a failed junction attempt is latched per process"
}

test_posix_symlink_never_consults_junction
test_junction_fallback_claims_the_lock
test_junction_unavailable_fails_closed
test_junction_failure_latches_per_process
