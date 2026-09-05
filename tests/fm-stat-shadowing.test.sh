#!/usr/bin/env bash
# tests/fm-stat-shadowing.test.sh - verify Darwin stat helpers survive GNU coreutils
# stat shadowing /usr/bin/stat on hosts where ~/.local/bin/stat (GNU) precedes
# /usr/bin/stat in PATH.
#
# When GNU stat shadows BSD stat, `stat -f <fmt>` no longer means "format the
# output" — it means "print a filesystem dump" and prints the literal text
# `File: "<path>"` to stdout before failing on the format token. Callers that
# feed the output into arithmetic (e.g. `age=$(( $(date +%s) - m ))`) crash
# under `set -u` with "unbound variable" on the stray token.
#
# The fix: all Darwin `stat -f` calls in bin/ are prefixed with `/usr/bin/stat`
# to bypass any PATH-shadowing wrapper.
#
# This test proves the fix works by installing a fake GNU-like stat that shadows
# /usr/bin/stat and asserting the helpers still return correct values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$(uname)" = Darwin ] || { echo "skip: Darwin only"; exit 0; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-stat-shadowing.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- fake GNU stat that mimics ~/.local/bin/stat shadowing /usr/bin/stat -------

# GNU stat -f <fmt> prints a filesystem dump starting with `File: "<path>"` and
# exits non-zero when the format token is unrecognized by the filesystem path.
# We simulate this for the tokens used in our helpers so callers fail or produce
# garbage when they use the shadowed stat instead of /usr/bin/stat.
FAKE_STAT="$TMP_ROOT/fakebin/stat"
mkdir -p "$(dirname "$FAKE_STAT")"

cat > "$FAKE_STAT" <<'FAKESTAT'
#!/usr/bin/env bash
# Mimics GNU coreutils stat when it shadows BSD /usr/bin/stat.
# On Darwin: BSD stat uses %m (mtime), %z (size), etc.
# GNU stat -f treats its argument as a filesystem-path option, not a format.
# For the format tokens our code uses, GNU stat prints the filesystem dump
# starting with `File: "..."` and exits non-zero on the format token.
# We simulate exactly that failure mode.
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
  # The fake stat didn't catch this — something is wrong with the PATH setup
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

# 3. _fm_status_file_size from bin/fm-classify-lib.sh (LC_ALL=C stat -f '%z')
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
. "$ROOT/bin/fm-watch.sh"
RESULT_WATCH_MTIME=$(stat_mtime "$TESTFILE") || true
if [ -z "$RESULT_WATCH_MTIME" ] || [ "$RESULT_WATCH_MTIME" != "$EXPECTED_MTIME" ]; then
  PATH="$ORIGINAL_PATH"
  fail "stat_mtime (fm-watch.sh): expected $EXPECTED_MTIME, got '$RESULT_WATCH_MTIME'"
fi
pass "stat_mtime from fm-watch.sh returns correct epoch mtime under GNU stat shadowing"

# Restore PATH before exit
PATH="$ORIGINAL_PATH"
