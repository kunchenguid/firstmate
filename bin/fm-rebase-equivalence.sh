#!/usr/bin/env bash
# Refuse a rebase that silently changes the content a pipeline already validated.
#
# The no-mistakes pipeline rebases a branch onto its target immediately before
# pushing it. When that rebase drops content, the opened PR misrepresents the
# code the pipeline actually judged, and nothing in the run reports it. This
# script is the mechanical form of the by-hand comparison that caught two such
# rebases; see docs/verification/rebase-equivalence.md for both reproductions.
#
# It is a firstmate-invoked DIAGNOSTIC: it reports and never gates. Nothing in
# the delivery path calls it, an automatic gate on it was built here and
# withdrawn on measured evidence, and the defect it detects therefore remains
# open; docs/verification/rebase-equivalence.md owns that record and
# bin/fm-pr-check.sh owns why the gate must not be reintroduced there.
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
# WHERE THE VALIDATED HEAD COMES FROM
# The validated side comes from the pipeline too, never from the worker's own
# branch. A run commits its own fixes onto its copy of the branch, so the
# worker's head holds OLDER content, and a fix that REWRITES a line the branch
# added - foo(a) becoming foo(a, b) - would read as that line being dropped.
# --validated-head must therefore be the full commit id the run record names,
# and --validated-remote is only HOW that id is obtained: it names the
# pipeline's repository, which every initialized clone carries as an ordinary
# local-path remote, and such a remote answers a bare object id even once the
# branch ref has moved off it.
#
# What that pair establishes is exactly this and no more: the caller named a
# full object id, and that id resolves here. It is not provenance. A fetch of an
# object id succeeds whenever the object is already present locally, even when
# the remote does not hold it at all, so the remote is never evidence that the
# head came from the pipeline. The guarantee comes from the id itself: an object
# id IS the content, so it names the run record's commit or nothing, which is
# why only a full id is accepted and a symbolic name - which would resolve in
# this clone and hand back the local head - is refused. A validated head that
# cannot be named or obtained is CANNOT-OBSERVE: there is deliberately no
# fallback to a local ref, because quietly comparing the worker's own head is
# the defect this flag exists to remove.
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
# BOTH BASE FLAGS MEAN THE SAME THING
# --validated-base and --candidate-base both take a TRUNK ref, and each head's
# own base is that trunk narrowed to the head with `git merge-base`. Handing the
# same trunk to both is therefore correct rather than a trap: an exact fork
# point narrows to itself, so a caller who already knows the fork point loses
# nothing, while a caller who names a trunk that has since moved is not told
# that every trunk-only line is content the validated change removed.
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
#     the rebase rather than to the trunk;
#   - a FILE MODE the validated change set must still be set. A mode is content
#     too: a script that lands non-executable is broken in exactly the way a
#     dropped hunk is, and a mode change emits `old mode`/`new mode` lines with
#     no `@@` hunk at all, so the line comparison alone records it as carried. A
#     mode the validated change did not touch is left to the trunk, so a chmod
#     the trunk made on its own is never read as loss.
#
# Verdicts are three-valued and only PASS is a pass:
#   0  PASS            every validated change is carried by the candidate
#   3  DROPPED         named paths lost validated content, with the direction
#   2  CANNOT-OBSERVE  an input, a git call, or a comparison could not be made
# An unresolvable ref, an unreachable candidate, a git failure, a binary path
# that changed, and an empty validated contribution are all CANNOT-OBSERVE,
# never a silent pass. The verdict line is always printed, so a caller that
# sees none knows the check did not run.
# A run killed by a signal is that second case: it prints no verdict line and
# exits 128 plus the signal number, deliberately outside the verdict vocabulary.
# A cancelled comparison is not an observation, and a signal handler that only
# cleaned up would return to the next statement with its result files already
# deleted, so the emptiness checks below would both read false and the run would
# print a confident PASS it never earned.
#
# Usage:
#   fm-rebase-equivalence.sh --repo <dir> --validated-head <commit> \
#     --validated-remote <name-or-url> \
#     --candidate-pr <url> [--candidate-remote <name-or-url>]
#   fm-rebase-equivalence.sh --repo <dir> --validated-head <ref> \
#     --candidate-head <ref> [--validated-base <ref>] [--candidate-base <ref>]
#
# Either --validated-base or --candidate-base must be given in the local form,
# since a contribution cannot be measured without a trunk to measure it from.
# Every fetch runs non-interactively, so a remote that wants credentials refuses
# instead of blocking an unattended worker on a prompt with no verdict line.
set -eu

