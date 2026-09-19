#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
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
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
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
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
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
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
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
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
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
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# --- unit layer: MSYS/Windows-native ancestry fallback ------------------------
#
# fm_harness_ancestry_pids_windows is tried only when the POSIX ps walk above
# finds no harness at all. It is driven directly (and through
# fm_harness_ancestry_pids to prove the trigger condition) behind a fake
# powershell.exe, a fake MSYS /proc tree, and an overridable starting pid, so
# these cases run on any host without a real MSYS winpid or a real Windows
# process table.

# Run one library expression with <fakebin> shadowing PATH, and the fake MSYS
# /proc tree and native Windows table under test. kill is stubbed identically
# to lib_eval. <start_pid> seeds FM_MSYS_PID_OVERRIDE so the hybrid fallback's
# logical-ancestry climb starts from a fixture-controlled pid instead of the
# real $$ of this bash -c subshell.
win_lib_eval() {  # <fakebin> <proc_root> <start_pid> <expression>
  local fakebin=$1 proc_root=$2 start_pid=$3 expr=$4
  PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$proc_root" \
    FM_MSYS_PID_OVERRIDE="$start_pid" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

# Write one fake MSYS /proc/<pid> entry for the hybrid fallback's
# logical-ancestry climb: <winpid> is always recorded, <ppid> only when this
# hop has a further MSYS-visible parent - a real MSYS root has no /proc/1, so
# the last hop in a chain omits it to model that boundary.
write_msys_proc_entry() {  # <proc_root> <msys-pid> <winpid> [<msys-ppid>]
  local root=$1 pid=$2 winpid=$3 ppid=${4:-}
  mkdir -p "$root/$pid"
  printf '%s\n' "$winpid" > "$root/$pid/winpid"
  [ -n "$ppid" ] && printf '%s\n' "$ppid" > "$root/$pid/ppid"
}

# A ps fixture whose whole ancestry is ordinary shells up to a host-shaped pid
# 1, so the POSIX walk above exhausts all 16 hops (well short of that here)
# without ever matching, exactly the condition that must trigger the fallback.
write_no_harness_ps_fixture() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
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
  1:comm=) printf '%s\n' systemd ;;
  1:args=) printf '%s\n' systemd ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
}

test_windows_fallback_skipped_when_winpid_unreadable() {
  local dir fakebin
  dir="$TMP_ROOT/windows-no-winpid"
  fakebin=$(fm_fakebin "$dir")
  write_no_harness_ps_fixture "$fakebin"
  # No proc tree and no powershell.exe stub at all: a powershell call would be
  # a hard failure (command not found), proving the fallback never gets that
  # far without a readable MSYS /proc/<pid>/winpid.
  if win_lib_eval "$fakebin" "$dir/no-such-proc" 500 'fm_harness_ancestry_pids'; then
    fail "ancestry succeeded with no harness in ps and no readable MSYS /proc winpid"
  fi
  pass "session-lock: the Windows fallback is a no-op when MSYS's /proc/<pid>/winpid is not readable"
}

test_windows_fallback_not_tried_when_posix_finds_a_harness() {
  local dir fakebin marker got
  dir="$TMP_ROOT/windows-not-needed"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  marker="$dir/state/powershell-called"
  # The real invoking pid is unknown here, so the wildcard branch stands in for
  # "whatever ordinary shell called this" and climbs straight to a harness at
  # pid 900, exactly test_harness_beyond_a_gap_never_owns_the_lock's shape.
  cat > "$fakebin/ps" <<'SH'
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
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' claude ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' bash ;;
  910:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/powershell.exe" <<SH
#!/usr/bin/env bash
touch "$marker"
exit 1
SH
  chmod +x "$fakebin/powershell.exe"
  got=$(win_lib_eval "$fakebin" "$dir/unused-proc" 900 'fm_harness_ancestry_pids') \
    || fail "the POSIX ancestry match was lost once the Windows fallback path was wired up"
  [ "$got" = 900 ] || fail "ancestry resolved '$got', expected the POSIX-matched harness pid 900"
  [ -e "$marker" ] && fail "the Windows fallback ran even though the POSIX walk already found a harness"
  pass "session-lock: the Windows fallback is never tried once the POSIX walk already found a harness"
}

test_windows_fallback_climbs_and_stops_like_posix_walk() {
  local dir fakebin proc_root got
  dir="$TMP_ROOT/windows-claude-chain"
  fakebin=$(fm_fakebin "$dir")
  write_no_harness_ps_fixture "$fakebin"
  proc_root="$dir/proc"
  # A single MSYS hop crossing directly to winpid 500 (no ppid entry, i.e. the
  # MSYS boundary is reached immediately) - the native side climbs freely
  # through an ordinary bash.exe, then hits a two-hop claude.exe chain, then
  # stops at the first gap above it - the same "climb, extend through Claude,
  # stop at the gap" shape as the POSIX walk.
  write_msys_proc_entry "$proc_root" 500 500
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
cat <<'TABLE'
500,600,bash.exe
600,700,claude.exe
700,800,claude.exe
800,900,cmd.exe
TABLE
SH
  chmod +x "$fakebin/powershell.exe"
  got=$(win_lib_eval "$fakebin" "$proc_root" 500 'fm_harness_ancestry_pids') \
    || fail "the Windows fallback found no harness in a table with a claude.exe chain"
  [ "$got" = "$(printf '600\n700')" ] \
    || fail "Windows fallback resolved '$got', expected the contiguous claude.exe run 600,700"
  pass "session-lock: the Windows fallback climbs past ordinary ancestors and stops at the gap after a claude chain"
}

