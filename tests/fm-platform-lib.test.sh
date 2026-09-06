#!/usr/bin/env bash
# tests/fm-platform-lib.test.sh - unit tests for the shared platform seam:
# Windows detection overrides, HOME/TMPDIR fallbacks, locale-stable process
# identity, and MSYS/Cygwin fixed-column `ps` parsing.
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-platform-lib)
LIB="$ROOT/bin/fm-platform-lib.sh"

test_msys_fixed_ps_fields() {
  local dir fakebin out
  dir="$TMP_ROOT/msys-ps"
  fakebin=$(fm_fakebin "$dir")
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *" -o "*) exit 1 ;;
  *"-p 4321"*)
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n'
    printf 'S    4321    1234    4321      98765  pty0      197609 Jan 29 /usr/bin/bash --login\n'
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_platform_ps_field 4321 ppid' _ "$LIB")
  [ "$out" = 1234 ] || fail "fixed-column ps ppid parse returned '$out'"

  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_platform_ps_field 4321 comm' _ "$LIB")
  [ "$out" = "/usr/bin/bash --login" ] || fail "fixed-column ps command parse returned '$out'"

  out=$(PATH="$fakebin:$PATH" bash -c '. "$1"; fm_platform_ps_fixed_field 4321 stime' _ "$LIB")
  [ "$out" = "Jan 29" ] || fail "fixed-column ps start time parse returned '$out'"

  if PATH="$fakebin:$PATH" bash -c '. "$1"; fm_platform_pid_identity 4321' _ "$LIB"; then
    fail "fixed-column ps identity should fail without a stable creation token"
  fi

  pass "fm-platform-lib parses status-prefixed MSYS ps output and rejects unstable identity"
}

test_windows_userprofile_home_fallback() {
  local out
  # shellcheck disable=SC2016  # single quotes are deliberate: $1 expands inside bash -c.
  out=$(env HOME='' USERPROFILE='C:\Users\Captain' FM_PLATFORM_IS_WINDOWS=yes bash -c '. "$1"; fm_platform_home_dir' _ "$LIB")
  case "$out" in
    /c/Users/Captain|/cygdrive/c/Users/Captain) ;;
    *) fail "USERPROFILE fallback did not produce a POSIX-ish Windows home path: '$out'" ;;
  esac
  pass "fm-platform-lib falls back from HOME to USERPROFILE on Windows"
}

test_temp_root_windows_honors_tmpdir() {
  local out
  # shellcheck disable=SC2016  # single quotes are deliberate: $1 expands inside bash -c.
  out=$(env TMPDIR="$TMP_ROOT/custom-tmp" FM_PLATFORM_IS_WINDOWS=yes bash -c '. "$1"; fm_platform_temp_root' _ "$LIB")
  [ "$out" = "$TMP_ROOT/custom-tmp" ] || fail "Windows temp root should honor TMPDIR (got '$out')"
  pass "fm-platform-lib temp root honors TMPDIR on Windows"
}

test_temp_root_posix_is_tmp() {
  local out
  # shellcheck disable=SC2016  # single quotes are deliberate: $1 expands inside bash -c.
  out=$(env TMPDIR="$TMP_ROOT/custom-tmp" FM_PLATFORM_IS_WINDOWS=no bash -c '. "$1"; fm_platform_temp_root' _ "$LIB")
  [ "$out" = /tmp ] || fail "POSIX temp root should stay /tmp regardless of TMPDIR (got '$out')"
  pass "fm-platform-lib temp root stays /tmp on POSIX regardless of TMPDIR"
}

test_pid_identity_pins_lc_all_for_lstart() {
  local dir fakebin out
  dir="$TMP_ROOT/pid-identity-locale"
  fakebin=$(fm_fakebin "$dir")
cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-p 4321 -o lstart= -o command="*)
    printf '%s /usr/bin/bash\n' "${LC_ALL:-unset}"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  out=$(PATH="$fakebin:$PATH" LC_ALL=C.utf8 bash -c '. "$1"; fm_platform_pid_identity 4321' _ "$LIB")
  [ "$out" = "C /usr/bin/bash" ] || fail "pid identity did not pin LC_ALL=C for lstart ps (got '$out')"

  pass "fm-platform-lib pid identity pins LC_ALL for lstart ps"
}

test_msys_fixed_ps_fields
test_windows_userprofile_home_fallback
test_temp_root_windows_honors_tmpdir
test_temp_root_posix_is_tmp
test_pid_identity_pins_lc_all_for_lstart
