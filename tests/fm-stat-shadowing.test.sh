#!/usr/bin/env bash
# tests/fm-stat-shadowing.test.sh - verify fleet scripts ignore user-installed
# shims that shadow platform system tools earlier on PATH.
#
# On Darwin, GNU coreutils can put a GNU stat earlier on PATH than /usr/bin/stat.
# A bare `stat -f <fmt>` then reaches GNU stat, where `-f` means filesystem stat
# rather than BSD-format output and can leak a filesystem dump into callers.
# Runtime Darwin BSD-format calls use /usr/bin/stat so their syntax stays tied
# to the system BSD implementation. The stat assertions are Darwin-only: on
# Linux the `stat -f` semantics differ and the helpers take the `stat -c`
# branch instead, so there is nothing meaningful to shadow there.
#
# The same failure class hit `od`: a desktop application installed a CLI shim
# at ~/.local/bin/od ahead of /usr/bin/od, and every bare `od` call consumed its
# usage text as if it were hex output (2026-10-23 watcher flap: poisoned status
# signatures re-reported every file each cycle, and colliding procevent marker
# names silently dropped deliveries). All od call sites are pinned to
# /usr/bin/od, which is the real tool's path on both Darwin and Linux, so the
# od assertions run on every platform.
#
# This test proves the invariant by installing fakes that shadow the real tools
# and asserting the helpers still return correct values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-stat-shadowing.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

DARWIN=no
[ "$(uname -s)" = Darwin ] && DARWIN=yes

# --- fake GNU stat that mimics ~/.local/bin/stat shadowing /usr/bin/stat -------

# A shadowed GNU stat does not interpret `-f <fmt>` as BSD-format output.
# We fail the tokens used in our helpers so callers cannot accidentally use the
# shadowed stat instead of /usr/bin/stat. The fake is Darwin-only: on Linux the
# helpers legitimately call bare `stat -c`, which must keep reaching the real
# GNU stat, so shadowing stat there would only break the fixture itself.
FAKE_STAT="$TMP_ROOT/fakebin/stat"
mkdir -p "$(dirname "$FAKE_STAT")"

if [ "$DARWIN" = yes ]; then
cat > "$FAKE_STAT" <<'FAKESTAT'
#!/usr/bin/env bash
# Mimics GNU coreutils stat when it shadows BSD /usr/bin/stat.
# On Darwin: BSD stat uses %m (mtime), %z (size), etc.
# GNU stat -f treats its argument as a filesystem-path option, not a format.
# For the format tokens our code uses, this fake exits non-zero before a helper
# could consume shadowed output.
opt1=${1:-} opt2=${2:-}
if [ "$opt1" = "-f" ]; then
  case "$opt2" in
    %m|%l|%z|%d|%Lp|%i|%u|%B|%FB|%HT:%p|%d:%i|%d:%i:%z:%m:%c)
      printf 'File: "%s"\n' "${3:-}" >&2
      exit 1
      ;;
    *)
      printf 'GNU stat: unknown -f format: %s\n' "$opt2" >&2
      exit 1
      ;;
  esac
fi
printf 'GNU stat: unknown invocation: %s\n' "$*" >&2
exit 1
FAKESTAT
chmod +x "$FAKE_STAT"
fi

# --- fake od that mimics the observed ~/.local/bin/od desktop-app shim --------

# The shim that motivated the od pinning prints multi-line usage text to stdout
# and exits non-zero for the -An invocations fleet scripts use. The garbage
# lands on STDOUT, where a trailing `tr` in the pipeline masks the exit code,
# so the consumer silently treats usage text as encoded bytes.
FAKE_OD="$TMP_ROOT/fakebin/od"

cat > "$FAKE_OD" <<'FAKEOD'
#!/usr/bin/env bash
# Mimics a desktop-app CLI shim shadowing /usr/bin/od: usage text on stdout,
# non-zero exit for the system's octal-dump options.
printf 'Usage: od-shim [--port <n>] [--host <addr>]\n'
printf 'A shim must never stand in for the octal-dump tool.\n'
printf 'od-shim: unknown option: %s\n' "${1:-}" >&2
exit 2
FAKEOD
chmod +x "$FAKE_OD"

# Prepend fakebin so the fakes shadow /usr/bin/od everywhere, and
# /usr/bin/stat on Darwin where the stat fake is installed.
ORIGINAL_PATH="$PATH"
export PATH="$TMP_ROOT/fakebin:$ORIGINAL_PATH"

# The od pinning targets /usr/bin/od on every supported platform; a platform
# without the real tool there would make the pinned calls fail, so fail loudly
# here rather than passing vacuously.
[ -x /usr/bin/od ] || {
  PATH="$ORIGINAL_PATH"
  fail "/usr/bin/od is missing or not executable on this platform"
}

