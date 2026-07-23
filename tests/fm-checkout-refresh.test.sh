#!/usr/bin/env bash
# Behavior tests for the checkout-refresh discovery, upstream signal, timed
# backstop, untracked skill-draft hygiene, safety posture, worktree freshness
# proof, and LaunchAgent definition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-checkout-refresh-tests)
TEST_HOME="$TMP_ROOT/user"
FM_TEST_HOME="$TMP_ROOT/fm-home"
STATE_ROOT="$TMP_ROOT/refresh-state"
LOCK_ROOT="$TMP_ROOT/refresh-locks"
mkdir -p "$TEST_HOME" "$FM_TEST_HOME/projects" "$FM_TEST_HOME/config" "$STATE_ROOT"

commit_file() {
  local dir=$1 file=$2 content=$3 message=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$message"
}

build_origin() {
  local work="$TMP_ROOT/work-$1" remote="$TMP_ROOT/remotes/$1.git" remote_abs
  mkdir -p "$TMP_ROOT/remotes"
  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd -P)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  printf '%s\n' "$remote_abs"
}

clone_from() {
  local remote=$1 destination=$2
  git clone --quiet "file://$remote" "$destination"
}

advance_origin() {
  local message=$2 work="$TMP_ROOT/work-$1"
  commit_file "$work" file.txt "$message" "$message"
  git -C "$work" push -q origin main
}

switch_origin_default() {
  local work="$TMP_ROOT/work-$1" remote="$TMP_ROOT/remotes/$1.git"
  git -C "$work" checkout -q -b trunk
  commit_file "$work" trunk.txt trunk default-trunk
  git -C "$work" push -q origin trunk
  git -C "$remote" symbolic-ref HEAD refs/heads/trunk
}

run_refresh() {
  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_CHECKOUT_REFRESH_LOCK_ROOT="$LOCK_ROOT" \
    FM_TREEHOUSE_ROOT="$TEST_HOME/.treehouse" \
    FM_CHECKOUT_REFRESH_TEST=1 \
    "$ROOT/bin/fm-checkout-refresh.sh" "$@"
}

assert_head_matches_origin() {
  local checkout=$1
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$(git -C "$checkout" rev-parse origin/main)" ] \
    || fail "$checkout did not reach origin/main"
}

test_discovery_covers_projects_treehouse_external_and_config() {
  local remote project external pool_worktree explicit_remote explicit custom_root scanned out
  remote=$(build_origin relvino)
  project="$FM_TEST_HOME/projects/relvino"
  external="$TEST_HOME/relvino"
  clone_from "$remote" "$project"
  clone_from "$remote" "$external"
  project=$(cd "$project" && pwd -P)
  external=$(cd "$external" && pwd -P)

  pool_worktree="$TEST_HOME/.treehouse/relvino-test/1/relvino"
  mkdir -p "$(dirname "$pool_worktree")"
  git -C "$project" worktree add --quiet --detach "$pool_worktree" main
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$pool_worktree" \
    > "$TEST_HOME/.treehouse/relvino-test/treehouse-state.json"

  explicit_remote=$(build_origin explicit)
  explicit="$TMP_ROOT/explicit-checkout"
  clone_from "$explicit_remote" "$explicit"
  custom_root="$TMP_ROOT/custom-scan"
  scanned="$custom_root/relvino-copy"
  mkdir -p "$custom_root"
  clone_from "$remote" "$scanned"
  explicit=$(cd "$explicit" && pwd -P)
  scanned=$(cd "$scanned" && pwd -P)
  {
    printf 'path %s\n' "$explicit"
    printf 'scan %s\n' "$custom_root"
  } > "$FM_TEST_HOME/config/checkout-refresh"

  out=$(run_refresh discover)

  assert_contains "$out" "$project" "projects/ checkout was not discovered"
  assert_contains "$out" "$external" "matching-origin top-level clone was not discovered"
  assert_contains "$out" "$explicit" "configured checkout path was not discovered"
  assert_contains "$out" "$scanned" "configured shallow scan root was not discovered"
  assert_not_contains "$out" "$pool_worktree" "Treehouse pool worktree was treated as a mutable backing checkout"
  [ "$(printf '%s\n' "$out" | grep -Fxc "$project")" -eq 1 ] \
    || fail "Treehouse backing checkout was not deduplicated with projects/ checkout"
  pass "discovery covers projects, Treehouse backing checkouts, matching-origin clones, and config"
}

test_uninspectable_active_project_invalidates_heartbeat() {
  local project out status
  project="$FM_TEST_HOME/projects/relvino"
  chmod 000 "$project"
  printf '%s\n' preserved-project-heartbeat > "$STATE_ROOT/heartbeat"

  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  chmod 700 "$project"

  [ "$status" -ne 0 ] || fail "uninspectable active-home project reported healthy coverage"
  assert_contains "$out" "incomplete active-home project coverage at $project" \
    "uninspectable active-home project was not surfaced"
  [ "$(cat "$STATE_ROOT/heartbeat")" = preserved-project-heartbeat ] \
    || fail "uninspectable active-home project advanced the healthy heartbeat"
  pass "uninspectable active-home projects invalidate heartbeat health"
}

