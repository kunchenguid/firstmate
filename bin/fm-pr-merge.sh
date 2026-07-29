#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Sourcing the bridge library is inert for a home that never opted in; it is
# needed here because a Telegram-linked task may not be merged without the
# paired person's confirmation for this exact revision (see the gate below).
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

# Telegram publish gate.
#
# A message from the paired person authorizes preparing a change and showing a
# preview. It never authorizes publishing that change, and this is where that
# rule is enforced rather than merely documented: a task carrying a Telegram
# link may not merge without a live confirmation the person gave for exactly the
# revision this merge would land. The revision comes from the forge's own
# recorded PR head, not from anything a caller asserted, and the authorization
# is consumed here so it cannot be replayed onto a second landing.
#
# Whether the gate applies is decided by durable evidence - the task's immutable
# Telegram origin, or an armed publish record for it - rather than by the open
# conversation, so ending the exchange cannot end the gate.
#
# A task that never came from the bridge is unaffected: the whole gate is
# skipped and the merge behaves exactly as it did before the bridge existed.
if fmtg_landing_gate_applies "$ID" "$META"; then
  TG_REQUEST=$(fmtg_meta_get "$META" tg_request) \
    || TG_REQUEST=$(fmtg_meta_get "$META" tg_origin) || TG_REQUEST='<malformed>'
  fmtg_load_config
  TG_NOW=$(fmtg_now) || { echo "error: cannot read the current time" >&2; exit 1; }
  TG_PROJECT=$(fmtg_meta_get "$META" project) || TG_PROJECT=
  # The exact revision GitHub would merge. Without it there is nothing to check
  # the person's approval against, so a linked task refuses rather than merging
  # an unverified revision.
  TG_HEAD=$(fmtg_meta_get "$META" pr_head) || TG_HEAD=
  TG_REASON=$(fmtg_landing_guard "$ID" "$TG_PROJECT" "$URL" "$TG_HEAD" "$TG_NOW") || {
    TG_RC=$?
    printf 'REFUSED: %s\n' "$(fmtg_landing_refusal_text "$TG_REASON" "$ID" "$URL")" >&2
    printf 'This task answers Telegram request %s. Preview the change to the paired person and have them confirm publishing it before merging.\n' \
      "$TG_REQUEST" >&2
    exit "$TG_RC"
  }
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
