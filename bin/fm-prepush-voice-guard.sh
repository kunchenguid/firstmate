#!/usr/bin/env bash
# fm-prepush-voice-guard.sh - owner of the refusal that keeps firstmate's
# internal voice and internal pointers out of anything published from this
# machine. Unrelated to the bin/fm-voice-* audio relay family.
#
# THE DEFECT THIS EXISTS FOR. AGENTS.md tells every agent to address the user as
# "captain" in every response. An agent working INSIDE this repo reads AGENTS.md
# as an ordinary repo file and applies that rule to its commit messages, which it
# treats as responses. The offending commits came from the no-mistakes pipeline's
# own fix agent, not from a briefed task worker, so briefing workers cannot fix
# it. An instruction-level guard against agents adopting the captain's identity
# was already active while the leak happened anyway, so this is deterministic
# enforcement instead of a second instruction.
#
# WHY BEFORE THE FIRST PUSH, not before merge. On a repository firstmate does not
# own, a maintainer can merge at any moment, so a correction that waits for the
# merge window is a correction that may never happen. bin/fm-lint.sh invokes this
# owner on its default (no explicit-path) path, which is both what CI runs and
# what .no-mistakes.yaml pins as commands.lint. The gate's pipeline order puts
# lint last before push, after the review, test, and document steps have made
# their own commits, so this check reads back every commit that is about to
# leave - including the ones the gate's own agents wrote.
#
# WHAT IT REFUSES, and why the set is this narrow. Every rule below was selected
# against the real merged history of this repo (530 commits, ~15k message lines)
# and kept only when it matched real leaks with ZERO matches on legitimate
# messages. Rules that intuition suggested and evidence rejected are recorded in
# "REJECTED" below, because the reason they were rejected is the whole design:
# this repo's subject matter IS the fleet machinery, so banning house vocabulary
# refuses legitimate work.
#
# The admissible signal turned out to be POSITION, not vocabulary: an address to
# a person occupies a syntactic slot that technical prose never uses. "captain
# hold", "captain intent", "captain-gated", and "reaches the captain" all pass
# untouched, while "…: Captain, fixed the…" and "…scans, captain" refuse.
#
# The same position-not-vocabulary test admits the two session-pointer rules. A
# link to the working session is internal material leaving the machine exactly
# as an address is, and three such trailers are already in merged history, so it
# is refused here rather than by a second mechanism. A trailer key may contain a
# session-bearing token surrounded by letters or hyphens, but its value must
# still be a URL or opaque id. That token-shaped rule catches Codex-Session and
# Session-Link without enumerating worker runtimes and has zero false positives
# against Discussion, Regression, or prose-valued session configuration.
#
# The bare-link evidence is weaker because merged history contains only four
# URLs. That rule therefore requires an http(s) URL with a path segment beginning
# /session, optionally continued by slash, underscore, or hyphen, rather than
# matching any URL that merely mentions the word. The 333 legitimate merged
# lines using "session" in its ordinary technical sense still pass.
#
# The private work-document rules likewise key on a path shape, not a word. A
# path with a subdirectory under data/, data/<id>/<file> or anything deeper, is
# the per-task brief or report shape AGENTS.md defines. It catches exactly three
# real leaks in the same merged history - data/fm-send-reliability-reframe-s1/
# report.md and data/agentsmd-diet-s2/report.md twice - with zero false
# positives. The second such shape is the Lavish review artifact, .lavish/<file>
# and deeper, which has zero matches in merged history while the bare word
# "Lavish" has 59, because this repo develops that integration. Keying on the
# path and never on the word is what keeps those 59 legitimate messages
# shipping.
#
# Neither rule bounds how deep the path may go. A depth limit here would be a
# regex artifact rather than a chosen bound: data/<id>/evidence/report.md is as
# private as data/<id>/report.md, and a rule that stopped at two components
# would refuse the shallow leak while passing the deeper one.
#
# MEASURED COUNTS, all against origin/main's 14,965 merged message lines, and
# current as of this rule set. These are the figures the rules were selected on;
# any change to a rule must restate them:
#   captain-address-opening      219   every leaked line carries a commit prefix
#   captain-address-line           0   kept for the paragraph-initial shape
#   captain-address-trailing       6   leaks reachable by no other rule
#   captain-address-greeting       0   the address, not the nautical vocabulary
#   delivery-machinery-handoff     4   including "for the outer executor"
#   internal-session-pointer       3   real trailers already published
#   internal-session-link          3   the same three, seen as bare links
#   private-task-work-document     3   the two data/<id>/report.md leaks
#   private-review-artifact        0   no legitimate line to displace
#
# WHICH DOCUMENT FAMILIES ARE COVERED. Exactly two: data/<id>/<file> and
# .lavish/<file>. Deliberately left out, each because it has legitimate merged
# mentions, are .no-mistakes/, projects/, state/, config/, .env, and the flat
# named private files directly under data/; their counts and reasons are in
# REJECTED below. "No reference to internal working documents" is therefore
# enforced for those two path families, not as a general guarantee over every
# private file this repo happens to hold.
#
# KNOWN RESIDUAL. The trailing rule refuses a subject that ends in a bare
# ",<space>captain", so a comma list whose last item is the word captain
# ("firstmate, secondmate, captain") would be refused as an address. No such
# line exists in merged history and the six lines this rule caught existed only
# in this shape, so it is kept and the refusal is reworded past rather than
# narrowed on a case that has never occurred.
#
# The same shape of residual applies to the Lavish rule: a commit that
# legitimately changes the Lavish artifact integration could name ".lavish/" in
# its own message and would be refused. No such line exists in merged history,
# and rewording to the bare word clears it, so the rule is kept.
#
# REJECTED, with the evidence that rejected them:
#   - Bare nautical words (ahoy, shipshape, avast). This repo ships an /ahoy
#     skill and a "Captain, shipshape." acknowledgement rule; 13 legitimate
#     merged commits mention them. Banned as an ADDRESS instead (captain-greeting).
#   - An unscoped "captain" followed by a spaced dash. One legitimate merged
#     line reads "so the pane still reaches the captain - once per
#     PAUSE_RESURFACE_SECS". The admitted position-scoped dash and period forms
#     each have zero matches in merged history.
#   - A period accepted as bare punctuation after "captain", which is what
#     putting "." inside the punctuation class does. It accepts any following
#     character and so refuses "docs: captain.md now records the fleet owner"
#     and "* captain.md gains a section", contradicting the promise below that
#     the flat data/ files keep shipping. The period must end a sentence.
#   - Bare "uncommitted". Six legitimate merged lines describe this repo's own
#     uncommitted-work refusals. The real leak, "Changes remain uncommitted for
#     the outer executor", is caught by delivery-machinery-handoff instead.
#   - First-person "I" and second-person "you". Four legitimate merged lines use
#     "your"; a human contributor may legitimately write either, and refusing a
#     human's own voice is not what this guard is for.
#   - Verification narration ("Verified with X; all passed"). Hundreds of
#     legitimate merged commits carry it. It is process detail, not our voice.
#   - Bare "report" or "brief". Legitimate merged messages use both words; the
#     private per-task path shape is the leak, not either noun.
#   - Every data/ path. The flat private files data/backlog.md, data/captain.md,
#     data/learnings.md, data/projects.md, and data/secondmates.md appear
#     legitimately in eight merged messages, so requiring a subdirectory keeps
#     them outside the rule.
#   - The bare word "Lavish". 59 legitimate merged mentions, because this repo
#     develops that integration. Only the .lavish/<file> path is refused.
#   - Every state/ path. 46 legitimate merged mentions.
#   - Every config/ path. 45 legitimate merged mentions.
#   - Every .env path. 12 legitimate merged mentions.
#   - Every projects/ path. 5 legitimate merged mentions, all path-resolution
#     prose.
#   - Every .no-mistakes/ path. 1 legitimate merged mention, the architecture
#     prose "no-mistakes gate worktree (.no-mistakes/repos/".
#
# NO BYPASS FLAG AND NO BYPASS VARIABLE. A refusal is always fixable by
# rewording the message, so there is no case that needs an override. The refusal
# names the rule, the exact text that matched, and the command that rewords it.
# The default range's base is derived only from the default-branch refs and is
# not reachable from the environment: a base the caller could choose is an off
# switch, because a base equal to HEAD leaves an empty range that reports clean
# having scanned nothing. Explicit bounds belong to --range, which names what it
# scans instead of silently narrowing the pre-push default.
#
# Exit codes: 0 clean, 1 internal voice found, 2 usage error, 3 the scan or
# commit range could not be completed (fail closed - unknown is not clean).
#
# Usage:
#   fm-prepush-voice-guard.sh                  check every commit not yet on the
#                                              default branch (the pre-push default)
#   fm-prepush-voice-guard.sh --range <a>..<b> check an explicit commit range
#   fm-prepush-voice-guard.sh --commit <rev>   check one commit's message
#   fm-prepush-voice-guard.sh --text <file>    check arbitrary text, "-" for stdin
#                                              (a pull request title or description)
#   fm-prepush-voice-guard.sh --list-patterns  print the rule table
#   fm-prepush-voice-guard.sh --help           print this usage
#
# The default range is bounded by origin/main when it resolves and by local main
# only as a fallback, so an ahead local main cannot hide unpushed commits.
set -u

