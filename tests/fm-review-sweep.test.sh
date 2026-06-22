#!/usr/bin/env bash
# Behavior tests for fm-review-sweep.sh pure helpers.
# Sources the script's functions (the main() guard keeps sourcing side-effect-free)
# and exercises the side-effect-free logic: fleet resolution from data/projects.md,
# the CI-fail decision, the recommendation parser (clean APPROVE vs CONDITIONAL
# APPROVE), and the Jira MILE-key extraction. gh is stubbed on PATH so no network.
# shellcheck disable=SC2034  # PROJECTS_MD / FM_ROOT are read by sourced functions
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$ROOT/bin/fm-review-sweep.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# A scratch dir that stands in for FM_ROOT; the sweep writes nothing here for
# these tests (we never call main), but the path vars must resolve.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Set up the global env the sourced functions read. FM_ROOT drives STATE_DIR etc.
export FM_ROOT="$TMP"
# shellcheck disable=SC1090
# Source the functions only (the main() guard at the bottom prevents execution).
. "$SWEEP"

# ---- resolve_fleet: parse registry lines into owner/name<TAB>clone-path ----
test_resolve_fleet_parses_registry() {
  local reg="$TMP/projects.md"
  cat > "$reg" <<'EOF'
# Fleet registry

## project-racgoon (racgoon umbrella)

- racgoon-be [no-mistakes] - Backend Go service — github.com/veridianlab/racgoon (added 2026-06-22)
- racgoon-fe [no-mistakes] - Frontend React/TS app — github.com/veridianlab/raccoon-fe (added 2026-06-22)
- racgoon-infra [no-mistakes] - Terraform IaC — github.com/veridianlab/infra (added 2026-06-22)
EOF
  PROJECTS_MD="$reg"
  local out
  out=$(resolve_fleet)
  echo "$out" | grep -qx $'veridianlab/racgoon\tprojects/racgoon-be' \
    || fail "resolve_fleet did not emit racgoon-be -> veridianlab/racgoon"
  echo "$out" | grep -qx $'veridianlab/raccoon-fe\tprojects/racgoon-fe' \
    || fail "resolve_fleet did not strip to owner/name for raccoon-fe"
  echo "$out" | grep -qx $'veridianlab/infra\tprojects/racgoon-infra' \
    || fail "resolve_fleet did not map racgoon-infra to infra repo"
  # lines without a github.com URL are skipped (e.g. the header/section lines)
  [ "$(echo "$out" | wc -l)" -eq 3 ] || fail "resolve_fleet emitted wrong line count"
  pass "resolve_fleet parses owner/name and clone path from registry bullets"
}

test_resolve_fleet_strips_trailing_dot_git() {
  local reg="$TMP/projects2.md"
  cat > "$reg" <<'EOF'
- lynx-be [no-mistakes] - Backend — github.com/veridianlab/lynx-haven.git (added 2026-06-22)
EOF
  PROJECTS_MD="$reg"
  local out
  out=$(resolve_fleet)
  echo "$out" | grep -qx $'veridianlab/lynx-haven\tprojects/lynx-be' \
    || fail "resolve_fleet did not strip trailing .git"
  pass "resolve_fleet strips a trailing .git from the repo URL"
}

# ---- ci_status: FAILURE in any check => fail; otherwise pass ---------------
# Stub gh to emit a given JSON array of states.
stub_gh() {
  local states_json="$1" exit_code="${2:-0}"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
# test stub
case "\$*" in
  *pr*checks*) printf '%s' "$states_json"; exit $exit_code ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

test_ci_status_failure_is_fail() {
  # Real `gh pr checks` exits 1 when any check FAILED. The stub mirrors that;
  # ci_status must classify from the check content, NOT the non-zero exit code.
  stub_gh '["SUCCESS","FAILURE","SUCCESS"]' 1
  [ "$(ci_status owner/name 1)" = "fail" ] || fail "FAILURE should make ci_status return fail even when gh exits 1"
  pass "ci_status returns fail when any check is FAILURE (gh exit 1)"
}