test_nested_active_project_invalidates_heartbeat() {
  local container projects nested nested_state out status
  container="$TMP_ROOT/active-project-container"
  fm_git_init_commit "$container"
  projects="$container/projects"
  nested="$projects/nested-directory"
  nested_state="$TMP_ROOT/nested-active-state"
  mkdir -p "$nested" "$nested_state"
  printf '%s\n' preserved-nested-heartbeat > "$nested_state/heartbeat"

  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_PROJECTS_OVERRIDE="$projects" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$nested_state" \
    FM_CHECKOUT_REFRESH_LOCK_ROOT="$TMP_ROOT/nested-active-locks" \
    FM_TREEHOUSE_ROOT="$TMP_ROOT/nested-active-treehouse" \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "nested non-repository active project reported healthy coverage"
  assert_contains "$out" "active-home project is not an exact inspectable Git repository root: $nested" \
    "nested non-repository active project was not surfaced"
  [ "$(cat "$nested_state/heartbeat")" = preserved-nested-heartbeat ] \
    || fail "nested non-repository active project advanced the healthy heartbeat"
  pass "active projects must be exact canonical Git repository roots"
}

test_upstream_tip_signal_refreshes_between_firstmate_events() {
  local project external remote out
  project="$FM_TEST_HOME/projects/relvino"
  external="$TEST_HOME/relvino"
  remote=$(git -C "$project" remote get-url origin)
  : "$remote"

  run_refresh run-once --force >/dev/null
  advance_origin relvino C1
  out=$(run_refresh run-once)

  assert_contains "$out" "synced" "upstream-tip change did not trigger a refresh"
  assert_head_matches_origin "$project"
  assert_head_matches_origin "$external"
  pass "any observed upstream default-tip change refreshes all covered clones"
}

test_periodic_backstop_repairs_drift_without_a_new_tip() {
  local external="$TEST_HOME/relvino" prior
  prior=$(git -C "$external" rev-parse HEAD^)
  git -C "$external" reset --hard -q "$prior"
  find "$STATE_ROOT" -type f -name '*.last' -exec sh -c 'printf "0\n" > "$1"' _ {} \;

  run_refresh run-once >/dev/null

  assert_head_matches_origin "$external"
  pass "periodic backstop repairs local drift even when the observed upstream tip is unchanged"
}

test_live_default_change_is_surfaced_without_switching_branches() {
  local project before out
  project=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  before=$(git -C "$project" rev-parse HEAD)
  switch_origin_default relvino

  out=$(run_refresh run-once --force)

  assert_contains "$out" "relvino: STUCK: on branch main" \
    "a live upstream default-branch change was not surfaced as an unsafe checkout"
  [ "$(git -C "$project" rev-parse HEAD)" = "$before" ] \
    || fail "default-branch change moved the checkout"
  [ "$(git -C "$project" branch --show-current)" = main ] \
    || fail "default-branch change switched the checkout"
  pass "live default-branch changes are excluded and surfaced without mutation"
}

test_skill_drafts_surface_on_every_probe_without_log_spam() {
  local project draft_one draft_two out key alert status
  project=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  draft_one="$project/.agents/skills/local-one/SKILL.md"
  draft_two="$project/skills/local-two/SKILL.md"
  mkdir -p "$(dirname "$draft_one")" "$(dirname "$draft_two")"
  printf '%s\n' '# local one' > "$draft_one"

  out=$(run_refresh run-once)
  assert_contains "$out" "HYGIENE: 1 untracked skill-draft files" \
    "a new untracked skill draft was not surfaced between refresh events"
  assert_contains "$out" ".agents/skills/local-one/SKILL.md" \
    "the hygiene alert did not identify the draft"
  grep -Fq '# local one' "$draft_one" || fail "hygiene probe changed an untracked draft"

  out=$(run_refresh run-once)
  assert_not_contains "$out" "HYGIENE:" \
    "an unchanged hygiene inventory was repeatedly logged by the background probe"

  printf '%s\n' '# local two' > "$draft_two"
  out=$(run_refresh run-once)
  assert_contains "$out" "HYGIENE: 2 untracked skill-draft files" \
    "growth in the untracked skill-draft inventory was not surfaced"

  set +e
  out=$(run_refresh preflight "$project")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn preflight accepted a checkout containing untracked drafts"
  assert_contains "$out" "HYGIENE: 2 untracked skill-draft files" \
    "spawn preflight did not repeat the unresolved hygiene alert"

  out=$(run_refresh run-once --force --verbose)
  assert_contains "$out" "HYGIENE: 2 untracked skill-draft files" \
    "an operator-visible forced refresh did not repeat the unresolved hygiene alert"
  assert_contains "$out" "STUCK:" \
    "the safe refresh did not refuse the checkout containing untracked drafts"
  assert_contains "$out" "2 untracked, 2 under repository skill directories" \
    "the safe refresh did not quantify untracked skill drafts"
  grep -Fq '# local one' "$draft_one" || fail "safe refresh discarded the first draft"
  grep -Fq '# local two' "$draft_two" || fail "safe refresh discarded the second draft"

  key=$(printf '%s' "$project" | shasum -a 256 | awk '{print substr($1,1,24)}')
  alert="$STATE_ROOT/$key.hygiene-alert"
  [ -f "$alert" ] || fail "the unresolved hygiene alert was not persisted"
  rm -rf "$project/.agents" "$project/skills"
  run_refresh run-once >/dev/null
  [ ! -e "$alert" ] || fail "the hygiene alert did not clear after drafts were reconciled"
  pass "skill-draft accumulation surfaces promptly, persists, and never changes draft contents"
}

