#!/usr/bin/env bash
# Merge a task's PR/MR after atomically recording canonical pr= and any
# available pr_head= through bin/fm-pr-check.sh. The provider seam accepts
# GitHub and Codebase URLs, rejects malformed or override-bearing input before
# recording state, defaults GitHub to squash and Codebase to a real merge
# commit, and refuses to squash a Codebase MR whose head is or may be a merge
# commit. Exact accepted flags are owned by bin/fm-scm-lib.sh.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra provider merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-scm-lib.sh
. "$SCRIPT_DIR/fm-scm-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
if ! fm_pr_url_parse "$RAW_URL"; then
  if ! fm_scm_parse_pr_url "$RAW_URL" >/dev/null 2>&1; then
    case "$RAW_URL" in
      https://github.com/*|https://code.byted.org/*|https://code-tx.byted.org/*)
        fm_scm_parse_pr_url "$RAW_URL" >/dev/null || exit 1
        ;;
      *) echo "error: invalid PR merge request" >&2; exit 2 ;;
    esac
  fi
  echo "error: invalid PR merge request" >&2
  exit 2
fi
if [ "$FM_PR_PROVIDER" = gitlab ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
shift 2
[ "${1:-}" = "--" ] && shift

fm_scm_parse_pr_url "$URL" >/dev/null || exit 1
fm_scm_reject_url_override_args "$@" || exit 1

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" --no-watch
grep -qxF "pr=$URL" "$META" || { echo "error: PR/MR metadata recording failed" >&2; exit 1; }

fm_scm_merge_url "$URL" "$@"