SELF_DIR=
if ! SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); then
  printf 'fm-prepush-voice-guard.sh: cannot resolve its script directory. The scan did not complete.\n' >&2
  exit 3
fi
SELF="$SELF_DIR/fm-prepush-voice-guard.sh"
TAB=$(printf '\t')

fm_voice_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Rule table: id <TAB> case (i|s) <TAB> extended regex <TAB> hint.
#
# Boundaries are spelled out rather than using \b, which is a GNU extension the
# BSD grep on macOS does not accept.
FM_VOICE_RULES=()

# An address to the captain that opens the message's prose: after a conventional
# commit "type(scope): " prefix, after a "* " or "- " bullet (the shape a squash
# merge body gives every branch commit), or after a sentence boundary. This rule
# matches 219 leaked lines in merged history. Spaced dash and period forms had
# zero matches in merged history at these positions.
#
# The period must END A SENTENCE, so it is spelled as its own alternative
# followed by whitespace or end of line rather than sitting inside the
# punctuation class. Inside the class it would accept any following character
# and refuse "docs: captain.md now records the fleet owner", one of the flat
# private files this guard promises keeps shipping.
FM_VOICE_RULES+=("captain-address-opening${TAB}i${TAB}(^[*-][[:space:]]+|[.!?][[:space:]]+|:[[:space:]]+)captain([,:!?]|\\.([[:space:]]|\$)|[[:space:]]+-)${TAB}A commit message describes a change to the repository; it never addresses a person. Drop the address and state the change.")

