#!/usr/bin/env bash
# Behavior tests for fm-vault-drift.sh, the read-only documentation-vault drift
# detector.
#
# The check exists because a project's vault fell dozens of commits behind with
# nothing surfacing it, so these cases pin the four properties that make it
# trustworthy rather than noisy:
#   - the two vault shapes are told apart by INSPECTION, because they need
#     different remedies: an in-repo vault a crewmate can refresh in its own
#     worktree, and an external vault living in a separate repo that a project
#     worktree structurally cannot write;
#   - an absent or broken external link reports distinctly from a stale vault,
#     because "drift cannot be measured at all" is a different problem from
#     "drift measured and too large" - the ArkNode-AI case has both at once;
#   - a project with no vault, and a directory that merely shares the name
#     vault/ without the OKF bundle marker, produce no output at all;
#   - staleness is reported with the commit count behind and the drift window,
#     measured from commit timestamps so a run is deterministic.
# Bootstrap's relay of these lines is pinned in tests/fm-bootstrap.test.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-vault-drift-tests)
DRIFT="$ROOT/bin/fm-vault-drift.sh"

# Fixed fixture clock. Every commit gets an explicit epoch so drift windows are
# byte-stable regardless of when the suite runs.
DAY=86400
T0=1700000000 # 2023-11-14 22:13:20 UTC
T0_DATE=2023-11-14

# --- fixtures ---------------------------------------------------------------

# new_home <case-label>: a fresh isolated FM_HOME with an empty projects/ dir.
# The label is explicit rather than a counter because new_home is called in a
# command substitution, where a counter would never advance in the parent and
# every case would silently share one home and one set of fixture commits.
new_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

# commit_at <repo> <epoch> <path> <content> <msg>
commit_at() {
  local repo=$1 epoch=$2 path=$3 content=$4 msg=$5
  mkdir -p "$repo/$(dirname "$path")"
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add -A -- "$path"
  GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" \
    git -C "$repo" commit -qm "$msg" \
    || fail "fixture commit failed in $repo: $msg"
}

# init_repo <dir> <epoch>: a git repo with one initial commit.
init_repo() {
  local dir=$1 epoch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name fmtest
  git -C "$dir" config user.email fmtest@example.invalid
  commit_at "$dir" "$epoch" README.md "# $(basename "$dir")" initial
}

# project_commits <repo> <count> <epoch>: <count> ordinary project commits.
project_commits() {
  local repo=$1 count=$2 epoch=$3 i
  for ((i = 1; i <= count; i++)); do
    commit_at "$repo" "$epoch" "src/file-$i.txt" "change $i" "work $i"
  done
}

# in_repo_vault <repo> <epoch> [relpath]: commit an OKF vault bundle in the repo.
in_repo_vault() {
  local repo=$1 epoch=$2 rel=${3:-vault}
  commit_at "$repo" "$epoch" "$rel/00-Home.md" '# Vault home' "vault: seed $rel"
}

# external_vault <dir> <epoch>: a separate vault repo carrying the bundle marker.
external_vault() {
  local dir=$1 epoch=$2
  init_repo "$dir" "$epoch"
  commit_at "$dir" "$epoch" 00-Home.md '# Vault home' 'vault: seed'
}

declare_external() {
  local repo=$1
  shift
  printf '%s\n' "$@" > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  GIT_AUTHOR_DATE="@$T0 +0000" GIT_COMMITTER_DATE="@$T0 +0000" \
    git -C "$repo" commit -qm 'declare external vault'
}

run_drift() {
  local home=$1
  shift
  env "$@" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$DRIFT" 2>/dev/null
}

# --- cases ------------------------------------------------------------------

test_no_vault_is_silent() {
  local home out code
  home=$(new_home no-vault-is-silent)
  init_repo "$home/projects/plain" "$T0"
  project_commits "$home/projects/plain" 40 $((T0 + 30 * DAY))

  out=$(run_drift "$home")
  code=$?
  expect_code 0 "$code" "no-vault project"
  [ -z "$out" ] || fail "a project with no vault must produce no output, got: $out"
  pass "a project with no vault is silent"
}

test_directory_named_vault_without_marker_is_silent() {
  local home proj out
  home=$(new_home directory-named-vault-without-marker-is-silent)
  proj="$home/projects/fixtures"
  init_repo "$proj" "$T0"
  # A tracked directory that merely shares the name - e.g. a test fixture tree -
  # carries no OKF bundle marker and must never raise an alarm.
  commit_at "$proj" "$T0" scripts/testing/vault/test_verify.sh 'echo hi' 'add vault test fixture'
  project_commits "$proj" 40 $((T0 + 30 * DAY))

  out=$(run_drift "$home")
  [ -z "$out" ] || fail "a directory named vault without the bundle marker must be ignored, got: $out"
  pass "a same-named directory without the vault bundle marker is never reported"
}

