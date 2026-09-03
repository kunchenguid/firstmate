#!/usr/bin/env bash
# fm-cswap-lib.sh - automated cswap (claude-swap) account selection at a
# Claude-provider crew/secondmate dispatch boundary.
#
# WHY. The captain used to have firstmate manually prefer a fixed cswap slot
# on every dispatch. This library replaces that fixed-slot habit with a
# per-dispatch decision over the captain's own cswap-managed accounts,
# ranked by remaining 5h/7d headroom AND cswap's own weekly burn-rate-vs-
# reset projection (bin/fm-cswap-select.jq owns the ranking; this file owns
# I/O, safety guards, and evidence).
#
# ONE OWNER. quota-axi's spendPriority does not cover this: it models only
# the single currently-active OS-level Claude credential (see
# data/learnings.md), never a list of cswap-managed accounts, so it cannot
# rank candidates it has no visibility into. This library is therefore the
# one place that computes cswap account economics; it does not reimplement
# quota-axi's own spendPriority for any other provider.
#
# SAFETY CONTRACT.
#   - AUTHORIZATION. The whole mechanism is opt-in: fm-spawn.sh only calls this
#     library when the captain has set FM_CSWAP_AUTOSELECT=1, the deliberate
#     grant that opts a fleet into automated selection. Mutating the shared
#     active Claude credential is never assumed just because a `cswap` CLI is
#     installed; with the gate unset no cswap command runs at all. Within that
#     grant, selection is scoped to the captain's own cswap-managed accounts,
#     and only the non-disabled ones: a `disabled` account is the captain's
#     explicit "hold this out of rotation" signal and is never a candidate
#     (fm-cswap-select.jq is_eligible). Firing at every claude dispatch boundary
#     is intentional (AGENTS.md section 4 - this is the one place cswap
#     economics are decided), bounded by that authorization set and by the
#     mid-task guards below.
#   - `cswap switch <exact-number>` only - never a bare rotate, never
#     `--strategy`, so the target is always the one this library's own
#     ranking chose and can name in evidence.
#   - Fires only once, at the moment a NEW claude-harness agent is about to
#     be launched (bin/fm-spawn.sh, right before the launch command is sent
#     into the pane), never on a timer and never mid-task.
#   - Skips the switch entirely (fail-closed to "keep current", never a
#     silent guess) when: cswap or jq is unavailable, `cswap list --json`
#     fails or does not parse, any candidate's usage is stale past
#     FM_CSWAP_MAX_USAGE_AGE_S, or another claude-harness task recorded in
#     the same state directory is currently classified busy (mid-turn) -
#     switching the shared global credential out from under a live worker
#     is exactly what this guard exists to prevent.
#   - Never fires a switch onto the account already active: the decision
#     function itself treats that as "keep-current", and the caller
#     re-confirms the live active number under a per-state-dir lock
#     (state/.cswap-switch.lock) immediately before calling `cswap switch`,
#     so two racing spawns can never both fire onto the same freshly-chosen
#     target. If that re-confirmation shows the live active account has moved
#     to some OTHER account since the list was read (a concurrent spawn
#     already switched), the decision was ranked against stale state, so the
#     switch is skipped (keep-current) rather than executing an obsolete
#     target over a fresher selection. If the re-confirmation itself fails
#     (`cswap status --json` cannot report the live active account under the
#     lock), the switch is likewise skipped fail-closed - an unconfirmable
#     active account is never assumed to still be the one the decision ranked
#     against, so a stale target can never be fired on a failed status read.
#   - After a switch, re-reads `cswap status --json` and records whether the
#     active account actually became the intended one; a mismatch is
#     recorded as verified=false and never reported as a successful switch.
#   - Never aborts or blocks the spawn: every failure mode above is
#     recorded to the evidence sidecar and the caller proceeds with
#     whatever account is currently active.
#
# EVIDENCE. Every run writes state/<task-id>.cswap-select (JSON), even a
# no-op, so the decision remains inspectable after the fact:
#   {ranAt, decision, chosen, reason, active, switched, verified,
#    switchExitCode, skippedReason, candidates: [...]}
# candidates carries every account's read inputs (plan, pct5h/7d, resets,
# cswap's own expectedPct/aheadOfPace/projectedExhaustionAt/willLastToReset
# for the 7d window) plus this library's computed headroom/margin/reserve
# fields.
#
# PLAN SIZE. Selection ranks by plan size among the other inputs, but cswap's
# current `list --json` schema exposes no explicit plan/planSize field (the
# per-account keys are number/email/organization*/isOrganization/active/
# usageStatus/usage/usageFetchedAt/usageAgeSeconds only), so `plan` reads
# null today. That is not a gap: plan size is already folded into cswap's own
# weekly pace math - a larger plan produces a lower expectedPct pace and a
# longer projectedExhaustionAt runway, which is exactly the burn-runway-vs-
# reset figure this library ranks on. `plan` is still extracted and ranked so
# it is captured verbatim in evidence and takes effect the moment a future
# cswap build begins reporting it, without a second owner of plan economics.
#
# Usage: . bin/fm-cswap-lib.sh
#   fm_cswap_dispatch_switch <task-id> <state-dir>
set -u

