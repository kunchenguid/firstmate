#!/usr/bin/env bash
# Behavior tests for the explicit held-improvement stack used by fm-update.sh.
#
# The primary keeps its default branch as the pristine upstream base and runs a
# detached effective revision built from that base plus ordered local patches.
# A candidate is published only after every patch applies, and linked
# secondmate homes converge to the same known-good effective revision.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-held-improvements)
HELD="$ROOT/bin/fm-held-improvements.sh"
UPDATE="$ROOT/bin/fm-update.sh"

HELD_BASE=
HELD_HEAD=
HELD_CONTENT='#!/usr/bin/env bash
printf "push guard from PR 1602\n"'

new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'instructions v1\n' > "$w/seed/AGENTS.md"
  printf 'upstream v1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin"
  printf '#!/usr/bin/env bash\nprintf "tool v1\\n"\n' > "$w/seed/bin/tool.sh"
  chmod +x "$w/seed/bin/tool.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm base
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

make_pr_1602_source() {
  local w=$1
  HELD_BASE=$(git -C "$w/seed" rev-parse main)
  git -C "$w/seed" checkout -qb held-pr-1602 main
  printf '%s\n' "$HELD_CONTENT" > "$w/seed/bin/fm-push-guard.sh"
  chmod +x "$w/seed/bin/fm-push-guard.sh"
  git -C "$w/seed" add bin/fm-push-guard.sh
  git -C "$w/seed" commit -qm 'PR 1602 held push guard'
  HELD_HEAD=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/seed" push -q origin HEAD:held-pr-1602
  git -C "$w/seed" checkout -q main
  git -C "$w/main" fetch -q origin held-pr-1602
}

activate_pr_1602() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" init main >/dev/null
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$HELD" add 010 pr-1602 "$HELD_BASE" "$HELD_HEAD" \
      'PR 1602 push guard' >/dev/null
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" >/dev/null 2>&1
}

add_secondmate() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" HEAD
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
  } > "$w/home/state/$id.meta"
}

advance_upstream() {
  local w=$1 subject=$2
  printf 'upstream v2\n' > "$w/seed/README.md"
  git -C "$w/seed" add README.md
  git -C "$w/seed" commit -qm "$subject"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1
}

