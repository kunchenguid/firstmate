#!/usr/bin/env bash
# fm-preflight-lib.sh - the structural half of the Wardroom: refuse a brief that
# asks a crewmate to do something it physically cannot do, BEFORE the spawn
# burns a run.
#
# WHY THIS EXISTS. Three briefs written on 2026-08-28/29 specified impossible
# work, and each would have cost an entire crewmate run:
#
#   1. "Move data/command-center-roadmap.md into docs/" - data/ is gitignored,
#      so the file is not in a worktree at all, and a gitignored file cannot be
#      deleted by a commit.
#   2. "Fix the 68 stale briefs" - same cause; they live under data/ and are
#      invisible to a crewmate.
#   3. "Test the chain under FM_HOME=$(mktemp -d)" - fm-home-seed.sh leases from
#      the LIVE treehouse pool regardless of FM_HOME, so a "test" run silently
#      leaks a durable lease into the captain's pool.
#
# A fourth reached a live crewmate: a brief carrying the retired `>>` status
# redirect, whose reports the permission profile silently refused for ten
# minutes while the pane looked idle.
#
# The intake council caught the first three - but only after a full cycle of two
# thinker lenses and a foreign deep lens. These four defects are STRUCTURAL:
# decidable from the brief text, the project's own ignore rules, and a list of
# known-hazardous commands, with no model in the loop. Deciding them here is both
# cheaper and more reliable than asking three models to notice.
#
# THE REFUSAL NAMES THE OFFENDER. A preflight that says "invalid brief" costs
# another cycle to diagnose, which is the cost it exists to remove. Every
# finding carries the exact path or command and the reason it cannot be done.
#
# FAIL CLOSED, NOT NOISILY WRONG. False refusals are worse than no check at all:
# they train everyone to reach for the override, and then the gate protects
# nothing. So a path that merely RESEMBLES an offender is not a match:
#   - /Users/x/firstmate-notes/a is not under /Users/x/firstmate. The character
#     after the root must be a path separator, not any character.
#   - fm-spawn.sh.bak and my-fm-spawn.sh are not fm-spawn.sh. Both boundaries of
#     the script name are checked.
#   - `bin/fm-spawn.sh` MENTIONED is not `bin/fm-spawn.sh <id> <repo>` RUN. A
#     brief that asks a crewmate to CHANGE one of these scripts is ordinary,
#     legitimate firstmate-on-itself work; see "invocation, not mention" below.
#   - The gitignored rule never guesses: it asks the project's own git, which
#     also answers "tracked, therefore visible" for a path some pattern matches.
# The whole standard scaffold from bin/fm-brief.sh passes. It references the
# primary checkout four times - the status verb, the status file, the
# ensure-AGENTS.md helper, the gates classifier - and every one is sanctioned.
#
# IT CLASSIFIES; THE CALLER DECIDES. Like bin/fm-gates-lib.sh, this library only
# reports findings. What to do about them - refuse a spawn, print a banner,
# honour an override - is bin/fm-spawn.sh's policy, not this file's rule.
#
# IT IS READ-ONLY. It reads the brief and asks the project's git for its ignore
# rules. It writes nothing, anywhere.
#
# Spec: docs/specs/2026-08-31-brief-preflight.md
# Source this, or run the CLI:
#   bash bin/fm-preflight-lib.sh <brief> [<project-dir>] [<task-id>]
#   exit 0 clean, 1 offending.

# fm-home-seed.sh and fm-spawn.sh both take a treehouse lease from the LIVE
# pool, and neither is redirected by FM_HOME - which is what made "test it under
# FM_HOME=$(mktemp -d)" leak a durable lease into the captain's pool.
FM_PREFLIGHT_LEASE_SCRIPTS=${FM_PREFLIGHT_LEASE_SCRIPTS:-"fm-home-seed.sh fm-spawn.sh"}

