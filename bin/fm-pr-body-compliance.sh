#!/usr/bin/env bash
# fm-pr-body-compliance.sh - verify no-mistakes provenance for one GitHub PR.
#
# Inputs are supplied by .github/workflows/no-mistakes-required.yml:
#   PR_BODY        current pull-request body
#   PR_AUTHOR      pull-request author's GitHub login (diagnostic only)
#   PR_NUMBER      pull-request number (diagnostic only)
#   PR_HEAD_SHA    exact current pull-request head commit
#   GH_REPOSITORY  owner/repository containing the pull request
#   GH_TOKEN       token with read access to checks
#
# The deterministic body marker is the primary proof.
# A successful earlier invocation of this same GitHub Actions check on the exact
# same head is durable equivalent evidence: explanatory body edits cannot erase
# the already-recorded attestation, while any code change produces a new head
# that must carry the marker and pass independently.
set -u

marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
check_name='PR must be raised via no-mistakes'

if printf '%s' "${PR_BODY:-}" | grep -qF -- "$marker"; then
  printf 'Found no-mistakes signature in PR #%s body.\n' "${PR_NUMBER:-unknown}"
  exit 0
fi

checks=''
prior_heads=''
case "${PR_HEAD_SHA:-}" in
  *[!0-9a-fA-F]*|'') ;;
  *)
    if [ "${#PR_HEAD_SHA}" -eq 40 ] && [ -n "${GH_REPOSITORY:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
      checks=$(GH_TOKEN=$GH_TOKEN gh api --paginate \
        -H 'Accept: application/vnd.github+json' \
        "/repos/${GH_REPOSITORY}/commits/${PR_HEAD_SHA}/check-runs?per_page=100" \
        2>/dev/null) || checks=
      prior_heads=$(printf '%s\n' "$checks" | jq -r --arg name "$check_name" \
        '.check_runs[]? | select(.name == $name and .conclusion == "success" and .app.slug == "github-actions") | .head_sha' \
        2>/dev/null) || prior_heads=
    fi
    ;;
esac

if printf '%s\n' "$prior_heads" | grep -qxF -- "${PR_HEAD_SHA:-}"; then
  printf 'Found a successful no-mistakes attestation for the same head of PR #%s.\n' \
    "${PR_NUMBER:-unknown}"
  exit 0
fi

{
  echo "::error::This PR was not raised through no-mistakes."
  echo
  echo "Contributions to this repository must be submitted via 'git push no-mistakes'."
  echo "That pipeline runs the required review/test/lint/CI steps and writes a"
  echo "deterministic '## Pipeline' section into the PR body containing:"
  echo
  echo "    $marker"
  echo
  echo "See CONTRIBUTING.md for setup and the full workflow."
  echo
  echo "PR author: ${PR_AUTHOR:-unknown}"
} >&2
exit 1
