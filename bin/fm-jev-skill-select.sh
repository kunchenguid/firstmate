#!/usr/bin/env bash
# fm-jev-skill-select.sh - Jev skill selector (per-launch shadow default).
#
# Usage:
#   fm-jev-skill-select.sh --harness <name> --task-id <id> [--summary <text>]
#     [--skills-dir <dir>] [--comparison-label <label>]
#     [--launch-id <opaque-id>]
#     [--max <n>] [--status-note] [--stdin]
#     [--overlay <launch-brief>] [skill-id ...]
#
# Input: a harness name and an authored privacy-safe query as --summary.
#   Shadow reads approved SKILL.md files from --skills-dir children; positional
#   ids, --stdin, --max, --status-note, and --overlay do not affect shadow mode.
#   Live accepts ids from --skills-dir children, positional arguments, and stdin
#   (--stdin, or stdin when no other source is given and stdin is not a terminal).
#   Never pass page content, excerpts, or conflict lines in --summary.
#
# docs/configuration.md "Jev skill selector" owns shadow selection, approval,
#   privacy, comparison labels, and stop criteria; this header owns flags,
#   records, overlay injection, and live_loaded.
#
# Default shadow: reserve one case per launch under
#   $FM_HOME/state/jev-skill-shadow/cases/<launch-id>.json. Shadow calls require
#   the originating worker --launch-id; an existing case is returned without
#   another request. --comparison-label replaces its labels, accepting comma-
#   separated outcomes; omit --summary and skill sources for offline review.
#   An unfinished case cannot be labeled. Shadow never writes a launch overlay.
#
# Live retains state/<task-id>.jev-skills.json under $FM_HOME, reused for the
#   same task without another request, including relaunches. It offers the first
#   24 sorted ids plus none and search_external, selects up to --max (default 3),
#   and uses a 0.7 confidence floor. --status-note opts into a task status note.
#   Publishing a fresh launch overlay resets live_loaded while preserving the
#   cached selection; an eligible relaunch rechecks readability before injection.
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
SHADOW_CONFIDENCE_FLOOR=0.8
DEFAULT_MAX=3
CATALOG_MAX=24
SHADOW_MODEL=jev-1.13.0
SHADOW_STATE_MAX=30000
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
COMPARISON_LABEL=unlabeled LAUNCH_ID=''
SHADOW_ARGS=("$@")
SKILLS_DIRS=()
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) [ $# -ge 2 ] || die "--harness needs a value"; HARNESS=$2; shift 2 ;;
    --task-id) [ $# -ge 2 ] || die "--task-id needs a value"; TASK_ID=$2; shift 2 ;;
    --launch-id) [ $# -ge 2 ] || die "--launch-id needs a value"; LAUNCH_ID=$2; shift 2 ;;
    --summary) [ $# -ge 2 ] || die "--summary needs a value"; SUMMARY=$2; shift 2 ;;
    --comparison-label)
      [ $# -ge 2 ] || die "--comparison-label needs a value"
      [[ "$2" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]] || die "invalid comparison outcomes"
      IFS=, read -r -a labels <<<"$2"
      for label in "${labels[@]}"; do
        case "$label" in
          unlabeled|correct|incorrect|missed|caught|irrelevant|no-fit|unknown|p2-exposure|launch-changed|roster-omission) ;;
          *) die "--comparison-label is not a supported comparison outcome" ;;
        esac
      done
      COMPARISON_LABEL=$2
      shift 2
      ;;
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
if [ "$MODE" = shadow ]; then
  case "$LAUNCH_ID" in ''|*[!A-Za-z0-9._:-]*) die "shadow requires an originating --launch-id" ;; esac
  if [ "${FM_JEV_SHADOW_CHILD:-0}" != 1 ]; then
    exec python3 "$SCRIPT_DIR/fm-jev-skill-shadow.py" "$FM_HOME" "$LAUNCH_ID" "$COMPARISON_LABEL" "$0" "${SHADOW_ARGS[@]}"
  fi
  OUT="$STATE_DIR/jev-skill-shadow/cases/$LAUNCH_ID.json"
fi

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

