#!/usr/bin/env bash
# Quarterdeck: the structural verifier stage between a crewmate's `done:` claim
# and firstmate's acceptance. Spec: docs/specs/2026-07-01-agent-os-council.md.
#
# `done:` is a claim, not an acceptance. fm-verify.sh, run by firstmate when a
# ship task reports done:
#   1. adjudicates the worktree's gate ledger STRUCTURALLY, before either model
#      runs (fm_gates_classify in fm-gates-lib.sh) - see "gate adjudication"
#   2. snapshots the crewmate's diff        -> data/<id>/lens-diff.patch
#   3. runs the foreign lens on it          -> data/<id>/lens-review.md
#      (chain: FM_LENS_CMD > Fugu > codex > none - degrades loudly, never silently)
#   4. spawns an independent fresh-context verifier (default-REJECT) in the
#      crewmate's worktree                  -> data/<id>/verify-report.md
#   5. appends the decision to state/<id>.verdict (fm-verdict-lib grammar);
#      fm-merge-local/fm-pr-check refuse without a trailing approve.
#   6. on reject: relays findings to the crewmate (FM_RELAY_CMD, default
#      fm-send.sh); after FM_VERIFY_MAX_ATTEMPTS (default 3) rejects, escalates.
#
# GATE ADJUDICATION IS NOT THE MODEL'S JOB. It used to be: the verifier prompt
# said "every gate must be green; red or unproven gates are an automatic
# reject", which is unsatisfiable in any repo holding a declared red - and this
# one holds two. Whether correct work was accepted then depended on whether the
# LLM happened to reason about gates/accepted-red.md on that run. The rule now
# has one implementation, fm_gates_classify, and it runs in front of the lens
# and the verifier so an unacceptable ledger costs neither model. The prompt no
# longer states a gate rule at all; a second authority over one decision is what
# produced the contradiction.
#
# Fail closed: verifier won't run / emits no VERDICT line -> escalate, never
# approve. Non-ship tasks (scout/secondmate) skip in Phase 1.
#
# Seams: FM_VERIFY_CMD  verifier command; gets the prompt as $1, cwd=worktree,
#                       stdout must end with "VERDICT: approve|reject|escalate - reason"
#                       (default: claude -p --permission-mode bypassPermissions)
#        FM_LENS_CMD    lens command; diff on stdin, review on stdout
#        FM_RELAY_CMD   reject relay; default bin/fm-send.sh (word-split)
#        FM_VERIFY_FETCH_TIMEOUT
#                       seconds allowed for the one origin fetch that resolves
#                       the authorisation base (default 30); the cap is skipped
#                       where no timeout(1)/gtimeout exists, so the env guards
#                       in fetch_default_branch are what remove the hang
# Exit: 0 approve or skip, 2 reject, 3 escalate, 1 usage error.
# Usage: fm-verify.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-verdict-lib.sh
. "$SCRIPT_DIR/fm-verdict-lib.sh"
# shellcheck source=bin/fm-lens-lib.sh
. "$SCRIPT_DIR/fm-lens-lib.sh"
# shellcheck source=bin/fm-gates-lib.sh
. "$SCRIPT_DIR/fm-gates-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

ID=${1:?usage: fm-verify.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "${KIND:-ship}" != ship ]; then
  echo "skip: task $ID kind=${KIND:-?} (Quarterdeck verifies ship tasks only in Phase 1)"
  exit 0
fi

WORKTREE=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2-)
[ -d "$WORKTREE" ] || { echo "error: worktree $WORKTREE missing for task $ID" >&2; exit 1; }
BRIEF="$DATA/$ID/brief.md"
mkdir -p "$DATA/$ID"

MAX=${FM_VERIFY_MAX_ATTEMPTS:-3}

