#!/usr/bin/env bash
# fm-jev-skill-select.sh - once-per-session Jev skill selector (shadow default).
#
# Usage:
#   fm-jev-skill-select.sh --harness <name> --task-id <id> [--summary <text>]
#     [--skills-dir <dir>] [--max <n>] [--status-note] [--stdin]
#     [--overlay <launch-brief>] [skill-id ...]
#
# Input: a harness name, an optional privacy-safe query as --summary, and installed skill ids from
#   --skills-dir children, positional arguments, and stdin (--stdin, or stdin
#   when no other skill source is given and stdin is not a terminal).
#   Never pass page content, excerpts, or conflict lines in --summary.
#
# One Choice question whose options are the installed skill ids (capped), plus
#   fixed none and search_external options. Up to --max skills (default 3) are
#   taken from the chosen primary plus remaining probabilities. Confidence
#   floor 0.7; below the floor the recorded status is uncertain.
#   docs/configuration.md "Jev skill selector" owns the operator contract;
#   this header owns flags, the JSON file, overlay injection, and live_loaded.
#
# Default FM_JEV_SKILL_SELECT=shadow (also when unset): write
#   $FM_HOME/state/<task-id>.jev-skills.json and print it on stdout. Do not
#   load skills. Do not append a status note unless --status-note is passed.
#   A later call for the same task reuses that file and does not call Jev
#   again (once per session/task, not per prompt).
#
# Live load requires FM_JEV_SKILL_SELECT=live and the presence file
#   $FM_HOME/config/jev-skill-select-live. Spawn passes --overlay at the
#   published launch-brief after profile resolution. Skills then reach the
#   worker in that private overlay, using the harness's skill-invocation form
#   (slash, dollar, or named-file). live_loaded is true only after those
#   skill ids are verified in the overlay file. A missing overlay, Choice
#   none, uncertain/error status, shadow mode, or any write/verify failure
#   leaves live_loaded false and does not change a worker launch that would
#   otherwise proceed. This tool never blocks spawn: exit 0 for clear,
#   uncertain, error, off, and reuse. Exit 2 for usage or a live request
#   without the confirm file.
#
# Environment:
#   FM_HOME, FM_JEV_SKILL_SELECT (shadow|live), TYPESAFE_API_KEY,
#   OPENROUTER_API_KEY, and the Jev library variables in bin/fm-jev-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

CONFIDENCE_FLOOR=0.7
DEFAULT_MAX=3
CATALOG_MAX=24
LIVE_CONFIRM="${FM_JEV_SKILL_SELECT_LIVE_CONFIRM:-$FM_HOME/config/jev-skill-select-live}"
MODE=${FM_JEV_SKILL_SELECT:-shadow}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

HARNESS='' TASK_ID='' SUMMARY='' OVERLAY='' STATUS_NOTE=0 READ_STDIN=0 MAX=$DEFAULT_MAX
SKILLS_DIRS=()
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) [ $# -ge 2 ] || die "--harness needs a value"; HARNESS=$2; shift 2 ;;
    --task-id) [ $# -ge 2 ] || die "--task-id needs a value"; TASK_ID=$2; shift 2 ;;
    --summary) [ $# -ge 2 ] || die "--summary needs a value"; SUMMARY=$2; shift 2 ;;
    --skills-dir) [ $# -ge 2 ] || die "--skills-dir needs a value"; SKILLS_DIRS+=("$2"); shift 2 ;;
    --max)
      [ $# -ge 2 ] || die "--max needs a value"
      case "$2" in
        ''|*[!0-9]*) die "--max needs a positive integer" ;;
        0) die "--max needs a positive integer" ;;
      esac
      MAX=$2
      shift 2
      ;;
    --overlay)
      [ $# -ge 2 ] || die "--overlay needs a value"
      OVERLAY=$2
      shift 2
      ;;
    --status-note) STATUS_NOTE=1; shift ;;
    --stdin) READ_STDIN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) die "unknown flag $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

case "$MODE" in
  shadow|live) ;;
  *) die "FM_JEV_SKILL_SELECT must be shadow or live (got ${MODE})" ;;
esac

[ -n "$HARNESS" ] || die "--harness is required (see --help)"
[ -n "$TASK_ID" ] || die "--task-id is required (see --help)"
case "$TASK_ID" in
  *[!A-Za-z0-9._:-]*|'') die "task-id must match [A-Za-z0-9._:-]+" ;;
esac
command -v jq >/dev/null 2>&1 || die "jq required"

if [ "$MODE" = live ]; then
  if [ ! -f "$LIVE_CONFIRM" ]; then
    die "live skill load refused: missing confirm file $LIVE_CONFIRM"
  fi
fi

