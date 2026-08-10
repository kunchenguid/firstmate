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
#   - every non-blank line the validated change ADDED must be present in the
#     candidate's copy of that path (presence, not position, so trunk movement,
#     re-indentation, and hunk drift do not register as loss, and content the
#     trunk supplied independently still counts as carried);
#   - a non-blank line the validated change REMOVED must not come back in more
#     copies than the validated head itself kept.
#
# Verdicts are three-valued and only PASS is a pass:
#   0  PASS            every validated change is carried by the candidate
#   3  DROPPED         named paths lost validated content, with the direction
#   2  CANNOT-OBSERVE  an input, a git call, or a comparison could not be made
# An unresolvable ref, a git failure, a binary path that changed, and an empty
# validated contribution are all CANNOT-OBSERVE, never a silent pass. The
# verdict line is always printed, so a caller that sees none knows the check
# did not run.
#
# Usage:
#   fm-rebase-equivalence.sh --repo <dir> \
#     --validated-base <ref> --validated-head <ref> \
#     --candidate-head <ref>
#
# The candidate needs no base: the question is whether the validated content
# survives INTO the candidate's files, and content the candidate inherited from
# its trunk rather than re-applying is still content that landed.
set -eu

VERDICT_PASS=0
VERDICT_CANNOT=2
VERDICT_DROPPED=3

REPO=
VALIDATED_BASE=
VALIDATED_HEAD=
CANDIDATE_HEAD=

usage() {
  cat <<'EOF'
Refuse a rebase that silently changes the content a pipeline already validated.

Compares the pre-rebase (validated) head against the post-rebase (candidate)
head, each measured against its own base, and refuses when the candidate does
not carry every content change the validated head made.

Usage:
  fm-rebase-equivalence.sh --repo <dir> \
    --validated-base <ref> --validated-head <ref> \
    --candidate-head <ref>

Verdicts (only PASS is a pass):
  0  PASS            every validated change is carried by the candidate
  3  DROPPED         named paths lost validated content, with the direction
  2  CANNOT-OBSERVE  an input, a git call, or a comparison could not be made

See this script's header comment for the predicate and why it is neither a
tip-to-tip diff nor a merge-result comparison.
EOF
}

cannot_observe() {  # <reason>
  printf 'REBASE-EQUIVALENCE: CANNOT-OBSERVE %s\n' "$1"
  exit "$VERDICT_CANNOT"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO=${2:-}; shift 2 || cannot_observe "--repo needs a value" ;;
    --validated-base) VALIDATED_BASE=${2:-}; shift 2 || cannot_observe "--validated-base needs a value" ;;
    --validated-head) VALIDATED_HEAD=${2:-}; shift 2 || cannot_observe "--validated-head needs a value" ;;
    --candidate-head) CANDIDATE_HEAD=${2:-}; shift 2 || cannot_observe "--candidate-head needs a value" ;;
    -h|--help) usage; exit 0 ;;
    *) cannot_observe "unrecognized argument: $1" ;;
  esac
done

for pair in "repo:$REPO" "validated-base:$VALIDATED_BASE" \
  "validated-head:$VALIDATED_HEAD" "candidate-head:$CANDIDATE_HEAD"; do
  [ -n "${pair#*:}" ] || cannot_observe "missing required --${pair%%:*}"
done

[ -d "$REPO" ] || cannot_observe "repository directory is unavailable: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || cannot_observe "not a git repository: $REPO"

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

# Content lines a diff introduced (+) or withdrew (-), taken only from inside
# hunks so a payload line beginning with '+' or '-' is never read as a header.
# Blank and whitespace-only lines carry no content and are dropped: requiring
# them would add noise without ever proving anything was preserved.
sides_from_diff() {  # <diff-file> <added-out> <removed-out>
  # Truncate first: these are reused once per path, and a stale side file would
  # carry a previous path's content into this one's comparison.
  : > "$2"
  : > "$3"
  awk -v added="$2" -v removed="$3" '
    /^@@/ { inhunk = 1; next }
    !inhunk { next }
    /^\+/ { line = substr($0, 2); if (line ~ /[^ \t]/) print line > added; next }
    /^-/  { line = substr($0, 2); if (line ~ /[^ \t]/) print line > removed; next }
  ' "$1"
}

DROPS="$WORK/drops"
UNCERTAIN="$WORK/uncertain"
: > "$DROPS"
: > "$UNCERTAIN"

