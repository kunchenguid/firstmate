#!/usr/bin/env bash
# Establish the unprivileged command-tool closure inside an Azure invocation,
# then execute exact argv. Local dispatch skips setup and executes immediately.
#
# The guest root bootstrap owns only OS transport/test prerequisites. This
# helper installs repository-pinned ShellCheck and exact uv 0.9.10 into the
# invocation-private unprivileged HOME, never system-wide.
#
# Usage:
#   fm-azure-runner-command.sh <argv...>
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: fm-azure-runner-command.sh <argv...>" >&2; exit 2; }
if [ "${FM_AZURE_RUNNER:-0}" != 1 ]; then
  exec "$@"
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TOOLS="$HOME/.fm-runner-tools"
mkdir -p "$TOOLS/bin"
chmod 700 "$TOOLS" "$TOOLS/bin"

if [ ! -x "$TOOLS/bin/shellcheck" ]; then
  RUNNER_TEMP="$HOME" "$ROOT/bin/fm-install-shellcheck.sh" "$TOOLS/bin" >/dev/null
fi
if [ ! -x "$TOOLS/uv/bin/uv" ]; then
  python3 -m venv "$TOOLS/uv"
  printf '%s\n' 'uv==0.9.10 --hash=sha256:21981bc859802c94d4b8f026b8734d39e8146baac703f1e3eab2e2d87d65ca8c' >"$TOOLS/uv.requirements.txt"
  "$TOOLS/uv/bin/python" -m pip install \
    --index-url https://pypi.org/simple \
    --disable-pip-version-check \
    --no-cache-dir \
    --require-hashes \
    --requirement "$TOOLS/uv.requirements.txt"
fi
export PATH="$TOOLS/bin:$TOOLS/uv/bin:$PATH"
exec "$@"