test_upstream_and_real_held_change_converge_across_primary_and_secondmate() {
  local w out main_head effective
  w=$(new_world converge)
  make_pr_1602_source "$w"
  activate_pr_1602 "$w"
  add_secondmate "$w" sm1
  advance_upstream "$w" 'upstream feature after held patch'

  out=$(run_update "$w")

  assert_contains "$out" 'reapplied: pr-1602' \
    "update did not report the held improvement replay"
  grep -q '^upstream v2$' "$w/main/README.md" \
    || fail "primary did not receive the upstream change"
  grep -q 'push guard from PR 1602' "$w/main/bin/fm-push-guard.sh" \
    || fail "primary lost the held PR 1602 file"
  grep -q '^upstream v2$' "$w/sm1/README.md" \
    || fail "secondmate did not receive the upstream change"
  grep -q 'push guard from PR 1602' "$w/sm1/bin/fm-push-guard.sh" \
    || fail "secondmate did not receive the held PR 1602 file"

  git -C "$w/main" symbolic-ref -q HEAD >/dev/null \
    && fail "held-mode primary must run a detached effective revision"
  main_head=$(git -C "$w/main" rev-parse refs/heads/main)
  [ "$main_head" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "the pristine main ref did not fast-forward to origin/main"
  effective=$(git -C "$w/main" rev-parse HEAD)
  [ "$effective" = "$(git -C "$w/sm1" rev-parse HEAD)" ] \
    || fail "primary and secondmate effective revisions differ"
  pass "held updater: upstream and PR 1602 stay live on the primary and a linked secondmate"
}

test_upstream_equivalent_retires_held_improvement_by_content() {
  local w out source_commit upstream_commit listing
  w=$(new_world retire-equivalent)
  make_pr_1602_source "$w"
  source_commit=$HELD_HEAD
  activate_pr_1602 "$w"

  printf '%s\n' "$HELD_CONTENT" > "$w/seed/bin/fm-push-guard.sh"
  chmod +x "$w/seed/bin/fm-push-guard.sh"
  printf 'upstream v2\n' > "$w/seed/README.md"
  git -C "$w/seed" add README.md bin/fm-push-guard.sh
  git -C "$w/seed" commit -qm 'squash PR 1602 with an upstream companion change'
  upstream_commit=$(git -C "$w/seed" rev-parse HEAD)
  [ "$source_commit" != "$upstream_commit" ] \
    || fail "equivalent-upstream fixture accidentally reused the held commit id"
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")
  listing=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" list)

  assert_contains "$out" 'retired: pr-1602' \
    "content-equivalent upstream change did not retire the held improvement"
  assert_contains "$listing" 'retired 010 pr-1602' \
    "retired improvement remains in the active held set"
  assert_not_contains "$listing" 'active 010 pr-1602' \
    "content-equivalent improvement is still active"
  grep -q 'push guard from PR 1602' "$w/main/bin/fm-push-guard.sh" \
    || fail "retirement removed the upstream-equivalent push guard"
  pass "held updater: a squashed/rebased content equivalent retires automatically"
}

test_whitespace_different_upstream_content_does_not_retire() {
  local w out status listing
  w=$(new_world whitespace-different)
  make_pr_1602_source "$w"
  activate_pr_1602 "$w"

  printf '#!/usr/bin/env bash\nprintf    "push guard from PR 1602\\n"\n' \
    > "$w/seed/bin/fm-push-guard.sh"
  chmod +x "$w/seed/bin/fm-push-guard.sh"
  git -C "$w/seed" add bin/fm-push-guard.sh
  git -C "$w/seed" commit -qm 'rewrite PR 1602 with different whitespace'
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")
  status=$?
  listing=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" list)

  [ "$status" -ne 0 ] \
    || fail "whitespace-different upstream content was treated as an exact equivalent"
  assert_contains "$listing" 'active 010 pr-1602' \
    "whitespace-different upstream content retired the held improvement"
  assert_not_contains "$listing" 'retired 010 pr-1602' \
    "whitespace-different upstream content entered retired history"
  assert_contains "$out" 'collided with upstream change' \
    "whitespace-different content did not fail closed as a conflict"
  pass "held updater: whitespace-different upstream content never retires as equivalent"
}

test_relative_home_resolves_patch_paths_before_candidate_checkout() {
  local w out
  w=$(new_world relative-home)
  make_pr_1602_source "$w"

  out=$(cd "$w" && \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME=home "$HELD" init main && \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME=home \
      "$HELD" add 010 pr-1602 "$HELD_BASE" "$HELD_HEAD" 'PR 1602 push guard' && \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME=home "$UPDATE" 2>&1)

  assert_contains "$out" 'reapplied: pr-1602' \
    "relative FM_HOME did not resolve its patch before scratch-worktree replay"
  grep -q 'push guard from PR 1602' "$w/main/bin/fm-push-guard.sh" \
    || fail "relative FM_HOME lost the held file"
  pass "held updater: relative FM_HOME resolves held patches independently of candidate cwd"
}

test_pristine_base_checked_out_elsewhere_fails_before_moving_any_ref() {
  local w out status before_live before_base alarm
  w=$(new_world checked-out-base)
  make_pr_1602_source "$w"
  activate_pr_1602 "$w"
  before_live=$(git -C "$w/main" rev-parse HEAD)
  before_base=$(git -C "$w/main" rev-parse refs/heads/main)
  git -C "$w/main" worktree add -q "$w/main-holder" main
  advance_upstream "$w" 'upstream advance while pristine main is checked out elsewhere'

  out=$(run_update "$w")
  status=$?
  [ "$status" -ne 0 ] \
    || fail "held update moved a pristine branch that another worktree had checked out"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before_live" ] \
    || fail "checked-out pristine branch refusal moved the live effective revision"
  [ "$(git -C "$w/main" rev-parse refs/heads/main)" = "$before_base" ] \
    || fail "checked-out pristine branch refusal moved refs/heads/main"
  alarm=$(cat "$w/home/state/.nightly-update-needs-attention")
  assert_contains "$alarm" 'pristine main is checked out by worktree' \
    "checked-out pristine branch refusal did not explain the collision"
  assert_contains "$alarm" '/main-holder' \
    "checked-out pristine branch refusal did not name the owning worktree"
  assert_contains "$out" 'live revision was not changed' \
    "checked-out pristine branch refusal did not report fail-closed state"
  pass "held updater: a checked-out pristine base cannot move behind another worktree"
}

test_conflict_stops_on_last_good_and_names_both_sides_then_recovers() {
  local w out status before upstream_commit alarm
  w=$(new_world conflict)
  make_pr_1602_source "$w"
  activate_pr_1602 "$w"
  add_secondmate "$w" sm1
  before=$(git -C "$w/main" rev-parse HEAD)

  printf '#!/usr/bin/env bash\nprintf "incompatible upstream guard\\n"\n' \
    > "$w/seed/bin/fm-push-guard.sh"
  git -C "$w/seed" add bin/fm-push-guard.sh
  git -C "$w/seed" commit -qm 'replace push guard with incompatible upstream policy'
  upstream_commit=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")
  status=$?
  [ "$status" -ne 0 ] || fail "genuine held/upstream conflict unexpectedly passed"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "conflict moved the primary off its last known-good effective revision"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "conflict moved the secondmate off its last known-good effective revision"
  grep -q 'push guard from PR 1602' "$w/main/bin/fm-push-guard.sh" \
    || fail "conflict replaced the running held file"
  alarm=$(cat "$w/home/state/.nightly-update-needs-attention")
  assert_contains "$alarm" 'pr-1602' \
    "attention message did not name the held improvement"
  assert_contains "$alarm" "$(printf '%.12s' "$upstream_commit")" \
    "attention message did not name the colliding upstream commit"
  assert_contains "$alarm" 'replace push guard with incompatible upstream policy' \
    "attention message did not name the colliding upstream change"
  assert_contains "$out" 'bin/fm-push-guard.sh' \
    "conflict output did not name the collided path"

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$HELD" retire pr-1602 'operator chose the upstream policy after inspecting the conflict' \
      >/dev/null
  out=$(run_update "$w")
  assert_contains "$out" 'firstmate: updated ' \
    "explicit conflict resolution did not recover the update"
  [ ! -e "$w/home/state/.nightly-update-needs-attention" ] \
    || fail "successful recovery left the nightly attention alarm behind"
  grep -q 'incompatible upstream guard' "$w/main/bin/fm-push-guard.sh" \
    || fail "recovery did not install the chosen upstream side"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse HEAD)" ] \
    || fail "recovery did not reconverge the secondmate"
  pass "held updater: conflict is RED and explicit resolution recovers both homes"
}

