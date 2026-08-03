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

test_upstream_and_real_held_change_converge_across_primary_and_secondmate
test_upstream_equivalent_retires_held_improvement_by_content
test_whitespace_different_upstream_content_does_not_retire
test_relative_home_resolves_patch_paths_before_candidate_checkout
test_pristine_base_checked_out_elsewhere_fails_before_moving_any_ref
test_conflict_stops_on_last_good_and_names_both_sides_then_recovers

echo "# all held-improvement tests passed"
