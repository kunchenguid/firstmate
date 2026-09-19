#!/usr/bin/env bash
# Validate the shape of a generated project-local verification skill.
# The verification-skill agent skill (.agents/skills/verification-skill) is the
# single owner of the generation contract; this script is the single owner of
# that contract's executable shape check and is what the generator skill runs
# on its own output before handover. It checks the directory layout, the
# SKILL.md frontmatter name, the required H2 sections, the never-kill-by-
# process-name cleanup rule, the feature-map index, and that no placeholder
# survived generation. It intentionally checks shape, not behavior: proving
# the skill live is the generator skill's own required run.
# This is a worktree utility for crewmates, not a supervision script, so it
# does not call fm-guard.sh.
# Usage: fm-verification-skill-check.sh <skill-directory>
set -eu

usage() {
  echo "usage: fm-verification-skill-check.sh <skill-directory>" >&2
  echo "  exit 0: the generated verification skill has the required shape." >&2
  echo "  exit 1: one or more shape failures (each printed to stderr)." >&2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac
[ "$#" -eq 1 ] || { usage; exit 1; }

DIR=$1
if [ ! -d "$DIR" ]; then
  echo "FAIL: not a directory: $DIR" >&2
  exit 1
fi
DIR=$(cd "$DIR" && pwd -P)
BASENAME=$(basename "$DIR")
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

has_content() {
  printf '%s\n' "$1" | grep -q '[^[:space:]]'
}

section_body() {
  local file=$1
  local heading=$2
  awk -v want="$heading" '
    $0 == "## " want { insec = 1; next }
    /^## / { insec = 0 }
    insec { print }
  ' "$file"
}

SKILL="$DIR/SKILL.md"
if [ ! -f "$SKILL" ]; then
  echo "FAIL: missing $DIR/SKILL.md" >&2
  exit 1
fi

if ! FRONTMATTER=$(awk '
  NR == 1 && $0 == "---" { opened = 1; next }
  opened && $0 == "---" { closed = 1; exit }
  opened { print }
  END { if (!opened || !closed) exit 1 }
' "$SKILL"); then
  fail "SKILL.md must have opening and closing YAML frontmatter delimiters"
  FRONTMATTER=
fi
NAME=$(printf '%s\n' "$FRONTMATTER" | sed -n 's/^name:[[:space:]]*//p' | head -1)
[ -n "$NAME" ] || fail "SKILL.md frontmatter has no name: field"
if ! printf '%s\n' "$FRONTMATTER" | awk '
  /^description:[[:space:]]*/ {
    value = $0
    sub(/^description:[[:space:]]*/, "", value)
    if (value ~ /^[>|][-+]?$/) { block = 1; next }
    sub(/[[:space:]]+$/, "", value)
    lower = tolower(value)
    numeric = value ~ /^[-+]?[0-9][0-9_]*(\.[0-9_]*)?([eE][-+]?[0-9][0-9_]*)?$/ \
      || value ~ /^[-+]?\.[0-9][0-9_]*([eE][-+]?[0-9][0-9_]*)?$/ \
      || value ~ /^0[xX][[:xdigit:]_]+$/ \
      || value ~ /^0[oO][0-7_]+$/
    if (value ~ /^[[:alnum:]]/ \
        && lower !~ /^(null|~|true|false|yes|no|on|off)$/ \
        && !numeric \
        && value !~ /:[[:space:]]|:$/) valid = 1
    exit
  }
  block && /^[[:space:]]+/ && /[^[:space:]]/ { valid = 1; exit }
  block && !/^[[:space:]]*$/ { exit }
  END { exit valid ? 0 : 1 }
'; then
  fail "SKILL.md frontmatter description is missing or invalid"
fi
case "$NAME" in
  verify-*) ;;
  *) fail "skill name must start with verify- (got: ${NAME:-none})" ;;
esac
if [ -n "$NAME" ] && [ "$NAME" != "$BASENAME" ]; then
  fail "skill name '$NAME' does not match directory name '$BASENAME'"
fi

for heading in Launch Doctor Drive Evidence Cleanup Helpers; do
  body=$(section_body "$SKILL" "$heading")
  has_content "$body" || fail "SKILL.md is missing a non-empty '## $heading' section"
done

# The cleanup rule is the contract point most likely to be dropped: cleanup
# must carry the never-kill-by-process-name prohibition verbatim enough to
# match, so a future editor cannot silently delete it. Phrase matching is
# whitespace-tolerant so prose line wrapping cannot hide the rule.
CLEANUP_BODY=$(section_body "$SKILL" "Cleanup" | tr '\n' ' ')
printf '%s\n' "$CLEANUP_BODY" | grep -Eqi "kill[[:space:]]+by[[:space:]]+process[[:space:]]+name" \
  || fail "Cleanup section must state the rule: never kill by process name; kill what you started"

EVIDENCE_BODY=$(section_body "$SKILL" "Evidence" | tr '\n' ' ')
printf '%s\n' "$EVIDENCE_BODY" | grep -Eqi "user[[:space:]]+path" \
  || fail "Evidence section must require exercising the real user path"

FEATURES="$DIR/features/README.md"
if [ ! -f "$FEATURES" ]; then
  fail "missing features/README.md feature-map index"
else
  mapfile -t siblings < <(find "$DIR/features" -maxdepth 1 -type f ! -name README.md -name '*.md' | sort)
  [ "${#siblings[@]}" -ge 1 ] || fail "features/ has no feature files beside README.md"
  for feature in "${siblings[@]}"; do
    filename=$(basename "$feature")
    if ! grep -Fq "($filename)" "$FEATURES" && ! grep -Fq "(./$filename)" "$FEATURES"; then
      fail "features/README.md does not reference $filename"
    fi

    for heading in "Sub-features" "How to get to it (user POV)" "Gotchas"; do
      body=$(section_body "$feature" "$heading")
      has_content "$body" || fail "$filename is missing a non-empty '## $heading' section"
    done
    body=$(awk '
      /^## Driving it with .+[^[:space:]][[:space:]]*$/ { insec = 1; next }
      /^## / { insec = 0 }
      insec { print }
    ' "$feature")
    has_content "$body" || fail "$filename is missing a non-empty '## Driving it with <harness>' section"
  done
fi

if grep -rnE '<app>|<harness>|TODO|TBD|PLACEHOLDER' "$DIR" --include='*.md' --include='*.sh' >/dev/null 2>&1; then
  fail "placeholder or template marker left behind:"
  grep -rnE '<app>|<harness>|TODO|TBD|PLACEHOLDER' "$DIR" --include='*.md' --include='*.sh' | sed 's/^/  /' >&2
fi

if [ "$failures" -gt 0 ]; then
  echo "fm-verification-skill-check: $failures failure(s) in $DIR" >&2
  exit 1
fi
echo "ok: $DIR has the required verification-skill shape"
