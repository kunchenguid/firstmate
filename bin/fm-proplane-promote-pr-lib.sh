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
# Record versus rendered diff: the promotion is built on integrate/prakrit-to-main
# (the no-mistakes validation commits its fixes there, not onto prakrit), but the
# keeper-branch rule never pushes integrate/* to GitHub, so the PR is opened from
# prakrit and GitHub renders prakrit's diff. Those two can disagree in both
# directions, so the body states the promoted range as authoritative, names the
# exact tip main is fast-forwarded to, and lists the commits on either side of the
# disagreement. A reader must never be misled about what landed.
#
# That comparison is made against a freshly fetched prakrit, never the local
# remote-tracking ref: the record is opened long after this run's first fetch,
# and a sandbox that promotes into prakrit in between would otherwise be invisible
# to a reconciliation that claims to describe what GitHub shows.
#
# Sourced by bin/fm-proplane-promote-prakrit-to-main.sh (opens the PR) and
# bin/fm-proplane-promote-full.sh (--dry-run preview). GitHub access goes
# through gh-axi, per AGENTS.md.
#
# Public functions:
#   fm_proplane_promote_pr_range_count <git_root> <base_ref> <head_ref>
#     Commits in <base_ref>..<head_ref>, merges included, or 0 when the range
#     cannot be read. This is the size of what lands, so it decides whether there
#     is anything to record at all.
#   fm_proplane_promote_pr_commit_count <git_root> <no-merges|with-merges> <rev-args...>
#   fm_proplane_promote_pr_commit_listing <git_root> <empty_text> <no-merges|with-merges> <rev-args...>
#     A count and its listing, taken under the same filter. Every number the body
#     prints beside a list comes from the first with the filter the second used.
#   fm_proplane_promote_pr_title <base_sha> <head_sha>
#     One-line PR title naming the promoted range.
#   fm_proplane_promote_pr_body <git_root> <base_ref> <head_ref> <security_status> <security_report> <validation_status> [pr_head_ref] [kind]
#     Markdown body: promoted commit range, the exact tip main is fast-forwarded
#     to, security-review outcome, validation outcome. <security_report> may be
#     empty when no report path was printed. <pr_head_ref> is the local ref for
#     the branch the PR is opened FROM (origin/prakrit); when it is given, the
#     body reconciles the promoted range against the diff GitHub actually
#     renders. See "record versus rendered diff" below.
#     <kind> is `record` (default) or `preview`. A preview runs before the
#     integrate branch exists, so it knows neither the tip main lands on nor how
#     the head branch compares to it, and says so instead of guessing. A preview
#     reconciles nothing and therefore makes no network call at all.
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

# Bounded network call. Prefers timeout, falls back to gtimeout, and runs the
# call bare when neither is installed rather than refusing to record anything.
fm_proplane_promote_pr_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$FM_PROPLANE_PR_GH_TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$FM_PROPLANE_PR_GH_TIMEOUT" "$@"
  else
    "$@"
  fi
}

fm_proplane_promote_pr_gh() {
  fm_proplane_promote_pr_bounded gh-axi "$@"
}

