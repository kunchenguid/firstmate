#!/usr/bin/env bash
# fm-gate-ref-probe.sh - read-only check that a no-mistakes push of this copy's
# HEAD will be accepted by the gate repository, before the push is attempted.
#
# Usage: fm-gate-ref-probe.sh [<worktree>]   (default: the current directory)
#
# `no-mistakes axi sync --check` can report `custody_returned`, `relation: equal`
# and `next_action.code: run_pipeline` while the push still fails. Its relation
# compares this HEAD with the head its own run record preserved, and custody
# recovery stamps that record without moving the gate's `refs/heads/<branch>`.
# The pipeline push is judged against that gate ref, which a rebase after a
# crash leaves at the pre-rebase head. Once custody is stamped, a repeated
# `--recover --keep-local` is an accepted no-op, so the status offers nothing.
# This probe reads the one ref the push is judged against and names what it
# holds, so a worker learns of the stale ref before a run that cannot start.
#
# It only reads: it never fetches, writes or deletes a ref in the gate or in
# the copy, and it never asks the daemon anything. The gate's objects are
# exposed to the copy through GIT_ALTERNATE_OBJECT_DIRECTORIES for the duration
# of its own git reads, which writes nothing. It cannot repair the ref, and it
# deliberately offers no way to; the tool-owned gate ref is changed only by
# no-mistakes itself.
#
# Output is `key: value` lines on stdout. `gate_ref` is the verdict:
#   absent      the gate has no ref for this branch; the push creates it
#   in-sync     the gate ref equals HEAD, or HEAD descends from it
#   stale       diverged from HEAD and every commit only the gate ref carries
#               has a patch-equivalent commit in HEAD (the usual rebase);
#               merge commits cannot be patch-compared and are only counted
#   holds-work  the gate ref carries commits HEAD does not (it is ahead of
#               HEAD, or diverged with commits that are not patch-equivalent)
# `anchors` lists the refs/no-mistakes/* refs that already keep the gate ref's
# tip reachable, so a reader can see whether anything would be lost.
#
# Exit codes: 0 the push can be accepted (absent or in-sync); 10 stale;
# 11 holds-work; 2 the question could not be answered (no branch, no
# no-mistakes remote, unreadable gate, a failed history read).
set -u

wt=${1:-.}
fail() { printf 'error: %s\n' "$1" >&2; exit 2; }

git -C "$wt" rev-parse --git-dir >/dev/null 2>&1 || fail "$wt is not a git copy"
branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || fail "HEAD is detached; there is no branch to probe"
head=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{commit}') || fail "HEAD does not resolve to a commit"
gate=$(git -C "$wt" config --get remote.no-mistakes.url) || fail "this copy has no no-mistakes remote"
[ -d "$gate" ] || fail "the gate repository $gate is not a local directory"
gate=$(cd "$gate" && pwd -P) || fail "the gate repository $gate is unreadable"
git --git-dir="$gate" rev-parse --git-dir >/dev/null 2>&1 || fail "$gate is not a git repository"

printf 'branch: %s\nhead: %s\ngate: %s\n' "$branch" "$head" "$gate"

tip=$(git --git-dir="$gate" rev-parse --verify --quiet "refs/heads/$branch^{commit}") || tip=
if [ -z "$tip" ]; then
  printf 'gate_ref: absent\nverdict: the gate has no ref for %s, so a push creates it\n' "$branch"
  exit 0
fi
printf 'gate_tip: %s\n' "$tip"

# Gate objects are read through an alternate, so nothing is written to the copy.
gitwt() { GIT_ALTERNATE_OBJECT_DIRECTORIES="$gate/objects" git -C "$wt" "$@"; }

subject=$(gitwt log -1 --format=%s "$tip" 2>/dev/null) || subject=
[ -n "$subject" ] && printf 'gate_tip_subject: %s\n' "$subject"

anchors=$(git --git-dir="$gate" for-each-ref --contains "$tip" --format='%(refname)' refs/no-mistakes 2>/dev/null | paste -sd' ' -)
printf 'anchors: %s\n' "${anchors:-none}"

if [ "$tip" = "$head" ] || gitwt merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
  printf 'gate_ref: in-sync\nverdict: HEAD carries the gate ref, so the push is a fast-forward\n'
  exit 0
fi

if gitwt merge-base --is-ancestor "$head" "$tip" 2>/dev/null; then
  ahead=$(gitwt rev-list --count "$head..$tip" 2>/dev/null) || ahead='?'
  printf 'relation: gate-ahead\nunique_commits: %s\ngate_ref: holds-work\n' "$ahead"
  printf 'verdict: the gate ref is %s commit(s) ahead of HEAD, so the push is rejected and HEAD does not carry those commits; recover custody first and do not push\n' "$ahead"
  exit 11
fi

base=$(gitwt merge-base "$head" "$tip" 2>/dev/null) || base=
if [ -z "$base" ]; then
  printf 'relation: unrelated\ngate_ref: holds-work\nverdict: the gate ref shares no history with HEAD, so nothing can show it is safe to replace\n'
  exit 11
fi
printf 'relation: diverged\nmerge_base: %s\n' "$base"

# `git cherry` marks a commit `-` when the other side has a patch-equivalent one.
cherry=$(gitwt cherry "$head" "$tip" "$base" 2>/dev/null) || fail "could not patch-compare the gate ref with HEAD"
unique=$(printf '%s\n' "$cherry" | grep -c '^+')
total=$(gitwt rev-list --count "$base..$tip" 2>/dev/null) || fail "could not count the gate-only commits"
merges=$(gitwt rev-list --merges --count "$base..$tip" 2>/dev/null) || fail "could not count the gate-only merge commits"
printf 'gate_only_commits: %s\ngate_only_merges: %s\nunique_commits: %s\n' "$total" "$merges" "$unique"
if [ "$unique" = 0 ]; then
  printf 'gate_ref: stale\n'
  printf 'verdict: the gate ref is the pre-rebase form of work HEAD already carries (every non-merge gate-only commit has a patch-equivalent in HEAD), so a push is rejected non-fast-forward and nothing would be lost; only no-mistakes may move that ref\n'
  [ "$merges" = 0 ] || printf 'note: %s gate-only merge commit(s) are not patch-compared; check them before treating the ref as disposable\n' "$merges"
  exit 10
fi
printf 'gate_ref: holds-work\n'
printf 'verdict: the gate ref carries %s commit(s) with no patch-equivalent in HEAD, so a push is rejected and replacing the ref would lose them; recover custody or reconcile before running\n' "$unique"
exit 11
