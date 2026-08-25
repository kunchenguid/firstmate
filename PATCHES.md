# Local Patches

This file tracks local modifications applied to the upstream Firstmate codebase.
Each patch has a unique ID, a clear revert procedure, and a status.

---

## patch-wedge-cap-2026-08-19

**Status:** applied on branch `patch/wedge-cap-2026-08-19` (off main). v2 (2026-08-25) addresses Greptile review: per-hash marker keying + atomic marker write after wake.

**Problem:** `FM_WEDGE_DEMAND_INSPECT_COUNT` (default 3) adds a `demand-deep-inspection` marker to wedge-escalation wakes once a pane has re-wedged on the same stale hash. The design assumes a human or smart supervisor will act on the marker and break the loop. In LLM-supervised unattended setups (herdr + pi agent), the marker is read but never acted on: pi responds to every wake, the wedge never resolves, escalations keep incrementing (observed: 70, 112, 129 in a single session), and the agent loop hammers the model API until the quota is drained. Root-cause of the 2026-08-18 MiniMax subscription drain (~359M tokens).

**Fix:** Add a new constant `FM_WEDGE_MAX_ESCALATIONS` (default 10). Once escalations reach it, `wedge_timer_check` emits ONE terminal wake with a `PERMANENTLY-WEDGED` marker and writes a durable `STATE/.wedge-permanent-<key>-<hash12>` file (per-hash, not per-window, so a fresh stale hash in the same window can still escalate). Subsequent polls for the SAME stale hash short-circuit (no more wakes). The marker is cleared at the existing reset sites (`handle_paused_stale`, `clear_pause_tracking`) via a glob on `.wedge-permanent-<key>-*`, so a wedge that genuinely resolves can re-escalate later if it wedges again.

**Atomicity invariant (v2 fix):** the marker is written AFTER `wake` succeeds. Writing the marker before wake-publish would let a crash or `wake` failure between the two leave the pane permanently silent (marker on disk, wake never delivered). Writing last means a mid-flow crash leaves no marker, and the next poll re-enters the cap-reached branch and retries.

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