# Verify the od shadowing is active: a bare `od -An -v -tx1` must reach the
# fake (garbage on stdout, non-zero exit), not the real octal-dump tool.
if od -An -v -tx1 </dev/null >/dev/null 2>&1; then
  PATH="$ORIGINAL_PATH"
  fail "shadowing sanity check: bare od -An -v -tx1 should fail under the shim but did not"
fi
if [ -n "$(/usr/bin/od -An -v -tx1 </dev/null 2>/dev/null)" ]; then
  PATH="$ORIGINAL_PATH"
  fail "/usr/bin/od sanity check failed - the real tool printed output for empty input"
fi
pass "shadowing: fake od shim shadows /usr/bin/od in PATH"

if [ "$DARWIN" = yes ]; then
# Verify the shadowing is active: a bare `stat -f %m /` must fail (not use BSD)
if stat -f %m / >/dev/null 2>&1; then
  # The fake stat didn't catch this, so something is wrong with the PATH setup
  PATH="$ORIGINAL_PATH"
  fail "shadowing sanity check: bare stat -f %m / should fail under GNU-shadow but did not"
fi

# Also verify /usr/bin/stat still works when called directly
REAL_MTIME=$(/usr/bin/stat -f %m "$0" 2>/dev/null) || true
[ -n "$REAL_MTIME" ] && [ "$REAL_MTIME" -ge 0 ] || {
  PATH="$ORIGINAL_PATH"
  fail "/usr/bin/stat -f %m sanity check failed - /usr/bin/stat is not working"
}
pass "shadowing: fake GNU stat shadows /usr/bin/stat in PATH"

# --- test the fixed helpers under shadowing ----------------------------------

. "$ROOT/bin/fm-supervision-lib.sh"
. "$ROOT/bin/fm-startup-memory-budget-lib.sh"

TESTFILE="$TMP_ROOT/testfile"
printf 'hello world\n' > "$TESTFILE"

# 1. fm_sup_stat_mtime from bin/fm-supervision-lib.sh
RESULT_MTIME=$(fm_sup_stat_mtime "$TESTFILE") || true
EXPECTED_MTIME=$(/usr/bin/stat -f %m "$TESTFILE" 2>/dev/null)
if [ -z "$RESULT_MTIME" ] || [ "$RESULT_MTIME" != "$EXPECTED_MTIME" ]; then
  PATH="$ORIGINAL_PATH"
  fail "fm_sup_stat_mtime: expected $EXPECTED_MTIME, got '$RESULT_MTIME'"
fi
pass "fm_sup_stat_mtime returns correct epoch mtime under GNU stat shadowing"

# 2. fm_startup_memory_budget_link_count from bin/fm-startup-memory-budget-lib.sh
RESULT_LINKS=$(fm_startup_memory_budget_link_count "$TESTFILE") || true
EXPECTED_LINKS=$(/usr/bin/stat -f %l "$TESTFILE" 2>/dev/null)
if [ -z "$RESULT_LINKS" ] || [ "$RESULT_LINKS" != "$EXPECTED_LINKS" ]; then
  PATH="$ORIGINAL_PATH"
  fail "fm_startup_memory_budget_link_count: expected $EXPECTED_LINKS, got '$RESULT_LINKS'"
fi
pass "fm_startup_memory_budget_link_count returns correct link count under GNU stat shadowing"

# 3. _fm_status_file_size from bin/fm-classify-lib.sh
#    We source it and call the internal function directly.
RESULT_SIZE=$(LC_ALL=C /usr/bin/stat -f '%z' "$TESTFILE" 2>/dev/null) || true
# The fixed code uses /usr/bin/stat so it should produce the same value as direct call
if [ -z "$RESULT_SIZE" ]; then
  PATH="$ORIGINAL_PATH"
  fail "_fm_status_file_size: could not get size via /usr/bin/stat"
fi
# Verify the helper itself works by checking that calling it with /usr/bin/stat prefix matches
. "$ROOT/bin/fm-classify-lib.sh"
HELPER_SIZE=$(_fm_status_file_size "$TESTFILE") || true
if [ -z "$HELPER_SIZE" ] || [ "$HELPER_SIZE" != "$RESULT_SIZE" ]; then
  PATH="$ORIGINAL_PATH"
  fail "_fm_status_file_size: expected $RESULT_SIZE, got '$HELPER_SIZE'"
fi
pass "_fm_status_file_size returns correct byte size under GNU stat shadowing"

# 4. stat_mtime from bin/fm-watch.sh
# fm-watch.sh runs a top-level `mkdir -p` on its state dir when sourced; pin it
# to the temp root via FM_STATE_OVERRIDE so no artifact escapes into the repo's
# git-ignored state/ directory.
export FM_STATE_OVERRIDE="$TMP_ROOT/state"
. "$ROOT/bin/fm-watch.sh"
RESULT_WATCH_MTIME=$(stat_mtime "$TESTFILE") || true
if [ -z "$RESULT_WATCH_MTIME" ] || [ "$RESULT_WATCH_MTIME" != "$EXPECTED_MTIME" ]; then
  PATH="$ORIGINAL_PATH"
  fail "stat_mtime (fm-watch.sh): expected $EXPECTED_MTIME, got '$RESULT_WATCH_MTIME'"
