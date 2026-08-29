#!/usr/bin/env bash
# fm-learning-recurrence.sh - measure how many times a promoted learning's
# guarded defect pattern has been (re)introduced into its guarded file(s)
# since the rule was recorded.
#
# Usage:
#   bin/fm-learning-recurrence.sh <rule-id>
#   bin/fm-learning-recurrence.sh --list
#
# A promoted learning (data/learnings.md, private and not read by this
# script) is not "learned" until it binds as an executable check - see the
# matching tests/<subject>.test.sh - AND its recurrence is measured rather
# than remembered. The check answers "does the defect exist right now";
# this script answers "how many times has it come back": it walks this
# repo's own commit history for the rule's guarded path(s) and counts every
# commit whose diff ADDS a line matching the rule's banned pattern, then
# splits that count into introductions before the rule existed and
# recurrences on or after the date the rule was recorded. Git history is the
# source of truth here on purpose - a hand-kept recurrence tally is exactly
# the kind of remembered process this fleet has already measured dropping
# steps under load (see data/learnings.md, "Merge, teardown, and
# record-done are three commands").
#
# A nonzero recurrence count means the binding check either did not exist
# yet at the time or was bypassed (e.g. a hotfix landed without the test
# suite). Per data/learnings.md doctrine, "a rule with recurrences is a
# wish, not a rule" - that is a signal to escalate the check's design, not
# to re-record the rule.
#
# To promote a new learning here: add a case arm below naming its guarded
# path(s), its banned pattern (POSIX ERE, matched against added lines only,
# comment lines excluded), and the date (YYYY-MM-DD) the rule was recorded.
# Add its binding check in the matching tests/<subject>.test.sh at the same
# time - this script only measures; it does not enforce anything itself.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-learning-recurrence-lib.sh
. "$SCRIPT_DIR/fm-learning-recurrence-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

list_rules() {
  cat <<'EOF'
no-mistakes-cli-not-skill  recorded=2026-08-22  guards=bin/fm-brief.sh
  Spawned Claude workers inherit firstmate's CLAUDE_CONFIG_DIR, which has no
  user-level skills directory, so an instruction to invoke a skill by name
  gets "Unknown skill" and stalls. Ship briefs must route validation through
  the no-mistakes CLI, never through a literal "/no-mistakes" invocation.
  Binding check: tests/fm-brief.test.sh:test_ship_briefs_never_instruct_skill_invocation
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --list) list_rules; exit 0 ;;
esac

RULE_ID="${1:-}"
[ -n "$RULE_ID" ] || { echo "usage: fm-learning-recurrence.sh <rule-id> | --list" >&2; exit 1; }

case "$RULE_ID" in
  no-mistakes-cli-not-skill)
    RECORDED=2026-08-22
    PATTERN='/no-mistakes'
    GUARDED=(bin/fm-brief.sh)
    ;;
  *)
    echo "error: unknown rule id '$RULE_ID' (bin/fm-learning-recurrence.sh --list)" >&2
    exit 2
    ;;
esac

introductions_total=0
recurrences_since_recorded=0
events=""
for path in "${GUARDED[@]}"; do
  while IFS=' ' read -r date sha; do
    [ -n "$date" ] || continue
    introductions_total=$((introductions_total + 1))
    events="$events$date $sha $path"$'\n'
    if [[ "$date" > "$RECORDED" || "$date" == "$RECORDED" ]]; then
      recurrences_since_recorded=$((recurrences_since_recorded + 1))
    fi
  done < <(introductions_for_path "$ROOT" "$path" "$PATTERN")
done

echo "rule=$RULE_ID"
echo "recorded=$RECORDED"
echo "guarded=${GUARDED[*]}"
echo "pattern=$PATTERN"
echo "introductions_total=$introductions_total"
echo "recurrences_since_recorded=$recurrences_since_recorded"
if [ -n "$events" ]; then
  echo "events:"
  printf '%s' "$events"
fi
