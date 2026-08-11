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
#   process  the review ran in its own agent process, not the maker's:
#            independent when the reviewer held sessions of its own, NOT
#            independent when it shared one with the review-fixer (the party
#            fixing the code is then also the party judging it), and
#            could-not-observe when the run carries no reviewer session at all.
#            A recorded reviewing invocation says a review RAN; only a recorded
#            session says it ran as a process apart from the maker's, and
#            reading the first as the second is the collapse this file refuses.
#   model    the reviewing model differs from the making model.
#   vendor   the reviewing model provider differs from the making one.
#   pool     the reviewing model draws on a different credential pool - a
#            different account or quota window - from the making one. This is
#            the dimension a harness name cannot answer.
#
# EVERY DIMENSION IS DERIVED PER RUN. Independence is a property of a RUN
# against specific bytes; a branch is only whatever runs happened to touch it,
# so nothing here is folded across runs before it is judged. Two runs that
# genuinely used different reviewers are TWO ANSWERS, not an absence of one, and
# dissolving them into "the reviews disagree" would manufacture an ambiguity the
# record does not contain.
#
# THE ASYMMETRY, WHICH EVERY FOLD IN THIS FILE OBEYS. What was never observed
# may only ever weaken a claim of INDEPENDENCE. It may never weaken a finding of
# DEPENDENCE:
#
#   observed not-independent    a POSITIVE finding. It SURVIVES every fold.
#                               Nothing unobserved erases it.
#   observed independent, with
#   an unobserved sibling       could-not-observe, NOT independent: the run
#                               nobody looked at could be the dependent one.
#
# Inverting that would let a gap launder a known problem into an unknown one,
# which reads as the milder of the two while being strictly worse. So a fold
# ranks not-independent above could-not-observe above independent, whether it is
# folding runs into a dimension or dimensions into the overall verdict.
#
# The overall verdict is the WEAKEST dimension, and it is deliberately not a
# separate stored fact anywhere: any not-independent dimension makes the whole
# verdict not-independent, and could-not-observe applies only when nothing was
# observed dependent. A consumer that wants "independent on model but not on
# pool" reads the dimensions, which is exactly the distinction the collapse
# would destroy.
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

# THE MEMBER SET, WHICH IS A RUN QUESTION AND NOT A ROW QUESTION. The branch
# view folds RUNS, so which runs are members of that fold decides the verdict
# before any dimension is judged. Two readings are wrong in opposite directions
# and both were reachable:
#
#   a run that never reached the review step is NOT invisible. It provides no
#   independence evidence about these bytes, so it WEAKENS the fold to
#   could-not-observe. Dropping it is the reassuring answer and it is the same
#   defect as an absent session row reading as independent.
#
#   a run that was cancelled or failed is NOT a member. It never finished
#   verifying anything, so its reviewer is not the verifier of these bytes and
#   must not decide the branch's verdict. It is excluded - and the exclusion is
#   REPORTED on every dimension's reason, because an exclusion that strengthens
#   a verdict silently is the same laundering in the other direction.
#
# The governing asymmetry is unchanged: unobserved or unfinished evidence may
# only ever weaken a claim of independence, never a finding of dependence.
FM_INDEPENDENCE_NONMEMBER_RUN_STATUS='cancelled failed'

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

# Set FM_INDEPENDENCE_RANK to how strongly a result must survive a fold, so
# every fold in this file ranks the three values the same way and the asymmetry
# is stated once rather than re-derived at each site. An observed dependence
# outranks everything: it is a positive finding, and letting an unobserved
# sibling erase it would turn a known problem into an unknown one.
#
# It ASSIGNS rather than echoes because the fold below runs it once per
# dimension per run, and bin/fm-wake-ledger.sh runs that fold on a teardown's
# critical path where this library promises never to delay one. A command
# substitution here would be a fork per comparison for a three-way case.
FM_INDEPENDENCE_RANK=0
fm_independence_rank() {  # <PASS|FAIL|NO_VERIFIER_RAN>
  case "${1:-}" in
    FAIL) FM_INDEPENDENCE_RANK=2 ;;
    PASS) FM_INDEPENDENCE_RANK=0 ;;
    *) FM_INDEPENDENCE_RANK=1 ;;
  esac
}

