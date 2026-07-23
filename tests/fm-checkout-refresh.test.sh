#!/usr/bin/env bash
# Behavior tests for the checkout-refresh discovery, upstream signal, timed
# backstop, independent coverage and scheduler health, untracked skill-draft
# hygiene, safety posture, worktree freshness proof, and LaunchAgent definition.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-checkout-lock-lib.sh
. "$ROOT/bin/fm-checkout-lock-lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-checkout-refresh-tests)
TEST_HOME="$TMP_ROOT/user"
FM_TEST_HOME="$TMP_ROOT/fm-home"
STATE_ROOT="$TMP_ROOT/refresh-state"
LOCK_ROOT="$TMP_ROOT/refresh-locks"
mkdir -p "$TEST_HOME/.treehouse" "$FM_TEST_HOME/projects" "$FM_TEST_HOME/config" "$STATE_ROOT"

checkout_state_key() {
  local path
  path=$(fm_checkout_trusted_dir "$1") || return 1
  fm_checkout_hash_value "$path" "${2:-24}"
}

checkout_lock_key() {
  fm_checkout_stable_path_key "$1" directory 0 "${2:-24}"
}

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

run_isolated_refresh() {
  local home=$1 state_root=$2
  shift 2
  mkdir -p "$home/user/.treehouse"
  HOME="$home/user" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$state_root" \
    FM_CHECKOUT_REFRESH_LOCK_ROOT="$state_root-locks" \
    FM_TREEHOUSE_ROOT="$home/user/.treehouse" \
    FM_CHECKOUT_REFRESH_TEST=1 \
    "$ROOT/bin/fm-checkout-refresh.sh" "$@"
}

assert_refresh_state() {
  local state_root=$1 expected=$2 coverage_epoch coverage
  coverage_epoch=$(sed -n '1p' "$state_root/coverage-health" 2>/dev/null || true)
  coverage=$(sed -n '2p' "$state_root/coverage-health" 2>/dev/null || true)
  case "$coverage_epoch" in ''|*[!0-9]*) fail "coverage health timestamp is missing" ;; esac
  [ "$coverage" = "$expected" ] \
    || fail "expected $expected coverage health, found ${coverage:-missing}"
}

