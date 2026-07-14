#!/usr/bin/env bash
# FM_BASE_* variables here are OUT-PARAMS read by the scripts that source this lib, never
# by the lib itself, so SC2034's "appears unused" is structurally wrong about them.
# shellcheck disable=SC2034
#
# fm-base-lib.sh - the shared facts about a task's declared base branch.
#
# A ship task may declare a non-default intended base with fm-spawn.sh --base, which
# records base=<branch> into state/<id>.meta - the single source of truth for a task's
# base. Four scripts then ask the same questions about it, so the questions live here
# once and every consumer decides on the answer this file gives:
#
#   fm_base_valid_branch_name  is the recorded value a git branch name at all?
#   fm_base_liveness           IS THAT BASE STILL A LIVE FEATURE BASE?
#   fm_base_head_rooted        is a given head rooted in that base's own history?
#   fm_base_brief_marker       the line a based brief carries, so a spawn can check it
#   fm_base_liveness_brief_block  the crewmate's form of the liveness question
#
# LIVENESS IS THE ONE QUESTION, AND THIS FILE OWNS IT. A declared base is LIVE if and
# only if it still EXISTS on origin AND still carries at least one commit the default
# branch does not already have. Existing is not liveness: GitHub's delete-on-merge is
# off by default, so a base that merged and kept its branch is an ordinary end-state -
# it has no unmerged history left for a wrong-based merge to drag onto the default
# branch (the whole hazard), and rootedness is not even observable against it, because
# every fork point with such a base is reachable from the default branch and a
# perfectly stacked head reads UNROOTED. A consumer that asks the weaker
# does-the-branch-exist question refuses safe work and says something false about it.
#
# fm_base_probe_origin and fm_base_has_own_commits are the two primitives fm_base_liveness
# composes. Consumers call fm_base_liveness, not the primitives: a consumer that assembles
# its own partial version of the question is how four scripts came to give four different
# answers about one base.
#
# bin/fm-pr-check.sh's header owns what the guard DOES with these answers; this file only
# answers. It deliberately says nothing about a base's END OF LIFE - whether it merged,
# whether a squash merge put its content in the default branch, whether it was abandoned.
# Those cannot be settled from git without guessing, and every consumer hands them to a
# human instead (fm-pr-check.sh's header says how). Liveness is a different question and is
# decidable: it is plain ancestry, not a merge detector, so a SQUASH-merged base still reads
# live and still gets the full guard.
#
# NOTHING HERE INFERS ANYTHING FROM A COMMAND'S EXIT STATUS. `git ls-remote --exit-code`
# separates the cases at the source: 0 = the ref matched, 2 = no ref matched, anything
# else = the probe itself failed. A base we could not ask about is not a base that is
# gone, and an auth or network failure must never be read as either.
#
# Sourced by fm-spawn.sh, fm-brief.sh, fm-pr-check.sh and fm-review-diff.sh. No side
# effects on source. set -u / set -e safe.

# Both enums travel as RETURN CODES and pass through the same scope in fm-pr-check.sh, so
# they are given non-overlapping values: no outcome of one can ever be mistaken for an
# outcome of the other. Callers compare against these names, never bare numbers.

# Probe outcomes (fm_base_probe_origin).
FM_BASE_PRESENT=0
FM_BASE_PROBE_FAILED=1
FM_BASE_ABSENT=2

# Rootedness outcomes (fm_base_head_rooted).
FM_BASE_HEAD_ROOTED=3
FM_BASE_HEAD_UNROOTED=4
FM_BASE_HEAD_UNRELATED=5

# Own-commit outcomes (fm_base_has_own_commits).
FM_BASE_HAS_OWN_COMMITS=6
FM_BASE_NO_OWN_COMMITS=7
FM_BASE_OWN_COMMITS_UNKNOWN=8

# Liveness outcomes (fm_base_liveness) - the answer every consumer decides on.
FM_BASE_LIVE=9
FM_BASE_ABSORBED=10
FM_BASE_GONE=11
FM_BASE_LIVENESS_UNKNOWN=12

# fm_base_valid_branch_name: 0 (true) if <name> is a non-empty, whitespace-free, git-legal
# branch name that does not begin with '-'. The leading dash matters beyond tidiness: the
# value reaches git as a refspec, where git would read it as an option, and
# `--upload-pack=<cmd>` is an arbitrary-command vector. fm-spawn.sh validates on the way
# in; the consumers validate again on the way out, because meta is a plain text file a
# human can edit.
fm_base_valid_branch_name() {  # <name>
  local name=${1-}
  [ -n "$name" ] || return 1
  case "$name" in
    -*) return 1 ;;
    *[[:space:]]*) return 1 ;;
  esac
  git check-ref-format --branch "$name" >/dev/null 2>&1 || return 1
  return 0
}

