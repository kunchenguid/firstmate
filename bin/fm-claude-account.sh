#!/usr/bin/env bash
# fm-claude-account.sh - choose which declared Claude account a Claude spawn
# from this home should launch on, with the quota evidence for every account.
#
# Usage: fm-claude-account.sh pick [--model <claude-model>]
#        fm-claude-account.sh --help
#
# Reads this home's config/claude-account (FM_CONFIG_OVERRIDE, else
# $FM_HOME/config) through bin/fm-worker-account-lib.sh, which owns the pool
# format and refuses a malformed pool. Without the file, or with one line,
# there is nothing to choose: pick prints that account (`none` without a file,
# meaning spawn without --account) and exits 0 without running quota-axi.
#
# With several lines, pick runs quota-axi once:
#   env -u CLAUDE_CONFIG_DIR QUOTA_AXI_CLAUDE_PROFILES=<path entries joined
#   by ':'> quota-axi --provider claude --full --json
# bounded to 60 seconds, and validates the
# result with fm_quota_json_valid from bin/fm-quota-axi-lib.sh. Each declared
# entry is then bound to at most one schema-6 claude lane through the lane's
# --full accountLocator:
#   ordinary  the lane whose keychainService is exactly the unsuffixed
#             `Claude Code-credentials` store; on a host whose lanes carry no
#             keychainService at all (quota-axi publishes it only on macOS),
#             the lane whose path is $HOME/.claude.
#   <path>    the lane whose path equals the entry exactly and whose
#             keychainService is not the unsuffixed default store.
# A path containing ':' cannot be named in QUOTA_AXI_CLAUDE_PROFILES and stays
# unmeasured.
#
# The applicable scope is the lane's `model:<model>` row when --model names a
# model quota-axi reports for that lane, else its `all_models` row. A lane is
#   eligible    its state is fresh, the scope is known, effectivePercentRemaining
#               is above zero, and runway is not exhausted_now;
#   exhausted   fresh and known, but at zero remaining or exhausted_now;
#   unmeasured  anything else: no matching lane, no locator, a non-fresh state,
#               no applicable or no known scope, or no usable quota-axi output.
# Eligible lanes rank by the highest known spendPriority, ahead of eligible
# lanes whose spendPriority is unknown; an exact tie goes to the earliest
# resetsAt (the first limiting window's reset, as quota-axi's TOON shows it),
# then to the earlier line in the file. With no eligible lane, the first
# unmeasured entry in file order is chosen and marked as an unmeasured
# default, never silently; when every entry is measured and exhausted, nothing
# is chosen.
#
# Output (stdout): one `lane:` evidence line per declared entry in file order
# (entry, accountKey or `unmeasured`, scope, effectivePercentRemaining,
# spendPriority, runway, resetsAt, verdict, and reason), one `basis:` line,
# and finally `account: <entry>` naming the exact line to pass to
# bin/fm-spawn.sh --account. The exhausted outcome prints no account line.
#
# Exit status: 0 an account was named; 1 the pool or its configuration was
# refused (the error names the file); 2 usage error; 3 every declared account
# is measured and exhausted, so the caller must report instead of spawning.
# FM_QUOTA_AXI_MIN is not raised for this helper: an older quota-axi without
# account lanes or locators simply yields the disclosed unmeasured default.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_CLAUDE_ACCOUNT_QUOTA_SECONDS=60
FM_CLAUDE_ACCOUNT_EXHAUSTED_EXIT=3

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  echo "usage: fm-claude-account.sh pick [--model <claude-model>]" >&2
  exit 2
}

case "${1:-}" in
-h | --help | help)
  usage
  exit 0
  ;;
pick) shift ;;
'') die_usage "a subcommand is required" ;;
*) die_usage "unknown subcommand: $1" ;;
esac

