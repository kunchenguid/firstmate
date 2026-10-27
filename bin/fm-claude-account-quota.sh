#!/usr/bin/env bash
# fm-claude-account-quota.sh - measure each Claude account a home declares in
# config/claude-accounts, in isolation, and show which one quota favors.
#
# Usage:
#   fm-claude-account-quota.sh [--model <model>]
#
# For every declared entry, in file order, runs
#   CLAUDE_CONFIG_DIR=<root> quota-axi --provider claude --profile-only --json
# where <root> is the entry's own directory, or ~/.claude for `ordinary`.
# --profile-only reads only that root's credential file (no Keychain, refresh,
# fallback, or cache), so each row is that account's own quota and never the
# ambient account's; a root quota-axi cannot read there, such as an `ordinary`
# login kept in the macOS Keychain, is reported unmeasured. QUOTA_AXI_SNAPSHOT
# is removed from each read so a fixture for one account cannot answer for all.
#
# Each entry binds to its own snapshot's claude row and to the scopes that bound
# --model: all_models/all_products plus model:<id> and product:<id> for the
# bare id. The eligibility and ranking rules are the quota-array-dispatch
# skill's, applied to accounts instead of profiles: an exhausted_now runway or a
# known 0% scope is not eligible; an unmeasured account, an unknown scope, or a
# non-numeric spendPriority stays eligible but unranked; a ranked account
# carries its limiting scope's spendPriority. The highest known spendPriority is
# shown as the account to pass; a genuine tie, or no rankable account,
# escalates instead of picking by file order.
#
# Output (stdout, TOON-style block):
#   claude-account-quota:
#     status: clear | escalate | error
#     reason: <why the status is not clear>
#     candidate: <entry>  scope=.. remaining=..% spendPriority=.. runway=.. -> eligible | eligible, unranked: <reason> | not eligible: <reason>
#     account: --account <entry>     (status clear only)
#   clear    -> pass the account line to fm-spawn.sh with the chosen profile,
#               after the skill's reasoning-class and runway gates
#   escalate -> decide in the open from the candidate rows, or ask the captain
#   error    -> quota-axi is missing; decide as for unmeasured quota
#   Outcomes exit 0. Exit 2 for a usage error, an absent list, or a list that
#   bin/fm-worker-account-lib.sh refuses, which is actionable, never selected
#   around.
#
# Data only: this never launches Claude, checks a sign-in, writes a credential,
# or changes any home or account file. bin/fm-spawn.sh runs the sign-in check
# for the account a launch names.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

FM_CLAUDE_ACCOUNT_QUOTA_SECONDS=${FM_CLAUDE_ACCOUNT_QUOTA_SECONDS:-60}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

MODEL=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      [ -n "${2-}" ] || die "--model needs a value"
      MODEL=$2
      shift 2
      ;;
    --model=*)
      MODEL=${1#--model=}
      [ -n "$MODEL" ] || die "--model needs a value"
      shift
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unexpected argument: $1" ;;
  esac
done
[ "$MODEL" != default ] || MODEL=

command -v jq >/dev/null 2>&1 || die "jq is required"
LISTED=$(fm_worker_account_list claude "$CONFIG") || exit 2
[ -n "$LISTED" ] || die "this home declares no config/claude-accounts; there is nothing to measure"

if ! command -v quota-axi >/dev/null 2>&1; then
  printf 'claude-account-quota:\n  status: error\n  reason: quota-axi not installed\n'
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-account-quota.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# Every entry becomes {account, snapshot} or {account, error}; jq does the rest.
: > "$WORK/accounts.jsonl"
while IFS= read -r entry; do
  root=$entry
  [ "$entry" != ordinary ] || root="${HOME:?HOME is required to measure the ordinary account}/.claude"
  error=
  if ! fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env -u QUOTA_AXI_SNAPSHOT CLAUDE_CONFIG_DIR="$root" \
      quota-axi --provider claude --profile-only --json > "$WORK/snapshot.json" 2>/dev/null </dev/null; then
    error="quota-axi could not read this account"
  elif ! fm_quota_json_valid < "$WORK/snapshot.json"; then
    error="quota-axi returned an invalid snapshot"
  fi
  if [ -n "$error" ]; then
    jq -cn --arg account "$entry" --arg error "$error" '{account: $account, error: $error}'
  else
    jq -c --arg account "$entry" '{account: $account, snapshot: .}' "$WORK/snapshot.json"
  fi >> "$WORK/accounts.jsonl" || die "cannot record the quota reading for $entry"
done <<< "$LISTED"

jq -rs --arg model "$MODEL" '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def bare($m): ($m | split("/") | last);
  def applicable($row):
    bare($model) as $b |
    [$row.quotaSemantics.effectiveAvailability[]? | select(
      .scope == "all_models" or .scope == "all_products" or
      ($model != "" and (.scope == ("model:" + $b) or .scope == ("product:" + $b)))
    )];
  def evaluate:
    .account as $a |
    if .error then {account: $a, eligible: true, unranked: true, reason: .error}
    else
      ([.snapshot.providers[]? | select(.provider == "claude")] | first) as $row |
      if $row == null then {account: $a, eligible: true, unranked: true, reason: "no claude quota row"}
      else
        applicable($row) as $rows |
        if any($rows[]; (.runway.status // "") == "exhausted_now") then
          ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
          {account: $a, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
        elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
          ($rows | map(select(.status == "known" and .effectivePercentRemaining <= 0)) | first) as $bad |
          {account: $a, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
        elif (["known", "partial"] | index($row.quotaSemantics.status)) == null then
          {account: $a, eligible: true, unranked: true, reason: "unmeasured (\($row.quotaSemantics.status))"}
        elif ($rows | length) == 0 then
          {account: $a, eligible: true, unranked: true, reason: "no applicable quota scope"}
        elif any($rows[]; .status != "known") then
          ($rows | map(select(.status != "known")) | first) as $bad |
          {account: $a, scope: $bad.scope, eligible: true, unranked: true, reason: "quota scope \($bad.scope) unknown"}
        elif any($rows[]; (.selection.spendPriority | type) != "number") then
          ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
          {account: $a, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing at \($bad.scope)"}
        else
          ($rows | min_by(.selection.spendPriority)) as $lim |
          {account: $a, scope: $lim.scope, pct: $lim.effectivePercentRemaining, runway: $lim.runway.status, spendPriority: $lim.selection.spendPriority, eligible: true}
        end
      end
    end;
  map(evaluate) as $cands |
  [$cands[] | select(.eligible and ((.unranked // false) | not))] as $ranked |
  (if ($ranked | length) == 0 then {status: "escalate", reason: "no rankable eligible account"}
   else
     ($ranked | max_by(.spendPriority)) as $best |
     if ([$ranked[] | select(.spendPriority == $best.spendPriority)] | length) > 1
     then {status: "escalate", reason: "genuine spendPriority tie"}
     else {status: "clear", chosen: $best.account}
     end
   end) as $verdict |
  "claude-account-quota:",
  "  status: \($verdict.status)",
  (if $verdict.reason then "  reason: \($verdict.reason)" else empty end),
  ($cands[] | "  candidate: \(.account | flat)"
    + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
    + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat)" elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
  (if $verdict.chosen then "  account: --account \($verdict.chosen | flat | @sh)" else empty end)
' "$WORK/accounts.jsonl" || die "cannot evaluate the quota readings"