test_preflight_rejects_hygiene_without_an_origin() {
  local checkout="$TMP_ROOT/no-origin-checkout" draft out status
  fm_git_init_commit "$checkout"
  draft="$checkout/.agents/skills/local-only/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# local only' > "$draft"

  set +e
  out=$(run_refresh preflight "$checkout")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "preflight accepted untracked skill drafts in a no-origin checkout"
  assert_contains "$out" "HYGIENE: 1 untracked skill-draft files" \
    "no-origin preflight swallowed its hygiene finding"
  grep -Fq '# local only' "$draft" || fail "no-origin preflight changed the draft"
  pass "preflight treats hygiene as actionable independently of sync eligibility"
}

test_treehouse_pool_skill_drafts_are_inventoried() {
  local pool_worktree draft out key alert
  pool_worktree="$TEST_HOME/.treehouse/relvino-test/1/relvino"
  pool_worktree=$(cd "$pool_worktree" && pwd -P)
  draft="$pool_worktree/.agents/skills/pool-draft/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# pool draft' > "$draft"

  out=$(run_refresh run-once)
  assert_contains "$out" "$pool_worktree: HYGIENE: 1 untracked skill-draft files" \
    "an untracked draft in a Treehouse pool worktree was not surfaced"
  grep -Fq '# pool draft' "$draft" || fail "pool hygiene inventory changed the draft"

  key=$(printf '%s' "$pool_worktree" | shasum -a 256 | awk '{print substr($1,1,24)}')
  alert="$STATE_ROOT/$key.hygiene-alert"
  [ -f "$alert" ] || fail "the pool-worktree hygiene alert was not persisted"
  rm -rf "$pool_worktree/.agents"
  run_refresh run-once >/dev/null
  [ ! -e "$alert" ] || fail "the pool-worktree hygiene alert did not clear"
  pass "Treehouse pool worktrees participate in skill-draft hygiene detection"
}

test_ignored_skill_files_are_outside_the_collision_guard() {
  local source="$TMP_ROOT/ignored-source" worktree="$TMP_ROOT/ignored-worktree" draft out
  fm_git_worktree "$source" "$worktree" ignored-skill
  git -C "$worktree" checkout --quiet --detach
  printf '%s\n' '.agents/skills/' >> "$source/.git/info/exclude"
  draft="$worktree/.agents/skills/intentional/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# intentional ignored material' > "$draft"

  run_refresh verify-worktree "$worktree" "$source" \
    || fail "an ignored skill file made a clean local acquisition fail"
  out=$(run_refresh preflight "$worktree") \
    || fail "preflight rejected an acquisition containing only ignored skill material"
  assert_not_contains "$out" "HYGIENE:" \
    "ignored skill material entered the untracked-draft collision inventory"
  grep -Fq '# intentional ignored material' "$draft" \
    || fail "ignored skill-file inspection changed its contents"
  pass "gitignored skill files remain outside the non-ignored collision guard"
}

test_pool_preflight_surfaces_dirty_worktrees_without_blocking_clean_selection() {
  local project pool_worktree before out
  project=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  pool_worktree="$TEST_HOME/.treehouse/relvino-test/1/relvino"
  pool_worktree=$(cd "$pool_worktree" && pwd -P)
  before=$(cat "$pool_worktree/file.txt")
  printf '%s\n' dirty-pool-change >> "$pool_worktree/file.txt"

  out=$(run_refresh pool-preflight "$project" 2>&1) \
    || fail "inspectable dirty pool entries should remain skippable while another clean entry may be selected"
  assert_contains "$out" "$pool_worktree: skipped: dirty Treehouse pool worktree remains unavailable for acquisition" \
    "pre-acquisition pool inspection did not surface the dirty entry"
  grep -Fq dirty-pool-change "$pool_worktree/file.txt" \
    || fail "pool preflight changed the dirty worktree"
  printf '%s\n' "$before" > "$pool_worktree/file.txt"
  pass "pool preflight surfaces dirty entries and leaves them unavailable untouched"
}