# The overall verdict over a set of dimensions: the WEAKEST one, on the same
# asymmetry every fold in this file obeys. Any observed not-independent
# dimension makes the whole verdict not-independent and no unresolved sibling
# dimension may erase it - a checker PROVEN to have drawn on the maker's own
# credential pool is a finding, and reporting it as "could not observe" because
# the vendor mapping was missing would launder it into the milder word.
# Could-not-observe applies only when nothing was observed dependent: a checker
# proven to run its own model still tells a reader nothing about whose account
# paid for it, so that may never read as plain "independent" either.
#
# Stated once here because every producer of the record block folds it the same
# way, and two copies of this rule would drift the moment only one was edited.
fm_independence_overall_of() {  # <process> <model> <vendor> <pool>
  case "${1:-}${2:-}${3:-}${4:-}" in
    *FAIL*) printf 'FAIL' ;;
    *NO_VERIFIER_RAN*) printf 'NO_VERIFIER_RAN' ;;
    *) printf 'PASS' ;;
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
#     \t<shared_sessions>\t<reviewer_sessions>\t<run>\t<run_status>
#
# A run that recorded NO agent invocation at all still emits one row, with every
# invocation field empty. It has to: the fold below counts RUNS, and a run that
# never reached the review step is a member whose verifier identity was never
# captured. Leaving it out of the block would delete it from the fold entirely,
# which is the reassuring answer rather than the honest one.
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
    # The run's own status rides on every row it produces. Whether a run is a
    # member of the branch fold is a fact about the RUN, so it has to travel
    # with the run rather than be re-derived per row by the caller.
    status_of = {}
    run_ids = []
    for repo_id in repo_ids:
        for run_id, status in conn.execute(
            "select id, status from runs where repo_id = ? and branch = ?",
            (repo_id, branch),
        ):
            run_ids.append(run_id)
            status_of[run_id] = status or ""
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
        invocations = list(
            conn.execute(
                "select step_name, round, purpose, agent, model_provider, model,"
                " exit_status from agent_invocations where run_id = ?"
                " order by started_at",
                (run_id,),
            )
        )
        if invocations:
            rows.extend((run_id,) + tuple(r) for r in invocations)
        else:
            # A run that recorded no agent-backed step at all. It is still a run
            # that touched these bytes, and the fold has to be able to see it.
            rows.append((run_id, "", None, "", "", None, None, ""))
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
                str(status_of.get(run_id) or ""),
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

# fm_independence_members <steps>: echo only the rows belonging to runs that are
# MEMBERS of the branch fold, which is every run the pipeline recorded except
# one it marked cancelled or failed. A run that did not finish never verified
# these bytes, so its reviewer may not decide whether they were verified
# independently. An unrecognized status is a member: a status this fleet cannot
# read is not a licence to drop a run from the evidence.
fm_independence_members() {  # <steps>
  printf '%s\n' "${1:-}" | awk -F'\t' -v drop="$FM_INDEPENDENCE_NONMEMBER_RUN_STATUS" '
    BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) out[d[i]] = 1 }
    NF && !($11 in out)'
}

# fm_independence_dropped <steps>: how many RUNS the member set excludes. The
# count is reported on every dimension rather than kept here, because an
# exclusion that quietly strengthens a verdict is the same laundering as a gap
# that quietly weakens one.
fm_independence_dropped() {  # <steps>
  printf '%s\n' "${1:-}" | awk -F'\t' -v drop="$FM_INDEPENDENCE_NONMEMBER_RUN_STATUS" '
    BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) out[d[i]] = 1 }
    NF && ($11 in out) && !($10 in seen) { seen[$10] = 1; c++ }
    END { printf "%d", c + 0 }'
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

