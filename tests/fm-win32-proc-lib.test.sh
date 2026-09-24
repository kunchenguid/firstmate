#!/usr/bin/env bash
# Behavior tests for bin/fm-win32-proc-lib.sh, the shared Win32 process-table
# fallback every ancestry walk on a Windows host reads when Cygwin ps cannot
# answer the fields it needs.
#
# The facts pinned here are the ones a wrong port would silently break:
#   1. fields lookup returns "<ppid>\t<comm>\t<args>" with comm normalized to
#      the same shape POSIX ps -o comm= produces - ExecutablePath with
#      backslashes turned to forward slashes and a trailing .exe dropped, so
#      anchored matches like ^pi$/^omp$/^devin$ still fire.
#   2. the table loads once per process and the load is the only PowerShell
#      call: repeated lookups must not fork it again.
#   3. capability is detected by trying, never by uname, and a failed probe or
#      load latches _FM_WIN32_UNAVAILABLE so a broken PowerShell is asked at
#      most once.
#   4. fm_win32_proc_own_pid reports this shell's WINPID (the id every
#      Win32_Process row is keyed by), which `ps -l` is the one flag
#      combination that still prints on the legacy Cygwin ps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-win32-proc-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-win32-proc-lib)

# A fake PowerShell whose entire job is printing a caller-supplied table and,
# optionally, counting its own invocations so one-load caching is provable.
write_fake_powershell() {  # <fakebin> [<marker-file>]
  local fakebin=$1 marker=${2:-}
  cat > "$fakebin/powershell.exe" <<SH
#!/usr/bin/env bash
${marker:+printf '%s\n' 1 >> "$marker"}
printf '%s\n' "\$FM_TEST_WIN32_TABLE"
SH
  chmod +x "$fakebin/powershell.exe"
}

# A fake ps answering only `ps -l -p $$`-shaped queries the way the real
# legacy Cygwin ps does: header plus one row whose WINPID field is the value
# the caller exported as FM_TEST_OWN_WINPID.
write_fake_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  -o\ *) echo "ps: unknown option -- o" >&2; exit 1 ;;
  -l\ -p\ *)
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n'
    printf '   1234       1    1234    %s  ?         1000 00:00:00 bash\n' "${FM_TEST_OWN_WINPID:-999999}"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/ps"
}

lib_eval() {  # <fakebin> <expression>
  env PATH="$1:$PATH" bash -c '. "$1"; eval "$2"' _ "$LIB" "$2"
}

make_fakebin() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

test_fields_lookup_normalizes_comm() {
  local fakebin got
  fakebin=$(make_fakebin fields)
  write_fake_powershell "$fakebin"
  got=$(FM_TEST_WIN32_TABLE=$'5000\t4\tdevin.exe\tC:\\Users\\Admin\\AppData\\Local\\devin\\cli\\bin\\devin.exe\t"C:\\Users\\Admin\\AppData\\Local\\devin\\cli\\bin\\devin.exe" -- serve' \
    lib_eval "$fakebin" 'fm_win32_proc_fields 5000') \
    || fail "fields lookup returned nonzero for a live pid"
  [ "$got" = $'4\tC:/Users/Admin/AppData/Local/devin/cli/bin/devin\t"C:/Users/Admin/AppData/Local/devin/cli/bin/devin.exe" -- serve' ] \
    || fail "fields lookup printed [$got], expected ppid 4, exe-stripped forward-slash path, and the forward-slashed cmdline"
  pass "win32-proc: fields returns normalized comm and args for a live pid"
}

test_fields_falls_back_to_name_when_path_empty() {
  local fakebin got
  fakebin=$(make_fakebin namefallback)
  write_fake_powershell "$fakebin"
  got=$(FM_TEST_WIN32_TABLE=$'7000\t1\tsvc.exe\t\t' \
    lib_eval "$fakebin" 'fm_win32_proc_fields 7000') \
    || fail "fields lookup returned nonzero when ExecutablePath was empty"
  [ "$got" = $'1\tsvc\t' ] \
    || fail "empty ExecutablePath printed [$got], expected Name with .exe dropped"
  pass "win32-proc: comm falls back to Name when ExecutablePath is empty"
}

test_fields_missing_pid_fails() {
  local fakebin
  fakebin=$(make_fakebin missing)
  write_fake_powershell "$fakebin"
  if FM_TEST_WIN32_TABLE=$'1\t0\tsystem\tC:\\Windows\\System32\\ntoskrnl.exe\t' \
    lib_eval "$fakebin" 'fm_win32_proc_fields 424242' >/dev/null; then
    fail "fields lookup succeeded for a pid not in the table"
  fi
  pass "win32-proc: fields fails for a pid absent from the table"
}

