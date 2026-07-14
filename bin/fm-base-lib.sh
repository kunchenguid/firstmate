#!/usr/bin/env bash
# Every FM_BASE_* variable here is an OUT-PARAM read by the scripts that source this lib,
# never by the lib itself, so SC2034's "appears unused" is structurally wrong about all of
# them. Disabled once, at the file level, rather than annotating each assignment - which
# would only rot as out-params are added.
# shellcheck disable=SC2034
#
# fm-base-lib.sh - THE ONE OWNER OF WHAT A TASK'S DECLARED BASE BRANCH MEANS.
#
# A task declares its intended base with fm-spawn.sh --base, which records base= and the
# base's spawn-time tip as base_sha= into state/<id>.meta. Four scripts then have to
# agree about what that declaration means RIGHT NOW:
#
#   bin/fm-spawn.sh       may this task be launched against that base at all?
#   bin/fm-base-state.sh  what is the base RIGHT NOW - the crewmate's own accessor, which
#                         bin/fm-brief.sh's brief has it consult before it touches a branch,
#                         because the base can merge or vanish between scaffold and run
#   bin/fm-pr-check.sh    may this PR be recorded and armed for merge?
#   bin/fm-review-diff.sh what is the honest diff base for review?
#
# THEY DO NOT EACH ASK THEIR OWN VERSION OF THE QUESTION. Every one of them decides on the
# predicates below, and the two consumers that have a head to look at decide on one shared
# verdict (fm_base_verdict), so review and merge can never reach opposite conclusions from
# the same facts. Four half-questions, each subtly wrong in its own way, is what this file
# exists to prevent.
#
# THE DECIDING QUESTION IS NEVER WHETHER THE BASE BRANCH STILL EXISTS. Branch existence is
# an unsound proxy in BOTH directions:
#
#   deleted without merging   an abandoned feature, a closed base PR, a force-deleted
#                             branch. The base's commits never landed, the pipeline
#                             replayed them onto the head when it rebased onto the
#                             default branch, and merging would drag them in. The
#                             hazard is fully present even though the branch is gone.
#   merged but NOT deleted    GitHub's "automatically delete head branches" is OFF by
#                             default, so this is at least as common an end-state as
#                             the deleted one. The base's work is already in the
#                             default branch, so a head that was rebased onto the
#                             default branch has nothing left to drag anywhere, and
#                             guarding it would refuse a safe merge forever.
#
# WHAT DECIDES IS TWO INDEPENDENT QUESTIONS, AND BOTH MUST BE ASKED:
#
#   WHERE IS THE HEAD ROOTED (fm_base_head_rooted)? In the default branch, or in the
#   base's own commits? This is asked FIRST, because it is what says whether merging
#   the head into the default branch would carry the base's commits along at all.
#
#   HAS THE BASE'S WORK LANDED (fm_base_work_landed)? It refines what the first answer
#   MEANS: a head rooted in a live base is correctly stacked, while a head rooted in a
#   base that has already SQUASH-merged still carries that base's pre-squash commits -
#   which the default branch does not have by commit id, however much it has their
#   content - so merging it into the default branch would land them all over again.
#
# Neither question subsumes the other, and landedness alone is NOT a licence to stand
# down: it only tells the default branch's content story, not the head's commit story.
# The origin probe is an INPUT to both, never the decision. Relaxing the guard takes
# proof; anything short of proof keeps it on.
#
# AN UNANSWERED QUESTION NEVER PRODUCES A PERMISSIVE ANSWER. Every outcome below is either
# proved or UNKNOWN, and UNKNOWN is not a state a caller may act on - it is a refusal.
# LIVE, in particular, is permissive: it means "correctly stacked on a live base, allow",
# so inferring it from a landedness that could not be settled would wave through the very
# head the guard exists to catch (a base that had in fact squash-merged, whose child PR
# then merges into a dead branch and never reaches the default branch at all).
#
# NOTHING HERE INFERS ANYTHING FROM A FETCH'S EXIT STATUS. A base we could not ask about
# is not a base that merged, and an auth or network failure must never be read as one.
# `git ls-remote --exit-code` separates the three cases at the source: 0 = the ref matched,
# 2 = no ref matched, anything else = the probe itself failed. That is a real
# discriminator, not a guess at git's error text.
#
# Sourced by fm-spawn.sh, fm-brief.sh, fm-pr-check.sh and fm-review-diff.sh. No side
# effects on source. set -u / set -e safe.