# The field separator for the per-run rows below. It is the ASCII unit
# separator and NOT a tab, and that is load-bearing rather than tidy.
#
# Tab is one of bash's three IFS WHITESPACE characters, so `read` with IFS set
# to a tab collapses a run of them into one delimiter instead of yielding the
# empty fields between them. A run whose reviewing invocations recorded no
# vendor and no model emits two empty identity fields, and under a tab the
# numeric columns after them would each shift left - landing the review count in
# the shared-session slot and reporting "the reviewer shared a session with the
# agent that fixes its findings" for a run that recorded no session at all.
# That is a FABRICATED observation of dependence, built out of an absence of
# evidence, and it is the most durable value in this file: the asymmetry above
# makes an observed dependence survive every fold downstream. A non-whitespace
# separator preserves empty fields, so an unrecorded identity stays unrecorded.
FM_INDEPENDENCE_FS=$'\037'

# fm_independence_runs <member steps>
# Echo one row per MEMBER RUN, in the order the pipeline recorded them, with
# FM_INDEPENDENCE_FS between the fields:
#
#   <run><FS><vendor><FS><model><FS><shared_sessions><FS><reviewer_sessions><FS><reviews>
#
# This is the unit every dimension is judged on. EVERY member run gets a row,
# including one whose reviews count is zero: a run that touched these bytes and
# never reached the review step captured no verifier identity, and the caller
# reports that as could-not-observe. Selecting only the runs that DID review
# would let a run with no reviewer disappear behind a sibling that had one,
# which is the branch-scoped reading this file exists to refuse.
#
# The vendor and model are collapsed WITHIN the run only, so a branch whose runs
# used different reviewers yields two rows with two identities rather than one
# row saying "mixed" - two answers, not an absence of answers. Only a run whose
# own reviewing invocations disagree can be mixed, and that is a genuine
# ambiguity in one run's record.
fm_independence_runs() {  # <member steps>
  printf '%s\n' "${1:-}" | awk -F'\t' -v p="$FM_INDEPENDENCE_CRITIC_PURPOSE" -v fs="$FM_INDEPENDENCE_FS" '
    NF {
      run = $10
      if (run == "") next
      if (!(run in seen)) {
        seen[run] = 1
        order[++n] = run
        shared[run] = $8 + 0
        sess[run] = $9 + 0
        reviews[run] = 0
      }
      if ($3 != p) next
      reviews[run]++
      if ($5 != "") vendor[run] = (run in vendor) && vendor[run] != $5 ? "mixed" : $5
      if ($6 != "") model[run] = (run in model) && model[run] != $6 ? "mixed" : $6
    }
    END {
      for (i = 1; i <= n; i++) {
        r = order[i]
        printf "%s%s%s%s%s%s%d%s%d%s%d\n", r, fs, vendor[r], fs, model[r], fs,
          shared[r], fs, sess[r], fs, reviews[r]
      }
    }'
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
  local steps='' members='' dropped=0 dropped_why critic cvendor cmodel ccount
  local mkey mprovider mpool ckey cprovider cpool ckey_for=''
  local run rvendor rmodel rshared rsess rreviews r_rank runs_n=0
  local r_process r_model r_vendor r_pool
  local r_process_why r_model_why r_vendor_why r_pool_why
  local process=NO_VERIFIER_RAN model=NO_VERIFIER_RAN vendor=NO_VERIFIER_RAN pool=NO_VERIFIER_RAN
  local process_n=0 model_n=0 vendor_n=0 pool_n=0
  local process_rank=-1 model_rank=-1 vendor_rank=-1 pool_rank=-1
  local process_why='' model_why='' vendor_why='' pool_why='' evidence overall

  evidence="branch=${branch:-unknown}"

  # WHICH RUNS ARE MEMBERS, decided before any dimension is judged. A run the
  # pipeline cancelled or marked failed never finished verifying these bytes, so
  # it is not a member and its reviewer does not decide the branch.
  if steps=$(fm_independence_steps "$repo" "$branch") && [ -n "$steps" ]; then
    members=$(fm_independence_members "$steps")
    dropped=$(fm_independence_dropped "$steps")
    [ "${dropped:-0}" = 0 ] || evidence="$evidence excluded=$dropped"
  else
    steps=''
  fi

  if [ -z "$steps" ]; then
    # No readable invocation record for these bytes. Every dimension is
    # could-not-observe, and none of them may read as independent.
    process_why='the validation pipeline recorded no agent invocation for these bytes'
    model_why=$process_why
    vendor_why=$process_why
    pool_why=$process_why
  elif [ -z "$members" ]; then
    # Every run that touched these bytes was cancelled or failed. Excluding them
    # is right - none of them verified anything - but it leaves NOTHING that
    # did, and an empty member set may never read as a clean branch.
    process_why='every run the pipeline recorded for these bytes was cancelled or failed; none of them verified them'
    model_why=$process_why
    vendor_why=$process_why
    pool_why=$process_why
  elif ! critic=$(fm_independence_critic "$members"); then
    process_why='the pipeline recorded steps for these bytes but no reviewing invocation'
    model_why=$process_why
    vendor_why=$process_why
    pool_why=$process_why
  else
    cvendor=$(printf '%s' "$critic" | cut -f1)
    cmodel=$(printf '%s' "$critic" | cut -f2)
    ccount=$(printf '%s' "$critic" | cut -f3)

    # The maker's routed identity resolves once: it is the same maker whichever
    # run reviewed its bytes.
    mkey=$(fm_model_key_for_route "$mharness" "$mmodel")
    mprovider=$(fm_model_registry_provider_of "$mkey")
    mpool=$(fm_model_pool_of "$mkey")

    process='' model='' vendor='' pool=''
    while IFS="$FM_INDEPENDENCE_FS" read -r run rvendor rmodel rshared rsess rreviews; do
      [ -n "$run" ] || continue
      runs_n=$((runs_n + 1))

      # PROCESS. The recorded SESSIONS are the evidence, not the invocation: an
      # invocation row says a review ran, and says nothing about whose process
      # it ran in. On this run an empty reviewer/review-fixer overlap counts as
      # separation only because this run recorded sessions to overlap.
      #
      # A run with NO reviewing invocation cannot pass this dimension however
      # many sessions it recorded - there was no review to run in a process of
      # its own - but an OBSERVED overlap is still a positive finding and is
      # still reported, because the asymmetry runs one way only.
      if [ "${rshared:-0}" -gt 0 ] 2>/dev/null; then
        r_process=FAIL
        r_process_why="the reviewer shared $rshared session(s) with the agent that fixes its findings"
      elif [ "${rreviews:-0}" -eq 0 ] 2>/dev/null; then
        r_process=NO_VERIFIER_RAN
        r_process_why='this run recorded no reviewing invocation at all; nothing about it verified these bytes'
      elif [ "${rsess:-0}" -gt 0 ] 2>/dev/null; then
        r_process=PASS
        r_process_why="$rreviews reviewing invocation(s) ran in $rsess session(s) of their own"
      else
        r_process=NO_VERIFIER_RAN
        r_process_why="$rreviews reviewing invocation(s) ran and no reviewer session was recorded; whose process reviewed is not observable"
      fi

      # A run that never reached the review step captured no reviewing identity,
      # so every identity dimension is could-not-observe for it. This is the
      # weakening that makes such a run visible to the fold at all; dropping it
      # would let it disappear behind a sibling run that did review.
      if [ "${rreviews:-0}" -eq 0 ] 2>/dev/null; then
        r_model=NO_VERIFIER_RAN
        r_model_why='this run recorded no reviewing invocation; no reviewing identity was captured for it'
        r_vendor=NO_VERIFIER_RAN
        r_vendor_why=$r_model_why
        r_pool=NO_VERIFIER_RAN
        r_pool_why=$r_model_why
      else
        # This run's reviewing identity, resolved through declarations rather
        # than through name similarity. Held across iterations because
        # consecutive runs usually reviewed with the same identity and each
        # resolution is a jq.
        if [ "$rvendor|$rmodel" != "$ckey_for" ]; then
          ckey_for="$rvendor|$rmodel"
          ckey=$(fm_model_key_for_pipeline "$rvendor" "$rmodel")
          cprovider=$(fm_model_registry_provider_of "$ckey")
          cpool=$(fm_model_pool_of "$ckey")
        fi

        # MODEL. Comparable only once both sides resolve to a registry key:
        # "opus" and "claude-opus-5" are neither observably the same model nor
        # observably two, and guessing either way is the failure this whole file
        # exists to prevent.
        if [ "$rmodel" = mixed ] || [ "$rvendor" = mixed ]; then
          r_model=NO_VERIFIER_RAN
          r_model_why='the reviewing invocations of this run disagree on which model reviewed'
        elif [ -z "$mkey" ]; then
          r_model=NO_VERIFIER_RAN
          r_model_why="the model registry declares no entry for the making model ${mharness:-unknown}/${mmodel:-unknown}"
        elif [ -z "$ckey" ]; then
          r_model=NO_VERIFIER_RAN
          r_model_why="the model registry declares no pipeline_model_ids mapping for the reviewing model ${rvendor:-unrecorded}/${rmodel:-unrecorded}"
        elif [ "$mkey" = "$ckey" ]; then
          r_model=FAIL
          r_model_why="the maker and the reviewer both ran $mkey"
        else
          r_model=PASS
          r_model_why="maker ran $mkey and the reviewer ran $ckey"
        fi

        # VENDOR.
        if [ -z "$mprovider" ] || [ -z "$cprovider" ]; then
          r_vendor=NO_VERIFIER_RAN
          r_vendor_why='the model registry does not resolve both the making and the reviewing provider'
        elif [ "$mprovider" = "$cprovider" ]; then
          r_vendor=FAIL
          r_vendor_why="the maker and the reviewer both ran on provider $mprovider"
        else
          r_vendor=PASS
          r_vendor_why="maker ran on $mprovider and the reviewer on $cprovider"
        fi

        # POOL - the account or quota window the call was billed to. A different
        # harness does not imply a different pool, which is why this is derived
        # from the declared shared_quota_pool and never from a harness or vendor
        # name.
        if [ -z "$mpool" ] || [ -z "$cpool" ]; then
          r_pool=NO_VERIFIER_RAN
          r_pool_why='the model registry records no shared_quota_pool for both the making and the reviewing model'
        elif [ "$mpool" = "$cpool" ]; then
          r_pool=FAIL
          r_pool_why="the maker and the reviewer both drew on the $mpool credential pool"
        else
          r_pool=PASS
          r_pool_why="maker drew on $mpool and the reviewer on $cpool"
        fi
      fi

      # Fold this run into the branch view, weakest run winning. A run that
      # merely repeats the standing answer only raises its count, so the reason
      # keeps naming the run that decided the verdict. The standing rank is
      # carried rather than recomputed: it only moves when the answer does.
      fm_independence_rank "$r_process"; r_rank=$FM_INDEPENDENCE_RANK
      if [ "$r_rank" -gt "$process_rank" ]; then
        process=$r_process process_why=$r_process_why process_n=1 process_rank=$r_rank
      elif [ "$r_process" = "$process" ]; then
        process_n=$((process_n + 1))
      fi
      fm_independence_rank "$r_model"; r_rank=$FM_INDEPENDENCE_RANK
      if [ "$r_rank" -gt "$model_rank" ]; then
        model=$r_model model_why=$r_model_why model_n=1 model_rank=$r_rank
      elif [ "$r_model" = "$model" ]; then
        model_n=$((model_n + 1))
      fi
      fm_independence_rank "$r_vendor"; r_rank=$FM_INDEPENDENCE_RANK
      if [ "$r_rank" -gt "$vendor_rank" ]; then
        vendor=$r_vendor vendor_why=$r_vendor_why vendor_n=1 vendor_rank=$r_rank
      elif [ "$r_vendor" = "$vendor" ]; then
        vendor_n=$((vendor_n + 1))
      fi
      fm_independence_rank "$r_pool"; r_rank=$FM_INDEPENDENCE_RANK
      if [ "$r_rank" -gt "$pool_rank" ]; then
        pool=$r_pool pool_why=$r_pool_why pool_n=1 pool_rank=$r_rank
      elif [ "$r_pool" = "$pool" ]; then
        pool_n=$((pool_n + 1))
      fi
    done <<EOF
$(fm_independence_runs "$members")
EOF

    evidence="$evidence reviews=$ccount runs=$runs_n critic=${cvendor:-unrecorded}/${cmodel:-unrecorded}"

    if [ -z "$process" ]; then
      # Reviewing invocations the pipeline recorded against no run at all. There
      # is nothing to judge per run, and judging them together is exactly the
      # branch-scoped reading this refuses.
      process=NO_VERIFIER_RAN model=NO_VERIFIER_RAN vendor=NO_VERIFIER_RAN pool=NO_VERIFIER_RAN
      process_why='the pipeline recorded reviewing invocations but no run to attribute them to'
      model_why=$process_why vendor_why=$process_why pool_why=$process_why
    fi

    # More than one member run means the branch view is a choice among readings,
    # so it says how many runs read the way the verdict does. A reader who sees
    # 1 of 3 knows two other runs said something else and can go and look.
    if [ "$runs_n" -gt 1 ]; then
      process_why="$process_why ($process_n of $runs_n run(s) read this way)"
      model_why="$model_why ($model_n of $runs_n run(s) read this way)"
      vendor_why="$vendor_why ($vendor_n of $runs_n run(s) read this way)"
      pool_why="$pool_why ($pool_n of $runs_n run(s) read this way)"
    fi
  fi

  # An exclusion is never silent. Dropping a cancelled or failed run is right,
  # and it can only ever STRENGTHEN what is left, so the reader is told on every
  # dimension that it happened and can go and look at what was dropped.
  if [ "${dropped:-0}" -gt 0 ] 2>/dev/null; then
    dropped_why=" ($dropped cancelled or failed run(s) excluded from the fold: a run that did not finish never verified these bytes)"
    process_why="$process_why$dropped_why"
    model_why="$model_why$dropped_why"
    vendor_why="$vendor_why$dropped_why"
    pool_why="$pool_why$dropped_why"
  fi

  fm_independence_record process "$process" "$process_why" "$evidence"
  fm_independence_record model "$model" "$model_why" "$evidence"
  fm_independence_record vendor "$vendor" "$vendor_why" "$evidence"
  fm_independence_record pool "$pool" "$pool_why" "$evidence"

  # The overall verdict is the WEAKEST dimension, on the same asymmetry every
  # fold in this file obeys. Any observed not-independent dimension makes the
  # whole verdict not-independent and no unresolved sibling dimension may erase
  # it: a checker PROVEN to have drawn on the maker's own credential pool is a
  # finding, and reporting it as "could not observe" because the vendor mapping
  # was missing would launder it into the milder word. Could-not-observe applies
  # only when nothing was observed dependent - a checker proven to run its own
  # model still tells a reader nothing about whose account paid for it, so that
  # may never read as plain "independent" either.
  overall=$(fm_independence_overall_of "$process" "$model" "$vendor" "$pool")
  fm_independence_record overall "$overall" \
    "process=$(fm_independence_label "$process") model=$(fm_independence_label "$model") vendor=$(fm_independence_label "$vendor") pool=$(fm_independence_label "$pool")" \
    "$evidence"
}