VERDICT_PASS=0
VERDICT_CANNOT=2
VERDICT_DROPPED=3

# Released from a trap armed before the fetch that creates it, rather than at
# one call site: the ref exists from the fetch onward, and every refusal - and
# every signal - between there and the end of the run would otherwise exit with
# it still present, accumulating one ref per validated commit in what is a
# SHARED object store for a gate worktree and pinning its objects.
#
# The candidate and base refs are deliberately NOT released, and the reason the
# validated ref is does not apply to them: they are keyed by REQUEST NUMBER, so
# a repeat run force-updates the same pair rather than adding one, while the
# validated ref is keyed by object id and would add one per validated commit
# forever. Their persistence is also what shows the fetch ran at all, which
# docs/verification/rebase-equivalence.md cites as evidence.
VALIDATED_REF=
WORK=
release_validated_ref() {
  [ -n "$VALIDATED_REF" ] || return 0
  git -C "$REPO" update-ref -d "$VALIDATED_REF" 2>/dev/null || true
  VALIDATED_REF=
}

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  release_validated_ref
  [ -n "$WORK" ] || return 0
  rm -rf "$WORK"
  WORK=
}

# Armed before anything this run can create, so no window exists between a
# resource appearing and its release being in force. Both resources are guarded
# on emptiness, so firing before either exists is a no-op.
#
# A signal must TERMINATE rather than fall through, so INT and TERM exit and let
# the EXIT trap do the cleanup. A handler that only cleaned up would return to
# the next statement with the working directory already deleted: the per-path
# loop's result files would be gone, both emptiness tests would read false, and
# a cancelled run would print PASS and exit 0. Exiting on 128 plus the signal
# keeps that outcome out of the verdict vocabulary entirely.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cannot_observe() {  # <reason>
  release_validated_ref
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
VALIDATED_REMOTE=
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
  fm-rebase-equivalence.sh --repo <dir> --validated-head <commit> \
    --validated-remote <name-or-url> \
    --candidate-pr <url> [--candidate-remote <name-or-url>]
  fm-rebase-equivalence.sh --repo <dir> --validated-head <ref> \
    --candidate-head <ref> [--validated-base <ref>] [--candidate-base <ref>]

--candidate-pr fetches the request's head and its base branch from the forge,
which is where a worker can reach a head the pipeline built and pushed from its
own repository. Both are fetched only from the repository the request URL
names: a configured remote is used when its URL is proven to be that same
repository and refused when it is not, because a request number collides across
repositories. With the base read from the request, --validated-base may be
omitted and is measured off that same trunk.
--candidate-remote names a remote or URL to prefer for those fetches.
--validated-remote is how the validated head is OBTAINED, and is not evidence
of where it came from. --validated-head must then be the full commit id the run
record names, and that id is fetched from the named repository. What the pair
establishes is exactly that the caller named a full object id and that the id
resolves here, since an object id is the content and so names that commit or
nothing. It never establishes that the head came from the pipeline, because a
fetch by object id succeeds whenever the object is already present locally. A
symbolic name is refused and a head that cannot be obtained is could-not-observe
rather than a fallback to a local ref, so this clone's own branch - older
content, since a run commits its fixes elsewhere - cannot stand in for it.
--candidate-base names the trunk ref for a run with no request to ask, such as
a comparison of two local heads.
Both base flags take a TRUNK ref and narrow it to each head's own fork point
with git merge-base, so the same trunk may be given to both. In the local form
one of them is required.

Verdicts (only PASS is a pass):
  0  PASS            every validated change is carried by the candidate
  3  DROPPED         named paths lost validated content, with the direction
  2  CANNOT-OBSERVE  an input, a git call, or a comparison could not be made

See this script's header comment for the predicate and why it is neither a
tip-to-tip diff nor a merge-result comparison.
EOF
}

