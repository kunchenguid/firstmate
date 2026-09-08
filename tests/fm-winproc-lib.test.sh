#!/usr/bin/env bash
# tests/fm-winproc-lib.test.sh - unit tests for the native Windows process
# bridge (bin/fm-winproc-lib.sh) and the two evidence sources the session-lock
# harness ancestry draws on (bin/fm-session-lock-lib.sh).
#
# This runs everywhere, not only on Windows. That is the point: the bridge is
# what decides whether this home may hold the session lock at all, so its logic
# has to be pinned on the platform CI actually runs. The library's documented
# seams supply both evidence sources from fixtures, so no Windows host, no
# PowerShell, and no live harness is needed.
#
# Every case that would populate the bridge's per-process memo runs inside its
# own subshell, and each seam rides in as a command prefix rather than an
# export. Both the snapshot of the process list and the resolved ancestry are
# cached on purpose, so a case run in this shell would answer the next case
# from the previous case's fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-lock-lib.sh"

# Fixture pids and images. HARNESS_WINPID stands in for a claude.exe and the
# other two for the Git Bash chain between it and this process.
HARNESS_WINPID=4242
SHELL_WINPID=4243
MID_WINPID=4244
HARNESS_IMAGE='C:\Users\fixture\.local\bin\claude.exe'
SHELL_IMAGE='C:\Program Files\Git\usr\bin\bash.exe'

# A ps -W fixture: PID PPID PGID WINPID TTY UID STIME COMMAND. Native rows
# carry ppid 0 exactly as the real thing does, which is why this source can
# never answer a parent question.
ps_fixture() {
  printf '%s\n' \
    "      PID    PPID    PGID     WINPID  TTY    UID    STIME COMMAND" \
    "  4194308       0       0 $HARNESS_WINPID  ?        0 09:50:35 $HARNESS_IMAGE" \
    "  4194309       0       0 $SHELL_WINPID  ?        0 09:50:36 $SHELL_IMAGE"
}

# The same rows with the harness absent, so source 1 can be withheld.
ps_fixture_no_harness() {
  printf '%s\n' \
    "      PID    PPID    PGID     WINPID  TTY    UID    STIME COMMAND" \
    "  4194309       0       0 $SHELL_WINPID  ?        0 09:50:36 $SHELL_IMAGE"
}

# A CIM fixture: "<pid> <ppid> <image>", carrying real parent links.
table_fixture() {
  printf '%s\n' \
    "$SHELL_WINPID $MID_WINPID $SHELL_IMAGE" \
    "$MID_WINPID $HARNESS_WINPID $SHELL_IMAGE" \
    "$HARNESS_WINPID 2532 $HARNESS_IMAGE"
}

# --- the backslash conversion, pinned ---------------------------------------
#
# A no-op conversion shipped once and no test noticed, because the harness
# regex is unanchored and matched the unconverted string by luck. Assert the
# transformation itself, not only the verdict it feeds.

CONVERTED=$(_fm_harness_native_comm "$HARNESS_IMAGE")
[ "$CONVERTED" = 'C:/Users/fixture/.local/bin/claude.exe' ] \
  || fail "backslash conversion wrong: got '$CONVERTED'"
[ "$CONVERTED" != "$HARNESS_IMAGE" ] \
  || fail "conversion was a no-op: input and output are identical"
pass "_fm_harness_native_comm converts every backslash to a forward slash"

# basename must see the real final component, which is the whole reason the
# conversion exists: MSYS basename splits on backslashes and GNU basename does
# not, so an unconverted path identifies different things on different hosts.
[ "$(basename -- "$CONVERTED")" = 'claude.exe' ] \
  || fail "converted path basename wrong: $(basename -- "$CONVERTED")"
pass "a converted image path yields its executable name as the basename"

if _fm_harness_native_comm "" >/dev/null 2>&1; then
  fail "_fm_harness_native_comm refused nothing: an empty path was accepted"
fi
pass "_fm_harness_native_comm refuses an empty path"