# The same address opening a line of its own. Capital-only on purpose: a wrapped
# body line can legitimately begin with a lowercase "captain," carried over from
# the middle of a sentence, while a deliberate vocative at the start of a
# paragraph is capitalized. Zero matches in merged history, because every leak
# there carries a commit prefix and is caught by the opening rule; it is kept
# for the paragraph-initial shape that prefix cannot reach.
FM_VOICE_RULES+=("captain-address-line${TAB}s${TAB}^Captain([,:!?]|\\.([[:space:]]|\$)|[[:space:]]+-)${TAB}A commit message describes a change to the repository; it never addresses a person. Drop the address and state the change.")

# The trailing form, which the opening rules miss: "…, captain" at the end of a
# line. Six leaked lines in merged history have only this shape.
FM_VOICE_RULES+=("captain-address-trailing${TAB}i${TAB},[[:space:]]*captain[[:space:]]*[.!?]*\$${TAB}A commit message describes a change to the repository; it never addresses a person. Drop the trailing address.")

# A greeting addressed to the captain. This is how the house nautical voice is
# refused without banning the words themselves, which this repo uses as real
# identifiers (the /ahoy skill, the "shipshape" acknowledgement rule).
FM_VOICE_RULES+=("captain-address-greeting${TAB}i${TAB}(^|[^[:alnum:]_])(ahoy|hello|hi|dear|aye),?[[:space:]]+captain([^[:alnum:]_]|\$)${TAB}Greetings belong in a reply, not in published history. Drop the greeting and state the change.")

