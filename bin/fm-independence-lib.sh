#!/usr/bin/env bash
# fm-independence-lib.sh - the single owner of verifier identity and of the
# DERIVED verdict "was the checker independent of the maker, and on which
# dimensions?"
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-independence-lib.sh
#   . "$SCRIPT_DIR/fm-independence-lib.sh"
#
# WHY THIS EXISTS. The terminal task record carried the MAKER's harness, model
# and effort and nothing about the checker, so "is our checker actually
# independent?" could only be answered by mining pipeline history by hand. The
# first attempt at closing that gap added critic_process/critic_vendor/
# critic_model fields that a caller could also STATE, through --critic-process
# and friends. That is the defect, not the fix: a claim anyone can write is a
# claim that will eventually be written wrongly, and an independence claim that
# is merely asserted is worth nothing. So independence is DERIVED here and
# nowhere else, and there is deliberately no argument, field, flag or note
# anywhere in the fleet that sets it.
#
# THE AUTHORITATIVE SOURCE, AND WHY IT IS THE RIGHT ONE. The validation
# pipeline's own state database holds one agent_invocations row per agent-backed
# step, written AT INVOCATION TIME with the agent, model and model_provider that
# actually ran. That is creation-time evidence. A configuration read afterwards
# is NOT evidence of what ran: the pipeline resolves `agent: auto` at run
# creation, so the config can say one thing while the run did another. Reading
# the invocation record is the whole point.
#
# Set FM_PIPELINE_STATE_DB to override the database path. It is opened read-only
# and takes no lock: this is telemetry, and it may never fail or delay a
# teardown, a wake, or a landing.
#
# THREE VALUES, NEVER TWO. bin/fm-verify-lib.sh already owns firstmate's
# three-valued observation type, so this file reuses it rather than inventing a
# parallel vocabulary:
#
#   PASS             independent        observed, and the dimension holds
#   FAIL             not-independent    observed, and the dimension does NOT hold
#   NO_VERIFIER_RAN  could-not-observe  the dimension could not be established
#
# A run whose verifier identity was never captured is could-not-observe and can
# NEVER read as independent. That is the whole failure this file exists to make
# unreachable: "I looked and the checker was the maker" and "I could not look"
# are different facts, and collapsing them is how an unverifiable certification
# claim came to exist.
#
# FOUR DIMENSIONS, NOT ONE BOOLEAN. It is measured in this fleet that the
# pipeline's reviewers consume one shared subscription window regardless of which
# runtime the worker used, so a different harness does NOT imply an independent
# verifier. "Independent model, same billing account" and "independent vendor
# entirely" are different facts and a reader needs to know which one they have,
# so the verdict names the dimensions rather than collapsing them:
#
#   process  the review ran in its own agent process, not the maker's. It is
#            derived PER RUN from the sessions the pipeline recorded there:
#            independent when the reviewer held sessions of its own, NOT
#            independent when it shared one with the review-fixer (the party
#            fixing the code is then also the party judging it), and
#            could-not-observe when the run carries no reviewer session at all.
#            A recorded reviewing invocation says a review RAN; only a recorded
#            session says it ran as a process apart from the maker's, and
#            reading the first as the second is the collapse this file refuses.
#            A branch reports its WEAKEST run, never the union: independence is
#            a property of a run against specific bytes, and a branch is only
#            whatever runs happened to touch it.
#   model    the reviewing model differs from the making model.
#   vendor   the reviewing model provider differs from the making one.
#   pool     the reviewing model draws on a different credential pool - a
#            different account or quota window - from the making one. This is
#            the dimension a harness name cannot answer.
#
# The overall verdict is the WEAKEST dimension, and it is deliberately not a
# separate stored fact anywhere: any could-not-observe makes the whole verdict
# could-not-observe, otherwise any not-independent makes it not-independent.
# A consumer that wants "independent on model but not on pool" reads the
# dimensions, which is exactly the distinction the collapse would destroy.
#
# NAME MATCHING IS NEVER INFERRED. The pipeline names vendors and models in its
# own vocabulary (anthropic, claude-opus-5) and this fleet's routing config names
# them in another (claude, opus). Two names that differ are NOT evidence of two
# vendors, and two names that match are not evidence of one: only a mapping this
# fleet DECLARED, in config/models.json, may relate them. When the registry
# declares no mapping for a model or provider the pipeline recorded, that
# dimension is could-not-observe - never independent. bin/fm-model-registry-lib.sh
# owns those declarations; docs/configuration.md owns their schema.
#
# NOTHING IS EVER BACKFILLED. A terminal record written before this existed
# carries no verifier identity and reads could-not-observe forever. Guessing an
# identity for a historical run would be indistinguishable from a real
# observation afterwards, which is precisely the corruption this fleet already
# suffered once when invented sequence numbers were written into 200 of 249
# ledger records.

