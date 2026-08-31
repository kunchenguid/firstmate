#!/usr/bin/env bash
# fm-gates-lib.sh - the one place that answers "is this gate's state acceptable?"
#
# THE RULE HAS ONE OWNER. It used to have three: tests/run-all.sh implemented
# it, bin/fm-verify.sh's verifier prompt contradicted it ("every gate must be
# green; red or unproven gates are an automatic reject"), and fm-brief.sh's
# GATE_CHECK clause restated it a third way. The ledger legitimately holds
# declared reds, so "every gate must be green" is unsatisfiable by construction:
# whether a task was accepted depended on whether the LLM verifier happened to
# reason its way to gates/accepted-red.md on that particular run. Correct work
# was rejected at random, at the most expensive possible moment - after the
# build, the pipeline, and CI. This file is that rule's only implementation;
# every other statement of it is now a citation.
#
# CLASSIFICATION IS NOT POLICY. This library only classifies, per gate:
# acceptable or not, and why. What to DO about it belongs to the caller -
# tests/run-all.sh skips a test, bin/fm-verify.sh rejects or escalates. Folding
# either caller's needs in here is how one caller's policy quietly bends the
# other's rule.
#
# IT IS PURE. It reads exactly two files under <root> - gates/ledger.json and
# gates/accepted-red.md - and writes nothing there at all. It must NEVER invoke
# gates/verify.sh or the `ledger` CLI: `ledger verify` re-runs every gate's
# test, REWRITES gates/ledger.json and gates/LEDGER.md in the worktree it is
# pointed at, exits 2 when the CLI is absent (as it is in CI), and demotes
# frozen gates to green as a side effect. A classifier that mutates the thing it
# is classifying is not a classifier. The root is always an ARGUMENT; nothing
# here assumes the caller's own repo.
#
# THE DOUBLE CONDITION. A red gate's test is excused only when BOTH hold:
#
#   1. the gate's status is "red" in gates/ledger.json, AND
#   2. the gate's id is listed in gates/accepted-red.md, with a stated reason
#
# Excusing on (1) alone would mask a real regression the moment a working gate
# went red. Excusing on (2) alone would let a stale declaration silence a test
# that had since been fixed. Requiring both means every excused red is someone's
# reviewed, written-down decision about a gate that is actually red today.
# gates/accepted-red.md is the canonical prose statement of why; this is its
# canonical implementation.
#
# FAIL CLOSED. An unreadable ledger, an unparseable accepted-red.md, or a status
# this file does not recognise is never quietly acceptable. It is reported as
# such and each caller decides which way to fail - but never toward "fine".
#
# Usage:
#   . bin/fm-gates-lib.sh            # library
#   fm_gates_classify <root>
#   bash bin/fm-gates-lib.sh <root>  # CLI: same output; exit 0 acceptable,
#                                    # 1 unacceptable, 2 cannot tell
#
# Output of fm_gates_classify: a HEADER line, then (for OK/NOACCEPTED) one
# tab-separated row per gate:
#
#   <verdict>\t<gate-id>\t<status>\t<test-path>\t<detail>
#
#   verdict     ok | bad-red | bad-unproven | bad-status
#   test-path   the ".test.sh" token from test_ref, or empty. Reported as the
#               ledger records it and NOT stat()ed - checking it is I/O, and
#               belongs to the caller that wants a freshness cross-check.
#   detail      the declared reason for an excused red; why, for a bad verdict.
#
# bad-unproven IS NOT bad-status. CONTRIBUTING.md ("Born-green gates are
# refused") records that the harness itself stamps "unproven" whenever a gate's
# test passes while first_observed_red is null, so it is the ordinary transient
# state of gate-driven development, not a value this repo cannot interpret. It
# is separated out because the two fail in different directions for the caller:
# an unproven gate is something a crewmate can clear by letting `ledger verify`
# observe the gate red, while a status nobody has a rule for is a ledger a human
# has to look at. Collapsing them sent the commonest non-clean status a crewmate
# can produce straight to a captain escalation. It is still NOT acceptable: the
# clean set below is exactly green and frozen, plus a declared red.
#
# Headers:
#   NOGATES     <root>/gates is not a directory. Not applicable; no rows.
#   NOLEDGER    gates/ exists but gates/ledger.json does not. No rows.
#   BADLEDGER   the ledger is unreadable, unparseable, or the wrong shape -
#               including a "gates" value that is not a JSON array, which
#               CONTRIBUTING.md and frozen gate m0-ledger-shape both call fatal,
#               any gate whose id, status, or test path carries a tab or a
#               newline, which would forge a row (see below), and any gate whose
#               id or status is missing or not a JSON string - stringifying
#               those produced the literal "None" as a gate id.
#               No rows - never a partial answer (see ALL OR NOTHING below).
#   NOACCEPTED  the ledger parsed but gates/accepted-red.md is absent, so NO
#               declarations exist. Rows follow, and every red among them is
#               undeclared by construction.
#   OK          both files read. Rows follow.
#
# ALL OR NOTHING. The rows are built whole inside python and written in a single
# call, and the shell emits them only if python exited cleanly. A half-list that
# stopped at a malformed entry looks exactly like a complete answer, and acting
# on one is a fail-open in the one place this file promises to fail closed.
#
# THE BADLEDGER REASON GOES TO STDERR. The parser names what it refused - which
# gate, and which field - and that is the one thing an operator staring at a
# fail-closed escalation needs. It cannot ride stdout: BADLEDGER is the whole
# of stdout by contract, and appending a reason to the header or adding a row
# would be exactly the partial answer above. So the parser diagnostic is simply
# not swallowed, and a caller that wants it redirects fd 2 (bin/fm-verify.sh
# does, into its escalation reason). It is a diagnostic, never a classification:
# a caller that ignores stderr still gets BADLEDGER and still fails closed.