test_current_in_repo_vault_is_silent() {
  local home proj out
  home=$(new_home current-in-repo-vault-is-silent)
  proj="$home/projects/hermes"
  init_repo "$proj" "$T0"
  in_repo_vault "$proj" "$T0"
  project_commits "$proj" 3 $((T0 + 2 * DAY))

  out=$(run_drift "$home")
  [ -z "$out" ] || fail "a current in-repo vault must be silent, got: $out"
  pass "an in-repo vault inside both thresholds is silent"
}

test_in_repo_vault_stale_by_commit_count() {
  local home proj out
  home=$(new_home in-repo-vault-stale-by-commit-count)
  proj="$home/projects/hermes"
  init_repo "$proj" "$T0"
  in_repo_vault "$proj" "$T0"
  project_commits "$proj" 20 $((T0 + DAY))

  out=$(run_drift "$home")
  assert_contains "$out" \
    "VAULT_DRIFT: hermes: in-repo vault stale at vault/ - vault last updated $T0_DATE, 20 project commits landed since, drift window 1d" \
    "in-repo staleness must report the commit count behind and the drift window"
  assert_contains "$out" "a crewmate can refresh it in its own worktree" \
    "an in-repo vault must carry the in-worktree remedy"
  pass "an in-repo vault behind by commit count reports count and window"
}

test_in_repo_vault_stale_by_drift_window() {
  local home proj out
  home=$(new_home in-repo-vault-stale-by-drift-window)
  proj="$home/projects/bzsim"
  init_repo "$proj" "$T0"
  in_repo_vault "$proj" "$T0"
  project_commits "$proj" 2 $((T0 + 8 * DAY))

  out=$(run_drift "$home")
  assert_contains "$out" \
    "VAULT_DRIFT: bzsim: in-repo vault stale at vault/ - vault last updated $T0_DATE, 2 project commits landed since, drift window 8d" \
    "a long drift window must report even with few commits behind"
  pass "an in-repo vault behind by drift window reports count and window"
}

test_external_symlinked_vault_stale_reports_the_separate_repo_remedy() {
  local home proj out
  home=$(new_home external-symlinked-vault-stale-reports-the-separate-repo-remedy)
  proj="$home/projects/arknode"
  init_repo "$proj" "$T0"
  declare_external "$proj" /vault
  external_vault "$home/vaults/arknode" "$T0"
  ln -s "$home/vaults/arknode" "$proj/vault"
  project_commits "$proj" 25 $((T0 + 3 * DAY))

  out=$(run_drift "$home")
  assert_contains "$out" \
    "VAULT_DRIFT: arknode: external vault stale at vault -> $home/vaults/arknode - vault last updated $T0_DATE, 25 project commits landed since, drift window 3d" \
    "external staleness must name the link target, the count behind, and the window"
  assert_contains "$out" \
    "the vault is a separate repo, which an isolated project worktree cannot write, so dispatch the update against that repo's own clone" \
    "an external vault must carry the separate-repo remedy"
  assert_not_contains "$out" "a crewmate can refresh it in its own worktree" \
    "an external vault must never be given the in-worktree remedy"
  pass "a stale external symlinked vault reports the separate-repo remedy"
}

test_current_external_symlinked_vault_is_silent() {
  local home proj out
  home=$(new_home current-external-symlinked-vault-is-silent)
  proj="$home/projects/arknode"
  init_repo "$proj" "$T0"
  declare_external "$proj" /vault
  external_vault "$home/vaults/arknode" $((T0 + 3 * DAY))
  ln -s "$home/vaults/arknode" "$proj/vault"
  project_commits "$proj" 2 $((T0 + 4 * DAY))

  out=$(run_drift "$home")
  [ -z "$out" ] || fail "a current external vault must be silent, got: $out"
  pass "a current external symlinked vault is silent"
}