assert_heartbeat_value() {
  local state_root=$1 expected=$2 actual
  actual=$(sed -n '1p' "$state_root/heartbeat" 2>/dev/null || true)
  [ "$actual" = "$expected" ] \
    || fail "expected heartbeat $expected, found ${actual:-missing}"
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

test_uninspectable_active_project_invalidates_coverage_health() {
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
  assert_refresh_state "$STATE_ROOT" unhealthy
  pass "uninspectable active-home projects invalidate coverage health"
}

test_nested_active_project_invalidates_coverage_health() {
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
  assert_refresh_state "$nested_state" unhealthy
  pass "active projects must be exact canonical Git repository roots"
}

test_discovery_rejects_nested_configured_and_scanned_paths() {
  local remote seed outer configured_child scan_root scanned_child scanned_canonical out err
  remote=$(build_origin exact-discovery)
  seed="$FM_TEST_HOME/projects/exact-discovery"
  outer="$TMP_ROOT/exact-discovery-outer"
  configured_child="$outer/configured-child"
  scan_root="$outer/scan-root"
  scanned_child="$scan_root/scanned-child"
  out="$TMP_ROOT/exact-discovery.out"
  err="$TMP_ROOT/exact-discovery.err"
  clone_from "$remote" "$seed"
  clone_from "$remote" "$outer"
  mkdir -p "$configured_child" "$scanned_child"
  scanned_canonical=$(cd "$scanned_child" && pwd -P)
  {
    printf 'path %s\n' "$configured_child"
    printf 'scan %s\n' "$scan_root"
  } > "$FM_TEST_HOME/config/checkout-refresh"

  run_refresh discover > "$out" 2> "$err" \
    || fail "exact-root discovery fixture failed"

  assert_no_grep "^$configured_child$" "$out" \
    "configured nested directory was emitted as a checkout"
  assert_no_grep "^$scanned_canonical$" "$out" \
    "scanned nested directory was emitted as a clone"
  assert_grep "configured checkout is not an exact inspectable Git repository root: $configured_child" \
    "$err" "configured nested directory was not surfaced"
  assert_grep "discovered clone is not an exact inspectable Git repository root: $scanned_canonical" \
    "$err" "scanned nested directory was not surfaced"
  rm -f "$FM_TEST_HOME/config/checkout-refresh"
  rm -rf "$seed" "$outer"
  pass "configured and scanned checkouts require exact Git roots"
}

test_discovery_provenance_failures_invalidate_coverage() {
  local fixture home state remote project pool out status scan fakebin real_git
  fixture="$TMP_ROOT/discovery-provenance"
  home="$fixture/home"
  state="$fixture/state"
  scan="$fixture/scan"
  fakebin="$fixture/fakebin"
  mkdir -p "$home/user" "$home/projects" "$home/config" "$state" "$scan" "$fakebin"
  remote=$(build_origin discovery-provenance)
  project="$home/projects/relvino"
  clone_from "$remote" "$project"
  pool="$home/user/.treehouse/relvino"
  mkdir -p "$pool"
  printf '{"worktrees":[{"name":"bad","path":"%s"}]}\n' "$project" \
    > "$pool/treehouse-state.json"

  set +e
  out=$(run_isolated_refresh "$home" "$state" discover 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "unrelated Treehouse backing checkout was accepted"
  assert_contains "$out" "Treehouse worktree identity or registration is not inspectable: $project" \
    "unrelated Treehouse state path was not surfaced"

  rm -rf "$home/user/.treehouse"
  ln -s "$fixture/missing-project" "$home/projects/broken-project"
  printf 'scan %s\n' "$scan" > "$home/config/checkout-refresh"
  ln -s "$fixture/missing-scan-target" "$scan/broken-candidate"
  set +e
  out=$(run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "broken discovery symlinks reported healthy coverage"
  assert_contains "$out" "broken active-home project symlink" \
    "broken active-project symlink was not surfaced"
  assert_refresh_state "$state" unhealthy

  rm -f "$home/projects/broken-project"
  set +e
  out=$(run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "broken scanned symlink reported healthy coverage"
  assert_contains "$out" "broken scan candidate symlink" \
    "broken scanned symlink was not surfaced"
  assert_refresh_state "$state" unhealthy

  rm -f "$scan/broken-candidate"
  clone_from "$remote" "$scan/scanned-repo"
  : > "$scan/scanned-repo/.fm-fail-git-probe"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ -f "${2:-}/.fm-fail-git-probe" ] \
    && [ "${3:-}" = rev-parse ] && [ "${4:-}" = --is-inside-work-tree ]; then
  exit 128
fi
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"
  set +e
  out=$(
    export PATH="$fakebin:$PATH"
    export FM_REAL_GIT="$real_git"
    run_isolated_refresh "$home" "$state" run-once --force 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "uninspectable discovered Git identity reported healthy coverage"
  assert_contains "$out" "discovered Git identity cannot be inspected or disproved:" \
    "discovered rev-parse failure was classified as a non-Git directory"
  assert_refresh_state "$state" unhealthy
  pass "discovery provenance failures invalidate coverage health"
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

  key=$(checkout_state_key "$project")
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

  key=$(checkout_state_key "$pool_worktree")
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
  assert_contains "$out" "FLEET_SYNC: checkout-refresh: skipped: unsafe config path" \
    "session-start bootstrap suppressed the unsafe configuration warning"
  grep -Fq '# bootstrap draft' "$draft" || fail "bootstrap refresh changed the draft"
  rm -rf "$project/.agents"
  run_refresh run-once >/dev/null
  pass "session-start bootstrap relays hygiene and discovery diagnostics"
}

test_treehouse_discovery_failure_invalidates_coverage_health() {
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
  assert_refresh_state "$STATE_ROOT" unhealthy

  printf '%s\n' '{}' > "$bad_state"
  printf '%s\n' preserved-schema-heartbeat > "$STATE_ROOT/heartbeat"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Treehouse state without a worktrees field reported healthy coverage"
  assert_contains "$out" "worktrees is required" \
    "missing Treehouse worktrees schema was not surfaced"
  assert_refresh_state "$STATE_ROOT" unhealthy

  printf '{"worktrees":[{"path":"%s"}]}\n' "$missing_path" > "$bad_state"
  printf '%s\n' preserved-path-heartbeat > "$STATE_ROOT/heartbeat"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "uninspectable declared Treehouse worktree reported healthy coverage"
  assert_contains "$out" "Treehouse worktree identity or registration is not inspectable: $missing_path" \
    "uninspectable declared Treehouse worktree was not surfaced"
  assert_refresh_state "$STATE_ROOT" unhealthy
  rm -rf "$(dirname "$bad_state")"

  chmod 000 "$treehouse_root"
  printf '%s\n' preserved-root-heartbeat > "$STATE_ROOT/heartbeat"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  chmod 700 "$treehouse_root"
  [ "$status" -ne 0 ] || fail "unreadable Treehouse root reported healthy coverage"
  assert_contains "$out" "configured root is unsafe or unreadable" \
    "unreadable Treehouse root was not surfaced"
  assert_refresh_state "$STATE_ROOT" unhealthy

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
  assert_refresh_state "$STATE_ROOT" unhealthy
  pass "unreadable roots, malformed schemas, and uninspectable paths invalidate coverage health"
}

test_raw_treehouse_root_symlink_invalidates_coverage_health() {
  local real_root linked_root linked_parent linked_child missing_root out status
  real_root="$TMP_ROOT/treehouse-root-real"
  linked_root="$TMP_ROOT/treehouse-root-link"
  mkdir -p "$real_root"
  ln -s "$real_root" "$linked_root"

  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_CHECKOUT_REFRESH_LOCK_ROOT="$LOCK_ROOT" \
    FM_TREEHOUSE_ROOT="$linked_root" FM_CHECKOUT_REFRESH_TEST=1 \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "symlinked raw Treehouse root reported healthy coverage"
  assert_contains "$out" "configured root is unsafe or unreadable: $linked_root" \
    "symlinked raw Treehouse root was resolved before rejection"
  assert_refresh_state "$STATE_ROOT" unhealthy

  linked_parent="$TMP_ROOT/treehouse-parent-link"
  linked_child="$linked_parent/pools"
  ln -s "$real_root" "$linked_parent"
  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_CHECKOUT_REFRESH_LOCK_ROOT="$LOCK_ROOT" \
    FM_TREEHOUSE_ROOT="$linked_child/" FM_CHECKOUT_REFRESH_TEST=1 \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "Treehouse root with a symlinked ancestor and trailing slash reported healthy coverage"
  assert_contains "$out" "configured root is unsafe or unreadable: $linked_child/" \
    "Treehouse ancestor symlink was hidden by normalization"

  missing_root="$TMP_ROOT/configured-treehouse-missing"
  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_CHECKOUT_REFRESH_LOCK_ROOT="$LOCK_ROOT" \
    FM_TREEHOUSE_ROOT="$missing_root" FM_CHECKOUT_REFRESH_TEST=1 \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "explicitly configured missing Treehouse root reported healthy coverage"
  assert_contains "$out" "configured root is unsafe or unreadable: $missing_root" \
    "missing configured Treehouse root was treated as benignly absent"
  pass "raw, ancestor-symlinked, and missing configured Treehouse roots fail closed"
}

test_empty_treehouse_and_identity_tool_failures_fail_closed() {
  local out status
  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_CHECKOUT_REFRESH_LOCK_ROOT="$LOCK_ROOT" \
    FM_TREEHOUSE_ROOT= FM_CHECKOUT_REFRESH_TEST=1 \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "explicitly empty Treehouse root fell back to the default"
  assert_contains "$out" "configured root is unsafe or unreadable:" \
    "explicitly empty Treehouse root was not surfaced"

  set +e
  out=$(FM_CHECKOUT_TEST_DISABLE_SYSTEM_PERL=1 run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "missing fixed identity tool reported healthy coverage"
  assert_contains "$out" "checkout-refresh home identity is unavailable" \
    "fixed identity-tool failure did not fail before state aliasing"
  pass "empty Treehouse configuration and identity-tool failures fail closed"
}

test_config_git_metadata_and_non_git_races_fail_closed() {
  local real_config linked_config remote source redirected scan candidate out status
  real_config="$TMP_ROOT/config-real"
  linked_config="$TMP_ROOT/config-linked"
  mkdir -p "$real_config"
  printf '# valid\n' > "$real_config/checkout-refresh"
  ln -s "$real_config" "$linked_config"
  set +e
  out=$(FM_CONFIG_OVERRIDE="$linked_config" run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "config through a symlinked ancestor reported healthy coverage"
  assert_contains "$out" "unsafe config path" \
    "config ancestor redirect was not surfaced"
  rm -f "$linked_config"

  remote=$(build_origin redirected-git)
  source="$TMP_ROOT/redirected-git-source"
  redirected="$TMP_ROOT/redirected-git-candidate"
  clone_from "$remote" "$source"
  mkdir -p "$redirected"
  ln -s "$source/.git" "$redirected/.git"
  printf 'path %s\n' "$redirected" > "$FM_TEST_HOME/config/checkout-refresh"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "redirected Git metadata reported healthy coverage"
  assert_contains "$out" "configured checkout is not an exact inspectable Git repository root" \
    "redirected Git metadata was not surfaced"
  rm -f "$FM_TEST_HOME/config/checkout-refresh"

  scan="$TMP_ROOT/non-git-race-scan"
  candidate="$scan/candidate"
  mkdir -p "$candidate"
  printf 'scan %s\n' "$scan" > "$FM_TEST_HOME/config/checkout-refresh"
  set +e
  out=$(FM_CHECKOUT_TEST_CREATE_GIT_AT="$candidate" run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "concurrent Git metadata creation was classified as non-Git"
  assert_contains "$out" "discovered Git identity cannot be inspected or disproved" \
    "concurrent Git metadata creation was not surfaced"
  rm -f "$FM_TEST_HOME/config/checkout-refresh"
  pass "config, Git metadata, and non-Git classification races fail closed"
}

test_skill_inventory_failure_preserves_alert_and_invalidates_coverage() {
  local project draft key alert prior fakebin real_git out status
  project=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  draft="$project/.agents/skills/inventory-failure/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# retained draft' > "$draft"
  run_refresh run-once >/dev/null
  key=$(checkout_state_key "$project")
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
  assert_refresh_state "$STATE_ROOT" unhealthy
  rm -rf "$fakebin" "$project/.agents"
  run_refresh run-once >/dev/null
  pass "skill inventory failures preserve alerts and invalidate coverage health"
}

test_lock_root_failure_invalidates_coverage_before_preparation() {
  local state_root="$TMP_ROOT/lock-root-health-state" bad_lock="$TMP_ROOT/lock-root-health-file"
  local out status now
  mkdir -p "$state_root"
  printf '%s\n' occupied > "$bad_lock"
  printf '%s\n' manual-heartbeat > "$state_root/heartbeat"
  now=$(date +%s)
  printf '%s\n%s\n' "$now" healthy > "$state_root/coverage-health"

  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$state_root" \
    FM_CHECKOUT_REFRESH_LOCK_ROOT="$bad_lock" \
    FM_TREEHOUSE_ROOT="$TEST_HOME/.treehouse" \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "unsafe lock-root preparation preserved healthy coverage"
  assert_contains "$out" "unsafe checkout-refresh lock directory: $bad_lock" \
    "unsafe lock-root preparation was not surfaced"
  assert_refresh_state "$state_root" unhealthy
  assert_heartbeat_value "$state_root" manual-heartbeat
  pass "lock-root preparation failures invalidate coverage without refreshing liveness"
}

test_reinspection_failure_invalidates_coverage_health() {
  local remote home state_root lock_root treehouse project fakebin real_git out key alert
  local initial_head reinspection_count
  remote=$(build_origin reinspection)
  home="$TMP_ROOT/reinspection-home"
  state_root="$TMP_ROOT/reinspection-state"
  lock_root="$TMP_ROOT/reinspection-locks"
  treehouse="$TMP_ROOT/reinspection-treehouse"
  project="$home/projects/reinspection"
  fakebin="$TMP_ROOT/reinspection-fakebin"
  real_git=$(command -v git)
  fm_git_init_commit "$home"
  mkdir -p "$home/projects" "$home/config" "$state_root" "$treehouse" "$fakebin"
  clone_from "$remote" "$project"
  project=$(cd "$project" && pwd -P)
  home=$(cd "$home" && pwd -P)
  initial_head=$(git -C "$project" rev-parse HEAD)
  advance_origin reinspection changed-after-discovery
  printf '%s\n' manual-reinspection-heartbeat > "$state_root/heartbeat"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] \
  && [ "${2:-}" = "${FM_TEST_REINSPECTION_TARGET:?}" ] \
  && [ "${3:-}" = rev-parse ] \
  && [ "${4:-}" = --show-toplevel ]; then
  count=$(cat "${FM_TEST_REINSPECTION_COUNT:?}" 2>/dev/null || printf 0)
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_TEST_REINSPECTION_COUNT"
  if [ "$count" -gt 1 ]; then
    printf '%s\n' "${FM_TEST_REINSPECTION_ENCLOSING:?}"
    exit 0
  fi
fi
exec "${FM_TEST_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"

  out=$(HOME="$TEST_HOME" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$state_root" \
    FM_CHECKOUT_REFRESH_LOCK_ROOT="$lock_root" \
    FM_TREEHOUSE_ROOT="$treehouse" \
    FM_TEST_REAL_GIT="$real_git" FM_TEST_REINSPECTION_TARGET="$project" \
    FM_TEST_REINSPECTION_ENCLOSING="$home" \
    FM_TEST_REINSPECTION_COUNT="$TMP_ROOT/reinspection-count" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force 2>&1)

  assert_contains "$out" "$project: skipped: covered checkout became uninspectable during refresh" \
    "covered-checkout reinspection failure was not surfaced"
  assert_refresh_state "$state_root" unhealthy
  assert_heartbeat_value "$state_root" manual-reinspection-heartbeat
  reinspection_count=$(cat "$TMP_ROOT/reinspection-count")
  [ "$reinspection_count" -eq 3 ] \
    || fail "both post-discovery passes did not repeat the exact-root proof"
  [ "$(git -C "$project" rev-parse HEAD)" = "$initial_head" ] \
    || fail "identity-drifted covered path was refreshed through its enclosing repository"
  key=$(checkout_state_key "$project")
  alert="$state_root/$key.alert"
  assert_grep "covered checkout became uninspectable during refresh" "$alert" \
    "covered-checkout reinspection failure did not persist an alert"
  pass "covered-checkout reinspection failures invalidate coverage health"
}

test_scheduler_liveness_is_scheduler_owned() {
  local home="$TMP_ROOT/scheduler-owned-home" state_root="$TMP_ROOT/scheduler-owned-state"
  local lock_root="$TMP_ROOT/scheduler-owned-locks" treehouse="$TMP_ROOT/scheduler-owned-treehouse"
  local project heartbeat
  project="$home/projects/local"
  mkdir -p "$home/projects" "$home/config" "$state_root" "$treehouse"
  fm_git_init_commit "$project"
  printf '%s\n' manual-sentinel > "$state_root/heartbeat"

  HOME="$TEST_HOME" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$state_root" \
    FM_CHECKOUT_REFRESH_LOCK_ROOT="$lock_root" \
    FM_TREEHOUSE_ROOT="$treehouse" \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --force >/dev/null
  assert_refresh_state "$state_root" healthy
  assert_heartbeat_value "$state_root" manual-sentinel

  HOME="$TEST_HOME" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$state_root" \
    FM_CHECKOUT_REFRESH_LOCK_ROOT="$lock_root" \
    FM_TREEHOUSE_ROOT="$treehouse" \
    "$ROOT/bin/fm-checkout-refresh.sh" run-once --scheduled --force >/dev/null
  heartbeat=$(sed -n '1p' "$state_root/heartbeat" 2>/dev/null || true)
  case "$heartbeat" in ''|*[!0-9]*) fail "scheduled run did not advance scheduler liveness" ;; esac
  assert_refresh_state "$state_root" healthy
  pass "only scheduler-owned runs advance the liveness heartbeat"
}

test_unreadable_scan_root_invalidates_coverage_health() {
  local home="$TMP_ROOT/unreadable-scan-home" state_root="$TMP_ROOT/unreadable-scan-state"
  local scan_root="$TMP_ROOT/unreadable-scan-root" canonical_scan project out status
  project="$home/projects/local"
  mkdir -p "$home/user" "$home/projects" "$home/config" "$state_root" "$scan_root"
  fm_git_init_commit "$project"
  printf 'scan %s\n' "$scan_root" > "$home/config/checkout-refresh"
  canonical_scan=$(cd "$scan_root" && pwd -P)
  chmod 111 "$scan_root"

  out=$(run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  status=$?
  chmod 700 "$scan_root"

  [ "$status" -ne 0 ] || fail "unreadable scan root reported successful coverage"
  assert_contains "$out" "scan root is unreadable or cannot be enumerated: $canonical_scan" \
    "unreadable scan root was silently enumerated as empty"
  assert_refresh_state "$state_root" unhealthy
  pass "scan roots must be readable and successfully enumerable"
}

test_unreadable_scanned_origin_invalidates_coverage_health() {
  local remote home="$TMP_ROOT/unreadable-origin-home" state_root="$TMP_ROOT/unreadable-origin-state"
  local project scan_root candidate canonical_candidate fakebin real_git out status
  remote=$(build_origin unreadable-scanned-origin)
  project="$home/projects/seed"
  scan_root="$home/shared"
  candidate="$scan_root/candidate"
  fakebin="$home/fakebin"
  real_git=$(command -v git)
  mkdir -p "$home/user" "$home/projects" "$home/config" "$state_root" "$scan_root" "$fakebin"
  clone_from "$remote" "$project"
  clone_from "$remote" "$candidate"
  canonical_candidate=$(cd "$candidate" && pwd -P)
  printf 'scan %s\n' "$scan_root" > "$home/config/checkout-refresh"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] \
  && [ "${2:-}" = "${FM_TEST_UNREADABLE_ORIGIN_TARGET:?}" ] \
  && [ "${3:-}" = remote ] \
  && [ "$#" -eq 3 ]; then
  exit 74
fi
exec "${FM_TEST_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"

  out=$(FM_TEST_REAL_GIT="$real_git" FM_TEST_UNREADABLE_ORIGIN_TARGET="$canonical_candidate" \
    PATH="$fakebin:$PATH" \
    run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "unreadable scanned origin reported successful coverage"
  assert_contains "$out" "discovered checkout origin identity cannot be inspected: $canonical_candidate" \
    "unreadable scanned origin was treated as an irrelevant directory"
  assert_refresh_state "$state_root" unhealthy
  pass "scanned repository origin failures invalidate coverage"
}

test_failed_alert_persistence_forces_reinspection() {
  local remote home="$TMP_ROOT/alert-persistence-home" state_root="$TMP_ROOT/alert-persistence-state"
  local project key alert last_file out status
  remote=$(build_origin alert-persistence)
  project="$home/projects/alert-persistence"
  mkdir -p "$home/user" "$home/projects" "$home/config" "$state_root"
  clone_from "$remote" "$project"
  run_isolated_refresh "$home" "$state_root" run-once --force >/dev/null
  key=$(checkout_state_key "$project")
  alert="$state_root/$key.alert"
  last_file="$state_root/$key.last"
  printf '%s\n' 1 > "$last_file"
  mkdir "$alert"
  printf '%s\n' dirty > "$project/untracked.txt"

  out=$(run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "failed checkout-alert persistence reported success"
  assert_contains "$out" "STUCK:" "failed alert write did not surface the unsafe checkout"
  assert_contains "$out" "checkout alert cannot be persisted" \
    "failed alert write was not surfaced"
  [ "$(cat "$last_file")" = 1 ] || fail "failed refresh advanced checkout cadence state"
  assert_refresh_state "$state_root" unhealthy

  out=$(run_isolated_refresh "$home" "$state_root" run-once 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "run after failed alert persistence reported success"
  assert_contains "$out" "STUCK:" \
    "prior unhealthy coverage did not force pre-backstop reinspection"
  assert_contains "$out" "checkout alert cannot be persisted" \
    "second alert persistence failure was hidden"
  [ "$(cat "$last_file")" = 1 ] || fail "failed retry advanced checkout cadence state"
  assert_refresh_state "$state_root" unhealthy
  pass "failed alert persistence cannot become healthy before reinspection"
}

test_local_authority_is_fully_inspected_and_tracks_origin_identity() {
  local remote home="$TMP_ROOT/local-authority-home" state_root="$TMP_ROOT/local-authority-state"
  local project initial out status fakebin real_git old_tip
  remote=$(build_origin local-authority)
  project="$home/projects/local-authority"
  mkdir -p "$home/user" "$home/projects" "$home/config" "$home/data" "$state_root"
  clone_from "$remote" "$project"
  project=$(cd "$project" && pwd -P)
  printf -- '- local-authority [local-only] - test project (added 2026-07-23)\n' > "$home/data/projects.md"
  initial=$(git -C "$project" rev-parse HEAD)
  advance_origin local-authority upstream-only-change

  out=$(run_isolated_refresh "$home" "$state_root" run-once --force --verbose)

  assert_contains "$out" "$project: already current at local main" \
    "local-only checkout with origin did not use its local default tip"
  assert_refresh_state "$state_root" healthy
  [ "$(git -C "$project" rev-parse HEAD)" = "$initial" ] \
    || fail "local-only checkout advanced to its remote"

  printf '%s\n' draft > "$project/untracked.txt"
  out=$(run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  assert_contains "$out" "with uncommitted changes (1 untracked)" \
    "local-only untracked work was not surfaced"
  assert_refresh_state "$state_root" unhealthy
  status=0
  run_isolated_refresh "$home" "$state_root" preflight "$project" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "local-only preflight accepted untracked work"
  rm -f "$project/untracked.txt"

  git -C "$project" checkout -q -b feature
  out=$(run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  assert_contains "$out" "on non-default branch feature" \
    "local-only non-default branch was not surfaced"
  assert_refresh_state "$state_root" unhealthy
  status=0
  run_isolated_refresh "$home" "$state_root" preflight "$project" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "local-only preflight accepted a non-default branch"
  git -C "$project" checkout -q main

  commit_file "$project" local.txt local local-default-advance
  old_tip=$(git -C "$project" rev-parse HEAD^)
  git -C "$project" checkout -q --detach "$old_tip"
  out=$(run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  assert_contains "$out" "detached HEAD at stale local tip" \
    "stale local-only checkout was not surfaced"
  assert_refresh_state "$state_root" unhealthy
  git -C "$project" checkout -q main

  fakebin="$home/fakebin"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] \
  && [ "${2:-}" = "${FM_TEST_LOCAL_STATUS_TARGET:?}" ] \
  && [ "${3:-}" = status ]; then
  exit 74
fi
exec "${FM_TEST_REAL_GIT:?}" "$@"
SH
  chmod +x "$fakebin/git"
  out=$(FM_TEST_REAL_GIT="$real_git" FM_TEST_LOCAL_STATUS_TARGET="$project" \
    PATH="$fakebin:$PATH" \
    run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  assert_contains "$out" "local checkout cleanliness cannot be inspected" \
    "unreadable local-only status was treated as clean"
  assert_refresh_state "$state_root" unhealthy
  rm -rf "$fakebin"

  run_isolated_refresh "$home" "$state_root" run-once --force >/dev/null
  git -C "$project" remote remove origin
  out=$(run_isolated_refresh "$home" "$state_root" run-once --force 2>&1)
  assert_contains "$out" "covered checkout origin identity drifted" \
    "persisted local-only origin removal was not surfaced"
  assert_refresh_state "$state_root" unhealthy
  pass "local authority inspects safety and preserves origin identity"
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
  key=$(checkout_lock_key "$common")
  checkout_lock="$LOCK_ROOT/$key.lock"
  mkdir -p "$checkout_lock"
  printf '%s\n' "$$" > "$checkout_lock/pid"
  out=$(run_refresh run-once --force)
  assert_contains "$out" "$checkout: skipped: refresh already running (pid $$)" \
    "shared-checkout lock contention was not surfaced"
  alias="$TMP_ROOT/relvino-checkout-alias"
  ln -s "$checkout" "$alias"
  out=$(run_refresh preflight "$alias" 2>&1) || true
  assert_contains "$out" "checkout-refresh preflight target must be an exact inspectable Git repository root: $alias" \
    "a symlink alias was not rejected before lock resolution"
  rm -rf "$checkout_lock"
  pass "refresh locks recover abandoned owners and serialize every checkout alias"
}

test_session_mode_preserves_gone_branch_pruning() {
  local remote work project out
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

  out=$(run_refresh run-once --force --session)
  git -C "$project" show-ref --verify --quiet refs/heads/merged \
    || fail "session refresh deleted a gone branch without landed-work proof"
  assert_contains "$out" "retained gone branch merged because landed work cannot be proved" \
    "session refresh did not surface an unproven gone branch"

  git -C "$work" merge -q --no-ff merged -m land-merged
  git -C "$work" push -q origin main
  run_refresh run-once --force --session >/dev/null
  if git -C "$project" show-ref --verify --quiet refs/heads/merged; then
    fail "session refresh retained a gone branch after its content landed"
  fi
  pass "session pruning requires positive landed-work proof"
}

test_config_and_external_identity_fail_closed() {
  local remote project external original_origin out status config_real
  remote=$(build_origin identity-history)
  project="$FM_TEST_HOME/projects/identity-history"
  external="$TEST_HOME/identity-history"
  clone_from "$remote" "$project"
  clone_from "$remote" "$external"
  run_refresh run-once --force >/dev/null

  original_origin=$(git -C "$external" remote get-url origin)
  git -C "$external" remote set-url origin file://"$TMP_ROOT/remotes/unrelated.git"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "external origin drift reported successful coverage"
  assert_contains "$out" "prior external checkout origin changed at" \
    "external origin drift was silently dropped from discovery"
  assert_refresh_state "$STATE_ROOT" unhealthy
  git -C "$external" remote set-url origin "$original_origin"
  run_refresh run-once --force >/dev/null

  printf '%s\n' 'unexpected directive' > "$FM_TEST_HOME/config/checkout-refresh"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "unknown checkout-refresh config reported successful coverage"
  assert_contains "$out" "unknown config directive" "unknown config was not surfaced"
  assert_refresh_state "$STATE_ROOT" unhealthy
  rm -f "$FM_TEST_HOME/config/checkout-refresh"

  {
    printf 'path %s\n' "$TMP_ROOT/missing-configured-checkout"
    printf 'scan %s\n' "$TMP_ROOT/missing-configured-scan"
  } > "$FM_TEST_HOME/config/checkout-refresh"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "invalid configured coverage paths reported success"
  assert_contains "$out" "configured checkout is not an exact inspectable Git repository root" \
    "invalid configured checkout was not surfaced"
  assert_contains "$out" "configured scan root is not a directory" \
    "invalid configured scan root was not surfaced"
  rm -f "$FM_TEST_HOME/config/checkout-refresh"

  config_real="$TMP_ROOT/checkout-refresh-symlink-target"
  printf '# valid target\n' > "$config_real"
  ln -s "$config_real" "$FM_TEST_HOME/config/checkout-refresh"
  set +e
  out=$(run_refresh run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "symlinked checkout-refresh config reported success"
  assert_contains "$out" "unsafe config path" "symlinked config was not surfaced"
  assert_refresh_state "$STATE_ROOT" unhealthy
  rm -f "$FM_TEST_HOME/config/checkout-refresh" "$config_real"
  pass "configuration and prior external identity failures invalidate coverage"
}

test_public_entrypoints_reject_nested_repository_paths() {
  local source worktree nested alias_parent alias_source out status
  source="$TMP_ROOT/exact-entry-source"
  worktree="$TMP_ROOT/exact-entry-worktree"
  fm_git_worktree "$source" "$worktree" exact-entry
  nested="$source/nested"
  mkdir -p "$nested"
  set +e
  out=$(run_refresh preflight "$nested" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "preflight accepted a nested repository path"
  assert_contains "$out" "must be an exact inspectable Git repository root" \
    "nested preflight refusal was unclear"
  set +e
  run_refresh acquire-worktree "$nested" nested-test >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "worktree acquisition accepted a nested repository path"
  set +e
  run_refresh verify-worktree "$worktree" "$nested" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "worktree verification accepted a nested source path"
  alias_parent="$TMP_ROOT/exact-entry-parent-link"
  ln -s "$(dirname "$source")" "$alias_parent"
  alias_source="$alias_parent/$(basename "$source")/"
  set +e
  out=$(run_refresh preflight "$alias_source" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "preflight accepted a repository through a symlinked ancestor and trailing slash"
  assert_contains "$out" "must be an exact inspectable Git repository root" \
    "ancestor-symlinked preflight refusal was unclear"
  mkdir -p "$source/relative-caller"
  (
    cd "$source/relative-caller" || exit 1
    run_refresh preflight .. >/dev/null
  ) || fail "parent-relative exact repository root was rejected"
  pass "public refresh entrypoints require lexical and canonical repository roots"
}

test_explicit_secondmate_home_requires_live_default_tip() {
  local remote source home status
  remote=$(build_origin explicit-home-freshness)
  source="$TMP_ROOT/explicit-home-source"
  home="$TMP_ROOT/explicit-secondmate-home"
  clone_from "$remote" "$source"
  git clone --quiet "$source" "$home"
  run_refresh verify-home "$home" "$source" \
    || fail "fresh explicit secondmate home failed live-tip verification"
  advance_origin explicit-home-freshness C1
  set +e
  run_refresh verify-home "$home" "$source" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "stale explicit secondmate home passed live-tip verification"
  run_refresh preflight "$source" >/dev/null
  run_refresh preflight "$home" >/dev/null
  run_refresh verify-home "$home" "$source" \
    || fail "refreshed explicit secondmate home failed live-tip verification"
  pass "explicit secondmate homes require proven live-tip freshness"
}

test_lock_owner_symlink_cannot_escape_state_directory() {
  local outside lock status
  outside="$TEST_HOME/external-lock-owner"
  lock="$STATE_ROOT/escaped-lock"
  mkdir -p "$outside"
  printf '%s\n' 999999 > "$outside/pid"
  printf '%s\n' 999999 > "$outside/process-group"
  ln -s "$outside" "$lock"
  set +e
  FM_HOME="$FM_TEST_HOME" FM_ROOT="$ROOT" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; FM_LOCK_STALE_AFTER=0; fm_lock_try_acquire "$2"' \
    bash "$ROOT" "$lock" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "lock acquisition accepted an external owner target"
  assert_present "$outside/pid" "lock cleanup deleted an external owner pid"
  assert_present "$outside/process-group" "lock cleanup deleted an external process-group guard"
  [ -L "$lock" ] || fail "lock cleanup rewrote a malformed external owner link"
  pass "lock cleanup remains confined to state-owned owner directories"
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
  assert_refresh_state "$STATE_ROOT" unhealthy
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
  key=$(checkout_lock_key "$common")
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
  local custom_treehouse="$TMP_ROOT/custom-treehouse" other_treehouse="$TMP_ROOT/other-treehouse" out status now
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

  key=$(checkout_state_key "$FM_TEST_HOME" 16)
  plist="$agents/com.firstmate.checkout-refresh.$key.plist"
  install_state_root="$install_state_base/homes/$key"
  assert_grep '<key>StartInterval</key><integer>60</integer>' "$plist" \
    "LaunchAgent does not carry the upstream signal cadence"
  assert_grep '<key>FM_CHECKOUT_REFRESH_BACKSTOP</key><string>900</string>' "$plist" \
    "LaunchAgent does not persist the timed backstop"
  assert_grep 'fm-checkout-refresh.sh</string>' "$plist" \
    "LaunchAgent does not invoke the checkout refresher"
  assert_grep '<string>--scheduled</string>' "$plist" \
    "LaunchAgent does not identify its scheduler-owned invocation"
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
  now=$(date +%s)
  printf '%s\n' "$now" > "$install_state_root/heartbeat"
  printf '%s\n%s\n' "$((now - 1))" healthy > "$install_state_root/coverage-health"
  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TREEHOUSE_ROOT="$custom_treehouse" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure \
    || fail "matching LaunchAgent scheduler configuration was reported unhealthy"

  printf '%s\n%s\n' "$now" unhealthy > "$install_state_root/coverage-health"
  set +e
  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TREEHOUSE_ROOT="$custom_treehouse" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "LaunchAgent health accepted an unhealthy latest coverage run"
  assert_contains "$out" "latest coverage run is missing or unhealthy" \
    "LaunchAgent health did not diagnose the failed coverage run"
  printf '%s\n%s\n' "$now" healthy > "$install_state_root/coverage-health"

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
  second_key=$(checkout_state_key "$second_home" 16)
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

test_logical_home_state_migrates_and_ambiguity_fails_closed() {
  local home state_base logical_key current_physical_key physical_key logical physical agents fakebin physical_plist logical_plist now out status
  local rollback_home rollback_logical_key rollback_physical_key rollback_logical rollback_physical rollback_physical_plist rollback_logical_plist
  local staging_home staging_logical_key staging_physical_key staging_logical staging_physical staging_physical_plist
  home="$TMP_ROOT/state-migration-home"
  state_base="$TMP_ROOT/state-migration-base"
  mkdir -p "$home/projects" "$home/config" "$home/user/.treehouse"
  logical_key=$(checkout_state_key "$home" 16)
  current_physical_key=$(fm_checkout_physical_path_key "$home" directory 16)
  physical_key=1111111111111111
  [ "$physical_key" != "$logical_key" ] || physical_key=2222222222222222
  [ "$physical_key" != "$current_physical_key" ] || physical_key=3333333333333333
  logical="$state_base/homes/$logical_key"
  physical="$state_base/homes/$physical_key"
  agents="$TMP_ROOT/state-migration-agents"
  fakebin="$TMP_ROOT/state-migration-fakebin"
  physical_plist="$agents/com.firstmate.checkout-refresh.$physical_key.plist"
  logical_plist="$agents/com.firstmate.checkout-refresh.$logical_key.plist"
  mkdir -p "$physical" "$agents" "$fakebin"
  printf 'preserved\n' > "$physical/external-identities"
  now=$(date +%s)
  printf '%s\n%s\n' "$now" "$ROOT/bin/fm-checkout-refresh.sh" > "$physical/heartbeat"
  printf '%s\nhealthy\n' "$now" > "$physical/coverage-health"
  printf '<plist><string>%s/bin/fm-checkout-refresh.sh</string><key>FM_HOME</key><string>%s</string><key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>%s</string></plist>\n' \
    "$ROOT" "$(cd "$home" && pwd -P)" "$physical" > "$physical_plist"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/launchctl"
  out=$(HOME="$home/user" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$state_base" \
    FM_TREEHOUSE_ROOT="$home/user/.treehouse" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  [ -f "$logical/external-identities" ] || fail "physical home state was not migrated to the logical namespace"
  [ ! -e "$physical" ] || fail "physical home state namespace survived migration"
  [ -f "$logical_plist" ] || fail "physical LaunchAgent was not migrated to the logical label"
  [ ! -e "$physical_plist" ] || fail "physical LaunchAgent survived logical-label migration"

  rollback_home="$TMP_ROOT/state-migration-rollback-home"
  mkdir -p "$rollback_home/projects" "$rollback_home/config" "$rollback_home/user/.treehouse"
  rollback_logical_key=$(checkout_state_key "$rollback_home" 16)
  rollback_physical_key=4444444444444444
  [ "$rollback_physical_key" != "$rollback_logical_key" ] || rollback_physical_key=5555555555555555
  rollback_logical="$state_base/homes/$rollback_logical_key"
  rollback_physical="$state_base/homes/$rollback_physical_key"
  rollback_physical_plist="$agents/com.firstmate.checkout-refresh.$rollback_physical_key.plist"
  rollback_logical_plist="$agents/com.firstmate.checkout-refresh.$rollback_logical_key.plist"
  mkdir -p "$rollback_physical"
  printf 'preserved-on-failure\n' > "$rollback_physical/external-identities"
  printf '<plist><string>%s/bin/fm-checkout-refresh.sh</string><key>FM_HOME</key><string>%s</string><key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>%s</string></plist>\n' \
    "$ROOT" "$(cd "$rollback_home" && pwd -P)" "$rollback_physical" > "$rollback_physical_plist"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_LAUNCHCTL_LOG"
exit 0
SH
  chmod +x "$fakebin/launchctl"
  set +e
  out=$(HOME="$rollback_home/user" FM_HOME="$rollback_home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$state_base" \
    FM_TREEHOUSE_ROOT="$rollback_home/user/.treehouse" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_TEST_PHYSICAL_PLIST="$rollback_physical_plist" \
    FM_TEST_LAUNCHCTL_LOG="$TMP_ROOT/state-migration-rollback-launchctl.log" \
    "$ROOT/bin/fm-checkout-refresh.sh" install 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failed logical LaunchAgent activation reported success"
  [ -f "$rollback_physical/external-identities" ] \
    || fail "failed LaunchAgent migration did not restore physical state"
  [ -f "$rollback_physical_plist" ] || fail "failed LaunchAgent migration removed the prior definition"
  [ ! -e "$rollback_logical" ] || fail "failed LaunchAgent migration left a logical state namespace"
  [ ! -e "$rollback_logical_plist" ] || fail "failed LaunchAgent migration left a logical definition"
  assert_grep "bootstrap gui/$(id -u) $rollback_physical_plist" "$TMP_ROOT/state-migration-rollback-launchctl.log" \
    "failed logical health verification did not restart the prior LaunchAgent"

  staging_home="$TMP_ROOT/state-migration-stage-home"
  mkdir -p "$staging_home/projects" "$staging_home/config" "$staging_home/user/.treehouse"
  staging_logical_key=$(checkout_state_key "$staging_home" 16)
  staging_physical_key=6666666666666666
  [ "$staging_physical_key" != "$staging_logical_key" ] || staging_physical_key=7777777777777777
  staging_logical="$state_base/homes/$staging_logical_key"
  staging_physical="$state_base/homes/$staging_physical_key"
  staging_physical_plist="$agents/com.firstmate.checkout-refresh.$staging_physical_key.plist"
  mkdir -p "$staging_physical"
  printf 'preserved-stage\n' > "$staging_physical/external-identities"
  printf '<plist><string>%s/bin/fm-checkout-refresh.sh</string><key>FM_HOME</key><string>%s</string><key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>%s</string></plist>\n' \
    "$ROOT" "$(cd "$staging_home" && pwd -P)" "$staging_physical" > "$staging_physical_plist"
  set +e
  out=$(HOME="$staging_home/user" FM_HOME="$staging_home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$state_base" \
    FM_TREEHOUSE_ROOT="$staging_home/user/.treehouse" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_CHECKOUT_REFRESH_TEST=1 \
    FM_CHECKOUT_TEST_HOME_MIGRATION_FAILURE=stage \
    FM_TEST_LAUNCHCTL_LOG="$TMP_ROOT/state-migration-stage-launchctl.log" \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "partial home-state staging failure reported success"
  [ -f "$staging_physical/external-identities" ] || fail "partial staging failure damaged prior state"
  [ -f "$staging_physical_plist" ] || fail "partial staging failure removed prior LaunchAgent"
  [ ! -e "$staging_logical" ] || fail "partial staging failure published a logical namespace"

  mkdir -p "$state_base/homes/$current_physical_key"
  set +e
  out=$(HOME="$home/user" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$state_base" \
    FM_TREEHOUSE_ROOT="$home/user/.treehouse" \
    FM_CHECKOUT_REFRESH_PLATFORM=Linux \
    "$ROOT/bin/fm-checkout-refresh.sh" ensure 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "ambiguous state namespaces were accepted"
  assert_contains "$out" "ambiguous checkout-refresh home state namespaces" \
    "ambiguous state namespaces did not fail closed"
  pass "logical home state migration is discoverable, staged, and rollback-safe"
}

test_same_path_replacement_and_manifest_failures_are_unhealthy() {
  local home state checkout original_checkout first_remote second_remote out status
  home="$TMP_ROOT/replacement-home"
  state="$TMP_ROOT/replacement-state"
  checkout="$TMP_ROOT/replacement-checkout"
  original_checkout="$TMP_ROOT/replacement-checkout-original"
  mkdir -p "$home/projects" "$home/config" "$home/user/.treehouse" "$state"
  first_remote=$(build_origin replacement-first)
  second_remote=$(build_origin replacement-second)
  clone_from "$first_remote" "$checkout"
  printf 'path %s\n' "$checkout" > "$home/config/checkout-refresh"
  run_isolated_refresh "$home" "$state" run-once --force >/dev/null
  mv "$checkout" "$original_checkout"
  clone_from "$second_remote" "$checkout"
  set +e
  out=$(run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  set -e
  assert_contains "$out" "covered checkout" \
    "same-path checkout replacement was not tied to prior coverage"
  assert_contains "$out" "identity drifted" \
    "same-path checkout replacement was baselined instead of surfaced"
  assert_refresh_state "$state" unhealthy

  rm -rf "$checkout"
  clone_from "$first_remote" "$checkout"
  set +e
  out=$(run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  set -e
  assert_contains "$out" "physical identity drifted" \
    "same-origin physical replacement was baselined instead of surfaced"
  assert_refresh_state "$state" unhealthy

  set +e
  out=$(FM_CHECKOUT_TEST_MANIFEST_FAILURE=append run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "manifest append failure remained healthy"
  assert_refresh_state "$state" unhealthy
  set +e
  out=$(FM_CHECKOUT_TEST_MANIFEST_FAILURE=sort run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "manifest sort failure remained healthy"
  assert_refresh_state "$state" unhealthy
  pass "same-path replacement and manifest failures invalidate coverage"
}

test_legacy_identity_requires_physical_binding_and_migrates_transactionally() {
  local home state checkout remote origin stable_key physical_key legacy_prefix stable_prefix out
  home="$TMP_ROOT/legacy-identity-home"
  state="$TMP_ROOT/legacy-identity-state"
  checkout="$TMP_ROOT/legacy-identity-checkout"
  mkdir -p "$home/projects" "$home/config" "$home/user/.treehouse" "$state"
  remote=$(build_origin legacy-identity)
  clone_from "$remote" "$checkout"
  origin=$(git -C "$checkout" remote get-url origin)
  printf 'path %s\n' "$checkout" > "$home/config/checkout-refresh"
  stable_key=$(checkout_state_key "$checkout")
  physical_key=$(fm_checkout_physical_path_key "$checkout" directory 24)
  legacy_prefix="$state/aaaaaaaaaaaaaaaaaaaaaaaa"
  [ "${legacy_prefix##*/}" != "$physical_key" ] || legacy_prefix="$state/bbbbbbbbbbbbbbbbbbbbbbbb"
  printf '%s\norigin %s\n' "$checkout" "$origin" > "$legacy_prefix.identity"
  printf 'legacy-tip\n' > "$legacy_prefix.tip"
  set +e
  out=$(run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  set -e
  assert_contains "$out" "filename does not match the current physical checkout" \
    "unbindable legacy checkout identity did not surface its missing physical proof"
  assert_present "$legacy_prefix.identity" "unbindable legacy identity history was rewritten"
  assert_absent "$state/$stable_key.identity" "unbindable legacy identity was rebaselined"
  assert_refresh_state "$state" unhealthy

  mv "$legacy_prefix.identity" "$state/$physical_key.identity"
  mv "$legacy_prefix.tip" "$state/$physical_key.tip"
  legacy_prefix="$state/$physical_key"
  stable_prefix="$state/$stable_key"
  set +e
  out=$(FM_CHECKOUT_TEST_IDENTITY_MIGRATION_FAILURE=publish \
    run_isolated_refresh "$home" "$state" run-once --force 2>&1)
  set -e
  assert_present "$legacy_prefix.identity" "partial identity publish failure lost legacy identity"
  assert_present "$legacy_prefix.tip" "partial identity publish failure lost legacy tip"
  assert_absent "$stable_prefix.identity" "partial identity publish failure exposed destination identity"
  assert_absent "$stable_prefix.tip" "partial identity publish failure exposed destination tip"
  assert_refresh_state "$state" unhealthy

  run_isolated_refresh "$home" "$state" run-once --force >/dev/null \
    || fail "physically bound legacy identity did not migrate"
  [ "$(awk 'END { print NR + 0 }' "$stable_prefix.identity")" -eq 3 ] \
    || fail "migrated legacy identity did not retain its physical binding"
  assert_absent "$legacy_prefix.identity" "successful identity migration retained the legacy identity name"
  assert_absent "$legacy_prefix.tip" "successful identity migration retained the legacy tip name"
  assert_refresh_state "$state" healthy
  pass "legacy checkout identities require binding and publish transactionally"
}

test_lock_key_failure_cannot_construct_a_shared_lock_path() {
  local out status
  set +e
  out=$(bash -c '
    set -u
    . "$1/bin/fm-checkout-lock-lib.sh"
    fm_checkout_lock_key() { return 1; }
    fm_checkout_lock_path "$1" "$2"
  ' bash "$ROOT" "$TMP_ROOT/failed-lock-root" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failed lock-key derivation returned a lock path"
  [ -z "$out" ] || fail "failed lock-key derivation emitted a fallback lock path: $out"
  pass "lock-key derivation failure cannot collapse onto a shared lock path"
}

test_logical_lock_keys_survive_creation_and_atomic_replacement() {
  local home registry replacement missing_home_key created_home_key missing_registry_key replaced_registry_key
  home="$TMP_ROOT/aba-secondmate-home"
  registry="$TMP_ROOT/aba-data/secondmates.md"
  mkdir -p "$(dirname "$registry")"
  missing_home_key=$(fm_checkout_stable_path_key "$home" directory 1 24)
  missing_registry_key=$(fm_checkout_stable_path_key "$registry" file 1 24)
  mkdir -p "$home"
  printf 'initial\n' > "$registry"
  created_home_key=$(fm_checkout_stable_path_key "$home" directory 1 24)
  replacement="$registry.replacement"
  printf 'replacement\n' > "$replacement"
  mv "$replacement" "$registry"
  replaced_registry_key=$(fm_checkout_stable_path_key "$registry" file 1 24)
  [ "$missing_home_key" = "$created_home_key" ] || fail "home lifecycle lock key changed after home creation"
  [ "$missing_registry_key" = "$replaced_registry_key" ] || fail "registry lock key changed after atomic replacement"
  pass "logical lifecycle keys survive path creation and replacement"
}

if [ "${FM_TEST_FOCUSED:-}" = review-round-14 ]; then
  test_bounded_refresh_terminates_descendants
  test_launch_agent_definition_is_home_scoped_with_scheduler_seam
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-durable-identity ]; then
  test_logical_home_state_migrates_and_ambiguity_fails_closed
  test_same_path_replacement_and_manifest_failures_are_unhealthy
  test_legacy_identity_requires_physical_binding_and_migrates_transactionally
  test_lock_key_failure_cannot_construct_a_shared_lock_path
  test_logical_lock_keys_survive_creation_and_atomic_replacement
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-15 ]; then
  test_lock_root_failure_invalidates_coverage_before_preparation
  test_reinspection_failure_invalidates_coverage_health
  test_scheduler_liveness_is_scheduler_owned
  test_launch_agent_definition_is_home_scoped_with_scheduler_seam
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-16 ]; then
  test_reinspection_failure_invalidates_coverage_health
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-6 ]; then
  test_nested_active_project_invalidates_coverage_health
  test_bounded_refresh_terminates_descendants
  test_acquisition_honors_shared_checkout_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-7 ]; then
  test_discovery_rejects_nested_configured_and_scanned_paths
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-refresh-safety ]; then
  test_config_and_external_identity_fail_closed
  test_public_entrypoints_reject_nested_repository_paths
  test_explicit_secondmate_home_requires_live_default_tip
  test_session_mode_preserves_gone_branch_pruning
  test_lock_owner_symlink_cannot_escape_state_directory
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-refresh-followups ]; then
  test_unreadable_scan_root_invalidates_coverage_health
  test_unreadable_scanned_origin_invalidates_coverage_health
  test_failed_alert_persistence_forces_reinspection
  test_local_authority_is_fully_inspected_and_tracks_origin_identity
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-refresh-provenance ]; then
  test_discovery_provenance_failures_invalidate_coverage
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-refresh-symlinks ]; then
  test_discovery_covers_projects_treehouse_external_and_config
  test_treehouse_discovery_failure_invalidates_coverage_health
  test_raw_treehouse_root_symlink_invalidates_coverage_health
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-refresh-authority ]; then
  test_empty_treehouse_and_identity_tool_failures_fail_closed
  test_config_git_metadata_and_non_git_races_fail_closed
  test_public_entrypoints_reject_nested_repository_paths
  exit 0
fi

test_discovery_covers_projects_treehouse_external_and_config
test_uninspectable_active_project_invalidates_coverage_health
test_nested_active_project_invalidates_coverage_health
test_discovery_rejects_nested_configured_and_scanned_paths
test_upstream_tip_signal_refreshes_between_firstmate_events
test_periodic_backstop_repairs_drift_without_a_new_tip
test_live_default_change_is_surfaced_without_switching_branches
test_skill_drafts_surface_on_every_probe_without_log_spam
test_preflight_rejects_hygiene_without_an_origin
test_treehouse_pool_skill_drafts_are_inventoried
test_ignored_skill_files_are_outside_the_collision_guard
test_pool_preflight_surfaces_dirty_worktrees_without_blocking_clean_selection
test_bootstrap_relays_hygiene_alerts
test_treehouse_discovery_failure_invalidates_coverage_health
test_raw_treehouse_root_symlink_invalidates_coverage_health
test_empty_treehouse_and_identity_tool_failures_fail_closed
test_config_git_metadata_and_non_git_races_fail_closed
test_skill_inventory_failure_preserves_alert_and_invalidates_coverage
test_lock_root_failure_invalidates_coverage_before_preparation
test_reinspection_failure_invalidates_coverage_health
test_scheduler_liveness_is_scheduler_owned
test_unreadable_scan_root_invalidates_coverage_health
test_unreadable_scanned_origin_invalidates_coverage_health
test_discovery_provenance_failures_invalidate_coverage
test_failed_alert_persistence_forces_reinspection
test_local_authority_is_fully_inspected_and_tracks_origin_identity
test_dirty_nondefault_and_diverged_checkouts_are_untouched
test_refresh_locks_recover_stale_owners_and_surface_contention
test_session_mode_preserves_gone_branch_pruning
test_config_and_external_identity_fail_closed
test_public_entrypoints_reject_nested_repository_paths
test_explicit_secondmate_home_requires_live_default_tip
test_lock_owner_symlink_cannot_escape_state_directory
test_worktree_freshness_verification_fails_closed
test_bounded_refresh_terminates_descendants
test_acquisition_honors_shared_checkout_lock
test_launch_agent_definition_is_home_scoped_with_scheduler_seam
test_logical_home_state_migrates_and_ambiguity_fails_closed
test_same_path_replacement_and_manifest_failures_are_unhealthy
test_legacy_identity_requires_physical_binding_and_migrates_transactionally
test_lock_key_failure_cannot_construct_a_shared_lock_path
test_logical_lock_keys_survive_creation_and_atomic_replacement
