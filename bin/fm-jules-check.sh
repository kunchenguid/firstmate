#!/usr/bin/env bash
# Record a Jules-backed task: appends jules_session=<session-id> to
# state/<id>.meta when not already present, then arms the watcher's session
# poll by writing state/<id>.check.sh, which runs `jules-axi watch` and prints
# one line for each non-empty state transition (the watcher's check contract:
# output = wake firstmate, silence = keep sleeping).
# Usage: fm-jules-check.sh <task-id> <jules-session-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
SESSION=$2

META="$STATE/$ID.meta"
if [ -f "$META" ] && ! grep -qxF "jules_session=$SESSION" "$META"; then
  echo "jules_session=$SESSION" >> "$META"
fi

cat > "$STATE/$ID.check.sh" <<SCRIPT
command -v jules-axi >/dev/null 2>&1 || exit 0
session=\$(grep '^jules_session=' "$STATE/$ID.meta" | tail -1 | cut -d= -f2-)
[ -n "\$session" ] || exit 0
jules-axi watch "\$session" --state-file "$STATE/$ID.jules.state"
SCRIPT
echo "armed: state/$ID.check.sh polls jules session $SESSION"
