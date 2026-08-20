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

pass 'fm-pr-lib parses provider-tagged GitHub and nested GitLab identities'
echo '# fm-pr-lib.test.sh: all assertions passed'
