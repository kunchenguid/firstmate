#!/usr/bin/env bash
# Child-side corr turn-end reconciliation for officer homes: the complement of
# the parent-owned pending-reply guard, not a second copy of it.
#
# Ownership boundary (stated here once): bin/fm-pending-reply-lib.sh owns the
# marked-send expectation mechanics end to end - fm-send registers the durable
# parent record and embeds corr=<id>, the parent watcher ticks the record,
# reposts after its deadline, and escalates. That library also owns the corr
# token format (FM_PENDING_REPLY_CORR_RE) and the resolution predicate
# (fm_pending_reply_line_resolves); this script sources both instead of copying
# them, so a format change cannot fork here.
#
# What this script adds is the RECEIVING side's own check at TURN END: an
# officer home that received marked requests but wrote no correlated booking
# line hears about every missing one loudly before its turn ends
# (data/forensik-2026-08/lehren-ledger.md L58), so the booking happens before
# the next turn instead of after a parent recovery round.
#
# Received marks come from the channel's own open-expectation ledger - the
# parent's state/pending-replies/ records - never from conversation or pane
# scraping. A record is this home's received-and-unbooked mark exactly when
# ALL of the following hold:
#   - the record's task meta (<parent-state>/<task_id>.meta) carries home=
#     naming THIS home, so another mate's expectation is never named here;
#   - delivered_epoch is set: an undelivered request never reached this home,
#     and delivery recovery stays the sender's problem;
#   - phase is not resolved;
#   - the owner's own resolution scan (fm_pending_reply_find_resolve_line over
#     the record's recorded parent_status file) finds no correlated line -
#     the same bytes and the same predicate the parent applies, so this check
#     names only debts the channel itself still counts. An answer written to
#     any other file does not resolve the expectation and therefore still
#     reads as missing here, by design.
#
# Scope: only a home whose .fm-secondmate-parent binding records a LOCAL route
# can read the parent ledger directly. Remote-route homes, plain primary homes
# without a binding, and a binding pointing back at this own home silently
# skip; the parent-side guard covers those cases unchanged.
#
# Blocking is bounded, never a wedge: exit 2 requires a stable session
# identity (FM_CORR_ABGLEICH_SESSION, supplied by bin/fm-turnend-guard.sh from
# the hook payload) AND a difference fingerprint not already named for that
# session ($STATE/.corr-abgleich-blocked). Without a session id the script
# names each distinct difference set once, advisories only, and exits 0. Once
# a set has been named for the current key it stays silent until the set
# changes, so an unchanged debt never spends another harness continuation.
#
# Exit codes: 0 quiet, out of scope, or advisory already named; 2 block now
# with the loud difference list on stderr. Callers treat any nonzero other
# than 2 as a harmless no-op.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SESSION=${FM_CORR_ABGLEICH_SESSION:-}

[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# The parent-side owner of the corr format, resolution predicate, and record
# schema; sourced, never restated. It transitively brings fm_meta_get.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

# Only a genuine local-route officer home reads the parent ledger directly.
# fm_secondmate_parent_record_parse sets FM_SECONDMATE_PARENT_ROUTE/_HOME/_HOST
# as output globals and fails closed on any malformed record.
fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || exit 0
[ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || exit 0
PARENT_HOME=$FM_SECONDMATE_PARENT_HOME
case "$PARENT_HOME" in /*) ;; *) exit 0 ;; esac
[ -d "$PARENT_HOME" ] || exit 0

MY_HOME=$FM_HOME
MY_HOME_NORM=$(cd "$MY_HOME" 2>/dev/null && pwd -P) || MY_HOME_NORM=$MY_HOME
if [ "$PARENT_HOME" = "$MY_HOME" ] || [ "$PARENT_HOME" = "$MY_HOME_NORM" ]; then
  exit 0
fi

PARENT_STATE="$PARENT_HOME/state"
[ -d "$PARENT_STATE" ] || exit 0
REPLY_DIR=$(fm_pending_reply_dir "$PARENT_STATE")
[ -d "$REPLY_DIR" ] || exit 0

missing_ids=()
missing_targets=()
for rec in "$REPLY_DIR"/*; do
  [ -f "$rec" ] || continue
  case "$(basename "$rec")" in .*) continue ;; esac
  corr=$(fm_pending_reply_get "$rec" corr_id)
  [ -n "$corr" ] || corr=$(basename "$rec")
  task_id=$(fm_pending_reply_get "$rec" task_id)
  [ -n "$task_id" ] || continue
  phase=$(fm_pending_reply_get "$rec" phase)
  [ "$phase" = resolved ] && continue
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || continue
  meta="$PARENT_STATE/$task_id.meta"
  [ -f "$meta" ] || continue
  rec_home=$(fm_meta_get "$meta" home)
  [ -n "$rec_home" ] || continue
  if [ "$rec_home" != "$MY_HOME" ]; then
    rec_home_norm=$(cd "$rec_home" 2>/dev/null && pwd -P) || continue
    [ "$rec_home_norm" = "$MY_HOME_NORM" ] || continue
  fi
  # The exact surface the parent resolves from, scanned with the owner's own
  # predicate: a correlated line anywhere else does not settle the debt.
  status_file=$(fm_pending_reply_get "$rec" parent_status)
  [ -n "$status_file" ] || status_file="$PARENT_STATE/$task_id.status"
  resolve_line=$(fm_pending_reply_find_resolve_line "$status_file" "$corr")
  [ -n "$resolve_line" ] && continue
  missing_ids+=("$corr")
  missing_targets+=("$status_file")
done

[ "${#missing_ids[@]}" -gt 0 ] || exit 0

fingerprint=$(printf '%s\n' "${missing_ids[@]}" \
  | LC_ALL=C sort | cksum 2>/dev/null | awk '{printf "%s-%s", $1, $2}')
[ -n "$fingerprint" ] || fingerprint=unavailable
memory_key="${SESSION:-unknown} $fingerprint"
memory_file="$STATE/.corr-abgleich-blocked"
named_memory=$(cat "$memory_file" 2>/dev/null || true)
[ "$named_memory" = "$memory_key" ] && exit 0
tmp_memory="$memory_file.tmp.$$"
if ! printf '%s\n' "$memory_key" > "$tmp_memory" 2>/dev/null \
  || ! mv -f "$tmp_memory" "$memory_file" 2>/dev/null; then
  rm -f "$tmp_memory" 2>/dev/null || true
fi

{
  printf '●  TURN WOULD END WITH UNBOOKED CORRELATED REQUESTS\n'
  printf '●  Marked requests this home received have NO corr= booking line in the\n'
  printf '●  status file the sender resolves against - they still count as unanswered:\n'
  i=0
  while [ "$i" -lt "${#missing_ids[@]}" ]; do
    printf '●    corr=%s   book into: %s\n' "${missing_ids[$i]}" "${missing_targets[$i]}"
    i=$((i + 1))
  done
  printf '●  Append one status line containing the exact corr=<id> for each, e.g.\n'
  printf '●  bin/fm-secondmate-report.sh <status-file> done <id> "<note>", BEFORE ending the turn.\n'
} >&2

[ -n "$SESSION" ] && exit 2
exit 0
