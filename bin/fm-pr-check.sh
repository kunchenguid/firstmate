#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> to state/<id>.meta and arms the
# watcher's merge poll by writing state/<id>.check.sh, which prints one line iff
# the PR is merged (the watcher's check contract: output = wake firstmate,
# silence = keep sleeping).
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

META="$FM_ROOT/state/$ID.meta"
if [ -f "$META" ] && ! grep -qxF "pr=$URL" "$META"; then
  echo "pr=$URL" >> "$META"
fi

cat > "$FM_ROOT/state/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