# Narration of the delivery machinery handing work between agents: text about
# how the change was produced rather than what it does. Four leaked lines in
# merged history, including "Changes remain uncommitted for the outer executor".
FM_VOICE_RULES+=("delivery-machinery-handoff${TAB}i${TAB}(^|[^[:alnum:]_])outer[[:space:]]+(executor|pipeline|run)([^[:alnum:]_]|\$)${TAB}Published history must not narrate how the change was validated or which agent finishes it. State what the change does.")

# A pointer at the working session that produced the change, as a trailer whose
# value is a URL or an opaque id. Three such trailers are already in merged
# history, so this is a recurring leak rather than a hypothetical one. Requiring
# both a session-bearing key token and the value shape separates a pointer from
# ordinary prose or configuration.
FM_VOICE_RULES+=("internal-session-pointer${TAB}i${TAB}^[[:space:]]*[[:alpha:]-]*(session|conversation|transcript|chat|thread)[[:alpha:]-]*[[:space:]]*:[[:space:]]*(https?://|[A-Za-z0-9_-]{16,})${TAB}Published history must not link the working session that produced the change. Delete the trailer.")

# The same pointer as a bare link, which survives being moved out of a trailer
# and into a sentence in a pull request description. Matched on the session path
# segment rather than on the host, so it does not become a list of vendors, and
# URLs that mention session outside their path stay legitimate.
FM_VOICE_RULES+=("internal-session-link${TAB}i${TAB}https?://[^[:space:]?#]*/session([/_-][^[:space:]?#]+)?([^[:alnum:]_-]|\$)${TAB}Published history must not link the working session that produced the change. Remove the link.")

# A private per-task work document is a path rooted at data/ with at least one
# subdirectory: data/<id>/<file>, and anything deeper. Requiring a subdirectory
# excludes the named flat data files that legitimate commit messages discuss,
# while the tail accepts further slashes so a deeper private path cannot slip
# past a bound nobody chose. Spelling the boundaries out avoids GNU-only \b.
#
# The leading class excludes "/" on purpose, and the Lavish rule below does not.
# "data" is an ordinary directory name that occurs inside legitimate paths such
# as tests/data/fixtures/x.txt, so a preceding slash must disqualify the match;
# ".lavish" is a distinctive dot-prefixed directory whose parent path is
# irrelevant, so a preceding slash is allowed there. Both leading classes
# exclude "." so a longer dotted name cannot be split into a false match.
FM_VOICE_RULES+=("private-task-work-document${TAB}i${TAB}(^|[^[:alnum:]_/.-])data/[[:alnum:]_.-]+/[[:alnum:]_./-]+${TAB}Published history must not reference a private per-task work document. Remove the data/<id>/<file> path and describe the durable outcome.")

# The local Lavish review artifact, which is the other private work-document
# shape this repo produces. Keyed on the dot-prefixed directory path so the 59
# legitimate merged mentions of the bare word "Lavish" keep shipping.
FM_VOICE_RULES+=("private-review-artifact${TAB}i${TAB}(^|[^[:alnum:]_.-])\\.lavish/[[:alnum:]_./-]+${TAB}Published history must not reference a local review artifact. Remove the .lavish/<file> path and describe the durable outcome.")