# --- the roots that count as "the primary checkout" --------------------------
#
# A brief is written by the home that generated it, so that home's own path is
# the one that appears in it. $HOME/firstmate is included unconditionally
# because briefs are also written BY HAND in that conventional form, and a brief
# aimed at the main fleet must be refused even when the preflight runs from a
# secondmate home. Each root is offered both as given and resolved through
# symlinks: fm-brief.sh pins FM_HOME verbatim, while a caller may hand us the
# physical path.
fm_preflight_roots() {
  local r phys seen=""
  for r in "${FM_PREFLIGHT_HOME:-}" "${FM_HOME:-}" "${FM_ROOT:-}" "${HOME:-}/firstmate"; do
    [ -n "$r" ] || continue
    while [ "$r" != / ] && [ "${r%/}" != "$r" ]; do r=${r%/}; done
    case "$seen" in *"|$r|"*) : ;; *) seen="$seen|$r|"; printf '%s\n' "$r" ;; esac
    if [ -d "$r" ] && phys=$(cd "$r" 2>/dev/null && pwd -P); then
      case "$seen" in *"|$phys|"*) : ;; *) seen="$seen|$phys|"; printf '%s\n' "$phys" ;; esac
    fi
  done
}

# --- the text scanner --------------------------------------------------------
#
# Everything decidable from the brief text alone happens in one awk pass: the
# primary-checkout rule, the pool-lease rule, and both halves of the status
# rule. The gitignored rule needs the project's git, so this pass emits only its
# CANDIDATES and the shell resolves them.
#
# Output is TSV, one record per line:
#   FINDING <rule> <offender> <why>
#   CAND    <glob-normalised path> <path as written> <line>
fm_preflight_awk_program() {
  cat <<'AWK'
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

# A name character, for boundary tests. A script name must be preceded and
# followed by something that is not one, so fm-spawn.sh.bak and my-fm-spawn.sh
# are not fm-spawn.sh.
function namechar(c) { return c ~ /^[A-Za-z0-9._-]$/ }

function finding(rule, offender, why) {
  if ((rule SUBSEP offender) in emitted) return
  emitted[rule SUBSEP offender] = 1
  printf "FINDING\t%s\t%s\t%s\n", rule, offender, why
}

# --- "under this root", with a real boundary --------------------------------
# Returns the remainder after "<root>/", "" for the bare root itself, or the
# sentinel SOH for "not under this root". The boundary check is the whole point:
# a bare prefix test makes /Users/x/firstmate-notes a child of /Users/x/firstmate,
# which is exactly the lookalike this must not match.
function under(path, root) {
  if (path == root) return ""
  if (substr(path, 1, length(root) + 1) == root "/") return substr(path, length(root) + 2)
  return "\001"
}

# The sanctioned references a brief may make into the primary checkout. These
# are precisely what bin/fm-brief.sh itself emits, and nothing wider:
#   <root>         the home itself, as FM_HOME=... pins it.
#   <root>/state   the state dir, as FM_STATE_OVERRIDE=... pins it.
#   bin/...        firstmate's own helper scripts, which the brief hands the
#                  crewmate to RUN (fm-status.sh, fm-ensure-agents-md.sh,
#                  fm-gates-lib.sh). Read and execute, never edit.
#   state/<id>.*   this task's own status file.
#   data/<id>/...  this task's own brief and report dir.
# A bare directory pin names no material, so it passes. Anything DEEPER that is
# not this task's is another task's material - which is how "fix the 68 stale
# briefs" got written - and is refused.
#
# strict=1 is the glob case. A glob is only ever evaluated on the text BEFORE
# its first glob character, so a bare pin there is not a pin at all:
# ~/firstmate/data/*/brief.md has prefix "data/" but names every other task's
# brief, and ~/firstmate/** has prefix "" but names the whole checkout. Under a
# glob, only a prefix ALREADY confined to this task - bin/, state/<id>,
# data/<id> - is sanctioned.
#
# partial=1 says that prefix stopped MID-SEGMENT, so its last segment is only a
# prefix of a real name. state/<id>.* is the shape real status and meta files
# have, and it is sanctioned because the "." is a boundary the glob cannot cross
# back over; state/<id>* and data/<id>* are not, because they also match
# <id>-other. Without this distinction, the "state/<id>.*" this file's own
# refusal message advertises as sanctioned was itself refused.
function sanctioned(rem, strict, partial,   seg) {
  if (rem != "/" ) sub(/\/$/, "", rem)
  if (rem == "bin" || substr(rem, 1, 4) == "bin/") return 1
  if (rem == "" || rem == "state" || rem == "data") return !strict
  if (id == "") return 0
  if (substr(rem, 1, 6) == "state/") {
    seg = substr(rem, 7); sub(/\/.*$/, "", seg)
    if (partial) return (seg == id ".")
    return (seg == id || substr(seg, 1, length(id) + 1) == id ".")
  }
  if (substr(rem, 1, 5) == "data/") {
    seg = substr(rem, 6); sub(/\/.*$/, "", seg)
    if (partial) return 0
    return (seg == id)
  }
  return 0
}

# --- invocation, not mention -------------------------------------------------
#
# The pool-leasing scripts are also ORDINARY SUBJECTS OF WORK: "add a preflight
# to bin/fm-spawn.sh" is a legitimate brief, and refusing it would make this
# gate one that nothing gets past. So the rule matches an INVOCATION FORM, not
# any appearance of the name.
#
# EVERY form must be written AS CODE - inside a backtick span or a fenced block
# - which is how a brief that means "run this" writes it, and how the standard
# scaffold writes every command it hands a crewmate. Inside that context:
#
#   invocation   `bash bin/fm-home-seed.sh ...`   an interpreter runs it
#                `./bin/fm-spawn.sh ...`          the path is executed
#                `bin/fm-spawn.sh <id> <repo>`    command position, with
#                                                 arguments: a synopsis to run
#   mention      `bin/fm-spawn.sh`                a code span with no arguments
#                a preflight in bin/fm-spawn.sh before the wardroom gate
#                - bin/fm-spawn.sh is the spawn entry point
#                the flagship bash bin/fm-spawn.sh wrapper launches crewmates
#                for reference, ./bin/fm-spawn.sh is the file you are editing
#
# The last two are why the code-context requirement covers the interpreter and
# ./ forms too, and not only the bare one. An earlier cut exempted them on the
# reasoning that "nothing else writes them" - but English does: a sentence can
# put the word "bash" or a relative path immediately before a script name while
# saying the opposite of run it. In prose there is no reliable signal at all;
# inside a code span there is.
#
# The cost is a miss on a command written as bare prose. That is covered from
# the other side by the FM_HOME rule below, which needs no code context because
# the false-isolation assignment means only one thing wherever it appears.
function lease_scan(line, sname, lineno,    pos, base, abs, s, e, word, why,
                    tick, span_s, span_e, i, inner, args) {
  base = 0
  while ((pos = index(substr(line, base + 1), sname)) > 0) {
    abs = base + pos
    base = abs
    s = abs
    e = abs + length(sname) - 1
    if (e < length(line) && namechar(substr(line, e + 1, 1))) continue
    # walk left over any path prefix (bin/, ./bin/) to recover the whole word
    while (s > 1 && substr(line, s - 1, 1) ~ /^[A-Za-z0-9._\/-]$/) s--
    word = substr(line, s, e - s + 1)
    # left boundary of the NAME itself: my-fm-spawn.sh walks left to the whole
    # word, whose tail is the name but whose preceding character is a name char.
    if (abs > s && namechar(substr(line, abs - 1, 1))) continue
    if (s > 1 && namechar(substr(line, s - 1, 1))) continue

    # code context, or it is prose
    tick = 0
    for (i = 1; i < s; i++) if (substr(line, i, 1) == "`") tick++
    if (!(in_fence || tick % 2 == 1)) continue
    span_s = 1
    if (tick % 2 == 1) for (i = s - 1; i >= 1; i--) if (substr(line, i, 1) == "`") { span_s = i + 1; break }
    span_e = length(line)
    for (i = e + 1; i <= length(line); i++) if (substr(line, i, 1) == "`") { span_e = i - 1; break }

    # The interpreter is looked for INSIDE the span, never across it: in
    # "run bash then `bin/fm-spawn.sh`" the word bash belongs to the sentence.
    inner = substr(line, span_s, s - span_s)
    why = ""
    if (inner ~ /(^|[ \t;&|(])(bash|sh|zsh|env|source)[ \t]+$/) why = "run by an interpreter"
    else if (substr(word, 1, 2) == "./") why = "executed as a path"
    else {
      inner = trim(inner)
      sub(/^[-*>]+[ \t]*/, "", inner)
      sub(/^[0-9]+[.)][ \t]*/, "", inner)
      sub(/^\$[ \t]+/, "", inner)
      while (inner ~ /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/, "", inner)
      if (trim(inner) != "") continue
      args = trim(substr(line, e + 1, span_e - e))
      sub(/[.,;:!?]+$/, "", args)
      if (args == "") continue
      why = "a command synopsis with arguments"
    }
    finding("pool-lease", word, \
      sname " leases from the LIVE treehouse pool regardless of FM_HOME, so running it (" why \
      ") leaks a durable lease into the captain's pool - line " lineno)
  }
}

# --- the false isolation ------------------------------------------------------
#
# The third defect was not really "a brief that runs fm-home-seed.sh". It was a
# brief that believed FM_HOME made the run disposable: "test the chain under
# FM_HOME=$(mktemp -d)". FM_HOME redirects the operational dirs, NOT the
# treehouse lease, so that run still takes a durable lease from the captain's
# live pool - the isolation is illusory, and the leak is silent.
#
# The assignment says that on its own, in any wrapping, so this needs no code
# context: nobody writes FM_HOME=$(mktemp -d) except to claim an isolation that
# does not exist.
#
# Only the DYNAMIC throwaway constructs count - $(mktemp ...) and $TMPDIR. A
# literal /tmp/... or /var/folders/... path was in an earlier cut and had to come
# out: it is not evidence of the belief, it is just where a home happens to live,
# and it refused the standard scaffold outright whenever FM_HOME sat under the
# system temp dir. A rule that fires on the scaffold is a rule nobody keeps.
function throwaway_home(line, lineno,    m) {
  if (!match(line, /FM_HOME[ \t]*=[ \t]*["'"'"']?(\$\(mktemp[^)]*\)?|\$TMPDIR)/)) return
  m = trim(substr(line, RSTART, RLENGTH))
  finding("pool-lease", m, \
    "FM_HOME does not redirect the treehouse lease, so pinning it to a throwaway dir does not isolate the run - fm-home-seed.sh and fm-spawn.sh still take a durable lease from the captain's LIVE pool - line " lineno)
}