# fm_independence_from_record <summary> <evidence>
# Print the same block fm_independence_dimensions prints, read back from the
# compact per-dimension summary a terminal task record already carries.
#
# THIS IS NOT A WRITABLE INDEPENDENCE CLAIM, and the difference is the whole
# point. The summary was DERIVED by this library from the pipeline's invocation
# records at teardown - the last moment the join existed - and appended to
# bin/fm-wake-ledger.sh's append-only evidence record. Reading it back is
# reading an authoritative record of what was observed about those exact bytes.
# No caller may hand this value in from outside that record: bin/fm-certify.sh
# takes no argument that carries it, and a fleet that let one exist would be
# back to the stated independence claim this seam closed.
#
# A word the summary does not carry - "unknown", or a dimension it never
# recorded at all - is could-not-observe. It is NEVER filled in from anywhere
# else: a value guessed for a torn-down task would be indistinguishable from an
# observed one afterwards.
fm_independence_from_record() {  # <summary> <evidence>
  local summary=${1:-} evidence=${2:-} dim value result overall pass_word fail_word
  local process=NO_VERIFIER_RAN model=NO_VERIFIER_RAN vendor=NO_VERIFIER_RAN pool=NO_VERIFIER_RAN

  # The words come from the owner that wrote them rather than being restated, so
  # renaming a value cannot silently stop this reader recognizing it.
  pass_word=$(fm_independence_label PASS)
  fail_word=$(fm_independence_label FAIL)

  while IFS=: read -r dim value; do
    [ -n "$dim" ] || continue
    case "$value" in
      "$pass_word") result=PASS ;;
      "$fail_word") result=FAIL ;;
      *) result=NO_VERIFIER_RAN ;;
    esac
    case "$dim" in
      process) process=$result ;;
      model) model=$result ;;
      vendor) vendor=$result ;;
      pool) pool=$result ;;
    esac
  done <<EOF