fm_voice_list_patterns() {
  local rule
  printf 'id\tcase\tregex\thint\n'
  for rule in "${FM_VOICE_RULES[@]}"; do
    printf '%s\n' "$rule"
  done
}

# Every read that can affect a clean verdict is checked below. Rule parsing and
# line lookup use shell builtins; scanner, text, commit, and report I/O failures
# return 3. Constant metadata substitutions are either builtins or status-checked.
fm_voice_read_line() {  # <line-number> <path>
  local wanted=$1 path=$2 current=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    current=$((current + 1))
    if [ "$current" -eq "$wanted" ]; then
      printf '%s' "$line"
      return 0
    fi
  done < "$path"
  return 1
}

# fm_voice_scan_file <label> <path>: print every rule match found in the text at
# <path>, prefixed by <label>. Returns 0 clean, 1 matched, or 3 scanner error.
fm_voice_scan_file() {
  local label=$1 path=$2
  local rule id case_flag regex hint hits hit line_no matched line found=0 grep_rc

  for rule in "${FM_VOICE_RULES[@]}"; do
    if ! IFS="$TAB" read -r id case_flag regex hint <<< "$rule"; then
      printf 'fm-prepush-voice-guard.sh: cannot parse a voice rule. The scan did not complete.\n' >&2
      return 3
    fi
    if [ -z "$id" ] || [ -z "$regex" ] || [ -z "$hint" ]; then
      printf 'fm-prepush-voice-guard.sh: voice rule %s is incomplete. The scan did not complete.\n' \
        "${id:-<unknown>}" >&2
      return 3
    fi

    grep_rc=0
    case "$case_flag" in
      i) hits=$(grep -n -o -i -E -e "$regex" -- "$path" 2>/dev/null) || grep_rc=$? ;;
      s) hits=$(grep -n -o -E -e "$regex" -- "$path" 2>/dev/null) || grep_rc=$? ;;
      *)
        printf 'fm-prepush-voice-guard.sh: voice rule %s has invalid case flag %s. The scan did not complete.\n' \
          "$id" "$case_flag" >&2
        return 3
        ;;
    esac
    if [ "$grep_rc" -eq 1 ]; then
      continue
    elif [ "$grep_rc" -ne 0 ]; then
      printf 'fm-prepush-voice-guard.sh: scanner failed for rule %s (grep exit %s). The scan did not complete.\n' \
        "$id" "$grep_rc" >&2
      return 3
    fi
    [ -n "$hits" ] || continue

    if [ "$found" -eq 0 ]; then
      printf '\n  %s\n' "$label"
      found=1
    fi
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      line_no=${hit%%:*}
      matched=${hit#*:}
      if ! line=$(fm_voice_read_line "$line_no" "$path"); then
        printf 'fm-prepush-voice-guard.sh: cannot read matched line %s for rule %s. The scan did not complete.\n' \
          "$line_no" "$id" >&2
        return 3
      fi
      printf '    line %s matched %s\n' "$line_no" "$id"
      printf '      in:      %s\n' "$line"
      printf '      matched: %s\n' "$matched"
      printf '      fix:     %s\n' "$hint"
    done <<EOF
$hits
EOF
  done

  [ "$found" -eq 0 ]
}

fm_voice_append_scan() {  # <label> <path> <report>
  local label=$1 path=$2 report=$3 scan_output scan_rc=0
  scan_output=$(fm_voice_scan_file "$label" "$path") || scan_rc=$?
  case "$scan_rc" in
    0|1) ;;
    3) return 3 ;;
    *)
      printf 'fm-prepush-voice-guard.sh: scanner returned unexpected status %s. The scan did not complete.\n' \
        "$scan_rc" >&2
      return 3
      ;;
  esac
  if [ -n "$scan_output" ] && ! printf '%s\n' "$scan_output" >> "$report"; then
    printf 'fm-prepush-voice-guard.sh: cannot write the refusal report. The scan did not complete.\n' >&2
    return 3
  fi
  return "$scan_rc"
}

