#!/usr/bin/env bash
# tests/ak47-safe-delete.test.sh - the guarded removal ak47/tick.sh deletes through.
#
# The contract this file exists to protect: a safety check that compares paths
# must first prove both sides spell the path the same way. Every refusal below is
# a case where a naive string comparison would have said "safe" and a real
# process would have lost its working directory.
#
# Hermetic: every path lives under one mktemp root, and the mount table and the
# handle check are both replaced through their documented seams.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/ak47/lib/safe-delete.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP_ROOT=
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ak47-sd-tests.XXXXXX")

# A mount table with no entries, so the mount check never fires by accident.
EMPTY_MOUNTS=$TMP_ROOT/mounts.empty
: >"$EMPTY_MOUNTS"

# shellcheck source=../ak47/lib/safe-delete.sh
. "$LIB"

# --- path identity --------------------------------------------------------------

test_path_same_accepts_two_spellings_of_one_path() {
  mkdir -p "$TMP_ROOT/real"
  ln -s "$TMP_ROOT/real" "$TMP_ROOT/link"
  ak47_path_same "$TMP_ROOT/real" "$TMP_ROOT/link" \
    || fail "ak47_path_same rejected a symlink and its target"
  ak47_path_same "$TMP_ROOT/real" "$TMP_ROOT/real/." \
    || fail "ak47_path_same rejected a path and its /. spelling"
  ak47_path_same "$TMP_ROOT/real" "$TMP_ROOT/real/../real" \
    || fail "ak47_path_same rejected a path and its ../ spelling"
  pass "ak47_path_same accepts every spelling of one path"
}

test_path_same_rejects_different_paths() {
  mkdir -p "$TMP_ROOT/a" "$TMP_ROOT/b"
  if ak47_path_same "$TMP_ROOT/a" "$TMP_ROOT/b"; then
    fail "ak47_path_same accepted two different paths"
  fi
  pass "ak47_path_same rejects two different paths"
}

test_path_same_prints_both_spellings_on_mismatch() {
  mkdir -p "$TMP_ROOT/a" "$TMP_ROOT/b"
  local out
  out=$(ak47_path_same "$TMP_ROOT/a" "$TMP_ROOT/b" 2>&1) || true
  case "$out" in
    *"$TMP_ROOT/a"*) : ;;
    *) fail "mismatch output did not name the first spelling: $out" ;;
  esac
  case "$out" in
    *"$TMP_ROOT/b"*) : ;;
    *) fail "mismatch output did not name the second spelling: $out" ;;
  esac
  pass "a path mismatch prints both spellings, so the difference is visible"
}

test_path_under_uses_whole_components() {
  mkdir -p "$TMP_ROOT/foo" "$TMP_ROOT/foobar"
  ak47_path_under "$TMP_ROOT/foo/x" "$TMP_ROOT/foo" \
    || fail "ak47_path_under rejected a real child"
  if ak47_path_under "$TMP_ROOT/foobar" "$TMP_ROOT/foo"; then
    fail "ak47_path_under accepted a sibling that merely shares a prefix"
  fi
  pass "ak47_path_under compares whole components, not string prefixes"
}

# --- mount hazard ---------------------------------------------------------------

test_mount_hazard_decodes_kernel_octal_escapes() {
  # The kernel writes a space in a mount point as \040. A comparison against the
  # literal path would miss the mount and delete into it.
  local mounts=$TMP_ROOT/mounts.escaped
  printf '/dev/sda1 %s/with\\040space ext4 rw 0 0\n' "$TMP_ROOT" >"$mounts"
  mkdir -p "$TMP_ROOT/with space"
  AK47_MOUNTS_FILE=$mounts ak47_mount_hazard "$TMP_ROOT/with space" \
    || fail "ak47_mount_hazard missed a mount point spelled with \\040"
  pass "ak47_mount_hazard decodes the kernel's octal escapes before comparing"
}

test_mount_hazard_ignores_an_unrelated_mount() {
  local mounts=$TMP_ROOT/mounts.other
  printf '/dev/sda1 /somewhere/else ext4 rw 0 0\n' >"$mounts"
  mkdir -p "$TMP_ROOT/plain"
  if AK47_MOUNTS_FILE=$mounts ak47_mount_hazard "$TMP_ROOT/plain"; then
    fail "ak47_mount_hazard flagged a path that is not a mount point"
  fi
  pass "ak47_mount_hazard leaves an ordinary directory alone"
}

# --- handle check ---------------------------------------------------------------

test_has_open_handles_sees_a_held_directory() {
  local d=$TMP_ROOT/held
  mkdir -p "$d"
  # A subshell whose cwd is inside the directory holds it for as long as it lives.
  ( cd "$d" && sleep 5 ) &
  local holder=$!
  sleep 0.3
  if ! ak47_has_open_handles "$d"; then
    kill "$holder" 2>/dev/null
    fail "ak47_has_open_handles missed a directory a live process is sitting in"
  fi
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  pass "ak47_has_open_handles sees a directory a live process is sitting in"
}

test_has_open_handles_clears_an_unheld_directory() {
  local d=$TMP_ROOT/free rc
  mkdir -p "$d"
  # The contract is rc 0 = held, 1 = free, 2 = unknown. "Free" is a non-zero
  # exit on purpose, so a caller that only tests truthiness fails closed.
  ak47_has_open_handles "$d"; rc=$?
  [ "$rc" -eq 1 ] \
    || fail "ak47_has_open_handles returned $rc for a directory nothing holds; expected 1 (free)"
  pass "ak47_has_open_handles clears a directory nothing holds"
}