test_declared_external_target_without_marker_reports_invalid() {
  local home proj target out
  home=$(new_home declared-external-target-without-marker-reports-invalid)
  proj="$home/projects/arknode"
  init_repo "$proj" "$T0"
  declare_external "$proj" /vault
  target="$home/vaults/not-a-vault"
  init_repo "$target" "$T0"
  ln -s "$target" "$proj/vault"
  project_commits "$proj" 30 $((T0 + 30 * DAY))

  out=$(run_drift "$home")
  assert_contains "$out" \
    "VAULT_DRIFT: arknode: external vault target invalid at vault -> $target - 00-Home.md marker missing" \
    "a declared external target without the bundle marker must report as invalid"
  assert_not_contains "$out" "vault stale at" \
    "a declared non-vault target must never be classified as stale"
  pass "a declared external target without the marker reports invalid"
}

test_undeclared_root_symlink_to_non_vault_repo_is_silent() {
  local home proj target out
  home=$(new_home undeclared-root-symlink-to-non-vault-repo-is-silent)
  proj="$home/projects/fixtures"
  init_repo "$proj" "$T0"
  target="$home/repos/unrelated"
  init_repo "$target" "$T0"
  ln -s "$target" "$proj/vault"
  project_commits "$proj" 30 $((T0 + 30 * DAY))

  out=$(run_drift "$home")
  [ -z "$out" ] || fail "an undeclared symlink to a non-vault repo must be ignored, got: $out"
  pass "an undeclared root symlink to a non-vault repo is silent"
}

test_broken_link_reports_distinctly_from_staleness() {
  local home proj out
  home=$(new_home broken-link-reports-distinctly-from-staleness)
  proj="$home/projects/arknode"
  init_repo "$proj" "$T0"
  declare_external "$proj" /vault
  ln -s "$home/vaults/gone" "$proj/vault"
  project_commits "$proj" 30 $((T0 + 30 * DAY))

  out=$(run_drift "$home")
  assert_contains "$out" \
    "VAULT_DRIFT: arknode: external vault link broken at vault -> $home/vaults/gone (target missing)" \
    "a dangling vault link must be reported as broken"
  assert_not_contains "$out" "vault stale at" \
    "a broken link must not be reported as staleness"
  pass "a broken vault link reports distinctly from a stale vault"
}

test_absent_link_reports_distinctly_from_staleness() {
  local home proj out
  home=$(new_home absent-link-reports-distinctly-from-staleness)
  proj="$home/projects/arknode"
  init_repo "$proj" "$T0"
  declare_external "$proj" /vault
  project_commits "$proj" 30 $((T0 + 30 * DAY))

  out=$(run_drift "$home")
  assert_contains "$out" \
    "VAULT_DRIFT: arknode: external vault link absent at vault - the project declares an external vault there but this clone has none, so vault drift cannot be measured here at all" \
    "a declared-but-missing external vault must be reported as an absent link"
  assert_not_contains "$out" "vault stale at" \
    "an absent link must not be reported as staleness"
  assert_not_contains "$out" "link broken at" \
    "an absent link must not be reported as a broken link"
  pass "an absent vault link reports distinctly from a stale vault"
}

# The regression that motivated the whole check: one project holding an absent
# external link at one declared location AND a genuinely stale external vault at
# another, which must surface as two separate problems with two separate remedies.
test_arknode_absent_link_and_stale_vault_at_once() {
  local home proj out lines
  home=$(new_home arknode-absent-link-and-stale-vault-at-once)
  proj="$home/projects/ArkNode-AI"
  init_repo "$proj" "$T0"
  declare_external "$proj" /vault /projects/trading-signal-ai/vault
  external_vault "$home/vaults/ArkNode-AI" "$T0"
  mkdir -p "$proj/projects/trading-signal-ai"
  ln -s "$home/vaults/ArkNode-AI" "$proj/projects/trading-signal-ai/vault"
  project_commits "$proj" 52 $((T0 + 7 * DAY))

  out=$(run_drift "$home")
  assert_contains "$out" \
    "VAULT_DRIFT: ArkNode-AI: external vault link absent at vault -" \
    "the unlinked declared vault must surface"
  assert_contains "$out" \
    "VAULT_DRIFT: ArkNode-AI: external vault stale at projects/trading-signal-ai/vault -> $home/vaults/ArkNode-AI - vault last updated $T0_DATE, 52 project commits landed since, drift window 7d" \
    "the stale external vault must surface with its own count and window"
  lines=$(printf '%s\n' "$out" | grep -c '^VAULT_DRIFT: ')
  [ "$lines" -eq 2 ] || fail "expected exactly two problems, got $lines:"$'\n'"$out"
  pass "a project with an absent link and a stale vault reports both, distinctly"
}

