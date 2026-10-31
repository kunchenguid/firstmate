#!/usr/bin/env bash
set -eu

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