# fm_base_probe_origin: ask origin whether <branch> exists, from within <git-dir>.
# A PRIMITIVE of fm_base_liveness; consumers ask liveness, not existence.
# Returns FM_BASE_PRESENT, FM_BASE_ABSENT, or FM_BASE_PROBE_FAILED, and always sets
# FM_BASE_PROBE_ERR to git's stderr, so a caller can name an infrastructure failure
# instead of it masquerading as a verdict about the base. The ref is fully qualified, so
# a branch name can never be read as an option.
fm_base_probe_origin() {  # <git-dir> <branch>
  local dir=${1-} branch=${2-} rc=0 err_file
  FM_BASE_PROBE_ERR=
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-base-probe.XXXXXX")
  git -C "$dir" ls-remote --exit-code --heads origin \
    "refs/heads/$branch" >/dev/null 2>"$err_file" || rc=$?
  FM_BASE_PROBE_ERR=$(cat "$err_file" 2>/dev/null || true)
  rm -f "$err_file"
  case "$rc" in
    0) return "$FM_BASE_PRESENT" ;;
    2) return "$FM_BASE_ABSENT" ;;
    *) return "$FM_BASE_PROBE_FAILED" ;;
  esac
}

# fm_base_has_own_commits: does the base still carry any commit the default branch does not
# already have? A PRIMITIVE of fm_base_liveness, and the half of liveness that separates a
# feature base with unmerged history a wrong-based merge could drag onto the default branch -
# the whole hazard - from a branch that is merely still on origin.
#
# It is plain ancestry - `git rev-list --count <base> ^<default>` - and nothing more. It is
# NOT a merge detector, and it does not try to be: a base that was SQUASH-merged still has
# its own commits absent from the default branch by SHA, so it reads HAS_OWN_COMMITS and the
# full guard applies to it. That is deliberate. Telling a squash merge from an abandoned
# branch needs an inference, and an inference that can be wrong is exactly what this design
# hands to a human instead.
#
# Returns FM_BASE_HAS_OWN_COMMITS, FM_BASE_NO_OWN_COMMITS, or FM_BASE_OWN_COMMITS_UNKNOWN
# (git could not answer; a caller must not read that as either verdict). Sets
# FM_BASE_OWN_COMMIT_COUNT when it could count.
fm_base_has_own_commits() {  # <git-dir> <base-sha> <default-sha>
  local dir=${1-} base_sha=${2-} default_sha=${3-} count
  FM_BASE_OWN_COMMIT_COUNT=
  count=$(git -C "$dir" rev-list --count "$base_sha" "^$default_sha" 2>/dev/null) \
    || return "$FM_BASE_OWN_COMMITS_UNKNOWN"
  case "$count" in
    '' | *[!0-9]*) return "$FM_BASE_OWN_COMMITS_UNKNOWN" ;;
  esac
  FM_BASE_OWN_COMMIT_COUNT=$count
  if [ "$count" -gt 0 ]; then
    return "$FM_BASE_HAS_OWN_COMMITS"
  fi
  return "$FM_BASE_NO_OWN_COMMITS"
}