# Every enum below travels as a RETURN CODE, and several of them pass through the same
# scope in the same call chain. They are therefore given non-overlapping numeric ranges,
# so no value of one enum can ever be mistaken for a value of another - "we could not
# tell" and "stand the guard down" aliasing to the same number in a merge gate is a
# fail-open, and giving them disjoint ranges makes that impossible by construction rather
# than by everyone remembering to capture the code into a local first.

# Probe outcomes (fm_base_probe_origin). Callers compare against these names, never bare
# numbers.
FM_BASE_PRESENT=0
FM_BASE_PROBE_FAILED=1
FM_BASE_ABSENT=2

# Landedness outcomes (fm_base_work_landed).
FM_BASE_WORK_LANDED=3
FM_BASE_WORK_UNLANDED=4
FM_BASE_WORK_UNKNOWN=5

# Rootedness outcomes (fm_base_head_rooted).
FM_BASE_HEAD_ROOTED=6
FM_BASE_HEAD_UNROOTED=7
FM_BASE_HEAD_UNRELATED=8

# What the declared base IS right now (fm_base_resolve_state), for the consumers that
# have no head to look at yet.
FM_BASE_STATE_LIVE=10       # it exists on origin and still carries unmerged work
FM_BASE_STATE_LANDED=11     # its work is in the default branch (branch kept OR deleted)
FM_BASE_STATE_ABANDONED=12  # it is gone from origin and its work never landed
FM_BASE_STATE_UNKNOWN=13    # we could not tell; callers stay fail-closed

# What a PR head IS, given the state of the base it declared (fm_base_verdict).
# This is the single verdict fm-pr-check.sh and fm-review-diff.sh both decide on.
FM_BASE_VERDICT_ORDINARY=20        # head sits on the default branch, base has merged: no hazard
FM_BASE_VERDICT_STACKED_LIVE=21    # head is rooted in a base that still carries unmerged work
FM_BASE_VERDICT_STACKED_LANDED=22  # head is rooted in a base that has merged: it carries the base's pre-merge commits
FM_BASE_VERDICT_UNSTACKED=23       # head sits on the default branch but the base is still unmerged: the incident
FM_BASE_VERDICT_ABANDONED_BASE=24  # the base was deleted without ever merging
FM_BASE_VERDICT_INDETERMINATE=25   # we could not tell; callers stay fail-closed

# fm_base_valid_branch_name: 0 (true) if <name> is a non-empty, dash-free,
# whitespace-free, git-legal branch name. A leading dash matters beyond tidiness:
# the value reaches git as a refspec, where git would read it as an option, and
# `--upload-pack=<cmd>` is an arbitrary-command vector. fm-spawn.sh validates on
# the way in; the consumers validate again on the way out, because meta is a plain
# text file a human can edit.
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

# fm_base_valid_commit_id: 0 (true) if <id> looks like a git object id. base_sha=
# reaches git as a rev, where a leading dash would be read as an option; and meta is
# a plain text file a human can edit, so the recorded value is checked on the way out
# just as the branch name is.
fm_base_valid_commit_id() {  # <id>
  local id=${1-}
  case "$id" in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#id}" -ge 7 ] && [ "${#id}" -le 64 ]
}

# fm_base_probe_origin: ask origin whether <branch> exists, from within <git-dir>. This
# is the INPUT to fm_base_resolve_state below, not a decision anybody makes on its own.
# Returns FM_BASE_PRESENT, FM_BASE_ABSENT, or FM_BASE_PROBE_FAILED, and always sets
# FM_BASE_PROBE_ERR to git's stderr, so a caller's fail-closed refusal can name the
# infrastructure failure instead of it masquerading as a wrong-base verdict. The ref
# is fully qualified, so a branch name can never be read as an option.
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