# Refresh the PR's head branch from origin. The reconciliation describes the diff
# GitHub renders, which is the REMOTE branch: the record is opened minutes to
# hours after this run's first fetch, and another sandbox can promote into
# prakrit in that window, so the local remote-tracking ref is not evidence of
# what the PR will show. Read-only against origin, bounded like every other
# network call here, and it moves no local branch. Non-zero means the head could
# not be read, which the body reports rather than answering from a stale ref.
fm_proplane_promote_pr_refresh_head() {
  local git_root=$1 pr_head_ref=$2 branch out
  [ -n "$pr_head_ref" ] || return 1
  case "$pr_head_ref" in
    origin/*) branch=${pr_head_ref#origin/} ;;
    # A ref that is not remote-tracking cannot go stale behind us, so it is used
    # as given rather than invented a remote branch name for.
    *) git -C "$git_root" rev-parse --verify --quiet "$pr_head_ref" >/dev/null 2>&1 || return 1
       return 0
       ;;
  esac
  out=$(fm_proplane_promote_pr_bounded git -C "$git_root" fetch --quiet origin \
    "+refs/heads/$branch:refs/remotes/origin/$branch" 2>&1) || {
    echo "proplane-promote-pr: could not refresh $pr_head_ref from origin, so the record will state that its reconciliation is unavailable" >&2
    printf '%s\n' "$out" >&2
    return 1
  }
  git -C "$git_root" rev-parse --verify --quiet "$pr_head_ref" >/dev/null 2>&1 || {
    echo "proplane-promote-pr: $pr_head_ref is unreadable even after refreshing from origin" >&2
    return 1
  }
  return 0
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

# Commits matching the given rev-list arguments under <merges>, which is
# `no-merges` or `with-merges`. Every number the body prints beside a listing is
# taken from here with the SAME <merges> the listing used: a count and a list
# that disagree are how a record ends up contradicting itself about what is
# missing, and the truncation marker is the only thing allowed to explain a gap.
fm_proplane_promote_pr_commit_count() {
  local git_root=$1 merges=$2
  shift 2
  local count
  if [ "$merges" = with-merges ]; then
    count=$(git -C "$git_root" rev-list --count "$@" 2>/dev/null) || count=0
  else
    count=$(git -C "$git_root" rev-list --count --no-merges "$@" 2>/dev/null) || count=0
  fi
  printf '%s\n' "${count:-0}"
}

# A capped `- <sha> <subject>` listing for the given rev-list arguments, under the
# same <merges> filter its count was taken with. The cap keeps a long promotion
# from drowning the record; the marker keeps a capped listing from reading as one
# a filter shortened, so a reader can always tell what the record omitted and why.
fm_proplane_promote_pr_commit_listing() {
  local git_root=$1 empty_text=$2 merges=$3
  shift 3
  local listing listed out
  if [ "$merges" = with-merges ]; then
    listing=$(git -C "$git_root" log --format='- %h %s' "$@" 2>/dev/null) || listing=""
  else
    listing=$(git -C "$git_root" log --no-merges --format='- %h %s' "$@" 2>/dev/null) || listing=""
  fi
  if [ -z "$listing" ]; then
    printf '%s\n' "$empty_text"
    return 0
  fi
  listed=$(printf '%s\n' "$listing" | wc -l | tr -d '[:space:]')
  out=$(printf '%s\n' "$listing" | head -n "$FM_PROPLANE_PR_COMMIT_CAP")
  if [ "$listed" -gt "$FM_PROPLANE_PR_COMMIT_CAP" ]; then
    out="$out
- (... $((listed - FM_PROPLANE_PR_COMMIT_CAP)) more, listing capped at $FM_PROPLANE_PR_COMMIT_CAP)"
  fi
  printf '%s\n' "$out"
}

fm_proplane_promote_pr_body() {
  local git_root=$1 base_ref=$2 head_ref=$3
  local security_status=$4 security_report=$5 validation_status=$6
  local pr_head_ref=${7:-} kind=${8:-record}
  local base_sha head_sha head_tip tip_line count listed_count count_line log report_line
  local pr_head_label diff_section lands_section will_close
  local unshown_count unlanded_count unshown_log unlanded_log
  local merge_only merge_only_count merge_only_log merge_only_lead
  base_sha=$(fm_proplane_promote_pr_short_sha "$git_root" "$base_ref")
  head_sha=$(fm_proplane_promote_pr_short_sha "$git_root" "$head_ref")
  count=$(fm_proplane_promote_pr_range_count "$git_root" "$base_ref" "$head_ref")
  listed_count=$(fm_proplane_promote_pr_commit_count "$git_root" no-merges "$base_ref..$head_ref")
  log=$(fm_proplane_promote_pr_commit_listing "$git_root" \
    '- (no non-merge commits in this range)' no-merges "$base_ref..$head_ref")
  # The listing below is non-merge commits, so a bare total would tell a reader
  # the list is short by a number with no truncation marker to explain it. The
  # total is what lands on main, so it stays, labelled with what the list shows.
  if [ "$count" = "$listed_count" ]; then
    count_line="- commits: $count"
  else
    count_line="- commits: $count (merges included; the $listed_count non-merge commits are what the listing below shows)"
  fi
  report_line=""
  if [ -n "$security_report" ]; then
    report_line="
- report: \`$security_report\`"
  fi

  diff_section=""
  if [ "$kind" = preview ]; then
    # A preview reports the ref it actually read, and never claims that ref is
    # what main lands on: only the real run builds the branch it fast-forwards to.
    # Where the ref cannot be read at all, saying so is the honest answer, and
    # synthesising a tip would be a sentence that is false for the run previewed.
    head_tip=$(git -C "$git_root" rev-parse "$head_ref" 2>/dev/null) || head_tip=""
    if [ -n "$head_tip" ]; then
      tip_line="- \`$head_ref\` is at \`$head_tip\` right now; the real promotion records the tip of \`integrate/prakrit-to-main\` as that branch stands when it runs"
    else
      tip_line="- \`$head_ref\` cannot be read here, so this preview names no tip; the real promotion records the tip of \`integrate/prakrit-to-main\` as that branch stands when it runs"
    fi
    diff_section="## This is a preview, not a record

This is the promotion record a real promote would open, built from \`$base_ref..$head_ref\` as they stand right now.
The real promotion validates on \`integrate/prakrit-to-main\` and records that branch's tip, which normally also carries the integration merge and any commits the no-mistakes validation itself makes, so both the range and the tip above can still move before the real record is written.
No pull request is opened, updated, or read by this preview, and nothing here is compared against the branch GitHub would render.

"
    lands_section="The ladder fast-forwards \`main\` to the recorded integrate tip right after opening the real record.
GitHub closes that PR as merged once \`main\` contains its head branch."
  else
    # The full sha of the tip main is fast-forwarded to: the record has to name
    # what landed exactly, not a ref name that keeps moving after the promotion.
    head_tip=$(git -C "$git_root" rev-parse "$head_ref" 2>/dev/null) || head_tip=unknown
    tip_line="- \`main\` is fast-forwarded to: \`$head_tip\`"
    # Without a readable PR head there is nothing to reconcile the range against,
    # so the closing line states the condition instead of asserting the outcome.
    lands_section="The ladder fast-forwards \`main\` to \`$head_tip\` right after opening this PR.
GitHub closes this PR as merged once \`main\` contains this PR's head branch."

    if [ -n "$pr_head_ref" ]; then
      pr_head_label=${pr_head_ref#origin/}
      diff_section="## Record versus this PR's diff

This PR's head is \`$pr_head_label\`, but the promoted range above is built on \`$head_ref\`, which the keeper-branch rule never pushes to GitHub.
The promoted range above is authoritative for what lands on \`main\`; the diff GitHub renders here is \`$pr_head_label\` and can differ from it.
"
      if ! fm_proplane_promote_pr_refresh_head "$git_root" "$pr_head_ref"; then
        diff_section="$diff_section
\`$pr_head_label\` could not be read from \`origin\` when this record was written, so this record cannot say which promoted commits its diff omits, nor which commits its diff shows that this promotion did not land.
The promoted range above still states exactly what lands on \`main\`.

"
      else
        # Whether GitHub closes the PR is an ancestry question, not a commit-count
        # one: a merge commit moves no file yet still decides it. That answer also
        # decides the alignment sentence below, so the body can never call the head
        # aligned and then say it carries work the promotion does not deliver.
        will_close=0
        if git -C "$git_root" merge-base --is-ancestor "$pr_head_ref" "$head_ref" 2>/dev/null; then
          will_close=1
        fi
        unshown_count=$(fm_proplane_promote_pr_commit_count "$git_root" no-merges "$base_ref..$head_ref" --not "$pr_head_ref")
        unlanded_count=$(fm_proplane_promote_pr_commit_count "$git_root" no-merges "$pr_head_ref" --not "$head_ref")
        # The head is outside the promoted range, yet nothing non-merge on it is:
        # what keeps this record from closing is merge commits alone.
        merge_only=0
        if [ "$will_close" -eq 0 ] && [ "${unlanded_count:-0}" -eq 0 ]; then
          merge_only=1
        fi
        if [ "${unshown_count:-0}" -gt 0 ]; then
          unshown_log=$(fm_proplane_promote_pr_commit_listing "$git_root" \
            '- (none)' no-merges "$base_ref..$head_ref" --not "$pr_head_ref")
          diff_section="$diff_section
Promoted but NOT on \`$pr_head_label\`, so this PR's diff does not show them ($unshown_count):

$unshown_log
"
        fi
        if [ "${unlanded_count:-0}" -gt 0 ]; then
          unlanded_log=$(fm_proplane_promote_pr_commit_listing "$git_root" \
            '- (none)' no-merges "$pr_head_ref" --not "$head_ref")
          diff_section="$diff_section
On \`$pr_head_label\` but NOT promoted, so this PR's diff shows them even though this promotion did not land them ($unlanded_count):

$unlanded_log
"
        fi
        if [ "${unshown_count:-0}" -eq 0 ] && [ "${unlanded_count:-0}" -eq 0 ] && [ "$will_close" -eq 1 ]; then
          diff_section="$diff_section
\`$pr_head_label\` carries the same non-merge commits as the promoted range, so this PR's diff is the promotion.
"
        fi
        # The ladder's own sync puts bare merge(main) commits on prakrit, so a head
        # that is not contained while nothing non-merge is unlanded is routine, and
        # it can happen alongside a divergence in the other direction. This is the
        # single condition the closing sentence below reads too, so that sentence
        # can never point at a listing this block did not emit.
        if [ "$merge_only" -eq 1 ]; then
          merge_only_count=$(fm_proplane_promote_pr_commit_count "$git_root" with-merges "$pr_head_ref" --not "$head_ref")
          merge_only_log=$(fm_proplane_promote_pr_commit_listing "$git_root" \
            '- (none)' with-merges "$pr_head_ref" --not "$head_ref")
          if [ "${unshown_count:-0}" -eq 0 ]; then
            merge_only_lead="\`$pr_head_label\` carries the same non-merge commits as the promoted range, so this PR's diff is the promotion, but \`$pr_head_label\` is still not contained in it"
          else
            merge_only_lead="\`$pr_head_label\` is still not contained in the promoted range, which already carries every non-merge commit on \`$pr_head_label\`"
          fi
          diff_section="$diff_section
$merge_only_lead: the difference is merge commits only ($merge_only_count):

$merge_only_log
"
        fi
        diff_section="$diff_section
"
        if [ "$will_close" -eq 1 ]; then
          lands_section="The ladder fast-forwards \`main\` to \`$head_tip\` right after opening this PR, which closes this PR as merged: \`main\` then contains \`$pr_head_label\`."
        else
          if [ "$merge_only" -eq 1 ]; then
            lands_section="The ladder fast-forwards \`main\` to \`$head_tip\` right after opening this PR.
This PR does NOT close as merged, because \`main\` does not contain \`$pr_head_label\` after that fast-forward: the difference is merge commits only, listed above."
          else
            lands_section="The ladder fast-forwards \`main\` to \`$head_tip\` right after opening this PR.
This PR does NOT close as merged, because \`main\` does not contain \`$pr_head_label\` after that fast-forward: \`$pr_head_label\` carries $unlanded_count commit(s) this promotion does not deliver, listed above."
          fi
          lands_section="$lands_section
It stays open until a later promotion records the range that catches that work up; \`main\` carries the promoted range above either way."
        fi
      fi
    fi
  fi

  cat <<EOF
Promotion record for the PropPlane keeper ladder: \`prakrit\` -> \`main\`.

## What is being promoted

- range: \`$base_ref..$head_ref\` (\`$base_sha..$head_sha\`)
$count_line
$tip_line

$log

${diff_section}## Security review

- outcome: $security_status$report_line

## Validation

- outcome: $validation_status

## How this lands

$lands_section
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
