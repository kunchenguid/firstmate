#!/usr/bin/env bash
# fm-intake-lib.sh - the Wardroom's append-only intake channel.
# Spec: docs/specs/2026-07-03-wardroom-intake.md.
#
# state/<id>.intake holds one line per event: `<kind>: <text>` with kind in
# proceed|revise|escalate|panel. proceed/revise/escalate are DECISIONS
# (fm-intake's outcome); panel lines are evidence (lens + thinker traces).
# A proceed may carry the panel's non-blocking notes on its own line - the
# council's findings are not lost just because they did not block.
# The gate consumed by fm-spawn is fm_intake_require_proceed: the LAST decision
# line must be proceed. FM_INTAKE_OVERRIDE=1 is the captain's explicit bypass
# and prints a loud banner so it never happens silently.
#
# Deliberately mirrors fm-verdict-lib.sh (spec: Deliberate decisions) - two
# small channels with different grammars beat a premature generic abstraction.
# Source this; do not execute it.

fm_intake_file() {  # <state-dir> <id>
  printf '%s/%s.intake\n' "$1" "$2"
}

fm_intake_append() {  # <state-dir> <id> <kind> <text>
  local kind=$3
  case "$kind" in
    proceed|revise|escalate|panel) : ;;
    *) echo "error: invalid intake kind '$kind' (proceed|revise|escalate|panel)" >&2; return 1 ;;
  esac
  printf '%s: %s\n' "$kind" "$4" >> "$(fm_intake_file "$1" "$2")"
}

fm_intake_last() {  # <state-dir> <id> -> kind of last decision line
  local f line
  f=$(fm_intake_file "$1" "$2")
  [ -f "$f" ] || return 1
  line=$(grep -E '^(proceed|revise|escalate):' "$f" | tail -1)
  [ -n "$line" ] || return 1
  printf '%s\n' "${line%%:*}"
}

fm_intake_revise_count() {  # <state-dir> <id>
  local f
  f=$(fm_intake_file "$1" "$2")
  [ -f "$f" ] || { echo 0; return 0; }
  grep -c '^revise:' "$f" || true
}

# --- the thinkers' severity grammar ------------------------------------------
#
# A thinker ends its reply with one PANEL line. Two of the four verdicts are
# NON-BLOCKING and two BLOCK:
#
#   PANEL: proceed             - nothing to say
#   PANEL: proceed-with-notes  - findings worth writing down that do not block
#   PANEL: revise              - a BLOCKING defect (worker would fail, do harm,
#                                or build the wrong thing)
#   PANEL: escalate            - only the captain may decide this
#
# proceed-with-notes is the word the council was missing. Without it a reviewer
# holding a real but non-blocking finding had nowhere to put it, so it either
# vetoed the spawn or was thrown away; across 96 verdicts it always vetoed.
# Non-blocking findings are now recorded on the proceed line and in the review
# file; firstmate folds what is worth folding into the brief before spawning.

# fm_intake_verdict <panel-line> -> proceed|proceed-with-notes|revise|escalate,
# or "invalid" for anything else. Deliberately strict: the caller maps invalid
# to escalate, so a garbled or absent verdict fails CLOSED. Matching a bare
# prefix would let `PANEL: proceeds` pass as a proceed, which is the one
# direction this function may never be loose in.
#
# The verdict word must be the WHOLE word, not a prefix that some other
# character happened to terminate. `PANEL: proceed/revise - unsure` is a thinker
# that could not choose, `PANEL: proceed_with_notes` is one that got the grammar
# wrong, and `PANEL: proceed?` is one that is guessing; reading a clean proceed
# out of any of them is the loose direction. So only two tails are accepted
# after the word: nothing at all, or the " - reason" the grammar asks for.
fm_intake_verdict() {
  local line=$1 word rest
  # A trailing CR or space is transport noise, not part of the verdict.
  while [ -n "$line" ] && [ "$line" != "${line%[[:space:]]}" ]; do line=${line%[[:space:]]}; done
  case "$line" in
    'PANEL: '*) rest=${line#PANEL: } ;;
    *) printf 'invalid\n'; return 0 ;;
  esac
  # Keep the leading run of lowercase letters and hyphens - the verdict word -
  # and hold on to whatever follows it, which must be the " - reason" tail.
  word=${rest%%[![:lower:]-]*}
  rest=${rest#"$word"}
  case "$rest" in
    '' | ' - '*) : ;;
    *) printf 'invalid\n'; return 0 ;;
  esac
  case "$word" in
    proceed|proceed-with-notes|revise|escalate) printf '%s\n' "$word" ;;
    *) printf 'invalid\n' ;;
  esac
}

