#!/usr/bin/env bash
# Behavior tests for the detect-only project-layout preflight.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-project-layout-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-layout-preflight)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
SOURCE="$TMP_ROOT/source"
REMOTE="$TMP_ROOT/source.git"

git -C "$TMP_ROOT" init -q -b main "$SOURCE" || fail "could not initialize source fixture"
printf '# fixture\n' > "$SOURCE/README.md"
git -C "$SOURCE" add README.md
git -C "$SOURCE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm initial \
  || fail "could not commit source fixture"
printf 'second\n' >> "$SOURCE/README.md"
git -C "$SOURCE" add README.md
git -C "$SOURCE" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm second \
  || fail "could not add second source commit"
git clone --quiet --bare "$SOURCE" "$REMOTE" || fail "could not create source bare remote"
ORIGIN_URL="file://$REMOTE"

setup_home() { # <home> <project-name>
  local home=$1 name=$2 project
  mkdir -p "$home/data" "$home/state" "$home/projects"
  project="$home/projects/$name"
  git clone --quiet "$ORIGIN_URL" "$project" || fail "could not clone $name fixture"
  git -C "$project" remote set-head origin --auto >/dev/null 2>&1 \
    || fail "could not set cached origin HEAD for $name"
  printf -- '- %s [direct-PR] - fixture project (added 2026-08-17)\n' "$name" > "$home/data/projects.md"
}

run_json() { # <home> <project> [extra args...]
  local home=$1 project=$2
  shift 2
  "$PREFLIGHT" --home "$home" --project "$project" --json "$@"
}

json_valid() {
  printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || fail "preflight did not emit valid JSON"
}

json_value() { # <json> <python-expression over d>
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)"
}

assert_json_code() { # <json> <blockers|warnings> <code>
  local json=$1 kind=$2 code=$3
  printf '%s' "$json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
kind, code=sys.argv[1:]
raise SystemExit(0 if code in [item["code"] for item in doc[kind]] else 1)
' "$kind" "$code" || fail "missing $kind code $code"
}

assert_no_json_code() { # <json> <blockers|warnings> <code>
  local json=$1 kind=$2 code=$3
  if printf '%s' "$json" | python3 -c '
import json,sys
doc=json.load(sys.stdin)
kind, code=sys.argv[1:]
raise SystemExit(0 if code in [item["code"] for item in doc[kind]] else 1)
' "$kind" "$code"; then
    fail "unexpected $kind code $code"
  fi
}

snapshot_fixture() { # <home> <project>
  local home=$1 project=$2 git_dir
  git_dir=$(git -C "$project" rev-parse --absolute-git-dir)
  {
    cksum "$home/data/projects.md"
    if [ -d "$home/state" ]; then
      find "$home/state" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
        cksum "$file"
      done
    fi
    GIT_OPTIONAL_LOCKS=0 git -C "$project" status --porcelain=v1
    GIT_OPTIONAL_LOCKS=0 git -C "$project" show-ref
    GIT_OPTIONAL_LOCKS=0 git -C "$project" config --local --list --show-origin
    GIT_OPTIONAL_LOCKS=0 git -C "$project" worktree list --porcelain
    find "$git_dir" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      cksum "$file"
    done
  } | LC_ALL=C sort
}

snapshot_git_admin() { # <worktree-or-bare-repo>
  local repo=$1 git_dir
  git_dir=$(git -C "$repo" rev-parse --absolute-git-dir) || return 1
  {
    GIT_OPTIONAL_LOCKS=0 git -C "$repo" show-ref
    GIT_OPTIONAL_LOCKS=0 git -C "$repo" config --local --list --show-origin
    find "$git_dir" -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      cksum "$file"
    done
  } | LC_ALL=C sort
}

