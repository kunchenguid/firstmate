#!/usr/bin/env bash
# Verify the pre-staged unprivileged command-tool closure inside an Azure
# invocation, then execute exact argv. Local dispatch executes immediately.
#
# The trusted guest bootstrap downloads and verifies pinned ShellCheck and uv
# before deny-all repository-command networking begins.
#
# Usage:
#   fm-azure-runner-command.sh <argv...>
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: fm-azure-runner-command.sh <argv...>" >&2; exit 2; }
if [ "${FM_AZURE_RUNNER:-0}" != 1 ]; then
  exec "$@"
fi

TOOLS="$HOME/.fm-runner-tools"
mkdir -p "$TOOLS/bin"
chmod 700 "$TOOLS" "$TOOLS/bin"

[ -x "$TOOLS/bin/shellcheck" ] || { echo "azure-runner-command: staged ShellCheck is absent" >&2; exit 125; }
[ -x "$TOOLS/uv/uv" ] || { echo "azure-runner-command: staged uv is absent" >&2; exit 125; }
[ -d "$TOOLS/wheelhouse" ] || { echo "azure-runner-command: staged Agent Fleet wheelhouse is absent" >&2; exit 125; }
[ "$("$TOOLS/bin/shellcheck" --version | awk '/^version:/ {print $2}')" = 0.11.0 ] || { echo "azure-runner-command: staged ShellCheck version mismatch" >&2; exit 125; }
[ "$("$TOOLS/uv/uv" --version)" = "uv 0.9.10" ] || { echo "azure-runner-command: staged uv version mismatch" >&2; exit 125; }
export PATH="$TOOLS/bin:$TOOLS/uv:$PATH"
export UV_OFFLINE=1 UV_NO_INDEX=1 UV_NO_SYNC=1 UV_FIND_LINKS="$TOOLS/wheelhouse"
exec "$@"
