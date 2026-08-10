#!/usr/bin/env bash
# Refuse a rebase that silently changes the content a pipeline already validated.
#
# The no-mistakes pipeline rebases a branch onto its target immediately before
# pushing it. When that rebase drops content, the opened PR misrepresents the
# code the pipeline actually judged, and nothing in the run reports it. This
# script is the mechanical form of the by-hand comparison that caught two such
# rebases; see docs/verification/rebase-equivalence.md for both reproductions.
#
# It compares the pre-rebase (validated) head against the post-rebase
# (candidate) head, each measured against ITS OWN base, and refuses when the
# candidate does not carry every content change the validated head made.
#
# WHERE THE CANDIDATE HEAD COMES FROM
# The pushed head is built inside the pipeline's own gate repository, and those
# objects never flow back to the worker's clone, so a worker cannot name it as
# a local ref. The forge is the one place both sides reach, so --candidate-pr
# fetches the request's head ref (refs/pull/<n>/head on GitHub,
# refs/merge-requests/<n>/head on GitLab) into a private ref and compares that.
# A fetch that cannot be made is CANNOT-OBSERVE, never a skip. --candidate-head
# stays available wherever both heads are already local.
#
# WHY EACH SIDE IS MEASURED AGAINST ITS OWN BASE
# `git diff <trunk>..<head>` is the wrong shape: tip-to-tip also reports trunk
# content the branch merely LACKS, which a real landing preserves rather than
# deletes. Diffing each head against its own base measures only what that head
# CONTRIBUTES, which is the quantity a rebase must carry over.
#
# WHY THIS IS NOT A MERGE-RESULT COMPARISON
# Screening a landing with `git merge-tree --write-tree <trunk> <head>` is the
# right tool for asking what a branch does to a trunk, and its exit status is
# authoritative there. It cannot serve as the rebase-equivalence predicate:
# the validated head is by construction still on its PRE-rebase base, so
# merging it into the post-rebase trunk conflicts whenever the trunk moved
# enough to require the rebase in the first place. Measured against the first
# reproduction, that merge exits 1 with conflicts in 90+ files while the
# rebased head merges clean, so the two results are not comparable and the
# comparison would refuse every rebase it was meant to screen.
#
# THE PREDICATE
# For every path the validated change touched:
#   - a path present at the validated head must exist at the candidate head;
#   - a deletion the validated change made must still be deleted;
#   - the candidate's copy of the path must hold at least as many copies of
#     each non-blank line as the validated change NET ADDED, so a hunk that
#     duplicates a line already in the file cannot be satisfied by the copy
#     that was already there. Only counts are compared, never positions, so
#     trunk movement and hunk drift do not register as loss and content the
#     trunk supplied independently still counts as carried. Lines match byte
#     for byte INCLUDING leading whitespace, so a re-indented line does read
#     as loss;
#   - a non-blank line the validated change NET REMOVED must not come back.
#     With --candidate-base that is measured against the candidate's own base,
#     so copies the TRUNK added are never mistaken for a resurrected removal.
#     Without it, only a line the validated change removed from the path
#     entirely is judged, because no other reappearance can be attributed to
#     the rebase rather than to the trunk.
#
# Verdicts are three-valued and only PASS is a pass:
#   0  PASS            every validated change is carried by the candidate
#   3  DROPPED         named paths lost validated content, with the direction
#   2  CANNOT-OBSERVE  an input, a git call, or a comparison could not be made
# An unresolvable ref, an unreachable candidate, a git failure, a binary path
# that changed, and an empty validated contribution are all CANNOT-OBSERVE,
# never a silent pass. The verdict line is always printed, so a caller that
# sees none knows the check did not run.
#
# Usage:
#   fm-rebase-equivalence.sh --repo <dir> \
#     --validated-base <ref> --validated-head <ref> \
#     { --candidate-pr <url-or-number> [--candidate-remote <name-or-url>] \
#       | --candidate-head <ref> } \
#     [--candidate-base <ref>]
#
# --candidate-base takes a trunk ref rather than an exact commit: the
# candidate's own base is derived from it with `git merge-base`, so naming the
# trunk branch still works after it has moved on. Supplying it sharpens the
# removal comparison only. The additions comparison stays absolute on purpose,
# because content the candidate inherited from its trunk instead of re-applying
# is still content that landed.
set -eu

