#!/usr/bin/env bash
# fm-afk-artifacts-lib.sh - the ONE owner of the away-mode delivery-artifact set.
#
# These files are session-scoped DELIVERY state, not the durable work record:
# the escalation buffer, its first-arrival sidecar, the wedge marker, and the
# delivery-block record. The durable record is state/.wake-queue, which replays
# independently, so clearing these on a fresh away-mode entry loses nothing.
#
# WHY THIS EXISTS: the set was spelled out literally in five places across
# bin/fm-afk-start.sh, bin/fm-afk-launch.sh (clear, back up, restore), and
# bin/fm-afk-return.sh. Adding a fifth artifact meant editing five lists, and a
# list that must be edited in five places is a list that will be edited in four.
# A delivery artifact that a launcher forgets to carry across a backup/restore
# leaks stale state into the next away-mode session, which is exactly how a
# wedge marker or a block record can appear to describe a stall that already
# ended. Callers iterate FM_AFK_DELIVERY_ARTIFACTS or use the helpers below.
#
# No side effects on source. set -u / set -e safe.

# The delivery artifacts, relative to a state directory. Order is not
# significant; every consumer treats the set as a whole.
FM_AFK_DELIVERY_ARTIFACTS='.subsuper-escalations
.subsuper-escalations.since
.subsuper-inject-wedged
.subsuper-delivery-blocked'

# fm_afk_artifacts_clear: drop every delivery artifact under <state-dir>.
# Best-effort by contract: a missing artifact is the normal case, so absence is
# never an error. Returns non-zero only when a present artifact could not be
# removed, which a caller doing transactional restore must notice.
fm_afk_artifacts_clear() {  # <state-dir>
  local state=$1 artifact result=0
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    rm -f "$state/$artifact" 2>/dev/null || result=1
  done <<EOF
$FM_AFK_DELIVERY_ARTIFACTS
EOF
  return "$result"
}

# fm_afk_artifacts_copy: copy every PRESENT delivery artifact from <src-dir> to
# <dst-dir>, preserving mtimes. Mtime preservation is load-bearing: the wedge
# alarm's once-per-window throttle is derived from the marker's age, so a copy
# that reset it would let a restored session re-alarm immediately.
# Returns non-zero if any present artifact could not be copied.
fm_afk_artifacts_copy() {  # <src-dir> <dst-dir>
  local src=$1 dst=$2 artifact result=0
  while IFS= read -r artifact; do
    [ -n "$artifact" ] || continue
    [ -e "$src/$artifact" ] || continue
    cp -p "$src/$artifact" "$dst/$artifact" 2>/dev/null || result=1
  done <<EOF
$FM_AFK_DELIVERY_ARTIFACTS
EOF
  return "$result"
}