# An explicitly empty value is refused rather than stored. A wrapper that
# builds `--validated-remote "$REMOTE"` with REMOTE unset would otherwise pass
# the presence guard below and silently resolve the validated head as an
# ordinary local ref, which is the exact fallback this flag exists to remove.
# The check is inline because cannot_observe inside a command substitution
# would have its verdict captured into the variable instead of printed.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|--validated-base|--validated-head|--validated-remote|\
    --candidate-head|--candidate-pr|--candidate-remote|--candidate-base)
      [ "$#" -ge 2 ] || cannot_observe "$1 needs a value"
      [ -n "$2" ] || cannot_observe "$1 was given an empty value, which is never a valid input"
      case "$1" in
        --repo) REPO=$2 ;;
        --validated-base) VALIDATED_BASE=$2 ;;
        --validated-head) VALIDATED_HEAD=$2 ;;
        --validated-remote) VALIDATED_REMOTE=$2 ;;
        --candidate-head) CANDIDATE_HEAD=$2 ;;
        --candidate-pr) CANDIDATE_PR=$2 ;;
        --candidate-remote) CANDIDATE_REMOTE=$2 ;;
        --candidate-base) CANDIDATE_BASE=$2 ;;
      esac
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) cannot_observe "unrecognized argument: $1" ;;
  esac
done

for pair in "repo:$REPO" "validated-head:$VALIDATED_HEAD"; do
  [ -n "${pair#*:}" ] || cannot_observe "missing required --${pair%%:*}"
done
if [ -z "$VALIDATED_BASE" ] && [ -z "$CANDIDATE_PR" ] && [ -z "$CANDIDATE_BASE" ]; then
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
# A candidate taken from the forge must be compared against a validated head
# taken from the pipeline, never against a local ref. The caller that cannot
# name the run's own head is the caller whose head is the OLDER content,
# because a run's fix commits stay in its gate repository, so a local ref here
# reports the pipeline's own accepted fixes as content the push dropped.
if [ -n "$CANDIDATE_PR" ] && [ -z "$VALIDATED_REMOTE" ]; then
  cannot_observe "--candidate-pr needs --validated-remote so the validated head comes from the pipeline rather than a local ref"
fi

[ -d "$REPO" ] || cannot_observe "repository directory is unavailable: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || cannot_observe "not a git repository: $REPO"

# Every fetch is non-interactive. An unattended worker that blocks on a
# credential prompt produces no verdict line at all, which is the one outcome
# this script's contract cannot tell apart from a crash, so a remote that wants
# credentials must fail onto CANNOT-OBSERVE instead. Batch mode is APPENDED to
# whatever ssh command the caller already exports rather than supplied only as a
# default: keeping a caller's value verbatim would drop the option and leave an
# ssh-form remote free to hang on a passphrase or a host-key prompt. A client
# that does not accept OpenSSH options - plink, tortoiseplink, a wrapper that
# rejects what it does not know - therefore fails here rather than being used
# verbatim. That is the deliberate direction: such a caller gets
# CANNOT-OBSERVE, where honouring the command could hang with no verdict at all.
git_fetch() {  # <source> <refspec>
  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=true \
  SSH_ASKPASS=true \
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -oBatchMode=yes" \
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

# Fetch the validated head from the pipeline's own repository. A run commits
# its own fixes onto its copy of the branch, so this clone's branch holds older
# content and resolving the validated side here would report a fix that
# REWROTE a validated line as that line being dropped. The caller names the
# exact commit from the run record, this fetches it by object id, and a fetch
# that cannot be made is CANNOT-OBSERVE with no fallback to a local ref.
if [ -n "$VALIDATED_REMOTE" ]; then
  # A symbolic name would resolve in this clone and hand back exactly the local
  # head this flag exists to stop trusting, so only a full object id is taken.
  # An object id is the content, so once that id resolves it names the run
  # record's commit and nothing else, whether the fetch carried it here or this
  # clone already held that exact object.
  case "$VALIDATED_HEAD" in
    *[!0-9a-fA-F]*)
      cannot_observe "--validated-remote needs --validated-head to be the full commit id the run record names, not $VALIDATED_HEAD" ;;
  esac
  [ "${#VALIDATED_HEAD}" -ge 40 ] \
    || cannot_observe "--validated-remote needs --validated-head to be the full commit id the run record names, not $VALIDATED_HEAD"
  # The release is already armed, so the name is recorded before the fetch that
  # writes it: the ref can exist the instant that fetch returns, and everything
  # slow in this run - the candidate fetch, the forge call, the base fetch -
  # happens after this point.
  VALIDATED_REF="refs/fm-rebase-equivalence/validated/$VALIDATED_HEAD"
  git_fetch "$VALIDATED_REMOTE" "+$VALIDATED_HEAD:$VALIDATED_REF" \
    || cannot_observe "cannot fetch the validated head $VALIDATED_HEAD from $VALIDATED_REMOTE"
  VALIDATED_HEAD=$VALIDATED_REF