MODEL=
while [ "$#" -gt 0 ]; do
  case "$1" in
  --model)
    [ -n "${2:-}" ] || die_usage "--model requires a value"
    MODEL=$2
    shift 2
    ;;
  --model=*)
    MODEL=${1#--model=}
    [ -n "$MODEL" ] || die_usage "--model requires a value"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die_usage "unexpected argument: $1" ;;
  esac
done
[ "$MODEL" != default ] || MODEL=

ENTRIES=$(fm_worker_account_entries claude "$CONFIG") || exit 1
if [ -z "$ENTRIES" ]; then
  echo "basis: this home has no config/claude-account, so Claude workers launch unpinned; spawn without --account"
  echo "account: none"
  exit 0
fi
DECLARED=()
while IFS= read -r line; do
  DECLARED+=("${line%%$'\t'*}")
done <<EOF_ENTRIES
$ENTRIES
EOF_ENTRIES
if [ "${#DECLARED[@]}" -eq 1 ]; then
  echo "basis: config/claude-account declares one account, so there is nothing to choose"
  echo "account: ${DECLARED[0]}"
  exit 0
fi

PROFILES=
for entry in "${DECLARED[@]}"; do
  case "$entry" in
  ordinary | *:*) ;;
  *) PROFILES="${PROFILES:+$PROFILES:}$entry" ;;
  esac
done

SNAPSHOT=
GLOBAL_REASON=
if ! command -v quota-axi >/dev/null 2>&1; then
  GLOBAL_REASON="quota-axi is not installed"
else
  quota_rc=0
  SNAPSHOT=$(fm_run_timed "$FM_CLAUDE_ACCOUNT_QUOTA_SECONDS" \
    env -u CLAUDE_CONFIG_DIR QUOTA_AXI_CLAUDE_PROFILES="$PROFILES" \
    quota-axi --provider claude --full --json 2>/dev/null </dev/null) || quota_rc=$?
  if ! printf '%s\n' "$SNAPSHOT" | fm_quota_json_valid; then
    if [ "$quota_rc" -eq 124 ]; then
      GLOBAL_REASON="quota-axi did not answer within ${FM_CLAUDE_ACCOUNT_QUOTA_SECONDS}s"
    else
      GLOBAL_REASON="quota-axi printed no valid quota snapshot (exit $quota_rc)"
    fi
    SNAPSHOT=
  elif [ "$(printf '%s\n' "$SNAPSHOT" | jq -r '.schemaVersion')" != 6 ]; then
    GLOBAL_REASON="quota-axi reports no account lanes (schema 5); it predates per-account Claude lanes"
    SNAPSHOT=
  fi
fi
[ -n "$SNAPSHOT" ] || SNAPSHOT='{"schemaVersion":6,"providers":[]}'

DECLARED_JSON=$(printf '%s\n' "${DECLARED[@]}" | jq -R . | jq -s .)

