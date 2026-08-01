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
#     Idempotent publish: updates the open <head> -> <base> PR when one exists
#     AND its title marks it as a promotion record, otherwise creates one. Sets
#     FM_PROPLANE_PROMOTE_PR_OPENED to 1 once a record exists, and
#     FM_PROPLANE_PROMOTE_PR_NUMBER and _URL to that record when they are known.
#     <dry_run>=1 prints the PR it would open and makes no GitHub call.
#   fm_proplane_promote_pr_comment <git_root> <number> <message> <dry_run>
#     Annotate an already-opened record, for when the promotion it describes did
#     not finish landing.
#   fm_proplane_promote_pr_report_label <path>
#     The sha-keyed report filename alone, never the absolute local path.
set -u

# Commit lines carried in the PR body. A promotion that merges a long-running
# sandbox can carry hundreds; the range and count above them stay exact either
# way, so the listing is capped rather than allowed to dominate the record.
FM_PROPLANE_PR_COMMIT_CAP=${FM_PROPLANE_PR_COMMIT_CAP:-40}

# Seconds any single GitHub call may take. The record is opened in the window
# between the passing gates and the fast-forward of main, so an unbounded hang
# here stalls a promotion that has already earned its push. A capped call that
# fails is just another warn-and-continue failure; a hang is not.
FM_PROPLANE_PR_GH_TIMEOUT=${FM_PROPLANE_PR_GH_TIMEOUT:-60}

# Title prefix that marks a PR as this ladder's promotion record. Shared by the
# title builder and the reuse guard so the two can never drift apart.
FM_PROPLANE_PR_TITLE_PREFIX='promote(ladder): prakrit -> main'

# Open PRs the reuse scan reads. The scan stops at the first promotion record it
# sees, so the only cost of a wider listing is the rows gh-axi prints, while too
# narrow a listing hides the record behind any unrelated PR for the same pair.
FM_PROPLANE_PR_LIST_LIMIT=${FM_PROPLANE_PR_LIST_LIMIT:-20}

# What fm_proplane_promote_pr_sync last published. OPENED is the fact that a
# record exists, tracked apart from NUMBER and URL because gh-axi output that
# omits the URL leaves the number unreadable without meaning nothing was opened.
FM_PROPLANE_PROMOTE_PR_OPENED=0
FM_PROPLANE_PROMOTE_PR_NUMBER=''
FM_PROPLANE_PROMOTE_PR_URL=''

# Bounded gh-axi call. Prefers timeout, falls back to gtimeout, and runs the
# call bare when neither is installed rather than refusing to record anything.
fm_proplane_promote_pr_gh() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$FM_PROPLANE_PR_GH_TIMEOUT" gh-axi "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$FM_PROPLANE_PR_GH_TIMEOUT" gh-axi "$@"
  else
    gh-axi "$@"
  fi
}

# The record is published to GitHub, so it carries the report's sha-keyed
# filename alone: the absolute path would publish this machine's home layout.
fm_proplane_promote_pr_report_label() {
  local path=${1:-}
  [ -n "$path" ] || return 0
  printf '%s\n' "${path##*/}"
}

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
  printf '%s (%s..%s)\n' "$FM_PROPLANE_PR_TITLE_PREFIX" "$1" "$2"
}