# The default-branch ref, probed the same way bin/fm-lint.sh's own
# fm_lint_changed_base_ref probes candidates. The remote-tracking ref is the
# publication boundary; local main is only a fallback when it does not resolve.
fm_voice_default_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf '%s\n' origin/main
  elif git rev-parse --verify -q main >/dev/null 2>&1; then
    printf '%s\n' main
  fi
}

# Commits on HEAD that the authoritative default-branch ref does not carry.
# Preferring origin/main prevents an ahead local main from hiding commits that
# the first feature push would publish.
#
# Both failure modes return 3, never 1: an unresolvable ref and an unusable
# rev-list both mean the range is unknown, and an unknown range must not be
# reported as either clean or leaking.
fm_voice_unpublished_commits() {  # <destination>
  local destination=$1
  local base_ref
  base_ref=$(fm_voice_default_ref)

  if [ -z "$base_ref" ]; then
    printf 'fm-prepush-voice-guard.sh: cannot determine which commits are unpublished: no default-branch ref resolved (tried origin/main, main).\n' >&2
    printf 'fm-prepush-voice-guard.sh: fetch the default branch (git fetch origin main), or name the bound with --range <a>..<b>, then re-run. An unknown range is not a clean range.\n' >&2
    return 3
  fi

  if ! git rev-list HEAD --not "$base_ref" > "$destination" 2>/dev/null; then
    printf 'fm-prepush-voice-guard.sh: cannot list the commits ahead of %s. An unknown range is not a clean range.\n' \
      "$base_ref" >&2
    return 3
  fi
}

MODE=range
RANGE=
TEXT_PATH=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --range)
      [ "$#" -ge 2 ] || { printf 'fm-prepush-voice-guard.sh: --range requires a revision range.\n' >&2; exit 2; }
      MODE=range
      RANGE=$2
      shift 2
      ;;
    --range=*) MODE=range; RANGE=${1#*=}; shift ;;
    --commit)
      [ "$#" -ge 2 ] || { printf 'fm-prepush-voice-guard.sh: --commit requires a revision.\n' >&2; exit 2; }
      MODE=commit
      RANGE=$2
      shift 2
      ;;
    --commit=*) MODE=commit; RANGE=${1#*=}; shift ;;
    --text)
      [ "$#" -ge 2 ] || { printf 'fm-prepush-voice-guard.sh: --text requires a path or "-".\n' >&2; exit 2; }
      MODE=text
      TEXT_PATH=$2
      shift 2
      ;;
    --text=*) MODE=text; TEXT_PATH=${1#*=}; shift ;;
    --list-patterns)
      fm_voice_list_patterns
      exit 0
      ;;
    --help|-h)
      fm_voice_usage
      exit 0
      ;;
    --) shift; break ;;
    *)
      printf 'fm-prepush-voice-guard.sh: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-prepush-voice-guard.XXXXXX") || {
  printf 'fm-prepush-voice-guard.sh: cannot create temporary scan storage. The scan did not complete.\n' >&2
  exit 3
}
trap 'rm -rf "$TMP_ROOT"' EXIT

MESSAGE_FILE="$TMP_ROOT/message"
REPORT="$TMP_ROOT/report"
if ! : > "$REPORT"; then
  printf 'fm-prepush-voice-guard.sh: cannot create the refusal report. The scan did not complete.\n' >&2
  exit 3
fi
SUBJECT_LABEL=

