#!/usr/bin/env bash
# Combined fleet quota view: subscription headroom across all agent providers.
# Merges two sources that each see a different slice of the fleet:
#   1. quota-axi --json    - authoritative for Codex (and Grok/Cursor/Copilot
#      when signed in). Its Claude reading is single-OAuth and under-reads the
#      multi-seat Anthropic fleet, so it is dropped from the view whenever the
#      multi-Claude balancer below is reachable.
#   2. /opt/claude balancer - the five-seat Anthropic view (per-seat 5h usage,
#      plan-wide 7d usage, rate-limit flags, and the load-balancer's own pick),
#      read via `bun run /opt/claude/src/cli.ts balance --json`. Read-only: this
#      never mutates the active account or selects a seat.
#
# Usage:
#   fm-quota.sh [--json] [--provider <claude,codex,cursor,copilot,grok>]
#   --json               emit the combined machine-readable object (see below)
#   --provider <list>    restrict quota-axi to these providers (passthrough)
#   --help
#
# Portable and fail-soft: a host without quota-axi, without /opt/claude, or
# without bun still gets whatever source is present. The tool never blocks and
# never prints credentials or tokens - only usage percentages, status strings,
# and seat labels (arcs/jr/nyu/ra/yfz), which are not secrets.
#
# Recommendation is evidence-first and continuous: each candidate is scored by
# its remaining headroom fraction (higher is better), rate-limited/unavailable
# candidates are hard-excluded, and the max wins. When Claude is fully rate-
# limited and no metered-free provider has headroom, it recommends the DeepSeek
# (ds) throwaway fallback. It advises; it does not route - fm-dispatch-select.sh
# owns the deterministic quota-balanced strategy and is untouched by this tool.
#
# JSON shape:
#   {generatedAt, claude:{available,pick,weeklyPct,allRateLimited,seats:[...]}|null,
#    providers:[{provider,label,status,minRemainingPct}], recommendation:{pick,remainingPct,reason,alternatives}}
set -u

QUOTA_CMD=${FM_QUOTA_AXI:-quota-axi}
CLAUDE_CLI=${FM_QUOTA_CLAUDE_CLI:-/opt/claude/src/cli.ts}
BUN=${FM_QUOTA_BUN:-bun}
TIMEOUT_SECS=${FM_QUOTA_TIMEOUT:-40}