# Idempotent guard: the ledger, the certification command and their tests may all
# source this in one process tree, and a re-source must not redefine constants
# under set -u.
if [ -n "${FM_INDEPENDENCE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_INDEPENDENCE_LIB_SOURCED=1

# bin/fm-model-registry-lib.sh owns config/models.json, including the declared
# mapping from another system's model vocabulary onto this fleet's, and the
# credential pool each routed model draws on. Sourced rather than re-parsed so
# there is one owner of what the registry says.
# shellcheck source=bin/fm-model-registry-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-model-registry-lib.sh"

# The dimensions, in report order. This list is the contract: a consumer
# iterating it sees every dimension, so adding one cannot silently go unread.
# bin/fm-wake-ledger.sh's report reads it rather than restating the list.
# shellcheck disable=SC2034  # consumed by sourcing scripts, not by this file
FM_INDEPENDENCE_DIMENSIONS='process model vendor pool'

# The step whose invocations are the CRITIC. The pipeline records step_name
# 'review' for two different purposes: 'review' is the reviewer that judges the
# code, and 'review-fix' is the agent that then CHANGES the code in response.
# The fixer is maker-side work, so folding it into the critic would let the
# maker's own vendor and model be reported as the checker's.
FM_INDEPENDENCE_CRITIC_PURPOSE='review'

# --- the record ---------------------------------------------------------------
#
# One line per dimension plus one overall line, in bin/fm-verify.sh's record
# shape so bin/fm-verify-lib.sh's fm_verify_case and fm_verify_coerce read it
# unchanged:
#
#   verify[1]{verifier,result,reason,evidence_ref}:
#     independence-<dimension>,<PASS|FAIL|NO_VERIFIER_RAN>,<reason>,<evidence>
#
# The reason is what a reader needs to act: which two identities were compared,
# or which declaration was missing.
#
# The delimiter wins over the prose. The reason is free text and the evidence
# reference follows it, so a comma inside a reason would silently move part of
# that reason into the evidence field of every reader - bin/fm-verify-lib.sh's
# fm_verify_parse included. Commas are turned into semicolons here rather than
# left to each reason's author to remember.

# fm_independence_record <dimension> <result> <reason> <evidence>
fm_independence_record() {
  local reason=${3:-}
  reason=${reason//,/;}
  printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  independence-%s,%s,%s,%s\n' \
    "$1" "$2" "$reason" "$4"
}

# Echo the human vocabulary for one three-valued result. The ledger and the
# certification command both render it through this function, so the mapping is
# stated once and no reader may invent a fourth word for a value.
#
# The optional second argument is the word for the unobserved value only. The
# ledger's compact per-task field says "unknown" there, matching every other
# unresolved field on that record; the certification command spells it out. The
# two observed values are never overridable: a reader that could rename PASS
# could rename it to something that overstates what was seen.
fm_independence_label() {  # <PASS|FAIL|NO_VERIFIER_RAN> [unobserved-word]
  case "${1:-}" in
    PASS) printf 'independent' ;;
    FAIL) printf 'not-independent' ;;
    *) printf '%s' "${2:-could-not-observe}" ;;
  esac
}

# The validation pipeline's own state database.
fm_independence_db() {
  printf '%s' "${FM_PIPELINE_STATE_DB:-$HOME/.no-mistakes/state.sqlite}"
}

# --- identity capture ---------------------------------------------------------