test_help_and_ready_json() {
  local home="$TMP_ROOT/ready home" cache="$TMP_ROOT/ready-cache.git" out rc cache_before cache_after
  setup_home "$home" sample
  git clone --quiet --bare "$ORIGIN_URL" "$cache"
  chmod 0700 "$cache"
  cache_before=$(snapshot_git_admin "$cache")
  out=$($PREFLIGHT --help) || fail "--help failed"
  assert_contains "$out" "performs no migration or cutover" "help omitted the detect-only boundary"
  out=$(run_json "$home" sample --cache-root "$cache")
  rc=$?
  expect_code 0 "$rc" "ready preflight"
  json_valid "$out"
  [ "$(json_value "$out" 'd["schema"]')" = fm-project-layout-preflight.v1 ] \
    || fail "wrong JSON schema"
  [ "$(json_value "$out" 'd["status"]')" = ready ] || fail "clean fixture was not ready"
  [ "$(json_value "$out" 'd["read_only"]')" = True ] || fail "read_only was not true"
  [ "$(json_value "$out" 'd["fingerprint"]["cutover_authority"]')" = False ] \
    || fail "fingerprint was represented as cutover authority"
  cache_after=$(snapshot_git_admin "$cache")
  [ "$cache_before" = "$cache_after" ] || fail "preflight changed cache refs, config, hooks, or objects"
  pass "clean managed clone produces deterministic ready evidence, not cutover authority"
}

test_idempotence_and_byte_invariance() {
  local home="$TMP_ROOT/invariant" project before between after one two
  setup_home "$home" sample
  project="$home/projects/sample"
  before=$(snapshot_fixture "$home" "$project")
  one=$(run_json "$home" sample) || fail "first invariant preflight blocked"
  between=$(snapshot_fixture "$home" "$project")
  two=$(run_json "$home" sample) || fail "second invariant preflight blocked"
  after=$(snapshot_fixture "$home" "$project")
  [ "$one" = "$two" ] || fail "repeat preflights emitted different evidence"
  [ "$before" = "$between" ] || fail "first preflight changed repository, registry, refs, config, index, or state bytes"
  [ "$between" = "$after" ] || fail "second preflight changed repository, registry, refs, config, index, or state bytes"
  pass "repeat preflight is byte-for-byte deterministic and leaves repository/state/config/refs unchanged"
}

test_dirty_off_default_and_unpushed() {
  local home="$TMP_ROOT/repository blockers" project out rc
  setup_home "$home" sample
  project="$home/projects/sample"
  git -C "$project" switch -q -c feature
  printf 'uncommitted\n' >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm local
  printf 'dirty\n' >> "$project/README.md"
  out=$(run_json "$home" sample)
  rc=$?
  expect_code 1 "$rc" "repository blocker preflight"
  assert_json_code "$out" blockers off_default
  assert_json_code "$out" blockers dirty_worktree
  assert_json_code "$out" blockers unpushed_commits
  pass "dirty, off-default, and unpushed repository state fails closed"
}

test_secret_redaction() {
  local home="$TMP_ROOT/credential" project out rc secret=supersecret query=moresecret
  setup_home "$home" sample
  project="$home/projects/sample"
  git -C "$project" remote set-url origin "https://user:$secret@example.invalid/team/app.git?token=$query"
  out=$(run_json "$home" sample)
  rc=$?
  expect_code 1 "$rc" "credential preflight"
  json_valid "$out"
  assert_json_code "$out" blockers origin_embedded_credentials
  assert_not_contains "$out" "$secret" "credential leaked into preflight output"
  assert_not_contains "$out" "$query" "query credential leaked into preflight output"
  assert_contains "$out" '<redacted>@example.invalid/team/app.git' "redacted origin identity was not reported"
  git -C "$project" remote set-url origin "https://example.invalid/team/app.git?token=$query"
  out=$(run_json "$home" sample)
  rc=$?
  expect_code 1 "$rc" "query credential preflight"
  assert_json_code "$out" blockers origin_embedded_credentials
  assert_not_contains "$out" "$query" "credential-only query leaked without URL userinfo"
  pass "credential-bearing origins are blocked and secrets never enter output or fingerprint"
}

