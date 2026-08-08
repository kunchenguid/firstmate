#!/usr/bin/env bash
# Run or verify the independent exact-head crosscheck ledger for a task PR.
#
# Usage:
#   fm-crosscheck.sh run <task-id> <full GitHub PR URL>
#   fm-crosscheck.sh verify <task-id> <full GitHub PR URL>
#   fm-crosscheck.sh merge <task-id> <full GitHub PR URL> <reviewed SHA> <method>
#
# `run` is intentionally independent of no-mistakes so both reviews can be in
# flight together once a PR exists. `verify` is the merge-gate operation: it
# re-reads live GitHub state, requires the latest attempt for that exact head
# and claims document to be clear, and prints only the reviewed SHA.
# `merge` repeats that verification and is the sole entrypoint to the private
# exact-SHA GitHub merge primitive.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

FM_CROSSCHECK_REQUIRED_PYTHON=3.11
fm_crosscheck_probe_python() {
  local candidate=$1
  FM_CROSSCHECK_PROBE_PATH=$(command -v "$candidate" 2>/dev/null || true)
  if [ -z "$FM_CROSSCHECK_PROBE_PATH" ]; then
    FM_CROSSCHECK_PROBE_RESULT="'$candidate' (not found)"
    return 1
  fi

  if FM_CROSSCHECK_PROBE_VERSION=$("$FM_CROSSCHECK_PROBE_PATH" -c '
import sys
print(".".join(str(part) for part in sys.version_info[:3]))
raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)
' 2>/dev/null); then
    FM_CROSSCHECK_PROBE_RESULT="'$candidate' -> '$FM_CROSSCHECK_PROBE_PATH' (Python $FM_CROSSCHECK_PROBE_VERSION)"
    return 0
  fi

  if [ -n "$FM_CROSSCHECK_PROBE_VERSION" ]; then
    FM_CROSSCHECK_PROBE_RESULT="'$candidate' -> '$FM_CROSSCHECK_PROBE_PATH' (Python $FM_CROSSCHECK_PROBE_VERSION, too old)"
  else
    FM_CROSSCHECK_PROBE_RESULT="'$candidate' -> '$FM_CROSSCHECK_PROBE_PATH' (did not report a usable Python version)"
  fi
  return 1
}

interpreter=
requested=${FM_CROSSCHECK_PYTHON:-}
if [ -n "$requested" ]; then
  if fm_crosscheck_probe_python "$requested"; then
    interpreter=$FM_CROSSCHECK_PROBE_PATH
  else
    printf 'CROSSCHECK UNREVIEWED: Python %s or newer is required; looked for FM_CROSSCHECK_PYTHON=%s and found %s. Install a supported Python or correct/unset FM_CROSSCHECK_PYTHON.\n' \
      "$FM_CROSSCHECK_REQUIRED_PYTHON" "'$requested'" "$FM_CROSSCHECK_PROBE_RESULT" >&2
    exit 1
  fi
else
  looked_for='python3.14, python3.13, python3.12, python3.11, python3'
  found=
  for candidate in python3.14 python3.13 python3.12 python3.11 python3; do
    if fm_crosscheck_probe_python "$candidate"; then
      interpreter=$FM_CROSSCHECK_PROBE_PATH
      break
    fi
    if [ -n "$found" ]; then
      found="$found; $FM_CROSSCHECK_PROBE_RESULT"
    else
      found=$FM_CROSSCHECK_PROBE_RESULT
    fi
  done
  if [ -z "$interpreter" ]; then
    printf 'CROSSCHECK UNREVIEWED: Python %s or newer is required; looked for %s and found %s. Install a supported Python or set FM_CROSSCHECK_PYTHON to its command or absolute path.\n' \
      "$FM_CROSSCHECK_REQUIRED_PYTHON" "$looked_for" "$found" >&2
    exit 1
  fi
fi

exec "$interpreter" "$SCRIPT_DIR/fm-crosscheck.py" "$@"
