#!/usr/bin/env bash
# tests/fm-stat-shadowing.test.sh - verify Darwin BSD-stat helpers ignore a GNU
# stat earlier on PATH.
#
# On Darwin, GNU coreutils can put a GNU stat earlier on PATH than /usr/bin/stat.
# A bare `stat -f <fmt>` then reaches GNU stat, where `-f` means filesystem stat
# rather than BSD-format output and can leak a filesystem dump into callers.
# Runtime Darwin BSD-format calls use /usr/bin/stat so their syntax stays tied
# to the system BSD implementation.
#
# This test proves the invariant by installing a fake GNU-like stat that shadows
# /usr/bin/stat and asserting the helpers still return correct values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Darwin-only: the shadowing assertions require a real BSD /usr/bin/stat to
# shadow; on Linux the `stat -f` semantics differ and the helpers take the
# `stat -c` branch instead, so there is nothing meaningful to assert. Skip
# visibly (after lib.sh so `pass`/`fail` exist) rather than silently.
if [ "$(uname)" != Darwin ]; then
  pass "Darwin-only test: shadowing assertions require BSD /usr/bin/stat; skipping on $(uname -s)"
  exit 0
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-stat-shadowing.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- fake GNU stat that mimics ~/.local/bin/stat shadowing /usr/bin/stat -------

# A shadowed GNU stat does not interpret `-f <fmt>` as BSD-format output.
# We fail the tokens used in our helpers so callers cannot accidentally use the
# shadowed stat instead of /usr/bin/stat.
FAKE_STAT="$TMP_ROOT/fakebin/stat"
mkdir -p "$(dirname "$FAKE_STAT")"

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

# Prepend fakebin so the fake GNU stat shadows /usr/bin/stat
ORIGINAL_PATH="$PATH"
export PATH="$TMP_ROOT/fakebin:$ORIGINAL_PATH"

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
  fail "/usr/bin/stat -f %m sanity check failed — /usr/bin/stat is not working"
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

# Restore PATH before exit
PATH="$ORIGINAL_PATH"