# Shadow mode has its own narrow input and record contract. The shadow path is
# intentionally separate from the legacy live overlay path below.
shadow_safe_text() {
  local text=$1
  [ -n "$text" ] || return 1
  [ "${#text}" -le 1200 ] || return 1
  printf '%s' "$text" | LC_ALL=C grep -Eq "[^[:alnum:][:space:].,;:!?()_+&%'-]" && return 1
  printf '%s' "$text" | LC_ALL=C grep -Eq '[/\\@[:cntrl:]]' && return 1
  printf '%s' "$text" | LC_ALL=C grep -Eiq \
    '(^|[^[:alnum:]])(credential|password|secret|private|personal|mail|email|cv|resume|career|feedback|worker trace|raw trace|page body|raw brief|conflict line|unpublished name)([^[:alnum:]]|$)' \
    && return 1
  printf '%s' "$text" | LC_ALL=C grep -Fq '://' && return 1
  return 0
}

shadow_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

shadow_write_record() {
  local status=$1 experiment_id=$2 roster_hash=$3 request_hash=$4 model=$5
  local decisions=$6 latency=$7 tokens=$8 label=$9 reason=${10:-}
  local tmp="${OUT}.tmp.$$"
  jq -n \
    --arg experiment_id "$experiment_id" --arg roster_hash "$roster_hash" \
    --arg request_hash "$request_hash" --arg model "$model" \
    --arg status "$status" --arg comparison_label "$label" --arg reason "$reason" \
    --argjson decisions "$decisions" --argjson latency_ms "$latency" \
    --argjson token_totals "$tokens" \
    '{version:2,experiment_id:$experiment_id,roster_hash:$roster_hash,
      request_hash:$request_hash,resolved_model:$model,status:$status,
      decisions:$decisions,latency_ms:$latency_ms,token_totals:$token_totals,
      comparison_label:$comparison_label,reason:$reason,shadow:true}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$OUT" || return 1
  cat "$OUT"
}

shadow_usage() {
  jq -c '{input_tokens:(.usage.input_tokens // 0),output_tokens:(.usage.output_tokens // 0)}' <<<"$1"
}

shadow_choice_valid() {
  local response=$1 key=$2 offered=$3
  jq -e --arg key "$key" --argjson offered "$offered" '
    (.answers[$key] | type == "object") and
    (.answers[$key].type == "choice") and
    (.answers[$key].choice | type == "string") and
    (.answers[$key].choice as $choice | ($offered | index($choice)) != null) and
    (.answers[$key].confidence | type == "number" and . >= 0 and . <= 1) and
    ((.answers[$key].probabilities | type) == "object") and
    ((.answers[$key].probabilities | keys | sort) == ($offered | sort)) and
    all(.answers[$key].probabilities[]; type == "number" and . >= 0 and . <= 1) and
    (([.answers[$key].probabilities[]] | add) >= 0.99) and
    (([.answers[$key].probabilities[]] | add) <= 1.01)
  ' <<<"$response" >/dev/null 2>&1
}

off_without_keys() {
  printf 'jev-skill-select: off (no TYPESAFE_API_KEY or OPENROUTER_API_KEY)\n' >&2
  exit 0
}

shadow_noul_probability() {
  local response=$1 key=$2
  jq -er --arg key "$key" '
    .answers[$key] | select(type == "object") | select(.type == "noul")
    | .noul
    | select(type == "number" and . >= 0 and . <= 1)
  ' <<<"$response" 2>/dev/null
}