test_bootstrap_relays_hygiene_alerts() {
  local project draft out config_backup config_real
  project=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  draft="$project/.agents/skills/bootstrap-draft/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# bootstrap draft' > "$draft"
  config_backup=$(mktemp "$TMP_ROOT/checkout-refresh-config.XXXXXX")
  cp "$FM_TEST_HOME/config/checkout-refresh" "$config_backup"
  printf '%s\n' 'unexpected directive' >> "$FM_TEST_HOME/config/checkout-refresh"

  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_TREEHOUSE_ROOT="$TEST_HOME/.treehouse" \
    FM_CHECKOUT_REFRESH_BOOTSTRAP_TEST=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  mv "$config_backup" "$FM_TEST_HOME/config/checkout-refresh"

  assert_contains "$out" "FLEET_SYNC: $project: HYGIENE: 1 untracked skill-draft files" \
    "session-start bootstrap did not relay the unresolved hygiene alert"
  assert_contains "$out" "FLEET_SYNC: checkout-refresh: skipped: unknown config directive 'unexpected'" \
    "session-start bootstrap swallowed checkout discovery diagnostics"

  config_real="$TMP_ROOT/checkout-refresh-real"
  mv "$FM_TEST_HOME/config/checkout-refresh" "$config_real"
  ln -s "$config_real" "$FM_TEST_HOME/config/checkout-refresh"
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_TREEHOUSE_ROOT="$TEST_HOME/.treehouse" \
    FM_CHECKOUT_REFRESH_BOOTSTRAP_TEST=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  rm "$FM_TEST_HOME/config/checkout-refresh"
  mv "$config_real" "$FM_TEST_HOME/config/checkout-refresh"
  assert_contains "$out" "FLEET_SYNC: checkout-refresh: skipped: unsafe symlink config" \
    "session-start bootstrap suppressed the unsafe configuration warning"
  grep -Fq '# bootstrap draft' "$draft" || fail "bootstrap refresh changed the draft"
  rm -rf "$project/.agents"
  run_refresh run-once >/dev/null
  pass "session-start bootstrap relays hygiene and discovery diagnostics"
}

test_treehouse_discovery_failure_invalidates_heartbeat() {
  local treehouse_root pool_dir bad_state missing_path="$TMP_ROOT/missing-treehouse-worktree" out status
  treehouse_root=$(cd "$TEST_HOME/.treehouse" && pwd -P)
  pool_dir="$treehouse_root/relvino-test"
  bad_state="$treehouse_root/broken/treehouse-state.json"
  mkdir -p "$(dirname "$bad_state")"
  printf '%s\n' '{"worktrees":[' > "$bad_state"
  printf '%s\n' preserved-heartbeat > "$STATE_ROOT/heartbeat"

  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "malformed Treehouse state reported healthy checkout coverage"
  assert_contains "$out" "incomplete Treehouse coverage at $bad_state" \
    "malformed Treehouse state was not surfaced"
  [ "$(cat "$STATE_ROOT/heartbeat")" = preserved-heartbeat ] \
    || fail "malformed Treehouse state advanced the healthy heartbeat"

  printf '%s\n' '{}' > "$bad_state"
  printf '%s\n' preserved-schema-heartbeat > "$STATE_ROOT/heartbeat"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Treehouse state without a worktrees field reported healthy coverage"
  assert_contains "$out" "worktrees is required" \
    "missing Treehouse worktrees schema was not surfaced"
  [ "$(cat "$STATE_ROOT/heartbeat")" = preserved-schema-heartbeat ] \
    || fail "missing Treehouse worktrees schema advanced the healthy heartbeat"

  printf '{"worktrees":[{"path":"%s"}]}\n' "$missing_path" > "$bad_state"
  printf '%s\n' preserved-path-heartbeat > "$STATE_ROOT/heartbeat"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "uninspectable declared Treehouse worktree reported healthy coverage"
  assert_contains "$out" "Treehouse worktree is not inspectable: $missing_path" \
    "uninspectable declared Treehouse worktree was not surfaced"
  [ "$(cat "$STATE_ROOT/heartbeat")" = preserved-path-heartbeat ] \
    || fail "uninspectable Treehouse path advanced the healthy heartbeat"
  rm -rf "$(dirname "$bad_state")"

  chmod 000 "$treehouse_root"
  printf '%s\n' preserved-root-heartbeat > "$STATE_ROOT/heartbeat"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  chmod 700 "$treehouse_root"
  [ "$status" -ne 0 ] || fail "unreadable Treehouse root reported healthy coverage"
  assert_contains "$out" "Treehouse root is unreadable" \
    "unreadable Treehouse root was not surfaced"
  [ "$(cat "$STATE_ROOT/heartbeat")" = preserved-root-heartbeat ] \
    || fail "unreadable Treehouse root advanced the healthy heartbeat"

  chmod 000 "$pool_dir"
  printf '%s\n' preserved-pool-heartbeat > "$STATE_ROOT/heartbeat"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  chmod 700 "$pool_dir"
  [ "$status" -ne 0 ] || fail "unreadable Treehouse pool reported healthy coverage"
  assert_contains "$out" "Treehouse pool is unreadable" \
    "unreadable Treehouse pool was not surfaced"
  [ "$(cat "$STATE_ROOT/heartbeat")" = preserved-pool-heartbeat ] \
    || fail "unreadable Treehouse pool advanced the healthy heartbeat"
  pass "unreadable roots, malformed schemas, and uninspectable paths invalidate heartbeat health"
}

