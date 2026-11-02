#!/usr/bin/env bash
# Regression tests for the anchored absence assertion helper in tests/lib.sh.
#
# The failure this suite pins: an anchored pattern handed to a fixed-string grep
# assertion searches for a literal caret and so passes no matter what the file
# holds. assert_no_regex accepts a clean absence, and rejects a matching line, a
# missing file, an invalid pattern, and a directory. The last case pins the
# escaped interactive-agent label guard: the anchored label pattern must tolerate
# the secondmate label's `.fm-remote` suffix and a dot-substituted lookalike that
# a literal-dot pattern would have matched, yet still reject the label itself.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-assertions)
printf 'backend=tmux\n' > "$TMP_ROOT/meta"
assert_no_regex '^mode=' "$TMP_ROOT/meta" 'absent field failed'
: > "$TMP_ROOT/empty"
assert_no_regex '^backend=' "$TMP_ROOT/empty" 'empty file failed'

for input in match missing invalid directory; do
  pattern='^backend='
  file="$TMP_ROOT/meta"
  case "$input" in
    missing) file="$TMP_ROOT/missing" ;;
    invalid) pattern='[' ;;
    directory) file="$TMP_ROOT" ;;
  esac
  if (assert_no_regex "$pattern" "$file" 'expected rejection') >"$TMP_ROOT/out" 2>&1; then
    fail "$input incorrectly passed absence assertion"
  fi
done

label=dev.firstmate.herdr
pattern="gui/123/${label//./\\.}$"
printf 'print gui/123/dev.firstmate.herdr.fm-remote\nprint gui/123/devXfirstmateXherdr\n' > "$TMP_ROOT/launchctl"
assert_no_regex "$pattern" "$TMP_ROOT/launchctl" 'dedicated or unrelated label rejected'
printf 'print gui/123/dev.firstmate.herdr\n' >> "$TMP_ROOT/launchctl"
if (assert_no_regex "$pattern" "$TMP_ROOT/launchctl" 'expected rejection') >"$TMP_ROOT/out" 2>&1; then
  fail 'interactive label incorrectly passed absence assertion'
fi
pass 'regex absence distinguishes no match from matches and errors'