# --- inert when the bridge is unavailable ------------------------------------
#
# An unavailable bridge answers nothing at all, so none of these calls reach a
# loader and none of them need a subshell.

bridge_is_inert() {
  fm_winproc_available && return 1
  fm_winproc_self >/dev/null 2>&1 && return 1
  fm_winproc_command "$HARNESS_WINPID" >/dev/null 2>&1 && return 1
  fm_winproc_ppid "$SHELL_WINPID" >/dev/null 2>&1 && return 1
  fm_winproc_table_command "$HARNESS_WINPID" >/dev/null 2>&1 && return 1
  return 0
}

FM_WINPROC_DISABLE=1 bridge_is_inert \
  || fail "an unavailable bridge must make every entry point return 1"
pass "FM_WINPROC_DISABLE makes the whole bridge inert on any host"

# DISABLE must beat FORCE, so the inert path stays provable on Windows too.
bridge_unavailable() {
  fm_winproc_available && return 1
  return 0
}

FM_WINPROC_DISABLE=1 FM_WINPROC_FORCE=1 bridge_unavailable \
  || fail "FM_WINPROC_DISABLE must win over FM_WINPROC_FORCE"
pass "FM_WINPROC_DISABLE wins over FM_WINPROC_FORCE"

# --- source 1 alone: the harness-exported pid --------------------------------
#
# The table fixture is deliberately empty here, so a pass cannot be coming from
# the parent-chain walk.

OUT=$(FM_WINPROC_FORCE=1 FM_WINPROC_SELF="$SHELL_WINPID" \
  FM_WINPROC_PS_CMD=ps_fixture FM_WINPROC_TABLE_CMD=true \
  CLAUDE_PID="$HARNESS_WINPID" fm_harness_ancestry_pids) \
  || fail "source 1 alone did not resolve an ancestry"
[ "$OUT" = "$HARNESS_WINPID" ] || fail "source 1 resolved the wrong pid: '$OUT'"
pass "the harness-exported pid resolves the ancestry with no parent-chain data"

# Prove that case was not vacuous: with the table empty the walk really is
# unusable on its own.
table_has_no_parent() {
  fm_winproc_ppid "$SHELL_WINPID" >/dev/null 2>&1 && return 1
  return 0
}

( FM_WINPROC_FORCE=1 FM_WINPROC_SELF="$SHELL_WINPID" \
  FM_WINPROC_TABLE_CMD=true table_has_no_parent ) \
  || fail "an empty table must make the parent-chain walk unusable"
pass "with an empty process table the parent-chain source is genuinely absent"

# --- source 2 alone: the Windows parent chain --------------------------------
#
# CLAUDE_PID is cleared and the ps fixture omits the harness, so source 1
# cannot contribute. Only the parent chain can answer.

OUT=$(unset CLAUDE_PID; FM_WINPROC_FORCE=1 FM_WINPROC_SELF="$SHELL_WINPID" \
  FM_WINPROC_PS_CMD=ps_fixture_no_harness FM_WINPROC_TABLE_CMD=table_fixture \
  fm_harness_ancestry_pids) \
  || fail "source 2 alone did not resolve an ancestry"
[ "$OUT" = "$HARNESS_WINPID" ] || fail "source 2 resolved the wrong pid: '$OUT'"
pass "the Windows parent chain resolves the ancestry with no harness-exported pid"

# Prove that case was not vacuous either: source 1 really is absent.
ps_has_no_harness() {
  fm_winproc_command "$HARNESS_WINPID" >/dev/null 2>&1 && return 1
  return 0
}

( FM_WINPROC_FORCE=1 FM_WINPROC_PS_CMD=ps_fixture_no_harness \
  ps_has_no_harness ) \
  || fail "a ps fixture without the harness must not report its image"
pass "with the harness absent from ps the exported-pid source is genuinely absent"