test_skill_inventory_failure_preserves_alert_and_heartbeat() {
  local project draft key alert prior fakebin real_git out status
  project=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  draft="$project/.agents/skills/inventory-failure/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# retained draft' > "$draft"
  run_refresh run-once >/dev/null
  key=$(printf '%s' "$project" | shasum -a 256 | awk '{print substr($1,1,24)}')
  alert="$STATE_ROOT/$key.hygiene-alert"
  [ -f "$alert" ] || fail "inventory-failure setup did not persist a hygiene alert"
  prior=$(cat "$alert")
  printf '%s\n' preserved-inventory-heartbeat > "$STATE_ROOT/heartbeat"
  fakebin="$TMP_ROOT/inventory-fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-}" = ls-files ]; then
  exit 74
fi
exec "${FM_TEST_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"

  set +e
  out=$(FM_TEST_REAL_GIT="$real_git" PATH="$fakebin:$PATH" run_refresh run-once --force 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "skill inventory failure reported healthy coverage"
  assert_contains "$out" "HYGIENE: inventory failed - preserving the prior alert" \
    "skill inventory failure was not surfaced"
  [ "$(cat "$alert")" = "$prior" ] || fail "skill inventory failure changed the prior alert"
  [ "$(cat "$STATE_ROOT/heartbeat")" = preserved-inventory-heartbeat ] \
    || fail "skill inventory failure advanced the healthy heartbeat"
  rm -rf "$fakebin" "$project/.agents"
  run_refresh run-once >/dev/null
  pass "skill inventory failures preserve alerts and invalidate heartbeat health"
}

test_dirty_nondefault_and_diverged_checkouts_are_untouched() {
  local remote dirty feature diverged dirty_head feature_head diverged_head out
  remote=$(build_origin safety)
  dirty="$FM_TEST_HOME/projects/safety-dirty"
  feature="$FM_TEST_HOME/projects/safety-feature"
  diverged="$FM_TEST_HOME/projects/safety-diverged"
  clone_from "$remote" "$dirty"
  clone_from "$remote" "$feature"
  clone_from "$remote" "$diverged"
  printf 'uncommitted\n' >> "$dirty/file.txt"
  git -C "$feature" checkout -q -b feature
  commit_file "$diverged" local.txt local local-divergence
  dirty_head=$(git -C "$dirty" rev-parse HEAD)
  feature_head=$(git -C "$feature" rev-parse HEAD)
  diverged_head=$(git -C "$diverged" rev-parse HEAD)
  advance_origin safety C1

  out=$(run_refresh run-once --force)

  assert_contains "$out" "safety-dirty: STUCK:" "dirty checkout did not surface STUCK"
  assert_contains "$out" "safety-feature: STUCK:" "non-default checkout did not surface STUCK"
  assert_contains "$out" "safety-diverged: STUCK:" "diverged checkout did not surface STUCK"
  [ "$(git -C "$dirty" rev-parse HEAD)" = "$dirty_head" ] || fail "dirty checkout HEAD moved"
  [ "$(git -C "$feature" rev-parse HEAD)" = "$feature_head" ] || fail "feature checkout HEAD moved"
  [ "$(git -C "$diverged" rev-parse HEAD)" = "$diverged_head" ] || fail "diverged checkout HEAD moved"
  grep -Fq uncommitted "$dirty/file.txt" || fail "dirty checkout contents were discarded"
  [ "$(git -C "$feature" branch --show-current)" = feature ] || fail "feature checkout branch changed"
  pass "background refresh preserves and surfaces dirty, non-default, and diverged work"
}

