#!/usr/bin/env bash
# Regression tests for single-owner custody of a pooled working copy.
#
# Treehouse keys a worktree pool by the repository, not by the checkout, and
# re-leases a slot as soon as the shell that held it is gone. Two firstmate
# homes that clone the same project therefore draw from ONE pool while neither
# can see the other's task records, so a slot one home's task still names gets
# handed to the other home - and whichever task is cleaned up first hard-resets
# the copy the other is working in.
#
# Four guarantees close that, and each is pinned here:
#   (a) every home leases from its OWN pool root (bin/fm-pool-root.sh, wired
#       into bin/fm-spawn.sh before the slot is acquired);
#   (b) a spawn refuses a copy another task in this home already claims
#       (bin/fm-spawn.sh), before the base refresh touches it;
#   (c) cleanup runs the canonical Git-authenticated custody check against the
#       copy and refuses when it is not this task's to discard
#       (bin/fm-teardown.sh);
#   (d) a spawn asks the project to release its delivered copies before leasing,
#       so a pool exhausted by copies nobody handed back does not block dispatch
#       (bin/fm-spawn.sh) - capacity, so a failure warns and the spawn continues.
#
# (a) is proven twice: portably against the configuration firstmate writes, and
# - where the real binary is installed - against treehouse itself allocating
# two clones of one origin, which is the vendor fact the whole class rests on.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

POOL_ROOT_BIN="$ROOT/bin/fm-pool-root.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-custody)

# --- (a) one pool root per home ---------------------------------------------

pool_root_for_home() {  # <home> <base> <project>
  FM_HOME="$1" FM_POOL_ROOT_BASE="$2" "$POOL_ROOT_BIN" "$3"
}

pool_config_view_for_home() {  # <home> <base> <project>
  FM_HOME="$1" FM_POOL_ROOT_BASE="$2" "$POOL_ROOT_BIN" --view "$3"
}

file_mode() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_two_homes_one_project() {  # <name>
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/homeA" "$case_dir/homeB" "$case_dir/base"
  fm_git_init_commit "$case_dir/upstream"
  git clone --quiet --bare "$case_dir/upstream" "$case_dir/origin.git"
  git clone --quiet "$case_dir/origin.git" "$case_dir/homeA/project"
  git clone --quiet "$case_dir/origin.git" "$case_dir/homeB/project"
  printf '%s\n' "$case_dir"
}

test_two_homes_configure_distinct_pool_roots() {
  local case_dir root_a root_b config_a config_b
  case_dir=$(make_two_homes_one_project distinct-roots)

  root_a=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$case_dir/homeA/project") \
    || fail "fm-pool-root.sh failed for the first home"
  root_b=$(pool_root_for_home "$case_dir/homeB" "$case_dir/base" "$case_dir/homeB/project") \
    || fail "fm-pool-root.sh failed for the second home"

  [ -n "$root_a" ] && [ -n "$root_b" ] || fail "fm-pool-root.sh printed no pool root"
  [ "$root_a" != "$root_b" ] \
    || fail "two homes cloning one project resolved the SAME pool root ($root_a)"
  [ -d "$root_a" ] && [ -d "$root_b" ] || fail "fm-pool-root.sh did not create the pool roots"
  config_a=$(pool_config_view_for_home "$case_dir/homeA" "$case_dir/base" "$case_dir/homeA/project")
  config_b=$(pool_config_view_for_home "$case_dir/homeB" "$case_dir/base" "$case_dir/homeB/project")
  assert_present "$config_a/treehouse.toml" "the first home has no generated Treehouse config"
  assert_present "$config_b/treehouse.toml" "the second home has no generated Treehouse config"
  git -C "$config_a" check-ignore -q -- treehouse.toml \
    || fail "the first generated Treehouse config is not actually ignored"
  git -C "$config_a" check-ignore -q -- .gitignore \
    || fail "the first generated ignore contract does not ignore itself"
  assert_absent "$case_dir/homeA/project/treehouse.toml" "pool setup mutated the first primary clone"
  assert_absent "$case_dir/homeB/project/treehouse.toml" "pool setup mutated the second primary clone"
  [ -z "$(git -C "$case_dir/homeA/project" status --porcelain)" ] \
    || fail "pool setup dirtied the first primary clone"
  [ -z "$(git -C "$case_dir/homeB/project" status --porcelain)" ] \
    || fail "pool setup dirtied the second primary clone"
  pass "two homes configure distinct roots outside their primary clones"
}

test_legacy_hash_collision_homes_resolve_distinct_pool_roots() {
  local parent_a=/private/tmp/fm-home-collision-8782
  local parent_b=/private/tmp/fm-home-collision-68310
  local home_a="$parent_a/home" home_b="$parent_b/home"
  local base="$TMP_ROOT/collision-base" status
  if [ ! -d /private/tmp ] || [ ! -w /private/tmp ]; then
    printf 'skip - exact canonical collision paths are unavailable on this platform\n'
    return 0
  fi

  (
    [ ! -e "$parent_a" ] && [ ! -L "$parent_a" ] || exit 2
    [ ! -e "$parent_b" ] && [ ! -L "$parent_b" ] || exit 2
    trap 'rmdir "$home_a" "$home_b" "$parent_a" "$parent_b" 2>/dev/null || true' EXIT
    mkdir "$parent_a" "$parent_b" || exit 3
    mkdir "$home_a" "$home_b" || exit 3
    root_a=$(FM_HOME="$home_a" FM_POOL_ROOT_BASE="$base" "$POOL_ROOT_BIN" --print) \
      || exit 4
    root_b=$(FM_HOME="$home_b" FM_POOL_ROOT_BASE="$base" "$POOL_ROOT_BIN" --print) \
      || exit 4
    [ "$root_a" != "$root_b" ] || exit 5
  )
  status=$?
  expect_code 0 "$status" \
    "the exact homes sharing legacy prefix 5edc853f must resolve distinct pool roots"
  pass "full home identities separate the exact legacy hash collision"
}

test_literal_pool_root_override_is_refused() {
  local case_dir shared out_a out_b status_a status_b
  case_dir=$(make_two_homes_one_project literal-root-refused)
  shared="$case_dir/shared-root"

  out_a=$(FM_HOME="$case_dir/homeA" FM_POOL_ROOT="$shared" \
    "$POOL_ROOT_BIN" --print 2>&1)
  status_a=$?
  out_b=$(FM_HOME="$case_dir/homeB" FM_POOL_ROOT="$shared" \
    "$POOL_ROOT_BIN" --print 2>&1)
  status_b=$?
  expect_code 1 "$status_a" "a literal root override must not bypass the first home's namespace"
  expect_code 1 "$status_b" "a shared literal root override must not bypass the second home's namespace"
  assert_contains "$out_a" "use FM_POOL_ROOT_BASE" "the first refusal did not provide the safe relocation setting"
  assert_contains "$out_b" "use FM_POOL_ROOT_BASE" "the second refusal did not provide the safe relocation setting"
  assert_absent "$shared" "the refused literal root override created a shared pool path"
  pass "a literal pool root override cannot disable per-home isolation"
}

