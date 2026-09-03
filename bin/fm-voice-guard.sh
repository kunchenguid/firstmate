#!/usr/bin/env bash
# fm-voice-guard.sh - owner of the refusal that keeps firstmate's internal voice
# out of anything published from this machine.
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
# KNOWN RESIDUAL. The trailing rule refuses a subject that ends in a bare
# ",<space>captain", so a comma list whose last item is the word captain
# ("firstmate, secondmate, captain") would be refused as an address. No such
# line exists in merged history and the six lines this rule caught existed only
# in this shape, so it is kept and the refusal is reworded past rather than
# narrowed on a case that has never occurred.
#
# REJECTED, with the evidence that rejected them:
#   - Bare nautical words (ahoy, shipshape, avast). This repo ships an /ahoy
#     skill and a "Captain, shipshape." acknowledgement rule; 13 legitimate
#     merged commits mention them. Banned as an ADDRESS instead (captain-greeting).
#   - "captain" followed by a spaced dash. One legitimate merged line reads
#     "so the pane still reaches the captain - once per PAUSE_RESURFACE_SECS".
#   - Bare "uncommitted". Six legitimate merged lines describe this repo's own
#     uncommitted-work refusals. The real leak, "Changes remain uncommitted for
#     the outer executor", is caught by delivery-machinery-handoff instead.
#   - First-person "I" and second-person "you". Four legitimate merged lines use
#     "your"; a human contributor may legitimately write either, and refusing a
#     human's own voice is not what this guard is for.
#   - Verification narration ("Verified with X; all passed"). Hundreds of
#     legitimate merged commits carry it. It is process detail, not our voice.
#
# NO BYPASS FLAG. A refusal is always fixable by rewording the message, so there
# is no case that needs an override. The refusal names the rule, the exact text
# that matched, and the command that rewords it.
#
# Exit codes: 0 clean, 1 internal voice found, 2 usage error, 3 the commit range
# could not be determined (fail closed - an unknown range is not a clean range).
#
# Usage:
#   fm-voice-guard.sh                     check every commit not yet on the
#                                         default branch (the pre-push default)
#   fm-voice-guard.sh --range <a>..<b>    check an explicit commit range
#   fm-voice-guard.sh --commit <rev>      check one commit's message
#   fm-voice-guard.sh --text <file>       check arbitrary text, "-" for stdin
#                                         (a pull request description)
#   fm-voice-guard.sh --list-patterns     print the rule table
#   fm-voice-guard.sh --help              print this usage
#
# FM_VOICE_GUARD_BASE overrides the default-branch ref used to bound the default
# range; without it the resolvable refs among origin/main and main are used, and
# a commit reachable from any of them is already published and never scanned.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-voice-guard.sh"
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
# merge body gives every branch commit), or after a sentence boundary. All 219
# leaked lines in merged history have this shape.
FM_VOICE_RULES+=("captain-address-opening${TAB}i${TAB}(^[*-][[:space:]]+|[.!?][[:space:]]+|:[[:space:]]+)captain[,:!?]${TAB}A commit message describes a change to the repository; it never addresses a person. Drop the address and state the change.")

# The same address opening a line of its own. Capital-only on purpose: a wrapped
# body line can legitimately begin with a lowercase "captain," carried over from
# the middle of a sentence, while a deliberate vocative at the start of a
# paragraph is capitalized.
FM_VOICE_RULES+=("captain-address-line${TAB}s${TAB}^Captain[,:!?]${TAB}A commit message describes a change to the repository; it never addresses a person. Drop the address and state the change.")

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

fm_voice_rule_field() {  # <rule> <field-index>
  printf '%s' "$1" | cut -d"$TAB" -f"$2"
}

fm_voice_list_patterns() {
  local rule
  printf 'id\tcase\tregex\thint\n'
  for rule in "${FM_VOICE_RULES[@]}"; do
    printf '%s\n' "$rule"
  done
}