# fm_base_liveness: THE question about a declared base, asked once, here. Is <base-branch>
# still a LIVE feature base - on origin, and still carrying at least one commit
# <default-branch> does not already have?
#
# Every base-aware consumer calls this and switches on the answer: bin/fm-spawn.sh before it
# records a new declaration, bin/fm-pr-check.sh before it records pr=, bin/fm-review-diff.sh
# before it picks a diff base, and bin/fm-brief.sh through fm_base_liveness_brief_block, the
# crewmate's form of the same question. None of them may ask a weaker one.
#
# It fetches origin/<base> and origin/<default> into <git-dir>'s remote-tracking refs, so the
# count runs against origin's authoritative commits rather than a local branch that may be
# frozen at clone time. It touches no working tree, no local branch, and no HEAD.
#
# Returns:
#   FM_BASE_LIVE              on origin, carrying its own unmerged commits. Guard it.
#   FM_BASE_ABSORBED          on origin, but the default branch already has everything it
#                             carries. Not a feature base to stack on, and no hazard left.
#   FM_BASE_GONE              origin genuinely has no such branch. NOT a claim about whether
#                             it merged or was abandoned - that is a human's call.
#   FM_BASE_LIVENESS_UNKNOWN  the question could not be settled. NEVER read as either
#                             verdict: an infrastructure failure is not a fact about a base.
#
# Sets FM_BASE_LIVENESS_WHY to one clause naming what it found or could not determine,
# FM_BASE_LIVENESS_ERR to git's own error where there is one, and FM_BASE_TIP /
# FM_BASE_DEFAULT_SHA to the commits it resolved, so a caller can pass them straight to
# fm_base_head_rooted without re-resolving anything.
fm_base_liveness() {  # <git-dir> <base-branch> <default-branch>
  local dir=${1-} base=${2-} default=${3-} probe_rc=0 own_rc=0 err
  FM_BASE_TIP=
  FM_BASE_DEFAULT_SHA=
  FM_BASE_LIVENESS_WHY=
  FM_BASE_LIVENESS_ERR=

  fm_base_probe_origin "$dir" "$base" || probe_rc=$?
  case "$probe_rc" in
    "$FM_BASE_PRESENT") ;;
    "$FM_BASE_ABSENT")
      FM_BASE_LIVENESS_WHY="that branch no longer exists on origin"
      return "$FM_BASE_GONE"
      ;;
    *)
      FM_BASE_LIVENESS_WHY="origin could not be asked whether that branch still exists"
      FM_BASE_LIVENESS_ERR=$FM_BASE_PROBE_ERR
      return "$FM_BASE_LIVENESS_UNKNOWN"
      ;;
  esac

  if ! err=$(git -C "$dir" fetch --quiet origin \
    "+refs/heads/$base:refs/remotes/origin/$base" 2>&1); then
    FM_BASE_LIVENESS_WHY="that branch is on origin but could not be fetched"
    FM_BASE_LIVENESS_ERR=$err
    return "$FM_BASE_LIVENESS_UNKNOWN"
  fi
  if ! FM_BASE_TIP=$(git -C "$dir" rev-parse --verify --quiet \
    "refs/remotes/origin/$base^{commit}"); then
    FM_BASE_LIVENESS_WHY="that branch did not resolve to a commit after fetching"
    return "$FM_BASE_LIVENESS_UNKNOWN"
  fi
  if ! err=$(git -C "$dir" fetch --quiet origin \
    "+refs/heads/$default:refs/remotes/origin/$default" 2>&1); then
    FM_BASE_LIVENESS_WHY="the repo default branch ('$default') could not be fetched from origin, so what that base carries beyond it cannot be counted"
    FM_BASE_LIVENESS_ERR=$err
    return "$FM_BASE_LIVENESS_UNKNOWN"
  fi
  if ! FM_BASE_DEFAULT_SHA=$(git -C "$dir" rev-parse --verify --quiet \
    "refs/remotes/origin/$default^{commit}"); then
    FM_BASE_LIVENESS_WHY="the repo default branch ('$default') did not resolve to a commit"
    return "$FM_BASE_LIVENESS_UNKNOWN"
  fi

  fm_base_has_own_commits "$dir" "$FM_BASE_TIP" "$FM_BASE_DEFAULT_SHA" || own_rc=$?
  case "$own_rc" in
    "$FM_BASE_HAS_OWN_COMMITS")
      FM_BASE_LIVENESS_WHY="that branch carries $FM_BASE_OWN_COMMIT_COUNT commit(s) '$default' does not have"
      return "$FM_BASE_LIVE"
      ;;
    "$FM_BASE_NO_OWN_COMMITS")
      FM_BASE_LIVENESS_WHY="that branch carries no commit '$default' does not already have"
      return "$FM_BASE_ABSORBED"
      ;;
    *)
      FM_BASE_LIVENESS_WHY="git could not count what that branch carries beyond '$default'"
      return "$FM_BASE_LIVENESS_UNKNOWN"
      ;;
  esac
}

# fm_base_head_rooted: is <head-sha> rooted in the base's OWN history, rather than in the
# default branch? The head must fork from a commit the default branch cannot reach; a
# merge-base the default branch CAN reach means the head carries none of the base's work,
# because it was rebased onto the default branch - the incident this guards (see
# data/learnings.md 2026-07-07).
#
# It deliberately does NOT ask the head to descend from the base's CURRENT TIP. A stacked
# PR whose base is itself under review sees that base advance all the time, and a head
# that is merely behind is still correctly based and safe to merge; demanding tip-descent
# would turn every routine base advance into a hard merge refusal.
#
# Ask fm_base_liveness FIRST, and only ask this of a base it reported LIVE. Rootedness is
# only observable against a base that has unmerged history of its own: once every commit the
# base carries is an ancestor of the default branch, every fork point with it is reachable
# from the default branch too, so a perfectly stacked head reads UNROOTED. A caller that
# skips that gate refuses a safe PR and tells the operator its head was rebased when it
# was not.
#
# Returns FM_BASE_HEAD_ROOTED, FM_BASE_HEAD_UNROOTED, or FM_BASE_HEAD_UNRELATED (the two
# commits share no history at all). Sets FM_BASE_MERGE_BASE to the branch point when there
# is one, so a caller's refusal can name it.
fm_base_head_rooted() {  # <git-dir> <base-sha> <head-sha> <default-sha>
  local dir=${1-} base_sha=${2-} head_sha=${3-} default_sha=${4-} merge_base
  FM_BASE_MERGE_BASE=
  merge_base=$(git -C "$dir" merge-base "$base_sha" "$head_sha" 2>/dev/null) \
    || return "$FM_BASE_HEAD_UNRELATED"
  [ -n "$merge_base" ] || return "$FM_BASE_HEAD_UNRELATED"
  FM_BASE_MERGE_BASE=$merge_base
  if git -C "$dir" merge-base --is-ancestor "$merge_base" "$default_sha" 2>/dev/null; then
    return "$FM_BASE_HEAD_UNROOTED"
  fi
  return "$FM_BASE_HEAD_ROOTED"
}