# fm_base_work_landed: did the declared base's work actually reach the default branch?
# Asked of the base's CONTENT, not of the head, and answered the same way whether the
# base branch is still on origin or not:
#
#   landed    the base's work is in the default branch already. It merged - whether its
#             branch was deleted afterwards or kept. A head that sits on the DEFAULT
#             branch therefore has no unmerged feature history left to drag into it. A
#             head still ROOTED IN THE BASE is a different story: see fm_base_head_rooted,
#             because a squash merge leaves the base's own commits out of the default
#             branch by commit id even though their content is in it, and such a head
#             still carries them.
#   unlanded  the base still carries unmerged work. This is the live-feature-branch
#             case the guard exists for - and it is ALSO an abandoned base that was
#             deleted without merging, whose commits the pipeline replayed onto the
#             head. Callers keep guarding.
#   unknown   we could not tell. Not landed: callers never relax on it.
#
# The fact it reasons from is a base tip: the live tip on origin while the branch is
# still there, else base_sha=, the tip fm-spawn.sh recorded at spawn time when the
# base necessarily still existed. Two ways that commit's work can be carried by the
# default branch:
#
#   ancestor  the base merged with a merge commit or a fast-forward, so the recorded
#             commit is literally an ancestor of the default branch.
#   contained the base was squash-merged or rebase-merged (a squash is firstmate's
#             own default, and GitHub's most common setting), so the commit is NOT an
#             ancestor, but its content is already in the default branch: merging the
#             base into the default branch again would change nothing. Tested with a
#             real 3-way merge (git merge-tree --write-tree, git >= 2.38), so a
#             default branch that advanced past the squash still reads as containing
#             the base.
#   squashed  the replay above did not resolve, but some commit the default branch took
#             since the fork has EXACTLY the base's cumulative diff - which is what a
#             squash merge produces. Proved by patch id (fm_base_patch_landed).
#   replayed  the replay did not resolve, but every commit the base added since the fork
#             has a patch-equivalent commit in the default branch - what a rebase merge
#             produces. Proved by patch id too.
#
# The last two exist because the replay conflicts as soon as the default branch edits the
# base's own lines AFTER taking them, which is ordinary; without them, a base that had
# demonstrably merged would read as unsettleable and its child PRs would be refused for a
# hazard that is long gone. They only ever PROVE a merge - failing to find one proves
# nothing, and leaves the answer UNKNOWN.
#
# When the tip is the recorded SPAWN-TIME one, that is exactly what we want: if the
# base advanced and then merged, the merged content is a superset of the recorded
# tip's, so both tests still hold. When the branch is still on origin its LIVE tip is
# used instead, which is stricter: a base that merged and then took new commits reads
# as unlanded, and the guard rightly stays on.
#
# Returns FM_BASE_WORK_LANDED, FM_BASE_WORK_UNLANDED, or FM_BASE_WORK_UNKNOWN (the
# recorded commit is not in the local object store, or the containment merge could not be
# run or conflicted and no patch proof of a merge exists either). UNKNOWN is not LANDED,
# and it is not UNLANDED either: callers refuse on it.
# Sets FM_BASE_WORK_HOW to ancestor|contained|squashed|replayed|no-commit|no-merge|diverged.
fm_base_work_landed() {  # <git-dir> <base-sha> <default-sha>
  local dir=${1-} base_sha=${2-} default_sha=${3-} out rc=0 merged_tree default_tree
  FM_BASE_WORK_HOW=
  if ! git -C "$dir" cat-file -e "$base_sha^{commit}" 2>/dev/null; then
    FM_BASE_WORK_HOW=no-commit
    return "$FM_BASE_WORK_UNKNOWN"
  fi
  if git -C "$dir" merge-base --is-ancestor "$base_sha" "$default_sha" 2>/dev/null; then
    FM_BASE_WORK_HOW=ancestor
    return "$FM_BASE_WORK_LANDED"
  fi
  out=$(git -C "$dir" merge-tree --write-tree "$default_sha" "$base_sha" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    merged_tree=${out%%$'\n'*}
    default_tree=$(git -C "$dir" rev-parse --verify --quiet "$default_sha^{tree}") || {
      FM_BASE_WORK_HOW=no-merge
      return "$FM_BASE_WORK_UNKNOWN"
    }
    if [ -n "$merged_tree" ] && [ "$merged_tree" = "$default_tree" ]; then
      FM_BASE_WORK_HOW=contained
      return "$FM_BASE_WORK_LANDED"
    fi
    # The replay resolved and it CHANGES the default branch, so the base's work is
    # demonstrably not all there. That is a proof, not a guess.
    FM_BASE_WORK_HOW=diverged
    return "$FM_BASE_WORK_UNLANDED"
  fi
  # The replay conflicted (rc 1), or this git is too old for `merge-tree --write-tree`.
  # Containment is unproven - which is not the same as disproven, so the patch tests get
  # their turn before the answer becomes UNKNOWN.
  if fm_base_patch_landed "$dir" "$base_sha" "$default_sha"; then
    return "$FM_BASE_WORK_LANDED"
  fi
  FM_BASE_WORK_HOW=no-merge
  return "$FM_BASE_WORK_UNKNOWN"
}

# fm_base_patch_landed: can the base's merge be proved by PATCH, where replaying it onto
# the default branch could not resolve? Two proofs, both by patch id, both positive-only:
#
#   squashed  a commit the default branch took since the fork has exactly the base's
#             cumulative diff - a squash merge of the base, firstmate's own default.
#   replayed  every commit the base added since the fork has a patch-equivalent commit in
#             the default branch (git cherry) - a rebase merge of the base.
#
# Both survive the default branch editing the base's lines afterwards, which is exactly the
# state that makes the 3-way replay conflict, so this is what keeps a demonstrably merged
# base from reading as unsettleable forever.
#
# Returns 0 and sets FM_BASE_WORK_HOW when it proves a merge, 1 when it proves nothing.
# Finding no proof is NOT evidence of the opposite: the caller stays UNKNOWN, never
# UNLANDED, on a 1.
fm_base_patch_landed() {  # <git-dir> <base-sha> <default-sha>
  local dir=${1-} base_sha=${2-} default_sha=${3-} fork base_patch match cherry
  fork=$(git -C "$dir" merge-base "$base_sha" "$default_sha" 2>/dev/null) || return 1
  [ -n "$fork" ] || return 1

  # One `git log -p | git patch-id` pipeline covers every commit the default branch took
  # since the fork, so this costs two processes rather than one per commit.
  base_patch=$(git -C "$dir" diff "$fork" "$base_sha" 2>/dev/null \
    | git -C "$dir" patch-id --stable 2>/dev/null | cut -d' ' -f1)
  if [ -n "$base_patch" ]; then
    match=$(git -C "$dir" log -p --no-merges "$fork..$default_sha" 2>/dev/null \
      | git -C "$dir" patch-id --stable 2>/dev/null \
      | awk -v p="$base_patch" '$1 == p { print $2; exit }')
    if [ -n "$match" ]; then
      FM_BASE_WORK_HOW=squashed
      return 0
    fi
  fi

  cherry=$(git -C "$dir" cherry "$default_sha" "$base_sha" "$fork" 2>/dev/null) || return 1
  # Every line is "- <sha>" (patch-equivalent upstream) or "+ <sha>" (not there). No lines
  # at all means the base added nothing since the fork, which proves nothing on its own.
  [ -n "$cherry" ] || return 1
  if printf '%s\n' "$cherry" | grep -q '^+'; then
    return 1
  fi
  FM_BASE_WORK_HOW=replayed
  return 0
}

# fm_base_head_rooted: is <head-sha> rooted in the base's OWN unmerged history, rather
# than in the default branch? The head must fork from a commit the default branch cannot
# reach; a merge-base the default branch CAN reach means the head carries none of the
# base's unmerged work, because it was rebased onto the default branch - the incident.
#
# It deliberately does NOT ask the head to descend from the base's CURRENT TIP. A
# stacked PR whose base is itself under review sees that base advance all the time, and
# a head that is merely behind is still correctly based and safe to merge; demanding
# tip-descent would turn every routine base advance into a hard merge refusal.
#
# THIS IS ASKED FIRST, AND IT IS MEANINGFUL WHATEVER fm_base_work_landed SAYS - it reads
# the head's commits, where landedness reads the default branch's content, and a merged
# base does not make the head's own history disappear:
#
#   ancestor-merged base   its commits ARE in the default branch, so a head stacked on it
#                          forks from a commit the default branch can reach and reads
#                          UNROOTED. Correct: the head carries nothing the default branch
#                          lacks, and it is an ordinary default-branch PR.
#   squash-merged base     its commits are NOT in the default branch by id, only their
#                          content is, so a head still stacked on it forks from a commit
#                          the default branch cannot reach and reads ROOTED. Correct, and
#                          it is exactly the head that would re-land the base's commits.
#
# So a caller that asked landedness first and stood down on it would wave that second
# head straight through.
#
# Returns FM_BASE_HEAD_ROOTED, FM_BASE_HEAD_UNROOTED, or FM_BASE_HEAD_UNRELATED (the two
# commits share no history at all). Sets FM_BASE_MERGE_BASE to the branch point when
# there is one, so a caller's refusal can name it.
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

# fm_base_resolve_state: what IS the declared base right now? The whole question, asked
# once, for the consumer that has no head to look at (fm-spawn.sh) and as the first half
# of the verdict below.
#
# It probes origin, fetches the base's objects when the branch is there and the default
# branch always, picks the tip the predicates may reason from, and asks landedness. The
# probe runs first, so an origin that cannot be reached is never mistaken for a base that
# is gone. Branch existence is only ever an INPUT: it chooses WHICH tip (the live one, or
# the recorded spawn-time one) and, for an unlanded base, whether the base is still live or
# was abandoned.
#
# Returns FM_BASE_STATE_LIVE, FM_BASE_STATE_LANDED, FM_BASE_STATE_ABANDONED, or
# FM_BASE_STATE_UNKNOWN. LANDED, LIVE and ABANDONED are all PROVED: the base's work is in
# the default branch, or it demonstrably is not and the branch is still on origin, or it
# demonstrably is not and the branch is gone. A landedness that could not be settled is
# UNKNOWN whether the branch is on origin or not, and callers refuse on it - because LIVE
# is not the cautious answer, it is the permissive one ("correctly stacked, allow"), and a
# base that had in fact squash-merged would sail through it: its child PR would merge into
# a dead branch and the fix would never reach the default branch. Landedness is unsettleable
# only when replaying the base onto the default branch conflicts AND no squash or rebase
# merge of it can be found there - which is also the state in which the base's OWN PR
# cannot merge, so the refusal names a real repo problem rather than an arbitrary one.
#
# Sets FM_BASE_STATE_TIP (the tip to reason from), FM_BASE_STATE_DEFAULT_SHA (the freshly
# fetched default branch, which callers pass on to fm_base_head_rooted),
# FM_BASE_STATE_PRESENT (true|false), FM_BASE_STATE_WHY (ancestor|contained|squashed|
# replayed|diverged|no-commit|no-merge|probe-failed|fetch-failed|no-tip|gone-no-tip|
# gone-tip-unknown|default-fetch-failed|default-no-tip) and FM_BASE_STATE_ERR (git's own
# stderr when the probe or a fetch failed). The state IS the answer: there is no separate
# "landedness was merely unsettled" out-param, because an unsettled landedness no longer
# produces any state but UNKNOWN, and FM_BASE_STATE_WHY already names which question went
# unanswered.
fm_base_resolve_state() {  # <git-dir> <base-branch> <recorded-base-sha> <default-branch-name>
  local dir=${1-} branch=${2-} recorded=${3-} default_branch=${4-}
  local probe_rc=0 landed_rc=0 tip err
  FM_BASE_STATE_TIP=
  FM_BASE_STATE_DEFAULT_SHA=
  FM_BASE_STATE_PRESENT=false
  FM_BASE_STATE_WHY=
  FM_BASE_STATE_ERR=

  # The probe runs BEFORE any fetch, so an origin that cannot be reached at all is
  # reported as exactly that rather than as whichever fetch happened to fail first.
  fm_base_probe_origin "$dir" "$branch" || probe_rc=$?
  case "$probe_rc" in
    "$FM_BASE_PRESENT") FM_BASE_STATE_PRESENT=true ;;
    "$FM_BASE_ABSENT") ;;
    *)
      FM_BASE_STATE_ERR=$FM_BASE_PROBE_ERR
      FM_BASE_STATE_WHY=probe-failed
      return "$FM_BASE_STATE_UNKNOWN"
      ;;
  esac

  if "$FM_BASE_STATE_PRESENT"; then
    # The predicates read commits, not refs, so the base's objects have to be here.
    if ! err=$(git -C "$dir" fetch --quiet origin \
      "+refs/heads/$branch:refs/remotes/origin/$branch" 2>&1); then
      FM_BASE_STATE_ERR=$err
      FM_BASE_STATE_WHY=fetch-failed
      return "$FM_BASE_STATE_UNKNOWN"
    fi
    tip=$(git -C "$dir" rev-parse --verify --quiet \
      "refs/remotes/origin/$branch^{commit}") || {
      FM_BASE_STATE_WHY=no-tip
      return "$FM_BASE_STATE_UNKNOWN"
    }
  else
    # Gone. That is the state, and ONLY the state - it says nothing about whether the
    # base merged. The tip recorded at spawn, the last time the branch demonstrably
    # existed, is the fact that does.
    if [ -z "$recorded" ] || ! fm_base_valid_commit_id "$recorded"; then
      FM_BASE_STATE_WHY=gone-no-tip
      return "$FM_BASE_STATE_UNKNOWN"
    fi
    if ! git -C "$dir" cat-file -e "$recorded^{commit}" 2>/dev/null; then
      FM_BASE_STATE_WHY=gone-tip-unknown
      return "$FM_BASE_STATE_UNKNOWN"
    fi
    tip=$recorded
  fi

  if ! err=$(git -C "$dir" fetch --quiet origin \
    "+refs/heads/$default_branch:refs/remotes/origin/$default_branch" 2>&1); then
    FM_BASE_STATE_ERR=$err
    FM_BASE_STATE_WHY=default-fetch-failed
    return "$FM_BASE_STATE_UNKNOWN"
  fi
  FM_BASE_STATE_DEFAULT_SHA=$(git -C "$dir" rev-parse --verify --quiet \
    "refs/remotes/origin/$default_branch^{commit}") || {
    FM_BASE_STATE_WHY=default-no-tip
    return "$FM_BASE_STATE_UNKNOWN"
  }

  FM_BASE_STATE_TIP=$tip
  fm_base_work_landed "$dir" "$tip" "$FM_BASE_STATE_DEFAULT_SHA" || landed_rc=$?
  FM_BASE_STATE_WHY=$FM_BASE_WORK_HOW
  if [ "$landed_rc" -eq "$FM_BASE_WORK_LANDED" ]; then
    return "$FM_BASE_STATE_LANDED"
  fi
  # Only a PROVED unlanded base is live or abandoned; branch existence just says which of
  # the two. An unsettled landedness is neither, however present the branch is.
  if [ "$landed_rc" -eq "$FM_BASE_WORK_UNLANDED" ]; then
    if "$FM_BASE_STATE_PRESENT"; then
      return "$FM_BASE_STATE_LIVE"
    fi
    return "$FM_BASE_STATE_ABANDONED"
  fi
  return "$FM_BASE_STATE_UNKNOWN"
}