test_symlink_and_cache_permission_hazards() {
  local home="$TMP_ROOT/symlink" outside="$TMP_ROOT/outside" cache="$TMP_ROOT/cache.git" missing="$TMP_ROOT/missing-cache.git" out rc
  setup_home "$home" sample
  mkdir -p "$outside"
  ln -s "$outside" "$home/projects/escape"
  out=$(run_json "$home" escape)
  rc=$?
  expect_code 1 "$rc" "symlink preflight"
  assert_json_code "$out" blockers project_symlink
  assert_json_code "$out" blockers project_path_escape

  out=$(run_json "$home" sample --cache-root "$missing")
  rc=$?
  expect_code 1 "$rc" "missing cache preflight"
  assert_json_code "$out" blockers cache_missing
  assert_absent "$missing" "detect-only preflight created the proposed cache path"

  git clone --quiet --bare "$ORIGIN_URL" "$cache"
  chmod 0777 "$cache"
  out=$(run_json "$home" sample --cache-root "$cache")
  rc=$?
  expect_code 1 "$rc" "cache permission preflight"
  assert_json_code "$out" blockers cache_permissions
  pass "symlink escape and non-owner-only cache permissions fail closed"
}

test_alternate_shallow_partial_promisor_and_replace() {
  local alternate_home="$TMP_ROOT/alternate" shallow_home="$TMP_ROOT/shallow" project out rc head parent
  setup_home "$alternate_home" sample
  project="$alternate_home/projects/sample"
  printf '%s/objects\n' "$REMOTE" > "$project/.git/objects/info/alternates"
  git -C "$project" config extensions.partialClone origin
  git -C "$project" config remote.origin.promisor true
  git -C "$project" config remote.origin.partialclonefilter blob:none
  head=$(git -C "$project" rev-parse HEAD)
  parent=$(git -C "$project" rev-parse HEAD^)
  git -C "$project" update-ref "refs/replace/$head" "$parent"
  printf '%s %s\n' "$head" "$parent" > "$project/.git/info/grafts"
  out=$(run_json "$alternate_home" sample)
  rc=$?
  expect_code 1 "$rc" "alternate feature preflight"
  assert_json_code "$out" blockers unexpected_alternate
  assert_json_code "$out" blockers partial_clone
  assert_json_code "$out" blockers promisor_remote
  assert_json_code "$out" blockers replace_refs
  assert_json_code "$out" blockers grafts

  mkdir -p "$shallow_home/data" "$shallow_home/state" "$shallow_home/projects"
  git clone --quiet --depth 1 "$ORIGIN_URL" "$shallow_home/projects/sample"
  git -C "$shallow_home/projects/sample" remote set-head origin --auto >/dev/null 2>&1
  printf -- '- sample [direct-PR] - fixture project (added 2026-08-17)\n' > "$shallow_home/data/projects.md"
  out=$(run_json "$shallow_home" sample)
  rc=$?
  expect_code 1 "$rc" "shallow preflight"
  assert_json_code "$out" blockers shallow_repository
  pass "alternate, shallow, partial, promisor, replace, and graft states are observable blockers"
}

test_no_origin_and_diverged_default() {
  local no_origin_home="$TMP_ROOT/no-origin" diverged_home="$TMP_ROOT/diverged"
  local project divergent_remote="$TMP_ROOT/divergent.git" publisher="$TMP_ROOT/publisher" out rc
  setup_home "$no_origin_home" sample
  git -C "$no_origin_home/projects/sample" remote remove origin
  out=$(run_json "$no_origin_home" sample)
  rc=$?
  expect_code 1 "$rc" "no-origin preflight"
  assert_json_code "$out" blockers no_origin
  assert_json_code "$out" blockers default_branch_unknown

  git clone --quiet --bare "$ORIGIN_URL" "$divergent_remote"
  setup_home "$diverged_home" sample
  project="$diverged_home/projects/sample"
  git -C "$project" remote set-url origin "file://$divergent_remote"
  git -C "$project" fetch -q origin
  git -C "$project" remote set-head origin --auto >/dev/null 2>&1
  printf 'local\n' >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm local
  git clone --quiet "file://$divergent_remote" "$publisher"
  printf 'remote\n' > "$publisher/remote.txt"
  git -C "$publisher" add remote.txt
  git -C "$publisher" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm remote
  git -C "$publisher" push -q origin main
  git -C "$project" fetch -q origin
  out=$(run_json "$diverged_home" sample)
  rc=$?
  expect_code 1 "$rc" "diverged preflight"
  assert_json_code "$out" blockers default_diverged
  assert_json_code "$out" blockers unpushed_commits
  pass "no-origin and diverged default states fail closed from local evidence"
}

