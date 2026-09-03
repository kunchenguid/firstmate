# fm-cswap-select.jq - the pure cswap account-selection decision function.
#
# Sourced by bin/fm-cswap-lib.sh via `jq -f`, never invoked standalone in
# production, but stable enough to unit-test directly with fixture JSON
# (tests/fm-cswap-select.test.sh).
#
# Input (stdin): a JSON array of per-account rows, one per cswap-managed
# account, already epoch-normalized by fm_cswap_augment_epochs (raw ISO8601
# strings cannot reach here - jq's fromdateiso8601 does not accept cswap's
# fractional-second/offset timestamps). Each row:
#   {number, email, alias, disabled, usageStatus, usageAgeSeconds, plan,
#    pct5h, resets5hEpoch, pct7d, resets7dEpoch,
#    expectedPct7d, aheadOfPace7d, willLastToReset7d, projectedExhaustionAt7dEpoch}
# Numeric/boolean fields are null when cswap did not report them. `plan` is
# the account's plan-size multiplier when cswap exposes one; cswap's current
# `list --json` schema carries no explicit plan field (it is null in
# practice), because plan size is already folded into cswap's own weekly
# pace math (expectedPct7d / projectedExhaustionAt7d / willLastToReset7d) -
# a bigger plan yields a lower expected-pace and a longer projected runway.
# It is still read and ranked so the figure is captured verbatim in evidence
# and takes effect immediately if a future cswap build reports it.
#
# --argjson now        current epoch seconds
# --argjson active     the currently active account number, or null
# --argjson maxAgeS     usage freshness floor in seconds; an older
#                       usageAgeSeconds makes that candidate ineligible
#                       (fail-closed on stale evidence, never a fabricated
#                       guess)
#
# Output: one JSON object -
#   {decision: "switch"|"keep-current", chosen: <number-or-null>,
#    reason: "<human-readable>", candidates: [<row + computed fields>]}
#
# Decision method:
#  1. A candidate is eligible only when enabled, usageStatus is "ok", both
#     the 5h and 7d windows report a numeric pct under 100, and the usage
#     measurement is not older than $maxAgeS. A missing resets timestamp on
#     a window is NOT disqualifying by itself - cswap omits resetsAt for a
#     window nothing has consumed yet (a genuinely untouched account has no
#     open window to report), and neither reset epoch is read anywhere but
#     the 7d margin computation below, which already treats a missing
#     projection as the safest case. Any other case (disabled, error status,
#     absent or out-of-range pct, or stale usage) is disclosed uncertainty,
#     not a guess, so the row is excluded rather than ranked.
#  2. margin7d is cswap's own weekly burn-rate-vs-reset projection
#     (projectedExhaustionAt7dEpoch - resets7dEpoch): positive means the
#     account is projected to exhaust AFTER its own reset (safe, and larger
#     is a bigger buffer); negative means it will run dry BEFORE reset (the
#     exact "burn runway vs reset time" figure this selection exists for).
#     null means cswap projected no burn at all (idle/flat account - treated
#     as the safest tier, never a fabricated infinite number).
#  3. Eligible accounts split into "safe" (willLastToReset7d true, or no
#     projection at all) and the rest; safe accounts are preferred as a
#     group over at-risk ones whenever at least one safe account exists.
#  4. Within a tier, rank by margin7d (bigger buffer wins), then plan size
#     (a larger plan has more absolute capacity; null plans compare equal so
#     the current cswap schema is unaffected), then remaining 7d headroom,
#     then remaining 5h headroom, then - the deliberate tie-break - the
#     currently active account, then account number for a fully
#     deterministic order. Ranking the active account ahead of an
#     otherwise-tied peer is what keeps a genuine tie on the current
#     account rather than churning to an arbitrary equally-good one.
#  5. No eligible candidate at all keeps the current account (fail-closed);
#     this function never chooses a switch on absent or stale evidence.

def is_eligible:
  # Fail CLOSED on authorization: a candidate is eligible only when its
  # disabled state is EXPLICITLY the boolean false (positively in-rotation).
  # fm_cswap_augment_epochs/fm_cswap_candidates already normalize cswap's
  # omit-when-enabled contract to a concrete boolean, so `== false` here means
  # a null or otherwise-unconfirmed disabled state can never slip through as
  # enabled and reach `cswap switch` (`.disabled | not` would have let a null
  # pass as eligible).
  (.disabled == false)
  and (.usageStatus == "ok")
  and (.pct5h != null) and (.pct7d != null)
  and (.pct5h < 100) and (.pct7d < 100)
  and ((.usageAgeSeconds == null) or (.usageAgeSeconds <= $maxAgeS));

def margin7d_of:
  if (.projectedExhaustionAt7dEpoch == null) or (.resets7dEpoch == null) then null
  else .projectedExhaustionAt7dEpoch - .resets7dEpoch
  end;

def reserve7d_of:
  if (.expectedPct7d == null) or (.pct7d == null) then null
  else (.expectedPct7d - .pct7d)
  end;

def is_safe7d:
  (.willLastToReset7d == true) or (.projectedExhaustionAt7dEpoch == null);

def fmt_days($seconds):
  if $seconds == null then "unknown"
  else (($seconds / 86400) * 100 | round | . / 100 | tostring) + "d"
  end;

map(
  . + {
    eligible: is_eligible,
    headroom5h: (if .pct5h == null then null else (100 - .pct5h) end),
    headroom7d: (if .pct7d == null then null else (100 - .pct7d) end),
    margin7dSeconds: margin7d_of,
    reserve7dPct: reserve7d_of,
    safe7d: is_safe7d
  }
) as $rows
| ($rows | map(select(.eligible))) as $eligible
| if ($eligible | length) == 0 then
    {
      decision: "keep-current",
      chosen: null,
      reason: "no eligible cswap account (all disabled, errored, unmeasurable, or usage older than \($maxAgeS)s)",
      candidates: $rows
    }
  else
    ($eligible | map(select(.safe7d))) as $safeRows
    | (if ($safeRows | length) > 0 then $safeRows else $eligible end) as $pool
    | (
        $pool | sort_by([
          -(.margin7dSeconds // 999999999999),
          -(.plan // 0),
          -(.headroom7d // 0),
          -(.headroom5h // 0),
          (if .number == $active then 0 else 1 end),
          .number
        ])
      ) as $ranked
    | ($ranked[0]) as $best
    | if $best.number == $active then
        {
          decision: "keep-current",
          chosen: $active,
          reason: "active account \($active) is already the best eligible candidate (margin7d=\(fmt_days($best.margin7dSeconds)), headroom7d=\($best.headroom7d)%)",
          candidates: $rows
        }
      else
        {
          decision: "switch",
          chosen: $best.number,
          reason: "account \($best.number) has margin7d=\(fmt_days($best.margin7dSeconds)) headroom7d=\($best.headroom7d)% headroom5h=\($best.headroom5h)% vs active account \(($active // "none"))",
          candidates: $rows
        }
      end
  end