$(printf '%s' "$summary" | tr '+' '\n')
EOF

  fm_independence_record process "$process" "$(fm_independence_recorded_why "$process")" "$evidence"
  fm_independence_record model "$model" "$(fm_independence_recorded_why "$model")" "$evidence"
  fm_independence_record vendor "$vendor" "$(fm_independence_recorded_why "$vendor")" "$evidence"
  fm_independence_record pool "$pool" "$(fm_independence_recorded_why "$pool")" "$evidence"
  overall=$(fm_independence_overall_of "$process" "$model" "$vendor" "$pool")
  fm_independence_record overall "$overall" \
    "process=$(fm_independence_label "$process") model=$(fm_independence_label "$model") vendor=$(fm_independence_label "$vendor") pool=$(fm_independence_label "$pool")" \
    "$evidence"
}

# The reason a dimension read back from a durable record carries. It always says
# WHERE the value came from, so a reader can never mistake a record of an old
# observation for a fresh one made against the bytes in front of them.
fm_independence_recorded_why() {  # <PASS|FAIL|NO_VERIFIER_RAN>
  case "${1:-}" in
    PASS|FAIL)
      printf 'the durable terminal record for these bytes derived this dimension as %s' \
        "$(fm_independence_label "$1")"
      ;;
    *)
      printf 'the durable terminal record for these bytes carries no observation of this dimension'
      ;;
  esac
}

