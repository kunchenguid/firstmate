#!/usr/bin/env bash
# tests/fm-epic-status.test.sh - fm-epic-status.sh + fm-epic-dispatch-plan.sh.
#
# Exercises both real scripts against a real fixture home (data/plans epic dir +
# stories, a backlog, a projects registry, a secondmates registry) so the model -
# signed detection, per-story dispatchable/blocked/done/unseeded, story-base-driven
# epic-branch check with drift, delivery-mode resolution, dispatch-owner surfacing,
# and PRINT-ONLY dispatch - is proven end to end, not asserted against source bytes.
# The only network dependency (bin/fm-epic-branch.sh verify) is replaced through the
# FM_EPIC_BRANCH_BIN seam by a fake that also LOGS every call, so the test both
# controls branch presence and proves the dispatch plan never runs `create`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATUS="$ROOT/bin/fm-epic-status.sh"
PLAN="$ROOT/bin/fm-epic-dispatch-plan.sh"
TMP_ROOT=$(fm_test_tmproot fm-epic-status)

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/plans/epic-demo/stories"

# --- fixture: registry, backlog, epic + stories -----------------------------
cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects
- alpha [local-only production=main] - fixture (added 260101)
- beta [no-mistakes-prod-only production=main] - fixture (added 260101)
EOF

# A secondmate whose clone list mentions beta, so the dispatch-owner surfaces it
# as a candidate to confirm by scope (never a hard route).
cat > "$HOME_DIR/data/secondmates.md" <<'EOF'
- betamate - handles beta insurance work (home: /tmp/betamate; scope: insurance partner work on beta; projects: beta; added 2026-01-01)
EOF

cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] demo-02 - [demo] second (repo: alpha) (kind: ship) (since 260101)
- [ ] demo-03 - [demo] third (repo: alpha) (kind: ship) (since 260101)
- [ ] demo-04 - [demo] fourth (repo: beta) (kind: ship) (since 260101)
- [ ] demo-05 - [demo] fifth (repo: alpha) (kind: ship) (since 260101)
- [ ] demo-07 - [demo] scout (repo: alpha) (kind: scout) (since 260101)
- [ ] demo-fu-open - [demo] mid-epic follow-up (repo: alpha) (kind: ship) (since 260110)
- [ ] demo-hold-1 - decision hold parent: demo (repo: alpha) (kind: captain) (since 260110)
- [ ] unrelated-1 - [other] not this epic (repo: alpha) (kind: ship) (since 260110)
- [ ] demo-edge-decoy - decoy parent: demo-01 (repo: alpha) (kind: ship) (since 260110)

## Done
- [x] demo-01 - [demo] first https://example.invalid/pr/1 (repo: alpha) (kind: ship) (merged 260102)
- [x] demo-fu-done - [demo] earlier follow-up https://example.invalid/pr/9 (repo: alpha) (kind: ship) (merged 260111)
EOF

cat > "$HOME_DIR/data/plans/epic-demo/epic.md" <<'EOF'
---
epic: demo
title: Demo epic
repos: [alpha, beta]
status: active
signed_off: 2026-01-02   # signed
---
# Demo epic
EOF

# demo-01: done. demo-02: dep demo-01 (done) -> dispatchable. demo-03: dep demo-02
# (queued) -> blocked. demo-04: delivery key + dep demo-02 done? no, dep demo-01 ->
# dispatchable, its own `delivery: direct-PR` key must win over beta's prod-only
# registry posture. demo-05: base epic/other -> DRIFT + a distinct branch to cut.
# demo-06: a story with NO backlog entry -> unseeded.
story() { # <file> <id> <repo> <pr_base> <depends> <delivery>
  cat > "$HOME_DIR/data/plans/epic-demo/stories/$1" <<EOF
---
id: $2
epic: demo
repo: $3
pr_base: $4
depends: [$5]
kind: ship
${6:+delivery: $6}
---
# $2 heading
EOF
}
story 01.md demo-01 alpha epic/demo ""        ""
story 02.md demo-02 alpha epic/demo demo-01   ""
story 03.md demo-03 alpha epic/demo demo-02   ""
story 04.md demo-04 beta  main      demo-01   direct-PR
story 05.md demo-05 alpha epic/other demo-01  ""
story 06.md demo-06 alpha main ""             ""
# A dispatchable SCOUT story (dep merged): dispatches with --scout, no mode/base.
cat > "$HOME_DIR/data/plans/epic-demo/stories/07.md" <<'EOF'
---
id: demo-07
epic: demo
repo: alpha
pr_base: epic/demo
depends: [demo-01]
kind: scout
---
# demo-07 heading
EOF