# Already at the cap before this run? Straight to the captain, no more spins.
if [ "$(fm_verdict_reject_count "$STATE" "$ID")" -ge "$MAX" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($MAX rejects); captain decision required"
  echo "escalate: task $ID at attempt cap ($MAX rejects)" >&2
  exit 3
fi

# --- shared reject path -------------------------------------------------------
#
# The structural gate stage and the verifier both reject through here, so the
# attempt count, the verdict line, the relay, and the cap behave identically
# whichever stage found the problem. Two reject paths would drift.
verify_reject() {  # <reason> <findings-pointer>
  local reason=$1 findings=$2 n
  n=$(( $(fm_verdict_reject_count "$STATE" "$ID") + 1 ))
  fm_verdict_append "$STATE" "$ID" reject "(attempt $n of $MAX) $reason"
  # shellcheck disable=SC2086 # FM_RELAY_CMD is deliberately word-split
  ${FM_RELAY_CMD:-"$SCRIPT_DIR/fm-send.sh"} "fm-$ID" \
    "QUARTERDECK REJECTED (attempt $n of $MAX): $reason. Findings: $findings. Fix and append a fresh done: line." \
    || echo "warning: could not relay reject to fm-$ID (window gone?)" >&2
  if [ "$n" -ge "$MAX" ]; then
    fm_verdict_append "$STATE" "$ID" escalate "attempt cap reached ($n rejects); captain decision required"
    echo "escalate: task $ID hit the attempt cap ($n of $MAX)" >&2
    exit 3
  fi
  echo "reject: task $ID (attempt $n of $MAX); findings relayed" >&2
  exit 2
}

verify_escalate() {  # <reason>
  fm_verdict_append "$STATE" "$ID" escalate "$1"
  echo "escalate: task $ID - $1" >&2
  exit 3
}

# TWO BASES, TWO QUESTIONS, TWO POLICIES - and the difference is deliberate.
#
#   FM_AUTH_BASE_*  answers "was this declaration reviewed by somebody other
#                   than the crewmate?" That is a SECURITY question, so it is
#                   origin-only and fails closed. It also scopes ledger debt,
#                   which fails closed the same way.
#   FM_DIFF_BASE_*  answers "how much of this branch should the foreign lens
#                   read?" That is review COVERAGE, not authorisation, so it
#                   keeps the permissive fallback. Narrowing the lens to one
#                   commit because a fetch failed makes the review worse for
#                   every project with no gates/ dir at all - which is most of
#                   them - and buys no safety whatsoever, since nothing is
#                   authorised by the size of a patch file.
default_branch() {
  local ref branch
  ref=$(git -C "$WORKTREE" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then echo "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$WORKTREE" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"; return 0
    fi
  done
  return 1
}

# THE AUTHORISATION BASE IS RESOLVED ONCE, IN THE MAIN BODY, INTO THESE VARIABLES.
# An earlier draft memoized inside a base_ref() that both stages called as
# `$(base_ref)`. A subshell's assignments die with the subshell, so the memo was
# discarded on return every time: the guard was still empty in the parent, both
# call sites took the fresh branch, and the fetch ran twice. Worse, the promise
# that the self-authorisation check and the debt scoping compare against the
# SAME base was false by construction. Assigning in the main body, before either
# consumer runs, is what makes it true.
#
# WHICH candidate wins is a SECURITY question, so the candidates are not equal
# and must not be ranked as though they were. The self-authorisation guard means
# something only if the base is a ref the crewmate does not casually control.
# refs/remotes/origin/<default> takes a push to a protected default branch,
# which prime directive 1 forbids and branch protection normally blocks.
# refs/heads/<default> takes nothing: firstmate's project clones are POOLED, so
# a crewmate worktree shares that ref with the primary checkout, and an ordinary
# local commit - not even a deliberate `git update-ref` - is enough to make a
# declaration the branch wrote itself read as inherited and reviewed.
#
# An earlier round took the candidate whose merge base was FURTHEST FORWARD, so
# that a declaration committed to an unpushed local default would not read as
# forged. That was a usability argument about a guard whose whole purpose is
# security, and it is withdrawn: furthest-forward made the bypass above the
# ORDINARY path rather than an attack. Do not reintroduce it.
#
# So: with an origin, the base is the merge base against origin/<default> and
# nothing else. A failed fetch falls back to an already-present
# origin/<default>, never to the local branch, and an origin/<default> that
# cannot be resolved at all leaves the base UNSET so both of ITS consumers - the
# self-authorisation check and the ledger-debt scoping - fail closed. With no
# origin at all there is no second candidate, so the local default IS the base -
# and fm-verify says out loud that it is only as trustworthy as that branch.
#
# None of that reasoning reaches the DIFF PAYLOAD, which authorises nothing; see
# resolve_diff_base below.
FM_AUTH_BASE_REF=""
FM_AUTH_BASE_COMMIT=""
FM_AUTH_BASE_WHY=""
FM_AUTH_BASE_LOCAL_ONLY=no
FM_DIFF_BASE_REF=""
FM_DIFF_BASE_COMMIT=""

# The fetch is the only network call on the Quarterdeck accept path, and a
# verifier that HANGS is worse than one that escalates: fm-verify is what stands
# between a done: claim and acceptance, so a wedged fetch wedges the task. Guard
# against blocking, not just against failure - an ssh URL for a host absent from
# known_hosts, or an https URL whose credential helper has expired, otherwise
# leaves git waiting on an interactive prompt with no tty to answer it. The env
# guards are what actually remove the hang; the wall-clock cap is defence in
# depth and is skipped where no timeout(1) exists (macOS ships none by default).
#
# ONE invocation, with the cap as a prefix array. Spelled out as two arms, the
# no-timeout(1) arm - the DEFAULT one on macOS - silently drifts from the other
# the first time the refspec or the http tuning is edited. `${pre[@]+...}` is
# the bash 3.2 safe form for expanding a possibly-empty array under `set -u`.
FM_VERIFY_SSH_BATCH='ssh -oBatchMode=yes -oConnectTimeout=10'
fetch_default_branch() {
  local default=$1 secs=${FM_VERIFY_FETCH_TIMEOUT:-30}
  local pre=()
  if command -v timeout >/dev/null 2>&1; then
    pre=(timeout "$secs")
  elif command -v gtimeout >/dev/null 2>&1; then
    pre=(gtimeout "$secs")
  fi
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$FM_VERIFY_SSH_BATCH" \
    ${pre[@]+"${pre[@]}"} git -C "$WORKTREE" \
      -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 \
      fetch origin "+refs/heads/$default:refs/remotes/origin/$default" \
      --quiet >/dev/null 2>&1 || true
}

# Leaves FM_AUTH_BASE_REF/FM_AUTH_BASE_COMMIT empty when no REVIEWED base is
# resolvable, with FM_AUTH_BASE_WHY naming the step that failed. Both of its
# consumers then fail closed: the gate stage escalates over a declaration it
# cannot check, and the debt scoping treats every offending gate as this
# branch's own.
resolve_auth_base() {
  local default cand mb
  if ! default=$(default_branch); then
    FM_AUTH_BASE_WHY="no default branch could be determined for that worktree"
    return 0
  fi
  if git -C "$WORKTREE" remote get-url origin >/dev/null 2>&1; then
    fetch_default_branch "$default"
    cand="refs/remotes/origin/$default"
  else
    FM_AUTH_BASE_LOCAL_ONLY=yes
    cand="refs/heads/$default"
  fi
  if ! git -C "$WORKTREE" rev-parse --verify --quiet "$cand^{commit}" >/dev/null 2>&1; then
    if [ "$FM_AUTH_BASE_LOCAL_ONLY" = yes ]; then
      FM_AUTH_BASE_WHY="$cand could not be resolved, and there is no origin remote to fall back to"
    else
      FM_AUTH_BASE_WHY="$cand could not be resolved - the fetch did not succeed and no cached copy exists - and refs/heads/$default is not a reviewed base while an origin remote exists, because a pooled clone shares that ref with the primary checkout"
    fi
    return 0
  fi
  if ! mb=$(git -C "$WORKTREE" merge-base HEAD "$cand" 2>/dev/null) || [ -z "$mb" ]; then
    FM_AUTH_BASE_WHY="HEAD and $cand share no merge base"
    return 0
  fi
  FM_AUTH_BASE_REF=$cand
  FM_AUTH_BASE_COMMIT=$mb
}
resolve_auth_base

if [ "$FM_AUTH_BASE_LOCAL_ONLY" = yes ] && [ -n "$FM_AUTH_BASE_REF" ]; then
  echo "base: $WORKTREE has no origin remote, so the base is $FM_AUTH_BASE_REF - for a local-only project the base is only as trustworthy as the local default branch"
fi

# The DIFF PAYLOAD base. This one decides how much of the branch the foreign lens
# gets to read, and a patch file authorises nothing, so the origin-only rule
# above deliberately does NOT apply here. Tying the lens to the authorisation
# base meant that an origin which merely could not be REACHED - offline, or a
# remote-tracking ref never fetched - silently cut the review down to `git show
# HEAD`, the top commit alone, for every project including the majority that
# have no gates/ dir at all. Worse review, identical safety.
#
# So: origin/<default> when it resolved, else the merge base with the local
# default, else HEAD only - and the degradation is said OUT LOUD on stdout, not
# left inside the patch file where no operator reads it.
resolve_diff_base() {
  local default mb
  if [ -n "$FM_AUTH_BASE_COMMIT" ]; then
    FM_DIFF_BASE_REF=$FM_AUTH_BASE_REF
    FM_DIFF_BASE_COMMIT=$FM_AUTH_BASE_COMMIT
    return 0
  fi
  default=$(default_branch) || return 0
  git -C "$WORKTREE" show-ref --verify --quiet "refs/heads/$default" || return 0
  mb=$(git -C "$WORKTREE" merge-base HEAD "refs/heads/$default" 2>/dev/null) || return 0
  [ -n "$mb" ] || return 0
  FM_DIFF_BASE_REF="refs/heads/$default"
  FM_DIFF_BASE_COMMIT=$mb
}
resolve_diff_base

if [ -z "$FM_AUTH_BASE_COMMIT" ]; then
  if [ -n "$FM_DIFF_BASE_COMMIT" ]; then
    echo "diff: no reviewed base for the lens payload (${FM_AUTH_BASE_WHY:-no base branch is resolvable there}), so the diff is taken against $FM_DIFF_BASE_REF - untrusted as an authorisation base, but it still shows the whole branch"
  else
    echo "diff: no base branch is resolvable at all (${FM_AUTH_BASE_WHY:-unknown reason}), so the foreign lens sees the HEAD commit ONLY, not the whole branch"
  fi
fi

# --- 1. gate ledger adjudication (structural, ahead of both models) -----------
#
# Which way each condition fails, and why:
#
#   no gates/ dir            NOT APPLICABLE - proceed. Most projects firstmate
#                            ships to have no gate ledger at all; escalating on
#                            a missing file would stop every one of them.
#   red, declared with a
#     reason in accepted-red PROCEED. That is the whole point of the baseline.
#   red, undeclared          REJECT. Crewmate-actionable: make the gate green,
#                            or get its red declared. The kind of finding a
#                            fresh `done:` can answer.
#   gates/ but no
#     accepted-red.md        No declarations exist, so every red is undeclared
#                            by construction and rejects on the line above. A
#                            fully green ledger with no accepted-red.md is fine.
#   test_ref names a file
#     that is not on disk    REJECT, if this branch TOUCHED that gate. A ledger
#                            claiming green for a gate whose test no longer
#                            exists is stale by construction. This proves only
#                            that the ledger is not pointing at deleted tests -
#                            NOT that any test passes. Proving that is CI's job,
#                            and re-running the suite here would duplicate it at
#                            the most expensive moment. Untouched, it is
#                            REPORTED as pre-existing debt - see "whose debt".
#   gates/ but no ledger     ESCALATE, if gates/ holds gate machinery
#                            (verify.sh or accepted-red.md): the repo declares
#                            itself gate-governed and the record of what is
#                            proven is gone. Infrastructure, not work. With
#                            neither, "gates" is just a directory name and this
#                            is NOT APPLICABLE - proceed.
#   unreadable ledger        ESCALATE. Same reason: a parse failure is not a
#                            finding a crewmate can fix by editing code.
#   unproven status          REJECT, if this branch TOUCHED that gate.
#                            Crewmate-actionable, and ordinary: the harness
#                            stamps unproven whenever a gate test passes while
#                            first_observed_red is null (CONTRIBUTING.md). The
#                            fix is to let `ledger verify` observe the gate red,
#                            which is work, not a human decision. Untouched, it
#                            is REPORTED as pre-existing debt.
#   unrecognised status      ESCALATE. Never a pass, and not a work defect - a
#                            ledger this repo cannot interpret needs a human.
#   a declared red whose
#     declaration this
#     branch added itself    ESCALATE. See "self-authorised reds" below.
#
# gates/verify.sh is deliberately never invoked: `ledger verify` re-runs every
# gate, REWRITES the ledger inside the crewmate's worktree, and is absent in CI.
#
# The classifier writes its refusal reason - which gate, which field - to stderr
# and leaves stdout to the classification itself, so that reason is captured
# here rather than let past the operator. It is a diagnostic, not a
# classification: if the capture fails, BADLEDGER is still BADLEDGER, just
# without the detail.
GATE_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-verify-gates.XXXXXX" 2>/dev/null) || GATE_ERR=/dev/null
GATE_RAW=$(fm_gates_classify "$WORKTREE" 2>"$GATE_ERR")
GATE_HEADER=$(printf '%s\n' "$GATE_RAW" | head -1)
GATE_ROWS=$(printf '%s\n' "$GATE_RAW" | tail -n +2)
# The last non-empty line: a raised SystemExit is that line on its own, while a
# JSON parse error ends its traceback with the message. Either way one line.
GATE_WHY=$(sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' "$GATE_ERR" 2>/dev/null \
  | grep -v '^$' | tail -1)
[ "$GATE_ERR" = /dev/null ] || rm -f "$GATE_ERR"

case "$GATE_HEADER" in
  NOGATES)
    echo "gates: no gates/ dir in $WORKTREE - gate adjudication not applicable"
    ;;
  NOLEDGER)
    # A DIRECTORY NAMED gates/ IS NOT A CLAIM OF GATE GOVERNANCE. "gates" is an
    # ordinary directory name - a Go package, a Python module, a state-machine
    # dir - and fm-verify runs against every ship task in every project
    # firstmate manages. Escalating on the name alone conscripts unrelated
    # repos into a captain escalation on every single task, with no
    # crewmate-side remedy and no override short of FM_VERIFY_OVERRIDE.
    #
    # What claims gate governance is the machinery, not the name: gates/verify.sh,
    # gates/accepted-red.md, or gates/LEDGER.md. With one of those present and no
    # ledger, the record of what is proven really is gone and the fail-closed
    # escalation is right. With none, this is somebody else's gates/ dir and gate
    # adjudication simply does not apply.
    #
    # LEDGER.md earns its place in that set rather than padding it: CONTRIBUTING.md
    # records that `ledger verify` REGENERATES it, so it exists in every
    # gate-governed repo, whereas a repo with no declared reds legitimately has no
    # accepted-red.md and gates/verify.sh is a firstmate convention rather than
    # something the CLI creates. Without it, a gate-governed repo holding only
    # ledger.json + LEDGER.md whose ledger.json went missing proceeded SILENTLY -
    # the exact fail-open this test exists to prevent. It also cannot re-conscript
    # an unrelated Go or Python gates/ package, which will not contain it.
    #
    # This is POLICY, so it lives here. bin/fm-gates-lib.sh still reports
    # NOLEDGER for the same input: its headers are a shared contract with
    # tests/run-all.sh, which has its own answer (skip nothing, out loud).
    if [ -f "$WORKTREE/gates/verify.sh" ] || [ -f "$WORKTREE/gates/accepted-red.md" ] \
        || [ -f "$WORKTREE/gates/LEDGER.md" ]; then
      verify_escalate "gates/ in $WORKTREE holds gate machinery (verify.sh, accepted-red.md or LEDGER.md) but gates/ledger.json does not exist - nothing can be proven about the gates in that repo; fail closed"
    fi
    echo "gates: $WORKTREE has a gates/ dir with no ledger, no verify.sh, no accepted-red.md and no LEDGER.md - not a gate-governed repo, so gate adjudication is not applicable"
    ;;
  BADLEDGER)
    verify_escalate "gates/ledger.json in $WORKTREE is unreadable or the wrong shape${GATE_WHY:+: $GATE_WHY} - gate state cannot be classified; fail closed"
    ;;
  OK | NOACCEPTED)
    ;;
  *)
    # The header set is a cross-file contract, documented under "Headers:" in
    # bin/fm-gates-lib.sh. Anything outside it means this script and that
    # library disagree about what was said - a version skew, or a corrupted
    # capture - and a header nothing here understands carries no rows either.
    # Falling through with empty rows made every awk filter below come back
    # empty and the stage announce "gates: acceptable" over a ledger it had read
    # not one gate from: the accept path claiming a property it never
    # established, which is the fail-open this whole stage exists to remove
    # (the same shape already closed twice in the library, at the non-array
    # coercion and the all-or-nothing row build). So it names what it saw and
    # fails closed.
    verify_escalate "the gate classifier returned a header this script has no rule for: '$GATE_HEADER'${GATE_WHY:+ (stderr: $GATE_WHY)} - the header set is a contract with bin/fm-gates-lib.sh (NOGATES, NOLEDGER, BADLEDGER, NOACCEPTED, OK), so this is either a version skew between the two or a corrupt classification; nothing can be concluded about the gates either way. Ask the classifier directly with: bash $SCRIPT_DIR/fm-gates-lib.sh $WORKTREE. Fail closed"
    ;;
