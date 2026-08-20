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

# write_story <dir> <id> <epic> <repo> <pr_base> [gate] [depends] : a story file
# with the full seven-key contract frontmatter and a heading. gate defaults to
# false and depends to []. An empty <pr_base> omits the key (to test the refusal).
# ids are lower-kebab and match the filename so the story passes fm-epic-lint.sh.
write_story() {
  local dir=$1 id=$2 epic=$3 repo=$4 pr_base=$5 gate=${6:-false} depends=${7:-'[]'}
  {
    printf -- '---\n'
    printf 'id: %s\n' "$id"
    printf 'epic: %s\n' "$epic"
    printf 'repo: %s\n' "$repo"
    [ -n "$pr_base" ] && printf 'pr_base: %s\n' "$pr_base"
    printf 'depends: %s\n' "$depends"
    printf 'kind: ship\n'
    printf 'gate: %s\n' "$gate"
    printf -- '---\n'
    printf '# Story %s heading\n' "$id"
  } > "$dir/$id.md"
}

# make_home <name> : a fixture home with one registered repo `svc`, an empty
# backlog, and an umbrella `u` carrying an epic `things` with stories
# svc-01..svc-03 (svc-01 is the one gate story). Echoes the home path. The caller
# may mutate the fixture before running.
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
  local sdir="$home/umbrellas/u/plans/ep/stories"
  write_story "$sdir" svc-01 things svc main true
  write_story "$sdir" svc-02 things svc main false
  write_story "$sdir" svc-03 things svc main false
  # By default the fixture epic is a FROZEN, SIGNED design so the freshness guards
  # pass; guard tests re-sign it to a draft / stale state to drive the refusals.
  sign_home "$home"
  printf '%s\n' "$home"
}

# sign_home <home> [status] [signed_off]: make the fixture epic a FROZEN, SIGNED
# design so the freshness guards (design-freeze + stale-sign) pass. Defaults to
# status: active and signed_off: today (UTC), which matches the just-created
# files' own mtime day, so the happy path is deterministic regardless of the wall
# clock. make_home leaves the epic UNSIGNED so the guard tests can drive it.
sign_home() {
  local home=$1 status=${2:-active} signed=${3:-} epic="$1/umbrellas/u/plans/ep/epic.md"
  [ -n "$signed" ] || signed=$(date -u +%Y-%m-%d)
  # Insert (or replace) status + signed_off just under the `epic:` line.
  awk -v st="$status" -v so="$signed" '
    /^status:/ { next }
    /^signed_off:/ { next }
    { print }
    /^epic:/ { print "status: " st; print "signed_off: " so }
  ' "$epic" > "$epic.tmp" && mv "$epic.tmp" "$epic"
}

# --- happy path: move + seed, ids/tags derived from frontmatter --------------
test_promote_moves_and_seeds() {
  local home; home=$(make_home happy)
  run "$home" u
  expect_code 0 "$RC" "promote failed on a clean fixture"

  assert_present "$home/data/plans/ep/epic.md" "epic dir not moved into data/plans/"
  [ -L "$home/umbrellas/u/plans/ep" ] || fail "umbrella epic copy is not a back-symlink"
  assert_grep "ep" "$home/umbrellas/u/.promoted" "promote marker not written"

  # Every story seeded with its REAL id and the epic's tag, matching by construction.
  local n
  for n in svc-01 svc-02 svc-03; do
    assert_grep "- [ ] $n - [things]" "$home/data/backlog.md" "story $n not seeded with matching id+tag"
  done
  assert_contains "$OUT" "seeded: 3" "seed count wrong"
  assert_contains "$OUT" "STOP" "sign-off gate not printed"
  assert_contains "$OUT" "bin/fm-epic-branch.sh create things svc" "branch step missing"
  # Never auto-signs / auto-dispatches.
  assert_not_contains "$OUT" "signed_off: added" "must not claim to have signed"
  pass "promote moves the epic dir and seeds stories with frontmatter-derived id+tag"
}