test_pool_root_refuses_to_write_inside_the_primary_clone() {
  local case_dir clone out status generated
  case_dir=$(make_two_homes_one_project root-inside-primary-refused)
  clone="$case_dir/homeA/project"

  out=$(FM_HOME="$case_dir/homeA" FM_POOL_ROOT_BASE="$clone" \
    "$POOL_ROOT_BIN" "$clone" 2>&1)
  status=$?
  expect_code 1 "$status" "a pool root inside the primary clone must be refused"
  assert_contains "$out" "would mutate the primary project" \
    "the unsafe pool-root refusal did not identify the primary-clone boundary"
  generated=$(find "$clone" -mindepth 1 -maxdepth 1 -type d -name 'homeA-*' -print -quit)
  [ -z "$generated" ] || fail "the refusal created a pool directory inside the primary clone"
  assert_absent "$case_dir/homeA/state/treehouse-config" \
    "the refusal created a generated config view before rejecting the root"
  [ -z "$(git -C "$clone" status --porcelain)" ] \
    || fail "the unsafe pool-root refusal dirtied the primary clone"
  pass "a pool root inside the primary clone is rejected before any mutation"
}

test_relative_pool_root_base_is_refused_before_mutation() {
  local case_dir clone out_a out_b status_a status_b
  case_dir=$(make_two_homes_one_project relative-root-refused)
  clone="$case_dir/homeA/project"
  mkdir -p "$case_dir/cwd-a" "$case_dir/cwd-b"

  out_a=$(cd "$case_dir/cwd-a" && FM_HOME="$case_dir/homeA" \
    FM_POOL_ROOT_BASE=relative-pools "$POOL_ROOT_BIN" "$clone" 2>&1)
  status_a=$?
  out_b=$(cd "$case_dir/cwd-b" && FM_HOME="$case_dir/homeA" \
    FM_POOL_ROOT_BASE=relative-pools "$POOL_ROOT_BIN" "$clone" 2>&1)
  status_b=$?
  expect_code 1 "$status_a" "a relative pool base must be refused from the first directory"
  expect_code 1 "$status_b" "a relative pool base must be refused from the second directory"
  assert_contains "$out_a" "must be absolute" "the first relative-base refusal did not identify the stable-path requirement"
  assert_contains "$out_b" "must be absolute" "the second relative-base refusal did not identify the stable-path requirement"
  assert_absent "$case_dir/cwd-a/relative-pools" "the first refusal created a cwd-relative pool"
  assert_absent "$case_dir/cwd-b/relative-pools" "the second refusal created a cwd-relative pool"
  assert_absent "$case_dir/homeA/state/treehouse-config" \
    "the relative-base refusal created a generated config view"
  pass "relative pool bases cannot split one home's pool by working directory"
}

test_pool_root_is_idempotent_without_mutating_the_clone() {
  local case_dir clone config before after
  case_dir=$(make_two_homes_one_project idempotent)
  clone="$case_dir/homeA/project"
  pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$clone" >/dev/null \
    || fail "fm-pool-root.sh failed on its first generated config"
  config="$(pool_config_view_for_home "$case_dir/homeA" "$case_dir/base" "$clone")/treehouse.toml"
  before=$(cksum < "$config")
  pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$clone" >/dev/null \
    || fail "a repeat run of fm-pool-root.sh failed"
  after=$(cksum < "$config")
  [ "$before" = "$after" ] || fail "a repeat run rewrote an already-correct generated config"
  assert_absent "$clone/treehouse.toml" "idempotent pool setup wrote into the primary clone"
  [ -z "$(git -C "$clone" status --porcelain)" ] \
    || fail "idempotent pool setup dirtied the primary clone"
  pass "the generated pool config is idempotent and never mutates the primary clone"
}

test_pool_root_preserves_a_tracked_primary_config() {
  local case_dir clone out status
  case_dir=$(make_two_homes_one_project tracked-config)
  clone="$case_dir/homeA/project"
  printf 'max_trees = 20\nroot = "/somewhere/shared"\n' > "$clone/treehouse.toml"
  git -C "$clone" add treehouse.toml
  git -C "$clone" commit -qm "track treehouse.toml"

  out=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$clone" 2>&1)
  status=$?
  expect_code 0 "$status" "an isolated config view should not rewrite or reject tracked project config: $out"
  assert_grep '/somewhere/shared' "$clone/treehouse.toml" "a tracked config was rewritten anyway"
  [ -z "$(git -C "$clone" status --porcelain)" ] || fail "the refusal left project content modified"
  pass "a tracked primary treehouse.toml remains untouched and outside dispatch authority"
}

test_pool_root_preserves_a_nonregular_primary_config() {
  local case_dir clone out status
  case_dir=$(make_two_homes_one_project nonregular-config)
  clone="$case_dir/homeA/project"
  mkdir "$clone/treehouse.toml"
  touch "$clone/treehouse.toml/preserved"

  out=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$clone" 2>&1)
  status=$?
  expect_code 0 "$status" "an isolated config view should not inspect or rewrite the primary config path: $out"
  assert_present "$clone/treehouse.toml/preserved" "the invalid config path was modified"
  pass "a nonregular primary config path remains untouched by dispatch"
}

test_pool_root_verifies_the_written_config() {
  local case_dir clone fakebin out status generated relocated_base
  case_dir=$(make_two_homes_one_project verify-written-config)
  clone="$case_dir/homeA/project"
  relocated_base="$case_dir/new/relocated/base"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/mv"

  out=$(FM_HOME="$case_dir/homeA" FM_POOL_ROOT_BASE="$relocated_base" \
    PATH="$fakebin:$PATH" "$POOL_ROOT_BIN" "$clone" 2>&1)
  status=$?
  expect_code 1 "$status" "pool configuration should refuse when its write did not take effect"
  assert_contains "$out" "could not write and verify" "the failed write postcondition was not reported"
  generated=$(find "$case_dir/homeA/state/treehouse-config" -name treehouse.toml -print -quit 2>/dev/null || true)
  [ -z "$generated" ] || fail "the no-op writer unexpectedly configured a pool root"
  generated=$(find "$case_dir/homeA/state/treehouse-config" -name .git -print -quit 2>/dev/null || true)
  [ -z "$generated" ] || fail "the failed generated write left a partial Git view"
  assert_absent "$case_dir/new" \
    "the failed generated write left newly created pool-root parents"
  assert_absent "$case_dir/homeA/state" \
    "the failed generated write left newly created config-view parents"
  assert_absent "$clone/treehouse.toml" "the failed generated write mutated the primary clone"
  pass "pool configuration rolls back every newly created path after verification fails"
}

