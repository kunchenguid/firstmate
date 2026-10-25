#!/usr/bin/env bash
# Read proposed publication text on stdin. Exit 1 for Lavish, 0 for clean text;
# grep/read errors keep their own diagnostics and exit code. No command/file interception.
set -u
pattern='https?://[^/[:space:]?#]+:4387([/?#[:space:]"<>)]|$)|(^|[^[:alnum:]_-])lavish-axi([^[:alnum:]_-]|$)'
if grep -Ei "$pattern" >/dev/null; then
  echo 'owner-rules: Lavish publication refused; use the sign-off board (sign-off-axi) instead' >&2
  exit 1
else
  rc=$?
  [ "$rc" -eq 1 ] || exit "$rc"
fi
exit 0