test_cache_identity_and_format_mismatch() {
  local home="$TMP_ROOT/cache identity" other="$TMP_ROOT/other" other_remote="$TMP_ROOT/other.git"
  local cache="$TMP_ROOT/mismatch-cache.git" sha_cache="$TMP_ROOT/sha-cache.git" out rc
  setup_home "$home" sample
  fm_git_init_commit "$other"
  git clone --quiet --bare "$other" "$other_remote"
  git clone --quiet --bare "file://$other_remote" "$cache"
  chmod 0700 "$cache"
  out=$(run_json "$home" sample --cache-root "$cache")
  rc=$?
  expect_code 1 "$rc" "cache origin mismatch preflight"
  assert_json_code "$out" blockers cache_origin_mismatch

  if git init -q --bare --object-format=sha256 "$sha_cache" 2>/dev/null; then
    git -C "$sha_cache" remote add origin "$ORIGIN_URL"
    chmod 0700 "$sha_cache"
    out=$(run_json "$home" sample --cache-root "$sha_cache")
    rc=$?
    expect_code 1 "$rc" "cache object format mismatch preflight"
    assert_json_code "$out" blockers cache_object_format_mismatch
  fi
  pass "cache origin and supported object-format mismatches fail closed"
}

test_live_work_endpoint_orca_pending_and_no_mistakes_worktree() {
  local home="$TMP_ROOT/live" project gate_wt out rc
  gate_wt="$home/.no-mistakes/runs/run-1"
  setup_home "$home" sample
  project="$home/projects/sample"
  mkdir -p "$(dirname "$gate_wt")"
  git -C "$project" worktree add -q --detach "$gate_wt" HEAD
  fm_write_meta "$home/state/same-id.meta" \
    "project=$project" "worktree=$gate_wt" "window=terminal-1" \
    "endpoint_task_id=same-id" "backend=orca" "orca_worktree_id=orca-1"
  mkdir -p "$home/state/pending-replies"
  fm_write_meta "$home/state/pending-replies/0123456789abcdef" \
    "schema=fm-pending-reply.v1" "task_id=same-id" "phase=awaiting_report"
  out=$(run_json "$home" sample)
  rc=$?
  expect_code 1 "$rc" "live work preflight"
  assert_json_code "$out" blockers linked_worktrees
  assert_json_code "$out" blockers no_mistakes_run_worktree
  assert_json_code "$out" blockers live_task_metadata
  assert_json_code "$out" blockers live_endpoint
  assert_json_code "$out" blockers live_orca
  assert_json_code "$out" blockers pending_reply
  pass "linked run worktree, live metadata, endpoint, Orca, and pending reply all block"
}