# fm_intake_is_placeholder <panel-line> -> 0 when the line is the GRAMMAR
# TEMPLATE rather than a decision.
#
# The thinker prompt lists all four PANEL lines so a thinker knows the grammar,
# and each of those lines parses to a perfectly valid verdict. A model that
# echoes or restates the menu therefore emits real-looking verdicts it never
# reached - and `PANEL: escalate - <why the captain, not the crewmate, must
# decide>` would deterministically stop the spawn. What separates a template
# from a decision is the reason: a template's reason is a placeholder token,
# `<like this>`, where a decision's is prose. Matched by SHAPE, not by the four
# exact strings, so a reworded template is caught too.
fm_intake_is_placeholder() {
  local line=$1 word rest inner
  while [ -n "$line" ] && [ "$line" != "${line%[[:space:]]}" ]; do line=${line%[[:space:]]}; done
  case "$line" in
    'PANEL: '*) rest=${line#PANEL: } ;;
    *) return 1 ;;
  esac
  word=${rest%%[![:lower:]-]*}
  rest=${rest#"$word"}
  case "$rest" in
    ' - '*) rest=${rest# - } ;;
    *) return 1 ;;
  esac
  case "$rest" in
    '<'*'>')
      inner=${rest#<}
      inner=${inner%>}
      case "$inner" in
        *'>'*) return 1 ;;
        *) return 0 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# fm_intake_recent_kinds <state-dir> <window> -> the kind of each of the most
# recent <window> decisions, oldest first, one per line. Recency is file
# modification time across state/*.intake, then append order within a file.
# Nothing prunes .intake files, so this is what keeps the corpus bounded.
fm_intake_recent_kinds() {
  local dir=$1 window=$2 f
  local files=()
  for f in "$dir"/*.intake; do
    [ -f "$f" ] || continue
    files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  # shellcheck disable=SC2012 # find cannot portably order by mtime, and these
  # names are always "<task-id>.intake" with a kebab-slug id - no newlines.
  { ls -tr "${files[@]}" 2>/dev/null || true; } | while IFS= read -r f; do
    grep -E '^(proceed|revise|escalate):' "$f" || true
  done | sed 's/:.*//' | tail -n "$window"
}

# fm_intake_health <state-dir> [min-decisions] [window] -> prints one summary
# line; returns 1 when the council's proceed rate is STRUCTURALLY ZERO over the
# most recent decisions.
#
# A gate that can never pass is indistinguishable from a gate that is broken.
# The council ran 96 verdicts - 0 proceed, 59 revise, 37 escalate - before a
# human noticed it had no reachable exit, because nothing was watching the one
# number that would have said so. This is that watch. Zero proceeds over a
# meaningful sample is a fault in the BAR, not evidence that every brief was
# bad; below the sample floor it means nothing and this stays quiet.
#
# The judgement is a ROLLING WINDOW, not the all-time corpus, and that is the
# whole point: read cumulatively, the very first proceed would disarm this
# detector forever, so the one prompt regression it exists to catch could only
# ever be caught once. Over the last FM_INTAKE_HEALTH_WINDOW decisions it stays
# live - if a later change drives the proceed rate back to zero, it fires again.
fm_intake_health() {
  local dir=$1 min=${2:-${FM_INTAKE_HEALTH_MIN:-10}}
  local window=${3:-${FM_INTAKE_HEALTH_WINDOW:-20}}
  local p=0 r=0 e=0 total rate kinds kind
  # Both bounds are validated: a non-numeric value would make the comparison
  # below error out and read as false, which switches the detector OFF - the
  # silently-unwatched-watchdog failure this whole function exists to prevent.
  [ "$window" -ge 1 ] 2>/dev/null || window=20
  [ "$min" -ge 1 ] 2>/dev/null || min=10
  kinds=$(fm_intake_recent_kinds "$dir" "$window")
  if [ -n "$kinds" ]; then
    while IFS= read -r kind; do
      case "$kind" in
        proceed) p=$(( p + 1 )) ;;
        revise) r=$(( r + 1 )) ;;
        escalate) e=$(( e + 1 )) ;;
      esac
    done <<EOF
$kinds
EOF
  fi
  total=$(( p + r + e ))
  rate=0
  [ "$total" -gt 0 ] && rate=$(( p * 100 / total ))
  printf 'intake health: decisions=%d proceed=%d revise=%d escalate=%d proceed-rate=%d%% window=%d\n' \
    "$total" "$p" "$r" "$e" "$rate" "$window"
  if [ "$total" -ge "$min" ] && [ "$p" -eq 0 ]; then
    return 1
  fi
  return 0
}

fm_intake_require_proceed() {  # <state-dir> <id> <label>
  local last
  if [ "${FM_INTAKE_OVERRIDE:-}" = 1 ]; then
    {
      echo "==================== WARDROOM OVERRIDE ===================="
      echo "WARNING: $3 spawning task $2 WITHOUT an intake proceed"
      echo "(FM_INTAKE_OVERRIDE=1 - captain authority; logged, not silent)"
      echo "==========================================================="
    } >&2
    return 0
  fi
  last=$(fm_intake_last "$1" "$2" 2>/dev/null) || last=none
  if [ "$last" != proceed ]; then
    {
      echo "======================== WARDROOM ========================="
      echo "REFUSED: $3 for task $2 - no intake proceed (last intake: $last)"
      echo "Run: bin/fm-intake.sh $2 <project-dir>"
      echo "Captain bypass (loud, logged): FM_INTAKE_OVERRIDE=1"
      echo "==========================================================="
    } >&2
    return 1
  fi
  return 0
}
