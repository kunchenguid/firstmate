#!/usr/bin/env bash
# Repo-wide bash parse sweep for the macOS system bash (3.2) bug class.
#
# Every script here runs via `#!/usr/bin/env bash`, and on stock macOS that
# resolves to /bin/bash 3.2.57. Bash 3.2's lexer mis-tracks quote state inside
# a heredoc nested in `$(...)` (see tests/fm-brief.test.sh and issue #166), so
# a script can parse cleanly on a modern bash yet fail to launch at all on the
# captain's machine. This sweep runs `bash -n` over the whole toolbelt and the
# test suite with the strictest parser available: /bin/bash when it is a 3.x
# bash (macOS), else PATH bash. On Linux CI that fallback is a modern bash
# whose rewritten command-substitution parser accepts the 3.2-breaking
# constructs, so ci.yml pairs this with a true bash-3.2 docker parse job.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pick_parse_bash() {
  if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = 3 ]; then
    printf '/bin/bash'
  else
    printf 'bash'
  fi
}

test_toolbelt_and_tests_parse() {
  local parse_bash parse_ver f rc=0
  parse_bash=$(pick_parse_bash)
  # shellcheck disable=SC2016  # single quotes are deliberate: $BASH_VERSION expands in the probed bash, not here
  parse_ver=$("$parse_bash" -c 'echo "$BASH_VERSION"')
  for f in "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh "$ROOT"/tests/*.sh; do
    "$parse_bash" -n "$f" || { echo "parse failure: $f" >&2; rc=1; }
  done
  [ "$rc" = 0 ] || fail "one or more scripts fail $parse_bash -n (bash 3.2 compatibility regression)"
  pass "all bin/, bin/backends/, and tests/ scripts parse under $parse_bash ($parse_ver)"
}

test_toolbelt_and_tests_parse