json_mode=0
provider_arg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json_mode=1 ;;
    --provider)
      [ "$#" -gt 1 ] || { echo "error: --provider requires a value" >&2; exit 2; }
      provider_arg=$2; shift ;;
    --provider=*) provider_arg=${1#--provider=} ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

run_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$TIMEOUT_SECS" "$@"; else "$@"; fi; }

# --- Source 1: quota-axi (multi-vendor) --------------------------------------
quota_json='{"providers":[]}'
if command -v "$QUOTA_CMD" >/dev/null 2>&1; then
  qargs=(--json)
  [ -n "$provider_arg" ] && qargs+=(--provider "$provider_arg")
  raw=$(run_timeout "$QUOTA_CMD" "${qargs[@]}" 2>/dev/null || true)
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    quota_json=$raw
  fi
fi

# --- Source 2: /opt/claude multi-seat balancer -------------------------------
claude_json=null
if [ -r "$CLAUDE_CLI" ] && command -v "$BUN" >/dev/null 2>&1; then
  raw=$(run_timeout "$BUN" run "$CLAUDE_CLI" balance --json 2>/dev/null || true)
  if [ -n "$raw" ] && printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    claude_json=$raw
  fi
fi

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Combine + recommend (one jq program) ------------------------------------
combined=$(jq -n \
  --argjson q "$quota_json" \
  --argjson c "$claude_json" \
  --arg now "$generated_at" '
  # remaining fraction for a quota-axi provider = min percentRemaining over its
  # usable windows, /100; null when no windows (signed out / rate limited).
  def min_remaining($p):
    ([ $p.windows[]? | .percentRemaining // empty ] | if length > 0 then (min / 100) else null end);

  # Claude block from the balancer (null when balancer unreachable).
  ($c) as $cb
  | (if $cb == null then null else {
      available: ($cb.allRateLimited | not),
      pick: $cb.account,
      weeklyPct: $cb.weeklyPct,
      allRateLimited: $cb.allRateLimited,
      seats: [ $cb.scores[] | {
        account,
        fivehrUsedPct: ((.rollingPct * 100) | round),
        rateLimited,
        paceStatus,
        activeSessions,
        isPick: (.account == $cb.account)
      } ]
    } end) as $claude

  # Provider table from quota-axi. Drop claude when the balancer supersedes it.
  | [ $q.providers[]?
      | select(.provider != "claude" or $claude == null)
      | { provider, label, status: .state.status,
          minRemainingPct: (min_remaining(.) | if . == null then null else (. * 100 | round) end) } ] as $providers

  # Candidates for the recommendation, each with a remaining fraction.
  | ([ if $claude != null and $claude.available then
         { label: ("claude-opus (seat " + $claude.pick + ")"),
           # binding = min(plan-wide 7d headroom, best available seat 5h headroom)
           remaining: ([ (1 - $claude.weeklyPct),
                         ([ $claude.seats[] | select(.rateLimited | not) | (1 - (.fivehrUsedPct/100)) ] | max // 0) ] | min) }
       else empty end ]
     + [ $q.providers[]?
         | select(.provider == "codex" and .state.status == "fresh")
         | { label: "pi-codex", remaining: (min_remaining(.) // 0) } ]
     + [ $q.providers[]?
         | select(.provider == "grok" and .state.status == "fresh")
         | { label: "pi-grok", remaining: (min_remaining(.) // 0) } ]
    ) as $cands

  | ($cands | map(select(.remaining > 0)) | sort_by(-.remaining)) as $ranked
  | (if ($ranked | length) == 0 then
       { pick: "deepseek (ds) fallback",
         remainingPct: null,
         reason: "no subscription provider has usable headroom (Claude fully rate-limited and no metered-free provider free); route disposable fan-out to ds.",
         alternatives: [] }
     else
       ($ranked[0]) as $best
       | { pick: $best.label,
           remainingPct: ($best.remaining * 100 | round),
           reason: ("highest remaining headroom: " + ([ $ranked[] | (.label + " " + ((.remaining*100)|round|tostring) + "%") ] | join(", ")) + "."),
           alternatives: [ $ranked[1:][] | { pick: .label, remainingPct: (.remaining*100|round) } ] }
     end) as $rec

  | { generatedAt: $now, claude: $claude, providers: $providers, recommendation: $rec }
')

if [ "$json_mode" -eq 1 ]; then
  printf '%s\n' "$combined"
  exit 0
fi

# --- Human-readable render ----------------------------------------------------
printf '%s\n' "$combined" | jq -r '
  def bar($usedPct): ([[($usedPct // 0) / 10 | floor, 0] | max, 10] | min) as $n
    | (("#" * $n) + ("." * (10 - $n)));
  def pad($s; $w): $s + (" " * ([$w - ($s | length), 0] | max));
  "FLEET QUOTA  (" + .generatedAt + ")",
  "",
  "Providers (quota-axi):",
  ( if (.providers | length) == 0 then "  (quota-axi unavailable)"
    else (.providers[]
      | "  " + (.label // .provider | .[0:16]) + "\t"
        + (if .minRemainingPct == null then ("-- " + .status) else ((.minRemainingPct|tostring) + "% free") end))
    end ),
  "",
  ( if .claude == null then "Claude (multi-seat): balancer unreachable (/opt/claude absent); quota-axi single-OAuth reading above is the only Claude signal."
    else
      ( "Claude seats (/opt/claude balancer)  plan 7d used " + ((.claude.weeklyPct*100)|round|tostring) + "%"
        + (if .claude.allRateLimited then "  [ALL RATE-LIMITED]" else "" end) ),
      ( .claude.seats[]
        | "  " + (if .isPick then "* " else "  " end) + pad(.account; 5)
          + "  5h [" + bar(.fivehrUsedPct) + "] " + (.fivehrUsedPct|tostring) + "% used"
          + (if .rateLimited then "  RATE-LIMITED" else "" end)
          + (if .activeSessions > 0 then ("  (" + (.activeSessions|tostring) + " active)") else "" end) ),
      "  (* = balancers current pick)"
    end ),
  "",
  "-> Recommended dispatch: " + .recommendation.pick
    + (if .recommendation.remainingPct != null then ("  (" + (.recommendation.remainingPct|tostring) + "% headroom)") else "" end),
  "   " + .recommendation.reason
'
