#!/usr/bin/env bash
# tests/fm-session-lock-windows.test.sh - the Windows process backend of
# bin/fm-session-lock-lib.sh, and the symlink-free lock mode of
# bin/fm-wake-lib.sh.
#
# Both exist because Git Bash/MSYS breaks assumptions the POSIX paths are built
# on, and both are driven here from ANY host: the backend is selected by
# FM_PROC_BACKEND, the Win32 process table is injected through
# FM_WIN_PROC_TABLE, and MSYS's /proc is a fixture directory behind
# FM_PROC_ROOT_OVERRIDE. Nothing here shells out to PowerShell or requires
# Windows, so the regression stays covered on Linux and macOS CI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-windows)

LIB="$ROOT/bin/fm-session-lock-lib.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"

# A Win32 process table shaped exactly like the real one: TAB-separated
# pid / ppid / executable path / command line, with Windows backslashes, .exe
# suffixes and a quoted argv[0].
#
# The tree is the real one this fix was found in:
#   34568 bash  -> 27644 bash -> 33796 claude.exe -> 20576 pwsh.exe -> 36672 wt
# plus 4242 as an unrelated live Claude session that this process does NOT
# descend from.
win_table() {
  printf '%s\t%s\t%s\t%s\n' \
    34568 27644 'C:\Program Files\Git\usr\bin\bash.exe' '"C:\Program Files\Git\usr\bin\bash.exe" -c /c/Users/u/.claude/hooks/notify.sh' \
    27644 33796 'C:\Program Files\Git\bin\bash.exe' '"C:\Program Files\Git\bin\bash.exe" -c bin/fm-claude-stop-autoarm.sh' \
    33796 20576 'C:\Users\u\.local\bin\claude.exe' '"C:\Users\u\.local\bin\claude.exe"' \
    20576 36672 'C:\Program Files\PowerShell\7\pwsh.exe' '"C:\Program Files\PowerShell\7\pwsh.exe"' \
    36672 25692 'C:\Program Files\WindowsApps\WindowsTerminal.exe' '"C:\Program Files\WindowsApps\WindowsTerminal.exe"' \
    4242 1 'C:\Users\u\.local\bin\claude.exe' '"C:\Users\u\.local\bin\claude.exe"'
}

# A version-named Claude Code install, whose basename identifies nothing and
# whose only harness evidence is a whole path component.
win_table_version_named() {
  printf '%s\t%s\t%s\t%s\n' \
    34568 27644 'C:\Program Files\Git\usr\bin\bash.exe' '"C:\Program Files\Git\usr\bin\bash.exe" -c hook' \
    27644 33796 'C:\Program Files\Git\bin\bash.exe' '"C:\Program Files\Git\bin\bash.exe" -c hook' \
    33796 20576 'C:\Users\u\AppData\Local\claude\versions\2.1.220.exe' '"C:\Users\u\AppData\Local\claude\versions\2.1.220.exe" --resume' \
    20576 1 'C:\Program Files\PowerShell\7\pwsh.exe' '"C:\Program Files\PowerShell\7\pwsh.exe"'
}

# Ordinary Windows processes that merely live under a harness-named directory,
# or merely start with a harness name, and must never be read as a harness.
win_table_ordinary() {
  printf '%s\t%s\t%s\t%s\n' \
    34568 27644 'C:\Program Files\Git\usr\bin\bash.exe' '"C:\Program Files\Git\usr\bin\bash.exe" -c hook' \
    27644 20576 'C:\Users\u\.claude\hooks\notify.exe' '"C:\Users\u\.claude\hooks\notify.exe" --quiet' \
    20576 1 'C:\opt\pipeline\bin\runner.exe' '"C:\opt\pipeline\bin\runner.exe" --once'
}

