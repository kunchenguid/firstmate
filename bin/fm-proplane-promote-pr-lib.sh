#!/usr/bin/env bash
# Promotion-record pull request for the PropPlane keeper ladder (prakrit -> main).
#
# Standing captain order (2026-07-31): every prakrit -> main promotion leaves a
# pull request behind, so what went live and the evidence it went live on stay
# readable after the fact.
#
# The PR is a RECORD, not a second gate. The ladder fast-forwards main
# immediately after opening it, which GitHub closes as merged. Nothing here
# waits for a review, and nothing here may abort a promotion: a GitHub failure
# costs the record, while stopping midway leaves main and production diverged.
# Every function below therefore returns non-zero for the caller to warn on
# rather than exiting the process.
#
# Sourced by bin/fm-proplane-promote-prakrit-to-main.sh (opens the PR) and
# bin/fm-proplane-promote-full.sh (--dry-run preview). GitHub access goes
# through gh-axi, per AGENTS.md.
#
# Public functions:
#   fm_proplane_promote_pr_range_count <git_root> <base_ref> <head_ref>
#     Commits in <base_ref>..<head_ref>, or 0 when the range cannot be read.
#   fm_proplane_promote_pr_title <base_sha> <head_sha>
#     One-line PR title naming the promoted range.
#   fm_proplane_promote_pr_body <git_root> <base_ref> <head_ref> <security_status> <security_report> <validation_status>
#     Markdown body: promoted commit range, security-review outcome, validation
#     outcome. <security_report> may be empty when no report path was printed.
#   fm_proplane_promote_pr_sync <git_root> <base> <head> <title> <body_file> <dry_run>
#     Idempotent publish: updates the open <head> -> <base> PR when one exists,
#     otherwise creates it. <dry_run>=1 prints the PR it would open and makes no
#     GitHub call.
set -u

# Commit lines carried in the PR body. A promotion that merges a long-running
# sandbox can carry hundreds; the range and count above them stay exact either
# way, so the listing is capped rather than allowed to dominate the record.
FM_PROPLANE_PR_COMMIT_CAP=${FM_PROPLANE_PR_COMMIT_CAP:-40}

fm_proplane_promote_pr_range_count() {
  local git_root=$1 base_ref=$2 head_ref=$3 count
  count=$(git -C "$git_root" rev-list --count "$base_ref..$head_ref" 2>/dev/null) || count=0
  printf '%s\n' "${count:-0}"
}

fm_proplane_promote_pr_short_sha() {
  local git_root=$1 ref=$2 sha
  sha=$(git -C "$git_root" rev-parse --short "$ref" 2>/dev/null) || sha=unknown
  printf '%s\n' "${sha:-unknown}"
}

fm_proplane_promote_pr_title() {
  printf 'promote(ladder): prakrit -> main (%s..%s)\n' "$1" "$2"
}

fm_proplane_promote_pr_body() {
  local git_root=$1 base_ref=$2 head_ref=$3
  local security_status=$4 security_report=$5 validation_status=$6
  local base_sha head_sha count log report_line
  base_sha=$(fm_proplane_promote_pr_short_sha "$git_root" "$base_ref")
  head_sha=$(fm_proplane_promote_pr_short_sha "$git_root" "$head_ref")
  count=$(fm_proplane_promote_pr_range_count "$git_root" "$base_ref" "$head_ref")
  log=$(git -C "$git_root" log --no-merges --format='- %h %s' "$base_ref..$head_ref" 2>/dev/null |
    head -n "$FM_PROPLANE_PR_COMMIT_CAP") || log=""
  [ -n "$log" ] || log='- (no non-merge commits in this range)'
  report_line=""
  [ -n "$security_report" ] && report_line="
- report: \`$security_report\`"

  cat <<EOF
Promotion record for the PropPlane keeper ladder: \`prakrit\` -> \`main\`.

## What is being promoted

- range: \`$base_ref..$head_ref\` (\`$base_sha..$head_sha\`)
- commits: $count

$log

## Security review

- outcome: $security_status$report_line

## Validation

- outcome: $validation_status

## How this lands

The ladder fast-forwards \`main\` to this range right after opening this PR, which closes this PR as merged.
This PR is the promotion record, not a second approval gate, so nothing waits on a review here.
EOF
}

# Echo the first URL in a blob of tool output, or nothing. Used only to give the
# captain a full link; a tool that prints no URL is not a failure.
fm_proplane_promote_pr_first_url() {
  printf '%s\n' "$1" | grep -oE 'https://[^[:space:]"]+' | head -n 1 || true
}

fm_proplane_promote_pr_sync() {
  local git_root=$1 base=$2 head=$3 title=$4 body_file=$5 dry_run=${6:-0}
  local listing number out url

  if [ "$dry_run" = 1 ]; then
    echo "DRY gh-axi pr create --base $base --head $head --title \"$title\" --body-file <generated>"
    echo "--- PR body (dry run, not opened) ---"
    cat "$body_file"
    echo "--- end PR body ---"
    return 0
  fi

  command -v gh-axi >/dev/null 2>&1 || {
    echo "proplane-promote-pr: gh-axi unavailable, no promotion record opened" >&2
    return 1
  }

  # An open PR for the same head -> base pair IS the record for this promotion,
  # so a re-run updates it instead of stacking a duplicate. Once the ladder
  # fast-forwards main the PR closes as merged, so the next promotion of a new
  # range correctly finds nothing open and creates its own record.
  listing=$(cd "$git_root" && gh-axi pr list --state open --base "$base" --head "$head" --limit 1 2>&1) || {
    echo "proplane-promote-pr: could not list open PRs for $head -> $base" >&2
    printf '%s\n' "$listing" >&2
    return 1
  }
  number=$(printf '%s\n' "$listing" |
    awk '/^[[:space:]]+[0-9]+,/ { sub(/^[[:space:]]+/, ""); sub(/,.*/, ""); print; exit }')

  if [ -n "$number" ]; then
    out=$(cd "$git_root" && gh-axi pr edit "$number" --title "$title" --body-file "$body_file" 2>&1) || {
      echo "proplane-promote-pr: could not update promotion record PR #$number" >&2
      printf '%s\n' "$out" >&2
      return 1
    }
    echo "proplane-promote-pr: updated promotion record PR #$number"
  else
    out=$(cd "$git_root" && gh-axi pr create --base "$base" --head "$head" \
      --title "$title" --body-file "$body_file" 2>&1) || {
      echo "proplane-promote-pr: could not open promotion record PR" >&2
      printf '%s\n' "$out" >&2
      return 1
    }
    echo "proplane-promote-pr: opened promotion record PR"
  fi

  url=$(fm_proplane_promote_pr_first_url "$out")
  [ -n "$url" ] && echo "proplane-promote-pr: $url"
  return 0
}