fi

# Fetch the candidate head from the forge. The head the pipeline pushed exists
# nowhere in the worker's clone, so a check that could only name a local commit
# would report CANNOT-OBSERVE on every run and gate nothing.
CANDIDATE_BASE_REF=
if [ -n "$CANDIDATE_PR" ]; then
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
    *[!0-9]*) cannot_observe "--candidate-pr must be a request URL: $CANDIDATE_PR" ;;
    # An all-digit value is a well-formed request number and is still refused,
    # because it names no repository and so nothing can prove any source is the
    # one the request belongs to. Falling back to a configured remote is exactly
    # the collision the identity rule below exists to close: every forge
    # publishes the same head namespace for every repository, so the number
    # resolves against WHICHEVER repository that remote happens to be - here
    # origin fetches upstream while requests are opened on the fork. That
    # returned a confident DROPPED verdict over 12 paths of an unrelated
    # project's request. A verdict about code nobody asked about is worse than
    # no verdict, so the numeric form has no path onward at all.
    *) cannot_observe "--candidate-pr $CANDIDATE_PR is a bare number, which names no repository; pass the request URL so the source can be proven to be the repository it belongs to" ;;
  esac

  # A request number is only unique within one repository, and every forge
  # publishes the same head namespace for all of them. A remote that is not the
  # repository the URL names would therefore answer with a DIFFERENT request
  # that happens to share the number, so the comparison would be confidently
  # wrong rather than merely unavailable. Only a source proven to be that
  # repository is used.
  CANDIDATE_SOURCES=()
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

# A head compared against itself is not a comparison. Every path's counts match
# by construction, so the run would print PASS in a form indistinguishable from
# a real one - the "passes without looking" outcome this check exists to make
# impossible. It is refused here rather than reported, because the caller's
# idea of which commit is which is what went wrong.
[ "$VH" != "$CH" ] || cannot_observe \
  "the validated head and the candidate resolve to the same commit $VH, so nothing would be compared"

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

# The validated base is narrowed exactly like the candidate's, so both flags
# take one shape and the same trunk may be handed to both. Narrowing an exact
# fork point returns that fork point, so a caller who already knows it is
# unaffected; a caller who names a trunk that has since moved is spared having
# every trunk-only line read as content the validated change removed.
VB_TRUNK=
if [ -n "$VALIDATED_BASE" ]; then
  VB_TRUNK=$(resolve "$VALIDATED_BASE") \
    || cannot_observe "cannot resolve --validated-base: $VALIDATED_BASE"
  VB_NAME=$VALIDATED_BASE
else
  [ -n "$CB_TRUNK" ] || cannot_observe "missing required --validated-base"
  VB_TRUNK=$CB_TRUNK
  VB_NAME="the candidate's trunk"
fi
VB=$(git -C "$REPO" merge-base "$VB_TRUNK" "$VH" 2>/dev/null) \
  || cannot_observe "cannot find the validated head's own base under $VB_NAME"
[ -n "$VB" ] || cannot_observe "cannot find the validated head's own base under $VB_NAME"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-rebase-equiv.XXXXXX") \
  || cannot_observe "cannot create a working directory"

