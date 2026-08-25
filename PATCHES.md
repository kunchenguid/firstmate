# Local Patches

This file tracks local modifications applied to the upstream Firstmate codebase.
Each patch has a unique ID, a clear revert procedure, and a status.

---

## patch-wedge-cap-2026-08-19

**Status:** applied on branch `patch/wedge-cap-2026-08-19` (off main). v9 (2026-08-25) replaces the v6/v7/v8 recovery-lift model with a cap-horizon design. The cap marker is honored for at most FM_CAP_HORIZON_SECS (default 24h); after that, the cap is stale and a new wedge on the same (window, hash) can re-fire. The v6/v7/v8 auto-lift sites (using pause_state_class=working) are removed - pause_state_class can be a steady-state during a wedge, not a recovery signal, and trying to use it as a recovery gate introduced cycle issues in every round (R5, R6, R7, R8). Hash change naturally invalidates the marker (keyed on hash); operator can `rm` for immediate re-engagement.

**Problem:** `FM_WEDGE_DEMAND_INSPECT_COUNT` (default 3) adds a `demand-deep-inspection` marker to wedge-escalation wakes once a pane has re-wedged on the same stale hash. The design assumes a human or smart supervisor will act on the marker and break the loop. In LLM-supervised unattended setups (herdr + pi agent), the marker is read but never acted on: pi responds to every wake, the wedge never resolves, escalations keep incrementing (observed: 70, 112, 129 in a single session), and the agent loop hammers the model API until the quota is drained. Root-cause of the 2026-08-18 MiniMax subscription drain (~359M tokens).

**Fix:** Add a new constant `FM_WEDGE_MAX_ESCALATIONS` (default 10) and `FM_CAP_HORIZON_SECS` (default 86400 = 24h). Once escalations reach `FM_WEDGE_MAX_ESCALATIONS`, `wedge_timer_check` emits ONE terminal wake with a `PERMANENTLY-WEDGED` marker and writes a durable `STATE/.wedge-permanent-<key>-<hash12>` file. Subsequent polls for the SAME stale hash short-circuit (no more wakes) UNTIL either:
  - the cap horizon elapses (marker file's stored timestamp is older than `FM_CAP_HORIZON_SECS`), OR
  - the hash changes (marker is keyed on hash; different key = different cap), OR
  - the operator manually `rm`s the marker for immediate re-engagement.

**Why this model instead of auto-lift on recovery:** the v6/v7/v8 lift sites used `pause_state_class=working` as the recovery gate, but pause_state_class can be a steady-state during a wedge (the worker is doing things but the pane is static). Using a steady-state verdict as a recovery signal introduced a fresh cycle issue on every Greptile round (R5: cap never lifted; R6: cap not lifted on same-hash recovery without pause; R7: cap fires every wedge_timer_check after lift; R8: pause_state_class=working is unchanged throughout the original wedge). The cap-horizon model bounds silent-suppression to a fixed time window without depending on an ambiguous recovery verdict.

**Trade-offs:**
  - Short wedges (< STALE_ESCALATE_SECS * FM_WEDGE_MAX_ESCALATIONS) produce only normal escalations, no cap wake.
  - Long wedges (>= the horizon) produce 1 cap wake per horizon, bounded.
  - Cycling wedges (wedges, recovers, wedges) bounded by 1 cap wake per horizon.
  - Operator `rm` provides immediate re-engagement (bypasses the horizon).

Other `clear_pause_tracking` / `handle_paused_stale` call sites do NOT clear the marker (those are automatic supervision-state transitions, not proof that the wedge resolved).

**Atomicity invariant (v4 fix):** the marker is written FIRST, with an explicit error check. v3 wrote the marker AFTER `fm_wake_append` but BEFORE `wake`, which was correct in spirit but didn't check the marker write — a fs failure on the marker write persisted nothing and `wake` `exit 0`ed anyway, so the cap kept firing terminal wakes every ~STALE_ESCALATE_SECS. v4 writes the marker first; if the write fails, exit 1 without queueing or waking (clean abort, next poll retries). If the marker write succeeds but `fm_wake_append` then fails, the marker is rolled back (`rm -f "$permanent_marker"`) and exit 1 (clean abort, next poll retries). Success path: marker durable, queue entry durable, `wake` runs. Neither failure mode produces the v1 "silent wedge" (marker without queue entry) or the v3 "fire every STALE_ESCALATE_SECS" regression.

**Override validation (v3 fix):** `FM_WEDGE_MAX_ESCALATIONS` is validated at load. A non-positive integer (0, negative) would fire the cap on the very first wedge escalation, silencing wakes before the demand-deep-inspection marker ever surfaces; a non-integer would make the integer comparison error silently (no `set -e` here) and the cap would never fire. Either case the safety floor is broken. Both are rejected with a `triage_log` warning and the value falls back to the default (10).

**Files modified:** `bin/fm-watch.sh`

**Diff size:** +60 / -6 (approx, vs main)

**Revert procedure:**

```bash
cd ~/firstmate
git checkout main
git branch -D patch/wedge-cap-2026-08-19
git rm PATCHES.md   # only if not adopted upstream
```

Or, to revert in-place on the branch:

```bash
cd ~/firstmate
git checkout bin/fm-watch.sh
rm PATCHES.md
git commit -am "revert: patch-wedge-cap-2026-08-19"
```

**Upstream report:** see PR #2605 against `kunchenguid/firstmate` and the message text in this session's chat history. If the maintainer accepts a similar fix on main, this patch can be dropped and the branch deleted.

**Override knobs (if the cap fires too eagerly):**

```bash
# Make the cap even tighter (5 escalations = ~20 min) for cost-sensitive setups:
export FM_WEDGE_MAX_ESCALATIONS=5

# Disable the cap entirely (revert to upstream behavior):
export FM_WEDGE_MAX_ESCALATIONS=999999
```

**Why not just kill the v1 watcher or disable herdr auto-restore:** those would lose real supervision functionality (idle detection, error surfacing, agent restore on herdr restart). The cap preserves the existing signal-escalation design and only adds a safety floor at the unattended-loop end.