# fm_voice_scan_file <label> <path>: print every rule match found in the text at
# <path>, prefixed by <label>. Returns 1 when anything matched.
fm_voice_scan_file() {
  local label=$1 path=$2
  local rule id case_flag regex hint hits line_no matched line found=0

  for rule in "${FM_VOICE_RULES[@]}"; do
    id=$(fm_voice_rule_field "$rule" 1)
    case_flag=$(fm_voice_rule_field "$rule" 2)
    regex=$(fm_voice_rule_field "$rule" 3)
    hint=$(fm_voice_rule_field "$rule" 4)

    if [ "$case_flag" = i ]; then
      hits=$(grep -n -o -i -E -e "$regex" -- "$path" 2>/dev/null) || hits=
    else
      hits=$(grep -n -o -E -e "$regex" -- "$path" 2>/dev/null) || hits=
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
      line=$(sed -n "${line_no}p" "$path")
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

# The candidate default-branch refs, probed the same way bin/fm-lint.sh's own
# fm_lint_changed_base_ref probes them so both agree on what "the default
# branch" means in a given checkout.
fm_voice_default_refs() {
  local ref
  if [ -n "${FM_VOICE_GUARD_BASE:-}" ]; then
    printf '%s\n' "$FM_VOICE_GUARD_BASE"
    return 0
  fi
  for ref in origin/main main; do
    if git rev-parse --verify -q "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
    fi
  done
}

# Commits on HEAD that no known default-branch ref already carries. Excluding
# every resolvable ref, not just the first, keeps a stale local main from
# dragging already-published history into the scan.
#
# Both failure modes return 3, never 1: an unresolvable ref and an unusable
# rev-list both mean the range is unknown, and an unknown range must not be
# reported as either clean or leaking.
fm_voice_unpublished_commits() {  # <destination>
  local destination=$1
  local -a refs
  local ref
  refs=()
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    refs+=("$ref")
  done < <(fm_voice_default_refs)

  if [ "${#refs[@]}" -eq 0 ]; then
    printf 'fm-voice-guard.sh: cannot determine which commits are unpublished: no default-branch ref resolved (tried %s).\n' \
      "${FM_VOICE_GUARD_BASE:-origin/main, main}" >&2
    printf 'fm-voice-guard.sh: fetch the default branch (git fetch origin main) or set FM_VOICE_GUARD_BASE, then re-run. An unknown range is not a clean range.\n' >&2
    return 3
  fi

  if ! git rev-list HEAD --not "${refs[@]}" > "$destination" 2>/dev/null; then
    printf 'fm-voice-guard.sh: cannot list the commits ahead of %s. An unknown range is not a clean range.\n' \
      "${refs[*]}" >&2
    return 3
  fi
}

MODE=range
RANGE=
TEXT_PATH=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --range)
      [ "$#" -ge 2 ] || { printf 'fm-voice-guard.sh: --range requires a revision range.\n' >&2; exit 2; }
      MODE=range
      RANGE=$2
      shift 2
      ;;
    --range=*) MODE=range; RANGE=${1#*=}; shift ;;
    --commit)
      [ "$#" -ge 2 ] || { printf 'fm-voice-guard.sh: --commit requires a revision.\n' >&2; exit 2; }
      MODE=commit
      RANGE=$2
      shift 2
      ;;
    --commit=*) MODE=commit; RANGE=${1#*=}; shift ;;
    --text)
      [ "$#" -ge 2 ] || { printf 'fm-voice-guard.sh: --text requires a path or "-".\n' >&2; exit 2; }
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
      printf 'fm-voice-guard.sh: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-voice-guard.XXXXXX") || exit 2
trap 'rm -rf "$TMP_ROOT"' EXIT

MESSAGE_FILE="$TMP_ROOT/message"
REPORT="$TMP_ROOT/report"
: > "$REPORT"
SUBJECT_LABEL=

if [ "$MODE" = text ]; then
  if [ "$TEXT_PATH" = - ]; then
    cat > "$MESSAGE_FILE"
  elif [ -f "$TEXT_PATH" ]; then
    cat -- "$TEXT_PATH" > "$MESSAGE_FILE"
  else
    printf 'fm-voice-guard.sh: no such text file: %s\n' "$TEXT_PATH" >&2
    exit 2
  fi
  SUBJECT_LABEL='the supplied text'
  if ! fm_voice_scan_file "text" "$MESSAGE_FILE" >> "$REPORT"; then
    FOUND=1
  else
    FOUND=0
  fi
else
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'fm-voice-guard.sh: not inside a git work tree.\n' >&2
    exit 2
  }

  COMMITS_FILE="$TMP_ROOT/commits"
  if [ "$MODE" = commit ]; then
    git rev-parse --verify -q "$RANGE^{commit}" > "$COMMITS_FILE" || {
      printf 'fm-voice-guard.sh: not a commit: %s\n' "$RANGE" >&2
      exit 2
    }
    SUBJECT_LABEL='that commit'
  elif [ -n "$RANGE" ]; then
    git rev-list "$RANGE" > "$COMMITS_FILE" 2>/dev/null || {
      printf 'fm-voice-guard.sh: not a revision range: %s\n' "$RANGE" >&2
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
    git log -1 --format=%B "$sha" > "$MESSAGE_FILE" 2>/dev/null || continue
    subject=$(git log -1 --format=%s "$sha" 2>/dev/null)
    if ! fm_voice_scan_file "commit $(printf '%.12s' "$sha") - $subject" "$MESSAGE_FILE" >> "$REPORT"; then
      FOUND=1
    fi
  done < "$COMMITS_FILE"
fi

if [ "$FOUND" -eq 0 ]; then
  exit 0
fi

{
  printf 'fm-voice-guard.sh: REFUSING - firstmate internal voice found in %s.\n' "$SUBJECT_LABEL"
  printf 'This text would become permanent public history under the repository owner'"'"'s name.\n'
  cat "$REPORT"
  printf '\n  How to clear this refusal:\n'
  if [ "$MODE" = text ]; then
    printf '    Reword the text above, then re-run this check.\n'
  else
    printf '    Reword the message so it states what the change does, then re-run this check:\n'
    printf '      git commit --amend        for the tip commit\n'
    printf '      git rebase -i <base>      then mark the named commits "reword"\n'
    printf '    Inside a no-mistakes run, respond to the gate and let the pipeline reword; do not push around this check.\n'
  fi
  printf '    Inspect the full rule table with: bin/fm-voice-guard.sh --list-patterns\n'
} >&2

exit 1