test_refresh_locks_recover_stale_owners_and_surface_contention() {
  local run_lock="$STATE_ROOT/.run-lock" checkout common key checkout_lock alias out
  mkdir -p "$run_lock"
  touch -t 200001010000 "$run_lock"

  out=$(run_refresh run-once --force)
  assert_not_contains "$out" "refresh already running" \
    "an abandoned ownerless run lock was not recovered"
  [ ! -e "$run_lock" ] || fail "recovered run lock was not released"

  mkdir -p "$run_lock"
  printf '%s\n' "$$" > "$run_lock/pid"
  out=$(run_refresh run-once --force)
  assert_contains "$out" "checkout-refresh: skipped: refresh already running (pid $$)" \
    "live run-lock contention was silent"
  rm -rf "$run_lock"

  checkout=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  common=$(git -C "$checkout" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$checkout/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  key=$(printf '%s' "$common" | shasum -a 256 | awk '{print substr($1,1,24)}')
  checkout_lock="$LOCK_ROOT/$key.lock"
  mkdir -p "$checkout_lock"
  printf '%s\n' "$$" > "$checkout_lock/pid"
  out=$(run_refresh run-once --force)
  assert_contains "$out" "$checkout: skipped: refresh already running (pid $$)" \
    "shared-checkout lock contention was not surfaced"
  alias="$TMP_ROOT/relvino-checkout-alias"
  ln -s "$checkout" "$alias"
  out=$(run_refresh preflight "$alias") || true
  assert_contains "$out" "$alias: skipped: refresh already running (pid $$)" \
    "a symlink alias bypassed the canonical repository lock"
  rm -rf "$checkout_lock"
  pass "refresh locks recover abandoned owners and serialize every checkout alias"
}

test_session_mode_preserves_gone_branch_pruning() {
  local remote work project
  remote=$(build_origin prune)
  work="$TMP_ROOT/work-prune"
  git -C "$work" checkout -q -b merged
  commit_file "$work" merged.txt merged merged
  git -C "$work" push -q -u origin merged
  git -C "$work" checkout -q main
  project="$FM_TEST_HOME/projects/prune"
  clone_from "$remote" "$project"
  git -C "$project" checkout -q -b merged --track origin/merged
  git -C "$project" checkout -q main
  git -C "$work" push -q origin --delete merged

  run_refresh run-once --force >/dev/null
  git -C "$project" show-ref --verify --quiet refs/heads/merged \
    || fail "cadence refresh pruned a gone branch"

  run_refresh run-once --force --session >/dev/null
  if git -C "$project" show-ref --verify --quiet refs/heads/merged; then
    fail "session refresh did not preserve gone-branch pruning"
  fi
  pass "session mode preserves pruning while cadence mode disables it"
}

test_worktree_freshness_verification_fails_closed() {
  local remote primary worktree unrelated local_source local_worktree before status dirty tip
  remote=$(build_origin verify)
  primary="$TMP_ROOT/verify-primary"
  worktree="$TMP_ROOT/verify-worktree"
  clone_from "$remote" "$primary"
  before=$(git -C "$primary" rev-parse HEAD)
  git -C "$primary" worktree add --quiet --detach "$worktree" "$before"
  advance_origin verify C1

  set +e
  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" \
    "$ROOT/bin/fm-checkout-refresh.sh" verify-worktree "$worktree" "$primary" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "stale acquired worktree passed freshness verification"

  git -C "$primary" fetch -q origin
  git -C "$worktree" checkout --quiet --detach origin/main
  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" \
    "$ROOT/bin/fm-checkout-refresh.sh" verify-worktree "$worktree" "$primary" \
    || fail "fresh acquired worktree failed verification"
  tip=$(git -C "$worktree" rev-parse HEAD)
  run_refresh verify-returnable "$worktree" "$primary" "$tip" \
    || fail "unchanged detached acquisition failed return-safety verification"
  git -C "$worktree" switch --quiet -c return-unsafe
  set +e
  run_refresh verify-returnable "$worktree" "$primary" "$tip" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an attached acquired worktree passed return-safety verification"
  git -C "$worktree" checkout --quiet --detach "$tip"

  unrelated="$TMP_ROOT/verify-unrelated"
  fm_git_init_commit "$unrelated"
  set +e
  run_refresh verify-worktree "$unrelated" "$primary" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "an unrelated repository passed worktree identity verification"

  local_source="$TMP_ROOT/verify-local-source"
  local_worktree="$TMP_ROOT/verify-local-worktree"
  fm_git_worktree "$local_source" "$local_worktree" local-acquisition
  git -C "$local_worktree" checkout --quiet --detach
  run_refresh verify-worktree "$local_worktree" "$local_source" \
    || fail "clean remote-free worktree failed its local default-tip proof"
  commit_file "$local_source" local.txt advanced advance-local-default
  set +e
  run_refresh verify-worktree "$local_worktree" "$local_source" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "stale remote-free worktree passed its local default-tip proof"

  git -C "$local_worktree" reset --hard -q "$(git -C "$local_source" rev-parse HEAD)"
  dirty="$local_worktree/.agents/skills/retained/SKILL.md"
  mkdir -p "$(dirname "$dirty")"
  printf '%s\n' '# retain me' > "$dirty"
  set +e
  run_refresh verify-worktree "$local_worktree" "$local_source" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 3 ] || fail "dirty acquired worktree did not return the retain-only status"
  grep -Fq '# retain me' "$dirty" || fail "dirty worktree verification changed its draft"
  pass "acquisition proof validates repository identity, local freshness, and cleanliness"
}

