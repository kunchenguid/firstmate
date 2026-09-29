#!/usr/bin/env bash
# Route an explicitly configured independent review when a ship records a build
# commit or a reviewable PR. The task metadata supplies review_class,
# review_owner (a secondmate in this home), and review_family. A successful
# fm-send inbox delivery is the receipt; the deterministic delivery id makes a
# crash between delivery and receipt publication safe to retry.
# Usage: fm-review-route.sh configure <task-id> <class> <secondmate-id> <family>
#        fm-review-route.sh scan <task-id>
#        fm-review-route.sh request <task-id> <pr-url|-> <40-hex-head> <class> <family> [<blocking-finding-key> <rationale>]
# A third round is refused unless a named blocking correctness or security
# finding and its rationale are supplied. A scan never invents that exception.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'fm-review-route: %s\n' "$*" >&2; exit 1; }
meta_value() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
valid_atom() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
valid_head() { case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac; [ "${#1}" -eq 40 ]; }

[ "$#" -ge 2 ] || die 'usage: scan <task> | request <task> <pr|-> <head> <class> <family> [<finding-key> <rationale>]'
COMMAND=$1 ID=$2
fm_pr_task_id_valid "$ID" || die 'invalid task id'
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die 'task metadata unavailable'
[ "$(meta_value "$META" kind)" = ship ] || die 'only ships can request review'
if [ "$COMMAND" = configure ]; then
  [ "$#" -eq 5 ] || die 'configure needs task, class, secondmate, and model family'
  CLASS=$3 OWNER=$4 FAMILY=$5
  if ! valid_atom "$CLASS" || ! valid_atom "$OWNER" || ! valid_atom "$FAMILY"; then
    die 'invalid review configuration'
  fi
  OWNER_META="$STATE/$OWNER.meta"
  [ -f "$OWNER_META" ] && [ ! -L "$OWNER_META" ] \
    && [ "$(meta_value "$OWNER_META" kind)" = secondmate ] || die 'review owner is not a recorded secondmate'
  [ "$OWNER" != "$ID" ] || die 'implementer cannot own its review'
  META_LOCK=$(fm_meta_lock_path "$META") || die 'could not name metadata lock'
  fm_lock_acquire_wait "$META_LOCK" || die 'metadata lock unavailable'
  trap 'fm_lock_release "$META_LOCK"' EXIT
  [ ! -e "$STATE/$ID.review-rounds" ] || die 'review has already started'
  umask 077
  META_TMP=$(mktemp "$STATE/.fm-review-config.XXXXXX") || die 'could not stage review configuration'
  awk -v c="$CLASS" -v o="$OWNER" -v f="$FAMILY" '
    /^review_class=|^review_owner=|^review_family=/ {next}
    /^pr=/ && !inserted {print "review_class=" c; print "review_owner=" o; print "review_family=" f; inserted=1}
    {print}
    END {if (!inserted) {print "review_class=" c; print "review_owner=" o; print "review_family=" f}}
  ' "$META" > "$META_TMP"
  chmod 0600 "$META_TMP"
  mv -f -- "$META_TMP" "$META"
  printf 'review configured: task=%s class=%s owner=%s family=%s\n' "$ID" "$CLASS" "$OWNER" "$FAMILY"
  exit 0
fi
OWNER=$(meta_value "$META" review_owner)
CLASS=$(meta_value "$META" review_class)
FAMILY=$(meta_value "$META" review_family)
if ! valid_atom "$OWNER" || ! valid_atom "$CLASS" || ! valid_atom "$FAMILY"; then
  die 'review owner, class, or family is not configured'
fi
OWNER_META="$STATE/$OWNER.meta"
[ -f "$OWNER_META" ] && [ ! -L "$OWNER_META" ] \
  && [ "$(meta_value "$OWNER_META" kind)" = secondmate ] || die 'review owner is not a recorded secondmate'
[ "$OWNER" != "$ID" ] || die 'implementer cannot own its review'

PR=- HEAD='' FINDING='' RATIONALE=''
case "$COMMAND" in
  scan)
    [ "$#" -eq 2 ] || die 'scan takes one task id'
    # A committed build declaration is intentionally exact, so ordinary
    # progress prose cannot dispatch a review of an uncommitted tree.
    STATUS="$STATE/$ID.status"
    if [ -f "$STATUS" ] && [ ! -L "$STATUS" ]; then
      HEAD=$(sed -nE 's/^working( \[[^]]+\])?: build done commit=([0-9a-fA-F]{40})( |$).*/\2/p; s/^needs-decision( \[[^]]+\])?:.*ready for independent review at ([0-9a-fA-F]{40})( |$).*/\2/p' "$STATUS" | tail -1)
    fi
    PR=$(meta_value "$META" pr)
    if [ -n "$PR" ]; then
      HEAD=$(meta_value "$META" pr_head)
    fi
    [ -n "$HEAD" ] || exit 0
    [ -n "$PR" ] || PR=-
    ;;
  request)
    { [ "$#" -eq 6 ] || [ "$#" -eq 8 ]; } || die 'invalid request arguments'
    PR=$3 HEAD=$4
    [ "$CLASS" = "$5" ] && [ "$FAMILY" = "$6" ] || die 'request disagrees with configured review class or family'
    if [ "$#" -eq 8 ]; then FINDING=$7; RATIONALE=$8; fi
    ;;
  *) die 'unknown command' ;;