# --- back-symlink: canonical epic in the home, symlink in the umbrella --------
# The umbrella must keep a back-symlink to the canonical epic so design continues
# in the lab, with ONE source of truth and no scanner double-count.
test_backsymlink_canonical_and_single_count() {
  local home; home=$(make_home backlink)
  run "$home" u
  expect_code 0 "$RC" "promote failed"

  local canon="$home/data/plans/ep" link="$home/umbrellas/u/plans/ep"

  # (1) canonical epic is a REAL directory in the home.
  { [ -d "$canon" ] && [ ! -L "$canon" ]; } || fail "data/plans/ep is not a real directory"

  # (2) the umbrella copy is a symlink resolving to the canonical dir.
  [ -L "$link" ] || fail "umbrella epic copy is not a symlink"
  [ "$(cd "$link" && pwd -P)" = "$(cd "$canon" && pwd -P)" ] \
    || fail "umbrella symlink does not resolve to data/plans/ep"

  # (3) editing THROUGH the symlink writes to the real file.
  printf 'edited via umbrella\n' >> "$link/epic.md"
  assert_grep "edited via umbrella" "$canon/epic.md" "edit through the symlink did not reach the canonical file"

  # (4) no double-count: even a scan that FOLLOWS the symlink resolves every
  #     epic.md to ONE canonical path (dedupe by realpath).
  local uniq
  uniq=$(find -L "$home" -name epic.md -type f 2>/dev/null \
    | while read -r f; do (cd "$(dirname "$f")" && pwd -P); done | sort -u | wc -l | tr -d ' ')
  [ "$uniq" = "1" ] || fail "epic counted $uniq times (double-count via the umbrella symlink)"

  # (5) re-run is idempotent: no error, symlink intact and still on target.
  run "$home" u
  expect_code 0 "$RC" "idempotent re-run refused"
  [ -L "$link" ] || fail "re-run destroyed the back-symlink"
  [ "$(cd "$link" && pwd -P)" = "$(cd "$canon" && pwd -P)" ] || fail "re-run broke the symlink target"
  pass "epic is canonical in the home, back-symlinked in the umbrella, editable through it, and counted once"
}

# --- heal: an older plain-mv promote (no back-symlink) is repaired on re-run --
test_rerun_heals_missing_backsymlink() {
  local home; home=$(make_home heal)
  # Simulate a promote done by the OLD script: epic moved, marker written, but
  # NO back-symlink left in the umbrella.
  mkdir -p "$home/data/plans"
  mv "$home/umbrellas/u/plans/ep" "$home/data/plans/ep"
  printf 'ep\n' > "$home/umbrellas/u/.promoted"
  [ -e "$home/umbrellas/u/plans/ep" ] && fail "fixture already has a back-symlink"

  run "$home" u
  expect_code 0 "$RC" "reconcile re-run failed"
  [ -L "$home/umbrellas/u/plans/ep" ] || fail "re-run did not heal the missing back-symlink"
  [ "$(cd "$home/umbrellas/u/plans/ep" && pwd -P)" = "$(cd "$home/data/plans/ep" && pwd -P)" ] \
    || fail "healed symlink points at the wrong target"
  pass "a re-run heals an older plain-mv promote by creating the back-symlink"
}

# --- idempotent re-run: clean no-op ------------------------------------------
test_rerun_is_noop() {
  local home; home=$(make_home rerun)
  run "$home" u
  expect_code 0 "$RC" "first promote failed"
  local before; before=$(cat "$home/data/backlog.md")
  run "$home" u
  expect_code 0 "$RC" "idempotent re-run refused"
  assert_contains "$OUT" "seeded: 0" "re-run seeded again"
  assert_contains "$OUT" "already correct: 3" "re-run did not see the stories as already correct"
  assert_contains "$OUT" "reconciled: 0" "re-run reconciled a correct backlog"
  [ "$(cat "$home/data/backlog.md")" = "$before" ] || fail "re-run mutated the backlog"
  pass "a re-run after a full promote is a clean no-op"
}

# --- partial resume: some present, add only the rest -------------------------
test_partial_resume() {
  local home; home=$(make_home partial)
  # Simulate a crash after only svc-01 was seeded: pre-seed svc-01 correctly, and
  # pre-move the epic dir + marker so locate reconciles from data/plans.
  mkdir -p "$home/data/plans"
  mv "$home/umbrellas/u/plans/ep" "$home/data/plans/ep"
  printf 'ep\n' > "$home/umbrellas/u/.promoted"
  # svc-01 already correctly seeded before the simulated crash.
  printf '## In flight\n\n## Queued\n- [ ] svc-01 - [things] Story svc-01 heading (repo: svc) (kind: ship) (since 2026-08-15)\n## Done\n' > "$home/data/backlog.md"

  run "$home" u
  expect_code 0 "$RC" "partial resume failed"
  assert_contains "$OUT" "seeded: 2" "did not add exactly the missing stories"
  assert_contains "$OUT" "already correct: 1" "did not skip the present story"
  # svc-01 appears exactly once (no duplicate).
  [ "$(grep -c '\- \[ \] svc-01 ' "$home/data/backlog.md")" -eq 1 ] || fail "svc-01 duplicated"
  pass "a re-run after a partial seed adds only the missing stories"
}