# A stale exported pid must not win. The pid is set but ps does not list it, so
# the walk has to carry the verdict.
OUT=$(FM_WINPROC_FORCE=1 FM_WINPROC_SELF="$SHELL_WINPID" \
  FM_WINPROC_PS_CMD=ps_fixture_no_harness FM_WINPROC_TABLE_CMD=table_fixture \
  CLAUDE_PID=999999 fm_harness_ancestry_pids) \
  || fail "a stale exported pid must fall through to the parent chain"
[ "$OUT" = "$HARNESS_WINPID" ] || fail "stale exported pid produced '$OUT'"
pass "a dead harness-exported pid falls through to the parent chain"

# --- neither source: must fail closed ---------------------------------------
#
# The legacy ps ancestry walk is neutralized with a refusing fake, so the result
# cannot depend on whatever real process tree this test happens to run inside.

FAKEBIN="$(fm_test_tmproot winproc-fakebin)/bin"
mkdir -p "$FAKEBIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$FAKEBIN/ps"
chmod 0755 "$FAKEBIN/ps"

ancestry_refuses() {
  fm_harness_ancestry_pids >/dev/null 2>&1 && return 1
  return 0
}

( unset CLAUDE_PID
  PATH="$FAKEBIN:$PATH" FM_WINPROC_FORCE=1 FM_WINPROC_SELF="$SHELL_WINPID" \
    FM_WINPROC_PS_CMD=true FM_WINPROC_TABLE_CMD=true ancestry_refuses ) \
  || fail "with no evidence at all the ancestry must fail rather than guess"
pass "no evidence from either source fails closed"

# --- liveness ----------------------------------------------------------------
#
# All three cases share one fixture, so the cached snapshot is the same answer
# either way and these can run in this shell.

if ! FM_WINPROC_FORCE=1 FM_WINPROC_PS_CMD=ps_fixture \
  fm_harness_pid_alive "$HARNESS_WINPID"; then
  fail "a harness listed in ps must read as alive"
fi
pass "fm_harness_pid_alive accepts a harness image present in the process list"

if FM_WINPROC_FORCE=1 FM_WINPROC_PS_CMD=ps_fixture \
  fm_harness_pid_alive 999999; then
  fail "a pid absent from ps must not read as alive"
fi
pass "fm_harness_pid_alive rejects a pid absent from the process list"

# A live pid that is not a harness is not a harness. This is what stops an
# unrelated process inheriting the session lock after pid reuse.
if FM_WINPROC_FORCE=1 FM_WINPROC_PS_CMD=ps_fixture \
  fm_harness_pid_alive "$SHELL_WINPID"; then
  fail "a live non-harness pid must not read as a live harness"
fi
pass "fm_harness_pid_alive rejects a live process that is not a harness"

# --- the bridge file itself is absent -----------------------------------------
#
# Eighteen test fixtures build a partial bin/ holding only the scripts under
# test, so bin/fm-session-lock-lib.sh gets copied without its Windows sibling.
# A hard source there killed the library and failed three CI shards for reasons
# that had nothing to do with the cases being run. Reproduce that layout exactly
# and require the library to load and keep answering.

PARTIAL="$(fm_test_tmproot winproc-partial)/bin"
mkdir -p "$PARTIAL"
cp "$ROOT/bin/fm-session-lock-lib.sh" "$PARTIAL/fm-session-lock-lib.sh"
cp "$ROOT/bin/fm-cursor-lib.sh" "$PARTIAL/fm-cursor-lib.sh"
[ ! -e "$PARTIAL/fm-winproc-lib.sh" ]   || fail "the partial fixture must not contain the bridge"