VERDICT_PASS=0
VERDICT_CANNOT=2
VERDICT_DROPPED=3

cannot_observe() {  # <reason>
  printf 'REBASE-EQUIVALENCE: CANNOT-OBSERVE %s\n' "$1"
  exit "$VERDICT_CANNOT"
}

# The verdict vocabulary is defined before anything that can fail, so even a
# broken installation reports a verdict rather than a bare shell error.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -r "$SCRIPT_DIR/fm-pr-lib.sh" ] \
  || cannot_observe "request URL parsing is unavailable: $SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

REPO=
VALIDATED_BASE=
VALIDATED_HEAD=
CANDIDATE_HEAD=
CANDIDATE_PR=
CANDIDATE_REMOTE=
CANDIDATE_BASE=

usage() {
  cat <<'EOF'
Refuse a rebase that silently changes the content a pipeline already validated.

Compares the pre-rebase (validated) head against the post-rebase (candidate)
head, each measured against its own base, and refuses when the candidate does
not carry every content change the validated head made.

Usage:
  fm-rebase-equivalence.sh --repo <dir> \
    --validated-base <ref> --validated-head <ref> \
    { --candidate-pr <url-or-number> [--candidate-remote <name-or-url>] \
      | --candidate-head <ref> } \
    [--candidate-base <ref>]

--candidate-pr fetches the request's head ref from the forge, which is where a
worker can reach a head the pipeline built and pushed from its own repository.
--candidate-remote names where to fetch it from and defaults to origin; a full
request URL is also tried directly, so a request opened on a fork still
resolves.
--candidate-base names the trunk the candidate sits on. It is optional, and
supplying it lets the removal comparison tell a line the trunk added apart from
a validated removal the rebase undid.

Verdicts (only PASS is a pass):
  0  PASS            every validated change is carried by the candidate
  3  DROPPED         named paths lost validated content, with the direction
  2  CANNOT-OBSERVE  an input, a git call, or a comparison could not be made

See this script's header comment for the predicate and why it is neither a
tip-to-tip diff nor a merge-result comparison.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:-}; shift 2 || cannot_observe "--repo needs a value" ;;
    --validated-base) VALIDATED_BASE=${2:-}; shift 2 || cannot_observe "--validated-base needs a value" ;;
    --validated-head) VALIDATED_HEAD=${2:-}; shift 2 || cannot_observe "--validated-head needs a value" ;;
    --candidate-head) CANDIDATE_HEAD=${2:-}; shift 2 || cannot_observe "--candidate-head needs a value" ;;
    --candidate-pr) CANDIDATE_PR=${2:-}; shift 2 || cannot_observe "--candidate-pr needs a value" ;;
    --candidate-remote) CANDIDATE_REMOTE=${2:-}; shift 2 || cannot_observe "--candidate-remote needs a value" ;;
    --candidate-base) CANDIDATE_BASE=${2:-}; shift 2 || cannot_observe "--candidate-base needs a value" ;;
    -h|--help) usage; exit 0 ;;
    *) cannot_observe "unrecognized argument: $1" ;;
  esac
done

for pair in "repo:$REPO" "validated-base:$VALIDATED_BASE" \
  "validated-head:$VALIDATED_HEAD"; do
  [ -n "${pair#*:}" ] || cannot_observe "missing required --${pair%%:*}"
done
if [ -n "$CANDIDATE_HEAD" ] && [ -n "$CANDIDATE_PR" ]; then
  cannot_observe "--candidate-head and --candidate-pr name two different candidates; pass one"
fi
if [ -z "$CANDIDATE_HEAD" ] && [ -z "$CANDIDATE_PR" ]; then
  cannot_observe "missing required --candidate-head or --candidate-pr"
fi
if [ -n "$CANDIDATE_REMOTE" ] && [ -z "$CANDIDATE_PR" ]; then
  cannot_observe "--candidate-remote only applies to --candidate-pr"
fi

[ -d "$REPO" ] || cannot_observe "repository directory is unavailable: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || cannot_observe "not a git repository: $REPO"