# --- R2 fix: a case/kebab-renamed story id is RECONCILED, not orphaned -------
# The aimica failure: a story file renamed LH-01 -> lh-01 (here SVC-01 -> svc-01)
# left a stale lowercase backlog line under a mismatched tag forever. Re-running
# promote must now converge that line to the canonical id/title/tag in place.
test_reconciles_case_variant_seed() {
  local home; home=$(make_home casevariant)
  # A pre-seed of story svc-01 under a wrong-case id and short tag (the aimica
  # LH-01 -> lh-01 failure), carrying a hand-added note line that MUST survive.
  printf '## In flight\n\n## Queued\n- [ ] SVC-01 - [th] wrong-case seed (repo: old) (kind: docs) (since 2026-08-10)\n  hand note: keep me\n## Done\n' > "$home/data/backlog.md"
  run "$home" u
  expect_code 0 "$RC" "promote should reconcile a case-variant seed, not refuse"
  assert_contains "$OUT" "renamed backlog id SVC-01 -> svc-01" "did not report the id rewrite"
  # Canonical line now present with the real id, tag, title, repo, kind...
  assert_grep "- [ ] svc-01 - [things] Story svc-01 heading (repo: svc) (kind: ship)" \
    "$home/data/backlog.md" "case-variant line not converged to canonical"
  # ...the stale lowercase id gone...
  assert_no_grep "- [ ] SVC-01" "$home/data/backlog.md" "stale case-variant line survived"
  # ...and the hand-added note preserved.
  assert_grep "hand note: keep me" "$home/data/backlog.md" "hand-added note was clobbered"
  # svc-02, svc-03 seeded fresh; svc-01 counted as renamed, not duplicated.
  assert_contains "$OUT" "seeded: 2" "did not seed the two new stories"
  assert_contains "$OUT" "renamed: 1" "did not count the rename"
  [ "$(grep -c 'svc-01' "$home/data/backlog.md")" -eq 1 ] || fail "svc-01 duplicated"
  pass "a case/kebab-renamed story id is reconciled in place, preserving state and notes"
}

# --- R2 fix: a present story whose title/repo/kind DRIFTED is refreshed -------
test_reconciles_drifted_fields() {
  local home; home=$(make_home drift)
  run "$home" u
  expect_code 0 "$RC" "first promote failed"
  # Simulate a redesign after the first promote: the story svc-02 title changed.
  write_story "$home/data/plans/ep/stories" svc-02 things svc main  # regenerate (heading same)
  # Force a real drift by editing the seeded backlog line to a stale title/repo/kind.
  perl -i -pe 's/- \[ \] svc-02 - \[things\] Story svc-02 heading \(repo: svc\) \(kind: ship\)/- [ ] svc-02 - [things] STALE title (repo: wrong) (kind: docs)/' \
    "$home/data/backlog.md"
  assert_grep "STALE title" "$home/data/backlog.md" "fixture drift not applied"
  run "$home" u
  expect_code 0 "$RC" "reconcile re-run failed"
  assert_contains "$OUT" "refreshed backlog entry svc-02" "did not report the field refresh"
  assert_contains "$OUT" "reconciled: 1" "did not count the reconcile"
  assert_grep "- [ ] svc-02 - [things] Story svc-02 heading (repo: svc) (kind: ship)" \
    "$home/data/backlog.md" "drifted line not converged to canonical"
  assert_no_grep "STALE title" "$home/data/backlog.md" "stale title survived"
  pass "an already-present story with drifted derived fields is rewritten to match the story"
}