make_second_source() {
  local w=$1 branch=$2 file=$3
  git -C "$w/seed" checkout -qb "$branch" main
  printf '#!/usr/bin/env bash\nprintf "%s\\n"\n' "$branch" > "$w/seed/$file"
  git -C "$w/seed" add "$file"
  git -C "$w/seed" commit -qm "held source $branch"
  git -C "$w/seed" push -q origin "HEAD:$branch"
  git -C "$w/seed" checkout -q main
  git -C "$w/main" fetch -q origin "$branch"
  git -C "$w/seed" rev-parse "$branch"
}

# An id that is a dash-suffix of another entry's id must never select it. Two
# entries, ids 'pr-1602' and '1602', are the exact shape that made the recovery
# path retire the wrong improvement and made add refuse a genuinely free id.
test_id_matching_is_exact_across_dash_suffixed_ids() {
  local w second listing out
  w=$(new_world dash-suffix-ids)
  make_pr_1602_source "$w"
  second=$(make_second_source "$w" held-second bin/fm-second-guard.sh)

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" init main >/dev/null
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$HELD" add 010 pr-1602 "$HELD_BASE" "$HELD_HEAD" 'PR 1602 push guard' >/dev/null
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$HELD" add 020 1602 "$HELD_BASE" "$second" 'second held guard' 2>&1) \
    || fail "add refused a free id that is a dash-suffix of an existing id: $out"

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$HELD" retire 1602 'operator chose the upstream side' >/dev/null
  listing=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" list)

  assert_contains "$listing" 'active 010 pr-1602' \
    "retiring id 1602 also retired the unrelated pr-1602 entry"
  assert_contains "$listing" 'retired 020 1602' \
    "retiring id 1602 did not retire the entry the operator named"
  assert_not_contains "$listing" 'retired 010 pr-1602' \
    "the dash-suffixed id selected the wrong held improvement"
  pass "held stack: add and retire match an id exactly, never as a dash-suffix"
}