STATE_DIR="$FM_HOME/state"
OUT="$STATE_DIR/${TASK_ID}.jev-skills.json"
mkdir -p "$STATE_DIR" || die "could not create $STATE_DIR"

# Harness skill-invocation form honored by the worker's launch overlay.
# Slash and dollar forms are the verified composer commands; everything else
# is the installed skill id for a natural-language load.
fm_jev_skill_invoke_form() {
  local id=$1
  case "$HARNESS" in
    codex) printf '$%s' "$id" ;;
    claude|grok|kimi|cursor|gemini|muse|rovo) printf '/%s' "$id" ;;
    *) printf '%s' "$id" ;;
  esac
}

fm_jev_skill_file() {
  local id=$1 dir
  for dir in ${SKILLS_DIRS+"${SKILLS_DIRS[@]}"}; do
    if [ -f "$dir/$id/SKILL.md" ] && [ -r "$dir/$id/SKILL.md" ]; then
      printf '%s/%s/SKILL.md' "$dir" "$id"
      return 0
    fi
  done
  return 1
}

# Write the selected skills into the published launch-brief overlay.
# Returns 0 only when every skill id is then present in that file.
# A non-zero return leaves the caller's live_loaded false without failing spawn.
overlay_apply_ok() {
  local skills_json=$1 status=$2
  local overlay_dir tmp heading count id skill_file
  [ "$MODE" = live ] || return 1
  [ -n "$OVERLAY" ] || return 1
  [ -f "$OVERLAY" ] && [ -w "$OVERLAY" ] || return 1
  [ "$status" = clear ] || return 1
  count=$(jq -r 'if type == "array" then length else 0 end' <<<"$skills_json" 2>/dev/null) || return 1
  [ "$count" -gt 0 ] || return 1

  while IFS= read -r id; do
    fm_jev_skill_file "$id" >/dev/null || return 1
  done < <(jq -r '.[]' <<<"$skills_json")

  heading='# Jev-selected skills'
  overlay_dir=$(dirname "$OVERLAY")
  tmp=$(mktemp "$overlay_dir/.jev-skills-overlay.XXXXXX") || return 1
  awk -v heading="$heading" '
    $0 == heading { skip=1; next }
    skip && /^# / { skip=0 }
    skip { next }
    { print }
  ' "$OVERLAY" > "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf '\n%s\n' "$heading"
    printf '%s\n' 'This launch selected the following installed skills.'
    printf '%s\n' 'Load them now, before doing the assigned work, using this runtime'\''s skill form when it has one, otherwise by reading the installed skill file.'
    printf '%s\n' 'Do not speculatively search beyond these skills as part of this selection step.'
    printf '%s\n' 'Discover and load other applicable skills whenever the task requires them.'
    jq -r '.[]' <<<"$skills_json" | while IFS= read -r id; do
      [ -n "$id" ] || continue
      form=$(fm_jev_skill_invoke_form "$id")
      skill_file=$(fm_jev_skill_file "$id") || exit 1
      printf -- "- %s: read \`%s\`\n" "$form" "$skill_file"
    done
  } >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$OVERLAY" || { rm -f "$tmp"; return 1; }

  jq -r '.[]' <<<"$skills_json" | while IFS= read -r id; do
    [ -n "$id" ] || continue
    grep -F -q "$id" "$OVERLAY" || exit 1
  done || return 1
  grep -F -q "$heading" "$OVERLAY" || return 1
  return 0
}

record_live_loaded() {
  local live_loaded=$1 reused=$2 tmp
  tmp="${OUT}.tmp.$$"
  jq --argjson live_loaded "$live_loaded" --argjson reused "$reused" \
    '.live_loaded = $live_loaded | .reused = $reused' "$OUT" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$OUT"
}

if [ -f "$OUT" ]; then
  jq -e 'type == "object"' "$OUT" >/dev/null 2>&1 || die "existing $OUT is not a JSON object"
  if [ -n "$OVERLAY" ]; then
    skills_json=$(jq -c '.skills // []' "$OUT")
    rec_status=$(jq -r '.status // "error"' "$OUT")
    live_loaded=false
    if overlay_apply_ok "$skills_json" "$rec_status"; then
      live_loaded=true
    fi
    record_live_loaded "$live_loaded" true || true
    cat "$OUT"
  else
    jq --argjson reused true '.reused = $reused' "$OUT"
  fi
  exit 0
fi

TMPDIR=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMPDIR"' EXIT
CATALOG="$TMPDIR/skills"

add_skill() {
  local id=$1
  case "$id" in
    ''|none|search_external) return 0 ;;
    *[!A-Za-z0-9._:/-]*) return 0 ;;
  esac
  printf '%s\n' "$id" >> "$CATALOG"
}