esac

# Positive, not exclusionary: only a header whose rows this stage knows how to
# read reaches it, so a new or unrecognised header cannot arrive here at all.
if [ "$GATE_HEADER" = OK ] || [ "$GATE_HEADER" = NOACCEPTED ]; then
  # Unrecognised statuses first: they mean the ledger says something this repo
  # has no rule for, which no crewmate edit can resolve.
  GATE_UNKNOWN=$(printf '%s\n' "$GATE_ROWS" \
    | awk -F'\t' '$1 == "bad-status" { printf "%s (%s) ", $2, $3 }')
  [ -z "$GATE_UNKNOWN" ] \
    || verify_escalate "gate ledger holds a status this repo has no rule for: ${GATE_UNKNOWN% } - what is acceptable is owned by FM_GATES_CLEAN_STATUSES in bin/fm-gates-lib.sh, and this status is not in it; either the ledger is corrupt, or the status is new and teaching the classifier about it is a deliberate decision. Ask it directly with: bash $SCRIPT_DIR/fm-gates-lib.sh $WORKTREE. Fail closed"

  # SELF-AUTHORISED REDS. A declared red is acceptable because someone REVIEWED
  # the declaration - gates/accepted-red.md calls itself "a deliberate,
  # reviewable statement". A line a branch adds to its own diff has been
  # reviewed by nobody, so a crewmate whose gate will not go green could excuse
  # it simply by writing the excuse, and both this stage and tests/run-all.sh
  # would honour it. So every declaration the ledger actually RELIES on is
  # checked against the merge base.
  #
  # It escalates rather than rejects: adding a baseline is legitimate work, and
  # by that file's own contract approving a new one is the captain's call, not
  # something to bounce back to the crewmate that wrote it.
  #
  # Only RELIED-UPON declarations count. A declaration this branch adds for a
  # gate that is green, or that is not in the ledger at all, excuses nothing.
  #
  # The base is classified with the SAME classifier, over the worktree's own
  # ledger paired with the BASE copy of accepted-red.md, so "was this declared
  # before" is answered by the one owner of the declaration format rather than
  # by a second parser here - which is how the rule came to have three
  # statements in the first place.
  GATE_DECLARED=$(printf '%s\n' "$GATE_ROWS" \
    | awk -F'\t' '$1 == "ok" && $3 == "red" { print $2 }')
  if [ -n "$GATE_DECLARED" ]; then
    gate_base_why=""
    gate_self=""
    gate_base_ref=$FM_AUTH_BASE_REF
    gate_base=$FM_AUTH_BASE_COMMIT
    if [ -z "$gate_base_ref" ] || [ -z "$gate_base" ]; then
      gate_base_why="the reviewed base could not be established (${FM_AUTH_BASE_WHY:-no base branch is resolvable there})"
    elif ! gate_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-verify-base.XXXXXX" 2>/dev/null); then
      gate_base_why="a scratch dir for the base comparison could not be created"
    else
      mkdir -p "$gate_tmp/gates"
      if ! git -C "$WORKTREE" show "${gate_base}:gates/accepted-red.md" \
          > "$gate_tmp/gates/accepted-red.md" 2>/dev/null; then
        gate_base_why="gates/accepted-red.md does not exist at the merge base $gate_base (via $gate_base_ref)"
      elif ! cp "$WORKTREE/gates/ledger.json" "$gate_tmp/gates/ledger.json" 2>/dev/null; then
        gate_base_why="gates/ledger.json could not be read for the base comparison"
      else
        gate_base_raw=$(fm_gates_classify "$gate_tmp" 2>/dev/null)
        if [ "$(printf '%s\n' "$gate_base_raw" | head -1)" != OK ]; then
          gate_base_why="the base copy of gates/accepted-red.md could not be classified"
        else
          # Anything the worktree calls a declared red but the base calls an
          # UNDECLARED red is a declaration this branch introduced.
          #
          # THE DECLARED SET IS AN INPUT FILE, NEVER `awk -v`. awk performs
          # ESCAPE-SEQUENCE processing on a -v assignment, so a gate id holding
          # the two characters \n arrived inside awk as a real newline and split
          # into the two keys "fx" and "red", while the base row still carried
          # the literal backslash. `$2 in d` therefore never matched, gate_self
          # stayed empty, and a declaration this branch wrote into its own diff
          # sailed straight through the one guard that exists to catch it -
          # verified, and the same forgery class as a delimiter in a gate id.
          # Escaping around -v would be one clever id away from the same bug, so
          # the escape processing is removed rather than worked around: awk's
          # two-file idiom reads the set as its FIRST INPUT, and field values
          # read from input are not escape-processed, so both sides of the
          # comparison are byte-exact. The set lives in the scratch dir the base
          # comparison already makes, so the existing rm -rf still removes it on
          # every exit path. GATE_DECLARED is non-empty here, so FNR == NR
          # cannot mistake the first classification row for a declaration.
          printf '%s\n' "$GATE_DECLARED" > "$gate_tmp/declared-red.txt"
          gate_self=$(printf '%s\n' "$gate_base_raw" | tail -n +2 \
            | awk -F'\t' '
                FNR == NR { d[$0] = 1; next }
                $1 == "bad-red" && ($2 in d) { printf "%s ", $2 }' \
              "$gate_tmp/declared-red.txt" -)
        fi
      fi
      rm -rf "$gate_tmp"
    fi

    if [ -n "$gate_base_why" ]; then
      verify_escalate "the gate ledger relies on a red declared in gates/accepted-red.md ($(printf '%s' "$GATE_DECLARED" | tr '\n' ' ')) but $gate_base_why, so whether that declaration was ever reviewed cannot be established; fail closed"
    fi
    if [ -n "$gate_self" ]; then
      verify_escalate "this branch declares its own red gates in gates/accepted-red.md: ${gate_self% } - a declaration a branch adds to its own diff has been reviewed by nobody, and accepting a new red baseline is a captain decision (compared against merge base $gate_base via $gate_base_ref; if that base is behind the real one, the declaration was inherited rather than written here)"
    fi
  fi

  # WHOSE DEBT IS IT? The two conditions below - an unproven gate, and a
  # test_ref naming a file that is not on disk - are invisible to CI. run-all.sh
  # iterates tests/*.test.sh ON DISK, so a ledger citing a deleted test never
  # fails the suite, and an unproven gate's test passes by definition. So a repo
  # carrying either as pre-existing debt used to reject EVERY ship task
  # dispatched into it: three relays the crewmate could not act on, then a
  # captain escalation, while the pipeline and CI stayed green. That is the same
  # "correct work rejected at the most expensive moment" this stage exists to
  # remove, only deterministic instead of random.
  #
  # So both are scoped to what THIS BRANCH is responsible for. A gate is this
  # branch's when the diff against the reviewed base touches it: its entry in
  # gates/ledger.json changed, or the test file its test_ref names is in the
  # diff (a DELETED test shows up there, which is exactly the case that must
  # still reject). Anything else is pre-existing debt: reported in this stage's
  # output, never rejected, because the crewmate cannot act on it.
  #
  # It stays fail-closed where it must: if the base, the diff, or the base copy
  # of the ledger cannot be read, scope is UNKNOWN and every offending gate is
  # treated as this branch's own - and the stage SAYS so, on stdout and in the
  # reject text, rather than accusing the branch of touching gates it never saw
  # (see "fail closed must not mean fail dishonest" below). Undeclared reds are
  # deliberately NOT scoped - CI does catch those, because run-all runs an
  # undeclared red gate's test and it fails.
  #
  # The comparison is per ENTRY, not per file. Whole-file granularity would put
  # every gate in scope the moment a branch registered one new gate, which is
  # the ordinary shape of gate-driven work and would leave this scoping doing
  # nothing at all.
  #
  # --no-renames IS LOAD-BEARING, not tidiness. Rename detection is on by
  # default (diff.renames since git 2.9) and prints only the DESTINATION path, so
  # a crewmate who renames a test file and forgets to update the gate's test_ref
  # left the ledger entry unchanged AND the old path invisible - the gate fell
  # out of scope and its staleness was merely reported, in exactly the case the
  # staleness check exists for. With --no-renames a rename appears as both paths,
  # so the old one lands in the scope set.
  gate_scope_known=no
  gate_scope_why=""
  gate_changed_files=""
  gate_touched_ids=""
  if [ -z "$FM_AUTH_BASE_COMMIT" ]; then
    gate_scope_why="the reviewed base could not be established (${FM_AUTH_BASE_WHY:-no base branch is resolvable there})"
  elif ! gate_tracked=$(git -C "$WORKTREE" diff --name-only --no-renames "$FM_AUTH_BASE_COMMIT" -- 2>/dev/null) \
      || ! gate_untracked=$(git -C "$WORKTREE" ls-files --others --exclude-standard 2>/dev/null); then
    gate_scope_why="the diff against the reviewed base $FM_AUTH_BASE_COMMIT could not be read"
  else
    gate_changed_files=$(printf '%s\n%s\n' "$gate_tracked" "$gate_untracked")
    if gate_base_ledger=$(git -C "$WORKTREE" show "$FM_AUTH_BASE_COMMIT:gates/ledger.json" 2>/dev/null); then
      if gate_touched_ids=$(printf '%s' "$gate_base_ledger" \
          | python3 -c '
import json, sys

# ONLY the fields the scope question actually turns on: status decides unproven,
# test_ref decides staleness. Comparing whole serialized entries put the ENTIRE
# ledger in scope on any ordinary gate-driven branch and left this scoping doing
# nothing, because "ledger verify" re-stamps every gate it RUNS (CONTRIBUTING.md)
# and mandates a re-freeze sweep after any change: commit
# 5709948 of this repo added 39 last_verified lines while adding 2 gates. A gate
# whose only difference is a bookkeeping re-stamp was not touched in any sense
# these two conditions care about, so last_verified, mutation_verified and
# first_observed_red are excluded BY BEING ABSENT from this list. Add a future
# stamp field to the ledger without adding it here.
SCOPE_FIELDS = ("status", "test_ref")

def entries(doc):
    gates = doc.get("gates")
    if not isinstance(gates, list):
        raise SystemExit("base ledger gates is not a JSON array")
    out = {}
    for g in gates:
        if not isinstance(g, dict) or not isinstance(g.get("id"), str):
            raise SystemExit("base ledger holds a gate with no string id")
        out[g["id"]] = json.dumps([g.get(f) for f in SCOPE_FIELDS], sort_keys=True)
    return out

base = entries(json.load(sys.stdin))
head = entries(json.load(open(sys.argv[1])))
for gid in head:
    if base.get(gid) != head[gid]:
        print(gid)
' "$WORKTREE/gates/ledger.json" 2>/dev/null); then
        gate_scope_known=yes
      else
        gate_scope_why="gates/ledger.json at the reviewed base $FM_AUTH_BASE_COMMIT could not be compared with the one in the worktree"
      fi
    else
      # No ledger at the base at all: every gate in this one arrived here.
      gate_touched_ids=$(printf '%s\n' "$GATE_ROWS" | awk -F'\t' '$2 != "" { print $2 }')
      gate_scope_known=yes
    fi
  fi

  # FAIL CLOSED MUST NOT MEAN FAIL DISHONEST.
  #
  # When scope cannot be determined, gate_in_scope answers yes for every gate -
  # which is the right SAFETY behaviour and stays. But it made the stage say
  # things that were not true: nothing on stdout admitted the check had degraded
  # (unlike the diff-base degradation, which this file deliberately announces),
  # and the two rejects below asserted "gates this branch touched" over gates the
  # branch had never seen, while the "(pre-existing and not your responsibility)"
  # qualifier could not appear because the PRE lists are necessarily empty in
  # this state. The crewmate was told it broke something it did not break and
  # sent to fix inherited debt on a false premise - the same "correct work
  # rejected at the most expensive moment" defect this stage exists to remove,
  # reached through the fail-closed door.
  #
  # The path is not exotic: an unresolvable origin/<default> - offline, or a
  # remote-tracking ref never fetched - in a repo whose ledger carries no
  # declared reds skips the self-authorisation escalation entirely, so nothing
  # else stops the run. So the degradation is said out loud, and the reject text
  # says which of the two things it knows: "you broke this", or "we could not
  # tell whose this is, so you are seeing all of it".
  if [ "$gate_scope_known" = yes ]; then
    gate_scope_note=""
    gate_scope_unproven_of="unproven gates this branch touched"
    gate_scope_stale_of="in gates this branch touched"
  else
    echo "gates: which gates THIS branch is answerable for could not be determined - $gate_scope_why - so every unproven gate and every ledger reference to a missing test file is treated as this branch's own (fail closed); inherited debt cannot be told apart from new debt on this run"
    gate_scope_note=" - NOTE: which gates this branch touched could not be established ($gate_scope_why), so every offending gate in the ledger is listed here conservatively and some of them may be pre-existing debt this branch did not create"
    gate_scope_unproven_of="unproven gates"
    gate_scope_stale_of=""
  fi

  # ONE SPELLING OF THE LEDGER'S TEST PATH, FOR EVERY READER OF IT.
  #
  # The scope check compares that path against git's changed-file list BYTE FOR
  # BYTE, while the existence check hands it to the filesystem, which normalizes
  # on its own. Those two disagreed: a ledger writing "bash ./tests/aa.test.sh"
  # yields the token ./tests/aa.test.sh, so `[ -e ]` resolved it and correctly
  # reported the file gone, while the scope grep compared it against git's
  # tests/aa.test.sh and missed - so a test file THIS BRANCH deleted was excused
  # as somebody else's pre-existing debt, a fail-open decided by nothing but how
  # the path happens to be spelled in the ledger. Same class as the rename case:
  # a spelling difference must not let a gate slip out of its own check.
  #
  # So the token is normalized ONCE, here, and every consumer - the scope grep,
  # the existence test, and the operator-facing message - reads the same string.
  # git prints repo-relative paths with no leading ./ and no doubled slashes, so
  # normalizing the ledger side is what makes the two comparable.
  gate_norm_path() {  # <ledger test path> -> git's spelling of the same path
    local p=$1
    # Slashes first, so .//tests/x collapses to ./tests/x and then loses the
    # ./ rather than being left as /tests/x.
    while [ "${p%%//*}" != "$p" ]; do p=${p//\/\//\/}; done
    while [ "${p#./}" != "$p" ]; do p=${p#./}; done
    printf '%s' "$p"
  }

  # gate_in_scope <gate-id> <test-path>: 0 when this branch is answerable for
  # that gate. Unknown scope answers 0 - fail closed, never excuse the lot.
  gate_in_scope() {
    local gid=$1 tref=$2
    [ "$gate_scope_known" = yes ] || return 0
    printf '%s\n' "$gate_touched_ids" | grep -qxF -- "$gid" && return 0
    if [ -n "$tref" ]; then
      printf '%s\n' "$gate_changed_files" | grep -qxF -- "$tref" && return 0
    fi
    return 1
  }

  # `unproven` is a status this repo DOES have a rule for, so it must not take
  # the captain path: CONTRIBUTING.md records that the harness stamps it
  # whenever a gate test passes while first_observed_red is null. The crewmate
  # clears it by letting the gate be observed red, which is work.
  TAB=$(printf '\t')
  GATE_UNPROVEN=""
  GATE_UNPROVEN_PRE=""
  while IFS= read -r gate_row; do
    [ -n "$gate_row" ] || continue
    gid=${gate_row%%"$TAB"*}
    tref=$(gate_norm_path "${gate_row#*"$TAB"}")
    if gate_in_scope "$gid" "$tref"; then
      GATE_UNPROVEN="$GATE_UNPROVEN$gid "
    else
      GATE_UNPROVEN_PRE="$GATE_UNPROVEN_PRE$gid "
    fi
  done <<UNPROVENROWS
$(printf '%s\n' "$GATE_ROWS" | awk -F'\t' '$1 == "bad-unproven" { print $2 "\t" $4 }')
UNPROVENROWS

  GATE_UNDECLARED=$(printf '%s\n' "$GATE_ROWS" \
    | awk -F'\t' '$1 == "bad-red" { printf "%s ", $2 }')

  # Freshness cross-check: every gate must still point at a test that exists.
  #
  # The row is split POSITIONALLY, empty middle fields intact. `IFS=<tab> read`
  # cannot do that - tab is IFS whitespace, so a run of tabs collapses to one
  # delimiter and an empty column simply vanishes. A gate whose test_ref holds
  # no ".test.sh" token has an empty test-path column, so its declared REASON
  # slid left into that field and fm-verify rejected the crewmate over a path
  # the ledger never claimed: the very class of spurious reject this stage
  # exists to remove. awk indexes by position, so an empty test path stays
  # empty and that gate is simply not freshness-checked, which is the only
  # honest answer for a gate this classifier could read no path out of.
  GATE_PATHS=$(printf '%s\n' "$GATE_ROWS" | awk -F'\t' '$4 != "" { print $2 "\t" $4 }')
  GATE_STALE=""
  GATE_STALE_PRE=""
  while IFS= read -r gate_row; do
    [ -n "$gate_row" ] || continue
    gid=${gate_row%%"$TAB"*}
    tref=$(gate_norm_path "${gate_row#*"$TAB"}")
    if [ -e "$WORKTREE/$tref" ]; then continue; fi
    if gate_in_scope "$gid" "$tref"; then
      GATE_STALE="$GATE_STALE$gid -> $tref; "
    else
      GATE_STALE_PRE="$GATE_STALE_PRE$gid -> $tref; "
    fi
  done <<GATEROWS
$GATE_PATHS
GATEROWS

  # Reported before any reject fires, so the operator sees the whole picture -
  # what this branch answers for, and what it merely inherited - whichever way
  # the stage ends.
  GATE_PRE_NOTE=""
  if [ -n "$GATE_UNPROVEN_PRE" ]; then
    GATE_PRE_NOTE="${GATE_PRE_NOTE}unproven: ${GATE_UNPROVEN_PRE% }; "
  fi
  if [ -n "$GATE_STALE_PRE" ]; then
    GATE_PRE_NOTE="${GATE_PRE_NOTE}test file missing: ${GATE_STALE_PRE%; }; "
  fi
  if [ -n "$GATE_PRE_NOTE" ]; then
    echo "gates: pre-existing ledger debt in gates this branch did not touch, reported and NOT rejected: ${GATE_PRE_NOTE%; }"
  fi

  if [ -n "$GATE_UNDECLARED" ]; then
    note=""
    [ "$GATE_HEADER" = NOACCEPTED ] \
      && note=" (this repo has no gates/accepted-red.md, so no red is declared)"
    verify_reject \
      "the gate ledger is red on ${GATE_UNDECLARED% } and that red is not declared in gates/accepted-red.md$note" \
      "gates/ledger.json and gates/accepted-red.md in your worktree; run bash $SCRIPT_DIR/fm-gates-lib.sh $WORKTREE"
  fi

  if [ -n "$GATE_UNPROVEN" ]; then
    verify_reject \
      "the gate ledger holds ${gate_scope_unproven_of}: ${GATE_UNPROVEN% } - an unproven gate has never been observed red, so it proves nothing. Register the gate while its test genuinely fails and let ledger verify stamp first_observed_red itself, rather than hand-writing that timestamp${GATE_UNPROVEN_PRE:+ (pre-existing and not your responsibility: ${GATE_UNPROVEN_PRE% })}${gate_scope_note}" \
      "gates/ledger.json in your worktree, and CONTRIBUTING.md on born-green gates; run bash $SCRIPT_DIR/fm-gates-lib.sh $WORKTREE"
  fi

  if [ -n "$GATE_STALE" ]; then
    verify_reject \
      "the gate ledger references test files that do not exist on disk${gate_scope_stale_of:+, $gate_scope_stale_of}: ${GATE_STALE%; } - a ledger citing deleted tests is stale by construction${GATE_STALE_PRE:+ (pre-existing and not your responsibility: ${GATE_STALE_PRE%; })}${gate_scope_note}" \
      "gates/ledger.json in your worktree; run bash $SCRIPT_DIR/fm-gates-lib.sh $WORKTREE"
  fi

  if [ -n "$GATE_PRE_NOTE" ]; then
    echo "gates: acceptable for this branch (every gate green, frozen, or a declared red; pre-existing debt noted above)"
  else
    echo "gates: acceptable (every gate green, frozen, or a declared red)"
  fi
fi

# --- 2. diff payload ---------------------------------------------------------
DIFF_FILE="$DATA/$ID/lens-diff.patch"
{
  if [ -n "$FM_DIFF_BASE_COMMIT" ]; then
    git -C "$WORKTREE" log --oneline "$FM_DIFF_BASE_COMMIT..HEAD"
    git -C "$WORKTREE" diff "$FM_DIFF_BASE_COMMIT..HEAD"
  else
    echo "(no base branch resolvable; showing HEAD commit only)"
    git -C "$WORKTREE" show HEAD
  fi
} | head -c 200000 > "$DIFF_FILE"

# --- 3. foreign lens: shared chain (fm-lens-lib.sh) ----------------------------
LENS_REVIEW="$DATA/$ID/lens-review.md"
LENS_PROMPT="You are a hostile senior reviewer. Roast this diff before it ships: correctness bugs, untested claims, security holes, scope drift. Be specific (file:line). End with the findings that most deserve a reject, or 'no blocking findings'."

LENS=$(fm_lens_run "$DIFF_FILE" "$LENS_REVIEW" "$LENS_PROMPT" fugu "$WORKTREE" "task $ID")
fm_verdict_append "$STATE" "$ID" lens "$LENS $(head -c 120 "$LENS_REVIEW" | tr '\n' ' ')"

# --- 4. independent verifier (fail closed) -------------------------------------
REPORT="$DATA/$ID/verify-report.md"
VERIFY_CMD=${FM_VERIFY_CMD:-claude -p --permission-mode bypassPermissions}

BRIEF_TEXT="(no brief found at $BRIEF)"
[ -f "$BRIEF" ] && BRIEF_TEXT=$(cat "$BRIEF")
# NO APOSTROPHES IN THIS HEREDOC BODY. It is an unquoted heredoc inside a
# command substitution, and bash re-scans that body when the substitution runs:
# a lone ' opens a quote it never closes, and the script dies at runtime with
# "unexpected EOF while looking for matching '" pointing at a line well past the
# heredoc. `bash -n` does NOT catch it. Verified: adding the single word
# "repo's" here made fm-verify exit 2 mid-run. Write "the ledger in this repo",
# never "this repo's ledger". The heredoc must stay unquoted so $BRIEF_TEXT,
# $LENS and $(cat "$LENS_REVIEW") still expand.
PROMPT=$(cat <<EOF
You are the Quarterdeck verifier: a fresh-context independent checker. The
crewmate for task $ID claims done. Default stance: REJECT until proven.
Never trust what the crewmate says - re-run everything yourself from this
worktree ($WORKTREE, branch fm/$ID).

Checklist:
1. Re-prove each claim in the definition of done below by EXECUTING it (run the
   tests, run the command, read the diff), not by trusting the report the crewmate wrote.
2. Weigh the foreign-lens review below; confirm or dismiss each finding.
3. No cheating: confirm tests were not weakened, skipped, or deleted, and the
   diff stays inside the assigned scope.

Out of scope for you: whether the gate ledger in this repo is acceptable. That
was already adjudicated structurally, before you were spawned, by
fm_gates_classify in bin/fm-gates-lib.sh - the only authority on it. Do not
re-derive, restate, or override that rule, and do not run gates/verify.sh: it
re-runs every gate and rewrites the ledger in this worktree. A red gate
declared in gates/accepted-red.md is accepted on purpose and is not a finding.
You may still check that the tests THIS task claims to have added or changed
actually pass.

# The task brief
$BRIEF_TEXT

# Foreign-lens review (lens=$LENS)
$(cat "$LENS_REVIEW")

Your reply MUST end with exactly one line, nothing after it:
VERDICT: approve - <one-line reason>
VERDICT: reject - <the concrete failure a fix must address>
VERDICT: escalate - <why a human must decide>
EOF
)

verdict_kind=""
verdict_reason=""
if (cd "$WORKTREE" && sh -c "$VERIFY_CMD \"\$1\"" _ "$PROMPT") > "$REPORT" 2>&1; then
  line=$(grep -E '^VERDICT: (approve|reject|escalate)' "$REPORT" | tail -1 || true)
  if [ -n "$line" ]; then
    verdict_kind=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate).*$/\1/')
    verdict_reason=$(printf '%s' "$line" | sed -E 's/^VERDICT: (approve|reject|escalate)[^A-Za-z0-9]*//')
  fi
fi
if [ -z "$verdict_kind" ]; then
  fm_verdict_append "$STATE" "$ID" escalate "verifier infrastructure failure (no VERDICT line; see data/$ID/verify-report.md) - fail closed"
  echo "escalate: verifier produced no verdict for $ID (see $REPORT)" >&2
  exit 3
fi

# --- 5. record + route ----------------------------------------------------------
case "$verdict_kind" in
  approve)
    fm_verdict_append "$STATE" "$ID" approve "${verdict_reason:-verifier approve} (lens=$LENS)"
    echo "approve: task $ID verified (lens=$LENS)"
    exit 0
    ;;
  escalate)
    fm_verdict_append "$STATE" "$ID" escalate "${verdict_reason:-verifier escalate}"
    echo "escalate: task $ID needs the captain (see $REPORT)" >&2
    exit 3
    ;;
  reject)
    verify_reject "${verdict_reason:-verifier reject}" \
      "data/$ID/verify-report.md and data/$ID/lens-review.md"
    ;;
esac