if [ "$MODE" = text ]; then
  if [ "$TEXT_PATH" = - ]; then
    if ! cat > "$MESSAGE_FILE"; then
      printf 'fm-prepush-voice-guard.sh: cannot read text from stdin. The scan did not complete.\n' >&2
      exit 3
    fi
  elif [ -f "$TEXT_PATH" ]; then
    if ! cat -- "$TEXT_PATH" > "$MESSAGE_FILE"; then
      printf 'fm-prepush-voice-guard.sh: cannot read text file: %s. The scan did not complete.\n' \
        "$TEXT_PATH" >&2
      exit 3
    fi
  else
    printf 'fm-prepush-voice-guard.sh: no such text file: %s\n' "$TEXT_PATH" >&2
    exit 2
  fi
  SUBJECT_LABEL='the supplied text'
  scan_rc=0
  fm_voice_append_scan "text" "$MESSAGE_FILE" "$REPORT" || scan_rc=$?
  case "$scan_rc" in
    0) FOUND=0 ;;
    1) FOUND=1 ;;
    *) exit 3 ;;
  esac
else
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'fm-prepush-voice-guard.sh: not inside a git work tree.\n' >&2
    exit 2
  }

  COMMITS_FILE="$TMP_ROOT/commits"
  if [ "$MODE" = commit ]; then
    git rev-parse --verify -q "$RANGE^{commit}" > "$COMMITS_FILE" || {
      printf 'fm-prepush-voice-guard.sh: not a commit: %s\n' "$RANGE" >&2
      exit 2
    }
    SUBJECT_LABEL='that commit'
  elif [ -n "$RANGE" ]; then
    git rev-list "$RANGE" > "$COMMITS_FILE" 2>/dev/null || {
      printf 'fm-prepush-voice-guard.sh: not a revision range: %s\n' "$RANGE" >&2
      exit 2
    }
    SUBJECT_LABEL='the commits in that range'
  else
    rc=0
    fm_voice_unpublished_commits "$COMMITS_FILE" || rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    SUBJECT_LABEL='the commits about to be pushed'
  fi

  FOUND=0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    if ! git log -1 --format=%B "$sha" > "$MESSAGE_FILE" 2>/dev/null; then
      printf 'fm-prepush-voice-guard.sh: cannot read commit message for %.12s. The scan did not complete.\n' \
        "$sha" >&2
      exit 3
    fi
    if ! IFS= read -r subject < "$MESSAGE_FILE"; then
      printf 'fm-prepush-voice-guard.sh: cannot read commit subject for %.12s. The scan did not complete.\n' \
        "$sha" >&2
      exit 3
    fi
    scan_rc=0
    fm_voice_append_scan "commit $(printf '%.12s' "$sha") - $subject" "$MESSAGE_FILE" "$REPORT" || scan_rc=$?
    case "$scan_rc" in
      0) ;;
      1) FOUND=1 ;;
      *) exit 3 ;;
    esac
  done < "$COMMITS_FILE"
fi

if [ "$FOUND" -eq 0 ]; then
  exit 0
fi

{
  printf 'fm-prepush-voice-guard.sh: REFUSING - firstmate internal voice found in %s.\n' "$SUBJECT_LABEL"
  printf 'This text would become permanent public history under the repository owner'"'"'s name.\n'
  if ! cat "$REPORT"; then
    printf 'fm-prepush-voice-guard.sh: cannot read the refusal report. The scan did not complete.\n' >&2
    exit 3
  fi
  printf '\n  How to clear this refusal:\n'
  if [ "$MODE" = text ]; then
    printf '    Reword the text above, then re-run this check.\n'
  else
    printf '    Reword the message so it states what the change does, then re-run this check:\n'
    printf '      git commit --amend        for the tip commit\n'
    printf '      git rebase -i <base>      then mark the named commits "reword"\n'
    printf '    Inside a no-mistakes run, respond to the gate and let the pipeline reword; do not push around this check.\n'
  fi
  printf '    Inspect the full rule table with: bin/fm-prepush-voice-guard.sh --list-patterns\n'
} >&2

exit 1