test_windows_fallback_single_hop_harness_stops_immediately() {
  local dir fakebin proc_root got
  dir="$TMP_ROOT/windows-single-hop"
  fakebin=$(fm_fakebin "$dir")
  write_no_harness_ps_fixture "$fakebin"
  proc_root="$dir/proc"
  write_msys_proc_entry "$proc_root" 500 500
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
cat <<'TABLE'
500,600,codex.exe
600,700,claude.exe
TABLE
SH
  chmod +x "$fakebin/powershell.exe"
  got=$(win_lib_eval "$fakebin" "$proc_root" 500 'fm_harness_ancestry_pids') \
    || fail "the Windows fallback found no harness for a matching first hop"
  [ "$got" = 500 ] \
    || fail "Windows fallback resolved '$got', expected only the single non-claude match 500"
  pass "session-lock: the Windows fallback stops at a single non-claude match without climbing further"
}

test_windows_fallback_matches_case_insensitively_and_ignores_unknown_names() {
  local dir fakebin proc_root got
  dir="$TMP_ROOT/windows-case-insensitive"
  fakebin=$(fm_fakebin "$dir")
  write_no_harness_ps_fixture "$fakebin"
  proc_root="$dir/proc"
  write_msys_proc_entry "$proc_root" 500 500
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
cat <<'TABLE'
500,600,explorer.exe
600,700,Claude.EXE
TABLE
SH
  chmod +x "$fakebin/powershell.exe"
  got=$(win_lib_eval "$fakebin" "$proc_root" 500 'fm_harness_ancestry_pids') \
    || fail "the Windows fallback did not match a differently-cased claude executable name"
  [ "$got" = 600 ] \
    || fail "Windows fallback resolved '$got', expected the case-insensitive match at pid 600"
  pass "session-lock: the Windows fallback matches harness executable names case-insensitively"
}

test_windows_fallback_reports_failure_when_no_name_matches() {
  local dir fakebin proc_root
  dir="$TMP_ROOT/windows-no-match"
  fakebin=$(fm_fakebin "$dir")
  write_no_harness_ps_fixture "$fakebin"
  proc_root="$dir/proc"
  write_msys_proc_entry "$proc_root" 500 500
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
cat <<'TABLE'
500,600,explorer.exe
600,1,winlogon.exe
TABLE
SH
  chmod +x "$fakebin/powershell.exe"
  if win_lib_eval "$fakebin" "$proc_root" 500 'fm_harness_ancestry_pids'; then
    fail "the Windows fallback reported success from a table with no harness executable at all"
  fi
  pass "session-lock: the Windows fallback reports failure when nothing in the table is a known harness"
}

# The regression case for this fix: fm-lock.sh reported "cannot locate harness
# process in ancestry" in a real Herdr + Claude session on Windows even though
# claude.exe was genuinely a few hops up. Diagnosis showed MSYS's fork()
# emulation does not give a forked bash.exe a Windows ParentProcessId that
# resolves to anything live - only MSYS's own /proc/<pid>/ppid bookkeeping
# knows the real logical parent - and the real session chain nests several
# such MSYS-forked bash generations (one per script-calls-script hop) between
# the innermost shell and the native claude.exe ancestor.
test_windows_fallback_crosses_nested_msys_fork_ancestry() {
  local dir fakebin proc_root got
  dir="$TMP_ROOT/windows-nested-msys-fork"
  fakebin=$(fm_fakebin "$dir")
  write_no_harness_ps_fixture "$fakebin"
  proc_root="$dir/proc"
  # Three MSYS-forked bash generations (10 -> 11 -> 12) before the MSYS root
  # boundary (12 has no further ppid file, exactly like a real MSYS root
  # having no /proc/1). Each inner hop's own winpid (501, 502) is deliberately
  # NOT the crossing point, and the table below gives 501 a dead-end "native
  # parent" that a walk trusting Win32_Process.ParentProcessId for an
  # MSYS-forked pid would wrongly try to climb from and fail - reproducing the
  # exact shape of the real failure.
  write_msys_proc_entry "$proc_root" 10 501 11
  write_msys_proc_entry "$proc_root" 11 502 12
  write_msys_proc_entry "$proc_root" 12 500
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
cat <<'TABLE'
501,999,bash.exe
500,600,bash.exe
600,700,claude.exe
TABLE
SH
  chmod +x "$fakebin/powershell.exe"
  got=$(win_lib_eval "$fakebin" "$proc_root" 10 'fm_harness_ancestry_pids') \
    || fail "the Windows fallback did not cross a nested MSYS fork ancestry to reach the native claude.exe"
  [ "$got" = 600 ] \
    || fail "Windows fallback resolved '$got', expected the claude.exe pid 600 reached only via the topmost MSYS hop's winpid 500"
  pass "session-lock: the Windows fallback climbs MSYS's own /proc ancestry across nested fork() hops before crossing into the native Windows tree"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_windows_fallback_skipped_when_winpid_unreadable
test_windows_fallback_not_tried_when_posix_finds_a_harness
test_windows_fallback_climbs_and_stops_like_posix_walk
test_windows_fallback_single_hop_harness_stops_immediately
test_windows_fallback_matches_case_insensitively_and_ignores_unknown_names
test_windows_fallback_reports_failure_when_no_name_matches
test_windows_fallback_crosses_nested_msys_fork_ancestry
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