if ! ABSENT_OUT=$(bash -c '
  . "$1/fm-session-lock-lib.sh" || { echo "SOURCE-FAILED"; exit 1; }
  fm_winproc_available && { echo "STUB-CLAIMED-AVAILABLE"; exit 1; }
  fm_harness_pid_alive 999999 && { echo "DEAD-PID-READ-AS-ALIVE"; exit 1; }
  echo LOADED
' _ "$PARTIAL" 2>&1); then
  fail "without the bridge the session-lock library must still load: $ABSENT_OUT"
fi
[ "$ABSENT_OUT" = LOADED ]   || fail "unexpected output with the bridge absent: $ABSENT_OUT"
pass "the session-lock library loads and still answers with the bridge absent"

# --- the census: both counts from one snapshot -------------------------------
#
# The herdr idle-shell proof asks whether a pane's shell is alone and childless.
# In table_fixture the shell is a lone leaf and MID_WINPID has exactly one
# child, which are the two shapes that proof has to tell apart.

CENSUS=$( FM_WINPROC_FORCE=1 FM_WINPROC_TABLE_CMD=table_fixture \
  fm_winproc_pid_census "$SHELL_WINPID" )
[ "$CENSUS" = "1 0" ] \
  || fail "a lone childless pid must census as '1 0', got '$CENSUS'"
pass "fm_winproc_pid_census reports a lone childless process as '1 0'"

CENSUS=$( FM_WINPROC_FORCE=1 FM_WINPROC_TABLE_CMD=table_fixture \
  fm_winproc_pid_census "$MID_WINPID" )
[ "$CENSUS" = "1 1" ] \
  || fail "a pid with one child must census as '1 1', got '$CENSUS'"
pass "fm_winproc_pid_census counts a child process"

CENSUS=$( FM_WINPROC_FORCE=1 FM_WINPROC_TABLE_CMD=table_fixture \
  fm_winproc_pid_census 999999 )
[ "$CENSUS" = "0 0" ] \
  || fail "a pid absent from the table must census as '0 0', got '$CENSUS'"
pass "fm_winproc_pid_census reports an absent pid as '0 0'"

( FM_WINPROC_DISABLE=1 fm_winproc_pid_census "$SHELL_WINPID" >/dev/null 2>&1 ) \
  && fail "the census must be inert when the bridge is unavailable"
pass "fm_winproc_pid_census is inert with the bridge unavailable"

( FM_WINPROC_FORCE=1 FM_WINPROC_TABLE_CMD=table_fixture \
  fm_winproc_pid_census 'not-a-pid' >/dev/null 2>&1 ) \
  && fail "the census must refuse a non-numeric pid"
pass "fm_winproc_pid_census refuses a non-numeric pid"

# --- the flush: a deliberate re-observation sees the new truth ----------------
#
# Memoization is right for one moment and wrong across an action: a caller that
# signals a process and then re-asks whether it is gone must not be answered
# from the snapshot taken before the signal. The three reads below run as direct
# calls rather than command substitutions, because a substitution's subshell
# would discard the memo and hide the very staleness this pins.

table_shell_alive() { printf '%s\n' "$SHELL_WINPID $MID_WINPID $SHELL_IMAGE"; }
table_shell_exited() { printf '%s\n' "$MID_WINPID 1 $SHELL_IMAGE"; }

FLUSH_DIR=$(fm_test_tmproot winproc-flush)
( export FM_WINPROC_FORCE=1
  export FM_WINPROC_TABLE_CMD=table_shell_alive
  fm_winproc_pid_census "$SHELL_WINPID" > "$FLUSH_DIR/first"
  export FM_WINPROC_TABLE_CMD=table_shell_exited
  fm_winproc_pid_census "$SHELL_WINPID" > "$FLUSH_DIR/stale"
  fm_winproc_flush
  fm_winproc_pid_census "$SHELL_WINPID" > "$FLUSH_DIR/fresh" )
[ "$(cat "$FLUSH_DIR/first")" = "1 0" ] \
  || fail "the first census must see the live shell"
[ "$(cat "$FLUSH_DIR/stale")" = "1 0" ] \
  || fail "without a flush the memo must still answer from the first snapshot"
[ "$(cat "$FLUSH_DIR/fresh")" = "0 0" ] \
  || fail "after a flush the census must see the exited shell, got '$(cat "$FLUSH_DIR/fresh")'"
pass "fm_winproc_flush drops the memo so a re-observation is genuinely fresh"

echo "# fm-winproc-lib.test.sh: all assertions passed"
