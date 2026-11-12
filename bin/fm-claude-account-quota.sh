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
# ambient account's. QUOTA_AXI_SNAPSHOT is removed from each read so a fixture
# for one account cannot answer for all.
# quota-axi exits nonzero when it cannot measure a provider, for example when
# the vendor rate-limits the quota endpoint, yet still prints a valid snapshot
# naming that state; such a snapshot is kept, so the account is reported
# unmeasured with the vendor's own reason rather than as an unreadable root.
#
# A login kept in the macOS Keychain has no credential file, so its
# --profile-only row is marked notSetUp. Only when some entry's row is, the
# script makes one more read for every declared directory at once:
#   env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR \
#     -u CLAUDE_CODE_OAUTH_TOKEN -u QUOTA_AXI_CLAUDE_SWAP -u QUOTA_AXI_SNAPSHOT \
#     QUOTA_AXI_CLAUDE_PROFILES=<declared directories joined by ':'> \
#     quota-axi --provider claude --full --json --no-credential-refresh
# quota-axi reports one lane per profile there (the default profile, which is
# `ordinary`, plus each listed directory), each read only from its own store,
# and --full names each lane's accountLocator. A notSetUp entry takes the one
# lane whose locator selects it: for `ordinary`, the lane whose keychainService
# is the unsuffixed `Claude Code-credentials` item (or, where quota-axi reports
# no keychainService, the lane at ~/.claude); for a directory, the lane whose
# path equals the entry and whose keychainService is not that default item.
# An entry that no lane, or more than one lane, claims keeps its notSetUp row
# plus an uncertainty line saying why, and is never answered from another lane
# or the ambient account. A directory containing ':' cannot be listed and stays
# unmeasured. Entries --profile-only already measured keep that reading.
# The read never passes --allow-keychain-prompt, so it opens a Keychain item only
# under the grant quota-axi recorded when the operator once approved that item
# with `quota-axi --allow-keychain-prompt`; an item without that grant reports
# quota-axi's own keychain-access reason instead of prompting. A lane served
# stale from quota-axi's cache adds an uncertainty line saying so.
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
#     row: <entry>  root=<dir>  scope=<scope>  status=..  remaining=..%  spendPriority=..  runway=..  usableRunwaySeconds=..  confidence=..
#     row: <entry>  root=<dir>  uncertainty: <why this account is not fully measured>
#   usableRunwaySeconds is that scope's own runway time from the same snapshot,
#   printed whenever quota-axi reports it and always for projected_exhaustion,
#   where `-` means the snapshot gave no finite time. confidence is the
#   runway's projectionConfidence, the default TOON's confidence column.
#   Uncertainty names a failed or invalid read, quota-axi's own unknown or
#   rate-limited state and reason, a stale reading, a missing claude row, no
#   applicable scope, or why no Keychain-aware lane could be bound.
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

# An entry whose credential file is absent (quota-axi marks its row notSetUp)
# may still be signed in through the macOS Keychain, which --profile-only never
# opens. Such entries are bound from one Keychain-aware read of every declared
# directory; the header owns the read and the binding rule.
JQ_NOT_SET_UP='def not_set_up:
  .snapshot and ([.snapshot.providers[]? | select(.provider == "claude")] | first | .notSetUp == true);'
if [ -n "$(jq -r "$JQ_NOT_SET_UP"' select(not_set_up) | .account' "$WORK/accounts.jsonl")" ]; then
  profiles=
  while IFS= read -r entry; do
    case "$entry" in
      /*:*) ;;
      /*) profiles="${profiles:+$profiles:}$entry" ;;
    esac
  done <<< "$LISTED"
  shared_error=
  if [ -z "$profiles" ]; then
    shared_error="no declared config directory to read beside the default profile"
  else
    fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" env -u QUOTA_AXI_SNAPSHOT -u QUOTA_AXI_CLAUDE_SWAP \
      -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_OAUTH_TOKEN \
      QUOTA_AXI_CLAUDE_PROFILES="$profiles" \
      quota-axi --provider claude --full --json --no-credential-refresh > "$WORK/shared.json" 2>/dev/null </dev/null
    fm_quota_json_valid < "$WORK/shared.json" || shared_error="the Keychain-aware quota-axi read returned no valid snapshot"
  fi
  [ -z "$shared_error" ] || printf '{"providers": []}\n' > "$WORK/shared.json"
  if ! jq -c --slurpfile shared "$WORK/shared.json" --arg error "$shared_error" --arg home "${HOME:-}" "$JQ_NOT_SET_UP"'
    [$shared[0].providers[]? | select(.provider == "claude" and (.accountLocator | type) == "object"
      and .accountLocator.kind == "config-dir")] as $lanes |
    ([$lanes[].accountLocator.keychainService | strings] | length > 0) as $keychains |
    def claims($e):
      if $e == "ordinary" then
        if $keychains then .accountLocator.keychainService == "Claude Code-credentials"
        else .accountLocator.path == ($home + "/.claude") end
      else .accountLocator.path == $e and .accountLocator.keychainService != "Claude Code-credentials" end;
    if not_set_up then
      .account as $e | [$lanes[] | select(claims($e))] as $claimed |
      if ($claimed | length) == 1 then .snapshot = {providers: $claimed}
      else .unbound = (
        if $error != "" then $error
        elif ($e | contains(":")) then "a path containing : cannot be named in QUOTA_AXI_CLAUDE_PROFILES"
        elif ($claimed | length) > 1 then "\($claimed | length) Keychain-aware lanes claim this account, so none is used"
        else "no Keychain-aware lane is located at this account" end)
      end
    else . end
  ' "$WORK/accounts.jsonl" > "$WORK/bound.jsonl" || ! mv "$WORK/bound.jsonl" "$WORK/accounts.jsonl"; then
    die "cannot bind the Keychain-aware quota reading"
  fi
fi

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
        (if $row.state.stale == true then "\($head)  uncertainty: stale reading served from the quota-axi cache" else empty end),
        (if (["known", "partial"] | index($row.quotaSemantics.status)) == null then
          "\($head)  uncertainty: quota \(show($row.quotaSemantics.status))\(if $row.state.status then " (\($row.state.status | flat): \(show($row.state.error)))" else "" end)"
         else empty end),
        (if ($rows | length) == 0 then "\($head)  uncertainty: no applicable quota scope" else empty end),
        ($rows[] | "\($head)  scope=\(.scope | flat)  status=\(show(.status))  remaining=\(show(.effectivePercentRemaining))%  spendPriority=\(show(.selection.spendPriority))  runway=\(show(.runway.status))"
          + (if .runway.usableRunwaySeconds != null or .runway.status == "projected_exhaustion"
             then "  usableRunwaySeconds=\(show(.runway.usableRunwaySeconds))" else "" end)
          + ((.runway.projectionConfidence // .confidence) as $c | if $c then "  confidence=\($c | flat)" else "" end))
      end
    end,
    (if .unbound then "\($head)  uncertainty: \(.unbound | flat)" else empty end))
' "$WORK/accounts.jsonl" || die "cannot format the quota readings"
