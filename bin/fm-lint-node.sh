#!/usr/bin/env bash
# fm-lint-node.sh - parse every JavaScript tool in bin/, the way fm-lint.sh
# parses every shell script.
#
# Usage:
#   bin/fm-lint-node.sh [file...]
#
# ShellCheck's file set is `bin/*.sh bin/backends/*.sh tests/*.sh`, so the .mjs
# and .cjs tools in bin/ were parsed by nothing. A syntax error in one of them
# reached main with a green lint. `node --check` is not a linter and does not
# pretend to be one; it is the parse that was missing.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)

command -v node >/dev/null 2>&1 || {
  echo "fm-lint-node: node is required to parse the JavaScript tools" >&2
  exit 1
}

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  # Canonical file set, the same shape fm-lint.sh owns for shell.
  files=("$ROOT"/bin/*.mjs "$ROOT"/bin/*.cjs)
fi

printf 'fm-lint-node: %s (%s files)\n' "$(node --version)" "${#files[@]}" >&2
status=0
for file in "${files[@]}"; do
  [ -e "$file" ] || continue
  # --check parses without executing, so a tool with import-time side effects
  # is still safe to lint.
  node --check "$file" || status=1
done
exit "$status"
