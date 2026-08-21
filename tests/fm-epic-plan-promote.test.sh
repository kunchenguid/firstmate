#!/usr/bin/env bash
# Tests for bin/fm-epic-plan-promote.sh: promoting a worker's committed task-time
# plan over the epic's canonical stories/<id>-plan/ draft (epwf-02 #4), so a
# downstream story reads the fresh HEAD-bound plan instead of the design-time one.
#
# The worked example the story asks for is test_promote_from_clone_downstream_reads:
# a fixture epic with a STALE upfront draft for svc-01, a worker's REFRESHED plan
# in the clone, and a downstream svc-02 that depends on svc-01. After promotion the
# canonical dir holds the refreshed plan (the stale draft is gone) and the epic
# still lints green - i.e. downstream dispatch reads the promoted plan.
#
# The rest pin the contract: --from for a pre-merge worktree source, replace (not
# merge) semantics, idempotency, and the guardrails (unknown epic, story not in the
# epic, missing/planless source, self-promotion, and the post-promote lint gate).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-epic-plan-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-epic-plan-promote)

# fresh <name> : build a fresh home with a signed, valid `demo` epic (repo svc):
#   - svc-01 (the gate) with a STALE upfront plan draft + a resolving pointer,
#   - svc-02 depending on svc-01 (the downstream reader),
#   - a clone at projects/svc holding svc-01's REFRESHED task-time plan.
# Echoes the home dir so a caller can mutate one thing before promoting.
fresh() {
  local home="$TMP_ROOT/$1"
  local epic="$home/data/plans/260101-epic-demo"
  mkdir -p "$epic/stories" "$home/projects/svc/plans/svc-01-plan"

  cat > "$home/data/projects.md" <<'EOF'
# Projects
- svc [direct-PR production=main] - fixture repo (added 260101)
EOF
  cat > "$epic/epic.md" <<'EOF'
---
epic: demo
title: Demo epic
repos: [svc]
signed_off: 2026-01-02
status: active
---
# Epic demo
EOF
  # svc-01 gate story + its STALE design-time plan draft.
  mkdir -p "$epic/stories/svc-01-plan"
  cat > "$epic/stories/svc-01.md" <<'EOF'
---
id: svc-01
epic: demo
repo: svc
pr_base: main
depends: []
kind: ship
gate: true
---
# Story svc-01

## Implementation plan
_Pointer: `stories/svc-01-plan/`._
EOF
  printf 'STALE design-time draft anchored to an old HEAD\n' > "$epic/stories/svc-01-plan/plan.md"
  printf 'stale phase that no longer applies\n' > "$epic/stories/svc-01-plan/phase-old.md"

  # svc-02 downstream reader.
  cat > "$epic/stories/svc-02.md" <<'EOF'
---
id: svc-02
epic: demo
repo: svc
pr_base: epic/demo
depends: [svc-01]
kind: ship
gate: false
---
# Story svc-02
EOF

  # The worker's committed, plan-review-approved REFRESHED plan, in the clone.
  cat > "$home/projects/svc/plans/svc-01-plan/plan.md" <<'EOF'
# svc-01 REFRESHED task-time plan
Re-bound to current HEAD; anchors re-verified.
EOF
  printf 'fresh phase\n' > "$home/projects/svc/plans/svc-01-plan/phase-01.md"

  printf '%s\n' "$home"
}

promote() {  # <home> <args...> -> OUT, RC
  local home=$1; shift
  OUT=$(FM_HOME="$home" "$PROMOTE" "$@" 2>&1); RC=$?
}

canon_plan() { echo "$1/data/plans/260101-epic-demo/stories/svc-01-plan"; }

