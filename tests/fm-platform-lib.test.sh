#!/usr/bin/env bash
# tests/fm-platform-lib.test.sh - unit tests for the MSYS/Windows path-form
# conversion owner (bin/fm-platform-lib.sh).
#
# This runs everywhere, not only on Windows. The library's FM_PLATFORM_UNAME
# seam plus a cygpath fixture injected on PATH supply both halves of the MSYS
# branch, so a Linux runner exercises the same code a Git Bash home takes.
#
# Every case runs in its own bash process. The library caches its platform
# verdict in FM_PLATFORM_MSYS for the life of a process, so a case run in this
# shell would answer the next case from the previous case's fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-platform-lib.sh"
TMP_ROOT=$(fm_test_tmproot platform-lib)

# A cygpath that answers from fixtures, so the assertion is the library's
# handling of the tool's output rather than the tool's own correctness.
#
# Both fixtures name their interpreter absolutely. Each case runs with only its
# own fixture directory on PATH, so a `/usr/bin/env` shebang would fail to find
# an interpreter and every case would pass through the failed-cygpath branch.
FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/cygpath" <<'EOF'
#!/bin/sh
case "$1" in
  -m) printf 'X:/fixture/native\n' ;;
  -u) printf '/x/fixture/posix\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKE_BIN/cygpath"

# A cygpath that fails the way a broken or refusing one does: non-zero, silent.
BROKEN_BIN="$TMP_ROOT/broken-bin"
mkdir -p "$BROKEN_BIN"
cat > "$BROKEN_BIN/cygpath" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BROKEN_BIN/cygpath"

# No cygpath at all, and nothing else either: the library uses only builtins
# once FM_PLATFORM_UNAME is supplied, so an empty PATH is a faithful fixture.
EMPTY_BIN="$TMP_ROOT/empty-bin"
mkdir -p "$EMPTY_BIN"

# Run <func> <input> in a fresh process with <uname> reported and <bindir>
# alone on PATH.
run_conv() {  # <uname> <bindir> <func> <input>
  FM_PLATFORM_UNAME="$1" bash -c '
    PATH=$1
    export PATH
    . "$2"
    "$3" "$4"
  ' _ "$2" "$LIB" "$3" "$4"
}

# --- off MSYS, every path is already the native one -------------------------

for input in /tmp/x C:/x; do
  out=$(run_conv Linux "$EMPTY_BIN" fm_path_native "$input")
  [ "$out" = "$input" ] \
    || fail "off MSYS fm_path_native changed '$input' to '$out'"
  out=$(run_conv Linux "$EMPTY_BIN" fm_path_posix "$input")
  [ "$out" = "$input" ] \
    || fail "off MSYS fm_path_posix changed '$input' to '$out'"
done
pass "off MSYS both conversions return their input unchanged"

# --- on MSYS with a working cygpath -----------------------------------------

out=$(run_conv MINGW64_NT-fixture "$FAKE_BIN" fm_path_native /tmp/x)
[ "$out" = 'X:/fixture/native' ] \
  || fail "fm_path_native did not use cygpath -m output: got '$out'"
pass "on MSYS fm_path_native prints the mixed form cygpath reports"

out=$(run_conv MINGW64_NT-fixture "$FAKE_BIN" fm_path_posix 'C:/x')
[ "$out" = '/x/fixture/posix' ] \
  || fail "fm_path_posix did not use cygpath -u output: got '$out'"
pass "on MSYS fm_path_posix prints the POSIX form cygpath reports"

# The MSYS spelling of the same platform must take the same branch.
out=$(run_conv MSYS_NT-fixture "$FAKE_BIN" fm_path_native /tmp/x)
[ "$out" = 'X:/fixture/native' ] \
  || fail "the MSYS_NT uname spelling missed the conversion branch: got '$out'"
pass "MSYS_NT and MINGW uname spellings take the same branch"

# --- on MSYS with cygpath missing -------------------------------------------
#
# A home without cygpath must degrade to the identity, not to an empty string:
# a caller cannot tell an empty conversion apart from a real answer.

for func in fm_path_native fm_path_posix; do
  out=$(run_conv MINGW64_NT-fixture "$EMPTY_BIN" "$func" /tmp/x)
  [ "$out" = /tmp/x ] \
    || fail "with cygpath absent $func returned '$out' instead of the input"
done
pass "with cygpath absent both conversions return their input unchanged"

# --- on MSYS with cygpath failing -------------------------------------------