test_pool_root_rolls_back_an_existing_view_on_verification_failure() {
  local case_dir clone config project_git_dir fakebin real_git out status toml_before ignore_before
  local toml_mode ignore_mode exclude_before
  case_dir=$(make_two_homes_one_project rollback-existing-view)
  clone="$case_dir/homeA/project"
  config=$(pool_config_view_for_home "$case_dir/homeA" "$case_dir/base" "$clone") \
    || fail "could not create the rollback fixture view"
  project_git_dir=$(git -C "$clone" rev-parse --absolute-git-dir)
  rm -f -- "$config/.git/HEAD" "$config/.git/commondir" "$config/.git/index"
  rmdir "$config/.git"
  ln -s "$project_git_dir" "$config/.git"
  printf 'root = "/preserved/original"\n' > "$config/treehouse.toml"
  printf '.gitignore\ntreehouse.toml\npreserved-local-entry\n' > "$config/.gitignore"
  chmod 0640 "$config/treehouse.toml"
  chmod 0600 "$config/.gitignore"
  toml_before=$(cksum < "$config/treehouse.toml")
  ignore_before=$(cksum < "$config/.gitignore")
  toml_mode=$(file_mode "$config/treehouse.toml")
  ignore_mode=$(file_mode "$config/.gitignore")
  exclude_before=$(cksum < "$clone/.git/info/exclude")
  real_git=$(command -v git)
  fakebin=$(fm_fakebin "$case_dir/verify-failure")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *" check-ignore "*) exit 1 ;;
esac
exec "${FM_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"

  out=$(FM_HOME="$case_dir/homeA" FM_POOL_ROOT_BASE="$case_dir/base" \
    FM_REAL_GIT="$real_git" PATH="$fakebin:$PATH" "$POOL_ROOT_BIN" "$clone" 2>&1)
  status=$?
  expect_code 1 "$status" "a failed ignore verification must fail pool configuration"
  assert_contains "$out" "could not write and verify" "the transactional verification failure was not reported"
  [ "$(cksum < "$config/treehouse.toml")" = "$toml_before" ] \
    || fail "failed verification did not restore the prior Treehouse config"
  [ "$(cksum < "$config/.gitignore")" = "$ignore_before" ] \
    || fail "failed verification did not restore the prior ignore contract"
  [ "$(file_mode "$config/treehouse.toml")" = "$toml_mode" ] \
    || fail "failed verification did not restore the Treehouse config mode"
  [ "$(file_mode "$config/.gitignore")" = "$ignore_mode" ] \
    || fail "failed verification did not restore the ignore-contract mode"
  [ -L "$config/.git" ] && [ "$(readlink "$config/.git")" = "$project_git_dir" ] \
    || fail "failed verification did not restore the prior Git control link"
  [ "$(cksum < "$clone/.git/info/exclude")" = "$exclude_before" ] \
    || fail "generated-view rollback mutated the primary clone's Git exclusion"
  [ -z "$(git -C "$clone" status --porcelain)" ] \
    || fail "generated-view rollback dirtied the primary clone"
  pass "pool configuration restores the complete prior view after verification failure"
}