test_bounded_refresh_terminates_descendants() {
  local remote checkout fakebin real_git out status parent_pid child_pid
  remote=$(build_origin bounded)
  checkout="$FM_TEST_HOME/projects/bounded"
  clone_from "$remote" "$checkout"
  fakebin="$TMP_ROOT/bounded-fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-}" = fetch ]; then
  trap '' TERM
  printf '%s\n' "$BASHPID" > "${FM_TEST_FETCH_PARENT:?}"
  (
    trap '' TERM
    printf '%s\n' "$BASHPID" > "${FM_TEST_FETCH_CHILD:?}"
    while :; do sleep 1; done
  ) &
  wait
fi
exec "${FM_TEST_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"

  set +e
  out=$(FM_TEST_REAL_GIT="$real_git" FM_TEST_FETCH_PARENT="$TMP_ROOT/fetch-parent.pid" \
    FM_TEST_FETCH_CHILD="$TMP_ROOT/fetch-child.pid" FM_CHECKOUT_REFRESH_SYNC_TIMEOUT=1 \
    PATH="$fakebin:$PATH" run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "bounded refresh command failed unexpectedly: $out"
  assert_contains "$out" "refresh timed out after 1s" \
    "bounded refresh did not report its timeout"
  parent_pid=$(cat "$TMP_ROOT/fetch-parent.pid")
  child_pid=$(cat "$TMP_ROOT/fetch-child.pid")
  if kill -0 "$parent_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then
    fail "bounded refresh returned while a fetch descendant was still alive"
  fi
  rm -rf "$fakebin" "$checkout"
  pass "bounded refresh terminates and reaps its complete descendant tree"
}