FM_CSWAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$FM_CSWAP_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$FM_CSWAP_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh disable=SC1091
. "$FM_CSWAP_LIB_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$FM_CSWAP_LIB_DIR/fm-wake-lib.sh"

# Accounts refresh on their own poll cadence (cswap's README: "a couple of
# minutes"); 30 minutes is well past any healthy poll interval, so evidence
# older than this is treated as unmeasurable rather than trusted.
FM_CSWAP_MAX_USAGE_AGE_S=${FM_CSWAP_MAX_USAGE_AGE_S:-1800}
FM_CSWAP_CMD_TIMEOUT_S=${FM_CSWAP_CMD_TIMEOUT_S:-10}

fm_cswap_available() {
  command -v cswap >/dev/null 2>&1
}

fm_cswap_jq_available() {
  command -v jq >/dev/null 2>&1
}

# fm_cswap_iso_to_epoch <iso8601>: epoch seconds, or return 1 on failure.
# cswap emits both "…SS.ffffff+00:00" (resetsAt) and "…SSZ" (projected*At)
# shapes (data/learnings.md); BSD `date -j -f` needs an exact format, so
# fractional seconds are stripped and a numeric +00:00 offset is normalized
# to Z before that attempt, while the GNU `date -d` fallback parses the
# original string directly (it accepts both shapes natively).
fm_cswap_iso_to_epoch() {
  local ts=$1 stripped
  [ -n "$ts" ] || return 1
  stripped=$(printf '%s' "$ts" | sed -E 's/\.[0-9]+//; s/\+00:00$/Z/')
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stripped" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null \
    || return 1
}

fm_cswap_now_epoch() {
  date -u +%s
}

# fm_cswap_list_json: bounded `cswap list --json` on stdout; empty stdout
# means the call failed or timed out (a successful call always emits at
# least schemaVersion), which is what the caller checks.
fm_cswap_list_json() {
  fm_run_timed "$FM_CSWAP_CMD_TIMEOUT_S" cswap list --json 2>/dev/null
}

# fm_cswap_status_json: bounded `cswap status --json` on stdout.
fm_cswap_status_json() {
  fm_run_timed "$FM_CSWAP_CMD_TIMEOUT_S" cswap status --json 2>/dev/null
}

# fm_cswap_augment_epochs: reads normalized account rows (as produced by the
# jq extraction in fm_cswap_candidates) on stdin, adds *Epoch fields for
# every ISO timestamp via fm_cswap_iso_to_epoch (never jq's fromdateiso8601 -
# see fm_cswap_iso_to_epoch), and prints the augmented array. A timestamp
# that fails to parse becomes null rather than aborting the whole read, so
# one account's malformed evidence cannot hide every other account's.
fm_cswap_augment_epochs() {
  local rows count i row resets5h resets7d proj7d \
    resets5h_epoch resets7d_epoch proj7d_epoch out
  rows=$(cat)
  count=$(printf '%s' "$rows" | jq 'length') || return 1
  out='[]'
  i=0
  while [ "$i" -lt "$count" ]; do
    row=$(printf '%s' "$rows" | jq -c ".[$i]")
    resets5h=$(printf '%s' "$row" | jq -r '.resets5h // empty')
    resets7d=$(printf '%s' "$row" | jq -r '.resets7d // empty')
    proj7d=$(printf '%s' "$row" | jq -r '.projectedExhaustionAt7d // empty')
    resets5h_epoch=$(fm_cswap_iso_to_epoch "$resets5h" || true)
    resets7d_epoch=$(fm_cswap_iso_to_epoch "$resets7d" || true)
    proj7d_epoch=$(fm_cswap_iso_to_epoch "$proj7d" || true)
    row=$(printf '%s' "$row" | jq -c \
      --argjson r5 "${resets5h_epoch:-null}" \
      --argjson r7 "${resets7d_epoch:-null}" \
      --argjson p7 "${proj7d_epoch:-null}" \
      '. + {resets5hEpoch: $r5, resets7dEpoch: $r7, projectedExhaustionAt7dEpoch: $p7}')
    out=$(printf '%s' "$out" | jq -c --argjson row "$row" '. + [$row]')
    i=$((i + 1))
  done
  printf '%s\n' "$out"
}

