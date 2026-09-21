#!/usr/bin/env bash
# fm-nm-stranded-gate.sh - recognize a no-mistakes gate ref stranded by a crash
# and print the safe fresh-branch remedy, or refuse when that would lose work.
#
# Usage: fm-nm-stranded-gate.sh [--remote <name>] [<worktree>]
#   <worktree>  the task worktree to check (default: the current directory)
#   --remote    the git remote naming the no-mistakes gate mirror
#               (default: no-mistakes)
#
# The symptom: after a daemon crash or a killed fix round, the gate mirror
# (the local bare repository the `no-mistakes` remote points at) still holds the
# branch's PRE-rebase tip while the worker sits on the rebased head, so every
# later `no-mistakes axi run` stops before its first step with
# "push to gate: ! [rejected] (non-fast-forward)", while `axi sync --check`
# reports the branch as settled and `axi sync --recover --keep-local` changes
# nothing. Forcing the shared mirror ref or touching the shared daemon is never
# the remedy; both serve every lane on the machine.
#
# The remedy this script checks: when every commit the stranded mirror ref holds
# is already in the current head (patch-equivalent, per
# `git rev-list --cherry-pick --left-only <stranded>...HEAD`), re-running on a
# FRESH branch name loses nothing, and the mirror accepts it as an ordinary new
# ref. Any left-only commit, merge commits included (they have no patch
# identity), is work the head lacks: the script refuses and the worker must stop
# and report blocked rather than abandon it. It also refuses while a PR is open
# with the stranded branch as its head, or when `gh pr list` cannot prove there
# is none: a fresh branch would open a second PR and silently orphan the first
# one's review and recorded pr= metadata.
#
# Strictly read-only. The mirror is read as an alternate object store for this
# process only (GIT_ALTERNATE_OBJECT_DIRECTORIES) and through `git --git-dir`
# ref reads; nothing is fetched, pushed, written, or moved in the mirror or the
# worktree, and the daemon is never contacted. The PR check only lists PRs; it
# never closes, supersedes, comments on, or otherwise changes one. It never
# creates the fresh branch; it prints the command for the worker to run.
#
# Output is key: value lines on stdout.
# Exit codes:
#   0  stranded, every stranded commit is in HEAD, and no PR is open for the
#      branch: `fresh_branch:` and `next:` name the safe remedy
#   1  stranded, and refused: the mirror ref holds commits HEAD lacks
#      (`unlanded:` lines list them), a PR is open for the branch (`open_pr:`
#      lines name it), or the open-PR query could not complete
#   2  usage error, or the worktree, branch, mirror, or objects could not be read
#   3  not stranded: the mirror has no ref for this branch, or HEAD already
#      contains the mirror ref (a push would fast-forward)
set -u

usage() {
  sed -n '4,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

REMOTE=no-mistakes
WT=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 2; }
      REMOTE=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) WT=$1; shift ;;
  esac
done

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

WT=$(cd "$WT" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) \
  || die "not a git worktree: $WT"
BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) \
  || die "HEAD is detached; check out the task branch first"
HEAD_SHA=$(git -C "$WT" rev-parse --verify --quiet 'HEAD^{commit}') \
  || die "HEAD does not resolve to a commit"

URL=$(git -C "$WT" remote get-url --push "$REMOTE" 2>/dev/null) \
  || die "no '$REMOTE' remote in $WT"
case "$URL" in
  file://*) URL=${URL#file://} ;;
esac
case "$URL" in
  /*) ;;
  *) die "'$REMOTE' remote is not a local mirror path: $URL" ;;
esac
MIRROR=$(cd "$URL" 2>/dev/null && pwd -P) || die "mirror is not readable: $URL"
[ -d "$MIRROR/objects" ] || die "mirror has no object store: $MIRROR"

# Every object read below sees the worktree's own objects plus the mirror's.
mgit() {
  GIT_ALTERNATE_OBJECT_DIRECTORIES="$MIRROR/objects" git -C "$WT" "$@"
}

printf 'branch: %s\n' "$BRANCH"
printf 'head: %s\n' "$HEAD_SHA"
printf 'mirror: %s\n' "$MIRROR"

STRANDED=$(git --git-dir="$MIRROR" rev-parse --verify --quiet "refs/heads/$BRANCH" 2>/dev/null) || {
  printf 'state: not-stranded\n'
  printf 'reason: the mirror has no ref for this branch\n'
  exit 3
}
printf 'mirror_ref: %s\n' "$STRANDED"
mgit cat-file -e "$STRANDED^{commit}" 2>/dev/null \
  || die "mirror ref $STRANDED is not a readable commit"

if mgit merge-base --is-ancestor "$STRANDED" "$HEAD_SHA" 2>/dev/null; then
  printf 'state: not-stranded\n'
  printf 'reason: HEAD already contains the mirror ref, so a push fast-forwards\n'
  exit 3
fi

UNLANDED=$(mgit rev-list --cherry-pick --left-only "$STRANDED...$HEAD_SHA" 2>/dev/null) \
  || die "could not compare the mirror ref with HEAD"

if [ -n "$UNLANDED" ]; then
  printf 'state: refused\n'
  printf 'reason: the mirror ref holds commits HEAD lacks; a fresh branch would abandon them\n'
  printf '%s\n' "$UNLANDED" | while IFS= read -r sha; do
    printf 'unlanded: %s\n' "$(mgit log -1 --format='%H %s' "$sha")"
  done
  printf 'next: stop and report blocked with these commits; do not force the mirror or touch the daemon\n'
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  OPEN_PRS=
  PR_QUERY_FAILED="gh is not installed"
elif OPEN_PRS=$(cd "$WT" && gh pr list --head "$BRANCH" --state open --json url -q '.[].url' 2>/dev/null); then
  PR_QUERY_FAILED=
else
  PR_QUERY_FAILED="gh pr list failed"
fi
if [ -n "$PR_QUERY_FAILED" ]; then
  printf 'state: refused\n'
  printf 'reason: could not prove no PR is open for %s (%s); a fresh branch could orphan it\n' "$BRANCH" "$PR_QUERY_FAILED"
  printf 'next: stop and report blocked with this output; do not force the mirror or touch the daemon\n'
  exit 1
fi
if [ -n "$OPEN_PRS" ]; then
  printf 'state: refused\n'
  printf 'reason: a PR is open for %s; a fresh branch would open a second PR and orphan it\n' "$BRANCH"
  printf '%s\n' "$OPEN_PRS" | while IFS= read -r url; do
    printf 'open_pr: %s\n' "$url"
  done
  printf 'next: stop and report blocked naming this PR; do not force the mirror or touch the daemon\n'
  exit 1
fi

# First free <base>-rN name, absent both locally and in the mirror.
ref_taken() {
  git -C "$WT" show-ref --verify --quiet "refs/heads/$1" \
    || git --git-dir="$MIRROR" show-ref --verify --quiet "refs/heads/$1"
}
base=$BRANCH
n=2
if [[ "$BRANCH" =~ ^(.+)-r([0-9]+)$ ]]; then
  base=${BASH_REMATCH[1]}
  n=$((10#${BASH_REMATCH[2]} + 1))
fi
while ref_taken "$base-r$n"; do
  n=$((n + 1))
done
FRESH="$base-r$n"

printf 'state: stranded\n'
printf 'reason: every mirror-ref commit is already in HEAD; the mirror refuses only the rewritten history\n'
printf 'fresh_branch: %s\n' "$FRESH"
printf 'next: git switch -c %s\n' "$FRESH"
printf 'next: re-run the same no-mistakes axi run invocation from that branch\n'
exit 0
