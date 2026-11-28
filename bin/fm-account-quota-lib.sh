#!/usr/bin/env bash
# fm-account-quota-lib.sh - the single owner of measuring each account a home
# declares in a runner's account list (config/claude-accounts or
# config/codex-accounts), in isolation, and printing each one's quota facts.
# Sourced by bin/fm-claude-account-quota.sh and bin/fm-codex-account-quota.sh,
# which own only their argument parsing.
#
# fm_account_quota_report <harness> <config-dir> <model>
# For every declared entry, in file order, runs
#   <VAR>=<root> quota-axi --provider <harness> --profile-only --json
# where <VAR> is CLAUDE_CONFIG_DIR or CODEX_HOME and <root> is the entry's own
# directory, or ~/.claude or ~/.codex for `ordinary`. --profile-only reads only
# that root's credential file (no Keychain, refresh, fallback, or cache), so
# each row is that account's own quota and never the ambient account's; a root
# quota-axi cannot read there, such as an `ordinary` Claude login kept in the
# macOS Keychain, is reported unmeasured. QUOTA_AXI_SNAPSHOT is removed from
# each read so a fixture for one account cannot answer for all. quota-axi exits
# nonzero when it cannot measure a provider, for example when the vendor
# rate-limits the quota endpoint, yet still prints a valid snapshot naming that
# state; such a snapshot is kept, so the account is reported unmeasured with the
# vendor's own reason rather than as an unreadable root.
#
# Each entry binds to its own snapshot's <harness> row and to the scopes that
# bound <model>: all_models/all_products plus model:<id> and product:<id> for
# the bare id. This prints facts only; it never judges eligibility or picks an
# account. The quota-array-dispatch skill applies its gates and spendPriority
# ranking to these rows and chooses the --account to pass.
#
# Output (stdout, TOON-style block), one or more lines per declared entry in
# file order:
#   <harness>-account-quota:
#     row: <entry>  root=<dir>  scope=<scope>  status=..  remaining=..%  spendPriority=..  runway=..  usableRunwaySeconds=..  confidence=..
#     row: <entry>  root=<dir>  uncertainty: <why this account is not fully measured>
#   usableRunwaySeconds is that scope's own runway time from the same snapshot,
#   printed whenever quota-axi reports it and always for projected_exhaustion,
#   where `-` means the snapshot gave no finite time. confidence is the
#   runway's projectionConfidence, the default TOON's confidence column.
#   Uncertainty names a failed or invalid read, quota-axi's own unknown or
#   rate-limited state and reason, a missing <harness> row, or no applicable
#   scope. A missing quota-axi prints `error: quota-axi not installed` in the
#   block. Readings return 0. Returns 2, with one error, for a missing jq, an
#   absent list, or a list that bin/fm-worker-account-lib.sh refuses, which is
#   actionable, never selected around.
#
# Data only: this never launches a runner, checks a sign-in, writes a
# credential, or changes any home or account file. bin/fm-spawn.sh runs the
# sign-in check for the account a launch names.
#
# FM_ACCOUNT_QUOTA_SECONDS bounds each read (default 60); for Claude, the older
# FM_CLAUDE_ACCOUNT_QUOTA_SECONDS is honored when FM_ACCOUNT_QUOTA_SECONDS is unset.

# shellcheck source=bin/fm-worker-account-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"