# Every input crosses in through ENVIRON, never -v: awk processes escape
# sequences in a -v value and rejects an embedded newline outright, so a root
# list or any path holding a backslash would be mangled or fatal.
BEGIN {
  nroots = split(ENVIRON["FM_PF_ROOTS"], root, "\n")
  while (nroots > 0 && root[nroots] == "") nroots--
  nlease = split(ENVIRON["FM_PF_LEASE"], leases, " ")
  id = ENVIRON["FM_PF_ID"]
  HOMEDIR = ENVIRON["FM_PF_HOME"]
  in_fence = 0; saw_status_path = 0; saw_status_verb = 0
}

{
  line = $0
  lineno = NR

  # --- status rule, half one: the retired >> redirect ------------------------
  # A redirect into a .status path is silently refused by the permission
  # profile: the report never lands and the pane just looks idle. The scaffold's
  # own WARNING about this ("A direct `>>` redirect into that path is refused")
  # carries no .status target after the operator, so it does not match.
  if (match(line, />>?[ \t]*["']?[^ \t"'|;&`]*\.status/)) {
    tgt = substr(line, RSTART, RLENGTH)
    sub(/^>>?[ \t]*["']?/, "", tgt)
    finding("status-redirect", tgt, \
      "status reporting by shell redirect is refused by the permission profile and the report is silently lost - the brief must teach bin/fm-status.sh - line " lineno)
  }
  if (index(line, "fm-status.sh") > 0) saw_status_verb = 1

  # --- pool-lease rule -------------------------------------------------------
  for (li = 1; li <= nlease; li++) if (leases[li] != "") lease_scan(line, leases[li], lineno)
  throwaway_home(line, lineno)

  # Fenced-code tracking runs AFTER this line is scanned, so a fence marker line
  # is never treated as being inside the block it opens.
  if (line ~ /^[ \t]*```/) in_fence = !in_fence

  # --- tokenise for paths ----------------------------------------------------
  # Punctuation that can never be part of a path becomes whitespace; * and ?
  # survive, because a brief legitimately writes data/*/brief.md and each rule
  # normalises globs its own way below.
  t = line
  gsub(/[`"'()\[\]{}<>,;:!|=&]/, " ", t)
  n = split(t, toks, /[ \t]+/)
  for (k = 1; k <= n; k++) {
    tok = toks[k]
    sub(/[.]+$/, "", tok)                  # sentence-final period, never a path
    if (tok == "" || index(tok, "/") == 0) continue
    if (index(tok, "://") > 0) continue    # a URL is not a path
    if (substr(tok, 1, 1) == "-") continue

    if (tok ~ /\.status$/) saw_status_path = 1

    if (substr(tok, 1, 1) == "~") {
      if (substr(tok, 2, 1) != "/") continue
      tok = HOMEDIR substr(tok, 2)
    }

    if (substr(tok, 1, 1) == "/") {
      # --- primary-checkout rule ---------------------------------------------
      # A glob truncates the path at its first glob segment: ~/firstmate/**
      # names the root (sanctioned) while ~/firstmate/data/*/brief.md names
      # data/ (not this task's, so refused). Guessing past a glob would be
      # inventing a path the brief never wrote.
      p = tok; globbed = 0; partial = 0
      if (p ~ /[*?]/) {
        globbed = 1
        sub(/[*?].*$/, "", p)
        partial = (substr(p, length(p), 1) != "/")
      }
      for (ri = 1; ri <= nroots; ri++) {
        rem = under(p, root[ri])
        if (rem == "\001") continue
        if (sanctioned(rem, globbed, partial)) break
        finding("primary-checkout", tok, \
          "under the firstmate primary checkout " root[ri] \
          ", which the permission profile denies to crewmates; only bin/, state/" \
          (id == "" ? "<id>" : id) ".* and data/" (id == "" ? "<id>" : id) \
          "/ are sanctioned - line " lineno)
        break
      }
      continue
    }

    # --- gitignored rule: candidates ---------------------------------------
    # Relative paths only; the shell asks the project's own git whether each is
    # invisible in a worktree. A glob segment is normalised to a literal so the
    # question can be asked at all: data/*/brief.md -> data/x/brief.md.
    if (substr(tok, 1, 2) == "./") tok = substr(tok, 3)
    if (index(tok, "/") == 0 || tok ~ /^\.\.\// || substr(tok, 1, 1) == "/") continue
    orig = tok
    gsub(/[*?]+/, "x", tok)
    if (tok == "" || substr(tok, 1, 1) == "/") continue
    printf "CAND\t%s\t%s\t%s\n", tok, orig, lineno
  }
}

END {
  # --- status rule, half two: a status file named without the verb -----------
  # A brief that names the status file but never names bin/fm-status.sh has not
  # taught reporting at all; the crewmate reaches for a redirect and its reports
  # vanish. Same defect as half one, one step earlier.
  if (saw_status_path && !saw_status_verb)
    finding("status-redirect", "bin/fm-status.sh", \
      "the brief names a .status file but never teaches the reporting verb bin/fm-status.sh, so the crewmate will reach for a redirect the permission profile silently refuses")
}
AWK
}

# --- the classifier ----------------------------------------------------------
#
# fm_brief_preflight <brief-file> [<project-dir>] [<task-id>]
# Prints one TSV finding per line: <rule>\t<offender>\t<why>
# Returns 0 when the brief is clean, 1 when it is not.
#
# A project dir that is not a git repo is NOT "cannot tell": a tree with no
# ignore machinery hides nothing, so the gitignored rule is simply not
# applicable and the other three still run. Mirrors fm_gates_classify's NOGATES.
fm_brief_preflight() {
  local brief=$1 proj=${2:-} id=${3:-}
  if [ ! -f "$brief" ]; then
    printf 'unreadable-brief\t%s\t%s\n' "$brief" "no brief file to check"
    return 1
  fi

  local raw kind a b c found=0 cands=""
  raw=$(FM_PF_ROOTS="$(fm_preflight_roots)" FM_PF_ID="$id" \
        FM_PF_HOME="${HOME:-/nonexistent}" FM_PF_LEASE="$FM_PREFLIGHT_LEASE_SCRIPTS" \
        awk "$(fm_preflight_awk_program)" "$brief") || {
    printf 'unreadable-brief\t%s\t%s\n' "$brief" "the brief could not be scanned"
    return 1
  }

  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      FINDING) found=1; printf '%s\t%s\t%s\n' "$a" "$b" "$c" ;;
      CAND)    cands="$cands$a"$'\t'"$b"$'\t'"$c"$'\n' ;;
    esac
  done <<EOF
$raw
EOF

  # --- gitignored rule -------------------------------------------------------
  # git is the authority, not a pattern this file re-implements. Asked without
  # --no-index, it also answers "tracked, therefore visible" for a path some
  # ignore pattern happens to match, which is the honest answer for a crewmate:
  # a tracked file IS in its worktree.
  if [ -n "$proj" ] && [ -d "$proj" ] && git -C "$proj" rev-parse --git-dir >/dev/null 2>&1; then
    local norm orig line seen=""
    while IFS=$'\t' read -r norm orig line; do
      [ -n "$norm" ] || continue
      case "$seen" in *"|$orig|"*) continue ;; esac
      seen="$seen|$orig|"
      if git -C "$proj" check-ignore -q -- "$norm" 2>/dev/null; then
        found=1
        printf 'gitignored\t%s\t%s\n' "$orig" \
          "gitignored in $proj, so it does not exist in a crewmate's worktree and no commit can add, move or delete it - line $line"
      fi
    done <<EOF
$cands
EOF
  fi

  [ "$found" = 0 ] || return 1
  return 0
}

# --- the spawn gate ----------------------------------------------------------
#
# fm_brief_preflight_require <brief> <project-dir> <id> <label>
# Prints the refusal banner - every offender, named, with why - and returns 1.
# FM_PREFLIGHT_OVERRIDE=1 is the captain's bypass: loud and logged, never silent.
fm_brief_preflight_require() {
  local brief=$1 proj=$2 id=$3 label=$4 findings rule offender why
  if [ "${FM_PREFLIGHT_OVERRIDE:-}" = 1 ]; then
    {
      echo "=================== PREFLIGHT OVERRIDE ===================="
      echo "WARNING: $label spawning task $id WITHOUT a brief preflight"
      echo "(FM_PREFLIGHT_OVERRIDE=1 - captain authority; logged, not silent)"
      echo "==========================================================="
    } >&2
    return 0
  fi
  findings=$(fm_brief_preflight "$brief" "$proj" "$id") && return 0
  {
    echo "======================== PREFLIGHT ========================="
    echo "REFUSED: $label for task $id - the brief asks for work the crewmate"
    echo "cannot see or safely touch. Each offender is named below."
    while IFS=$'\t' read -r rule offender why; do
      [ -n "$rule" ] || continue
      echo "  [$rule] $offender"
      echo "      $why"
    done <<EOF
$findings
EOF
    echo "Fix the brief at: $brief"
    echo "Captain bypass (loud, logged): FM_PREFLIGHT_OVERRIDE=1"
    echo "==========================================================="
  } >&2
  return 1
}

# --- CLI ---------------------------------------------------------------------
#
# So firstmate, a crewmate, or a human can ask the same question the spawn gate
# asks and get the same answer, without reimplementing it.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -lt 1 ]; then
    echo "usage: fm-preflight-lib.sh <brief> [<project-dir>] [<task-id>]" >&2
    exit 2
  fi
  fm_brief_preflight "$1" "${2:-}" "${3:-}"
  exit $?
fi