fi
pass "stat_mtime from fm-watch.sh returns correct epoch mtime under GNU stat shadowing"
else
pass "Darwin-only stat shadowing assertions skipped on $(uname -s)"
fi

# --- test the od call sites under shim shadowing (all platforms) --------------

# fm-classify-lib.sh and fm-watch.sh are already sourced on Darwin; source them
# here on the other platforms so the od assertions run identically everywhere.
if [ "$DARWIN" != yes ]; then
  . "$ROOT/bin/fm-classify-lib.sh"
  export FM_STATE_OVERRIDE="$TMP_ROOT/state"
  . "$ROOT/bin/fm-watch.sh"
fi

# 1. status_observed_signature is the 2026-10-23 flap's root cause: under the
# shim it returned the usage text as the "hex" payload, which the marker reader
# then refused to parse, re-reporting every status file on every cycle.
SHADOWED_FILE="$TMP_ROOT/shadowed.status"
printf 'working: shadow probe\n' > "$SHADOWED_FILE"
SIG=$(status_observed_signature "$SHADOWED_FILE") || {
  PATH="$ORIGINAL_PATH"
  fail "status_observed_signature failed outright under od shim shadowing"
}
case "$SIG" in
  r1:*) SIG_HEX=${SIG#r1:} ;;
  *)
    PATH="$ORIGINAL_PATH"
    fail "status_observed_signature lost its r1: prefix under od shim shadowing: ${SIG:0:80}"
    ;;
esac
case "$SIG_HEX" in
  ''|*[!0-9a-f]*)
    PATH="$ORIGINAL_PATH"
    fail "status_observed_signature returned a non-hex signature under od shim shadowing: ${SIG:0:80}"
    ;;
esac
pass "status_observed_signature returns a valid r1:hex signature under od shim shadowing"

# 2. status_presentation_marker_commit must refuse to persist a signature the
# reader side cannot parse, so one bad encode alarms once per watcher lifetime
# instead of poisoning the marker for every later cycle. The pinned od keeps a
# real signature valid, so feed the commit a broken encoder by stubbing the
# signature function the way the shim did.
COMMIT_FILE="$TMP_ROOT/commit.status"
printf 'working: commit probe\n' > "$COMMIT_FILE"
COMMIT_MARKER="$TMP_ROOT/.seen-commit_status"
COMMIT_SIZE=$(_fm_status_file_size "$COMMIT_FILE") || {
  PATH="$ORIGINAL_PATH"
  fail "could not size the commit fixture"
}
COMMIT_IDENT=$(_fm_open_decisions_file_ident "$COMMIT_FILE") || {
  PATH="$ORIGINAL_PATH"
  fail "could not identify the commit fixture"
}
status_presentation_marker_commit "$COMMIT_MARKER" "$COMMIT_FILE" "$COMMIT_SIZE" "$COMMIT_IDENT" || {
  PATH="$ORIGINAL_PATH"
  fail "status_presentation_marker_commit refused a valid signature"
}
SAVED_MARKER=$(cat "$COMMIT_MARKER")
status_observed_signature() { printf 'r1:Usage:od-shim-garbage'; }
if status_presentation_marker_commit "$COMMIT_MARKER" "$COMMIT_FILE" "$COMMIT_SIZE" "$COMMIT_IDENT" 2>/dev/null; then
  PATH="$ORIGINAL_PATH"
  fail "status_presentation_marker_commit persisted an unparseable signature"
fi
unset -f status_observed_signature
[ "$(cat "$COMMIT_MARKER")" = "$SAVED_MARKER" ] || {
  PATH="$ORIGINAL_PATH"
  fail "status_presentation_marker_commit clobbered the prior marker on a refused write"
}
pass "status_presentation_marker_commit refuses an unparseable signature and preserves the marker"

# 3. procevent_surfaced_marker names the per-source dedup marker from the od
# hex encoding of the queue key: under the shim every key collapsed onto one
# garbage name (a silent missed delivery), and a name holding '/' could never
# be created at all.
MARKER_A=$(procevent_surfaced_marker "adapter.source-a")
MARKER_B=$(procevent_surfaced_marker "adapter.source-b")
NAME_A=${MARKER_A##*/}
NAME_B=${MARKER_B##*/}
case "$NAME_A" in
  .seen-procevent-[0-9a-f]*) ;;
  *)
    PATH="$ORIGINAL_PATH"
    fail "procevent_surfaced_marker produced a non-hex marker name: $MARKER_A"
    ;;
esac
[ "$NAME_A" != "$NAME_B" ] || {
  PATH="$ORIGINAL_PATH"
  fail "procevent_surfaced_marker collapsed two distinct queue keys onto one marker name"
}
pass "procevent_surfaced_marker yields distinct slash-free hex names per queue key"

# Restore PATH before exit
PATH="$ORIGINAL_PATH"