fm_account_quota_report() {
  local harness=$1 config=$2 model=$3 file var listed work entry root error rc=0 seconds=60
  [ "$harness" != claude ] || seconds=${FM_CLAUDE_ACCOUNT_QUOTA_SECONDS:-60}
  seconds=${FM_ACCOUNT_QUOTA_SECONDS:-$seconds}
  file=$(fm_worker_account_list_file "$harness") || {
    printf 'error: %s has no declared account list\n' "$harness" >&2
    return 2
  }
  var=$(fm_worker_account_root_var "$harness")
  command -v jq >/dev/null 2>&1 || { printf 'error: jq is required\n' >&2; return 2; }
  listed=$(fm_worker_account_list "$harness" "$config") || return 2
  [ -n "$listed" ] || {
    printf 'error: this home declares no config/%s; there is nothing to measure\n' "$file" >&2
    return 2
  }

  if ! command -v quota-axi >/dev/null 2>&1; then
    printf '%s-account-quota:\n  error: quota-axi not installed\n' "$harness"
    return 0
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-$harness-account-quota.XXXXXX") || {
    printf 'error: cannot create a scratch directory\n' >&2
    return 2
  }

  # Every entry becomes {account, root, snapshot} or {account, root, error}.
  : > "$work/accounts.jsonl"
  while IFS= read -r entry; do
    root=$entry
    [ "$entry" != ordinary ] || root="${HOME:?HOME is required to measure the ordinary account}/.$harness"
    error=
    if fm_run_timed "$seconds" env -u QUOTA_AXI_SNAPSHOT "$var=$root" \
        quota-axi --provider "$harness" --profile-only --json > "$work/snapshot.json" 2>/dev/null </dev/null; then
      fm_quota_json_valid < "$work/snapshot.json" || error="quota-axi returned an invalid snapshot"
    elif ! fm_quota_json_valid < "$work/snapshot.json"; then
      error="quota-axi could not read this account"
    fi
    if [ -n "$error" ]; then
      jq -cn --arg account "$entry" --arg root "$root" --arg error "$error" '{account: $account, root: $root, error: $error}'
    else
      jq -c --arg account "$entry" --arg root "$root" '{account: $account, root: $root, snapshot: .}' "$work/snapshot.json"
    fi >> "$work/accounts.jsonl" || {
      printf 'error: cannot record the quota reading for %s\n' "$entry" >&2
      rm -rf "$work"
      return 2
    }
  done <<< "$listed"

  jq -rs --arg model "$model" --arg provider "$harness" '
    def flat: tostring | gsub("[\t\r\n]"; " ");
    def show($value): ($value // "-") | flat;
    def bare($m): ($m | split("/") | last);
    def applicable($row):
      bare($model) as $b |
      [$row.quotaSemantics.effectiveAvailability[]? | select(
        .scope == "all_models" or .scope == "all_products" or
        ($model != "" and (.scope == ("model:" + $b) or .scope == ("product:" + $b)))
      )];
    "\($provider)-account-quota:",
    (.[] | "  row: \(.account | flat)  root=\(.root | flat)" as $head |
      if .error then "\($head)  uncertainty: \(.error | flat)"
      else
        ([.snapshot.providers[]? | select(.provider == $provider)] | first) as $row |
        if $row == null then "\($head)  uncertainty: no \($provider) quota row"
        else
          applicable($row) as $rows |
          (if (["known", "partial"] | index($row.quotaSemantics.status)) == null then
            "\($head)  uncertainty: quota \(show($row.quotaSemantics.status))\(if $row.state.status then " (\($row.state.status | flat): \(show($row.state.error)))" else "" end)"
           else empty end),
          (if ($rows | length) == 0 then "\($head)  uncertainty: no applicable quota scope" else empty end),
          ($rows[] | "\($head)  scope=\(.scope | flat)  status=\(show(.status))  remaining=\(show(.effectivePercentRemaining))%  spendPriority=\(show(.selection.spendPriority))  runway=\(show(.runway.status))"
            + (if .runway.usableRunwaySeconds != null or .runway.status == "projected_exhaustion"
               then "  usableRunwaySeconds=\(show(.runway.usableRunwaySeconds))" else "" end)
            + ((.runway.projectionConfidence // .confidence) as $c | if $c then "  confidence=\($c | flat)" else "" end))
        end
      end)
  ' "$work/accounts.jsonl" || {
    printf 'error: cannot format the quota readings\n' >&2
    rc=2
  }
  rm -rf "$work"
  return "$rc"
}
