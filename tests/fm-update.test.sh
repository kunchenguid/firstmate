#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fork-based self-update of a running firstmate repo
# and every registered secondmate home.
#
# This fleet runs a FORK, so upstream reaches a home in two hops: origin is
# merged into fork/<default>, and only then does each home fast-forward to the
# fork. The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - INGEST: origin/main is merged into fork/main and pushed to the fork.
#   - ADVANCE: every home fast-forwards to FORK/main, never origin/main, so the
#     fleet's private adaptations survive the update instead of being stripped.
#   - A CONFLICTING ingest stops the run: nothing is pushed, nothing is forced,
#     and every home stays exactly where it was.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The home advance is a single-parent fast-forward (never a merge commit) and
#     a fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / .agents/skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)

# Build a fresh fork world:
#   origin.git  - the shared upstream, seeded with one commit;
#   fork.git    - this fleet's fork: that same commit PLUS one private adaptation
#                 (FORK.md), which every later assertion checks still survives;
#   seed        - a clone tracking origin, used to bump upstream;
#   forkwork    - a clone tracking the fork, used to bump the fork;
#   main        - the running firstmate repo: cloned from origin (so origin/HEAD
#                 resolves the default branch), with a fork remote added and its
#                 main branch checked out at fork/main, exactly like a real home.
# Plus a home dir with state/ and data/. Echoes the world dir. Files seeded:
# AGENTS.md, README.md, bin/tool.sh, and an internal skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$w/fork.git"
  git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git -C "$w/seed" push -q "$w/fork.git" main

  # The fork's private adaptation, on the fork only. Upstream never sees it, and
  # no home may ever lose it.
  git clone -q "$w/fork.git" "$w/forkwork"
  printf 'fleet adaptation\n' > "$w/forkwork/FORK.md"
  git -C "$w/forkwork" add -A
  git -C "$w/forkwork" commit -qm fork-adaptation
  git -C "$w/forkwork" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$w/main" remote add fork "$w/fork.git"
  git -C "$w/main" fetch -q fork
  git -C "$w/main" reset -q --hard fork/main

  printf '%s\n' "$w"
}

# Rewrite AGENTS.md on the FORK only, so a later instr bump on origin (which
# rewrites the same file) collides and the ingest must stop on a conflict.
bump_fork_conflicting() {
  local w=$1
  git -C "$w/forkwork" pull -q origin main >/dev/null 2>&1 || true
  printf 'fork-flavoured agents\n' > "$w/forkwork/AGENTS.md"
  git -C "$w/forkwork" add -A
  git -C "$w/forkwork" commit -qm fork-agents
  git -C "$w/forkwork" push -q origin main
  git -C "$w/main" fetch -q fork
  git -C "$w/main" reset -q --hard fork/main
}