# The vendor fact the class rests on: treehouse hands two clones of one origin
# slots from the SAME pool, and only `root` moves that pool. Self-skipping,
# because the pool allocator is a third-party binary CI installs only for the
# lanes that need it (bin/fm-install-treehouse.sh).
test_real_treehouse_stops_sharing_a_pool_between_homes() {
  local case_dir shared lease_a lease_b pool_a pool_b root_a root_b config_a config_b
  if ! command -v treehouse >/dev/null 2>&1; then
    printf 'ok - SKIP real-treehouse pool separation (treehouse not installed)\n'
    return 0
  fi
  case_dir=$(make_two_homes_one_project real-treehouse)
  shared="$case_dir/shared"
  mkdir -p "$shared"

  # Before: both clones point at one root, so treehouse pools them together.
  printf 'max_trees = 5\nroot = "%s"\n' "$shared" > "$case_dir/homeA/project/treehouse.toml"
  printf 'max_trees = 5\nroot = "%s"\n' "$shared" > "$case_dir/homeB/project/treehouse.toml"
  lease_a=$( cd "$case_dir/homeA/project" && treehouse get --lease 2>/dev/null )
  lease_b=$( cd "$case_dir/homeB/project" && treehouse get --lease 2>/dev/null )
  [ -n "$lease_a" ] && [ -n "$lease_b" ] || fail "treehouse did not lease a worktree to each clone"
  pool_a=$(dirname "$(dirname "$lease_a")")
  pool_b=$(dirname "$(dirname "$lease_b")")
  [ "$pool_a" = "$pool_b" ] \
    || fail "fixture did not reproduce the shared pool: $pool_a vs $pool_b"
  ( cd "$case_dir/homeA/project" && treehouse return --force "$lease_a" >/dev/null 2>&1 ) || true
  ( cd "$case_dir/homeB/project" && treehouse return --force "$lease_b" >/dev/null 2>&1 ) || true
  rm -f -- "$case_dir/homeA/project/treehouse.toml" "$case_dir/homeB/project/treehouse.toml"

  # After: each home uses an isolated user config and the pools no longer overlap.
  root_a=$(pool_root_for_home "$case_dir/homeA" "$case_dir/base" "$case_dir/homeA/project")
  root_b=$(pool_root_for_home "$case_dir/homeB" "$case_dir/base" "$case_dir/homeB/project")
  config_a=$(pool_config_view_for_home "$case_dir/homeA" "$case_dir/base" "$case_dir/homeA/project")
  config_b=$(pool_config_view_for_home "$case_dir/homeB" "$case_dir/base" "$case_dir/homeB/project")
  lease_a=$( cd "$config_a" && treehouse get --lease 2>/dev/null )
  lease_b=$( cd "$config_b" && treehouse get --lease 2>/dev/null )
  [ -n "$lease_a" ] && [ -n "$lease_b" ] || fail "treehouse did not lease from the per-home roots"
  case "$(cd "$(dirname "$lease_a")" && pwd -P)" in "$root_a"/*) ;;
    *) fail "the first home leased outside its own pool root: $lease_a" ;;
  esac
  case "$(cd "$(dirname "$lease_b")" && pwd -P)" in "$root_b"/*) ;;
    *) fail "the second home leased outside its own pool root: $lease_b" ;;
  esac
  ( cd "$case_dir/homeA/project" && treehouse return --force "$lease_a" >/dev/null 2>&1 ) || true
  ( cd "$case_dir/homeB/project" && treehouse return --force "$lease_b" >/dev/null 2>&1 ) || true
  pass "real treehouse pools two homes together until each claims its own root"
}

test_real_treehouse_accepts_encoded_pool_paths() {
  local case_dir special_base root config_home lease
  if ! command -v treehouse >/dev/null 2>&1; then
    printf 'ok - SKIP real-treehouse encoded pool path (treehouse not installed)\n'
    return 0
  fi
  case_dir=$(make_two_homes_one_project encoded-root)
  special_base="$case_dir/"$'pool"back\\slash\nline\177del'
  mkdir -p "$special_base"
  root=$(pool_root_for_home "$case_dir/homeA" "$special_base" "$case_dir/homeA/project") \
    || fail "fm-pool-root.sh rejected a valid filesystem path requiring TOML escapes"
  config_home=$(pool_config_view_for_home "$case_dir/homeA" "$special_base" "$case_dir/homeA/project")
  lease=$(cd "$config_home" && treehouse get --lease 2>/dev/null) \
    || fail "treehouse could not consume the safely encoded pool path"
  case "$lease" in "$root"/*) ;;
    *) fail "treehouse interpreted the encoded pool root differently: $lease" ;;
  esac
  treehouse return --force "$lease" >/dev/null 2>&1 || true
  pass "valid filesystem paths are encoded into Treehouse-consumable TOML"
}

# --- (b) a spawn never launches a second owner into one copy -----------------

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir fakebin pool_root pool_worktree
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$case_dir/home/data/$id" "$case_dir/home/projects" \
    "$case_dir/home/state" "$case_dir/home/config" "$case_dir/base"
  printf 'codex\n' > "$case_dir/home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$case_dir/home/data/$id/brief.md"
  touch "$case_dir/home/state/.last-watcher-beat"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_PANE_PATH:?}" ;;
esac
SH
  chmod +x "$fakebin/treehouse"

  fm_git_init_commit "$case_dir/upstream"
  git clone --quiet --bare "$case_dir/upstream" "$case_dir/origin.git"
  git clone --quiet "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin --auto >/dev/null 2>&1 || true
  pool_root=$(FM_HOME="$case_dir/home" FM_POOL_ROOT_BASE="$case_dir/base" \
    "$POOL_ROOT_BIN" --print)
  pool_worktree="$pool_root/.treehouse/fixture/1/project"
  mkdir -p "$(dirname "$pool_worktree")"
  git -C "$case_dir/project" worktree add --quiet --detach "$pool_worktree" HEAD
  ln -s "$pool_worktree" "$case_dir/pool"
  printf '%s\n' "$case_dir"
}

run_spawn_case() {  # <case-dir> <id> <args...>
  local case_dir=$1 id=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_PROJECTS_OVERRIDE="$case_dir/home/projects" FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_POOL_ROOT_BASE="$case_dir/base" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="${FM_CASE_PANE_PATH:-$case_dir/pool}" \
    FM_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" "$@" 2>&1
}

test_spawn_returns_a_lease_when_endpoint_confirmation_fails() {
  local case_dir id out status
  id='custody-unconfirmed-endpoint-r2'
  case_dir=$(make_spawn_case spawn-unconfirmed-endpoint "$id")
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
if [ "\${1:-}" = get ]; then
  printf '%s\n' "$case_dir/pool"
fi
SH
  chmod +x "$case_dir/fakebin/treehouse"
  cat > "$case_dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/sleep"

  out=$(FM_CASE_PANE_PATH="$case_dir/project" \
    run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "an unconfirmed endpoint must abort spawn"
  assert_contains "$out" "did not enter a worktree" \
    "the endpoint-confirmation failure was not reported"
  assert_grep "return --force $case_dir/pool" "$case_dir/treehouse.log" \
    "spawn leaked the acquired lease when endpoint confirmation failed"
  assert_absent "$case_dir/home/state/$id.meta" \
    "spawn published custody metadata for an unconfirmed endpoint"
  pass "an acquired lease is returned when endpoint confirmation fails"
}

test_spawn_defers_a_signal_until_acquired_lease_custody_is_armed() {
  local case_dir id out status wrapper
  id='custody-acquire-signal-r4'
  case_dir=$(make_spawn_case spawn-acquire-signal "$id")
  wrapper="$case_dir/spawn-wrapper"
  cat > "$wrapper" <<SH
#!/usr/bin/env bash
export FM_TEST_SPAWN_PID=\$\$
exec "$SPAWN" "\$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
if [ "\${1:-}" = get ]; then
  : > "$case_dir/lease-acquired"
  kill -TERM "\${FM_TEST_SPAWN_PID:?}"
  printf '%s\n' "$case_dir/pool"
fi
SH
  chmod +x "$wrapper" "$case_dir/fakebin/treehouse"

  out=$(SPAWN="$wrapper" run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the acquisition-boundary signal fixture did not stop spawn"
  assert_present "$case_dir/lease-acquired" "the signal fixture did not acquire a durable lease"
  assert_grep "return --force $case_dir/pool" "$case_dir/treehouse.log" \
    "spawn leaked a lease interrupted before its path reached the parent"
  assert_absent "$case_dir/home/state/$id.meta" \
    "spawn published custody metadata after an acquisition-boundary signal"
  pass "an acquisition-boundary signal returns the synchronously acquired lease"
}

test_spawn_refuses_a_copy_another_task_claims() {
  local case_dir id out status pool_head
  id='custody-claimed-r1'
  case_dir=$(make_spawn_case spawn-claimed "$id")
  # Another task of THIS home already owns that pooled copy and has unlanded work.
  fm_write_meta "$case_dir/home/state/other-task.meta" \
    "window=firstmate:fm-other-task" \
    "worktree=$case_dir/pool" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git -C "$case_dir/pool" checkout --quiet -b fm/other-task
  git -C "$case_dir/pool" commit -q --allow-empty -m "other task's unlanded work"
  pool_head=$(git -C "$case_dir/pool" rev-parse HEAD)

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "spawn should refuse a copy another task already claims: $out"
  assert_contains "$out" "task other-task claims" "the refusal did not name the claiming task"
  assert_absent "$case_dir/home/state/$id.meta" "a refused spawn still published task metadata"
  assert_no_grep 'get --lease' "$case_dir/treehouse.log" \
    "spawn asked Treehouse to recycle a copy already claimed by legacy metadata"
  [ "$(git -C "$case_dir/pool" rev-parse HEAD)" = "$pool_head" ] \
    || fail "the refused spawn reset the other task's copy before refusing"
  [ "$(git -C "$case_dir/pool" rev-parse --abbrev-ref HEAD)" = "fm/other-task" ] \
    || fail "the refused spawn moved the other task's copy off its branch"
  pass "a spawn refuses a pooled copy another task claims, leaving that copy untouched"
}

test_spawn_refuses_ambiguous_worktree_metadata() {
  local case_dir id out status pool_head
  id='custody-ambiguous-r1'
  case_dir=$(make_spawn_case spawn-ambiguous "$id")
  fm_write_meta "$case_dir/home/state/ambiguous-task.meta" \
    "window=firstmate:fm-ambiguous-task" \
    "worktree=$case_dir/not-this-copy" \
    "worktree=$case_dir/pool" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  git -C "$case_dir/pool" checkout --quiet -b fm/ambiguous-owner
  git -C "$case_dir/pool" commit -q --allow-empty -m "ambiguous owner's unlanded work"
  pool_head=$(git -C "$case_dir/pool" rev-parse HEAD)

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "spawn should fail closed on ambiguous worktree metadata"
  assert_contains "$out" "ambiguous worktree metadata" "the refusal did not identify the ambiguous ownership record"
  assert_absent "$case_dir/home/state/$id.meta" "ambiguous metadata still allowed a second owner record"
  assert_no_grep 'get --lease' "$case_dir/treehouse.log" \
    "ambiguous metadata was checked only after requesting a lease"
  [ "$(git -C "$case_dir/pool" rev-parse HEAD)" = "$pool_head" ] \
    || fail "ambiguous metadata allowed spawn to reset the claimed copy"
  [ "$(git -C "$case_dir/pool" rev-parse --abbrev-ref HEAD)" = "fm/ambiguous-owner" ] \
    || fail "ambiguous metadata allowed spawn to move the claimed copy"
  pass "spawn fails closed on ambiguous worktree metadata without touching the copy"
}

test_spawn_preserves_a_post_acquire_owner_conflict() {
  local case_dir id out status
  id='custody-racing-owner-r2'
  case_dir=$(make_spawn_case spawn-racing-owner "$id")
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
if [ "\${1:-}" = get ]; then
  printf '%s\n' \
    'window=firstmate:fm-racing-task' \
    'worktree=$case_dir/pool' \
    'project=$case_dir/project' \
    'kind=ship' \
    'mode=no-mistakes' \
    > "$case_dir/home/state/racing-task.meta"
  printf '%s\n' "$case_dir/pool"
fi
SH
  chmod +x "$case_dir/fakebin/treehouse"

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "a post-acquire owner conflict must refuse spawn"
  assert_contains "$out" "racing-task already claims" \
    "the post-acquire conflict did not identify its owner"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "the owner-conflict refusal returned and reset the contested lease"
  assert_absent "$case_dir/home/state/$id.meta" \
    "the owner-conflict refusal published a second custody record"
  pass "a post-acquire owner conflict preserves the contested lease"
}

test_spawn_does_not_return_a_published_lease_on_signal() {
  local case_dir id out status real_mv
  id='custody-published-signal-r3'
  case_dir=$(make_spawn_case spawn-published-signal "$id")
  real_mv=$(command -v mv)
  cat > "$case_dir/fakebin/mv" <<SH
#!/usr/bin/env bash
"$real_mv" "\$@" || exit \$?
case " \$* " in
  *" $case_dir/home/state/$id.meta ") kill -TERM "\$PPID" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/mv"

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the publication-boundary signal fixture did not stop spawn"
  assert_present "$case_dir/home/state/$id.meta" \
    "the signal fixture did not publish durable custody before stopping spawn"
  assert_grep "treehouse_lease_holder=$id" "$case_dir/home/state/$id.meta" \
    "the published record did not own the acquired durable lease"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "abort cleanup returned a lease after its custody record was published"
  pass "a signal after atomic publication cannot return the published lease"
}

test_fresh_spawn_refuses_an_existing_task_record_before_side_effects() {
  local case_dir id out status before after
  id='custody-existing-id-r1'
  case_dir=$(make_spawn_case spawn-existing-id "$id")
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/pool" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  before=$(cksum < "$case_dir/home/state/$id.meta")
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  new-window) touch "$case_dir/endpoint-created" ;;
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != get ] || touch "$case_dir/lease-requested"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  after=$(cksum < "$case_dir/home/state/$id.meta")
  expect_code 1 "$status" "a fresh spawn must refuse an existing task record"
  assert_contains "$out" "Use --relaunch" "the refusal did not name the supported reuse path"
  assert_absent "$case_dir/endpoint-created" "the refused fresh spawn created an endpoint"
  assert_absent "$case_dir/lease-requested" "the refused fresh spawn requested a worktree lease"
  [ "$before" = "$after" ] || fail "the refused fresh spawn overwrote existing task metadata"
  pass "a fresh spawn cannot replace an existing task record, endpoint, or lease"
}

test_spawn_claims_this_homes_pool_root_before_leasing() {
  local case_dir id out status config_home
  id='custody-own-pool-r1'
  case_dir=$(make_spawn_case spawn-own-pool "$id")

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an unclaimed pooled copy should still spawn"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "get --lease --lease-holder $id" "$case_dir/treehouse.log" \
    "spawn did not acquire its worktree as a durable task-labelled Treehouse lease"
  assert_grep "treehouse_lease_holder=$id" "$case_dir/home/state/$id.meta" \
    "spawn did not persist the durable lease identity with task custody metadata"
  config_home=$(pool_config_view_for_home "$case_dir/home" "$case_dir/base" "$case_dir/project")
  assert_present "$config_home/treehouse.toml" "spawn did not generate this home's Treehouse config"
  assert_absent "$case_dir/project/treehouse.toml" "spawn wrote Treehouse config into the primary clone"
  [ -z "$(git -C "$case_dir/project" status --porcelain)" ] \
    || fail "spawn dirtied the primary clone while selecting its pool"
  pass "a spawn selects this home's pool without mutating the primary clone"
}

# --- (d) delivered copies are released before a slot is requested ------------

# The project publishes the release step; the runner records that it ran, and
# reports <exit>.
add_release_step() {  # <case-dir> <exit>
  local case_dir=$1 exit_code=$2
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "pool:release-delivered": "node release.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  git -C "$case_dir/project" add package.json
  git -C "$case_dir/project" commit -qm "publish release housekeeping"
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = pool:release-delivered ]; then
  printf '%s\n' "\$PWD" > "$case_dir/release-run-dir.log"
  touch "\$PWD/release-artifact"
  printf '%s\\n' "\$*" >> "$case_dir/release.log"
  printf 'released 2 delivered copies\\n'
  exit $exit_code
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"
}

add_hanging_release_step() {  # <case-dir>
  local case_dir=$1
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "pool:release-delivered": "node release.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  git -C "$case_dir/project" add package.json
  git -C "$case_dir/project" commit -qm "publish hanging release housekeeping"
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = pool:release-delivered ]; then
  sleep 5
  touch "$case_dir/release-finished"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"
}

test_spawn_releases_delivered_copies_before_leasing() {
  local case_dir id out status run_dir
  id='custody-release-r1'
  case_dir=$(make_spawn_case spawn-release "$id")
  add_release_step "$case_dir" 0

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn should proceed after releasing delivered copies: $out"
  assert_present "$case_dir/release.log" "spawn never asked the project to release delivered copies"
  grep -qF -- '--yes' "$case_dir/release.log" \
    || fail "the release step was not run non-interactively"
  run_dir=$(cat "$case_dir/release-run-dir.log")
  [ "$run_dir" != "$case_dir/project" ] \
    || fail "the release step executed inside the primary clone"
  assert_absent "$case_dir/project/release-artifact" \
    "the release step mutated the primary clone"
  assert_absent "$run_dir" \
    "the authenticated release snapshot was not cleaned up"
  [ -z "$(git -C "$case_dir/project" status --porcelain)" ] \
    || fail "release housekeeping dirtied the primary clone"
  pass "a spawn runs release housekeeping from an authenticated isolated copy"
}

test_spawn_skips_projects_that_publish_no_release_step() {
  local case_dir id out status
  id='custody-no-release-r1'
  case_dir=$(make_spawn_case spawn-no-release "$id")
  cat > "$case_dir/fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm must not be invoked for a project without the release step\n' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/npm"

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a project without the release step should spawn unchanged: $out"
  assert_not_contains "$out" "must not be invoked" "spawn ran a release step the project never published"
  pass "a project that publishes no release step spawns exactly as before"
}

test_spawn_ignores_an_untracked_release_manifest() {
  local case_dir id out status
  id='custody-untracked-release-r1'
  case_dir=$(make_spawn_case spawn-untracked-release "$id")
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "pool:release-delivered": "node release.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
touch "$case_dir/release-ran"
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an untracked release manifest should not block spawn: $out"
  assert_absent "$case_dir/release-ran" "an untracked manifest activated housekeeping"
  assert_contains "$out" "spawned $id" "spawn did not continue after ignoring untracked housekeeping"
  pass "an untracked manifest cannot activate pool housekeeping"
}

test_spawn_continues_when_the_release_step_fails() {
  local case_dir id out status
  id='custody-release-fails-r1'
  case_dir=$(make_spawn_case spawn-release-fails "$id")
  add_release_step "$case_dir" 3

  out=$(run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "failed housekeeping must not block a dispatch: $out"
  assert_contains "$out" "pool:release-delivered failed" "a failed release step was not reported"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the failed release step"
  pass "a failed release step warns loudly and never blocks the dispatch"
}

test_spawn_bounds_a_hanging_release_step_without_external_timeout() {
  local case_dir id out status
  id='custody-release-timeout-r1'
  case_dir=$(make_spawn_case spawn-release-timeout "$id")
  add_hanging_release_step "$case_dir"

  out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_SPAWN_RELEASE_DELIVERED_TIMEOUT=1 \
    run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "timed-out housekeeping must not block a dispatch: $out"
  assert_contains "$out" "exit 124" "the hanging release step did not hit the shared deadline"
  assert_contains "$out" "spawned $id" "the spawn did not continue after the release deadline"
  assert_absent "$case_dir/release-finished" "the hanging release step escaped its deadline"
  pass "a hanging release step is bounded without timeout or gtimeout and spawn continues"
}

test_spawn_rejects_a_zero_equivalent_release_timeout() {
  local case_dir id out status
  id='custody-release-zero-timeout-r1'
  case_dir=$(make_spawn_case spawn-release-zero-timeout "$id")
  add_release_step "$case_dir" 0

  out=$(FM_SPAWN_RELEASE_DELIVERED_TIMEOUT=00 \
    run_spawn_case "$case_dir" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "invalid housekeeping configuration must not block a dispatch: $out"
  assert_contains "$out" "exit 125" "a zero-equivalent timeout was not rejected"
  assert_absent "$case_dir/release.log" "the release step ran with a disabled deadline"
  assert_contains "$out" "spawned $id" "the spawn did not continue after rejecting the zero timeout"
  pass "a zero-equivalent release timeout is rejected without blocking spawn"
}

# --- (c) cleanup refuses when the project says the copy is not ours ----------

make_teardown_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse tmux

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$case_dir/project" worktree add -q -b fm/task-c1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/task-c1.meta" \
    "window=firstmate:fm-task-c1" \
    "endpoint_task_id=task-c1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# The project publishes the check; <exit> is the verdict its runner reports.
add_custody_check() {  # <case-dir> <exit>
  local case_dir=$1 exit_code=$2
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  printf '%s\n' "$exit_code" > "$case_dir/project/custody.verdict"
  git -C "$case_dir/project" add package.json custody.verdict
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm "publish the custody check"
  git -C "$case_dir/project" push -q origin main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t merge -q main
  git -C "$case_dir/wt" push -q origin fm/task-c1
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = check:worktree-custody ]; then
  printf '%s\n' "\$PWD" > "$case_dir/custody-run-dir.log"
  printf '%s\n' "\$*" > "$case_dir/custody-args.log"
  printf 'pushed-not-merged: this copy is still delivering\n'
  exit "\$(cat "\$PWD/custody.verdict")"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"
}

run_teardown_case() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-c1 "$@" 2>&1
}

test_teardown_refuses_a_red_custody_verdict() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-red)
  add_custody_check "$case_dir" 1

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "cleanup should refuse a red custody verdict"
  assert_contains "$out" "check:worktree-custody" "the refusal did not name the project's check"
  assert_contains "$out" "pushed-not-merged" "the refusal did not relay what the check reported"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  [ -d "$case_dir/wt" ] || fail "a refused cleanup removed the working copy"
  pass "cleanup refuses when the project's custody check says the copy is not this task's"
}

test_forced_teardown_still_refuses_a_red_custody_verdict() {
  local case_dir out status run_dir
  case_dir=$(make_teardown_case teardown-custody-force-red)
  add_custody_check "$case_dir" 1
  printf '0\n' > "$case_dir/wt/custody.verdict"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  out=$(run_teardown_case "$case_dir" --force)
  status=$?
  expect_code 1 "$status" "forced cleanup should still refuse another owner's copy"
  assert_contains "$out" "check:worktree-custody" "the forced refusal did not name the project's check"
  assert_present "$case_dir/state/task-c1.meta" "forced custody refusal removed the task record"
  assert_absent "$case_dir/treehouse.log" "forced custody refusal returned the working copy"
  [ -d "$case_dir/wt" ] || fail "forced custody refusal removed the working copy"
  run_dir=$(cat "$case_dir/custody-run-dir.log")
  [ "$run_dir" != "$case_dir/wt" ] || fail "forced custody trusted the protected worktree's mutable check"
  [ "$(cat "$case_dir/custody-args.log")" = "run check:worktree-custody -- --worktree $case_dir/wt" ] \
    || fail "the canonical custody check did not receive the protected worktree path"
  assert_absent "$run_dir" "the authenticated custody snapshot was not cleaned up"
  pass "--force trusts canonical custody code, never the protected copy"
}

test_teardown_refuses_mutable_canonical_dependencies() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-mutable-dependency)
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  printf '%s\n' 'process.exit(require("custody-verdict"));' > "$case_dir/project/custody.js"
  git -C "$case_dir/project" add package.json custody.js
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t \
    commit -qm "publish dependency-backed custody check"
  git -C "$case_dir/project" push -q origin main
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t merge -q main
  git -C "$case_dir/wt" push -q origin fm/task-c1
  mkdir -p "$case_dir/project/node_modules/custody-verdict"
  printf '%s\n' 'module.exports = 0;' \
    > "$case_dir/project/node_modules/custody-verdict/index.js"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  out=$(NODE_PATH="$case_dir/project/node_modules" run_teardown_case "$case_dir" --force)
  status=$?
  expect_code 1 "$status" "mutable node_modules must not authorize destructive cleanup"
  assert_contains "$out" "check:worktree-custody says" "the unauthenticated dependency failure was not surfaced"
  assert_absent "$case_dir/treehouse.log" "mutable dependency code authorized a Treehouse return"
  assert_present "$case_dir/state/task-c1.meta" "mutable dependency code removed task ownership metadata"
  [ -d "$case_dir/wt" ] || fail "mutable dependency code removed the protected working copy"
  pass "canonical custody refuses rather than importing mutable node_modules"
}

test_teardown_refuses_a_worktree_only_custody_check() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-worktree-only)
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/wt/package.json"
  git -C "$case_dir/wt" add package.json
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm "publish only in mutable worktree"
  git -C "$case_dir/wt" push -q origin fm/task-c1
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
touch "$case_dir/unauthenticated-check-ran"
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"

  out=$(run_teardown_case "$case_dir" --force)
  status=$?
  expect_code 1 "$status" "a worktree-only custody check must not authorize destructive cleanup"
  assert_contains "$out" "cannot authenticate and execute" "the unauthenticated custody source was not reported"
  assert_absent "$case_dir/unauthenticated-check-ran" "teardown executed code from the protected worktree"
  assert_present "$case_dir/state/task-c1.meta" "unauthenticated custody removed the task record"
  [ -d "$case_dir/wt" ] || fail "unauthenticated custody removed the protected working copy"
  pass "a worktree-only custody check cannot authorize teardown"
}

test_forced_secondmate_cleanup_preflights_child_custody() {
  local case_dir home out status
  case_dir=$(make_teardown_case teardown-child-custody-force-red)
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-c1 > "$home/.fm-secondmate-home"
  fm_write_meta "$case_dir/state/task-c1.meta" \
    "window=firstmate:fm-task-c1" \
    "endpoint_task_id=task-c1" \
    "worktree=$home" \
    "home=$home" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=secondmate"
  fm_write_meta "$home/state/child-c1.meta" \
    "window=firstmate:fm-child-c1" \
    "endpoint_task_id=child-c1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  : > "$home/state/child-c1.status"
  add_custody_check "$case_dir" 1
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/endpoint.log"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  out=$(run_teardown_case "$case_dir" --force)
  status=$?
  expect_code 1 "$status" "forced secondmate cleanup should refuse a child owned elsewhere"
  assert_contains "$out" "child task child-c1 failed its custody check" "the refusal did not identify the protected child"
  assert_absent "$case_dir/endpoint.log" "child custody refusal closed an endpoint"
  assert_absent "$case_dir/treehouse.log" "child custody refusal returned a working copy"
  assert_present "$case_dir/state/task-c1.meta" "child custody refusal removed the parent record"
  assert_present "$home/state/child-c1.meta" "child custody refusal removed the child record"
  [ -d "$case_dir/wt" ] && [ -d "$home" ] \
    || fail "child custody refusal removed the child worktree or secondmate home"
  pass "forced secondmate cleanup validates every child before any mutation"
}

test_teardown_holds_task_set_lock_through_destructive_return() {
  local case_dir teardown_pid waited=0 spawn_out spawn_status teardown_status
  local endpoint_created=0 meta_published=0 teardown_alive=0
  case_dir=$(make_teardown_case teardown-spawn-race)
  add_custody_check "$case_dir" 0
  mkdir -p "$case_dir/home" "$case_dir/data/task-b" "$case_dir/projects" "$case_dir/base"
  printf 'brief for task-b\n' > "$case_dir/data/task-b/brief.md"
  printf 'codex\n' > "$case_dir/config/crew-harness"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$case_dir/endpoint.log"
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$case_dir/wt"; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
if [ "\${1:-}" = return ]; then
  : > "$case_dir/return-started"
  while [ ! -e "$case_dir/return-release" ]; do sleep 0.05; done
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  run_teardown_case "$case_dir" > "$case_dir/teardown.out" 2>&1 &
  teardown_pid=$!
  while [ ! -e "$case_dir/return-started" ] && kill -0 "$teardown_pid" 2>/dev/null \
      && [ "$waited" -lt 1200 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -e "$case_dir/return-started" ] || {
    : > "$case_dir/return-release"
    wait "$teardown_pid" 2>/dev/null || true
    fail "teardown never reached its destructive return boundary: $(cat "$case_dir/teardown.out")"
  }

  spawn_out=$(FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_PROJECTS_OVERRIDE="$case_dir/projects" FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_POOL_ROOT_BASE="$case_dir/base" FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" task-b "$case_dir/project" --mode no-mistakes --yolo off 2>&1)
  spawn_status=$?
  [ ! -e "$case_dir/endpoint.log" ] || endpoint_created=1
  [ ! -e "$case_dir/state/task-b.meta" ] || meta_published=1
  kill -0 "$teardown_pid" 2>/dev/null && teardown_alive=1

  : > "$case_dir/return-release"
  if wait "$teardown_pid"; then teardown_status=0; else teardown_status=$?; fi
  expect_code 1 "$spawn_status" "spawn should refuse while teardown owns the task set"
  assert_contains "$spawn_out" "task set is locked" "concurrent spawn did not refuse on the teardown's task-set lock"
  [ "$meta_published" -eq 0 ] || fail "concurrent spawn published metadata during destructive teardown"
  [ "$endpoint_created" -eq 0 ] || fail "concurrent spawn created an endpoint during destructive teardown"
  [ "$teardown_alive" -eq 1 ] || fail "teardown stopped holding the destructive boundary before the spawn refusal"
  expect_code 0 "$teardown_status" "serialized teardown should complete after return is released"
  pass "teardown holds the task-set lock through custody and destructive return"
}

test_teardown_proceeds_on_a_green_custody_verdict() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-green)
  add_custody_check "$case_dir" 0

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 0 "$status" "cleanup should proceed on a green custody verdict: $out"
  assert_absent "$case_dir/state/task-c1.meta" "a completed cleanup left the task record behind"
  pass "cleanup proceeds when the project's custody check reports the copy is free"
}

test_teardown_skips_projects_that_publish_no_check() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-absent)
  cat > "$case_dir/fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm must not be invoked for a project without the check\n' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/npm"

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 0 "$status" "a project without the check should tear down unchanged: $out"
  assert_not_contains "$out" "must not be invoked" "cleanup ran a check the project never published"
  pass "a project that publishes no custody check tears down exactly as before"
}

test_teardown_refuses_when_a_published_check_cannot_be_run() {
  local case_dir out status path_without_npm
  case_dir=$(make_teardown_case teardown-custody-unrunnable)
  add_custody_check "$case_dir" 0
  rm -f "$case_dir/fakebin/npm"
  # A PATH with no npm at all, so the published check cannot be answered.
  path_without_npm="$case_dir/fakebin"

  out=$(PATH="$path_without_npm:/usr/bin:/bin" run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "an unanswerable custody check should refuse, not pass silently"
  assert_contains "$out" "REFUSED" "the unanswerable check did not refuse loudly"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  pass "a published custody check that cannot be run refuses instead of tearing down"
}

test_teardown_uses_the_canonical_projects_custody_opt_in() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-canonical)
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  git -C "$case_dir/project" add package.json
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t \
    commit -qm "publish the custody check"
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = run ] && [ "\${2:-}" = check:worktree-custody ]; then
  printf 'old worktree cannot execute canonical custody check\n'
  exit 4
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/npm"

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "canonical opt-in must cover an older worktree"
  assert_contains "$out" "old worktree cannot execute" "cleanup did not attempt the canonical custody check in the old worktree"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  [ -d "$case_dir/wt" ] || fail "a refused cleanup removed the old working copy"
  pass "canonical custody opt-in protects an older worktree that cannot run the check"
}

test_teardown_refuses_an_unparseable_canonical_manifest() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-invalid-manifest)
  printf '{"scripts":{"check:worktree-custody":' > "$case_dir/project/package.json"
  git -C "$case_dir/project" add package.json

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "an unparseable canonical manifest must not be treated as absent"
  assert_contains "$out" "cannot confirm whether project" "the invalid manifest was not reported as unconfirmable"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  [ -d "$case_dir/wt" ] || fail "a refused cleanup removed the working copy"
  pass "an unparseable canonical manifest refuses cleanup instead of disabling custody"
}

test_teardown_detects_custody_hidden_by_a_working_edit() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-working-edit)
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  git -C "$case_dir/project" add package.json
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t \
    commit -qm "publish the custody check"
  printf '{\n  "name": "fixture",\n  "scripts": {}\n}\n' > "$case_dir/project/package.json"
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
printf 'published custody survives working manifest edit\n'
exit 4
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/npm" "$case_dir/fakebin/treehouse"

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "a working manifest edit must not hide published custody"
  assert_contains "$out" "published custody survives" "the published check was hidden by the working manifest"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  assert_absent "$case_dir/treehouse.log" "a working manifest edit allowed the copy to be returned"
  [ -d "$case_dir/wt" ] || fail "a refused cleanup removed the working copy"
  pass "a working manifest edit cannot hide custody published in Git"
}

test_teardown_refuses_a_missing_tracked_canonical_manifest() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-missing-tracked-manifest)
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  git -C "$case_dir/project" add package.json
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t \
    commit -qm "publish the custody check"
  rm "$case_dir/project/package.json"
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
printf 'missing working manifest cannot run published custody check\n'
exit 4
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/npm" "$case_dir/fakebin/treehouse"

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "a missing tracked canonical manifest must not disable custody"
  assert_contains "$out" "missing working manifest cannot run" "the tracked manifest was not detected from repository state"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  assert_absent "$case_dir/treehouse.log" "a missing tracked manifest allowed the copy to be returned"
  [ -d "$case_dir/wt" ] || fail "a refused cleanup removed the working copy"
  pass "a missing tracked canonical manifest remains a published custody opt-in"
}

test_teardown_detects_a_staged_deleted_canonical_manifest() {
  local case_dir out status
  case_dir=$(make_teardown_case teardown-custody-staged-deleted-manifest)
  printf '{\n  "name": "fixture",\n  "scripts": {\n    "check:worktree-custody": "node custody.js"\n  }\n}\n' \
    > "$case_dir/project/package.json"
  git -C "$case_dir/project" add package.json
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t \
    commit -qm "publish the custody check"
  git -C "$case_dir/project" rm -q package.json
  cat > "$case_dir/fakebin/npm" <<SH
#!/usr/bin/env bash
printf 'HEAD custody check survives staged manifest deletion\n'
exit 4
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/npm" "$case_dir/fakebin/treehouse"

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "a staged manifest deletion must not disable published custody"
  assert_contains "$out" "HEAD custody check survives" "the published check was not recovered from HEAD"
  assert_present "$case_dir/state/task-c1.meta" "a refused cleanup removed the task record"
  assert_absent "$case_dir/treehouse.log" "a staged manifest deletion allowed the copy to be returned"
  [ -d "$case_dir/wt" ] || fail "a refused cleanup removed the working copy"
  pass "a staged manifest deletion preserves the custody opt-in published by HEAD"
}

test_teardown_refuses_an_unavailable_canonical_project() {
  local case_dir missing_project out status
  case_dir=$(make_teardown_case teardown-custody-missing-project)
  missing_project="$case_dir/missing-project"
  fm_write_meta "$case_dir/state/task-c1.meta" \
    "window=firstmate:fm-task-c1" \
    "endpoint_task_id=task-c1" \
    "worktree=$case_dir/wt" \
    "project=$missing_project" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  out=$(run_teardown_case "$case_dir")
  status=$?
  expect_code 1 "$status" "an unavailable canonical project must refuse before cleanup"
  assert_contains "$out" "cannot confirm whether project $missing_project" "the unavailable canonical project was not reported as unconfirmable"
  assert_present "$case_dir/state/task-c1.meta" "an unavailable project removed the task record"
  assert_absent "$case_dir/treehouse.log" "an unavailable project allowed the copy to be returned"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = "fm/task-c1" ] \
    || fail "an unavailable canonical project detached the protected working copy"
  pass "an unavailable canonical project refuses cleanup before mutation"
}

test_two_homes_configure_distinct_pool_roots
test_legacy_hash_collision_homes_resolve_distinct_pool_roots
test_literal_pool_root_override_is_refused
test_pool_root_refuses_to_write_inside_the_primary_clone
test_relative_pool_root_base_is_refused_before_mutation
test_pool_root_is_idempotent_without_mutating_the_clone
test_pool_root_preserves_a_tracked_primary_config
test_pool_root_preserves_a_nonregular_primary_config
test_pool_root_verifies_the_written_config
test_pool_root_rolls_back_an_existing_view_on_verification_failure
test_real_treehouse_stops_sharing_a_pool_between_homes
test_real_treehouse_accepts_encoded_pool_paths
test_spawn_refuses_a_copy_another_task_claims
test_spawn_refuses_ambiguous_worktree_metadata
test_spawn_returns_a_lease_when_endpoint_confirmation_fails
test_spawn_defers_a_signal_until_acquired_lease_custody_is_armed
test_spawn_preserves_a_post_acquire_owner_conflict
test_spawn_does_not_return_a_published_lease_on_signal
test_fresh_spawn_refuses_an_existing_task_record_before_side_effects
test_spawn_claims_this_homes_pool_root_before_leasing
test_spawn_releases_delivered_copies_before_leasing
test_spawn_skips_projects_that_publish_no_release_step
test_spawn_ignores_an_untracked_release_manifest
test_spawn_continues_when_the_release_step_fails
test_spawn_bounds_a_hanging_release_step_without_external_timeout
test_spawn_rejects_a_zero_equivalent_release_timeout
test_teardown_refuses_a_red_custody_verdict
test_forced_teardown_still_refuses_a_red_custody_verdict
test_teardown_refuses_mutable_canonical_dependencies
test_teardown_refuses_a_worktree_only_custody_check
test_forced_secondmate_cleanup_preflights_child_custody
test_teardown_holds_task_set_lock_through_destructive_return
test_teardown_proceeds_on_a_green_custody_verdict
test_teardown_skips_projects_that_publish_no_check
test_teardown_refuses_when_a_published_check_cannot_be_run
test_teardown_uses_the_canonical_projects_custody_opt_in
test_teardown_refuses_an_unparseable_canonical_manifest
test_teardown_detects_custody_hidden_by_a_working_edit
test_teardown_refuses_a_missing_tracked_canonical_manifest
test_teardown_detects_a_staged_deleted_canonical_manifest
test_teardown_refuses_an_unavailable_canonical_project