test_unreadable_cache_and_taskless_pending_reply() {
  local home="$TMP_ROOT/unreadable" cache="$TMP_ROOT/unreadable-cache.git" out rc

  setup_home "$home" sample
  mkdir -p "$home/state/pending-replies"
  fm_write_meta "$home/state/pending-replies/0123456789abcdef" \
    "schema=fm-pending-reply.v1" "phase=awaiting_report"
  out=$(run_json "$home" sample)
  rc=$?
  expect_code 0 "$rc" "taskless pending reply preflight"
  assert_no_json_code "$out" blockers pending_reply
  [ "$(json_value "$out" 'd["live"]["pending_reply_count"]')" = 0 ] \
    || fail "taskless pending reply was counted as live"

  out=$(run_json "$home" sample --cache-root "$TMP_ROOT/cache/../escape.git")
  rc=$?
  expect_code 1 "$rc" "lexically unsafe cache preflight"
  assert_json_code "$out" blockers cache_path_unsafe
  assert_no_json_code "$out" blockers cache_missing
  assert_no_json_code "$out" blockers cache_not_git
  assert_no_json_code "$out" blockers cache_filesystem_unknown
  [ "$(json_value "$out" 'd["proposal"]["cache_locality"]')" = not-supplied ] \
    || fail "unsafe cache path was probed for filesystem locality"
  [ "$(json_value "$out" 'json.dumps(d["proposal"]["cache_is_git"])')" = false ] \
    || fail "unsafe cache path was probed with Git"

  if [ "$(id -u)" -eq 0 ]; then
    pass "taskless pending replies are ignored (unreadable-path coverage needs a non-root user)"
    return 0
  fi

  mkdir -p "$home/projects/unreadable"
  chmod 0600 "$home/projects/unreadable"
  out=$(run_json "$home" unreadable)
  rc=$?
  chmod 0700 "$home/projects/unreadable"
  expect_code 1 "$rc" "unreadable project preflight"
  assert_json_code "$out" blockers project_unresolved
  assert_no_json_code "$out" blockers project_path_escape
  assert_no_json_code "$out" blockers project_not_worktree
  assert_no_json_code "$out" blockers dirty_worktree
  assert_no_json_code "$out" blockers off_default
  [ "$(json_value "$out" 'd["repository"]["origin"]')" = "" ] \
    || fail "unresolved project borrowed an origin from the caller repository"
  [ "$(json_value "$out" 'd["repository"]["object_format"]')" = unknown ] \
    || fail "unresolved project borrowed an object format from the caller repository"

  mkdir -p "$cache"
  chmod 0600 "$cache"
  out=$(run_json "$home" sample --cache-root "$cache")
  rc=$?
  chmod 0700 "$cache"
  expect_code 1 "$rc" "unreadable cache preflight"
  assert_json_code "$out" blockers cache_unresolved
  assert_no_json_code "$out" blockers cache_not_bare
  assert_no_json_code "$out" blockers cache_not_git
  assert_no_json_code "$out" blockers cache_owner_mismatch
  assert_no_json_code "$out" blockers cache_permissions
  assert_no_json_code "$out" blockers cache_filesystem_unknown
  assert_no_json_code "$out" blockers cache_network_filesystem
  [ "$(json_value "$out" 'd["proposal"]["cache_uid"]')" = unknown ] \
    || fail "unresolved cache reported an ownership claim"
  [ "$(json_value "$out" 'd["proposal"]["cache_mode"]')" = unknown ] \
    || fail "unresolved cache reported a mode claim"
  [ "$(json_value "$out" 'd["proposal"]["cache_object_format"]')" = unknown ] \
    || fail "unresolved cache borrowed an object format from another repository"
  [ "$(json_value "$out" 'd["proposal"]["cache_origin"]')" = "" ] \
    || fail "unresolved cache borrowed an origin from another repository"
  [ "$(json_value "$out" 'json.dumps(d["proposal"]["cache_is_git"])')" = false ] \
    || fail "unreadable cache borrowed Git evidence from another repository"
  pass "unreadable cache paths never yield foreign Git evidence and taskless pending replies are ignored"
}

test_duplicate_cross_home_branch_and_remote_isolation() {
  local home="$TMP_ROOT/parent" child="$TMP_ROOT/child" project child_project out rc remote_path=/remote/private/home
  setup_home "$home" sample
  setup_home "$child" sample
  project="$home/projects/sample"
  child_project="$child/projects/sample"
  fm_write_meta "$home/state/collision.meta" "project=$project" "worktree=$project" "endpoint_task_id=collision"
  fm_write_meta "$child/state/collision.meta" "project=$child_project" "worktree=$child_project" "endpoint_task_id=collision"
  {
    printf -- '- local-mate - fixture (home: %s; scope: sample; projects: sample; added 2026-08-17)\n' "$child"
    printf -- '- remote-mate - fixture (host: build-host; root: /remote/code; home: %s; scope: sample; projects: sample; added 2026-08-17)\n' "$remote_path"
  } > "$home/data/secondmates.md"
  out=$(run_json "$home" sample)
  rc=$?
  expect_code 1 "$rc" "duplicate branch preflight"
  assert_json_code "$out" blockers duplicate_cross_home_branch
  assert_json_code "$out" warnings remote_home_unverified
  assert_not_contains "$out" "$remote_path" "remote home path leaked into local preflight evidence"
  [ "$(json_value "$out" 'd["live"]["remote_borrower_count"]')" = 1 ] \
    || fail "remote borrower was not counted without resolving its path"
  pass "duplicate cross-home fm/id is blocked and remote placement never receives a local path"
}

