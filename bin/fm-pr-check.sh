#!/usr/bin/env bash
# Record a PR/MR-ready task: appends pr=<url> and the provider's pr_head=<sha>
# to state/<id>.meta when available, then arms the watcher's merge poll by
# writing state/<id>.check.sh, which prints one line iff the PR/MR is merged
# (the watcher's check contract: output = wake firstmate, silence = keep sleeping).
# GitHub PRs use gh. Codebase MRs use bytedcli; missing or unauthenticated
# bytedcli makes the poll stay silent, while direct invocations print the helper
# error if the initial head lookup fails.
# The poll needs bin/fm-scm-lib.sh; if that path ever stops resolving the poll
# wakes firstmate once with a diagnostic and records state/<id>.check.error
# rather than going silently blind.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2
# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"

fm_scm_parse_pr_url "$URL" >/dev/null || exit 1

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if REMOTE_HEAD=$(fm_scm_pr_head "$WT" "$URL"); then
      PR_HEAD=$REMOTE_HEAD
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

quoted_url=$(printf "%s\n" "$URL" | sed "s/'/'\\\\''/g")
quoted_lib=$(printf "%s\n" "$FM_ROOT/bin/fm-scm-lib.sh" | sed "s/'/'\\\\''/g")
quoted_marker=$(printf "%s\n" "$STATE/$ID.check.error" | sed "s/'/'\\\\''/g")
rm -f "$STATE/$ID.check.error"
cat > "$STATE/$ID.check.sh" <<EOF
# shellcheck shell=bash
fm_scm_lib='$quoted_lib'
fm_scm_marker='$quoted_marker'
# shellcheck source=bin/fm-scm-lib.sh
if [ ! -r "\$fm_scm_lib" ] || ! . "\$fm_scm_lib"; then
  if [ ! -e "\$fm_scm_marker" ]; then
    : > "\$fm_scm_marker" 2>/dev/null || true
    echo "poll broken: cannot load \$fm_scm_lib; merge polling for '$quoted_url' is not running"
  fi
  exit 0
fi
state=\$(fm_scm_pr_state "" '$quoted_url' 2>/dev/null || true)
case "\$state" in
  MERGED|merged) echo "merged" ;;
esac
EOF
echo "armed: state/$ID.check.sh polls $URL"