# fm_base_verdict: THE ONE DECISION. Combine what the base IS (fm_base_resolve_state) with
# where the head is ROOTED (fm_base_head_rooted) into the single verdict bin/fm-pr-check.sh
# gates the merge on and bin/fm-review-diff.sh picks its diff base from, so the two cannot
# reach opposite conclusions from the same facts.
#
# It is a pure combiner over the two answers, and it demands BOTH, so no caller can settle
# a base on half the question. Callers sequence the two lookups themselves - fm-pr-check.sh
# has to fetch a PR head from GitHub before it has one to root, fm-review-diff.sh already
# has its compare ref - but neither of them decides anything.
#
#   ORDINARY         the head sits on the default branch and the base has merged. Nothing
#                    it once carried is unmerged any more, so there is no hazard: verify
#                    the PR as the ordinary default-branch PR it now is, and diff it
#                    against the default branch.
#   STACKED_LIVE     the head is rooted in a base that still carries unmerged work. This
#                    is what a based task is supposed to look like: allow it, require the
#                    PR to target that base, and diff against it.
#   STACKED_LANDED   the head is rooted in a base that has merged. A squash or rebase
#                    merge put the base's CONTENT in the default branch but not its
#                    COMMITS, and this head still carries them, so merging would land them
#                    all over again. Refuse; the recovery is the head's REBASE onto the
#                    default branch, not a retarget. The base is still the head's honest
#                    fork point, so review keeps diffing against it.
#   UNSTACKED        the head sits on the default branch but the base still carries
#                    unmerged work, so the head was rebased off it - and the pipeline
#                    replayed the base's own commits onto the head when it did. That is
#                    the launch incident (data/learnings.md 2026-07-07). Refuse.
#   ABANDONED_BASE   the base was deleted from origin WITHOUT ever merging. Its commits
#                    are on this head either way, and there is no branch left to target.
#                    Refuse.
#   INDETERMINATE    we could not settle it - the base's state is UNKNOWN (the probe
#                    failed, or it is gone with no usable recorded tip), or the head and
#                    the base share no history at all. Refuse.
#
# Sets FM_BASE_VERDICT_WHY: "unrelated" when rootedness is what could not be settled,
# otherwise FM_BASE_STATE_WHY, so a caller's refusal names the question that went
# unanswered rather than the one it never got to.
fm_base_verdict() {  # <state-rc> <rooted-rc>
  local state_rc=${1-} rooted_rc=${2-}
  FM_BASE_VERDICT_WHY=$FM_BASE_STATE_WHY
  if [ "$state_rc" -eq "$FM_BASE_STATE_UNKNOWN" ]; then
    return "$FM_BASE_VERDICT_INDETERMINATE"
  fi
  if [ "$rooted_rc" -eq "$FM_BASE_HEAD_UNRELATED" ]; then
    FM_BASE_VERDICT_WHY=unrelated
    return "$FM_BASE_VERDICT_INDETERMINATE"
  fi
  if [ "$rooted_rc" -eq "$FM_BASE_HEAD_ROOTED" ]; then
    case "$state_rc" in
      "$FM_BASE_STATE_LANDED") return "$FM_BASE_VERDICT_STACKED_LANDED" ;;
      "$FM_BASE_STATE_ABANDONED") return "$FM_BASE_VERDICT_ABANDONED_BASE" ;;
      *) return "$FM_BASE_VERDICT_STACKED_LIVE" ;;
    esac
  fi
  # UNROOTED: the head forks from a commit the default branch can reach, so it carries
  # none of the base's own commits by id.
  case "$state_rc" in
    "$FM_BASE_STATE_LANDED") return "$FM_BASE_VERDICT_ORDINARY" ;;
    "$FM_BASE_STATE_ABANDONED") return "$FM_BASE_VERDICT_ABANDONED_BASE" ;;
    *) return "$FM_BASE_VERDICT_UNSTACKED" ;;
  esac
}
