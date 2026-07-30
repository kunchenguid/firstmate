#!/usr/bin/env bash
# fm-skill-index.sh - render the agent-only skill trigger index from skill frontmatter.
#
# This script is the single owner of the trigger index's CONTENT and of the
# decision about WHEN to emit it. AGENTS.md keeps only the one-line rule that an
# agent-only skill loads at its declared trigger; the triggers themselves live in
# each skill's own frontmatter `description:` and are rendered from there, so a
# new skill is registered in exactly one place instead of two.
#
# WHICH SKILLS: every `.agents/skills/*/SKILL.md` whose frontmatter carries
# `user-invocable: false`. That marker already distinguishes the agent-only
# reference skills from the captain-invocable ones (/afk, /ahoy, /bearings,
# /stow, /updatefirstmate), so no second roster is maintained here.
#
# WHEN IT IS EMITTED, and why the default is to emit:
#   Some harnesses inject every skill's frontmatter description into the session
#   prompt unprompted. On those, a rendered index is a measured duplicate and is
#   suppressed. On every other harness the index may be the only trigger listing
#   the session ever sees, so it is emitted.
#   Suppression therefore requires POSITIVE evidence that the harness injects
#   descriptions. An unverified or unknown harness always gets the index: a
#   redundant listing costs bytes, while a wrongly suppressed one silently
#   removes every agent-only skill's load trigger. Record new evidence in
#   `.agents/skills/harness-adapters/SKILL.md` before adding a harness here.
#
# Verified injecting harnesses (suppressed):
#   claude - the harness lists every skill with its description in the system
#            prompt; observed directly in a live claude primary session.
#   grok   - `harness-adapters` records "firstmate skills are discovered" and a
#            verified end-to-end `/<skill>` invocation.
# Everything else (codex, opencode, pi, pi-signed, kimi, unknown) is emitted.
#
# Usage: fm-skill-index.sh [--harness <name>] [--force] [--list-agent-only]
#   --harness <name>   render for this harness; default is the detected primary.
#   --force            emit even for a suppressed harness (tests and inspection).
#   --list-agent-only  print just the agent-only skill names, one per line.
# Always exits 0 when it can read the skill directory: this is a reporting
# command composed into the session-start digest, never a gate.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="${FM_SKILL_DIR_OVERRIDE:-$REPO_ROOT/.agents/skills}"

HARNESS=
FORCE=0
LIST_ONLY=0

usage() {
  cat <<'EOF'
Usage: fm-skill-index.sh [--harness <name>] [--force] [--list-agent-only]

Render the agent-only skill trigger index from each skill's frontmatter.
  --harness <name>   render for this harness; default is the detected primary.
  --force            emit even for a suppressed harness (tests and inspection).
  --list-agent-only  print just the agent-only skill names, one per line.

Prints nothing on a harness that already injects skill descriptions (claude,
grok), so the index is never a duplicate. Prints the full index on every other
harness, including an unknown one, because suppressing it there would silently
remove every agent-only skill's load trigger.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness)
      [ "$#" -gt 1 ] || { echo "error: --harness requires a value" >&2; exit 2; }
      HARNESS=$2
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --list-agent-only)
      LIST_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[ -n "$HARNESS" ] || HARNESS=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)

# Positive-evidence suppression list; see the header before adding a harness.
harness_injects_descriptions() {
  case "$1" in
    claude|grok) return 0 ;;
    *) return 1 ;;
  esac
}

[ -d "$SKILL_DIR" ] || exit 0

if [ "$LIST_ONLY" -eq 0 ] && [ "$FORCE" -eq 0 ] && harness_injects_descriptions "$HARNESS"; then
  exit 0
fi

# Render each agent-only skill as one "- <name> - <description>" line.
# The frontmatter is the first --- ... --- block. `description:` may be an inline
# scalar or a folded/literal block whose indented continuation lines join with
# single spaces; both forms collapse to one line here.
render() {
  local file
  for file in "$SKILL_DIR"/*/SKILL.md; do
    [ -f "$file" ] || continue
    awk '
      BEGIN { in_fm = 0; seen_open = 0; agent_only = 0; name = ""; desc = ""; collecting = 0 }
      NR == 1 && $0 == "---" { in_fm = 1; seen_open = 1; next }
      in_fm && $0 == "---" { in_fm = 0; next }
      !in_fm { next }

      # A non-indented "key:" line ends any block scalar being collected.
      /^[^[:space:]#][^:]*:/ { collecting = 0 }

      /^name:[[:space:]]*/ {
        name = $0
        sub(/^name:[[:space:]]*/, "", name)
        next
      }
      /^user-invocable:[[:space:]]*/ {
        v = $0
        sub(/^user-invocable:[[:space:]]*/, "", v)
        gsub(/[[:space:]]+$/, "", v)
        if (v == "false") agent_only = 1
        next
      }
      /^description:[[:space:]]*/ {
        v = $0
        sub(/^description:[[:space:]]*/, "", v)
        gsub(/[[:space:]]+$/, "", v)
        if (v == ">-" || v == ">" || v == "|" || v == "|-") {
          collecting = 1
        } else {
          desc = v
        }
        next
      }
      collecting && /^[[:space:]]+/ {
        line = $0
        gsub(/^[[:space:]]+/, "", line)
        gsub(/[[:space:]]+$/, "", line)
        if (line != "") desc = (desc == "" ? line : desc " " line)
        next
      }

      END {
        if (!seen_open || !agent_only || name == "") exit 0
        if (list_only) { print name; exit 0 }
        if (desc == "") desc = "(no description in frontmatter)"
        printf "- %s - %s\n", name, desc
      }
    ' list_only="$LIST_ONLY" "$file"
  done
}

if [ "$LIST_ONLY" -eq 1 ]; then
  render | LC_ALL=C sort
  exit 0
fi

BODY=$(render | LC_ALL=C sort)
[ -n "$BODY" ] || exit 0

printf 'AGENT-ONLY SKILL TRIGGERS (harness %s does not inject skill descriptions)\n' "$HARNESS"
printf 'These skills are not captain-invocable; load one only at its trigger below.\n\n'
printf '%s\n' "$BODY"
exit 0
