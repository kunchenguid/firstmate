# Local Patches

This file tracks local modifications applied to the upstream Firstmate codebase.
Each patch has a unique ID, a clear revert procedure, and a status.

---

## patch-wedge-cap-2026-08-19

**Status:** applied on branch `patch/wedge-cap-2026-08-19` (off main). v3 (2026-08-25) addresses Greptile review round 2: marker-write before wake (wake() exits the script) and FM_WEDGE_MAX_ESCALATIONS override validation.

**Problem:** `FM_WEDGE_DEMAND_INSPECT_COUNT` (default 3) adds a `demand-deep-inspection` marker to wedge-escalation wakes once a pane has re-wedged on the same stale hash. The design assumes a human or smart supervisor will act on the marker and break the loop. In LLM-supervised unattended setups (herdr + pi agent), the marker is read but never acted on: pi responds to every wake, the wedge never resolves, escalations keep incrementing (observed: 70, 112, 129 in a single session), and the agent loop hammers the model API until the quota is drained. Root-cause of the 2026-08-18 MiniMax subscription drain (~359M tokens).

**Fix:** Add a new constant `FM_WEDGE_MAX_ESCALATIONS` (default 10). Once escalations reach it, `wedge_timer_check` emits ONE terminal wake with a `PERMANENTLY-WEDGED` marker and writes a durable `STATE/.wedge-permanent-<key>-<hash12>` file (per-hash, not per-window, so a fresh stale hash in the same window can still escalate). Subsequent polls for the SAME stale hash short-circuit (no more wakes). The marker is cleared at the existing reset sites (`handle_paused_stale`, `clear_pause_tracking`) via a glob on `.wedge-permanent-<key>-*`, so a wedge that genuinely resolves can re-escalate later if it wedges again.

**Atomicity invariant (v3 fix):** the marker is written AFTER `fm_wake_append` succeeds but BEFORE `wake` runs. v2 wrote it after `wake`, but `wake()` is sourced from `fm-push-transition-lib` and ends with `exit 0` (this watcher emits one wake per cycle), so the v2 marker write was dead code and the cap never persisted. v1 wrote it before `fm_wake_append`, but a fs failure during wake-append could leave a marker with no wake published, creating a silent wedge. v3 splits the difference: write only after wake-append succeeds (a fs failure here `exit 1`s without setting the marker, so the next poll retries cleanly) and before `wake` runs (so the marker is durable when the script exits).

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