# fm_base_brief_marker: the one line a based brief carries to prove it was rendered for that
# base. fm-brief.sh writes it into the brief; fm-spawn.sh requires it before launching a task
# whose meta declares a base, so a crewmate can never be handed a brief that says nothing
# about the base its PR will be guarded on. Defined here so the writer and the reader of the
# line cannot drift apart.
fm_base_brief_marker() {  # <branch>
  # shellcheck disable=SC2016  # Single quotes are deliberate: the backticks are literal
  # markdown in the brief the crewmate reads, not a command substitution.
  printf 'This task targets base branch `%s`, not the repo default.' "${1-}"
}

# fm_base_liveness_brief_block: the CREWMATE's form of fm_base_liveness - the same question,
# asked with the same two facts (is the branch on origin, and does it carry anything the
# default branch lacks), with a followable instruction for every answer it can return.
# It lives here, beside the predicate the scripts call, so the crewmate and the merge gate
# can never come to different conclusions about one base.
#
# A crewmate NEVER adjudicates its own base: only `live` lets it proceed, and every other
# answer is a distinct `blocked:` line and a stop, so firstmate decides. And it never reads
# the answer off a command that failed - a gone branch, an unfetchable default branch, and an
# unreachable origin all fail identically, and reading any of them as "the base merged" is how
# a feature branch's unmerged work reaches the default branch.
#
# It resolves the DEFAULT branch the way every script here resolves it: origin/HEAD when that
# resolves, else origin/main, else origin/master. `origin/HEAD` alone is not that question and
# is not dependable - a clone of an empty repo never gets one, which is exactly what firstmate's
# own create-then-clone flow produces - so a crewmate asking `^origin/HEAD` would hit a fatal on
# a base the scripts call LIVE, and report an infrastructure failure that never happened.
fm_base_liveness_brief_block() {  # <branch>
  local base=${1-}
  cat <<EOF
**Ask what state \`$base\` is in before you use it.** Do this on a fresh start before you root your branch on it, and again before you point a PR at it - a base merges most often exactly while its child is in flight.
\`\`\`
# Is \`$base\` still on origin? Exits 0 if it is, 2 if origin has no such branch, anything else if origin could not be asked.
git ls-remote --exit-code --heads origin refs/heads/$base
# Refresh origin's refs, then resolve the repo default branch the way firstmate's scripts do:
# origin/HEAD when it resolves, else origin/main, else origin/master. Plenty of clones never get
# an origin/HEAD, so asking \`^origin/HEAD\` on its own would fail on a perfectly live base.
git fetch --quiet origin
default=\$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
default=\${default#origin/}
if [ -z "\$default" ]; then
  for b in main master; do
    git show-ref --verify --quiet "refs/remotes/origin/\$b" && default=\$b && break
  done
fi
echo "default branch: \${default:-UNRESOLVED}"
# Count what \`$base\` carries that the default branch does not.
git rev-list --count "origin/$base" "^origin/\$default"
\`\`\`
Act on what those answers actually say, and on nothing else. A command that failed is not a verdict about \`$base\`.
- \`ls-remote\` exits 0 and the count is 1 or more - **live**. This is the ordinary case: \`$base\` is a feature branch with unmerged work of its own. Carry on with it.
- \`ls-remote\` exits 0 and the count is 0 - **absorbed**: the default branch already carries every commit \`$base\` has, so it is not a base to stack on and there is nothing left for the pre-merge guard to protect. Append \`blocked: intended base $base carries nothing the default branch does not already have\` and stop.
- \`ls-remote\` exits 2 - **gone**: origin has no such branch. Append \`blocked: intended base $base is gone from origin\` and stop.
- Anything else - \`ls-remote\` exits neither 0 nor 2, a fetch fails, the default branch prints \`UNRESOLVED\`, or the count does not print a number - **cannot tell**. This is an infrastructure failure, not a fact about \`$base\`. Append \`blocked: origin could not be asked about intended base $base: {git's error}\` and stop.

Whichever it is, a base that is not live is firstmate's call, not yours: do NOT fall back to the default branch on your own judgement, and do not guess what became of \`$base\`.
EOF
}