# --- a genuine orphan tag (no matching story at all) is still refused --------
test_refuses_orphan_epic_tag() {
  local home; home=$(make_home orphan)
  # A task under this epic's tag whose id matches NO story, even by case.
  printf '## In flight\n\n## Queued\n- [ ] ghost-99 - [things] foreign task (repo: svc) (kind: ship) (since 2026-08-10)\n## Done\n' > "$home/data/backlog.md"
  run "$home" u
  expect_code 1 "$RC" "promote should refuse a foreign epic-tagged task"
  assert_contains "$OUT" "will not auto-resolve" "did not name the unresolvable drift"
  assert_contains "$OUT" "ghost-99" "did not point at the offending task"
  # Wrote nothing: epic still in the umbrella, no new tasks.
  assert_present "$home/umbrellas/u/plans/ep" "refusal still moved the epic dir"
  assert_absent "$home/data/plans/ep" "refusal wrote into data/plans"
  assert_no_grep "- [ ] svc-01" "$home/data/backlog.md" "refusal seeded a second parallel task set"
  pass "a foreign task under this epic's tag is refused, not duplicated, and writes nothing"
}

# --- validation refusals write nothing ---------------------------------------
test_refuses_missing_pr_base() {
  local home; home=$(make_home nopr)
  # Strip pr_base from one story.
  write_story "$home/umbrellas/u/plans/ep/stories" svc-02 things svc ""
  run "$home" u
  expect_code 1 "$RC" "missing pr_base should fail"
  assert_contains "$OUT" "pr_base" "did not name the missing pr_base"
  assert_absent "$home/data/plans/ep" "wrote to data/plans despite a validation failure"
  assert_no_grep "- [ ] svc-01" "$home/data/backlog.md" "seeded despite a validation failure"
  pass "a story missing pr_base fails with an actionable message and writes nothing"
}

test_refuses_unregistered_repo() {
  local home; home=$(make_home norepo)
  write_story "$home/umbrellas/u/plans/ep/stories" svc-02 things ghost-repo main
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
  assert_grep "- [ ] svc-01 - [things]" "$home/data/backlog.md" "manual seed did not render the line"
  # Idempotent under manual too.
  run "$home" u
  assert_contains "$OUT" "seeded: 0" "manual re-run seeded again"
  [ "$(grep -c '\- \[ \] svc-01 ' "$home/data/backlog.md")" -eq 1 ] || fail "manual re-run duplicated svc-01"
  pass "the manual backlog backend seeds and stays idempotent"
}

# --- manual backend reconciles a drifted line in place -----------------------
test_manual_backend_reconciles() {
  local home; home=$(make_home manualrecon)
  printf 'manual\n' > "$home/config/backlog-backend"
  run "$home" u
  expect_code 0 "$RC" "manual-backend promote failed"
  # Drift svc-01's fields (pure reconcile) AND case-rename svc-02 -> SVC-02 (rename
  # path) - both go through the manual backend's line-edit helpers.
  perl -i -pe 's/- \[ \] svc-01 - \[things\] Story svc-01 heading \(repo: svc\) \(kind: ship\)/- [ ] svc-01 - [things] OLD (repo: bad) (kind: docs)/' \
    "$home/data/backlog.md"
  perl -i -pe 's/- \[ \] svc-02 /- [ ] SVC-02 /' "$home/data/backlog.md"
  run "$home" u
  expect_code 0 "$RC" "manual reconcile failed"
  assert_contains "$OUT" "reconciled: 1" "manual backend did not reconcile the drift"
  assert_contains "$OUT" "renamed backlog id SVC-02 -> svc-02" "manual backend did not rewrite the case-variant id"
  assert_grep "- [ ] svc-01 - [things] Story svc-01 heading (repo: svc) (kind: ship)" \
    "$home/data/backlog.md" "manual reconcile did not converge the line"
  assert_grep "- [ ] svc-02 - [things] Story svc-02 heading (repo: svc) (kind: ship)" \
    "$home/data/backlog.md" "manual rename did not converge the renamed line"
  assert_no_grep "OLD (repo: bad)" "$home/data/backlog.md" "manual reconcile left stale fields"
  assert_no_grep "- [ ] SVC-02" "$home/data/backlog.md" "manual rename left the stale case-variant id"
  pass "the manual backend rewrites drifted and case-renamed lines in place"
}