# The validated contribution's footprint. --no-renames keeps both sides
# measuring the same way, so a rename detected on one side only cannot read as
# a drop. --no-textconv joins --no-ext-diff because the copies counted below
# come from `git show <commit>:<path>`, which always emits the RAW blob: under a
# `diff=<driver>` gitattribute with a textconv, the harvested lines would be
# CONVERTED text and the two halves of the comparison would be different texts.
# Measured, that fails OPEN rather than loudly - a harvested line absent from
# the validated copy requires zero copies of itself, so a candidate that dropped
# the hunk outright reports PASS. That is the verdict-without-comparing outcome
# this check exists to make impossible, and --repo takes any directory, so the
# exposure is real wherever this diagnostic is pointed.
if ! git -C "$REPO" diff --no-renames --no-ext-diff --no-textconv -z --name-only "$VB" "$VH" > "$WORK/paths.z" 2>/dev/null; then
  cannot_observe "cannot read the validated contribution ($VB..$VH)"
fi
if [ ! -s "$WORK/paths.z" ]; then
  cannot_observe "validated contribution is empty ($VB..$VH); there is nothing to compare"
fi

DROPS="$WORK/drops"
UNCERTAIN="$WORK/uncertain"
: > "$DROPS"
: > "$UNCERTAIN"

# Presence is read from the TREE, not from the object store. `cat-file -e` on a
# gitlink fails, because a superproject does not hold the submodule's commit, so
# a submodule the validated change added or bumped would read as absent on both
# sides and be silently recorded as carried - a pass reached without comparing.
blob_exists() {  # <commit> <path>
  local entry
  entry=$(git -C "$REPO" ls-tree "$1" -- ":(literal)$2" 2>/dev/null) || return 1
  [ -n "$entry" ]
}

# The file mode a commit records for a path, empty when the path is absent
# there. Reports a git failure through its exit status so an unreadable tree is
# never mistaken for an absent path.
tree_mode() {  # <commit> <path>
  local entry
  entry=$(git -C "$REPO" ls-tree "$1" -- ":(literal)$2" 2>/dev/null) || return 1
  [ -n "$entry" ] || return 0
  printf '%s' "${entry%% *}"
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
  if ! git -C "$REPO" diff --no-renames --no-ext-diff --no-textconv -U0 "$VB" "$VH" -- ":(literal)$path" > "$WORK/d" 2>/dev/null; then
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

  # Both sides hold the path, so its mode can be judged. A mode is validated
  # content: an executable bit the change set and the rebase lost leaves a
  # script that cannot run, and a mode change emits `old mode`/`new mode` lines
  # with no `@@` hunk at all, so the line comparison alone records it as
  # carried. Only a mode the VALIDATED CHANGE set is required, so a chmod the
  # trunk made on its own is never read as loss.
  mode_drop=
  if ! vb_mode=$(tree_mode "$VB" "$path") \
    || ! vh_mode=$(tree_mode "$VH" "$path") \
    || ! ch_mode=$(tree_mode "$CH" "$path"); then
    printf '%s\tthe file mode of this path could not be read\n' "$path" >> "$UNCERTAIN"
    continue
  fi
  if [ -n "$vh_mode" ] && [ "$vh_mode" != "$vb_mode" ] && [ "$ch_mode" != "$vh_mode" ]; then
    mode_drop="the validated change set mode $vh_mode, the candidate has ${ch_mode:-none}"
  fi

  # A binary path cannot be compared line by line; identical blobs are still a
  # sound observation, anything else is reported rather than assumed carried.
  if grep -q '^Binary files ' "$WORK/d" 2>/dev/null; then
    vh_blob=$(git -C "$REPO" rev-parse "$VH:$path" 2>/dev/null || true)
    ch_blob=$(git -C "$REPO" rev-parse "$CH:$path" 2>/dev/null || true)
    if [ -n "$vh_blob" ] && [ "$vh_blob" = "$ch_blob" ]; then
      if [ -n "$mode_drop" ]; then
        printf 'dropped-mode\t%s\t%s\n' "$path" "$mode_drop" >> "$DROPS"
      fi
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
  if [ -n "$mode_drop" ]; then
    printf 'dropped-mode\t%s\t%s\n' "$path" "$mode_drop" >> "$DROPS"
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