# One jq pass owns lane binding, classification, and ranking, so the evidence
# printed and the choice made always come from the same reading.
# shellcheck disable=SC2016  # jq program text, not shell expansion.
RESULT=$(printf '%s\n' "$SNAPSHOT" | jq -r \
  --argjson declared "$DECLARED_JSON" \
  --arg model "$MODEL" \
  --arg home "${HOME:-}" \
  --arg global "$GLOBAL_REASON" '
  def str: if . == null then "unknown" else tostring end;
  [.providers[]? | select(.provider == "claude" and (.accountKey | type) == "string")] as $lanes |
  ([$lanes[] | .accountLocator.keychainService? // empty] | length > 0) as $keychains |
  def lane($e):
    if $e == "ordinary" then
      if $keychains then
        [$lanes[] | select(.accountLocator.keychainService? == "Claude Code-credentials")] | first
      else
        [$lanes[] | select(.accountLocator.path? == ($home + "/.claude"))] | first
      end
    else
      [$lanes[] | select(.accountLocator.path? == $e and
        (.accountLocator.keychainService? // "") != "Claude Code-credentials")] | first
    end;
  def scope_of($row):
    ($row.quotaSemantics.effectiveAvailability // []) as $s |
    (if $model != "" then ([$s[] | select(.scope == ("model:" + $model))] | first) else null end)
    // ([$s[] | select(.scope == "all_models")] | first);
  def reset_of($row; $sc):
    [($sc.limitingWindowIds // [])[] as $id | ($row.windows // [])[] |
      select(.id == $id) | (.resetsAt // empty)] | first;
  [range(0; $declared | length) as $i | $declared[$i] as $e | lane($e) as $row |
    (if $row == null then null else scope_of($row) end) as $sc |
    {idx: $i, entry: $e,
     key: ($row.accountKey // "unmeasured"),
     scope: ($sc.scope // "none"),
     epr: $sc.effectivePercentRemaining,
     sp: $sc.selection.spendPriority?,
     runway: $sc.runway.status?,
     resets: (if $sc == null then null else reset_of($row; $sc) end)} |
    if $row == null then
      .verdict = "unmeasured" |
      .reason = (if $global != "" then $global
        elif ($e | contains(":")) and $e != "ordinary" then "a path containing : cannot be named in QUOTA_AXI_CLAUDE_PROFILES"
        elif ($lanes | length) == 0 then "quota-axi reported no Claude account lanes"
        else "no quota-axi lane carries a locator for this account" end)
    elif ($row.state.status? // "unknown") != "fresh" then
      .verdict = "unmeasured" | .reason = "lane status is \($row.state.status? // "unknown")"
    elif $sc == null then
      .verdict = "unmeasured" | .reason = "the lane reports no all_models scope"
    elif $sc.status != "known" or (.epr | type) != "number" then
      .verdict = "unmeasured" | .reason = "the \(.scope) scope is not measured"
    elif .epr <= 0 or .runway == "exhausted_now" then
      .verdict = "exhausted" | .reason = "no allowance left in the \(.scope) scope"
    else
      .verdict = "eligible" |
      .reason = (if (.sp | type) == "number" then "fresh and measured" else "fresh and measured; spendPriority unknown" end)
    end
  ] as $rows |
  ($rows[] | ["lane", .idx, .key, .scope, (.epr | str), (.sp | str), (.runway | str), (.resets | str), .verdict, .reason] | @tsv),
  ([$rows[] | select(.verdict == "eligible")] |
    sort_by([(if (.sp | type) == "number" then 0 else 1 end), (if (.sp | type) == "number" then -.sp else 0 end), (.resets // "~"), .idx])) as $eligible |
  if ($eligible | length) > 0 then
    $eligible[0] as $best | ($eligible[1] // null) as $next |
    (if ($best.sp | type) != "number" then
       "no eligible account reports spendPriority, so the earliest resetsAt, then the earlier line, decided"
     elif $next != null and $next.sp == $best.sp then
       (if $next.resets != $best.resets then "highest spendPriority \($best.sp), tied and broken by the earliest resetsAt"
        else "highest spendPriority \($best.sp), tied and broken by the earlier line in config/claude-account" end)
     else "highest spendPriority \($best.sp) among \($eligible | length) eligible account(s)" end) as $why |
    ["choice", $best.idx, $why] | @tsv
  elif ([$rows[] | select(.verdict == "unmeasured")] | length) > 0 then
    ([$rows[] | select(.verdict == "unmeasured")] | first) as $first |
    ["choice", $first.idx, "UNMEASURED DEFAULT: no account is measurably eligible (\($first.reason)), so the first unmeasured line in config/claude-account is used without quota evidence"] | @tsv
  else
    ["exhausted", "-", "every declared Claude account is measured and exhausted; report instead of spawning"] | @tsv
  end
') || {
  echo "error: could not evaluate the quota-axi snapshot for config/claude-account" >&2
  exit 1
}

rc=0
while IFS=$'\t' read -r kind f1 f2 f3 f4 f5 f6 f7 f8 f9; do
  case "$kind" in
  lane)
    echo "lane: ${DECLARED[$f1]} accountKey=$f2 scope=$f3 effectivePercentRemaining=$f4 spendPriority=$f5 runway=$f6 resetsAt=$f7 verdict=$f8 ($f9)"
    ;;
  choice)
    echo "basis: $f2"
    echo "account: ${DECLARED[$f1]}"
    ;;
  exhausted)
    echo "basis: $f2"
    rc=$FM_CLAUDE_ACCOUNT_EXHAUSTED_EXIT
    ;;
  esac
done <<EOF_RESULT
$RESULT
EOF_RESULT
exit "$rc"