: > "$CATALOG"
for dir in ${SKILLS_DIRS+"${SKILLS_DIRS[@]}"}; do
  [ -d "$dir" ] || die "skills dir not a directory: $dir"
  [ -r "$dir" ] || die "skills dir not readable: $dir"
  for path in "$dir"/*; do
    [ -f "$path/SKILL.md" ] && [ -r "$path/SKILL.md" ] || continue
    add_skill "$(basename "$path")"
  done
done

for id in ${POSITIONAL+"${POSITIONAL[@]}"}; do
  add_skill "$id"
done

if [ "$READ_STDIN" = 1 ] || { [ ${#SKILLS_DIRS[@]} -eq 0 ] && [ ${#POSITIONAL[@]} -eq 0 ] && [ ! -t 0 ]; }; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    add_skill "$line"
  done
fi

if [ -s "$CATALOG" ]; then
  awk 'NF && !seen[$0]++' "$CATALOG" > "$TMPDIR/skills.uniq"
  mv "$TMPDIR/skills.uniq" "$CATALOG"
fi

SKILLS_JSON=$(jq -Rsc 'split("\n") | map(select(length > 0))' < "$CATALOG")
SKILL_COUNT=$(jq 'length' <<<"$SKILLS_JSON")
TRUNCATED=false
if [ "$SKILL_COUNT" -gt "$CATALOG_MAX" ]; then
  TRUNCATED=true
fi

QUESTIONS=$(jq -n --argjson skills "$SKILLS_JSON" --argjson max "$CATALOG_MAX" '
  def take: $skills[:$max];
  def criteria:
    (take | map({key: ., value: ("Installed skill " + .)}) | from_entries)
    + {
        none: "Load no extra skill this session.",
        search_external: "A useful skill is missing from the installed list."
      };
  {
    skill: {
      type: "choice",
      instructions: "Once for this worker session, pick the single most useful installed skill to load. Prefer none when the brief is enough. Prefer search_external only when a missing skill would materially help.",
      criteria: criteria
    }
  }
') || die "could not build Jev questions"

SUMMARY_TEXT=$SUMMARY
[ -n "$SUMMARY_TEXT" ] || SUMMARY_TEXT='(none)'
INSTALLED_LIST=$(jq -r 'join(", ")' <<<"$SKILLS_JSON")
STATE=$(printf 'harness: %s\ntask_id: %s\nsummary: %s\ninstalled_skills: %s\n' \
  "$HARNESS" "$TASK_ID" "$SUMMARY_TEXT" "$INSTALLED_LIST")
if ! STATE=$(fm_jev_compact_state "$STATE"); then
  die "task summary is too large for Jev state"
fi

write_record() {
  local status=$1 primary=$2 confidence=$3 probabilities=$4 skills_json=$5 reason=$6 reused=$7
  local live_loaded=${8:-false}
  jq -n \
    --arg task_id "$TASK_ID" \
    --arg harness "$HARNESS" \
    --arg summary "$SUMMARY" \
    --arg mode "$MODE" \
    --arg status "$status" \
    --arg primary "$primary" \
    --arg reason "$reason" \
    --argjson confidence "$confidence" \
    --argjson probabilities "$probabilities" \
    --argjson skills "$skills_json" \
    --argjson floor "$CONFIDENCE_FLOOR" \
    --argjson max "$MAX" \
    --argjson catalog_truncated "$TRUNCATED" \
    --argjson live_loaded "$live_loaded" \
    --argjson reused "$reused" \
    '{
      version: 1,
      task_id: $task_id,
      harness: $harness,
      summary: $summary,
      mode: $mode,
      status: $status,
      primary: (if $primary == "" then null else $primary end),
      skills: $skills,
      confidence: $confidence,
      probabilities: $probabilities,
      floor: $floor,
      max: $max,
      catalog_truncated: $catalog_truncated,
      live_loaded: $live_loaded,
      once: true,
      reused: $reused,
      reason: $reason
    }' > "$TMPDIR/record.json" || die "could not render JSON record"
  cp "$TMPDIR/record.json" "$OUT" || die "could not write $OUT"
  cat "$OUT"
}

maybe_status_note() {
  local status=$1 primary=$2 confidence=$3
  [ "$STATUS_NOTE" = 1 ] || return 0
  local label=$primary
  [ -n "$label" ] || label=none
  printf 'note: jev-skills %s primary=%s confidence=%s\n' "$status" "$label" "$confidence" \
    >> "$STATE_DIR/${TASK_ID}.status"
}

off_without_keys() {
  printf 'jev-skill-select: off (no TYPESAFE_API_KEY or OPENROUTER_API_KEY)\n' >&2
  exit 0
}

# Key presence matches fm-jev-lib.sh: env first, else $FM_HOME/.env.
if [ -z "${TYPESAFE_API_KEY:-}" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
  ts_key=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  or_key=$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")
  if [ -z "$ts_key" ] && [ -z "$or_key" ]; then
    off_without_keys
  fi
fi

DECIDE_ERR="$TMPDIR/decide.err"
DECIDE_CODE=0
RESPONSE=$(fm_jev_decide "$STATE" "$QUESTIONS" 2>"$DECIDE_ERR") || DECIDE_CODE=$?
if [ "$DECIDE_CODE" -ne 0 ]; then
  reason=$(tr '\n' ' ' < "$DECIDE_ERR" | sed 's/[[:space:]]*$//')
  [ -n "$reason" ] || reason="jev decide failed (exit $DECIDE_CODE)"
  write_record error '' 0 '{}' '[]' "$reason" false
  maybe_status_note error none 0
  exit 0
fi

fm_jev_log_call "$(jq -nc --arg purpose skill-select --arg task "$TASK_ID" --arg harness "$HARNESS" \
  '{purpose:$purpose,task:$task,harness:$harness}')" >/dev/null 2>&1 || true

CHOICE=$(jq -r '.answers.skill.choice // empty' <<<"$RESPONSE")
CONFIDENCE=$(jq -r '.answers.skill.confidence // empty' <<<"$RESPONSE")
PROBS=$(jq -c '.answers.skill.probabilities // empty' <<<"$RESPONSE")

if [ -z "$CHOICE" ] || [ -z "$CONFIDENCE" ] || [ -z "$PROBS" ] || [ "$PROBS" = 'null' ]; then
  write_record error '' 0 '{}' '[]' 'malformed Jev skill answer' false
  maybe_status_note error none 0
  exit 0
fi

if ! jq -e --arg choice "$CHOICE" '
    .answers.skill.probabilities | type == "object" and has($choice)
  ' <<<"$RESPONSE" >/dev/null; then
  write_record error '' 0 '{}' '[]' 'choice missing from probabilities' false
  maybe_status_note error none 0
  exit 0
fi

if ! fm_jev_probabilities_sum_ok "$PROBS"; then
  write_record error "$CHOICE" 0 "$PROBS" '[]' 'probabilities do not sum to 1' false
  maybe_status_note error "$CHOICE" 0
  exit 0
fi

if ! jq -e --arg conf "$CONFIDENCE" '$conf | tonumber | . == .' >/dev/null 2>&1 <<<"{}"; then
  write_record error "$CHOICE" 0 "$PROBS" '[]' 'confidence is not a number' false
  maybe_status_note error "$CHOICE" 0
  exit 0
fi

CONF_JSON=$(jq -n --arg c "$CONFIDENCE" '$c | tonumber')

STATUS=clear
REASON=''
if ! fm_jev_choice_confidence_ok "$CONFIDENCE" "$CONFIDENCE_FLOOR"; then
  STATUS=uncertain
  REASON="confidence below $CONFIDENCE_FLOOR"
fi

CRITERIA_HAS=$(jq -n -r --arg choice "$CHOICE" --argjson q "$QUESTIONS" \
  'if $q.skill.criteria | has($choice) then "yes" else "no" end')
if [ "$CRITERIA_HAS" != yes ]; then
  write_record error "$CHOICE" "$CONF_JSON" "$PROBS" '[]' 'choice is not an offered option' false
  maybe_status_note error "$CHOICE" "$CONFIDENCE"
  exit 0
fi

SKILLS_OUT='[]'
if [ "$CHOICE" != none ] && [ "$CHOICE" != search_external ]; then
  SKILLS_OUT=$(jq -n --argjson probs "$PROBS" --arg primary "$CHOICE" --argjson max "$MAX" \
    --argjson catalog "$SKILLS_JSON" --argjson cap "$CATALOG_MAX" '
      def offered: ($catalog[:$cap]);
      def extras:
        ($probs
          | to_entries
          | map(select(
              .key != "none"
              and .key != "search_external"
              and .key != $primary
              and (.key as $k | offered | index($k) != null)
            ))
          | sort_by(-.value)
          | map(.key)
          | .[0:([0, $max-1] | max)]
        );
      [$primary] + extras
    ')
fi

LIVE_LOADED=false
if overlay_apply_ok "$SKILLS_OUT" "$STATUS"; then
  LIVE_LOADED=true
fi
write_record "$STATUS" "$CHOICE" "$CONF_JSON" "$PROBS" "$SKILLS_OUT" "$REASON" false "$LIVE_LOADED"
maybe_status_note "$STATUS" "$CHOICE" "$CONFIDENCE"
exit 0