test_thresholds_are_overridable_and_invalid_values_fall_back() {
  local home proj out err
  home=$(new_home thresholds-are-overridable-and-invalid-values-fall-back)
  proj="$home/projects/hermes"
  init_repo "$proj" "$T0"
  in_repo_vault "$proj" "$T0"
  project_commits "$proj" 3 $((T0 + DAY))

  out=$(run_drift "$home")
  [ -z "$out" ] || fail "3 commits behind must be silent at the default threshold, got: $out"

  out=$(run_drift "$home" FM_VAULT_DRIFT_COMMITS=3)
  assert_contains "$out" "3 project commits landed since, drift window 1d" \
    "a lowered commit threshold must surface the drift"

  err=$(env FM_VAULT_DRIFT_COMMITS=soon FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$DRIFT" 2>&1 >/dev/null)
  assert_contains "$err" "invalid FM_VAULT_DRIFT_COMMITS 'soon'; using 20" \
    "an invalid threshold must warn instead of silently disabling the check"
  out=$(run_drift "$home" FM_VAULT_DRIFT_COMMITS=soon)
  [ -z "$out" ] || fail "an invalid threshold must fall back to the default, got: $out"
  pass "drift thresholds are overridable and invalid values fall back loudly"
}

test_every_registered_project_is_covered() {
  local home out
  home=$(new_home every-registered-project-is-covered)
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'REG'
# Projects

- registered [no-mistakes +yolo] - a registered clone with a stale vault (added 2026-07-27)
- never-cloned [direct-PR] - registered but not cloned here (added 2026-07-27)
REG
  init_repo "$home/projects/registered" "$T0"
  in_repo_vault "$home/projects/registered" "$T0"
  project_commits "$home/projects/registered" 25 $((T0 + DAY))
  init_repo "$home/projects/unregistered" "$T0"
  in_repo_vault "$home/projects/unregistered" "$T0"
  project_commits "$home/projects/unregistered" 25 $((T0 + DAY))

  out=$(run_drift "$home")
  assert_contains "$out" "VAULT_DRIFT: registered: in-repo vault stale" \
    "a registered project must be checked"
  assert_contains "$out" "VAULT_DRIFT: unregistered: in-repo vault stale" \
    "a clone missing from the registry must still be checked"
  assert_not_contains "$out" "never-cloned" \
    "a registered project with no clone here has nothing to inspect"
  pass "every registered project with a clone is classified, and extra clones too"
}

test_detection_never_writes() {
  local home proj vault before after
  home=$(new_home detection-never-writes)
  proj="$home/projects/arknode"
  init_repo "$proj" "$T0"
  declare_external "$proj" /vault
  vault="$home/vaults/arknode"
  external_vault "$vault" "$T0"
  ln -s "$vault" "$proj/vault"
  in_repo_vault "$proj" "$T0" docs/vault
  project_commits "$proj" 30 $((T0 + 30 * DAY))

  before=$(cd "$proj" && find . -not -path './.git/*' | sort
    git -C "$proj" status --porcelain
    git -C "$proj" rev-parse HEAD
    cd "$vault" && find . -not -path './.git/*' | sort
    git -C "$vault" status --porcelain
    git -C "$vault" rev-parse HEAD)
  run_drift "$home" >/dev/null
  after=$(cd "$proj" && find . -not -path './.git/*' | sort
    git -C "$proj" status --porcelain
    git -C "$proj" rev-parse HEAD
    cd "$vault" && find . -not -path './.git/*' | sort
    git -C "$vault" status --porcelain
    git -C "$vault" rev-parse HEAD)
  [ "$before" = "$after" ] || fail "detection must not touch the clone or the vault"$'\n'"before: $before"$'\n'"after: $after"
  pass "detection never writes to a project clone or to a vault"
}

test_no_vault_is_silent
test_directory_named_vault_without_marker_is_silent
test_current_in_repo_vault_is_silent
test_in_repo_vault_stale_by_commit_count
test_in_repo_vault_stale_by_drift_window
test_external_symlinked_vault_stale_reports_the_separate_repo_remedy
test_current_external_symlinked_vault_is_silent
test_declared_external_target_without_marker_reports_invalid
test_undeclared_root_symlink_to_non_vault_repo_is_silent
test_broken_link_reports_distinctly_from_staleness
test_absent_link_reports_distinctly_from_staleness
test_arknode_absent_link_and_stale_vault_at_once
test_thresholds_are_overridable_and_invalid_values_fall_back
test_every_registered_project_is_covered
test_detection_never_writes