esac
valid_head "$HEAD" || die 'review needs an exact 40-hex commit'
if [ "$PR" != - ]; then
  fm_pr_url_parse "$PR" || die 'invalid PR URL'
  [ "$(meta_value "$META" pr)" = "$FM_PR_URL" ] || die 'PR is not owned by this task'
  [ "$(meta_value "$META" pr_head)" = "$HEAD" ] || die 'review head differs from recorded PR head'
  PR=$FM_PR_URL
fi
if [ -n "$FINDING" ]; then
  valid_atom "$FINDING" || die 'invalid blocking finding key'
  case "$RATIONALE" in ''|*$'\n'*) die 'blocking finding needs a one-line rationale' ;; esac
  case "$RATIONALE" in *correctness*|*security*) ;; *) die 'exception must name correctness or security' ;; esac
fi

RECORD="$STATE/$ID.review-rounds"
LOCK="$STATE/.$ID.review-rounds.lock"
fm_lock_acquire_wait "$LOCK" || die 'review round lock unavailable'
trap 'fm_lock_release "$LOCK"' EXIT
[ ! -L "$RECORD" ] || die 'review round record is a link'
[ ! -e "$RECORD" ] || { [ -f "$RECORD" ] && [ "$(fm_pr_file_link_count "$RECORD")" = 1 ]; } || die 'review round record is unsafe'
if [ -f "$RECORD" ] && awk -F '\t' -v h="$HEAD" -v c="$CLASS" '$1==h && $3==c {found=1} END {exit !found}' "$RECORD"; then
  printf 'review already routed: task=%s head=%s pr=%s\n' "$ID" "$HEAD" "$PR"
  exit 0
fi
ROUNDS=0
if [ -f "$RECORD" ]; then
  ROUNDS=$(awk -F '\t' -v c="$CLASS" '$3==c && $1 ~ /^[0-9a-fA-F]+$/ {n++} END {print n+0}' "$RECORD")
fi
if [ "$ROUNDS" -ge 2 ] && [ -z "$FINDING" ]; then
  MARKER="$STATE/$ID.review-cap-escalated"
  if [ ! -e "$MARKER" ]; then
    printf '%s\n' "$HEAD" > "$MARKER"
    fm_wake_append check "review-cap-$ID" "review cap reached: task=$ID pr=$PR head=$HEAD class=$CLASS; file non-blocking polish as follow-up" || die 'could not escalate review cap'
  fi
  printf 'fm-review-route: two review rounds completed; third requires a blocking correctness or security finding\n' >&2
  exit 3
fi

DELIVERY_ID=$(printf '%s\n' "$ID" "$PR" "$HEAD" "$CLASS" "$FAMILY" | shasum -a 256 | cut -c1-16)
MESSAGE="Independent $CLASS review requested for task $ID. Review exact head $HEAD, PR $PR. Use a different model family from the implementer; target family $FAMILY. Report the verdict and finding keys to firstmate. Review request id $DELIVERY_ID."
[ -z "$FINDING" ] || MESSAGE="$MESSAGE Blocking $FINDING: $RATIONALE"
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$OWNER" --fire-and-forget "$DELIVERY_ID" "$MESSAGE" \
  || die 'review delivery was not confirmed; retry the same request'
umask 077
TMP=$(mktemp "$STATE/.fm-review-rounds.XXXXXX") || die 'could not stage review receipt'
if [ -f "$RECORD" ]; then cat "$RECORD" > "$TMP"; fi
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$HEAD" "$PR" "$CLASS" "$FAMILY" "$DELIVERY_ID" "${FINDING:--}" >> "$TMP"
chmod 0600 "$TMP"
mv -f -- "$TMP" "$RECORD"
printf 'review routed: task=%s round=%s head=%s pr=%s owner=%s class=%s family=%s receipt=%s\n' \
  "$ID" "$((ROUNDS + 1))" "$HEAD" "$PR" "$OWNER" "$CLASS" "$FAMILY" "$DELIVERY_ID"
