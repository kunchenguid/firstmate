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
# ONLY FROM THE REPOSITORY THE REQUEST NAMES
# A request number is unique only within one repository, and every forge
# publishes the same head namespace for all of them, so a fork request number
# collides with an unrelated upstream one. A configured remote is therefore used
# only when its URL is proven to name the repository the request URL names, and
# the request URL's own host is always tried. A remote that names some other
# repository is refused rather than quietly used, because answering with the
# wrong request is worse than not answering: it is a confident verdict about
# code nobody asked about.
#
# WHERE THE CANDIDATE'S BASE COMES FROM
# The trunk the candidate sits on is read from the request, not from a local
# ref. By the time this check matters the trunk HAS moved, since otherwise no
# rebase would have been needed, so a local ref lands short of the commit the
# candidate actually sits on and the removal comparison would be measured
# against the wrong base. A base that cannot be read or fetched is
# CANNOT-OBSERVE. --candidate-base overrides it with a trunk ref for a run that
# has no request to ask, and --validated-base may then be omitted, since the
# validated head's own base is the same fork point measured off the same trunk.
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
#     each non-blank line as the VALIDATED HEAD's copy holds, so a dropped
#     hunk cannot be covered by copies that were already in the file. The one
#     relief is a copy the trunk itself removed, which a faithful replay onto
#     that trunk could not have produced either, so with a candidate base the
#     requirement is the lesser of what the validated head holds and what a
#     replay onto that base would produce. Only counts are compared, never
#     positions, so trunk movement and hunk drift do not register as loss and
#     content the trunk supplied independently still counts as carried. Lines
#     match byte for byte INCLUDING leading whitespace, so a re-indented line
#     does read as loss;
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
#   fm-rebase-equivalence.sh --repo <dir> --validated-head <ref> \
#     --candidate-pr <url> [--candidate-remote <name-or-url>]
#   fm-rebase-equivalence.sh --repo <dir> \
#     --validated-base <ref> --validated-head <ref> \
#     --candidate-head <ref> [--candidate-base <ref>]
#
# --candidate-base takes a trunk ref rather than an exact commit: each head's
# own base is derived from it with `git merge-base`, so naming the trunk branch
# still works after it has moved on. Every fetch runs non-interactively, so a
# remote that wants credentials refuses instead of blocking an unattended
# worker on a prompt with no verdict line.
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
  fm-rebase-equivalence.sh --repo <dir> --validated-head <ref> \
    --candidate-pr <url> [--candidate-remote <name-or-url>]
  fm-rebase-equivalence.sh --repo <dir> \
    --validated-base <ref> --validated-head <ref> \
    --candidate-head <ref> [--candidate-base <ref>]

--candidate-pr fetches the request's head and its base branch from the forge,
which is where a worker can reach a head the pipeline built and pushed from its
own repository. Both are fetched only from the repository the request URL
names: a configured remote is used when its URL is proven to be that same
repository and refused when it is not, because a request number collides across
repositories. With the base read from the request, --validated-base may be
omitted and is measured off that same trunk.
--candidate-remote names a remote or URL to prefer for those fetches.
--candidate-base names the trunk ref for a run with no request to ask, such as
a comparison of two local heads.

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

for pair in "repo:$REPO" "validated-head:$VALIDATED_HEAD"; do
  [ -n "${pair#*:}" ] || cannot_observe "missing required --${pair%%:*}"
done
if [ -z "$VALIDATED_BASE" ] && [ -z "$CANDIDATE_PR" ]; then
  cannot_observe "missing required --validated-base"
fi
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

# Every fetch is non-interactive. An unattended worker that blocks on a
# credential prompt produces no verdict line at all, which is the one outcome
# this script's contract cannot tell apart from a crash, so a remote that wants
# credentials must fail onto CANNOT-OBSERVE instead.
git_fetch() {  # <source> <refspec>
  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=true \
  SSH_ASKPASS=true \
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -oBatchMode=yes}" \
    git -C "$REPO" fetch --quiet "$1" "$2" >/dev/null 2>&1
}