# --- fake epic-branch verifier: controls presence + logs every call ----------
# epic/demo present in alpha, MISSING in beta; epic/other MISSING in alpha.
CALLLOG="$TMP_ROOT/branch-calls.log"
: > "$CALLLOG"
FAKE_BRANCH="$TMP_ROOT/fake-epic-branch.sh"
cat > "$FAKE_BRANCH" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLLOG"
[ "\$1" = verify ] || { echo "fake was asked to run non-verify: \$*" >&2; exit 3; }
case "\$2/\$3" in
  demo/alpha) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BRANCH"

run_status() { FM_HOME="$HOME_DIR" FM_EPIC_BRANCH_BIN="$FAKE_BRANCH" "$STATUS" "$@"; }
run_plan()   { FM_HOME="$HOME_DIR" FM_EPIC_BRANCH_BIN="$FAKE_BRANCH" "$PLAN" "$@"; }

# ============================================================================
# fm-epic-status
# ============================================================================
OUT=$(run_status demo) || fail "fm-epic-status demo exited non-zero"

assert_contains "$OUT" "signed: yes" "signed epic (signed_off + active) reports signed: yes"
assert_contains "$OUT" "demo-01  DONE" "a merged story shows DONE"
assert_contains "$OUT" "demo-02  DISPATCHABLE" "a story whose only dep is merged is dispatchable"
assert_contains "$OUT" "demo-03  blocked-by: demo-02" "a story with an unmerged dep is blocked-by it"
assert_contains "$OUT" "demo-06  UNSEEDED" "a story with no backlog entry is unseeded"

# --- gap mode B (report dcen-04): off-plan tasks surface by MEMBERSHIP ---------
# A backlog task that belongs to the epic by an [demo] tag or a parent:demo edge
# but has no story file used to be invisible; it now rolls up under the epic.
assert_contains "$OUT" "off-plan tasks (epic membership on the task, no story file):" \
  "off-plan section header not printed"
assert_contains "$OUT" "demo-fu-open  open" "an epic-TAGGED backlog task with no story file must surface"
assert_contains "$OUT" "demo-hold-1  open" "a task carrying a parent:<slug> EDGE (no tag) must surface"
assert_contains "$OUT" "demo-fu-done  DONE" "a merged off-plan epic task must surface as DONE"
# Boundary: a non-member task and a parent edge to a DIFFERENT id must NOT surface.
assert_not_contains "$OUT" "unrelated-1" "a task tagged for another epic must not surface"
assert_not_contains "$OUT" "demo-edge-decoy" "a parent: edge to a different id (demo-01) must not match slug demo"
# An on-plan story is shown once (in stories), never double-listed as off-plan.
assert_not_contains "$OUT" "demo-02  open" "an on-plan story must not be double-listed as off-plan"
pass "gap mode B: epic-tagged/parent-edged off-plan tasks surface; non-members and on-plan stories do not"

assert_contains "$OUT" "epic/demo in alpha" "the epic branch check keys off the story pr_base"
assert_contains "$OUT" "epic/other in alpha  - MISSING" "a missing story-base branch is flagged"
assert_contains "$OUT" 'DRIFT: story base branch(es) differ from the epic slug "demo": other' \
  "a story base branch that differs from the epic slug is surfaced as DRIFT"
pass "status: signed, per-story states, story-base branch check, and DRIFT are correct"

# The epic slug branch itself (epic/demo in beta) is NOT invented: beta has no
# story basing on epic/demo, so it must not appear as a required branch.
assert_not_contains "$OUT" "epic/demo in beta" "a branch no story bases on is never invented"
pass "status: only branches a story actually bases on are checked"

# ============================================================================
# fm-epic-dispatch-plan
# ============================================================================
POUT=$(run_plan demo) || fail "fm-epic-dispatch-plan demo exited non-zero"

assert_contains "$POUT" "PRINTS ONLY" "the plan announces it prints only"
assert_contains "$POUT" "bin/fm-epic-branch.sh create other alpha" "plan emits create for the missing story-base branch, named as the story declares it"
assert_not_contains "$POUT" "create demo alpha" "plan does not re-cut an already-present branch"