# Fetch the candidate head from the forge. The head the pipeline pushed exists
# nowhere in the worker's clone, so a check that could only name a local commit
# would report CANNOT-OBSERVE on every run and gate nothing.
if [ -n "$CANDIDATE_PR" ]; then
  PR_NUMBER=
  PR_URL_SOURCE=
  PR_NAMESPACES=()
  case "$CANDIDATE_PR" in
    *://*)
      fm_pr_url_parse "$CANDIDATE_PR" \
        || cannot_observe "--candidate-pr is not a recognized pull or merge request URL: $CANDIDATE_PR"
      PR_NUMBER=$FM_PR_NUMBER
      PR_URL_SOURCE="https://$FM_PR_HOST/$FM_PR_PATH.git"
      case "$FM_PR_PROVIDER" in
        github) PR_NAMESPACES=(refs/pull) ;;
        *) PR_NAMESPACES=(refs/merge-requests) ;;
      esac
      ;;
    [1-9]*)
      case "$CANDIDATE_PR" in
        *[!0-9]*) cannot_observe "--candidate-pr must be a request URL or number: $CANDIDATE_PR" ;;
      esac
      PR_NUMBER=$CANDIDATE_PR
      # A bare number does not say which forge it came from, so both head
      # namespaces are tried rather than assuming one.
      PR_NAMESPACES=(refs/pull refs/merge-requests)
      ;;
    *) cannot_observe "--candidate-pr must be a request URL or number: $CANDIDATE_PR" ;;
  esac

  CANDIDATE_REF="refs/fm-rebase-equivalence/candidate/$PR_NUMBER"
  fetched=no
  for from in "${CANDIDATE_REMOTE:-origin}" "$PR_URL_SOURCE"; do
    [ -n "$from" ] || continue
    for namespace in "${PR_NAMESPACES[@]}"; do
      if git -C "$REPO" fetch --quiet "$from" \
        "+$namespace/$PR_NUMBER/head:$CANDIDATE_REF" >/dev/null 2>&1; then
        fetched=yes
        break
      fi
    done
    [ "$fetched" = no ] || break
  done
  [ "$fetched" = yes ] \
    || cannot_observe "cannot fetch the candidate head for request $PR_NUMBER from ${CANDIDATE_REMOTE:-origin}${PR_URL_SOURCE:+ or $PR_URL_SOURCE}"
  CANDIDATE_HEAD=$CANDIDATE_REF
fi