# Reduce a remote URL to <host>/<path> so two spellings of one repository
# compare equal and two different repositories never do. A local path carries
# no repository identity and is reported as having none.
repo_identity() {  # <url>
  local u=${1-}
  case "$u" in
    *://*) u=${u#*://} ;;
    *@*:*) u=${u#*@}; u=${u/:/\/} ;;
    *) return 1 ;;
  esac
  u=${u#*@}
  u=${u%/}
  u=${u%.git}
  case "$u" in
    */*) printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]' ;;
    *) return 1 ;;
  esac
}

# Fetch the candidate head from the forge. The head the pipeline pushed exists
# nowhere in the worker's clone, so a check that could only name a local commit
# would report CANNOT-OBSERVE on every run and gate nothing.
CANDIDATE_BASE_REF=
if [ -n "$CANDIDATE_PR" ]; then
  PR_NUMBER=
  PR_URL_SOURCE=
  PR_PROVIDER=
  PR_NAMESPACES=()
  case "$CANDIDATE_PR" in
    *://*)
      fm_pr_url_parse "$CANDIDATE_PR" \
        || cannot_observe "--candidate-pr is not a recognized pull or merge request URL: $CANDIDATE_PR"
      PR_NUMBER=$FM_PR_NUMBER
      PR_PROVIDER=$FM_PR_PROVIDER
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
      # A bare number names no repository, so it can only mean "this number on
      # that remote" and both head namespaces are tried.
      PR_NAMESPACES=(refs/pull refs/merge-requests)
      ;;
    *) cannot_observe "--candidate-pr must be a request URL or number: $CANDIDATE_PR" ;;
  esac

  # A request number is only unique within one repository, and every forge
  # publishes the same head namespace for all of them. A remote that is not the
  # repository the URL names would therefore answer with a DIFFERENT request
  # that happens to share the number, so the comparison would be confidently
  # wrong rather than merely unavailable. Only a source proven to be that
  # repository is used.
  CANDIDATE_SOURCES=()
  if [ -n "$PR_URL_SOURCE" ]; then
    PR_IDENTITY=$(repo_identity "$PR_URL_SOURCE") \
      || cannot_observe "cannot read a repository identity from the request URL: $CANDIDATE_PR"
    if [ -n "$CANDIDATE_REMOTE" ]; then
      REMOTE_URL=$(git -C "$REPO" remote get-url "$CANDIDATE_REMOTE" 2>/dev/null || printf '%s' "$CANDIDATE_REMOTE")
      REMOTE_IDENTITY=$(repo_identity "$REMOTE_URL" || true)
      if [ -n "$REMOTE_IDENTITY" ] && [ "$REMOTE_IDENTITY" = "$PR_IDENTITY" ]; then
        CANDIDATE_SOURCES+=("$CANDIDATE_REMOTE")
      else
        cannot_observe "--candidate-remote $CANDIDATE_REMOTE names ${REMOTE_IDENTITY:-no repository}, not $PR_IDENTITY which the request URL names"
      fi
    else
      ORIGIN_URL=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
      ORIGIN_IDENTITY=$(repo_identity "$ORIGIN_URL" || true)
      if [ -n "$ORIGIN_IDENTITY" ] && [ "$ORIGIN_IDENTITY" = "$PR_IDENTITY" ]; then
        CANDIDATE_SOURCES+=(origin)
      fi
    fi
    CANDIDATE_SOURCES+=("$PR_URL_SOURCE")
  else
    CANDIDATE_SOURCES+=("${CANDIDATE_REMOTE:-origin}")
  fi

  CANDIDATE_REF="refs/fm-rebase-equivalence/candidate/$PR_NUMBER"
  fetched=no
  for from in "${CANDIDATE_SOURCES[@]}"; do
    [ -n "$from" ] || continue
    for namespace in "${PR_NAMESPACES[@]}"; do
      if git_fetch "$from" "+$namespace/$PR_NUMBER/head:$CANDIDATE_REF"; then
        fetched=yes
        break
      fi
    done
    [ "$fetched" = no ] || break
  done
  [ "$fetched" = yes ] \
    || cannot_observe "cannot fetch the candidate head for request $PR_NUMBER from ${CANDIDATE_SOURCES[*]}"
  CANDIDATE_HEAD=$CANDIDATE_REF

  # The candidate's own base must come from the request itself. A local trunk
  # ref is whatever the clone last fetched, and by the time this check matters
  # the trunk HAS moved - otherwise no rebase would have been needed - so a
  # local ref lands short of the commit the candidate actually sits on.
  if [ -z "$CANDIDATE_BASE" ]; then
    [ "$PR_PROVIDER" = github ] \
      || cannot_observe "cannot read the base branch of request $PR_NUMBER from the forge; a GitHub request URL supplies it, otherwise name the trunk with --candidate-base"
    command -v gh >/dev/null 2>&1 \
      || cannot_observe "cannot read the base branch of $CANDIDATE_PR without gh; name the trunk with --candidate-base"
    BASE_NAME=$(GH_PROMPT_DISABLED=1 gh pr view "$CANDIDATE_PR" --json baseRefName -q .baseRefName 2>/dev/null || true)
    [ -n "$BASE_NAME" ] \
      || cannot_observe "cannot read the base branch of $CANDIDATE_PR from the forge"
    case "$BASE_NAME" in
      -*|*..*|*[!A-Za-z0-9._/-]*) cannot_observe "the forge reported an unusable base branch for $CANDIDATE_PR" ;;
    esac
    CANDIDATE_BASE_REF="refs/fm-rebase-equivalence/base/$PR_NUMBER"
    base_fetched=no
    for from in "${CANDIDATE_SOURCES[@]}"; do
      [ -n "$from" ] || continue
      if git_fetch "$from" "+refs/heads/$BASE_NAME:$CANDIDATE_BASE_REF"; then
        base_fetched=yes
        break
      fi
    done
    [ "$base_fetched" = yes ] \
      || cannot_observe "cannot fetch the base branch $BASE_NAME of request $PR_NUMBER"
    CANDIDATE_BASE=$CANDIDATE_BASE_REF
  fi
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

VH=$(resolve "$VALIDATED_HEAD") \
  || cannot_observe "cannot resolve --validated-head: $VALIDATED_HEAD"
CH=$(resolve "$CANDIDATE_HEAD") \
  || cannot_observe "cannot resolve --candidate-head: $CANDIDATE_HEAD"

# Both bases are fork points off the same trunk ref, found with merge-base, so
# a trunk that has moved past the commit either head sits on still names them
# exactly. That is what makes a trunk ref, rather than an exact commit, the
# right thing to hand this check.
CB=
CB_TRUNK=
if [ -n "$CANDIDATE_BASE" ]; then
  CB_TRUNK=$(resolve "$CANDIDATE_BASE") \
    || cannot_observe "cannot resolve --candidate-base: $CANDIDATE_BASE"
  CB=$(git -C "$REPO" merge-base "$CB_TRUNK" "$CH" 2>/dev/null) \
    || cannot_observe "cannot find the candidate's own base under $CANDIDATE_BASE"
  [ -n "$CB" ] || cannot_observe "cannot find the candidate's own base under $CANDIDATE_BASE"
fi

if [ -n "$VALIDATED_BASE" ]; then
  VB=$(resolve "$VALIDATED_BASE") \
    || cannot_observe "cannot resolve --validated-base: $VALIDATED_BASE"
else
  [ -n "$CB_TRUNK" ] || cannot_observe "missing required --validated-base"
  VB=$(git -C "$REPO" merge-base "$CB_TRUNK" "$VH" 2>/dev/null) \
    || cannot_observe "cannot find the validated head's own base under the request's trunk"
  [ -n "$VB" ] || cannot_observe "cannot find the validated head's own base under the request's trunk"
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
          # The candidate must hold every copy the validated head holds, so a
          # dropped hunk cannot be covered by copies that were already in the
          # file. The only relief is a copy the TRUNK itself removed, which a
          # faithful replay onto that trunk could not have produced either.
          need = vh[line]
          if (havebase == "1") {
            replay = cb[line] + d
            if (replay < need) need = replay
          }
          if (ch[line] < need) missing += need - ch[line]
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
