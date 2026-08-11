#!/usr/bin/env bash
# Read one crewmate endpoint's pane statusline and print its best-effort quota
# signal. Read-only diagnosis: it captures, parses, and prints, and never sends
# a key, kills an endpoint, or decides a handoff.
#
# Usage: fm-statusline-quota.sh <target> [--verdict]
#   <target> is anything fm-peek.sh accepts: a task id, a legacy fm-<id> label,
#   or an explicit backend target.
#   --verdict prints only the status token (ok|low|unknown|exhausted).
#
# Output without --verdict is the key=value line from fm_statusline_quota_parse,
# e.g. `status=low source=codex weekly_pct=3 context_pct=40`.
# Only the statusline region is read, never the transcript above it: a pane
# showing a diff, a test file, or a pasted statusline must not be able to report
# someone else's exhaustion as this crewmate's. This is a diagnostic read, so it
# takes no capture-window knob - widening the window could only pull transcript
# into a quota verdict.
# An unresolvable target fails like fm-peek.sh; a pane that resolves but cannot
# be captured or parsed prints status=unknown. This path never reports
# exhaustion it did not read, and a context reading never counts as one.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-statusline-quota-lib.sh
. "$SCRIPT_DIR/fm-statusline-quota-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

RAW_TARGET=
VERDICT_ONLY=0
for a in "$@"; do
  case "$a" in
    --verdict) VERDICT_ONLY=1 ;;
    -h|--help) usage ;;
    --*) echo "error: unknown option $a" >&2; usage ;;
    *)
      [ -z "$RAW_TARGET" ] || { echo "error: unexpected argument '$a'" >&2; usage; }
      RAW_TARGET=$a
      ;;
  esac
done
[ -n "$RAW_TARGET" ] || usage

"$SCRIPT_DIR/fm-guard.sh" || true

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")
BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")

# Small fixed window: every non-tmux adapter tails the capture to exactly this
# many lines, so it must still hold a multi-row statusline plus the blank rows
# some harnesses draw under it. The parser then keeps only the statusline region.
CAPTURED=$(fm_backend_capture "$BACKEND" "$T" 12 "$EXPECTED_LABEL" 2>/dev/null) || CAPTURED=

if [ "$VERDICT_ONLY" = 1 ]; then
  fm_statusline_quota_verdict "$CAPTURED"
else
  fm_statusline_quota_parse "$CAPTURED"
fi