# --- verify: green on a healthy epic, red (naming the drift) on a doctored one -
test_verify_green_then_red() {
  local home; home=$(make_home verify)
  run "$home" u
  expect_code 0 "$RC" "promote failed"

  # Green on the freshly promoted, healthy end-state.
  run "$home" verify u
  expect_code 0 "$RC" "verify should pass a healthy epic"
  assert_contains "$OUT" "verify OK" "did not confirm the healthy end-state"

  # (e) orphan: add a foreign epic-tagged task -> red naming it.
  printf -- '- [ ] ghost-99 - [things] orphan (repo: svc) (kind: ship) (since 2026-08-10)\n' >> "$home/data/backlog.md"
  run "$home" verify u
  expect_code 1 "$RC" "verify should fail on an orphan tag"
  assert_contains "$OUT" "(e)" "did not classify the orphan failure"
  assert_contains "$OUT" "ghost-99" "did not name the orphan task"

  # (d) drop a story's backlog entry -> red naming the missing brief.
  run "$home" u >/dev/null 2>&1 || true   # (no-op; keep state)
  local bl; bl=$(mktemp); grep -v ' svc-03 ' "$home/data/backlog.md" | grep -v 'ghost-99' > "$bl"; mv "$bl" "$home/data/backlog.md"
  run "$home" verify u
  expect_code 1 "$RC" "verify should fail when a story has no backlog entry"
  assert_contains "$OUT" "svc-03" "did not name the unqueued story"
  assert_contains "$OUT" "no backlog entry" "did not classify the missing brief"

  # (b) break the back-symlink -> red.
  rm -f "$home/umbrellas/u/plans/ep"
  run "$home" verify u
  expect_code 1 "$RC" "verify should fail on a missing back-symlink"
  assert_contains "$OUT" "back-symlink" "did not name the broken symlink"
  pass "verify passes a healthy epic and fails loudly naming the exact drift"
}

# --- verify + reconcile end to end: red before, green after promote ----------
# The captain-facing repro: rename a story id (case) + drift its title, verify is
# RED, re-run promote converges it, verify is GREEN.
test_verify_red_then_green_after_reconcile() {
  local home; home=$(make_home verifyrecon)
  run "$home" u
  expect_code 0 "$RC" "first promote failed"
  # Doctor the backlog: svc-02 -> case variant SVC-02 with a stale title.
  perl -i -pe 's/- \[ \] svc-02 - \[things\] Story svc-02 heading \(repo: svc\) \(kind: ship\)/- [ ] SVC-02 - [things] STALE (repo: svc) (kind: ship)/' \
    "$home/data/backlog.md"
  run "$home" verify u
  expect_code 1 "$RC" "verify should be red on the doctored backlog"
  assert_contains "$OUT" "SVC-02" "verify did not name the case-variant drift"
  # Re-run promote converges it...
  run "$home" u
  expect_code 0 "$RC" "reconcile re-run failed"
  assert_contains "$OUT" "renamed backlog id SVC-02 -> svc-02" "did not rewrite the drifted id"
  # ...and verify is now green.
  run "$home" verify u
  expect_code 0 "$RC" "verify should be green after reconcile"
  assert_contains "$OUT" "verify OK" "verify not green after reconcile"
  pass "verify is red on drift and green after promote converges it"
}