# fm_independence_steps_query <repo> <branch>
# Echo one TSV row per agent-backed step the pipeline recorded for those bytes:
#
#   <step>\t<round>\t<purpose>\t<agent>\t<vendor>\t<model>\t<exit_status>
#     \t<shared_sessions>\t<reviewer_sessions>\t<run>
#
# EVERY SESSION FACT IS THAT ROW'S OWN RUN'S, never a total over the branch.
# Independence is a property of a RUN against specific bytes: a branch is
# whatever runs happened to touch it, so summing the session evidence over them
# answers a different question and answers it reassuringly - one run that
# recorded no reviewer session disappears behind a sibling run that did. The
# run id is carried so the fold below can count RUNS rather than rows and report
# the weakest one.
#
# <shared_sessions> is the count of distinct sessions the reviewer and the
# review-fixer shared on that row's run and <reviewer_sessions> the count the
# reviewer held at all there. Both are needed: the first is what makes the
# process dimension observably absent, and the second is what makes it
# observable in the first place, so "no session was recorded" cannot read as
# "no session was shared". An absent value is the empty string and is never
# filled in.
#
# Returns non-zero when the database, python3, or the repo/branch join is
# unavailable - all of which are could-not-observe at the caller, never an empty
# success. An empty result set with a readable database is likewise NOT a
# success: the caller cannot tell "no reviewer ran" from "these bytes were never
# validated here", so it stays could-not-observe.
fm_independence_steps_query() {  # <repo> <branch>
  local repo=${1:-} branch=${2:-} db out
  [ -n "$repo" ] && [ -n "$branch" ] || return 1
  db=$(fm_independence_db)
  [ -f "$db" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  out=$(
    python3 - "$db" "$repo" "$branch" 2>/dev/null <<'PY'
import os
import sqlite3
import sys
import urllib.parse

db, repo, branch = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    uri = "file:%s?mode=ro" % urllib.parse.quote(db)
    conn = sqlite3.connect(uri, uri=True, timeout=2)
    # Match the repository on the resolved path: a symlinked or differently
    # spelled project path is the same repository, and reading it as a
    # different one would silently record could-not-observe.
    wanted = os.path.realpath(repo)
    repo_ids = [
        r[0]
        for r in conn.execute("select id, working_path from repos")
        if r[1] and os.path.realpath(r[1]) == wanted
    ]
    run_ids = []
    for repo_id in repo_ids:
        run_ids.extend(
            r[0]
            for r in conn.execute(
                "select id from runs where repo_id = ? and branch = ?",
                (repo_id, branch),
            )
        )
    if not run_ids:
        conn.close()
        sys.exit(0)

    # The reviewer and the review-fixer sharing one session on a run means the
    # party judging the code is the party changing it. Held PER RUN, never
    # totalled: a total cannot be un-summed afterwards, so a run with no
    # reviewer session would be indistinguishable from one whose sessions were
    # merely disjoint. The reviewer's own session count rides beside it because
    # a run that recorded no session has nothing to share, and an empty overlap
    # read as a pass would be exactly the could-not-observe collapse.
    sessions = {}
    for run_id in run_ids:
        roles = {}
        for role, session_id in conn.execute(
            "select role, session_id from run_agent_sessions where run_id = ?",
            (run_id,),
        ):
            roles.setdefault(role, set()).add(session_id)
        reviewer = roles.get("reviewer", set())
        sessions[run_id] = (
            len(reviewer & roles.get("review-fixer", set())),
            len(reviewer),
        )

    rows = []
    for run_id in run_ids:
        rows.extend(
            (run_id,) + tuple(r)
            for r in conn.execute(
                "select step_name, round, purpose, agent, model_provider, model,"
                " exit_status from agent_invocations where run_id = ?"
                " order by started_at",
                (run_id,),
            )
        )
    conn.close()
except Exception:
    sys.exit(1)

for run_id, step, rnd, purpose, agent, provider, model, exit_status in rows:
    shared, reviewer_sessions = sessions.get(run_id, (0, 0))
    print(
        "\t".join(
            (
                str(step or ""),
                str(rnd if rnd is not None else ""),
                str(purpose or ""),
                str(agent or ""),
                str(provider or ""),
                str(model or ""),
                str(exit_status or ""),
                str(shared),
                str(reviewer_sessions),
                str(run_id or ""),
            )
        )
    )
PY
  ) || return 1
  printf '%s' "$out"
}

# The pipeline read, held for the (repo, branch) it was made for. Both consumers
# need the step block AND the verdict derived from it, and the ledger's call is
# on a teardown's critical path where a second python3 startup buys nothing.
# Reading twice is also a second chance to disagree with itself.
FM_INDEPENDENCE_STEPS_KEY=''
FM_INDEPENDENCE_STEPS_VAL=''
FM_INDEPENDENCE_STEPS_RC=1

# fm_independence_steps_load <repo> <branch>
# Read the pipeline once for those bytes into FM_INDEPENDENCE_STEPS_VAL and
# return what the read returned. A caller that runs this in ITS OWN shell, then
# derives the verdict, pays for one read: a command substitution inherits the
# variables of the shell that spawned it, so the derivation below finds the
# block already there. Nothing may write the block from outside - it is set only
# from fm_independence_steps_query, which is the authoritative read.
fm_independence_steps_load() {  # <repo> <branch>
  local key="${1:-}|${2:-}"
  if [ "$key" = "$FM_INDEPENDENCE_STEPS_KEY" ]; then
    return "$FM_INDEPENDENCE_STEPS_RC"
  fi
  if FM_INDEPENDENCE_STEPS_VAL=$(fm_independence_steps_query "${1:-}" "${2:-}"); then
    FM_INDEPENDENCE_STEPS_RC=0
  else
    FM_INDEPENDENCE_STEPS_VAL=''
    FM_INDEPENDENCE_STEPS_RC=1
  fi
  FM_INDEPENDENCE_STEPS_KEY=$key
  return "$FM_INDEPENDENCE_STEPS_RC"
}

# fm_independence_steps <repo> <branch>: the step block for those bytes, read
# once. Same contract as fm_independence_steps_query, including its non-zero
# return for a read that could not be made.
fm_independence_steps() {  # <repo> <branch>
  fm_independence_steps_load "${1:-}" "${2:-}" || return 1
  printf '%s' "$FM_INDEPENDENCE_STEPS_VAL"
}

# Collapse the distinct non-empty values on stdin to one field value:
#   ''       nothing was recorded - could-not-observe at the caller
#   <value>  every record that carried this fact agreed
#   mixed    two records genuinely disagreed
# A record the pipeline wrote without the fact contributes nothing and can
# therefore never make a field "mixed": absence is not evidence of a second
# value.
fm_independence_collapse() {
  awk 'NF { seen[$0] = 1 } END {
    n = 0
    for (v in seen) { n++; last = v }
    if (n == 0) { print ""; exit }
    if (n > 1) { print "mixed"; exit }
    print last
  }'
}

