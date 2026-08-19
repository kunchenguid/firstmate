#!/usr/bin/env bash
# Tests for bin/fm-umbrella-promote.sh: promoting a designed umbrella epic into
# the home (move the epic dir into data/plans/ + seed its stories into the
# backlog), idempotently and fail-closed, then STOP at the sign-off gate.
#
# These drive the real script against throwaway fixture homes and prove the
# guarantees that two home firstmates got wrong by hand: ids + [<epic>] tags are
# derived from the story frontmatter so they match by construction (no orphans),
# a re-run is a clean no-op, a mismatched prior seed is refused rather than
# duplicated, and any validation failure writes nothing at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROMOTE="$ROOT/bin/fm-umbrella-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-umbrella-promote)

run() {  # <home> <args...> -> sets OUT, RC
  local home=$1; shift
  OUT=$(FM_HOME="$home" "$PROMOTE" "$@" 2>&1)
  RC=$?
}

# write_story <dir> <id> <epic> <repo> <pr_base> : a story file with a heading.
write_story() {
  local dir=$1 id=$2 epic=$3 repo=$4 pr_base=$5
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    printf 'epic: %s\n' "$epic"
    printf 'repo: %s\n' "$repo"
    [ -n "$pr_base" ] && printf 'pr_base: %s\n' "$pr_base"
    printf -- '---\n'
    printf '# Story %s heading\n' "$id"
  } > "$dir/$id.md"
}

# make_home <name> : a fixture home with one registered repo `svc`, an empty
# backlog, and an umbrella `u` carrying an epic `things` with stories T-01..T-03.
# Echoes the home path. The caller may mutate the fixture before running.
make_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/config" "$home/umbrellas/u/plans/ep/stories"
  home=$(cd "$home" && pwd -P)
  cat > "$home/data/projects.md" <<'EOF'
# Projects
- svc [direct-PR production=main] - fixture repo (added 260101)
EOF
  printf '## In flight\n\n## Queued\n## Done\n' > "$home/data/backlog.md"
  printf '# DESIGN\n' > "$home/umbrellas/u/DESIGN.md"
  cat > "$home/umbrellas/u/plans/ep/epic.md" <<'EOF'
---
epic: things
title: Things epic
repos: [svc]
---
# Epic things
EOF
  local n
  for n in T-01 T-02 T-03; do
    write_story "$home/umbrellas/u/plans/ep/stories" "$n" things svc main
  done
  printf '%s\n' "$home"
}

# --- happy path: move + seed, ids/tags derived from frontmatter --------------
test_promote_moves_and_seeds() {
  local home; home=$(make_home happy)
  run "$home" u
  expect_code 0 "$RC" "promote failed on a clean fixture"

  assert_present "$home/data/plans/ep/epic.md" "epic dir not moved into data/plans/"
  assert_absent "$home/umbrellas/u/plans/ep" "epic dir left behind in the umbrella"
  assert_grep "ep" "$home/umbrellas/u/.promoted" "promote marker not written"

  # Every story seeded with its REAL id and the epic's tag, matching by construction.
  local n
  for n in T-01 T-02 T-03; do
    assert_grep "- [ ] $n - [things]" "$home/data/backlog.md" "story $n not seeded with matching id+tag"
  done
  assert_contains "$OUT" "stories seeded now: 3" "seed count wrong"
  assert_contains "$OUT" "STOP" "sign-off gate not printed"
  assert_contains "$OUT" "bin/fm-epic-branch.sh create things svc" "branch step missing"
  # Never auto-signs / auto-dispatches.
  assert_not_contains "$OUT" "signed_off: added" "must not claim to have signed"
  pass "promote moves the epic dir and seeds stories with frontmatter-derived id+tag"
}

# --- idempotent re-run: clean no-op ------------------------------------------
test_rerun_is_noop() {
  local home; home=$(make_home rerun)
  run "$home" u
  expect_code 0 "$RC" "first promote failed"
  local before; before=$(cat "$home/data/backlog.md")
  run "$home" u
  expect_code 0 "$RC" "idempotent re-run refused"
  assert_contains "$OUT" "stories seeded now: 0" "re-run seeded again"
  assert_contains "$OUT" "already present: 3" "re-run did not see the stories as present"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "re-run mutated the backlog"
  pass "a re-run after a full promote is a clean no-op"
}

# --- partial resume: some present, add only the rest -------------------------
test_partial_resume() {
  local home; home=$(make_home partial)
  # Simulate a crash after only T-01 was seeded: pre-seed T-01 correctly, and
  # pre-move the epic dir + marker so locate reconciles from data/plans.
  mkdir -p "$home/data/plans"
  mv "$home/umbrellas/u/plans/ep" "$home/data/plans/ep"
  printf 'ep\n' > "$home/umbrellas/u/.promoted"
  # T-01 already correctly seeded before the simulated crash.
  printf '## In flight\n\n## Queued\n- [ ] T-01 - [things] Story T-01 heading (repo: svc) (kind: ship) (since 2026-08-15)\n## Done\n' > "$home/data/backlog.md"

  run "$home" u
  expect_code 0 "$RC" "partial resume failed"
  assert_contains "$OUT" "stories seeded now: 2" "did not add exactly the missing stories"
  assert_contains "$OUT" "already present: 1" "did not skip the present story"
  # T-01 appears exactly once (no duplicate).
  [ "$(grep -c '\- \[ \] T-01 ' "$home/data/backlog.md")" -eq 1 ] || fail "T-01 duplicated"
  pass "a re-run after a partial seed adds only the missing stories"
}

