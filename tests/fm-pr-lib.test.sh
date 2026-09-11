#!/usr/bin/env bash
# Characterization coverage for PR/MR identity parsing.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"

fm_pr_url_parse 'https://github.com/acme/project/pull/42'
[ "$FM_PR_PROVIDER" = github ] || fail 'GitHub URL must identify the github provider'
[ "$FM_PR_HOST" = github.com ] || fail 'GitHub URL must retain its host'
[ "$FM_PR_PATH" = acme/project ] || fail 'GitHub URL must retain owner/repository path'
[ "$FM_PR_OWNER" = acme ] || fail 'GitHub URL must expose its owner'
[ "$FM_PR_REPO" = project ] || fail 'GitHub URL must expose its repository'
[ "$FM_PR_NUMBER" = 42 ] || fail 'GitHub URL must parse its pull request number'

fm_pr_url_parse 'https://git.example.test/group/subgroup/project/-/merge_requests/7'
[ "$FM_PR_PROVIDER" = gitlab ] || fail 'GitLab URL must identify the gitlab provider'
[ "$FM_PR_HOST" = git.example.test ] || fail 'GitLab URL must retain its host'
[ "$FM_PR_PATH" = group/subgroup/project ] || fail 'GitLab URL must retain nested project path'
[ "$FM_PR_NUMBER" = 7 ] || fail 'GitLab URL must parse its merge request number'
[ -z "$FM_PR_OWNER" ] && [ -z "$FM_PR_REPO" ] \
  || fail 'GitLab URL must not expose GitHub owner/repository fields'

if fm_pr_url_parse 'https://github.com/acme/project/pull/0'; then
  fail 'PR number zero must be rejected'
fi
if fm_pr_url_parse 'https://git.example.test/group/-/merge_requests/7'; then
  fail 'GitLab path without a project segment must be rejected'
fi

test_disabled_gitlab_paths() {
  local fakebin home output rc tmp url command
  tmp=$(fm_test_tmproot fm-pr-disabled-provider)
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  mkdir -p "$home/config" "$fakebin"
  printf '%s\n' gitlab > "$home/config/disabled-adapters"
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf x > "$FM_GLAB_LOG"
exit 99
SH
  chmod +x "$fakebin/glab"
  url=https://gitlab.example/group/project/-/merge_requests/1

  for command in "$ROOT/bin/fm-pr-check.sh" "$ROOT/bin/fm-pr-merge.sh"; do
    rc=0
    output=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
      "$command" task "$url" 2>&1) || rc=$?
    expect_code 1 "$rc" "GitLab command must be refused"
    assert_contains "$output" "GitLab is disabled by config/disabled-adapters" \
      "GitLab command must name the policy"
  done

  output=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_GLAB_LOG="$tmp/glab.log" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-pr-poll.sh" --validated gitlab "$url" gitlab.example group/project 1 2>&1)
  [ -z "$output" ] || fail "disabled GitLab poll must stay silent to the watcher"
  [ ! -e "$tmp/glab.log" ] || fail "disabled GitLab poll invoked glab"
  pass 'GitLab check, merge, and poll paths remain disabled'
}

test_disabled_gitlab_paths
pass 'fm-pr-lib parses provider-tagged GitHub and nested GitLab identities'
echo '# fm-pr-lib.test.sh: all assertions passed'