# demo-02 is dispatchable on alpha (local-only registry posture, no delivery key).
assert_contains "$POUT" "bin/fm-brief.sh demo-02 alpha --mode local-only --base epic/demo" "dispatchable story uses the registered mode and its pr_base"
assert_contains "$POUT" "bin/fm-spawn.sh demo-02 alpha --mode local-only --yolo off --base epic/demo" "spawn line carries mode, yolo, and base"

# demo-04 carries `delivery: direct-PR`, which must WIN over beta's prod-only posture.
assert_contains "$POUT" "bin/fm-spawn.sh demo-04 beta --mode direct-PR --yolo" "a story delivery: key overrides the registered posture"

# A prod-only story WITHOUT a delivery key would need firstmate classification;
# demo-04 has the key so it must NOT show the prod-only prompt.
assert_not_contains "$POUT" "NEEDS firstmate surface classification" "a delivery: key settles the mode, no classification prompt"

# demo-07 is a dispatchable scout: it dispatches with --scout, never with --mode/--base.
assert_contains "$POUT" "bin/fm-brief.sh demo-07 alpha --scout" "a scout story dispatches with --scout"
assert_contains "$POUT" "bin/fm-spawn.sh demo-07 alpha --scout" "a scout story spawn uses --scout"
assert_not_contains "$POUT" "demo-07 alpha --mode" "a scout story never carries a delivery --mode"

# blocked / done / unseeded stories are never dispatched.
assert_not_contains "$POUT" "fm-spawn.sh demo-03" "a blocked story is not dispatched"
assert_not_contains "$POUT" "fm-spawn.sh demo-01" "a done story is not dispatched"
assert_not_contains "$POUT" "fm-spawn.sh demo-06" "an unseeded story is not dispatched"
pass "plan: cut set + dispatchable set + mode resolution + delivery-key override are correct"

# PRINT-ONLY proof: across both commands the branch tool was called ONLY with
# verify, never create - the plan mutates nothing.
if grep -qv '^verify ' "$CALLLOG"; then
  fail "the branch tool was invoked with a non-verify (mutating) command: $(grep -v '^verify ' "$CALLLOG")"
fi
pass "plan is print-only: the epic-branch tool was only ever asked to verify, never create"

# ============================================================================
# dispatch owner
# ============================================================================
# With the secondmate registry present and cloning beta, the owner line surfaces
# it as a candidate (to confirm by scope), defaulting to this home.
assert_contains "$OUT" "dispatch owner: this home" "dispatch owner defaults to this home"
assert_contains "$OUT" 'candidate secondmate "betamate"' "a secondmate cloning an involved repo is surfaced as a candidate"
pass "dispatch owner: defaults to this home and surfaces a candidate secondmate by clone"

# With NO secondmate registry, the owner is flatly this home (no candidates).
rm -f "$HOME_DIR/data/secondmates.md"
OUT2=$(run_status demo) || fail "status re-run without secondmates failed"
assert_contains "$OUT2" "dispatch owner: this home" "no registry -> this home"
assert_not_contains "$OUT2" "candidate secondmate" "no registry -> no candidates"
pass "dispatch owner: absent registry means this home, full stop"

# ============================================================================
# unsigned epic warning + unknown slug
# ============================================================================
# Rebuild an unsigned epic.md (no signed_off, status pending).
cat > "$HOME_DIR/data/plans/epic-demo/epic.md" <<'EOF'
---
epic: demo
title: Demo epic
repos: [alpha, beta]
status: pending
---
# Demo epic
EOF
OUT3=$(run_status demo) || fail "status on an unsigned epic failed"
assert_contains "$OUT3" "signed: NO" "an epic without signed_off reports signed: NO"
POUT3=$(run_plan demo) || fail "plan on an unsigned epic failed"
assert_contains "$POUT3" "WARNING: epic is not signed" "the plan warns loudly when the epic is not signed"
pass "unsigned epic: status says NO and the plan warns before any dispatch line"

run_status no-such-epic 2>/dev/null && fail "status accepted an unknown slug"
run_plan no-such-epic 2>/dev/null && fail "plan accepted an unknown slug"
pass "an unknown epic slug is a clean failure in both commands"