# --- botch detection: a case-mismatched prior seed is refused ----------------
test_refuses_case_mismatch_seed() {
  local home; home=$(make_home botch)
  # A botched hand-seed like aimica's: lowercase ids under a short tag.
  printf '## In flight\n\n## Queued\n- [ ] t-01 - [th] wrong-case seed (repo: svc) (kind: ship) (since 2026-08-10)\n## Done\n' > "$home/data/backlog.md"
  run "$home" u
  expect_code 1 "$RC" "promote should refuse a mismatched prior seed"
  assert_contains "$OUT" "MISMATCHED prior seed" "did not name the mismatch"
  assert_contains "$OUT" "t-01" "did not point at the offending task"
  # Wrote nothing: epic still in the umbrella, no new tasks.
  assert_present "$home/umbrellas/u/plans/ep" "refusal still moved the epic dir"
  assert_absent "$home/data/plans/ep" "refusal wrote into data/plans"
  assert_no_grep "- [ ] T-01" "$home/data/backlog.md" "refusal seeded a second parallel task set"
  pass "a mismatched prior seed is refused, not duplicated, and writes nothing"
}

# --- validation refusals write nothing ---------------------------------------
test_refuses_missing_pr_base() {
  local home; home=$(make_home nopr)
  # Strip pr_base from one story.
  write_story "$home/umbrellas/u/plans/ep/stories" T-02 things svc ""
  run "$home" u
  expect_code 1 "$RC" "missing pr_base should fail"
  assert_contains "$OUT" "no pr_base" "did not name the missing pr_base"
  assert_absent "$home/data/plans/ep" "wrote to data/plans despite a validation failure"
  assert_no_grep "- [ ] T-01" "$home/data/backlog.md" "seeded despite a validation failure"
  pass "a story missing pr_base fails with an actionable message and writes nothing"
}

test_refuses_unregistered_repo() {
  local home; home=$(make_home norepo)
  write_story "$home/umbrellas/u/plans/ep/stories" T-02 things ghost-repo main
  run "$home" u
  expect_code 1 "$RC" "unregistered repo should fail"
  assert_contains "$OUT" "not registered" "did not name the registration gap"
  assert_contains "$OUT" "ghost-repo" "did not name the unregistered repo"
  assert_absent "$home/data/plans/ep" "wrote to data/plans despite an unregistered repo"
  pass "an unregistered epic repo fails with an actionable message and writes nothing"
}

# --- manual backend seeds directly into the backlog file ---------------------
test_manual_backend() {
  local home; home=$(make_home manual)
  printf 'manual\n' > "$home/config/backlog-backend"
  run "$home" u
  expect_code 0 "$RC" "manual-backend promote failed"
  assert_contains "$OUT" "backlog backend: manual" "did not report the manual backend"
  assert_grep "- [ ] T-01 - [things]" "$home/data/backlog.md" "manual seed did not render the line"
  # Idempotent under manual too.
  run "$home" u
  assert_contains "$OUT" "stories seeded now: 0" "manual re-run seeded again"
  [ "$(grep -c '\- \[ \] T-01 ' "$home/data/backlog.md")" -eq 1 ] || fail "manual re-run duplicated T-01"
  pass "the manual backlog backend seeds and stays idempotent"
}

# --- fail-closed locate errors -----------------------------------------------
test_locate_errors() {
  local home; home=$(make_home locate)
  run "$home" nonexistent
  expect_code 1 "$RC" "unknown umbrella should fail"
  assert_contains "$OUT" "unknown umbrella" "wrong error for unknown umbrella"

  run "$home" ../etc
  expect_code 1 "$RC" "path-traversal id should fail"
  assert_contains "$OUT" "invalid umbrella id" "wrong error for unsafe id"

  # A second epic dir under plans/ is ambiguous.
  mkdir -p "$home/umbrellas/u/plans/ep2/stories"
  cp "$home/umbrellas/u/plans/ep/epic.md" "$home/umbrellas/u/plans/ep2/epic.md"
  run "$home" u
  expect_code 1 "$RC" "ambiguous multi-epic should fail"
  assert_contains "$OUT" "ambiguous" "did not report the ambiguity"
  pass "unknown id, unsafe id, and ambiguous multi-epic all fail closed"
}

test_promote_moves_and_seeds
test_rerun_is_noop
test_partial_resume
test_refuses_case_mismatch_seed
test_refuses_missing_pr_base
test_refuses_unregistered_repo
test_manual_backend
test_locate_errors

echo "# all fm-umbrella-promote tests passed"
