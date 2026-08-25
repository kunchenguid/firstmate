# Local Patches

This file tracks local modifications applied to the upstream Firstmate codebase.
Each patch has a unique ID, a clear revert procedure, and a status.

---

## patch-wedge-cap-2026-08-19

**Status:** applied on branch `patch/wedge-cap-2026-08-19` (off main). v4 (2026-08-25) addresses Greptile review round 3: explicit error-check on the marker write, with rollback on `fm_wake_append` failure so both error paths exit 1 with neither marker nor queue entry — the next poll retries cleanly.

**Problem:** `FM_WEDGE_DEMAND_INSPECT_COUNT` (default 3) adds a `demand-deep-inspection` marker to wedge-escalation wakes once a pane has re-wedged on the same stale hash. The design assumes a human or smart supervisor will act on the marker and break the loop. In LLM-supervised unattended setups (herdr + pi agent), the marker is read but never acted on: pi responds to every wake, the wedge never resolves, escalations keep incrementing (observed: 70, 112, 129 in a single session), and the agent loop hammers the model API until the quota is drained. Root-cause of the 2026-08-18 MiniMax subscription drain (~359M tokens).

**Fix:** Add a new constant `FM_WEDGE_MAX_ESCALATIONS` (default 10). Once escalations reach it, `wedge_timer_check` emits ONE terminal wake with a `PERMANENTLY-WEDGED` marker and writes a durable `STATE/.wedge-permanent-<key>-<hash12>` file (per-hash, not per-window, so a fresh stale hash in the same window can still escalate). Subsequent polls for the SAME stale hash short-circuit (no more wakes). The marker is cleared at the existing reset sites (`handle_paused_stale`, `clear_pause_tracking`) via a glob on `.wedge-permanent-<key>-*`, so a wedge that genuinely resolves can re-escalate later if it wedges again.

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