# Resolve every ref up front. A base or head that cannot be named is an input
# this check cannot stand on, never a comparison it may skip.
# Reports failure through its exit status rather than calling cannot_observe:
# it runs inside a command substitution, where a verdict printed here would be
# captured into the variable instead of reaching the caller.
resolve() {  # <ref>
  local out
  out=$(git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

VB=$(resolve "$VALIDATED_BASE") \
  || cannot_observe "cannot resolve --validated-base: $VALIDATED_BASE"
VH=$(resolve "$VALIDATED_HEAD") \
  || cannot_observe "cannot resolve --validated-head: $VALIDATED_HEAD"
CH=$(resolve "$CANDIDATE_HEAD") \
  || cannot_observe "cannot resolve --candidate-head: $CANDIDATE_HEAD"

# The candidate's own base. Derived with merge-base so the caller may name the
# trunk branch, which has usually moved on past the commit the candidate was
# actually rebased onto.
CB=
if [ -n "$CANDIDATE_BASE" ]; then
  CB_TRUNK=$(resolve "$CANDIDATE_BASE") \
    || cannot_observe "cannot resolve --candidate-base: $CANDIDATE_BASE"
  CB=$(git -C "$REPO" merge-base "$CB_TRUNK" "$CH" 2>/dev/null) \
    || cannot_observe "cannot find the candidate's own base under $CANDIDATE_BASE"
  [ -n "$CB" ] || cannot_observe "cannot find the candidate's own base under $CANDIDATE_BASE"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-rebase-equiv.XXXXXX") \
  || cannot_observe "cannot create a working directory"
trap 'rm -rf "$WORK"' EXIT INT TERM

# The validated contribution's footprint. --no-renames keeps both sides
# measuring the same way, so a rename detected on one side only cannot read as
# a drop.
if ! git -C "$REPO" diff --no-renames --no-ext-diff -z --name-only "$VB" "$VH" > "$WORK/paths.z" 2>/dev/null; then
  cannot_observe "cannot read the validated contribution ($VB..$VH)"
fi
if [ ! -s "$WORK/paths.z" ]; then
  cannot_observe "validated contribution is empty ($VB..$VH); there is nothing to compare"
fi

DROPS="$WORK/drops"
UNCERTAIN="$WORK/uncertain"
: > "$DROPS"
: > "$UNCERTAIN"

blob_exists() {  # <commit> <path>
  git -C "$REPO" cat-file -e "$1:$2" 2>/dev/null
}

# Materialize a blob, or an empty file when the path does not exist there. A
# missing path is a real observation of zero occurrences, not a failure.
blob_or_empty() {  # <commit> <path> <out>
  if blob_exists "$1" "$2"; then
    git -C "$REPO" show "$1:$2" > "$3" 2>/dev/null || return 1
    return 0
  fi
  : > "$3"
}

# A sentinel first line guarantees every input trips FNR==1, so an empty blob
# cannot silently merge two parts of the comparison together.
sentinel_copy() {  # <in> <out>
  { printf '\001fm-sentinel\n'; cat "$1"; } > "$2"
}

while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue

  # ":(literal)" keeps a tracked name containing *, ?, [ or a leading : from
  # being read as a wildcard, which would pull other files into this diff.
  if ! git -C "$REPO" diff --no-renames --no-ext-diff -U0 "$VB" "$VH" -- ":(literal)$path" > "$WORK/d" 2>/dev/null; then
    printf '%s\tthe validated change to this path could not be read\n' "$path" >> "$UNCERTAIN"
    continue
  fi

  vh_has=no; ch_has=no
  blob_exists "$VH" "$path" && vh_has=yes
  blob_exists "$CH" "$path" && ch_has=yes

  # Presence first: a path that is simply gone is an unambiguous drop, and
  # naming it as one keeps CANNOT-OBSERVE for what genuinely cannot be compared.
  if [ "$vh_has" = yes ] && [ "$ch_has" = no ]; then
    printf 'dropped-path\t%s\tpresent at the validated head, absent from the candidate\n' "$path" >> "$DROPS"
    continue
  fi
  if [ "$vh_has" = no ] && [ "$ch_has" = yes ]; then
    printf 'resurrected-path\t%s\tdeleted by the validated change, present again in the candidate\n' "$path" >> "$DROPS"
    continue
  fi
  if [ "$vh_has" = no ] && [ "$ch_has" = no ]; then
    continue
  fi

  # Both sides hold the path. A binary one cannot be compared line by line;
  # identical blobs are still a sound observation, anything else is reported
  # rather than assumed carried.
  if grep -q '^Binary files ' "$WORK/d" 2>/dev/null; then
    vh_blob=$(git -C "$REPO" rev-parse "$VH:$path" 2>/dev/null || true)
    ch_blob=$(git -C "$REPO" rev-parse "$CH:$path" 2>/dev/null || true)
    if [ -n "$vh_blob" ] && [ "$vh_blob" = "$ch_blob" ]; then
      continue
    fi
    printf '%s\tbinary path changed by the validated change cannot be compared line by line\n' "$path" >> "$UNCERTAIN"
    continue
  fi

  if ! blob_or_empty "$CH" "$path" "$WORK/cand"; then
    printf '%s\tthe candidate copy of this path could not be read\n' "$path" >> "$UNCERTAIN"
    continue
  fi
  if ! blob_or_empty "$VH" "$path" "$WORK/val"; then
    printf '%s\tthe validated copy of this path could not be read\n' "$path" >> "$UNCERTAIN"
    continue
  fi
  if [ -n "$CB" ]; then
    if ! blob_or_empty "$CB" "$path" "$WORK/cbase"; then
      printf "%s\tthe candidate's own base copy of this path could not be read\n" "$path" >> "$UNCERTAIN"
      continue
    fi
  else
    : > "$WORK/cbase"
  fi

  sentinel_copy "$WORK/d" "$WORK/p1"
  sentinel_copy "$WORK/cand" "$WORK/p2"
  sentinel_copy "$WORK/cbase" "$WORK/p3"
  sentinel_copy "$WORK/val" "$WORK/p4"

  # One pass over four inputs: the validated diff, then the candidate, the
  # candidate's own base, and the validated head's own copy of the path.
  # Blank and whitespace-only lines carry no content and are dropped: requiring
  # them would add noise without ever proving anything was preserved. Content
  # lines are taken only from inside hunks, and the in-hunk flag is cleared at
  # every file boundary, so no header can ever be harvested as content.
  if ! awk -v havebase="${CB:+1}" '
    FNR == 1 { part++; next }
    part == 1 {
      if ($0 ~ /^diff --git /) { inhunk = 0; next }
      if ($0 ~ /^@@/) { inhunk = 1; next }
      if (!inhunk) next
      if (substr($0, 1, 1) == "+") {
        line = substr($0, 2)
        if (line ~ /[^ \t]/) { delta[line]++; seen[line] = 1 }
        next
      }
      if (substr($0, 1, 1) == "-") {
        line = substr($0, 2)
        if (line ~ /[^ \t]/) { delta[line]--; seen[line] = 1 }
        next
      }
      next
    }
    part == 2 { if ($0 in seen) ch[$0]++; next }
    part == 3 { if ($0 in seen) cb[$0]++; next }
    part == 4 { if ($0 in seen) vh[$0]++; next }
    END {
      missing = 0
      back = 0
      for (line in seen) {
        d = delta[line]
        if (d > 0) {
          # Multiplicity is the point: K copies of a line that already occurred
          # once are not carried by the one copy that was already there.
          if (ch[line] < d) missing += d - ch[line]
        } else if (d < 0) {
          if (havebase == "1") {
            allowed = cb[line] - (-d)
            if (allowed < 0) allowed = 0
            if (ch[line] > allowed) back += ch[line] - allowed
          } else if (vh[line] == 0 && ch[line] > 0) {
            # Without the candidate base, a line the validated change only
            # thinned out cannot be told apart from one the trunk added, so
            # only a line it removed entirely is judged.
            back += ch[line]
          }
        }
      }
      printf "%d %d\n", missing, back
    }
  ' "$WORK/p1" "$WORK/p2" "$WORK/p3" "$WORK/p4" > "$WORK/counts" 2>/dev/null; then
    printf '%s\tthe content comparison could not be completed\n' "$path" >> "$UNCERTAIN"
    continue
  fi

  counts=$(tr -s '[:space:]' ' ' < "$WORK/counts")
  counts=${counts# }
  counts=${counts% }
  missing=${counts%% *}
  back=${counts##* }
  case "$missing$back" in
    ''|*[!0-9]*) printf '%s\tthe content comparison produced no readable result\n' "$path" >> "$UNCERTAIN"; continue ;;
  esac

  if [ "$missing" -gt 0 ]; then
    printf 'dropped-content\t%s\t%s line(s) added by the validated change are absent from the candidate\n' \
      "$path" "$missing" >> "$DROPS"
    continue
  fi
  if [ "$back" -gt 0 ]; then
    printf 'resurrected-content\t%s\t%s line(s) removed by the validated change reappear in the candidate\n' \
      "$path" "$back" >> "$DROPS"
    continue
  fi
done < "$WORK/paths.z"

if [ -s "$UNCERTAIN" ]; then
  printf 'REBASE-EQUIVALENCE: CANNOT-OBSERVE %s path(s) could not be compared\n' \
    "$(wc -l < "$UNCERTAIN" | tr -d '[:space:]')"
  while IFS=$'\t' read -r path reason; do
    printf '  %-21s%s: %s\n' uncomparable "$path" "$reason"
  done < "$UNCERTAIN"
  # A path that could not be compared hides whatever it would have reported, so
  # a confirmed drop alongside it is still named rather than swallowed.
  while IFS=$'\t' read -r kind path reason; do
    printf '  %-21s%s: %s\n' "$kind" "$path" "$reason"
  done < "$DROPS"
  exit "$VERDICT_CANNOT"
fi

if [ -s "$DROPS" ]; then
  printf 'REBASE-EQUIVALENCE: DROPPED %s path(s) lost validated content\n' \
    "$(wc -l < "$DROPS" | tr -d '[:space:]')"
  while IFS=$'\t' read -r kind path reason; do
    printf '  %-21s%s: %s\n' "$kind" "$path" "$reason"
  done < "$DROPS"
  exit "$VERDICT_DROPPED"
fi

printf 'REBASE-EQUIVALENCE: PASS validated content is carried by the candidate\n'
exit "$VERDICT_PASS"
