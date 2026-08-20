#!/usr/bin/env bash
# Behavior tests for bin/fm-search.sh.
#
# Default repository-root ripgrep skips gitignored data/, state/, and config/
# plus hidden .agents/skills/. These tests reproduce that miss against a
# firstmate-like home fixture, then prove the public helper finds the intended
# corpus without exposing secret-bearing paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEARCH="$ROOT/bin/fm-search.sh"
TMP_ROOT=$(fm_test_tmproot fm-search)

command -v rg >/dev/null 2>&1 || fail "rg is required for fm-search behavior tests"

# Unique needles so assertions cannot pass by matching this suite or the repo.
TRACKED_NEEDLE='fmsearch-tracked-needle-7f3a'
DATA_NEEDLE='fmsearch-data-needle-7f3a'
REPORT_NEEDLE='fmsearch-report-needle-7f3a'
STATE_NEEDLE='fmsearch-state-needle-7f3a'
HIDDEN_STATE_NEEDLE='fmsearch-hidden-state-needle-7f3a'
CONFIG_NEEDLE='fmsearch-config-needle-7f3a'
HIDDEN_CONFIG_NEEDLE='fmsearch-hidden-config-needle-7f3a'
SKILL_NEEDLE='fmsearch-skill-needle-7f3a'
SECRET_ENV_NEEDLE='fmsearch-secret-env-needle-7f3a'
SECRET_PROFILE_NEEDLE='fmsearch-secret-profile-needle-7f3a'
SECRET_CMUX_NEEDLE='fmsearch-secret-cmux-needle-7f3a'
NESTED_SECRET_CMUX_NEEDLE='fmsearch-nested-secret-cmux-needle-7f3a'
NESTED_SECRET_PROFILE_NEEDLE='fmsearch-nested-secret-profile-needle-7f3a'
PROJECTS_NEEDLE='fmsearch-projects-needle-7f3a'
NO_MISTAKES_NEEDLE='fmsearch-no-mistakes-needle-7f3a'
NOMATCH_NEEDLE='fmsearch-nomatch-needle-7f3a'

make_home_fixture() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p \
    "$home/data/scout-1/config" \
    "$home/state" \
    "$home/config" \
    "$home/.agents/skills/demo" \
    "$home/projects/other-repo" \
    "$home/.no-mistakes"
  cat > "$home/.gitignore" <<'EOF'
data/
state/
config/
projects/
.no-mistakes/
.env
EOF
  printf '# tracked README\n%s\n' "$TRACKED_NEEDLE" > "$home/README.md"
  printf '%s\n' "$DATA_NEEDLE" > "$home/data/captain.md"
  printf '%s\n' "$REPORT_NEEDLE" > "$home/data/scout-1/report.md"
  printf '%s\n' "$STATE_NEEDLE" > "$home/state/demo.status"
  printf '%s\n' "$HIDDEN_STATE_NEEDLE" > "$home/state/.afk"
  printf '%s\n' "$CONFIG_NEEDLE" > "$home/config/crew-harness"
  printf '%s\n' "$HIDDEN_CONFIG_NEEDLE" > "$home/config/.hidden-choice"
  printf '# demo skill\n%s\n' "$SKILL_NEEDLE" > "$home/.agents/skills/demo/SKILL.md"
  printf 'FMX_PAIRING_TOKEN=%s\n' "$SECRET_ENV_NEEDLE" > "$home/.env"
  chmod 600 "$home/.env"
  printf 'alias=%s\n' "$SECRET_PROFILE_NEEDLE" > "$home/config/claude-account-profiles"
  chmod 600 "$home/config/claude-account-profiles"
  printf '%s\n' "$SECRET_CMUX_NEEDLE" > "$home/config/cmux-socket-password"
  chmod 600 "$home/config/cmux-socket-password"
  printf '%s\n' "$NESTED_SECRET_CMUX_NEEDLE" > "$home/data/scout-1/config/cmux-socket-password"
  chmod 600 "$home/data/scout-1/config/cmux-socket-password"
  printf 'alias=%s\n' "$NESTED_SECRET_PROFILE_NEEDLE" > "$home/data/scout-1/config/claude-account-profiles"
  chmod 600 "$home/data/scout-1/config/claude-account-profiles"
  printf '%s\n' "$PROJECTS_NEEDLE" > "$home/projects/other-repo/README.md"
  printf '%s\n' "$NO_MISTAKES_NEEDLE" > "$home/.no-mistakes/evidence.txt"
  fm_git_identity
  git -C "$home" init -q
  git -C "$home" add .gitignore README.md .agents
  git -C "$home" commit -qm initial
  printf '%s\n' "$home"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

run_rg() {
  local home=$1
  shift
  (cd "$home" && env -u RIPGREP_CONFIG_PATH rg "$@" </dev/null)
}

run_search() {
  local home=$1
  shift
  (cd "$home" && "$SEARCH" "$@")
}