test_acquisition_honors_shared_checkout_lock() {
  local source fakebin common key lock out status marker
  source="$TMP_ROOT/acquisition-lock-source"
  fakebin="$TMP_ROOT/acquisition-lock-fakebin"
  marker="$TMP_ROOT/acquisition-lock-called"
  fm_git_init_commit "$source"
  mkdir -p "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
touch "${FM_TEST_TREEHOUSE_CALLED:?}"
printf '%s\n' "$PWD/acquired"
SH
  chmod +x "$fakebin/treehouse"
  common=$(git -C "$source" rev-parse --git-common-dir)
  case "$common" in /*) ;; *) common="$source/$common" ;; esac
  common=$(cd "$common" && pwd -P)
  key=$(printf '%s' "$common" | shasum -a 256 | awk '{print substr($1,1,24)}')
  lock="$LOCK_ROOT/$key.lock"
  mkdir -p "$lock"
  printf '%s\n' "$$" > "$lock/pid"

  set +e
  out=$(FM_TEST_TREEHOUSE_CALLED="$marker" PATH="$fakebin:$PATH" \
    run_refresh acquire-worktree "$source" firstmate-lock-test 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "Treehouse acquisition bypassed the shared checkout lock"
  assert_contains "$out" "Treehouse acquisition already running for $source (pid $$)" \
    "contended Treehouse acquisition did not identify the shared lock owner"
  [ ! -e "$marker" ] || fail "Treehouse ran while the shared checkout lock was held"
  rm -rf "$lock"
  pass "Treehouse acquisition serializes through the common Git lock"
}

test_launch_agent_definition_is_home_scoped_with_scheduler_seam() {
  local fakebin agents log plist second_home second_plist key second_key install_state_base install_state_root
  local custom_treehouse="$TMP_ROOT/custom-treehouse" other_treehouse="$TMP_ROOT/other-treehouse" out status
  fakebin="$TMP_ROOT/fakebin"
  agents="$TMP_ROOT/LaunchAgents"
  log="$TMP_ROOT/launchctl.log"
  install_state_base="$TMP_ROOT/install-state"
  mkdir -p "$fakebin" "$agents" "$custom_treehouse" "$other_treehouse"
  custom_treehouse=$(cd "$custom_treehouse" && pwd -P)
  other_treehouse=$(cd "$other_treehouse" && pwd -P)
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_LAUNCHCTL_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/launchctl"

  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TREEHOUSE_ROOT="$custom_treehouse" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" install

  key=$(printf '%s' "$(cd "$FM_TEST_HOME" && pwd -P)" | shasum -a 256 | awk '{print substr($1,1,16)}')
  plist="$agents/com.firstmate.checkout-refresh.$key.plist"
  install_state_root="$install_state_base/homes/$key"
  assert_grep '<key>StartInterval</key><integer>60</integer>' "$plist" \
    "LaunchAgent does not carry the upstream signal cadence"
  assert_grep '<key>FM_CHECKOUT_REFRESH_BACKSTOP</key><string>900</string>' "$plist" \
    "LaunchAgent does not persist the timed backstop"
  assert_grep 'fm-checkout-refresh.sh</string>' "$plist" \
    "LaunchAgent does not invoke the checkout refresher"
  assert_grep "<key>FM_HOME</key><string>$(cd "$FM_TEST_HOME" && pwd -P)</string>" "$plist" \
    "LaunchAgent does not bind the active Firstmate home"
  assert_grep "<key>FM_TREEHOUSE_ROOT</key><string>$custom_treehouse</string>" "$plist" \
    "LaunchAgent does not persist the configured Treehouse root"
  assert_grep "<key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>$install_state_base/homes/$key</string>" "$plist" \
    "LaunchAgent does not use home-scoped state"
  assert_grep "<key>FM_CHECKOUT_REFRESH_LOCK_ROOT</key><string>$install_state_base/locks</string>" "$plist" \
    "LaunchAgent does not use the shared checkout lock root"
  assert_grep 'bootstrap' "$log" "LaunchAgent was not bootstrapped"
  assert_grep 'kickstart' "$log" "LaunchAgent was not started"
  date +%s > "$install_state_root/heartbeat"
  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TREEHOUSE_ROOT="$custom_treehouse" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure \
    || fail "matching LaunchAgent scheduler configuration was reported unhealthy"

  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TREEHOUSE_ROOT="$other_treehouse" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "LaunchAgent health accepted a different Treehouse root"
  assert_contains "$out" "different Treehouse root" \
    "LaunchAgent Treehouse-root drift was not diagnosed"

  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TREEHOUSE_ROOT="$custom_treehouse" FM_CHECKOUT_REFRESH_INTERVAL=61 \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "LaunchAgent health accepted a different refresh interval"
  assert_contains "$out" "different refresh interval" \
    "LaunchAgent refresh-interval drift was not diagnosed"

  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TREEHOUSE_ROOT="$custom_treehouse" FM_CHECKOUT_REFRESH_BACKSTOP=901 \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "LaunchAgent health accepted a different refresh backstop"
  assert_contains "$out" "different refresh backstop" \
    "LaunchAgent refresh-backstop drift was not diagnosed"

  second_home="$TMP_ROOT/fm-home-two"
  mkdir -p "$second_home/projects" "$second_home/config"
  HOME="$TEST_HOME" FM_HOME="$second_home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" install
  second_key=$(printf '%s' "$(cd "$second_home" && pwd -P)" | shasum -a 256 | awk '{print substr($1,1,16)}')
  second_plist="$agents/com.firstmate.checkout-refresh.$second_key.plist"
  [ -f "$plist" ] && [ -f "$second_plist" ] \
    || fail "installing a second home displaced the first home's LaunchAgent"
  assert_grep "<key>FM_HOME</key><string>$(cd "$second_home" && pwd -P)</string>" "$second_plist" \
    "second LaunchAgent does not bind its own Firstmate home"
  assert_grep "<key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>$install_state_base/homes/$second_key</string>" "$second_plist" \
    "second LaunchAgent does not use its own state directory"

  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_PLATFORM=Linux \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Linux scheduler seam silently reported background coverage"
  assert_contains "$out" "no Linux scheduler adapter yet" \
    "Linux scheduler seam did not report its explicit platform limitation"
  pass "scheduler ownership is home-scoped and Linux remains an explicit adapter seam"
}

if [ "${FM_TEST_FOCUSED:-}" = review-round-6 ]; then
  test_nested_active_project_invalidates_heartbeat
  test_bounded_refresh_terminates_descendants
  test_acquisition_honors_shared_checkout_lock
  exit 0
fi

test_discovery_covers_projects_treehouse_external_and_config
test_uninspectable_active_project_invalidates_heartbeat
test_nested_active_project_invalidates_heartbeat
test_upstream_tip_signal_refreshes_between_firstmate_events
test_periodic_backstop_repairs_drift_without_a_new_tip
test_live_default_change_is_surfaced_without_switching_branches
test_skill_drafts_surface_on_every_probe_without_log_spam
test_preflight_rejects_hygiene_without_an_origin
test_treehouse_pool_skill_drafts_are_inventoried
test_ignored_skill_files_are_outside_the_collision_guard
test_pool_preflight_surfaces_dirty_worktrees_without_blocking_clean_selection
test_bootstrap_relays_hygiene_alerts
test_treehouse_discovery_failure_invalidates_heartbeat
test_skill_inventory_failure_preserves_alert_and_heartbeat
test_dirty_nondefault_and_diverged_checkouts_are_untouched
test_refresh_locks_recover_stale_owners_and_surface_contention
test_session_mode_preserves_gone_branch_pruning
test_worktree_freshness_verification_fails_closed
test_bounded_refresh_terminates_descendants
test_acquisition_honors_shared_checkout_lock
test_launch_agent_definition_is_home_scoped_with_scheduler_seam