# --- acceptable-on-their-own statuses ---------------------------------------
#
# "green" is proven. "frozen" is proven AND mutation-verified AND locked: it is
# strictly stronger than green, not weaker. CONTRIBUTING.md ("The gate ledger")
# records that `ledger verify` DEMOTES frozen gates to green, so frozen is a
# passing state that green is the fallback from, and `ledger verify`'s own
# definition of done - an empty WIP drain list - excludes frozen gates from the
# drain. gates/LEDGER.md's drain list holds only the reds.
#
# Treating frozen as unacceptable would reject every ship task in this very
# repository: 9 of its 41 gates are frozen today. Anything NOT in this tuple is
# unrecognised and fails closed; the set is deliberately short and explicit so
# adding to it is a visible decision rather than a drift.
FM_GATES_CLEAN_STATUSES='green frozen'

# fm_gates_classify <root>
# Prints the header and rows described above. Returns 0 unless <root> is
# missing (usage error, 1) - the classification itself is carried in the output,
# never in the exit code, because "no gates here" and "every gate is red" are
# both successful classifications with very different policies attached.
fm_gates_classify() {
  local root=${1:-}
  if [ -z "$root" ]; then
    echo "usage: fm_gates_classify <root>" >&2
    return 1
  fi

  local ledger="$root/gates/ledger.json"
  local accepted="$root/gates/accepted-red.md"

  [ -d "$root/gates" ] || { echo NOGATES; return 0; }
  [ -f "$ledger" ]     || { echo NOLEDGER; return 0; }

  # An absent accepted-red.md is not an error: it means no gate has been
  # declared, so the declared set is empty and every red is undeclared. The
  # header still says so, because a caller may want to distinguish "nothing was
  # declared" from "nothing needed declaring".
  local header=OK
  if [ ! -f "$accepted" ]; then
    header=NOACCEPTED
    accepted=""
  fi

  # stderr is deliberately NOT redirected: it carries the parser diagnostic that
  # names the offending gate and field, and swallowing it left BADLEDGER with no
  # reason at the one moment an operator most needs one.
  local out
  if out=$(FM_GATES_CLEAN="$FM_GATES_CLEAN_STATUSES" \
      python3 - "$ledger" "$accepted" <<'PY'
import json, os, re, sys

ledger_path, accepted_path = sys.argv[1], sys.argv[2]
clean = tuple(os.environ.get("FM_GATES_CLEAN", "").split())

# Declared ids: "- <gate-id> - <reason>". The reason is required by
# accepted-red.md's own format, and an entry without one is ignored rather than
# trusted: "an entry with no route back to green is a bug report, not a
# baseline". An empty path means the file is absent, so nothing is declared.
declared = {}
if accepted_path:
    for line in open(accepted_path):
        m = re.match(r"^\s*-\s+(\S+)\s+-\s+(.+?)\s*$", line)
        if m:
            declared[m.group(1)] = m.group(2)

ledger = json.load(open(ledger_path))
gates = ledger["gates"]

# ARRAY OR NOTHING. tests/run-all.sh used to coerce an object-shaped "gates"
# into a list, and lifting that coercion here was a fail-open: {"gates": {}}
# coerced to an empty list, produced zero rows, and classified OK - so
# fm-verify announced "gates: acceptable" over a ledger it had never read a
# single gate from. CONTRIBUTING.md ("The gate ledger") states that gates must
# be a JSON array and that any other shape makes EVERY `ledger` subcommand
# abort before doing any work, and frozen gate m0-ledger-shape freezes exactly
# that. A shape the harness itself calls fatal cannot be something this
# classifier quietly repairs. An EMPTY array is still a valid array: it means a
# ledger with no gates, which is acceptable, not broken.
if not isinstance(gates, list) or not all(isinstance(g, dict) for g in gates):
    raise SystemExit("ledger gates must be a JSON array of objects")

# A tab or newline inside a declared reason would silently shift every field
# after it and turn a fail-closed row into a misread one, so the detail column
# is flattened to spaces. The unabridged reason is always in accepted-red.md.
def flat(s):
    return re.sub(r"[\t\r\n]+", " ", str(s)).strip()

# THE STRUCTURAL FIELDS ARE THE ROW GRAMMAR, SO A DELIMITER IN ONE FORGES A ROW.
# Verified, and it is the whole authority defeated in one line: a gate whose id
# was "evil\nok<TAB>forged<TAB>red<TAB>tests/x.test.sh<TAB>reason" emitted a
# second line that parsed as a perfectly well-formed "this red is declared"
# verdict. tests/run-all.sh then skipped tests/x.test.sh and exited 0 - over an
# all-green ledger, with an accepted-red.md that declared nothing at all. A
# single tab is enough on its own: it shifts the remaining fields left until
# some attacker-chosen text lands in the status column.
#
# Flattening these the way the reason is flattened would keep the row intact but
# leave a mangled id standing in for a real one. Refusing outright is the
# stricter and more honest answer, and it costs nothing: a tab or a newline in a
# gate id, a status, or a test path is never a legitimate ledger. It is the same
# rule as the array check above - a ledger the harness would never accept is not
# one this classifier may quietly repair.
# The refusal covers the field's TYPE as well as its contents. str()-ing a
# missing id yielded the literal "None": two id-less gates collapsed onto one
# key, and an accepted-red.md line "- None - reason" would have excused an
# id-less red. A missing status was worse only by luck - it landed in bad-status
# and escalated - so both are refused here rather than repaired downstream.
# test_ref is refused on TYPE alone, by field_type: a present-but-non-string one
# used to stringify, yield no ".test.sh" token, and leave that gate silently
# exempt from fm-verify's freshness cross-check - a fail-open dressed as a no-op.
# Its CONTENTS are not the row grammar (only the extracted token is), so a
# legitimate multi-word command keeps its whitespace.
def field_type(value, field, index):
    if not isinstance(value, str):
        raise SystemExit(
            "gate #%d: %s must be a string, got %s" % (index, field, type(value).__name__))
    return value

def structural(value, field, index):
    field_type(value, field, index)
    if any(c in value for c in "\t\r\n"):
        raise SystemExit(
            "gate #%d: %s contains a tab or newline, which would forge a row" % (index, field))
    return value

# Built whole, then printed. A raise partway through must yield NO rows at all,
# never a half-list that would look like a complete answer.
rows = []
for i, g in enumerate(gates):
    gid = structural(g.get("id"), "id", i)
    status = structural(g.get("status"), "status", i)

    # test_ref is a shell command ("bash tests/x.test.sh"); take the path token.
    # A MISSING or null test_ref is legitimate and NOT an error: it means this
    # gate simply has no freshness check. Only a present value of the wrong type
    # is refused.
    test_ref = g.get("test_ref")
    if test_ref is None:
        test_ref = ""
    else:
        field_type(test_ref, "test_ref", i)
    test_path = ""
    for tok in test_ref.split():
        if tok.endswith(".test.sh"):
            # The type refusal above plus split() - which breaks on every
            # whitespace character - together make a delimiter in this token
            # impossible. Kept as a belt-and-braces assertion, not as the guard.
            test_path = structural(tok, "test_ref", i)
            break

    if status in clean:
        verdict, detail = "ok", ""
    elif status == "red":
        if gid in declared:
            verdict, detail = "ok", flat(declared[gid])
        else:
            verdict, detail = "bad-red", "red and not declared in gates/accepted-red.md"
    elif status == "unproven":
        # Recognised, and still not acceptable: a gate that has never been seen
        # red proves nothing, which is exactly why the harness refuses to call
        # it green. It gets its own verdict so a caller can route it to the
        # party who can fix it instead of to a human who cannot.
        verdict, detail = "bad-unproven", (
            "unproven: the gate has never been observed red, so it proves nothing yet")
    else:
        verdict, detail = "bad-status", 'unrecognised status "%s"' % status

    rows.append("\t".join((verdict, gid, status, test_path, detail)))

sys.stdout.write("".join(r + "\n" for r in rows))
PY
  ); then
    printf '%s\n' "$header"
    # An `[ -n ] && printf` one-liner here would make the whole statement return
    # 1 whenever there are zero rows, which is a live hazard under a caller
    # running set -e (bin/fm-verify.sh does).
    if [ -n "$out" ]; then printf '%s\n' "$out"; fi
    return 0
  fi
  echo BADLEDGER
  return 0
}

# --- CLI --------------------------------------------------------------------
#
# Exists so a crewmate or a human can ask the same question the machinery asks,
# and get the same answer, without reimplementing it: `bash
# bin/fm-gates-lib.sh <repo-root>`. Exit 0 acceptable, 1 unacceptable, 2 cannot
# tell (no ledger, or an unreadable one).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_gates_raw=$(fm_gates_classify "${1:-.}") || exit 1
  printf '%s\n' "$fm_gates_raw"
  case "$(printf '%s\n' "$fm_gates_raw" | head -1)" in
    NOGATES) exit 0 ;;
    NOLEDGER|BADLEDGER) exit 2 ;;
  esac
  if printf '%s\n' "$fm_gates_raw" | tail -n +2 | grep -q '^bad-'; then
    exit 1
  fi
  exit 0
fi
