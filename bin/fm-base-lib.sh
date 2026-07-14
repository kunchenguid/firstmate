#!/usr/bin/env bash
# FM_BASE_* variables here are OUT-PARAMS read by the scripts that source this lib, never
# by the lib itself, so SC2034's "appears unused" is structurally wrong about them.
# shellcheck disable=SC2034
#
# fm-base-lib.sh - the shared facts about a task's declared base branch.
#
# A ship task may declare a non-default intended base with fm-spawn.sh --base, which
# records base=<branch> into state/<id>.meta - the single source of truth for a task's
# base. Three scripts then need the same facts about it, so they live here once:
#
#   fm_base_valid_branch_name  is the recorded value a git branch name at all?
#   fm_base_probe_origin       does that branch exist on origin right now?
#   fm_base_has_own_commits    does it carry any commit the default branch lacks?
#   fm_base_head_rooted        is a given head rooted in that base's own history?
#   fm_base_brief_marker       the line a based brief carries, so a spawn can check it
#
# bin/fm-pr-check.sh's header owns what the guard DOES with these; this file only answers
# the questions. It deliberately answers nothing about a base's END OF LIFE - whether it
# merged, whether a squash merge put its content in the default branch, whether it was
# abandoned. Those questions cannot be settled from git alone without guessing, and every
# consumer hands them to a human instead (fm-pr-check.sh's header says how).
#
# NOTHING HERE INFERS ANYTHING FROM A FETCH'S EXIT STATUS. `git ls-remote --exit-code`
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
# already have? This is the only question that separates a LIVE feature base - one with
# unmerged history a wrong-based merge could drag onto the default branch, which is the
# whole hazard - from a branch that is merely still on origin.
#
# A branch existing on origin does NOT mean it is live. GitHub's delete-on-merge is off by
# default, so a base that merged and kept its branch is an ordinary end-state; every commit
# it carries is then an ancestor of the default branch, it has nothing left to drag
# anywhere, and rootedness is not even observable against it (any head's fork point with it
# is reachable from the default branch, so a correctly stacked head reads UNROOTED).
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
# Ask fm_base_has_own_commits FIRST. Rootedness is only observable against a base that has
# unmerged history of its own: once every commit the base carries is an ancestor of the
# default branch, every fork point with it is reachable from the default branch too, so a
# perfectly stacked head reads UNROOTED. A caller that skips that gate refuses a safe PR
# and tells the operator its head was rebased when it was not.
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