test_canonical_checkout_is_navigation_only() {
  local home="$TMP_ROOT/canonical" project human="$TMP_ROOT/human checkout" linked="$TMP_ROOT/linked human" out rc human_before human_after
  setup_home "$home" sample
  project="$home/projects/sample"
  git clone --quiet "$ORIGIN_URL" "$human"
  human_before=$(snapshot_git_admin "$human")
  out=$(run_json "$home" sample --canonical-path "$human") \
    || fail "independent canonical checkout should remain navigation-only evidence"
  assert_no_json_code "$out" blockers canonical_shares_common_dir
  human_after=$(snapshot_git_admin "$human")
  [ "$human_before" = "$human_after" ] || fail "preflight changed the human checkout's refs, config, hooks, index, or objects"
  git -C "$project" worktree add -q --detach "$linked" HEAD
  out=$(run_json "$home" sample --canonical-path "$linked")
  rc=$?
  expect_code 1 "$rc" "linked canonical preflight"
  assert_json_code "$out" blockers canonical_shares_common_dir
  pass "independent human checkout is navigation-only while a shared common dir is refused"
}

test_spaces_and_metacharacters_are_literal() {
  local home="$TMP_ROOT/metachar home" name="project \$(touch SHOULD_NOT_EXIST) [x]" project out rc sentinel="$PWD/SHOULD_NOT_EXIST"
  mkdir -p "$home/data" "$home/state" "$home/projects"
  project="$home/projects/$name"
  git clone --quiet "$ORIGIN_URL" "$project"
  git -C "$project" remote set-head origin --auto >/dev/null 2>&1
  out=$(run_json "$home" "$name")
  rc=$?
  expect_code 1 "$rc" "metacharacter preflight"
  json_valid "$out"
  assert_json_code "$out" blockers unregistered_project
  assert_absent "$sentinel" "project name metacharacters were executed"
  assert_contains "$out" "$name" "literal project name was not preserved"
  pass "spaces and shell metacharacters remain literal and deterministic"
}