test_ci_status_all_success_is_pass() {
  stub_gh '["SUCCESS","SUCCESS","SKIPPED"]'
  [ "$(ci_status owner/name 1)" = "pass" ] || fail "all-success should be pass"
  pass "ci_status returns pass when all checks are SUCCESS/SKIPPED"
}

test_ci_status_pending_is_not_fail() {
  # PENDING/STARTED are running states, not hard failures. Real `gh pr checks`
  # exits 8 while checks are pending; the stub mirrors that.
  stub_gh '["STARTED","PENDING"]' 8
  [ "$(ci_status owner/name 1)" = "pass" ] || fail "pending/running should not count as fail"
  pass "ci_status treats PENDING/STARTED as non-failure (gh exit 8)"
}

test_ci_status_empty_is_unknown() {
  stub_gh '[]'
  [ "$(ci_status owner/name 1)" = "unknown" ] || fail "empty checks should be unknown"
  pass "ci_status returns unknown when there are no checks"
}

# ---- parse_recommendation: clean APPROVE vs CONDITIONAL APPROVE -----------
# Stub gh api to return one comment body.
stub_gh_comment() {
  local body="$1"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
# test stub
printf '%s' $(printf '%q' "$body")
EOF
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

test_parse_clean_approve() {
  stub_gh_comment $'Some findings table.\n### Recommendation: APPROVE\nAll clear.'
  [ "$(parse_recommendation owner/name 1)" = "APPROVE" ] || fail "clean APPROVE not parsed"
  pass "parse_recommendation returns APPROVE for a clean approval"
}

test_parse_conditional_approve_is_not_clean_approve() {
  # CONDITIONAL APPROVE must surface as CONDITIONAL, never APPROVE, so the Jira
  # tie-in (which keys on == APPROVE) does not fire.
  stub_gh_comment $'### Recommendation: CONDITIONAL APPROVE\nRationale.'
  [ "$(parse_recommendation owner/name 1)" = "CONDITIONAL" ] \
    || fail "CONDITIONAL APPROVE should parse to CONDITIONAL, not APPROVE"
  pass "parse_recommendation returns CONDITIONAL for CONDITIONAL APPROVE"
}

test_parse_other_decisions() {
  for dec in BLOCK "REQUEST CHANGES" CAUTION; do
    stub_gh_comment "### Recommendation: $dec"
    local got
    got=$(parse_recommendation owner/name 1)
    # first word uppercased
    [ "$got" = "$(echo "$dec" | awk '{print toupper($1)}')" ] \
      || fail "recommendation '$dec' parsed as '$got'"
  done
  pass "parse_recommendation returns the decision word for BLOCK/REQUEST/CAUTION"
}

# ---- jira_key_for: extract MILE-\d+ from PR title/body ---------------------
# Reuses the gh comment stub to emit a title+body blob (jira_key_for greps it).
test_jira_key_from_title() {
  stub_gh_comment $'feat: Status Flow Config API & Permissions (MILE-1027)\n\nbody text'
  [ "$(jira_key_for owner/name 1)" = "MILE-1027" ] || fail "MILE key not extracted from title"
  pass "jira_key_for extracts the MILE- key from the PR title"
}

test_jira_key_from_body() {
  stub_gh_comment $'feat: no key in title\n\nLinked ticket: MILE-1132.'
  [ "$(jira_key_for owner/name 1)" = "MILE-1132" ] || fail "MILE key not extracted from body"
  pass "jira_key_for extracts the MILE- key from the PR body when title lacks one"
}

test_jira_key_none() {
  stub_gh_comment $'chore: no ticket here\n\nnothing'
  [ -z "$(jira_key_for owner/name 1)" ] || fail "should return empty when no MILE key"
  pass "jira_key_for returns empty when no MILE- key is present"
}

test_resolve_fleet_parses_registry
test_resolve_fleet_strips_trailing_dot_git
test_ci_status_failure_is_fail
test_ci_status_all_success_is_pass
test_ci_status_pending_is_not_fail
test_ci_status_empty_is_unknown
test_parse_clean_approve
test_parse_conditional_approve_is_not_clean_approve
test_parse_other_decisions
test_jira_key_from_title
test_jira_key_from_body
test_jira_key_none