test_pairs_lists_pid_ppid() {
  local fakebin got
  fakebin=$(make_fakebin pairs)
  write_fake_powershell "$fakebin"
  got=$(FM_TEST_WIN32_TABLE=$'4\t0\tsystem\tC:\\Windows\\x.exe\tx\n500\t4\tbash.exe\tC:\\Git\\bin\\bash.exe\tbash' \
    lib_eval "$fakebin" 'fm_win32_proc_pairs') \
    || fail "pairs returned nonzero"
  [ "$got" = $'4\t0\n500\t4' ] || fail "pairs printed [$got], expected the pid/ppid columns only"
  pass "win32-proc: pairs lists every row's pid and ppid"
}

test_pid_alive_membership() {
  local fakebin
  fakebin=$(make_fakebin alive)
  write_fake_powershell "$fakebin"
  FM_TEST_WIN32_TABLE=$'500\t4\tdevin.exe\tC:\\devin\\devin.exe\tdevin' \
    lib_eval "$fakebin" 'fm_win32_pid_alive 500' \
    || fail "pid_alive refused a pid present in the table"
  if FM_TEST_WIN32_TABLE=$'500\t4\tdevin.exe\tC:\\devin\\devin.exe\tdevin' \
    lib_eval "$fakebin" 'fm_win32_pid_alive 501' >/dev/null; then
    fail "pid_alive claimed a pid absent from the table"
  fi
  if lib_eval "$fakebin" 'fm_win32_pid_alive notapid' >/dev/null; then
    fail "pid_alive accepted a non-numeric pid"
  fi
  pass "win32-proc: pid_alive is table membership and rejects non-numeric input"
}

test_table_loads_once_per_process() {
  local fakebin marker calls
  fakebin=$(make_fakebin caching)
  marker="$TMP_ROOT/ps-calls"
  write_fake_powershell "$fakebin" "$marker"
  FM_TEST_WIN32_TABLE=$'500\t4\tdevin.exe\tC:\\devin\\devin.exe\tdevin' \
    lib_eval "$fakebin" 'fm_win32_proc_fields 500 >/dev/null; fm_win32_proc_fields 500 >/dev/null; fm_win32_proc_pairs >/dev/null; fm_win32_pid_alive 500' \
    || fail "a lookup sequence returned nonzero"
  calls=$(wc -l < "$marker" 2>/dev/null | tr -d ' ')
  [ "$calls" = 1 ] || fail "powershell ran $calls times for repeated lookups, expected exactly one table load"
  pass "win32-proc: the table loads once per process no matter how many lookups follow"
}

test_failed_probe_latches_unavailable() {
  local fakebin marker calls
  fakebin=$(make_fakebin latch)
  marker="$TMP_ROOT/fail-calls"
  # A PowerShell that exists but answers nothing must latch the unavailable
  # flag so later lookups never re-ask it.
  cat > "$fakebin/powershell.exe" <<SH
#!/usr/bin/env bash
printf '%s\n' 1 >> "$marker"
exit 0
SH
  chmod +x "$fakebin/powershell.exe"
  # The latch is per-process, so the whole sequence must run inside one eval:
  # the first load fails, and every later lookup must short-circuit without
  # asking powershell again.
  got=$(lib_eval "$fakebin" 'fm_win32_proc_load && printf unexpected-load-ok; fm_win32_proc_fields 1; fm_win32_proc_fields 2; fm_win32_proc_pairs; fm_win32_pid_alive 1 && printf unexpected-alive-ok' 2>/dev/null || true)
  [ -z "$got" ] || fail "an empty table produced output: $got"
  calls=$(wc -l < "$marker" 2>/dev/null | tr -d ' ')
  [ "$calls" = 1 ] || fail "powershell was asked $calls times after a failed load, expected the latch to stop at one"
  pass "win32-proc: a failed table load latches the unavailable flag"
}

test_own_pid_reports_winpid() {
  local fakebin got
  fakebin=$(make_fakebin ownpid)
  write_fake_ps "$fakebin"
  got=$(FM_TEST_OWN_WINPID=4242 lib_eval "$fakebin" 'fm_win32_proc_own_pid') \
    || fail "own_pid returned nonzero"
  [ "$got" = 4242 ] || fail "own_pid printed [$got], expected the ps -l WINPID field"
  pass "win32-proc: own_pid reports the shell's WINPID from ps -l"
}

test_no_powershell_pays_nothing() {
  # A PATH containing only an empty dir: command -v finds no powershell at
  # all, so the capability probe must fail closed without invoking anything.
  local fakebin bashbin
  fakebin=$(make_fakebin absent)
  bashbin=$(command -v bash) || fail "no bash on PATH for the empty-PATH probe"
  if env PATH="$fakebin" "$bashbin" -c '. "$1"; fm_win32_proc_available' _ "$LIB" 2>/dev/null; then
    fail "available reported a powershell capability on an empty PATH"
  fi
  pass "win32-proc: without a powershell binary the capability probe fails closed"
}

test_fields_lookup_normalizes_comm
test_fields_falls_back_to_name_when_path_empty
test_fields_missing_pid_fails
test_pairs_lists_pid_ppid
test_pid_alive_membership
test_table_loads_once_per_process
test_failed_probe_latches_unavailable
test_own_pid_reports_winpid
test_no_powershell_pays_nothing