test_has_open_handles_fails_closed_when_the_check_is_unavailable() {
  local d=$TMP_ROOT/unknown
  mkdir -p "$d"
  # A handle check that cannot run must report "unknown" (2), never "free" (1).
  # Shadow lsof with a stub that fails the way a broken lsof fails: an error on
  # stderr and a non-1 exit.
  local rc stubdir=$TMP_ROOT/stub-bin
  mkdir -p "$stubdir"
  cat >"$stubdir/lsof" <<'SH'
#!/usr/bin/env bash
echo 'lsof: WARNING: can not access /proc/1/fd' >&2
exit 3
SH
  chmod +x "$stubdir/lsof"
  PATH=$stubdir:$PATH ak47_has_open_handles "$d"; rc=$?
  [ "$rc" -eq 2 ] \
    || fail "ak47_has_open_handles returned $rc when the check could not run; expected 2 (unknown)"
  pass "ak47_has_open_handles fails closed when the check cannot run"
}

test_has_open_handles_reports_unknown_when_lsof_is_absent() {
  local d=$TMP_ROOT/nolsof rc
  mkdir -p "$d"
  # An empty PATH with no lsof at all: still unknown, never free.
  PATH=/nonexistent ak47_has_open_handles "$d"; rc=$?
  [ "$rc" -eq 2 ] \
    || fail "ak47_has_open_handles returned $rc with no lsof on PATH; expected 2 (unknown)"
  pass "ak47_has_open_handles reports unknown when lsof is absent"
}

# --- the removal itself ---------------------------------------------------------

test_safe_delete_quarantines_then_removes() {
  local d=$TMP_ROOT/victim
  mkdir -p "$d/sub"
  printf 'x\n' >"$d/sub/file"
  AK47_MOUNTS_FILE=$EMPTY_MOUNTS ak47_safe_delete "$d" >/dev/null \
    || fail "ak47_safe_delete refused an unheld, unmounted directory: $AK47_SD_ERROR"
  [ ! -e "$d" ] || fail "ak47_safe_delete left the directory in place"
  pass "ak47_safe_delete removes an unheld, unmounted directory"
}

test_safe_delete_refuses_a_held_directory() {
  local d=$TMP_ROOT/held-victim
  mkdir -p "$d"
  ( cd "$d" && sleep 5 ) &
  local holder=$!
  sleep 0.3
  if AK47_MOUNTS_FILE=$EMPTY_MOUNTS ak47_safe_delete "$d" >/dev/null; then
    kill "$holder" 2>/dev/null
    fail "ak47_safe_delete removed a directory a live process was sitting in"
  fi
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  [ -d "$d" ] || fail "ak47_safe_delete removed the directory even though it refused"
  pass "ak47_safe_delete refuses a directory a live process is sitting in"
}

test_safe_delete_refuses_a_mount_point() {
  local d=$TMP_ROOT/mountpoint
  mkdir -p "$d"
  local mounts=$TMP_ROOT/mounts.mp
  printf '/dev/sdb1 %s ext4 rw 0 0\n' "$d" >"$mounts"
  if AK47_MOUNTS_FILE=$mounts ak47_safe_delete "$d" >/dev/null; then
    fail "ak47_safe_delete removed a mount point"
  fi
  [ -d "$d" ] || fail "ak47_safe_delete removed the mount point even though it refused"
  pass "ak47_safe_delete refuses a mount point"
}

test_safe_delete_restores_when_a_handle_appears_mid_move() {
  # The window between the handle check and the rename is real. The seam makes a
  # handle appear exactly there, and the removal must put the directory back.
  local d=$TMP_ROOT/raced
  mkdir -p "$d"
  # AK47_HANDLE_CHECK names a FUNCTION, not a path. The first call (the
  # pre-check) says free; every later call says held, which is exactly the race
  # the post-rename re-scan exists to catch.
  # The seam replaces only the POST-rename scan, so it always reports held:
  # that is the process that opened a file in the window between the first scan
  # and the rename.
  seam_handle_check() { return 0; }
  if AK47_MOUNTS_FILE=$EMPTY_MOUNTS AK47_HANDLE_CHECK=seam_handle_check \
     ak47_safe_delete "$d" >/dev/null; then
    fail "ak47_safe_delete completed a removal after a handle appeared mid-move"
  fi
  [ -d "$d" ] || fail "ak47_safe_delete did not restore the directory after the race"
  pass "ak47_safe_delete restores the directory when a handle appears mid-move"
}

test_safe_delete_refuses_a_path_that_does_not_exist() {
  if AK47_MOUNTS_FILE=$EMPTY_MOUNTS ak47_safe_delete "$TMP_ROOT/never-existed" >/dev/null; then
    fail "ak47_safe_delete reported success for a path that does not exist"
  fi
  pass "ak47_safe_delete refuses a path that does not exist"
}

test_path_same_accepts_two_spellings_of_one_path
test_path_same_rejects_different_paths
test_path_same_prints_both_spellings_on_mismatch
test_path_under_uses_whole_components
test_mount_hazard_decodes_kernel_octal_escapes
test_mount_hazard_ignores_an_unrelated_mount
test_has_open_handles_sees_a_held_directory
test_has_open_handles_clears_an_unheld_directory
test_has_open_handles_fails_closed_when_the_check_is_unavailable
test_has_open_handles_reports_unknown_when_lsof_is_absent
test_safe_delete_quarantines_then_removes
test_safe_delete_refuses_a_held_directory
test_safe_delete_refuses_a_mount_point
test_safe_delete_restores_when_a_handle_appears_mid_move
test_safe_delete_refuses_a_path_that_does_not_exist