fm_proplane_promote_pr_body() {
  local git_root=$1 base_ref=$2 head_ref=$3
  local security_status=$4 security_report=$5 validation_status=$6
  local base_sha head_sha count listing listed log report_line
  base_sha=$(fm_proplane_promote_pr_short_sha "$git_root" "$base_ref")
  head_sha=$(fm_proplane_promote_pr_short_sha "$git_root" "$head_ref")
  count=$(fm_proplane_promote_pr_range_count "$git_root" "$base_ref" "$head_ref")
  listing=$(git -C "$git_root" log --no-merges --format='- %h %s' "$base_ref..$head_ref" 2>/dev/null) || listing=""
  if [ -z "$listing" ]; then
    log='- (no non-merge commits in this range)'
  else
    listed=$(printf '%s\n' "$listing" | wc -l | tr -d '[:space:]')
    log=$(printf '%s\n' "$listing" | head -n "$FM_PROPLANE_PR_COMMIT_CAP")
    # Without this marker a capped listing is indistinguishable from one the
    # --no-merges filter shortened, so a reader cannot tell which commits the
    # record omitted or why.
    if [ "$listed" -gt "$FM_PROPLANE_PR_COMMIT_CAP" ]; then
      log="$log
- (... $((listed - FM_PROPLANE_PR_COMMIT_CAP)) more, listing capped at $FM_PROPLANE_PR_COMMIT_CAP)"
    fi
  fi
  report_line=""
  if [ -n "$security_report" ]; then
    report_line="
- report: \`$security_report\`"
  fi

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

# Echo the PR number in a GitHub pull URL, or nothing.
fm_proplane_promote_pr_number_from_url() {
  printf '%s\n' "$1" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' | head -n 1 || true
}

fm_proplane_promote_pr_sync() {
  local git_root=$1 base=$2 head=$3 title=$4 body_file=$5 dry_run=${6:-0}
  local listing number out url

  FM_PROPLANE_PROMOTE_PR_OPENED=0
  FM_PROPLANE_PROMOTE_PR_NUMBER=''
  FM_PROPLANE_PROMOTE_PR_URL=''

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
  listing=$(cd "$git_root" && fm_proplane_promote_pr_gh pr list --state open --base "$base" --head "$head" --limit "$FM_PROPLANE_PR_LIST_LIMIT" 2>&1) || {
    echo "proplane-promote-pr: could not list open PRs for $head -> $base" >&2
    printf '%s\n' "$listing" >&2
    return 1
  }
  # Reuse is decided on the row's title, not on its position in the listing.
  # Trusting the first numeric row would rewrite an unrelated open PR's title and
  # body outright if gh-axi ever stopped honoring --base/--head or changed the
  # row layout, and that damage is not something a warning can undo.
  number=$(printf '%s\n' "$listing" | awk -v want="$FM_PROPLANE_PR_TITLE_PREFIX" '
    /^[[:space:]]+[0-9]+,/ {
      row = $0
      sub(/^[[:space:]]+/, "", row)
      num = row
      sub(/,.*/, "", num)
      title = row
      sub(/^[0-9]+,/, "", title)
      sub(/^"/, "", title)
      if (index(title, want) == 1) { print num; exit }
    }')
  if [ -z "$number" ] && printf '%s\n' "$listing" | grep -qE '^[[:space:]]+[0-9]+,'; then
    echo "proplane-promote-pr: no open $head -> $base PR is a promotion record, opening a new one rather than rewriting an unrelated PR" >&2
  fi

  if [ -n "$number" ]; then
    out=$(cd "$git_root" && fm_proplane_promote_pr_gh pr edit "$number" --title "$title" --body-file "$body_file" 2>&1) || {
      echo "proplane-promote-pr: could not update promotion record PR #$number" >&2
      printf '%s\n' "$out" >&2
      return 1
    }
    # shellcheck disable=SC2034 # Read by callers after fm_proplane_promote_pr_sync returns.
    FM_PROPLANE_PROMOTE_PR_OPENED=1
    FM_PROPLANE_PROMOTE_PR_NUMBER=$number
    echo "proplane-promote-pr: updated promotion record PR #$number"
  else
    out=$(cd "$git_root" && fm_proplane_promote_pr_gh pr create --base "$base" --head "$head" \
      --title "$title" --body-file "$body_file" 2>&1) || {
      echo "proplane-promote-pr: could not open promotion record PR" >&2
      printf '%s\n' "$out" >&2
      return 1
    }
    # shellcheck disable=SC2034 # Read by callers after fm_proplane_promote_pr_sync returns.
    FM_PROPLANE_PROMOTE_PR_OPENED=1
    echo "proplane-promote-pr: opened promotion record PR"
  fi

  url=$(fm_proplane_promote_pr_first_url "$out")
  if [ -n "$url" ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_proplane_promote_pr_sync returns.
    FM_PROPLANE_PROMOTE_PR_URL=$url
    echo "proplane-promote-pr: $url"
    [ -n "$FM_PROPLANE_PROMOTE_PR_NUMBER" ] ||
      FM_PROPLANE_PROMOTE_PR_NUMBER=$(fm_proplane_promote_pr_number_from_url "$url")
  fi
  return 0
}

# Add a note to an already-opened record. Used when the fast-forward the record
# announces did not complete, so the record never asserts a promotion that did
# not happen. Returns non-zero for the caller to warn on: an annotation that
# cannot be posted must never change the outcome of the promotion that failed.
fm_proplane_promote_pr_comment() {
  local git_root=$1 number=$2 message=$3 dry_run=${4:-0} out

  [ -n "$number" ] || {
    echo "proplane-promote-pr: no promotion record number to annotate" >&2
    return 1
  }

  if [ "$dry_run" = 1 ]; then
    echo "DRY gh-axi pr comment $number --body \"$message\""
    return 0
  fi

  command -v gh-axi >/dev/null 2>&1 || {
    echo "proplane-promote-pr: gh-axi unavailable, promotion record PR #$number not annotated" >&2
    return 1
  }

  out=$(cd "$git_root" && fm_proplane_promote_pr_gh pr comment "$number" --body "$message" 2>&1) || {
    echo "proplane-promote-pr: could not annotate promotion record PR #$number" >&2
    printf '%s\n' "$out" >&2
    return 1
  }
  echo "proplane-promote-pr: annotated promotion record PR #$number"
  return 0
}
