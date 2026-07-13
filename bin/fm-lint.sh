#!/usr/bin/env bash
# Usage: bin/fm-lint.sh
# Run the repository ShellCheck lint suite.
set -euo pipefail

files=(bin/*.sh bin/backends/*.sh tests/*.sh)

if command -v shellcheck >/dev/null 2>&1; then
  exec shellcheck "${files[@]}"
fi

if command -v docker >/dev/null 2>&1; then
  exec docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable "${files[@]}"
fi

printf 'shellcheck is required; install shellcheck or provide docker for the container fallback\n' >&2
exit 127