# The fork's published tip, which the homes must converge on.
fork_tip() {
  git -C "$1/fork.git" rev-parse main
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, .agents/skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

# Same run, but capturing the exit status too: the ingest stop path must be a
# non-zero exit, not just a printed complaint. Both results come back as globals
# because a command substitution would run this in a subshell and drop RUN_RC.
RUN_RC=0
RUN_OUT=""
run_update_rc() {
  local w=$1
  RUN_OUT=$(run_update "$w") && RUN_RC=0 || RUN_RC=$?
}

# --- T1: ingest upstream, then advance main + secondmate to the FORK --------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2 (the
# advance never leaves a home on a merge commit) with the fork model itself, so
# every contract is proven against the same update run.
test_ingests_upstream_and_advances_homes_to_fork() {
  local w out before_main before_sm
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr
  before_main=$(git -C "$w/main" rev-parse HEAD)
  before_sm=$(git -C "$w/sm1" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "upstream: merged origin/main into fork/main" "upstream ingested into the fork"
  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "nudge-secondmates: fm-sm1" "updated secondmate is nudged"

  # The ingest was published: the fork's own tip now contains upstream.
  git -C "$w/main" merge-base --is-ancestor origin/main "$(fork_tip "$w")" \
    || fail "fork tip does not contain origin/main after ingest"

  # Homes converge on the FORK's tip, not on origin's.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(fork_tip "$w")" ] \
    || fail "firstmate HEAD not at fork/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(fork_tip "$w")" ] \
    || fail "secondmate HEAD not at fork/main"
  [ "$(git -C "$w/main" rev-parse HEAD)" != "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate landed on origin/main - the fork's adaptations were stripped"

  # The whole point of the fork model: the private adaptation survives an
  # upstream ingest, and upstream's change arrives alongside it.
  [ -f "$w/main/FORK.md" ] || fail "fork adaptation FORK.md lost from firstmate"
  [ -f "$w/sm1/FORK.md" ] || fail "fork adaptation FORK.md lost from secondmate"
  grep -q v2 "$w/main/AGENTS.md" || fail "upstream instruction change did not reach firstmate"
  grep -q v2 "$w/sm1/AGENTS.md" || fail "upstream instruction change did not reach secondmate"

  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"

  # Each advance was a true fast-forward: the old tip is still reachable, so no
  # home was forced or rewritten. (The new tip is the ingest merge commit, so a
  # single-parent tip is NOT the invariant here - reachability is.)
  git -C "$w/main" merge-base --is-ancestor "$before_main" HEAD \
    || fail "firstmate advance was not a fast-forward"
  git -C "$w/sm1" merge-base --is-ancestor "$before_sm" HEAD \
    || fail "secondmate advance was not a fast-forward"
  pass "T1 upstream ingested into the fork, homes advanced to fork/main with adaptations intact"
}

# --- T2: a conflicting ingest stops the run, touching nothing ---------------
# Upstream and the fork both rewrote AGENTS.md, so the merge cannot be resolved
# mechanically. Prime directive #3 territory: never force, never half-apply.
test_conflicting_ingest_stops_and_touches_nothing() {
  local w out before_main before_sm before_fork
  w=$(new_world t2)
  bump_fork_conflicting "$w"
  add_sm "$w" sm1
  bump_origin "$w" instr
  before_main=$(git -C "$w/main" rev-parse HEAD)
  before_sm=$(git -C "$w/sm1" rev-parse HEAD)
  before_fork=$(fork_tip "$w")

  run_update_rc "$w"
  out="$RUN_OUT"

  [ "$RUN_RC" -ne 0 ] || fail "conflicting ingest exited 0, expected a non-zero stop"
  assert_contains "$out" "upstream: CONFLICT merging origin/main into fork/main" "conflict reported"
  assert_contains "$out" "conflict: AGENTS.md" "the conflicted path is named"
  assert_contains "$out" "resolve by hand" "the report says what to do next"

  # Nothing was published and nothing advanced.
  [ "$(fork_tip "$w")" = "$before_fork" ] || fail "fork tip moved despite a conflicting merge"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before_main" ] || fail "firstmate advanced despite a stopped ingest"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before_sm" ] || fail "secondmate advanced despite a stopped ingest"

  # The stop leaves no checkout mid-merge and no stray merge artifacts.
  [ -z "$(git -C "$w/main" status --porcelain)" ] || fail "firstmate working tree left dirty by the conflict"
  [ ! -f "$w/main/.git/MERGE_HEAD" ] || fail "firstmate left mid-merge"
  grep -q 'fork-flavoured agents' "$w/main/AGENTS.md" || fail "fork's AGENTS.md was clobbered"

  # The caller-action summary still parses, telling the caller to do nothing.
  assert_contains "$out" "reread-firstmate: no" "no reread after a stopped ingest"
  assert_contains "$out" "nudge-secondmates: none" "no nudge after a stopped ingest"
  pass "T2 conflicting ingest stops: nothing pushed, nothing advanced, nothing forced"
}

# --- T2b: the fork's own commits are never lost to a clean ingest -----------
# A fork commit that upstream knows nothing about must still be reachable from
# the published fork tip after the merge.
test_ingest_preserves_fork_only_history() {
  local w out
  w=$(new_world t2b)
  local fork_only
  fork_only=$(git -C "$w/main" rev-parse fork/main)
  bump_origin "$w" readme

  run_update_rc "$w"
  out="$RUN_OUT"

  [ "$RUN_RC" -eq 0 ] || fail "clean ingest exited non-zero"
  assert_contains "$out" "upstream: merged origin/main into fork/main" "clean merge reported"
  git -C "$w/main" merge-base --is-ancestor "$fork_only" "$(fork_tip "$w")" \
    || fail "the fork's own commit is unreachable from the published fork tip"
  git -C "$w/main" merge-base --is-ancestor origin/main "$(fork_tip "$w")" \
    || fail "upstream is unreachable from the published fork tip"
  pass "T2b clean ingest keeps both the fork's history and upstream's"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from fork/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "upstream: already merged into fork/main" "upstream ingest is idempotent"
  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

# --- T12: a home with no fork remote is skipped, never advanced from origin --
# The fork base mode must fail closed. Falling back to origin here would look
# like a successful update while silently stripping the fleet's adaptations.
test_home_without_fork_remote_is_skipped_not_advanced_from_origin() {
  local w out standalone before
  w=$(new_world t12)
  standalone="$w/standalone"
  # A standalone clone of UPSTREAM only: it has an origin remote but no fork.
  git clone -q "$w/origin.git" "$standalone"
  printf 'standalone\n' > "$standalone/.fm-secondmate-home"
  before=$(git -C "$standalone" rev-parse HEAD)
  printf -- '- standalone - no fork remote (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$standalone" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate standalone: skipped: no fork remote" "fork-less home skipped"
  assert_contains "$out" "nudge-secondmates: none" "skipped home is not nudged"
  [ "$(git -C "$standalone" rev-parse HEAD)" = "$before" ] \
    || fail "fork-less home was advanced anyway (origin fallback would strip adaptations)"
  pass "T12 a home without a fork remote is skipped, never advanced from origin"
}

# --- T13: a fork-less CODE ROOT is skipped too, exactly like a fork-less home --
# The fork base mode's verdict for a target with no fork remote is "skipped"
# (bin/fm-ff-lib.sh; T12 pins it for a home). The ingest used to call the same
# condition a hard failure and abort the whole run, so a fork-less code root -
# a remote Firstmate root cloned from origin alone, for instance - failed the
# update outright instead of being skipped. That inconsistency is the bug this
# pins: one condition, one verdict, on both paths.
#
# The guarantee is unchanged and is asserted here directly: skipping must never
# become an origin fallback, so the fork-less root must not move.
test_forkless_code_root_is_skipped_not_failed() {
  local w out rc before
  w=$(new_world t13)
  before=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" remote remove fork
  bump_origin "$w" instr

  rc=0
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null) || rc=$?

  [ "$rc" -eq 0 ] || fail "a fork-less code root must be skipped, not fail the run (exit $rc)"
  assert_contains "$out" "upstream: skipped: no fork remote" "ingest did not report the fork-less skip"
  assert_contains "$out" "firstmate: skipped: no fork remote" "the advance did not skip the fork-less root"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "fork-less code root was advanced anyway (an origin fallback would strip adaptations)"
  assert_contains "$out" "reread-firstmate: no" "a skipped run must not claim its instructions changed"
  pass "T13 a fork-less code root is skipped, never failed and never advanced from origin"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
}

test_ingests_upstream_and_advances_homes_to_fork
test_conflicting_ingest_stops_and_touches_nothing
test_ingest_preserves_fork_only_history
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_home_without_fork_remote_is_skipped_not_advanced_from_origin
test_forkless_code_root_is_skipped_not_failed
test_unsafe_secondmate_home_skipped_before_git_update

echo "# all fm-update tests passed"