# --- R3 regression: marker written before the move, healed on reconcile ------
# 061c366 fixed R3 (marker recorded BEFORE the move so a crash between move and
# seed still lets a re-run locate the moved copy). Keep it fixed: a promote must
# leave a correct .promoted marker, and a re-run from the moved copy must work.
test_marker_written_before_move() {
  local home; home=$(make_home r3)
  run "$home" u
  expect_code 0 "$RC" "promote failed"
  assert_grep "ep" "$home/umbrellas/u/.promoted" "marker not written on promote"
  # Simulate a crash AFTER move+marker but BEFORE any seed: wipe the backlog and
  # drop the source (already moved). A re-run must locate via the marker and seed.
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  [ -f "$home/umbrellas/u/.promoted" ] || fail "marker vanished"
  run "$home" u
  expect_code 0 "$RC" "reconcile-from-marker re-run failed"
  assert_contains "$OUT" "already promoted to data/plans/ep" "did not reconcile from the marker"
  assert_grep "- [ ] svc-01 - [things]" "$home/data/backlog.md" "did not re-seed from the moved copy"
  pass "the .promoted marker is written before the move and drives a clean reconcile re-run"
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

# --- freshness guard: a draft (unfrozen) epic refuses, writes nothing ---------
# R1 (promote-before-frozen): promote must not seed a backlog from a design that
# is still a draft. The contract is sign-THEN-promote.
test_refuses_draft_status() {
  local home; home=$(make_home draft)
  sign_home "$home" draft   # unfreeze: still a draft, keeps signed_off
  run "$home" u
  expect_code 1 "$RC" "a draft-status epic should refuse to promote"
  assert_contains "$OUT" "not \"active\"" "did not report the unfrozen status"
  assert_contains "$OUT" "SIGN the epic" "did not tell the captain to sign first"
  assert_absent "$home/data/plans/ep" "draft refusal wrote into data/plans"
  assert_no_grep "- [ ] svc-01" "$home/data/backlog.md" "draft refusal seeded the backlog"
  pass "a draft-status epic is refused with a sign-first message and writes nothing"
}

# --- freshness guard: a stale sign-off refuses, naming the newer file ----------
# R6 (no stale-sign guard): a design file edited AFTER the sign-off must block the
# promote until the captain re-signs the current design. mtimes are pinned in UTC
# so the day-resolution comparison is deterministic regardless of the wall clock.
test_stale_sign_guard() {
  local home; home=$(make_home stale)
  local ep="$home/umbrellas/u/plans/ep"
  # Freeze + sign at a fixed date, and pin every design file's mtime to that day.
  sign_home "$home" active 2026-08-18
  TZ=UTC touch -t 202608180000 "$ep/epic.md" "$ep/stories"/*.md "$home/umbrellas/u/DESIGN.md"
  # The captain edits ONE story AFTER signing.
  TZ=UTC touch -t 202608200000 "$ep/stories/svc-02.md"
  run "$home" u
  expect_code 1 "$RC" "a design edited after sign-off should refuse"
  assert_contains "$OUT" "stale" "did not report the stale sign-off"
  assert_contains "$OUT" "svc-02.md" "did not name the offending story file"
  assert_absent "$home/data/plans/ep" "stale refusal wrote into data/plans"
  assert_no_grep "- [ ] svc-01" "$home/data/backlog.md" "stale refusal seeded the backlog"

  # Re-sign the current design: signed_off now covers the edited story.
  sign_home "$home" active 2026-08-20
  TZ=UTC touch -t 202608200000 "$ep/epic.md"
  run "$home" u
  expect_code 0 "$RC" "promote should pass cleanly after re-signing the current design"
  assert_grep "- [ ] svc-02 - [things]" "$home/data/backlog.md" "did not seed after re-sign"
  pass "a design edited after sign-off is refused (naming the file) until re-signed"
}

# --- freshness guard: --allow-stale-sign downgrades to a loud warning ----------
test_allow_stale_sign_override() {
  local home; home=$(make_home allowstale)
  local ep="$home/umbrellas/u/plans/ep"
  sign_home "$home" active 2026-08-18
  TZ=UTC touch -t 202608180000 "$ep/epic.md" "$ep/stories"/*.md "$home/umbrellas/u/DESIGN.md"
  TZ=UTC touch -t 202608200000 "$ep/stories/svc-02.md"
  run "$home" --allow-stale-sign u
  expect_code 0 "$RC" "--allow-stale-sign should proceed"
  assert_contains "$OUT" "warning" "did not warn loudly about the stale sign-off"
  assert_contains "$OUT" "svc-02.md" "warning did not name the offending file"
  assert_grep "- [ ] svc-01 - [things]" "$home/data/backlog.md" "override did not seed the backlog"
  pass "--allow-stale-sign proceeds with a loud warning naming the stale file"
}

test_promote_moves_and_seeds
test_backsymlink_canonical_and_single_count
test_rerun_heals_missing_backsymlink
test_rerun_is_noop
test_partial_resume
test_reconciles_case_variant_seed
test_reconciles_drifted_fields
test_refuses_orphan_epic_tag
test_refuses_missing_pr_base
test_refuses_unregistered_repo
test_manual_backend
test_manual_backend_reconciles
test_verify_green_then_red
test_verify_red_then_green_after_reconcile
test_marker_written_before_move
test_locate_errors
test_refuses_draft_status
test_stale_sign_guard
test_allow_stale_sign_override

echo "# all fm-umbrella-promote tests passed"