blob_exists() {  # <commit> <path>
  git -C "$REPO" cat-file -e "$1:$2" 2>/dev/null
}

while IFS= read -r -d '' path; do
  [ -n "$path" ] || continue

  if ! git -C "$REPO" diff --no-renames --no-ext-diff -U0 "$VB" "$VH" -- "$path" > "$WORK/d" 2>/dev/null; then
    printf '%s\tthe validated change to this path could not be read\n' "$path" >> "$UNCERTAIN"
    continue
  fi

  vh_has=no; ch_has=no
  blob_exists "$VH" "$path" && vh_has=yes
  blob_exists "$CH" "$path" && ch_has=yes

  # A binary path cannot be compared line by line. Identical blobs are still a
  # sound observation; anything else is reported rather than assumed carried.
  if grep -q '^Binary files ' "$WORK/d" 2>/dev/null; then
    if [ "$vh_has" = yes ] && [ "$ch_has" = yes ] \
      && [ "$(git -C "$REPO" rev-parse "$VH:$path" 2>/dev/null)" = "$(git -C "$REPO" rev-parse "$CH:$path" 2>/dev/null)" ]; then
      continue
    fi
    printf '%s\tbinary path changed by the validated change cannot be compared line by line\n' "$path" >> "$UNCERTAIN"
    continue
  fi

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

  sides_from_diff "$WORK/d" "$WORK/added" "$WORK/removed"

  if ! git -C "$REPO" show "$CH:$path" > "$WORK/cand" 2>/dev/null; then
    printf '%s\tthe candidate copy of this path could not be read\n' "$path" >> "$UNCERTAIN"
    continue
  fi

  # Additions: presence in the candidate's copy, not position, so trunk
  # movement and re-indentation do not read as loss.
  if [ -s "$WORK/added" ]; then
    LC_ALL=C sort -u "$WORK/added" > "$WORK/added.s"
    LC_ALL=C sort -u "$WORK/cand" > "$WORK/cand.s"
    LC_ALL=C comm -23 "$WORK/added.s" "$WORK/cand.s" > "$WORK/missing"
    if [ -s "$WORK/missing" ]; then
      printf 'dropped-content\t%s\t%s line(s) added by the validated change are absent from the candidate\n' \
        "$path" "$(wc -l < "$WORK/missing" | tr -d '[:space:]')" >> "$DROPS"
      continue
    fi
  fi

  # Removals: a withdrawn line may legitimately still occur elsewhere in the
  # file, so only MORE copies than the validated head kept prove the removal
  # was undone.
  if [ -s "$WORK/removed" ]; then
    if ! git -C "$REPO" show "$VH:$path" > "$WORK/val" 2>/dev/null; then
      printf '%s\tthe validated copy of this path could not be read\n' "$path" >> "$UNCERTAIN"
      continue
    fi
    LC_ALL=C sort -u "$WORK/removed" > "$WORK/removed.s"
    # A sentinel first line guarantees every file trips FNR==1, so an empty
    # blob cannot silently merge two of the three inputs together.
    { printf '\001fm-sentinel\n'; cat "$WORK/removed.s"; } > "$WORK/p1"
    { printf '\001fm-sentinel\n'; cat "$WORK/val"; } > "$WORK/p2"
    { printf '\001fm-sentinel\n'; cat "$WORK/cand"; } > "$WORK/p3"
    awk '
      FNR == 1 { part++ }
      part == 1 { need[$0] = 1; next }
      part == 2 { if ($0 in need) vh[$0]++; next }
      part == 3 { if ($0 in need) ch[$0]++; next }
      END { n = 0; for (l in need) if (ch[l] > vh[l]) n++; print n }
    ' "$WORK/p1" "$WORK/p2" "$WORK/p3" > "$WORK/back" 2>/dev/null \
      || { printf '%s\tthe removal comparison could not be completed\n' "$path" >> "$UNCERTAIN"; continue; }
    back=$(tr -d '[:space:]' < "$WORK/back")
    case "$back" in
      ''|*[!0-9]*) printf '%s\tthe removal comparison produced no readable result\n' "$path" >> "$UNCERTAIN"; continue ;;
    esac
    if [ "$back" -gt 0 ]; then
      printf 'resurrected-content\t%s\t%s line(s) removed by the validated change reappear in the candidate\n' \
        "$path" "$back" >> "$DROPS"
      continue
    fi
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