test_ambient_git_environment_cannot_substitute_another_repository() {
  local home="$TMP_ROOT/ambient" project decoy clean ambient rc
  setup_home "$home" sample
  project="$home/projects/sample"
  decoy="$TMP_ROOT/ambient-decoy"
  git clone --quiet "$ORIGIN_URL" "$decoy" || fail "could not clone ambient decoy"
  git -C "$decoy" remote set-url origin https://decoy.invalid/team/decoy.git
  git -C "$decoy" switch -q -c decoy-branch
  printf 'decoy\n' >> "$decoy/README.md"
  clean=$(run_json "$home" sample) || fail "ambient baseline preflight blocked"
  ambient=$(GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" \
    GIT_INDEX_FILE="$decoy/.git/index" GIT_OBJECT_DIRECTORY="$decoy/.git/objects" \
    run_json "$home" sample)
  rc=$?
  expect_code 0 "$rc" "ambient git environment preflight"
  [ "$ambient" = "$clean" ] \
    || fail "ambient GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_OBJECT_DIRECTORY changed reported repository facts"
  assert_not_contains "$ambient" "decoy.invalid" "ambient repository origin leaked into the report"
  assert_not_contains "$ambient" "decoy-branch" "ambient repository branch leaked into the report"
  pass "hostile ambient Git environment cannot substitute another repository"
}

test_unverifiable_ownership_fails_closed() {
  local home="$TMP_ROOT/unverifiable" stub="$TMP_ROOT/stat-stub" out rc
  setup_home "$home" sample
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/stat"
  chmod 0755 "$stub/stat"
  out=$(PATH="$stub:$PATH" run_json "$home" sample)
  rc=$?
  expect_code 1 "$rc" "unverifiable ownership preflight"
  json_valid "$out"
  assert_json_code "$out" blockers home_owner_mismatch
  assert_json_code "$out" blockers home_writable_by_others
  assert_json_code "$out" blockers project_owner_mismatch
  assert_json_code "$out" blockers project_writable_by_others
  [ "$(json_value "$out" 'd["status"]')" != ready ] || fail "unverifiable ownership reported ready"
  pass "unverifiable ownership and permissions fail closed"
}

test_ambient_git_config_injection_cannot_alter_evidence() {
  local home="$TMP_ROOT/ambient config" clean injected rc
  setup_home "$home" sample
  clean=$(run_json "$home" sample) || fail "ambient config baseline preflight blocked"
  injected=$(GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=remote.evil.promisor GIT_CONFIG_VALUE_0=true \
    GIT_CONFIG_KEY_1=extensions.partialclone GIT_CONFIG_VALUE_1=evil \
    GIT_CONFIG_KEY_2=extensions.objectformat GIT_CONFIG_VALUE_2=sha256 \
    GIT_CONFIG_PARAMETERS="'extensions.objectformat=sha256'" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    run_json "$home" sample)
  rc=$?
  expect_code 0 "$rc" "ambient git config injection preflight"
  [ "$injected" = "$clean" ] \
    || fail "ambient GIT_CONFIG_* injection changed reported repository evidence"
  pass "ambient Git config injection cannot alter reported repository evidence"
}

test_ambient_home_overrides_cannot_substitute_another_home() {
  local home="$TMP_ROOT/ambient overrides" decoy clean injected rc
  setup_home "$home" sample
  decoy="$TMP_ROOT/ambient-overrides-decoy"
  mkdir -p "$decoy/data" "$decoy/bin"
  printf -- '- sample [local-only +yolo] - decoy project (added 2026-08-17)\n' > "$decoy/data/projects.md"
  printf '#!/bin/sh\necho "local-only on"\n' > "$decoy/bin/fm-project-mode.sh"
  chmod 0755 "$decoy/bin/fm-project-mode.sh"
  clean=$(run_json "$home" sample) || fail "ambient override baseline preflight blocked"
  injected=$(FM_DATA_OVERRIDE="$decoy/data" FM_ROOT_OVERRIDE="$decoy" run_json "$home" sample)
  rc=$?
  expect_code 0 "$rc" "ambient home override preflight"
  [ "$injected" = "$clean" ] \
    || fail "ambient FM_DATA_OVERRIDE/FM_ROOT_OVERRIDE changed reported home posture"
  assert_not_contains "$injected" "local-only" "decoy home mode leaked into the report"
  assert_not_contains "$injected" "\"yolo\":\"on\"" "decoy home yolo posture leaked into the report"
  pass "ambient home overrides cannot substitute another home's posture"
}

test_nested_directory_cannot_borrow_ancestor_repository() {
  local home="$TMP_ROOT/nested" out rc
  mkdir -p "$home/data" "$home/state"
  git clone --quiet "$ORIGIN_URL" "$home/outer" || fail "could not clone nested ancestor"
  git -C "$home/outer" remote set-url origin https://ancestor.invalid/team/outer.git
  mkdir -p "$home/outer/projects/sample"
  printf -- '- sample [direct-PR] - fixture project (added 2026-08-17)\n' > "$home/data/projects.md"
  out=$(run_json "$home/outer" sample)
  rc=$?
  expect_code 1 "$rc" "nested ancestor preflight"
  json_valid "$out"
  assert_json_code "$out" blockers project_not_worktree
  assert_not_contains "$out" "ancestor.invalid" "ancestor repository origin leaked into project evidence"
  pass "plain nested directory cannot borrow an ancestor repository identity"
}

test_help_and_ready_json
test_ambient_git_environment_cannot_substitute_another_repository
test_ambient_git_config_injection_cannot_alter_evidence
test_ambient_home_overrides_cannot_substitute_another_home
test_nested_directory_cannot_borrow_ancestor_repository
test_unverifiable_ownership_fails_closed
test_idempotence_and_byte_invariance
test_dirty_off_default_and_unpushed
test_secret_redaction
test_symlink_and_cache_permission_hazards
test_alternate_shallow_partial_promisor_and_replace
test_no_origin_and_diverged_default
test_cache_identity_and_format_mismatch
test_live_work_endpoint_orca_pending_and_no_mistakes_worktree
test_unreadable_cache_and_taskless_pending_reply
test_duplicate_cross_home_branch_and_remote_isolation
test_canonical_checkout_is_navigation_only
test_spaces_and_metacharacters_are_literal

echo "ALL TESTS PASSED"
