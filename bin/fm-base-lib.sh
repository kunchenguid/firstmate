#!/usr/bin/env bash
# FM_BASE_* variables here are OUT-PARAMS read by the scripts that source this lib, never
# by the lib itself, so SC2034's "appears unused" is structurally wrong about them.
# shellcheck disable=SC2034
#
# fm-base-lib.sh - the shared facts about a task's declared base branch.
#
# A ship task may declare a non-default intended base with fm-spawn.sh --base, which
# records base=<branch> into state/<id>.meta - the single source of truth for a task's
# base. Three scripts then need the same two facts about it, so they live here once:
#
#   fm_base_valid_branch_name  is the recorded value a git branch name at all?
#   fm_base_probe_origin       does that branch exist on origin right now?
#   fm_base_head_rooted        is a given head rooted in that base's own history?
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