# fm_cswap_candidates: normalizes raw `cswap list --json` into the row shape
# fm_cswap_augment_epochs and fm-cswap-select.jq expect. Returns 1 on
# unparseable input.
fm_cswap_candidates() {
  local raw=$1
  printf '%s' "$raw" | jq -c '
    [.accounts[] | {
      number, email,
      alias: (.alias // ""),
      # cswap emits `disabled` ONLY for a slot held out of rotation
      # (claude_swap/json_output.py: `row["disabled"] = True`); the key is
      # omitted for an in-rotation account and is never serialized as false or
      # null. Honor that confirmed contract - an ABSENT key is a positively
      # in-rotation account (enabled) - but fail CLOSED on any present-but-
      # ambiguous value: a bare null or a non-false scalar from a partial or
      # garbled read is treated as disabled, never silently enabled onto the
      # credential switch. (`.disabled // false` would have read such a null as
      # enabled.)
      disabled: (
        if (has("disabled") | not) then false
        elif (.disabled == false) then false
        else true
        end
      ),
      usageStatus,
      usageAgeSeconds: (.usageAgeSeconds // null),
      plan: (.plan // .planSize // .planMultiplier // null),
      pct5h: (.usage.fiveHour.pct // null),
      resets5h: (.usage.fiveHour.resetsAt // null),
      pct7d: (.usage.sevenDay.pct // null),
      resets7d: (.usage.sevenDay.resetsAt // null),
      expectedPct7d: (.usage.sevenDay.expectedPct // null),
      aheadOfPace7d: (.usage.sevenDay.aheadOfPace // null),
      projectedExhaustionAt7d: (.usage.sevenDay.projectedExhaustionAt // null),
      willLastToReset7d: (.usage.sevenDay.willLastToReset // null)
    }]
  ' 2>/dev/null
}

# fm_cswap_decide <candidates-json> <active-number-or-null>: runs the pure
# selection function and prints its decision JSON.
fm_cswap_decide() {
  local candidates=$1 active=$2 now
  now=$(fm_cswap_now_epoch)
  printf '%s' "$candidates" | jq -c \
    --argjson now "$now" \
    --argjson active "${active:-null}" \
    --argjson maxAgeS "$FM_CSWAP_MAX_USAGE_AGE_S" \
    -f "$FM_CSWAP_LIB_DIR/fm-cswap-select.jq" 2>/dev/null
}

# fm_cswap_any_other_claude_busy <state-dir> <exclude-id>: 0 (true) iff a
# task other than <exclude-id> whose recorded harness matches claude* is
# currently classified busy. Requires fm-backend.sh and fm-busy-lib.sh
# (sourced above). Never treats a read failure as "not busy" for a task
# whose meta genuinely exists and names a claude harness - an unclassifiable
# record is unknown, not idle, per fm-busy-lib.sh, so it does not trip this
# guard, matching that library's own "never fabricate idle" contract.
fm_cswap_any_other_claude_busy() {
  local state=$1 exclude=$2 meta id harness verdict
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" = "$exclude" ] && continue
    harness=$(fm_meta_get "$meta" harness)
    case "$harness" in claude*) ;; *) continue ;; esac
    verdict=$(fm_busy_classify_meta "$meta" "$id" "$state" 2>/dev/null) || continue
    if [ "${verdict%% *}" = busy ]; then
      return 0
    fi
  done
  return 1
}

# fm_cswap_write_evidence <path> <json>: atomic temp+rename write. Best
# effort - a write failure is not fatal to the caller, it just means this
# run's evidence is unavailable for later inspection.
fm_cswap_write_evidence() {
  local path=$1 json=$2 tmp
  tmp="$path.tmp.$$"
  if printf '%s\n' "$json" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
}

# fm_cswap_dispatch_switch <task-id> <state-dir>: the one entry point.
# Always returns 0; every outcome (including every guard skip and every
# failure) is recorded to state/<task-id>.cswap-select rather than raised to
# the caller, so a flaky or absent cswap can never block a crew dispatch.
fm_cswap_dispatch_switch() {
  local id=$1 state=$2
  local evidence="$state/$id.cswap-select"
  local switch_lock="$state/.cswap-switch.lock"
  local lock_held=0 raw candidates active decision chosen
  local switched=false verified=false switch_rc="" skipped_reason=""
  local status_json now_active

  if ! fm_cswap_available; then
    return 0
  fi
  if ! fm_cswap_jq_available; then
    fm_cswap_write_evidence "$evidence" \
      '{"decision":"keep-current","chosen":null,"reason":"jq unavailable; cswap evidence cannot be parsed","switched":false,"verified":false}'
    return 0
  fi

  raw=$(fm_cswap_list_json)
  if [ -z "$raw" ]; then
    fm_cswap_write_evidence "$evidence" \
      '{"decision":"keep-current","chosen":null,"reason":"cswap list --json failed or timed out","switched":false,"verified":false}'
    return 0
  fi
  active=$(printf '%s' "$raw" | jq -r '.activeAccountNumber // empty' 2>/dev/null)
  candidates=$(fm_cswap_candidates "$raw") || candidates=""
  if [ -z "$candidates" ]; then
    fm_cswap_write_evidence "$evidence" \
      '{"decision":"keep-current","chosen":null,"reason":"cswap list --json did not parse","switched":false,"verified":false}'
    return 0
  fi
  candidates=$(printf '%s' "$candidates" | fm_cswap_augment_epochs) || {
    fm_cswap_write_evidence "$evidence" \
      '{"decision":"keep-current","chosen":null,"reason":"cswap account timestamps could not be parsed","switched":false,"verified":false}'
    return 0
  }

  decision=$(fm_cswap_decide "$candidates" "$active")
  if [ -z "$decision" ]; then
    fm_cswap_write_evidence "$evidence" \
      '{"decision":"keep-current","chosen":null,"reason":"selection could not be evaluated","switched":false,"verified":false}'
    return 0
  fi
  chosen=$(printf '%s' "$decision" | jq -r '.chosen // empty')

  if [ "$(printf '%s' "$decision" | jq -r '.decision')" != switch ] || [ -z "$chosen" ]; then
    fm_cswap_write_evidence "$evidence" "$(printf '%s' "$decision" | jq -c \
      --argjson active "${active:-null}" \
      '. + {ranAt: (now | floor), active: $active, switched: false, verified: false}')"
    return 0
  fi

  # Serialize the read-decide-switch-verify sequence so two racing spawns can
  # never both fire onto the same freshly-chosen target (the burst/thrash
  # guard: a switch is only ever fired while holding this lock, and only
  # after re-confirming the live active account under it).
  fm_lock_acquire_wait "$switch_lock"
  lock_held=1

  status_json=$(fm_cswap_status_json)
  now_active=$(printf '%s' "$status_json" | jq -r '.active.number // empty' 2>/dev/null)

  if [ -z "$now_active" ]; then
    # `cswap status --json` failed to confirm the live active account under the
    # lock. The decision was ranked against the pre-lock `cswap list` read; with
    # no fresh confirmation we cannot rule out that a concurrent spawn moved the
    # active account since, so firing `chosen` could clobber a fresher
    # selection. Fail closed to keep-current rather than substitute the stale
    # pre-lock value (which would silently bypass the changed-account guard).
    skipped_reason="active account could not be confirmed under lock; decision may be stale, keeping current"
  elif [ "$now_active" = "$chosen" ]; then
    skipped_reason="already active (confirmed under lock, race with another selection)"
  elif [ "$now_active" != "$active" ]; then
    # The live active account differs from the one the `cswap list` read
    # (active=$active) ranked this decision against - a concurrent spawn already
    # switched, or the active account was unknown at list time and is now some
    # other account. Either way `chosen` was ranked against now-stale state;
    # fire-and-forget onto it could clobber a fresher selection, so fail closed
    # to keep-current rather than execute an obsolete target.
    skipped_reason="active account changed to $now_active since selection (concurrent switch); decision is stale, keeping current"
  elif fm_cswap_any_other_claude_busy "$state" "$id"; then
    skipped_reason="another claude-harness task is currently busy; switching the shared credential could affect it mid-turn"
  fi

  if [ -z "$skipped_reason" ]; then
    fm_run_timed "$FM_CSWAP_CMD_TIMEOUT_S" cswap switch "$chosen" >/dev/null 2>&1
    switch_rc=$?
    status_json=$(fm_cswap_status_json)
    now_active=$(printf '%s' "$status_json" | jq -r '.active.number // empty' 2>/dev/null)
    switched=true
    [ "$now_active" = "$chosen" ] && verified=true
  fi

  [ "$lock_held" -eq 0 ] || fm_lock_release "$switch_lock" 2>/dev/null || true

  fm_cswap_write_evidence "$evidence" "$(printf '%s' "$decision" | jq -c \
    --argjson active "${active:-null}" \
    --arg skipped "$skipped_reason" \
    --argjson switched "$switched" \
    --argjson verified "$verified" \
    --arg switchRc "${switch_rc:-}" \
    --arg confirmedActive "${now_active:-}" \
    '. + {
       ranAt: (now | floor),
       active: $active,
       switched: $switched,
       verified: $verified,
       switchExitCode: ($switchRc | if . == "" then null else tonumber end),
       confirmedActiveAfter: (if $confirmedActive == "" then null else $confirmedActive end),
       skippedReason: (if $skipped == "" then null else $skipped end)
     }')"
  return 0
}