# fm_independence_critic <steps>
# Echo
#   "<vendor>\t<model>\t<count>\t<shared_runs>\t<unobserved_runs>\t<runs>"
# for the reviewing invocations in a <steps> block, where count is how many
# reviewer invocations were recorded at all. Returns non-zero when the block
# records no reviewer, so the caller reports could-not-observe rather than an
# empty agreement.
#
# The three run counts are counts of RUNS, folded by run id so a run that
# reviewed twice is one run and not two. They are what let the caller report the
# WEAKEST run rather than the union of them: a single run whose reviewer session
# was never recorded is enough to make the branch unobservable, however many
# sibling runs recorded theirs.
fm_independence_critic() {  # <steps>
  local steps=${1:-} critic vendor model count runs
  critic=$(printf '%s\n' "$steps" | awk -F'\t' -v p="$FM_INDEPENDENCE_CRITIC_PURPOSE" '$3 == p')
  [ -n "$critic" ] || return 1
  count=$(printf '%s\n' "$critic" | grep -c .)
  vendor=$(printf '%s\n' "$critic" | cut -f5 | fm_independence_collapse)
  model=$(printf '%s\n' "$critic" | cut -f6 | fm_independence_collapse)
  # An unrecorded session count is read as zero sessions, never as a count that
  # happened not to be printed: the fail-closed direction is the only safe one
  # for a field whose whole job is saying whether anything was observed.
  runs=$(printf '%s\n' "$critic" | awk -F'\t' '
    {
      run = $10
      if (run in seen) next
      seen[run] = 1
      total++
      if (($8 + 0) > 0) shared++
      if (($9 + 0) == 0) unobserved++
    }
    END { printf "%d\t%d\t%d", shared + 0, unobserved + 0, total + 0 }')
  printf '%s\t%s\t%s\t%s' "$vendor" "$model" "$count" "$runs"
}

# --- the derived verdict ------------------------------------------------------

# fm_independence_dimensions <repo> <branch> <maker-harness> <maker-model>
# Print one record per dimension, then one overall record, all in the shape
# fm_independence_record emits. Always prints every dimension: a dimension that
# appeared only when it resolved would make independence look better covered
# than it is.
#
# This function takes NO argument that could assert a result. Every value it
# prints is read from the pipeline's invocation record or from this fleet's
# declared routing config, which is what makes independence underivable by hand.
fm_independence_dimensions() {  # <repo> <branch> <maker-harness> <maker-model>
  local repo=${1:-} branch=${2:-} mharness=${3:-} mmodel=${4:-}
  local steps critic cvendor cmodel ccount cshared cunobserved cruns
  local mkey mprovider mpool ckey cprovider cpool
  local process=NO_VERIFIER_RAN model=NO_VERIFIER_RAN vendor=NO_VERIFIER_RAN pool=NO_VERIFIER_RAN
  local process_why='' model_why='' vendor_why='' pool_why='' evidence overall

  evidence="branch=${branch:-unknown}"

  if ! steps=$(fm_independence_steps "$repo" "$branch") || [ -z "$steps" ]; then
    # No readable invocation record for these bytes. Every dimension is
    # could-not-observe, and none of them may read as independent.
    process_why='the validation pipeline recorded no agent invocation for these bytes'
    model_why=$process_why
    vendor_why=$process_why
    pool_why=$process_why
  elif ! critic=$(fm_independence_critic "$steps"); then
    process_why='the pipeline recorded steps for these bytes but no reviewing invocation'
    model_why=$process_why
    vendor_why=$process_why
    pool_why=$process_why
  else
    cvendor=$(printf '%s' "$critic" | cut -f1)
    cmodel=$(printf '%s' "$critic" | cut -f2)
    ccount=$(printf '%s' "$critic" | cut -f3)
    cshared=$(printf '%s' "$critic" | cut -f4)
    cunobserved=$(printf '%s' "$critic" | cut -f5)
    cruns=$(printf '%s' "$critic" | cut -f6)
    evidence="$evidence reviews=$ccount runs=$cruns critic=${cvendor:-unrecorded}/${cmodel:-unrecorded}"

    # PROCESS. The recorded SESSIONS are the evidence, not the invocation: an
    # invocation row says a review ran, and says nothing about whose process it
    # ran in.
    #
    # Read PER RUN and reported as the WEAKEST run, in the same order this file
    # folds the dimensions themselves: a run nobody observed dominates a run
    # observed to have failed, because unmeasured and failing need different
    # repairs and the first cannot be ruled out by the second. One run whose
    # reviewer session was never recorded therefore makes the answer
    # could-not-observe however many sibling runs recorded theirs - an empty
    # overlap there is an absence of evidence, not evidence of separation.
    if [ "${cunobserved:-0}" -gt 0 ] 2>/dev/null; then
      process_why="$cunobserved of $cruns reviewing run(s) recorded no reviewer session; whose process reviewed is not observable there"
    elif [ "${cshared:-0}" -gt 0 ] 2>/dev/null; then
      process=FAIL
      process_why="on $cshared of $cruns reviewing run(s) the reviewer shared a session with the agent that fixes its findings"
    else
      process=PASS
      process_why="$ccount reviewing invocation(s) over $cruns run(s) each recorded reviewer session(s) of their own"
    fi

    # The maker's routed identity, and the critic's, both resolved through
    # declarations rather than through name similarity.
    mkey=$(fm_model_key_for_route "$mharness" "$mmodel")
    ckey=$(fm_model_key_for_pipeline "$cvendor" "$cmodel")

    # MODEL. Comparable only once both sides resolve to a registry key: "opus"
    # and "claude-opus-5" are neither observably the same model nor observably
    # two, and guessing either way is the failure this whole file exists to
    # prevent.
    if [ "$cmodel" = mixed ]; then
      model=NO_VERIFIER_RAN
      model_why='the reviews disagree on which model reviewed; no single reviewing model is observable'
    elif [ -z "$mkey" ]; then
      model_why="the model registry declares no entry for the making model ${mharness:-unknown}/${mmodel:-unknown}"
    elif [ -z "$ckey" ]; then
      model_why="the model registry declares no pipeline_model_ids mapping for the reviewing model ${cvendor:-unrecorded}/${cmodel:-unrecorded}"
    elif [ "$mkey" = "$ckey" ]; then
      model=FAIL
      model_why="the maker and the reviewer both ran $mkey"
    else
      model=PASS
      model_why="maker ran $mkey and the reviewer ran $ckey"
    fi

    # VENDOR.
    mprovider=$(fm_model_registry_provider_of "$mkey")
    cprovider=$(fm_model_registry_provider_of "$ckey")
    if [ -z "$mprovider" ] || [ -z "$cprovider" ]; then
      vendor_why='the model registry does not resolve both the making and the reviewing provider'
    elif [ "$mprovider" = "$cprovider" ]; then
      vendor=FAIL
      vendor_why="the maker and the reviewer both ran on provider $mprovider"
    else
      vendor=PASS
      vendor_why="maker ran on $mprovider and the reviewer on $cprovider"
    fi

    # POOL - the account or quota window the call was billed to. A different
    # harness does not imply a different pool, which is why this is derived from
    # the declared shared_quota_pool and never from a harness or vendor name.
    mpool=$(fm_model_pool_of "$mkey")
    cpool=$(fm_model_pool_of "$ckey")
    if [ -z "$mpool" ] || [ -z "$cpool" ]; then
      pool_why='the model registry records no shared_quota_pool for both the making and the reviewing model'
    elif [ "$mpool" = "$cpool" ]; then
      pool=FAIL
      pool_why="the maker and the reviewer both drew on the $mpool credential pool"
    else
      pool=PASS
      pool_why="maker drew on $mpool and the reviewer on $cpool"
    fi
  fi

  fm_independence_record process "$process" "$process_why" "$evidence"
  fm_independence_record model "$model" "$model_why" "$evidence"
  fm_independence_record vendor "$vendor" "$vendor_why" "$evidence"
  fm_independence_record pool "$pool" "$pool_why" "$evidence"

  # The overall verdict is the WEAKEST dimension. Any could-not-observe makes
  # the whole verdict could-not-observe: a checker proven to run on its own
  # model tells a reader nothing about whether it was billed to the maker's
  # account, so reporting that as plain "independent" is the collapse this
  # refuses to make.
  overall=PASS
  case "$process$model$vendor$pool" in
    *NO_VERIFIER_RAN*) overall=NO_VERIFIER_RAN ;;
    *FAIL*) overall=FAIL ;;
  esac
  fm_independence_record overall "$overall" \
    "process=$(fm_independence_label "$process") model=$(fm_independence_label "$model") vendor=$(fm_independence_label "$vendor") pool=$(fm_independence_label "$pool")" \
    "$evidence"
}

# fm_independence_overall <records>: echo the overall three-valued result from a
# block fm_independence_dimensions printed.
fm_independence_overall() {
  printf '%s\n' "${1:-}" | sed -n 's/^  independence-overall,\([A-Z_]*\),.*/\1/p' | head -1
}

# fm_independence_gaps <records>: echo the dimensions that are not independent,
# each as "<dimension>:<label>", so a refusal can NAME what could not be
# established instead of reporting a generic failure.
fm_independence_gaps() {
  printf '%s\n' "${1:-}" | awk -F, \
    -v fail="$(fm_independence_label FAIL)" \
    -v unobserved="$(fm_independence_label NO_VERIFIER_RAN)" '
    /^  independence-/ {
      dim = $1
      sub(/^  independence-/, "", dim)
      if (dim == "overall") next
      if ($2 == "PASS") next
      print dim ":" ($2 == "FAIL" ? fail : unobserved)
    }'
}
