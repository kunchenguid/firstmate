#!/usr/bin/env bash
# fm-claude-account-quota.sh - measure each Claude account a home declares in
# config/claude-accounts, in isolation, and print each one's quota facts.
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
# quota-axi exits nonzero when it cannot measure a provider, for example when
# the vendor rate-limits the quota endpoint, yet still prints a valid snapshot
# naming that state; such a snapshot is kept, so the account is reported
# unmeasured with the vendor's own reason rather than as an unreadable root.
#
# Each entry binds to its own snapshot's claude row and to the scopes that bound
# --model: all_models/all_products plus model:<id> and product:<id> for the
# bare id. This prints facts only; it never judges eligibility or picks an
# account. The quota-array-dispatch skill applies its gates and spendPriority
# ranking to these rows and chooses the --account to pass.
#
# Output (stdout, TOON-style block), one or more lines per declared entry in
# file order:
#   claude-account-quota:
#     row: <entry>  root=<dir>  scope=<scope>  status=..  remaining=..%  spendPriority=..  runway=..  confidence=..
#     row: <entry>  root=<dir>  uncertainty: <why this account is not fully measured>
#   Uncertainty names a failed or invalid read, quota-axi's own unknown or
#   rate-limited state and reason, a missing claude row, or no applicable scope.
#   A missing quota-axi prints `error: quota-axi not installed` in the block.
#   Readings exit 0. Exit 2 for a usage error, an absent list, or a list that
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
  printf 'claude-account-quota:\n  error: quota-axi not installed\n'
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-account-quota.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

# Every entry becomes {account, root, snapshot} or {account, root, error}.
: > "$WORK/accounts.jsonl"
while IFS= read -r entry; do
  root=$entry
  [ "$entry" != ordinary ] || root="${HOME:?HOME is required to measure the ordinary account}/.claude"
  error=
  if fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env -u QUOTA_AXI_SNAPSHOT CLAUDE_CONFIG_DIR="$root" \
      quota-axi --provider claude --profile-only --json > "$WORK/snapshot.json" 2>/dev/null </dev/null; then
    fm_quota_json_valid < "$WORK/snapshot.json" || error="quota-axi returned an invalid snapshot"
  elif ! fm_quota_json_valid < "$WORK/snapshot.json"; then
    error="quota-axi could not read this account"
  fi
  if [ -n "$error" ]; then
    jq -cn --arg account "$entry" --arg root "$root" --arg error "$error" '{account: $account, root: $root, error: $error}'
  else
    jq -c --arg account "$entry" --arg root "$root" '{account: $account, root: $root, snapshot: .}' "$WORK/snapshot.json"
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
  "claude-account-quota:",
  (.[] | "  row: \(.account | flat)  root=\(.root | flat)" as $head |
    if .error then "\($head)  uncertainty: \(.error | flat)"
    else
      ([.snapshot.providers[]? | select(.provider == "claude")] | first) as $row |
      if $row == null then "\($head)  uncertainty: no claude quota row"
      else
        applicable($row) as $rows |
        (if (["known", "partial"] | index($row.quotaSemantics.status)) == null then
          "\($head)  uncertainty: quota \(show($row.quotaSemantics.status))\(if $row.state.status then " (\($row.state.status | flat): \(show($row.state.error)))" else "" end)"
         else empty end),
        (if ($rows | length) == 0 then "\($head)  uncertainty: no applicable quota scope" else empty end),
        ($rows[] | "\($head)  scope=\(.scope | flat)  status=\(show(.status))  remaining=\(show(.effectivePercentRemaining))%  spendPriority=\(show(.selection.spendPriority))  runway=\(show(.runway.status))"
          + (if .confidence then "  confidence=\(.confidence | flat)" else "" end))
      end
    end)
' "$WORK/accounts.jsonl" || die "cannot format the quota readings"