test_default_rg_misses_private_and_hidden_corpus() {
  local home out rc
  home=$(make_home_fixture default-miss)

  rc=0
  out=$(run_rg "$home" -- "$TRACKED_NEEDLE") || rc=$?
  expect_code 0 "$rc" "default rg on a tracked non-hidden file"
  assert_contains "$out" "$TRACKED_NEEDLE" "default rg must still see tracked non-hidden text"

  for needle in \
    "$DATA_NEEDLE" \
    "$REPORT_NEEDLE" \
    "$STATE_NEEDLE" \
    "$HIDDEN_STATE_NEEDLE" \
    "$CONFIG_NEEDLE" \
    "$HIDDEN_CONFIG_NEEDLE" \
    "$SKILL_NEEDLE"
  do
    rc=0
    out=$(run_rg "$home" -- "$needle") || rc=$?
    expect_code 1 "$rc" "default rg no-match for $needle"
    [ -z "$out" ] || fail "default rg unexpectedly matched $needle"$'\n'"--- output ---"$'\n'"$out"
  done
  pass "default repository-root rg misses gitignored and hidden corpus while still seeing tracked files"
}

test_helper_finds_representative_corpus_matches() {
  local home out rc
  home=$(make_home_fixture helper-hits)

  rc=0
  out=$(run_search "$home" -- "$TRACKED_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper tracked match"
  assert_contains "$out" "README.md" "helper must name the tracked file"
  assert_contains "$out" "$TRACKED_NEEDLE" "helper must show the tracked needle"

  rc=0
  out=$(run_search "$home" -- "$DATA_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper data/ match"
  assert_contains "$out" "data/captain.md" "helper must search gitignored data/"

  rc=0
  out=$(run_search "$home" -- "$REPORT_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper nested data/ match"
  assert_contains "$out" "data/scout-1/report.md" "helper must search nested gitignored reports"

  rc=0
  out=$(run_search "$home" -- "$STATE_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper state/ match"
  assert_contains "$out" "state/demo.status" "helper must search gitignored state/"

  rc=0
  out=$(run_search "$home" -- "$HIDDEN_STATE_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper hidden state match"
  assert_contains "$out" "state/.afk" "helper must search a gitignored hidden state file"

  rc=0
  out=$(run_search "$home" -- "$CONFIG_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper config/ match"
  assert_contains "$out" "config/crew-harness" "helper must search gitignored config/"

  rc=0
  out=$(run_search "$home" -- "$HIDDEN_CONFIG_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper hidden config match"
  assert_contains "$out" "config/.hidden-choice" "helper must search a gitignored hidden config file"

  rc=0
  out=$(run_search "$home" -- "$SKILL_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper .agents/skills match"
  assert_contains "$out" ".agents/skills/demo/SKILL.md" "helper must search hidden .agents/skills/"
  pass "helper finds tracked, data/, state/, config/, and .agents/skills/ matches"
}

test_helper_keeps_no_match_distinguishable() {
  local home out rc
  home=$(make_home_fixture no-match)
  rc=0
  out=$(run_search "$home" -- "$NOMATCH_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper no-match"
  [ -z "$out" ] || fail "helper no-match printed hits"$'\n'"--- output ---"$'\n'"$out"
  pass "helper no-match keeps ripgrep exit 1 and empty output"
}

test_helper_malformed_usage_fails_clearly() {
  local home out rc
  home=$(make_home_fixture usage)
  rc=0
  out=$(run_search "$home" 2>&1) || rc=$?
  expect_code 2 "$rc" "helper with no arguments"
  assert_contains "$out" "usage:" "empty invocation must print usage"
  pass "malformed usage fails with exit 2 and a usage message"
}

test_helper_omits_secrets_and_clone_trees() {
  local home out rc env_mode profile_mode
  home=$(make_home_fixture secrets)
  env_mode=$(file_mode "$home/.env")
  profile_mode=$(file_mode "$home/config/claude-account-profiles")

  rc=0
  out=$(run_search "$home" -- "$SECRET_ENV_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper .env exclusion"
  assert_not_contains "$out" "$SECRET_ENV_NEEDLE" "helper must not print .env secrets"

  rc=0
  out=$(run_search "$home" -- "$SECRET_PROFILE_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper claude-account-profiles exclusion"
  assert_not_contains "$out" "$SECRET_PROFILE_NEEDLE" "helper must not print account-profile secrets"

  rc=0
  out=$(run_search "$home" -- "$SECRET_CMUX_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper cmux-socket-password exclusion"
  assert_not_contains "$out" "$SECRET_CMUX_NEEDLE" "helper must not print the cmux socket password"

  rc=0
  out=$(run_search "$home" -- "$NESTED_SECRET_CMUX_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper nested cmux-socket-password exclusion"
  assert_not_contains "$out" "$NESTED_SECRET_CMUX_NEEDLE" \
    "helper must not print a cmux socket password nested below the search root"

  rc=0
  out=$(run_search "$home" -- "$NESTED_SECRET_PROFILE_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper nested claude-account-profiles exclusion"
  assert_not_contains "$out" "$NESTED_SECRET_PROFILE_NEEDLE" \
    "helper must not print account-profile secrets nested below the search root"

  rc=0
  out=$(run_search "$home" -- "$PROJECTS_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper projects/ exclusion"
  assert_not_contains "$out" "$PROJECTS_NEEDLE" "helper must not search projects/ clones by default"

  rc=0
  out=$(run_search "$home" -- "$NO_MISTAKES_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper .no-mistakes/ exclusion"
  assert_not_contains "$out" "$NO_MISTAKES_NEEDLE" "helper must not search .no-mistakes/ gate artifacts"

  [ "$(file_mode "$home/.env")" = "$env_mode" ] \
    || fail "helper changed .env permissions"
  [ "$(file_mode "$home/config/claude-account-profiles")" = "$profile_mode" ] \
    || fail "helper changed claude-account-profiles permissions"
  [ "$env_mode" = 600 ] || fail ".env fixture was not mode 600"
  [ "$(file_mode "$home/data/scout-1/config/cmux-socket-password")" = 600 ] \
    || fail "helper changed nested cmux-socket-password permissions"
  pass "helper omits secret-bearing paths at any depth and clone trees without weakening permissions"
}

test_helper_search_target_ignores_caller_stdin() {
  local home out rc
  home=$(make_home_fixture stdin)

  rc=0
  out=$(printf 'unrelated stdin text\n' | (cd "$home" && "$SEARCH" -- "$DATA_NEEDLE")) || rc=$?
  expect_code 0 "$rc" "helper with a pipe on stdin"
  assert_contains "$out" "data/captain.md" "a piped stdin must not replace the cwd walk"

  rc=0
  out=$(printf '%s\n' "$NOMATCH_NEEDLE" | (cd "$home" && "$SEARCH" -- "$NOMATCH_NEEDLE")) || rc=$?
  expect_code 1 "$rc" "helper no-match with the needle only on stdin"
  [ -z "$out" ] || fail "helper matched piped stdin instead of the corpus"$'\n'"--- output ---"$'\n'"$out"
  pass "helper searches the corpus regardless of the caller's stdin"
}

test_helper_ignores_operator_ripgrep_config() {
  local home cfg out rc
  home=$(make_home_fixture rgconfig)
  cfg="$home/operator-rg-config"
  printf -- '--glob=!data/\n--glob=!.agents/\n' > "$cfg"

  rc=0
  out=$(cd "$home" && RIPGREP_CONFIG_PATH="$cfg" "$SEARCH" -- "$DATA_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper under an excluding operator rg config"
  assert_contains "$out" "data/captain.md" "operator rg config must not remask gitignored data/"

  rc=0
  out=$(cd "$home" && RIPGREP_CONFIG_PATH="$cfg" "$SEARCH" -- "$SKILL_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper skills match under an excluding operator rg config"
  assert_contains "$out" ".agents/skills/demo/SKILL.md" "operator rg config must not remask hidden .agents/skills/"

  rc=0
  out=$(cd "$home" && RIPGREP_CONFIG_PATH="$cfg" "$SEARCH" -- "$SECRET_CMUX_NEEDLE") || rc=$?
  expect_code 1 "$rc" "helper secret exclusion under an operator rg config"
  assert_not_contains "$out" "$SECRET_CMUX_NEEDLE" "operator rg config must not unmask secret-bearing files"
  pass "helper ignores RIPGREP_CONFIG_PATH so operator rg config cannot remask the corpus"
}

test_helper_ignore_file_cannot_remask_corpus() {
  local home out rc
  home=$(make_home_fixture ignore-remask)
  printf 'data/\n' > "$home/.ignore"

  rc=0
  out=$(run_search "$home" -- "$DATA_NEEDLE") || rc=$?
  expect_code 0 "$rc" "helper data/ match with a remasking .ignore"
  assert_contains "$out" "data/captain.md" "a caller .ignore must not remask gitignored data/"
  pass "helper ignore files cannot remask the explicit corpus"
}

test_helper_missing_rg_fails_clearly() {
  local home fakebin out rc
  home=$(make_home_fixture missing-rg)
  fakebin=$(fm_fakebin "$TMP_ROOT/missing-rg")
  fm_test_hide_host_commands "$TMP_ROOT/missing-rg" rg
  rc=0
  out=$(cd "$home" && PATH="$fakebin:$PATH" "$SEARCH" -- "$TRACKED_NEEDLE" 2>&1) || rc=$?
  expect_code 2 "$rc" "helper with rg missing"
  assert_contains "$out" "rg" "missing-rg error must name rg"
  pass "missing rg fails clearly without searching"
}

test_default_rg_misses_private_and_hidden_corpus
test_helper_finds_representative_corpus_matches
test_helper_keeps_no_match_distinguishable
test_helper_malformed_usage_fails_clearly
test_helper_omits_secrets_and_clone_trees
test_helper_search_target_ignores_caller_stdin
test_helper_ignores_operator_ripgrep_config
test_helper_ignore_file_cannot_remask_corpus
test_helper_missing_rg_fails_clearly
