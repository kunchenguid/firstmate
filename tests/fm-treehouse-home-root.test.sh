#!/usr/bin/env bash
# tests/fm-treehouse-home-root.test.sh - regressions for the per-home Treehouse
# worktree root.
#
# Treehouse keys a pool by the repository's resolved origin, so before this every
# firstmate home cloning one origin allocated from a single shared pool: homes
# competed for the same numbered slots, and a slot could read free while its
# checkout was a linked worktree of another home's clone, which the spawn
# isolation assertion then refused and the task stopped. These tests pin the
# property that removes that shared namespace - two homes never pass the same
# worktree root - through the public interfaces that carry it: the derivation
# itself, the real fm-spawn.sh command sent to the worker's shell, the real
# fm-home-seed.sh lease, and the bootstrap capability gate.
#
# The complementary proof against the REAL provider - two clones of one origin
# acquiring concurrently, and a worktree in a legacy shared root still returning
# afterwards - is tests/fm-treehouse-pool-isolation-live-e2e.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-home-root)

test_root_is_per_home_and_spelling_independent() {
  local base home_a home_b root_a root_b link relative
  base="$TMP_ROOT/derive"
  home_a="$base/homes/alpha"
  home_b="$base/homes/beta"
  mkdir -p "$home_a" "$home_b" "$base/treehouse-base"

  root_a=$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$home_a") \
    || fail "no root derived for the first home"
  root_b=$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$home_b") \
    || fail "no root derived for the second home"
  [ "$root_a" != "$root_b" ] \
    || fail "two homes derived the same worktree root, so they would still share one pool: $root_a"
  case "$root_a" in
    "$base/treehouse-base"/*) : ;;
    *) fail "the operator's own TREEHOUSE_ROOT base was not honored: $root_a" ;;
  esac

  # Every process that knows a home must derive the identical root, however that
  # home was spelled: a get from one spelling and a get from another would
  # otherwise land in two pools and lose the per-home guarantee the slot claims
  # written beside each worktree assume.
  link="$base/link-to-alpha"
  ln -s "$home_a" "$link"
  [ "$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$link")" = "$root_a" ] \
    || fail "a symlinked spelling of one home derived a different root"
  [ "$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$home_a/")" = "$root_a" ] \
    || fail "a trailing-slash spelling of one home derived a different root"
  relative=$(cd "$base/homes" && TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root alpha) \
    || fail "a relative spelling of one home derived no root"
  [ "$relative" = "$root_a" ] || fail "a relative spelling of one home derived a different root"

  # Two spellings of the BASE must agree too, or one home would allocate from two
  # roots depending only on how the operator exported it.
  [ "$(TREEHOUSE_ROOT="$base/treehouse-base/" fm_treehouse_home_root "$home_a")" = "$root_a" ] \
    || fail "a trailing-slash TREEHOUSE_ROOT derived a different root for one home"
  pass "the worktree root is per home and independent of how the home or base is spelled"
}

test_root_falls_back_to_home_and_fails_closed() {
  local base fallback
  base="$TMP_ROOT/fallback"
  mkdir -p "$base/home" "$base/user"

  fallback=$(TREEHOUSE_ROOT='' HOME="$base/user" fm_treehouse_home_root "$base/home") \
    || fail "no root derived with TREEHOUSE_ROOT unset"
  case "$fallback" in
    "$base/user"/*) : ;;
    *) fail "an unset TREEHOUSE_ROOT did not fall back to Treehouse's own base: $fallback" ;;
  esac

  if TREEHOUSE_ROOT='' HOME="$base/user" fm_treehouse_home_root "$base/absent" >/dev/null 2>&1; then
    fail "a home that does not exist still produced a worktree root"
  fi
  if TREEHOUSE_ROOT='relative/base' HOME="$base/user" fm_treehouse_home_root "$base/home" >/dev/null 2>&1; then
    fail "a non-absolute base still produced a worktree root"
  fi
  if TREEHOUSE_ROOT='' HOME='' fm_treehouse_home_root "$base/home" >/dev/null 2>&1; then
    fail "an unresolvable base still produced a worktree root"
  fi
  pass "the worktree root falls back to Treehouse's own base and otherwise refuses"
}

# Build a spawn fixture under <case>/ and echo "<home> <project> <pool> <fakebin>".
make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$case_dir/treehouse-base"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  printf '%s %s %s %s\n' "$home" "$project" "$pool" "$fakebin"
}

# Drive the real spawn and echo the treehouse line it sent to the worker's shell.
spawn_pane_command() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin pane_log out
  case_dir="$TMP_ROOT/$name"
  read -r home project pool fakebin < "$case_dir/record"
  pane_log="$case_dir/pane.log"
  : > "$pane_log"
  out=$(FM_FAKE_PANE_LOG="$pane_log" TREEHOUSE_ROOT="$case_dir/treehouse-base" \
    fm_test_run_spawn "$home" "$pool" "$fakebin" \
    "$id" "$project" --mode local-only --yolo off) \
    || fail "spawn failed for $id"$'\n'"$out"
  grep -E '^treehouse( |$)' "$pane_log" || fail "spawn sent no treehouse command to the worker's shell"
}

test_spawn_allocates_from_its_own_home_root() {
  local cmd_a cmd_b root_a root_b
  make_spawn_case spawn-a root-spawn-a > "$TMP_ROOT/spawn-a-record"
  mkdir -p "$TMP_ROOT/spawn-a"
  mv "$TMP_ROOT/spawn-a-record" "$TMP_ROOT/spawn-a/record"
  make_spawn_case spawn-b root-spawn-b > "$TMP_ROOT/spawn-b-record"
  mv "$TMP_ROOT/spawn-b-record" "$TMP_ROOT/spawn-b/record"

  cmd_a=$(spawn_pane_command spawn-a root-spawn-a)
  cmd_b=$(spawn_pane_command spawn-b root-spawn-b)

  root_a=$(TREEHOUSE_ROOT="$TMP_ROOT/spawn-a/treehouse-base" fm_treehouse_home_root "$TMP_ROOT/spawn-a/home") \
    || fail "could not derive the first home's root"
  root_b=$(TREEHOUSE_ROOT="$TMP_ROOT/spawn-b/treehouse-base" fm_treehouse_home_root "$TMP_ROOT/spawn-b/home") \
    || fail "could not derive the second home's root"
  [ "$root_a" != "$root_b" ] || fail "the two spawn fixtures share one worktree root"

  assert_contains "$cmd_a" "--root '$root_a'" "spawn did not acquire from its own home's worktree root"
  assert_contains "$cmd_b" "--root '$root_b'" "spawn did not acquire from its own home's worktree root"
  assert_not_contains "$cmd_a" "$root_b" "one home's spawn reached into another home's worktree root"
  assert_not_contains "$cmd_b" "$root_a" "one home's spawn reached into another home's worktree root"
  pass "each home's spawn acquires its worktree from that home's own root"
}

test_home_seed_leases_from_the_seeding_home_root() {
  local home acquired fakebin log root_file base expected err
  base="$TMP_ROOT/seed"
  err="$base/seed.err"
  home="$base/home"
  acquired="$base/acquired"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$base/treehouse-base"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$base/remotes/alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  fakebin=$(make_fake_tmux "$base/fake")
  log="$base/fake/tmux.log"
  root_file="$base/fake/root"

  PATH="$fakebin:$PATH" FM_HOME="$home" TREEHOUSE_ROOT="$base/treehouse-base" \
    FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_FAKE_TREEHOUSE_ROOT_FILE="$root_file" \
    FM_SECONDMATE_CHARTER='seed root scope' FM_SECONDMATE_SCOPE='seed root scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err" \
    || fail "seed failed for a treehouse-acquired home"$'\n'"$(cat "$err")"

  expected=$(TREEHOUSE_ROOT="$base/treehouse-base" fm_treehouse_home_root "$home") \
    || fail "could not derive the seeding home's root"
  [ -f "$root_file" ] || fail "the seed lease carried no worktree root"
  [ "$(cat "$root_file")" = "$expected" ] \
    || fail "the seed leased from '$(cat "$root_file")', not the seeding home's root '$expected'"
  pass "a leased secondmate home comes from the seeding home's own worktree root"
}

test_home_seed_return_resolves_from_the_path() {
  local home acquired acquired_abs fakebin log err base
  base="$TMP_ROOT/seed-return"
  home="$base/home"
  acquired="$base/acquired"
  err="$base/seed.err"
  mkdir -p "$home/projects" "$home/data" "$home/state" "$base/treehouse-base"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$base/remotes/alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  acquired_abs=$(cd "$acquired" && pwd -P)
  printf 'other\n' > "$acquired/.fm-secondmate-home"
  fakebin=$(make_fake_tmux "$base/fake")
  log="$base/fake/tmux.log"

  if PATH="$fakebin:$PATH" FM_HOME="$home" TREEHOUSE_ROOT="$base/treehouse-base" \
    FM_FAKE_TREEHOUSE_HOME="$acquired" FM_FAKE_TMUX_LOG="$log" \
    FM_SECONDMATE_CHARTER='seed return scope' FM_SECONDMATE_SCOPE='seed return scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha >/dev/null 2>"$err"; then
    fail "seed reused an acquired home marked for another secondmate"
  fi
  # A return names the worktree, and Treehouse resolves the pool from that path.
  # Keeping the return flagless is what leaves every worktree already leased under
  # the previously shared root returnable once its home moves to its own root.
  assert_grep "treehouse return --force $acquired_abs" "$log" \
    "the rollback return did not name the worktree path"
  pass "a rollback return names the worktree path, so worktrees leased under any root stay returnable"
}

test_bootstrap_requires_the_worktree_root_flag() {
  local base fakebin out
  base="$TMP_ROOT/bootstrap"
  fakebin=$(fm_fakebin "$base/fake")
  mkdir -p "$base/home/state" "$base/home/data" "$base/home/config" "$base/home/projects"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
# A build carrying the durable lease but no global worktree root.
case "$*" in
  *--help*) printf 'Usage:\n  treehouse get [flags]\n\nFlags:\n      --lease\n      --lease-holder string\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$base/home" FM_STATE_OVERRIDE="$base/home/state" \
    FM_DATA_OVERRIDE="$base/home/data" FM_CONFIG_OVERRIDE="$base/home/config" \
    FM_PROJECTS_OVERRIDE="$base/home/projects" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_contains "$out" "MISSING: treehouse" \
    "bootstrap accepted a treehouse build that cannot give each home its own worktree root"
  pass "bootstrap reports a treehouse build without the worktree-root flag as needing an upgrade"
}

test_root_is_per_home_and_spelling_independent
test_root_falls_back_to_home_and_fails_closed
test_spawn_allocates_from_its_own_home_root
test_home_seed_leases_from_the_seeding_home_root
test_home_seed_return_resolves_from_the_path
test_bootstrap_requires_the_worktree_root_flag