# --- worked example: promote from the clone, downstream reads the fresh plan ----
test_promote_from_clone_downstream_reads() {
  local home; home=$(fresh clone)
  promote "$home" demo svc-01
  expect_code 0 "$RC" "promote should succeed: $OUT"
  assert_contains "$OUT" "epic lint OK" "promote must re-lint the epic green"

  local plan; plan=$(canon_plan "$home")
  assert_contains "$(cat "$plan/plan.md")" "REFRESHED task-time plan" "canonical plan.md was not replaced by the refreshed plan"
  assert_absent "$plan/phase-old.md" "the stale draft's phase file must be gone (replace, not merge)"
  assert_present "$plan/phase-01.md" "the refreshed phase file must be present after promote"

  # Downstream dispatch reads the canonical epic: it must still lint green, i.e.
  # svc-02 (depends on svc-01) consumes a well-formed promoted plan.
  local lint; lint=$(FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-epic-lint.sh" "$home/data/plans/260101-epic-demo" 2>&1)
  expect_code 0 "$?" "the epic must lint green after promotion so downstream stories dispatch: $lint"
  pass "a task-time plan promotes over the canonical draft and the downstream epic stays green"
}

# --- --from: promote a worktree plan that has not landed in the clone yet -------
test_promote_from_explicit_source() {
  local home; home=$(fresh fromsrc)
  local wt="$TMP_ROOT/worktree-plan"
  mkdir -p "$wt"
  printf '# svc-01 plan straight from the worker worktree\n' > "$wt/plan.md"
  promote "$home" demo svc-01 --from "$wt"
  expect_code 0 "$RC" "--from promote should succeed: $OUT"
  assert_contains "$(cat "$(canon_plan "$home")/plan.md")" "from the worker worktree" "--from source was not promoted into canonical"
  pass "--from promotes a pre-merge worktree plan into canonical"
}

# --- idempotent: a second run with the same source is a no-op-equivalent --------
test_idempotent_rerun() {
  local home; home=$(fresh idem)
  promote "$home" demo svc-01
  expect_code 0 "$RC" "first promote should succeed: $OUT"
  promote "$home" demo svc-01
  expect_code 0 "$RC" "second promote should also succeed: $OUT"
  assert_contains "$(cat "$(canon_plan "$home")/plan.md")" "REFRESHED task-time plan" "re-run must leave the promoted plan in place"
  pass "re-running the promote with the same source is idempotent"
}

# --- guardrails ----------------------------------------------------------------
test_unknown_epic() {
  local home; home=$(fresh noepic)
  promote "$home" nope svc-01
  expect_code 1 "$RC" "an unknown epic slug must fail"
  assert_contains "$OUT" "no epic with slug" "did not report the missing epic"
  pass "an unknown epic slug is an error"
}

test_story_not_in_epic() {
  local home; home=$(fresh nostory)
  promote "$home" demo svc-99
  expect_code 1 "$RC" "a story not in the epic must fail"
  assert_contains "$OUT" "is not in epic" "did not report the missing story"
  pass "a story id not in the epic is an error"
}

test_missing_source() {
  local home; home=$(fresh nosrc)
  rm -rf "$home/projects/svc/plans/svc-01-plan"
  promote "$home" demo svc-01
  expect_code 1 "$RC" "a missing source plan dir must fail"
  assert_contains "$OUT" "source plan dir does not exist" "did not report the missing source"
  pass "a missing default source plan dir is an error"
}

test_source_without_plan_md() {
  local home; home=$(fresh noplanmd)
  rm -f "$home/projects/svc/plans/svc-01-plan/plan.md"
  promote "$home" demo svc-01
  expect_code 1 "$RC" "a source without plan.md must fail"
  assert_contains "$OUT" "no plan.md" "did not reject the planless source"
  pass "a source dir with no plan.md is rejected (not a real plan directory)"
}

test_refuse_self_promotion() {
  local home; home=$(fresh selfpromo)
  # Point --from at the canonical dir itself: nothing to promote, and a blind
  # stage-then-swap would delete it. The script must refuse before touching it.
  promote "$home" demo svc-01 --from "$(canon_plan "$home")"
  expect_code 1 "$RC" "self-promotion must be refused"
  assert_contains "$OUT" "already the canonical plan dir" "did not refuse the self-promotion"
  assert_present "$(canon_plan "$home")/plan.md" "the canonical plan must survive a refused self-promotion"
  pass "promoting the canonical dir onto itself is refused without destroying it"
}

test_post_promote_lint_gate() {
  local home; home=$(fresh lintgate)
  # Break an unrelated story so the post-promote re-lint is RED. The promote must
  # fail loudly rather than silently shipping a broken epic.
  perl -i -pe 's/^kind: ship$/kind: frobnicate/' "$home/data/plans/260101-epic-demo/stories/svc-02.md"
  promote "$home" demo svc-01
  expect_code 1 "$RC" "a red post-promote lint must fail the promote"
  assert_contains "$OUT" "leaves the epic lint RED" "did not surface the lint gate failure"
  pass "a promotion that leaves the epic lint RED fails loudly"
}

test_promote_from_clone_downstream_reads
test_promote_from_explicit_source
test_idempotent_rerun
test_unknown_epic
test_story_not_in_epic
test_missing_source
test_source_without_plan_md
test_refuse_self_promotion
test_post_promote_lint_gate

echo "# all fm-epic-plan-promote tests passed"