run_shadow() {
  local roster_json roster_hash request_hash state questions
  local _fm_jev_route _fm_jev_url _fm_jev_model _fm_jev_key
  local response stage2_response offered detail_offered
  local stage1_choice stage1_confidence stage1_probs detail_choice detail_confidence detail_probs
  local model t0 t1 latency tokens1 tokens2 tokens chosen_fit decisions
  local -a top_ids
  if [ -z "${TYPESAFE_API_KEY:-}" ] && [ -z "${OPENROUTER_API_KEY:-}" ] \
    && [ -z "$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")" ] \
    && [ -z "$(fmx_env_get OPENROUTER_API_KEY "$FM_HOME/.env")" ]; then
    off_without_keys
  fi
  _fm_jev_resolve_route || exit 0
  case "$_fm_jev_route" in
    openrouter) SHADOW_MODEL=typesafe/jev-1.13 ;;
    typesafe) SHADOW_MODEL=jev-1.13.0 ;;
  esac
  [ -n "$SUMMARY" ] || { printf 'jev-skill-select: shadow skipped (no authored safe query)\n' >&2; exit 0; }
  shadow_safe_text "$SUMMARY" || { printf 'jev-skill-select: shadow skipped (query outside P0/P1 allowlist)\n' >&2; exit 0; }
  roster_json=$(python3 "$SCRIPT_DIR/fm-jev-skill-shadow.py" catalog "$FM_HOME" "${SKILLS_DIRS[@]}") || exit 0
  [ "$(jq 'length' <<<"$roster_json")" -gt 0 ] || { printf 'jev-skill-select: shadow skipped (no eligible public skills)\n' >&2; exit 0; }
  roster_hash=$(printf '%s' "$roster_json" | shadow_hash) || exit 0
  request_hash=$(printf '%s\n%s\n%s' "$SUMMARY" "$HARNESS" "$roster_hash" | shadow_hash) || exit 0
  state=$(jq -n --arg request "$SUMMARY" --arg runtime "$HARNESS" \
    '{request:$request,runtime:$runtime,worker_role:"worker"}')
  if ! state=$(JEV_STATE_MAX_BYTES=$SHADOW_STATE_MAX fm_jev_compact_state "$state"); then
    shadow_write_record error "$LAUNCH_ID" "$roster_hash" "$request_hash" "$SHADOW_MODEL" \
      '{}' 0 '{"input_tokens":0,"output_tokens":0}' "$COMPARISON_LABEL" state_too_large || exit 0
    exit 0
  fi
  questions=$(jq -n --argjson roster "$roster_json" '
    {skill:{type:"choice",instructions:"Choose the one installed public skill whose documented purpose best satisfies the safe request. Choose none when no skill specifically fits.",criteria:(($roster | map({key:.id,value:.description}) | from_entries) + {none:"No optional skill specifically fits the safe request."})}}
  ') || exit 0
  shadow_write_record pending "$LAUNCH_ID" "$roster_hash" "$request_hash" "$SHADOW_MODEL" \
    '{}' 0 '{"input_tokens":0,"output_tokens":0}' "$COMPARISON_LABEL" pending >/dev/null
  t0=$(_fm_jev_now_ms)
  response=$(JEV_MODEL="$SHADOW_MODEL" JEV_TIMEOUT=4 fm_jev_decide "$state" "$questions" 2>/dev/null) || {
    t1=$(_fm_jev_now_ms); latency=$((t1 - t0))
    shadow_write_record error "$LAUNCH_ID" "$roster_hash" "$request_hash" "$SHADOW_MODEL" \
      '{}' "$latency" '{"input_tokens":0,"output_tokens":0}' "$COMPARISON_LABEL" service_error || exit 0
    exit 0
  }
  t1=$(_fm_jev_now_ms); latency=$((t1 - t0))
  offered=$(jq -c '[.[] | .id] + ["none"]' <<<"$roster_json")
  if ! shadow_choice_valid "$response" skill "$offered"; then
    model=$(jq -r '.model // empty' <<<"$response"); [ -n "$model" ] || model=$SHADOW_MODEL
    shadow_write_record error "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" '{}' "$latency" \
      "$(shadow_usage "$response")" "$COMPARISON_LABEL" invalid_stage1 || exit 0
    exit 0
  fi
  stage1_choice=$(jq -r '.answers.skill.choice' <<<"$response")
  stage1_confidence=$(jq -r '.answers.skill.confidence' <<<"$response")
  stage1_probs=$(jq -c '.answers.skill.probabilities' <<<"$response")
  model=$(jq -r '.model // empty' <<<"$response"); [ -n "$model" ] || model=$SHADOW_MODEL
  tokens1=$(shadow_usage "$response")
  decisions=$(jq -n --arg choice "$stage1_choice" --argjson confidence "$stage1_confidence" \
    --argjson probabilities "$stage1_probs" '{stage1:{choice:$choice,confidence:$confidence,probabilities:$probabilities}}')
  if [ "$stage1_choice" = none ] || ! fm_jev_choice_confidence_ok "$stage1_confidence" "$SHADOW_CONFIDENCE_FLOOR"; then
    shadow_write_record none "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" \
      "$decisions" "$latency" "$tokens1" "$COMPARISON_LABEL" low_or_none || exit 0
    exit 0
  fi
  mapfile -t top_ids < <(jq -r --argjson probs "$stage1_probs" \
    'map({id:.id,p:($probs[.id] // 0)}) | sort_by(-.p,.id) | .[0:3] | .[].id' <<<"$roster_json")
  [ "${#top_ids[@]}" -gt 0 ] || exit 0
  detail_json=$(jq -c --argjson ids "$(printf '%s\n' "${top_ids[@]}" | jq -Rsc 'split("\n")[:-1]')" \
    '[.[] | select(.id as $id | $ids | index($id)) | {id, evidence:(.description + " Documented procedure excerpt: " + .excerpt)}]' <<<"$roster_json")
  detail_offered=$(jq -c '[.[] | .id] + ["none"]' <<<"$detail_json")
  questions=$(jq -n --argjson candidates "$detail_json" '
    ({detail:{type:"choice",instructions:"Choose the single candidate whose documented procedure specifically satisfies the safe request, or none.",criteria:(($candidates | map({key:.id,value:.evidence}) | from_entries) + {none:"No candidate specifically satisfies the safe request."})}})
    + ($candidates | map({key:("fit_" + .id),value:{type:"noul",instructions:("Does the documented procedure for skill " + .id + " specifically satisfy the safe request?"),criteria:{"true":"The documented procedure directly satisfies the request.","false":"It does not directly satisfy the request."}}}) | from_entries)
  ') || exit 0
  state=$(jq -c --argjson candidates "$detail_json" '. + {candidates:$candidates}' <<<"$state")
  shadow_write_record pending "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" \
    "$decisions" "$latency" "$tokens1" "$COMPARISON_LABEL" pending >/dev/null
  t0=$(_fm_jev_now_ms)
  stage2_response=$(JEV_MODEL="$SHADOW_MODEL" JEV_TIMEOUT=4 fm_jev_decide "$state" "$questions" 2>/dev/null) || {
    t1=$(_fm_jev_now_ms); latency=$((latency + t1 - t0))
    shadow_write_record error "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" \
      "$decisions" "$latency" "$tokens1" "$COMPARISON_LABEL" service_error || exit 0
    exit 0
  }
  t1=$(_fm_jev_now_ms); latency=$((latency + t1 - t0))
  tokens2=$(shadow_usage "$stage2_response")
  tokens=$(jq -n --argjson a "$tokens1" --argjson b "$tokens2" \
    '{input_tokens:($a.input_tokens + $b.input_tokens),output_tokens:($a.output_tokens + $b.output_tokens)}')
  if ! shadow_choice_valid "$stage2_response" detail "$detail_offered"; then
    shadow_write_record error "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" \
      "$decisions" "$latency" "$tokens" "$COMPARISON_LABEL" invalid_stage2 || exit 0
    exit 0
  fi
  for id in "${top_ids[@]}"; do
    shadow_noul_probability "$stage2_response" "fit_$id" >/dev/null || {
      shadow_write_record error "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" \
        "$decisions" "$latency" "$tokens" "$COMPARISON_LABEL" invalid_noul || exit 0
      exit 0
    }
  done
  detail_choice=$(jq -r '.answers.detail.choice' <<<"$stage2_response")
  detail_confidence=$(jq -r '.answers.detail.confidence' <<<"$stage2_response")
  detail_probs=$(jq -c '.answers.detail.probabilities' <<<"$stage2_response")
  chosen_fit=0
  if [ "$detail_choice" != none ]; then
    chosen_fit=$(shadow_noul_probability "$stage2_response" "fit_$detail_choice")
  fi
  decisions=$(jq -n --argjson first "$decisions" --arg choice "$detail_choice" \
    --argjson confidence "$detail_confidence" --argjson probabilities "$detail_probs" \
    --argjson fit "$chosen_fit" '{stage1:$first.stage1,stage2:{choice:$choice,confidence:$confidence,probabilities:$probabilities,chosen_fit_probability:$fit}}')
  if [ "$detail_choice" != none ] && fm_jev_choice_confidence_ok "$detail_confidence" "$SHADOW_CONFIDENCE_FLOOR" \
    && awk -v p="$chosen_fit" 'BEGIN { exit !(p >= 0.8) }'; then
    shadow_write_record recommended "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" \
      "$decisions" "$latency" "$tokens" "$COMPARISON_LABEL" recommended || exit 0
  else
    shadow_write_record none "$LAUNCH_ID" "$roster_hash" "$request_hash" "$model" \
      "$decisions" "$latency" "$tokens" "$COMPARISON_LABEL" low_detail_confidence || exit 0
  fi
  exit 0
}

if [ "$MODE" = shadow ]; then
  run_shadow
fi

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