# fm_independence_overall <records>: echo the overall three-valued result from a
# block fm_independence_dimensions printed.
fm_independence_overall() {
  printf '%s\n' "${1:-}" | sed -n 's/^  independence-overall,\([A-Z_]*\),.*/\1/p' | head -1
}

# fm_independence_each_dimension <records> [unobserved-word]
# Echo one TSV row per DIMENSION record in a block this file printed, never the
# overall one:
#
#   <dimension>\t<result>\t<label>\t<reason>
#
# THE RECORD SHAPE IS PARSED HERE AND NOWHERE ELSE. Three consumers wanted the
# same walk - the certification command's human render, the ledger's compact
# per-task field, and the gap list below - and each had written its own copy of
# "iterate the independence- lines, strip the prefix, skip overall, map the
# result onto a word". That is three places to update when the shape moves and
# three places for a fourth word to appear for a value this library already
# named, which is the same reason the label mapping itself was centralised.
# Consumers format this output; they no longer read the record.
#
# The optional unobserved word is passed through to fm_independence_label, which
# owns which of the three values a caller may rename and which it may not.
fm_independence_each_dimension() {  # <records> [unobserved-word]
  printf '%s\n' "${1:-}" | awk -F, \
    -v pass="$(fm_independence_label PASS)" \
    -v fail="$(fm_independence_label FAIL)" \
    -v unobserved="$(fm_independence_label NO_VERIFIER_RAN "${2:-}")" '
    /^  independence-/ {
      dim = $1
      sub(/^  independence-/, "", dim)
      if (dim == "overall") next
      label = ($2 == "PASS" ? pass : ($2 == "FAIL" ? fail : unobserved))
      printf "%s\t%s\t%s\t%s\n", dim, $2, label, $3
    }'
}

# fm_independence_gaps <records>: echo the dimensions that are not independent,
# each as "<dimension>:<label>", so a refusal can NAME what could not be
# established instead of reporting a generic failure.
fm_independence_gaps() {
  fm_independence_each_dimension "${1:-}" | awk -F'\t' '$2 != "PASS" { print $1 ":" $3 }'
}