# Build a fake MSYS /proc. Each entry maps an MSYS pid to its winpid and MSYS
# ppid, exactly as MSYS publishes them; ppid 1 is the boundary at which the
# parent is a native Windows process.
make_proc_root() {  # <dir> <msyspid:winpid:msysppid>...
  local dir=$1 entry pid winpid ppid
  shift
  rm -rf "$dir"
  for entry in "$@"; do
    pid=${entry%%:*}
    winpid=${entry#*:}; winpid=${winpid%%:*}
    ppid=${entry##*:}
    mkdir -p "$dir/$pid"
    printf '%s\n' "$winpid" > "$dir/$pid/winpid"
    printf '%s\n' "$ppid" > "$dir/$pid/ppid"
  done
  printf '%s' "$dir"
}

# The table functions have to exist inside the fixture child, so they are
# re-declared there from this file.
export_table_fns() {
  declare -f win_table win_table_version_named win_table_ordinary
}

# Run <expression> in a child that has the backend forced, the fake /proc in
# place with an entry for its own pid, and the named table loaded.
run_win() {  # <proc-root> <table-fn> <self-winpid> <self-msys-ppid> <expression>
  local proc_root=$1 table_fn=$2 self_winpid=$3 self_ppid=$4 expr=$5
  FM_PROC_BACKEND=windows FM_PROC_ROOT_OVERRIDE="$proc_root" \
    bash -c "
      set -u
      $(export_table_fns)
      mkdir -p \"\$FM_PROC_ROOT_OVERRIDE/\$\$\"
      printf '%s\n' '$self_winpid' > \"\$FM_PROC_ROOT_OVERRIDE/\$\$/winpid\"
      printf '%s\n' '$self_ppid' > \"\$FM_PROC_ROOT_OVERRIDE/\$\$/ppid\"
      . '$LIB'
      FM_WIN_PROC_TABLE=\$($table_fn)
      FM_WIN_PROC_TABLE_AT=\$SECONDS
      $expr
    "
}

test_windows_paths_are_normalized_for_the_matcher() {
  local got
  got=$(FM_PROC_BACKEND=windows bash -c '. "$1"; fm_win_normalize_path "C:\Users\u\.local\bin\claude.exe"' _ "$LIB")
  [ "$got" = 'C:/Users/u/.local/bin/claude' ] \
    || fail "a Windows executable path was not normalized for component matching, got '$got'"

  got=$(FM_PROC_BACKEND=windows bash -c '. "$1"; fm_win_normalize_path "C:\x\PI.EXE"' _ "$LIB")
  [ "$got" = 'C:/x/PI' ] || fail "an upper-case .EXE suffix survived normalization, got '$got'"

  # A quoted argv[0] containing a space must not be split into "C:/Program.
  got=$(FM_PROC_BACKEND=windows bash -c \
    '. "$1"; fm_win_normalize_args "\"C:\Program Files\Git\bin\bash.exe\" -c hook"' _ "$LIB")
  [ "$got" = 'C:/Program Files/Git/bin/bash -c hook' ] \
    || fail "a quoted Windows argv[0] was not unquoted for the matcher, got '$got'"
  pass "windows: executable paths and quoted argv[0] are normalized for the harness matcher"
}

test_windows_ancestry_resolves_the_session_across_the_msys_boundary() {
  local proc_root got
  # MSYS pid 900 (winpid 34568) is a forked child whose MSYS parent is 910
  # (winpid 27644); 910's MSYS ppid is 1, the boundary where the Win32 table
  # takes over and reaches claude.exe at 33796.
  proc_root=$(make_proc_root "$TMP_ROOT/proc-bridge" "910:27644:1")
  got=$(run_win "$proc_root" win_table 34568 910 'fm_harness_ancestry_pid') \
    || fail "the harness was not found across the MSYS/Win32 boundary"
  [ "$got" = 33796 ] \
    || fail "windows ancestry resolved '$got', expected the claude.exe session pid 33796"
  pass "windows: the ancestry crosses the MSYS fork boundary and resolves the native session"
}

test_windows_ancestry_stops_at_the_first_non_harness_gap() {
  local proc_root
  # 4242 is a live Claude session above the terminal, but pwsh sits between it
  # and this process, so it must never be claimed as this session's own.
  proc_root=$(make_proc_root "$TMP_ROOT/proc-gap" "910:27644:1")
  mkdir -p "$TMP_ROOT/gap-state"
  printf '4242\n' > "$TMP_ROOT/gap-state/.lock"
  if run_win "$proc_root" win_table 34568 910 \
    "fm_session_lock_owned_by_self '$TMP_ROOT/gap-state'"; then
    fail "an unrelated Claude session beyond the pwsh gap was accepted as this session's lock owner"
  fi
  printf '33796\n' > "$TMP_ROOT/gap-state/.lock"
  run_win "$proc_root" win_table 34568 910 \
    "fm_session_lock_owned_by_self '$TMP_ROOT/gap-state'" \
    || fail "the session's own lock was not recognized on windows"
  pass "windows: lock ownership stops at the first non-harness gap and accepts only its own run"
}

test_windows_version_named_session_is_identified() {
  local proc_root got
  proc_root=$(make_proc_root "$TMP_ROOT/proc-version" "910:27644:1")
  got=$(run_win "$proc_root" win_table_version_named 34568 910 'fm_harness_ancestry_pid') \
    || fail "a version-named Claude Code install was not identified on windows"
  [ "$got" = 33796 ] \
    || fail "windows version-named ancestry resolved '$got', expected 33796"
  pass "windows: a version-named Claude Code install is identified by its path component"
}

test_windows_ordinary_paths_are_never_harness_processes() {
  local proc_root
  proc_root=$(make_proc_root "$TMP_ROOT/proc-ordinary" "910:27644:1")
  if run_win "$proc_root" win_table_ordinary 34568 910 'fm_harness_ancestry_pid'; then
    fail "an ordinary .exe under ~/.claude was treated as a harness process on windows"
  fi
  if run_win "$proc_root" win_table_ordinary 34568 910 'fm_harness_pid_alive 27644'; then
    fail "an ordinary .exe under ~/.claude passed the harness-liveness predicate on windows"
  fi
  if run_win "$proc_root" win_table_ordinary 34568 910 'fm_harness_pid_alive 20576'; then
    fail "a path merely prefixed with a harness name passed the harness-liveness predicate"
  fi
  pass "windows: ordinary executables under a harness directory are not harness processes"
}

test_windows_liveness_is_table_membership_not_kill() {
  local proc_root
  proc_root=$(make_proc_root "$TMP_ROOT/proc-alive" "910:27644:1")
  # 33796 is a Win32 pid: `kill -0` would answer about a DIFFERENT process in
  # the MSYS pid space, so liveness must come from the table.
  run_win "$proc_root" win_table 34568 910 'fm_harness_pid_alive 33796' \
    || fail "a live Win32 harness pid was not seen as live"
  if run_win "$proc_root" win_table 34568 910 'fm_harness_pid_alive 999999'; then
    fail "a pid absent from the Win32 table was reported live"
  fi
  if run_win "$proc_root" win_table 34568 910 'fm_harness_pid_alive 20576'; then
    fail "a live NON-harness process (pwsh) was reported as a live harness"
  fi
  pass "windows: harness liveness is Win32 table membership, not an MSYS kill -0"
}

test_windows_backend_fails_closed_without_a_process_table() {
  local proc_root
  proc_root=$(make_proc_root "$TMP_ROOT/proc-empty" "910:27644:1")
  if FM_PROC_BACKEND=windows FM_PROC_ROOT_OVERRIDE="$proc_root" \
    bash -c '. "$1"; FM_WIN_PROC_TABLE=; FM_WIN_PS_EXE=/nonexistent-powershell; fm_harness_ancestry_pid' _ "$LIB" 2>/dev/null; then
    fail "the windows backend claimed an ancestry with no readable process table"
  fi
  pass "windows: an unreadable Win32 process table fails closed rather than guessing"
}

# --- symlink-free lock mode --------------------------------------------------

test_lock_works_without_symlinks() {
  local dir out
  dir="$TMP_ROOT/lock-nosymlink"
  mkdir -p "$dir"
  out=$(FM_LOCK_SYMLINKS=0 FM_STATE_OVERRIDE="$dir" bash -c '
    . "$1"
    L="$2/.lock.acquire"
    fm_lock_try_acquire "$L" || { echo "acquire-failed"; exit 0; }
    [ -d "$L" ] && [ ! -L "$L" ] || { echo "not-a-directory-lock"; exit 0; }
    [ "$(cat "$L/pid")" = "${BASHPID:-$$}" ] || { echo "owner-pid-not-published"; exit 0; }
    fm_lock_release "$L"
    [ -e "$L" ] && { echo "not-released"; exit 0; }
    fm_lock_try_acquire "$L" || { echo "reacquire-failed"; exit 0; }
    fm_lock_release "$L"
    echo ok
  ' _ "$WAKE_LIB" "$dir")
  [ "$out" = ok ] || fail "the symlink-free lock did not complete a clean acquire/release cycle: $out"
  # The failure this mode exists to prevent: a leaked lock path nobody holds,
  # which turns fm_lock_acquire_wait into an unbounded spin.
  [ -z "$(ls -A "$dir")" ] || fail "the symlink-free lock leaked state behind: $(ls -A "$dir")"
  pass "lock: a filesystem without symlinks gets an atomic directory lock, cleanly released"
}

test_lock_without_symlinks_is_mutually_exclusive() {
  local dir count
  dir="$TMP_ROOT/lock-race"
  mkdir -p "$dir"
  printf '0\n' > "$dir/counter"
  cat > "$dir/racer.sh" <<SH
. "$WAKE_LIB"
L="$dir/.contended"
for i in 1 2 3 4 5; do
  fm_lock_acquire_wait "\$L"
  n=\$(cat "$dir/counter" 2>/dev/null || echo 0)
  sleep 0.01
  printf '%s\n' "\$((n + 1))" > "$dir/counter"
  fm_lock_release "\$L"
done
SH
  for _ in 1 2 3 4; do
    FM_LOCK_SYMLINKS=0 bash "$dir/racer.sh" &
  done
  wait
  count=$(tr -d '[:space:]' < "$dir/counter")
  [ "$count" = 20 ] \
    || fail "the symlink-free lock did not serialize 4 writers over 5 rounds: counter=$count, expected 20"
  pass "lock: the symlink-free directory lock is mutually exclusive under contention"
}

test_lock_probe_does_not_leave_a_copied_directory() {
  local dir
  dir="$TMP_ROOT/lock-probe"
  mkdir -p "$dir"
  # The probe must clean up after itself even when `ln -s` DEEP-COPIES rather
  # than failing, which is exactly what MSYS does without Developer Mode.
  FM_STATE_OVERRIDE="$dir" bash -c '. "$1"; fm_lock_symlinks_available "$2" >/dev/null 2>&1 || true' _ "$WAKE_LIB" "$dir"
  [ -z "$(ls -A "$dir")" ] \
    || fail "the symlink capability probe left state behind: $(ls -A "$dir")"
  pass "lock: the symlink capability probe leaves nothing behind on either outcome"
}

test_windows_paths_are_normalized_for_the_matcher
test_windows_ancestry_resolves_the_session_across_the_msys_boundary
test_windows_ancestry_stops_at_the_first_non_harness_gap
test_windows_version_named_session_is_identified
test_windows_ordinary_paths_are_never_harness_processes
test_windows_liveness_is_table_membership_not_kill
test_windows_backend_fails_closed_without_a_process_table
test_lock_works_without_symlinks
test_lock_without_symlinks_is_mutually_exclusive
test_lock_probe_does_not_leave_a_copied_directory
