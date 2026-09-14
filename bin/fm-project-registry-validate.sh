#!/usr/bin/env bash
# Validates data/projects.md for status-protocol lines that do not belong.
#
# The registry is a free-form markdown file with headers, prose, project
# entries, and continuation notes. Validating its full shape is impractical
# because the file legitimately contains narrative paragraphs, bold text,
# indented annotations, and non-standard mode brackets.
#
# What this validator catches is the concrete threat that prompted it:
# status-protocol lines (done:, working:, blocked:, failed:, needs-decision:,
# paused:, resolved:, note:) that belong in state/<id>.status and were
# appended to the registry by an agent editing or appending to the wrong file.
#
# Exits 0 when clean, 1 when violations are found. Prints one PROJECT_REGISTRY
# diagnostic per violation to stderr.
#
# Usage: fm-project-registry-validate.sh <registry-file>
set -eu

usage() {
  echo "usage: fm-project-registry-validate.sh <registry-file>" >&2
  exit 2
}

REG="${1:-}"
[ -z "$REG" ] && usage

[ -f "$REG" ] || exit 0

# Status-protocol verbs from the brief scaffold (AGENTS.md section 4, rule 4).
# A line is a status-protocol line when it starts with one of these verbs
# followed by a colon, optionally with a bracketed key after the verb.
STATUS_VERBS='done|working|blocked|failed|needs-decision|paused|resolved|note'

line_num=0
errors=0
while IFS= read -r line; do
  line_num=$((line_num + 1))
  # Match: verb: ... or verb [key=...]: ...
  # Use grep -E for extended regex on all platforms.
  if printf '%s\n' "$line" | grep -Eq "^($STATUS_VERBS)( \[.*\])?: "; then
    printf 'PROJECT_REGISTRY: status-protocol line at line %d: '\''%s'\''\n' "$line_num" "$line" >&2
    errors=1
  fi
done < "$REG"

[ "$errors" -eq 0 ] || exit 1
exit 0