# One upstream commit that touches several of a held patch's paths is one
# collision, so the attention message must name it once rather than once per
# path. The held patch spans bin/fm-guard-a.sh and bin/fm-guard-b.sh, and
# upstream touches a twice and b once, so the repeat of the shared commit
# arrives while two commits are already recorded. That is the shape the dedup
# has to survive: a dedup that only works while it holds a single entry passes a
# one-commit fixture and still repeats every commit in the real message.
test_one_upstream_commit_across_several_paths_is_named_once() {
  local w out status alarm mentions shared
  w=$(new_world conflict-dedup)
  HELD_BASE=$(git -C "$w/seed" rev-parse main)
  git -C "$w/seed" checkout -qb held-multi main
  printf '%s\n' "$HELD_CONTENT" > "$w/seed/bin/fm-guard-a.sh"
  printf '%s\n' "$HELD_CONTENT" > "$w/seed/bin/fm-guard-b.sh"
  chmod +x "$w/seed/bin/fm-guard-a.sh" "$w/seed/bin/fm-guard-b.sh"
  git -C "$w/seed" add bin/fm-guard-a.sh bin/fm-guard-b.sh
  git -C "$w/seed" commit -qm 'held push guard across two paths'
  HELD_HEAD=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/seed" push -q origin HEAD:held-multi
  git -C "$w/seed" checkout -q main
  git -C "$w/main" fetch -q origin held-multi

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" init main >/dev/null
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$HELD" add 010 pr-1602 "$HELD_BASE" "$HELD_HEAD" 'PR 1602 push guard' >/dev/null
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" >/dev/null 2>&1

  printf '#!/usr/bin/env bash\nprintf "incompatible upstream a\\n"\n' \
    > "$w/seed/bin/fm-guard-a.sh"
  printf '#!/usr/bin/env bash\nprintf "incompatible upstream b\\n"\n' \
    > "$w/seed/bin/fm-guard-b.sh"
  git -C "$w/seed" add bin/fm-guard-a.sh bin/fm-guard-b.sh
  git -C "$w/seed" commit -qm 'one upstream commit replaces both guard paths'
  shared=$(git -C "$w/seed" rev-parse HEAD)
  printf '#!/usr/bin/env bash\nprintf "incompatible upstream a again\\n"\n' \
    > "$w/seed/bin/fm-guard-a.sh"
  git -C "$w/seed" add bin/fm-guard-a.sh
  git -C "$w/seed" commit -qm 'a later upstream commit revisits only guard a'
  git -C "$w/seed" push -q origin main

  out=$(run_update "$w")
  status=$?
  [ "$status" -ne 0 ] || fail "multi-path held/upstream conflict unexpectedly passed"
  alarm=$(cat "$w/home/state/.nightly-update-needs-attention")
  mentions=$(printf '%s\n' "$alarm" | grep -c "$shared")
  [ "$mentions" -eq 1 ] \
    || fail "the shared colliding upstream commit was named $mentions time(s) in the attention message"
  assert_contains "$alarm" 'a later upstream commit revisits only guard a' \
    "deduplication dropped a distinct colliding upstream commit"
  assert_contains "$out" 'bin/fm-guard-b.sh' \
    "conflict output did not name every collided path"
  pass "held updater: a colliding upstream commit is named once however many paths it touched"
}

# A stack directory without its live ref is a state no command can leave, so a
# failure after the directory lands must roll it back rather than be escapable.
test_failed_init_publication_rolls_the_stack_back() {
  local w out status blocker
  w=$(new_world init-rollback)
  make_pr_1602_source "$w"
  blocker=$(git -C "$w/main" rev-parse refs/heads/main)
  git -C "$w/main" update-ref refs/firstmate/held/live/blocker "$blocker"

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" init main 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "init reported success although the live ref could not publish"
  assert_contains "$out" 'nothing was changed' \
    "failed init did not report that it left nothing behind"
  [ ! -e "$w/home/config/held-improvements" ] \
    || fail "failed init left a half-initialized stack directory behind"
  git -C "$w/main" symbolic-ref -q HEAD >/dev/null \
    || fail "failed init left the primary detached without a stack"

  git -C "$w/main" update-ref -d refs/firstmate/held/live/blocker
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$HELD" init main >/dev/null \
    || fail "init could not run again after its own rollback"
  pass "held stack: a failed init publishes nothing and leaves init runnable"
}

# Known-effective refs pin their commit and tree against gc, so the set is
# retained rather than accumulated for the life of the repository.
test_known_effective_refs_stay_bounded_across_updates() {
  local w n refs live
  w=$(new_world effective-cap)
  make_pr_1602_source "$w"
  activate_pr_1602 "$w"

  for n in 1 2 3 4 5; do
    printf 'upstream v%s\n' "$n" > "$w/seed/README.md"
    git -C "$w/seed" add README.md
    git -C "$w/seed" commit -qm "upstream advance $n"
    git -C "$w/seed" push -q origin main
    HELD_EFFECTIVE_RETAIN=4 FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
      "$UPDATE" >/dev/null 2>&1 || fail "held update $n failed"
  done

  refs=$(git -C "$w/main" for-each-ref --format='%(refname)' refs/firstmate/held/effective \
    | grep -c .)
  [ "$refs" -le 4 ] || fail "known-effective refs grew unbounded: $refs retained under a cap of 4"
  live=$(git -C "$w/main" rev-parse HEAD)
  git -C "$w/main" show-ref --verify --quiet "refs/firstmate/held/effective/$live" \
    || fail "pruning dropped the current effective revision from the known-effective set"
  pass "held updater: the known-effective ref set stays bounded and keeps the live revision"
}

test_upstream_and_real_held_change_converge_across_primary_and_secondmate
test_upstream_equivalent_retires_held_improvement_by_content
test_whitespace_different_upstream_content_does_not_retire
test_relative_home_resolves_patch_paths_before_candidate_checkout
test_pristine_base_checked_out_elsewhere_fails_before_moving_any_ref
test_conflict_stops_on_last_good_and_names_both_sides_then_recovers
test_id_matching_is_exact_across_dash_suffixed_ids
test_one_upstream_commit_across_several_paths_is_named_once
test_failed_init_publication_rolls_the_stack_back
test_known_effective_refs_stay_bounded_across_updates

echo "# all held-improvement tests passed"