for func in fm_path_native fm_path_posix; do
  out=$(run_conv MINGW64_NT-fixture "$BROKEN_BIN" "$func" /tmp/x)
  [ "$out" = /tmp/x ] \
    || fail "with cygpath failing $func returned '$out' instead of the input"
done
pass "with cygpath failing both conversions return their input unchanged"

# --- an empty path is empty, and not an error -------------------------------

for func in fm_path_native fm_path_posix; do
  out=$(run_conv MINGW64_NT-fixture "$FAKE_BIN" "$func" "")
  rc=$?
  [ "$rc" = 0 ] || fail "$func returned $rc for an empty path"
  [ -z "$out" ] || fail "$func invented '$out' for an empty path"
done
pass "an empty path converts to nothing and succeeds"

# --- the mode-bit capability probe ------------------------------------------
#
# Run in a fresh process per case like everything else here: the probe memoizes
# one directory's verdict, so a second case in the same shell would be answered
# from the first case's fixture.

run_lib() {  # <func> <arg>...
  bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"
}

PROBE_DIR="$TMP_ROOT/mode-probe"
mkdir -p "$PROBE_DIR"
PROBE_FILE="$PROBE_DIR/artifact"
printf 'x\n' > "$PROBE_FILE"

FM_FS_MODES_HONORED=1 bash -c '. "$1"; fm_platform_fs_honors_modes "$2"' _ "$LIB" "$PROBE_FILE" \
  || fail "FM_FS_MODES_HONORED=1 did not force the strict mode contract"
FM_FS_MODES_HONORED=0 bash -c '. "$1"; fm_platform_fs_honors_modes "$2"' _ "$LIB" "$PROBE_FILE" \
  && fail "FM_FS_MODES_HONORED=0 did not declare modes unrepresentable"
pass "the mode probe honors its explicit override in both directions"

# A directory the probe cannot write keeps the strict contract, so an
# unexpected filesystem never silently drops the mode check.
run_lib fm_platform_fs_honors_modes "$TMP_ROOT/no-such-dir/artifact" \
  || fail "an unprobeable directory must keep the strict mode contract"
pass "a probe that cannot run at all reports modes-honored"

# Platform-adaptive: the unset probe must report what this filesystem actually
# does. After a real chmod 0600, a mount that stores modes reads 600 back and
# must probe as honoring; a noacl mount cannot and must probe as mode-free.
chmod 0600 "$PROBE_FILE"
PROBE_MODE=$(run_lib fm_platform_file_mode "$PROBE_FILE")
if [ "$PROBE_MODE" = 600 ]; then
  run_lib fm_platform_fs_honors_modes "$PROBE_FILE" \
    || fail "the probe called a mode-honoring filesystem mode-free"
  pass "on this mode-honoring filesystem the probe reports modes-honored"
else
  run_lib fm_platform_fs_honors_modes "$PROBE_FILE" \
    && fail "the probe called a mode-free filesystem honoring (read back $PROBE_MODE)"
  pass "on this mode-free filesystem the probe reports modes-ignored (reads $PROBE_MODE)"
fi

# --- the real host, whichever one this is -----------------------------------
#
# The fixtures above prove the branching; this proves the real cygpath contract
# holds where there is one, and that the library stays inert where there is not.

REAL_UNAME=$(uname -s)
case "$REAL_UNAME" in
  MINGW*|MSYS*)
    if command -v cygpath >/dev/null 2>&1; then
      NATIVE=$(bash -c '. "$1"; fm_path_native "$2"' _ "$LIB" /c/Users)
      case "$NATIVE" in
        *:*) : ;;
        *) fail "the real cygpath produced no drive letter for /c/Users: '$NATIVE'" ;;
      esac
      case "$NATIVE" in
        *\\*) fail "the mixed form must carry no backslash: '$NATIVE'" ;;
      esac
      BACK=$(bash -c '. "$1"; fm_path_posix "$2"' _ "$LIB" "$NATIVE")
      [ "$BACK" = /c/Users ] \
        || fail "round trip lost the path: /c/Users -> '$NATIVE' -> '$BACK'"
      pass "on this Git Bash host /c/Users round trips through both conversions"
    else
      pass "this MSYS host has no cygpath, so the conversions stay inert"
    fi
    ;;
  *)
    for func in fm_path_native fm_path_posix; do
      out=$(bash -c '. "$1"; "$2" "$3"' _ "$LIB" "$func" /tmp/probe)
      [ "$out" = /tmp/probe ] \
        || fail "on $REAL_UNAME $func changed /tmp/probe to '$out'"
    done
    pass "on $REAL_UNAME both conversions are the identity"
    ;;
esac

echo "# fm-platform-lib.test.sh: all assertions passed"
