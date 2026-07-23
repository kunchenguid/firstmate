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

  assert_contains "$out" "$project: STUCK: on branch main" \
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

test_bootstrap_relays_hygiene_alerts() {
  local project draft out
  project=$(cd "$FM_TEST_HOME/projects/relvino" && pwd -P)
  draft="$project/.agents/skills/bootstrap-draft/SKILL.md"
  mkdir -p "$(dirname "$draft")"
  printf '%s\n' '# bootstrap draft' > "$draft"

  out=$(HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" FM_TREEHOUSE_ROOT="$TEST_HOME/.treehouse" \
    FM_CHECKOUT_REFRESH_BOOTSTRAP_TEST=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: $project: HYGIENE: 1 untracked skill-draft files" \
    "session-start bootstrap did not relay the unresolved hygiene alert"
  grep -Fq '# bootstrap draft' "$draft" || fail "bootstrap refresh changed the draft"
  rm -rf "$project/.agents"
  run_refresh run-once >/dev/null
  pass "session-start bootstrap relays unresolved skill-draft hygiene"
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
  local run_lock="$STATE_ROOT/.run-lock" checkout key checkout_lock out
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
  key=$(printf '%s' "$checkout" | shasum -a 256 | awk '{print substr($1,1,24)}')
  checkout_lock="$LOCK_ROOT/$key.lock"
  mkdir -p "$checkout_lock"
  printf '%s\n' "$$" > "$checkout_lock/pid"
  out=$(run_refresh run-once --force)
  assert_contains "$out" "$checkout: skipped: refresh already running (pid $$)" \
    "shared-checkout lock contention was not surfaced"
  rm -rf "$checkout_lock"
  pass "refresh locks recover abandoned owners and serialize shared checkouts"
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
  local remote primary worktree no_origin before status
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
    "$ROOT/bin/fm-checkout-refresh.sh" verify-worktree "$worktree" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "stale acquired worktree passed freshness verification"

  git -C "$primary" fetch -q origin
  git -C "$worktree" checkout --quiet --detach origin/main
  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_ROOT="$STATE_ROOT" \
    "$ROOT/bin/fm-checkout-refresh.sh" verify-worktree "$worktree" \
    || fail "fresh acquired worktree failed verification"

  no_origin="$TMP_ROOT/verify-no-origin"
  fm_git_init_commit "$no_origin"
  set +e
  run_refresh verify-worktree "$no_origin" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "originless acquired worktree passed freshness verification"
  pass "post-acquisition proof refuses a worktree whose HEAD is not the upstream default tip"
}

test_launch_agent_definition_is_home_scoped_with_scheduler_seam() {
  local fakebin agents log plist second_home second_plist key second_key install_state_base out status
  fakebin="$TMP_ROOT/fakebin"
  agents="$TMP_ROOT/LaunchAgents"
  log="$TMP_ROOT/launchctl.log"
  install_state_base="$TMP_ROOT/install-state"
  mkdir -p "$fakebin" "$agents"
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_LAUNCHCTL_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/launchctl"

  HOME="$TEST_HOME" FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$install_state_base" \
    FM_CHECKOUT_REFRESH_PLATFORM=Darwin \
    FM_CHECKOUT_REFRESH_LAUNCH_AGENTS_DIR="$agents" \
    FM_CHECKOUT_REFRESH_LAUNCHCTL="$fakebin/launchctl" \
    FM_FAKE_LAUNCHCTL_LOG="$log" \
    "$ROOT/bin/fm-checkout-refresh.sh" install

  key=$(printf '%s' "$(cd "$FM_TEST_HOME" && pwd -P)" | shasum -a 256 | awk '{print substr($1,1,16)}')
  plist="$agents/com.firstmate.checkout-refresh.$key.plist"
  assert_grep '<key>StartInterval</key><integer>60</integer>' "$plist" \
    "LaunchAgent does not carry the upstream signal cadence"
  assert_grep '<key>FM_CHECKOUT_REFRESH_BACKSTOP</key><string>900</string>' "$plist" \
    "LaunchAgent does not persist the timed backstop"
  assert_grep 'fm-checkout-refresh.sh</string>' "$plist" \
    "LaunchAgent does not invoke the checkout refresher"
  assert_grep "<key>FM_HOME</key><string>$(cd "$FM_TEST_HOME" && pwd -P)</string>" "$plist" \
    "LaunchAgent does not bind the active Firstmate home"
  assert_grep "<key>FM_CHECKOUT_REFRESH_STATE_ROOT</key><string>$install_state_base/homes/$key</string>" "$plist" \
    "LaunchAgent does not use home-scoped state"
  assert_grep "<key>FM_CHECKOUT_REFRESH_LOCK_ROOT</key><string>$install_state_base/locks</string>" "$plist" \
    "LaunchAgent does not use the shared checkout lock root"
  assert_grep 'bootstrap' "$log" "LaunchAgent was not bootstrapped"
  assert_grep 'kickstart' "$log" "LaunchAgent was not started"

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

test_discovery_covers_projects_treehouse_external_and_config
test_upstream_tip_signal_refreshes_between_firstmate_events
test_periodic_backstop_repairs_drift_without_a_new_tip
test_live_default_change_is_surfaced_without_switching_branches
test_skill_drafts_surface_on_every_probe_without_log_spam
test_preflight_rejects_hygiene_without_an_origin
test_treehouse_pool_skill_drafts_are_inventoried
test_bootstrap_relays_hygiene_alerts
test_dirty_nondefault_and_diverged_checkouts_are_untouched
test_refresh_locks_recover_stale_owners_and_surface_contention
test_session_mode_preserves_gone_branch_pruning
test_worktree_freshness_verification_fails_closed
test_launch_agent_definition_is_home_scoped_with_scheduler_seam
