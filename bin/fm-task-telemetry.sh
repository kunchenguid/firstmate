#!/usr/bin/env bash
# Estimate task difficulty and collect token usage for completed direct reports.
# Usage:
#   fm-task-telemetry.sh estimate <brief-path>
#   fm-task-telemetry.sh collect <task-id>
#   fm-task-telemetry.sh summary
#
# Spawn records the estimate in state/<id>.meta as difficulty=<simple|intermediate|complex|unknown>.
# `estimate` scores only task-specific brief content, so template text alone cannot
# decide the bucket. bin/fm-brief.sh owns the `<!-- fm-brief:task-begin -->` and
# `<!-- fm-brief:task-end -->` markers that delimit the firstmate-filled text, and
# those markers are preferred whenever both are present. A brief scaffolded before
# the markers existed, or one that lost a marker to hand-editing, falls back to
# dropping the fixed preamble and the generated section headings; a brief that is
# not a scaffold at all is scored whole. The
# `{TASK}` placeholder never contributes either way.
# Teardown calls `collect` before volatile task state and worktree files are removed.
# `collect` appends usage_* fields to the live meta for immediate inspection, then
# upserts one durable TSV row in data/task-telemetry.tsv:
#   id recorded_at kind difficulty harness model effort prompt_tokens completion_tokens total_tokens difficulty_points tokens_per_difficulty_point source
#
# Usage collection is best-effort because harnesses expose token data differently.
# Every recorded number excludes cached prompt re-reads, so one harness is not
# scaled differently from another by how much of its context each turn is served
# from cache. Sources are tried in precedence order and the first kind that
# yields a reading wins; files within that kind are summed.
#   - explicit per-task usage sidecars at state/<id>.usage.json[l],
#     state/<id>.usage, worktree/.fm-token-usage.json[l], and
#     worktree/.fm-token-usage.
#   - Codex JSONL sessions under ~/.codex/sessions whose session cwd matches the
#     recorded worktree; token_count events are cumulative, so the last total per
#     session file is used. Codex reports input_tokens inclusive of
#     cached_input_tokens, so the cached part is subtracted from both the prompt
#     and the total.
#   - Claude JSONL transcripts under ~/.claude/projects/<cwd encoded with slash
#     as dash>; repeated content chunks for one assistant message are deduped by
#     message id or request id. Per-turn cache_read_input_tokens (the growing
#     context re-read from cache each turn) is excluded from the prompt sum;
#     input_tokens plus cache_creation_input_tokens (the newly supplied prompt
#     each turn) is counted.
#   - a generic usage-object reading of any of the above when the harness-specific
#     parser finds nothing. It takes at most one usage object per record, favouring
#     a cumulative-looking key over a sibling per-turn delta, and excludes
#     cache_read_input_tokens and cached_input_tokens like the harness parsers. It
#     cannot tell cumulative totals from deltas across records, so its rows are
#     labelled `<harness>-generic` and `summary` keeps them in their own group
#     rather than averaging them into a normalized harness reading.
# Unknown or unsupported harness logs still get a durable row with source=unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/task-telemetry.tsv"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

meta_get() {
  local meta=$1 key=$2
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

ts_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

sanitize_tsv() {
  tr '\t\r\n' '   ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

difficulty_points() {
  case "$1" in
    simple) printf '1\n' ;;
    intermediate) printf '2\n' ;;
    complex) printf '3\n' ;;
    *) printf '0\n' ;;
  esac
}

# Entries are extended-regex fragments matched as whole words, so one concept
# spelled several ways stays a single scored keyword.
TELEMETRY_KEYWORDS=(
  migration database schema security 'auth(entication|orization)?'
  concurrency race deadlock refactor
  architecture multi-project secondmate backend watcher teardown spawn dispatch
  no-mistakes ci e2e integration browser performance telemetry token quota
  recovery diagnose investigate audit design report
)

TASK_MARKER_BEGIN='<!-- fm-brief:task-begin -->'
TASK_MARKER_END='<!-- fm-brief:task-end -->'

# Heading fallback for briefs scaffolded before fm-brief.sh emitted the markers, and
# for a scaffold that lost one of the pair while its task text was edited.
SCAFFOLD_SECTIONS='^# (Herdr |(Setup|Rules|Project memory|Project clones|Operating model|Requests from the main firstmate|Escalation to main firstmate|Definition of done)[[:space:]]*$)'

# Task-specific brief text: the scaffold's own boilerplate carries enough size and
# lifecycle vocabulary to saturate the score on its own, so only the text firstmate
# fills in is scored. bin/fm-brief.sh owns the markers that delimit that region.
scored_content() {
  local brief=$1
  if grep -Fq "$TASK_MARKER_BEGIN" "$brief" 2>/dev/null \
    && grep -Fq "$TASK_MARKER_END" "$brief" 2>/dev/null; then
    awk -v begin="$TASK_MARKER_BEGIN" -v end="$TASK_MARKER_END" '
      index($0, begin) { inside = 1; next }
      index($0, end) { inside = 0; next }
      inside
    ' "$brief"
  elif grep -Eq '^# (Task|Charter)[[:space:]]*$' "$brief" 2>/dev/null; then
    awk -v boilerplate="$SCAFFOLD_SECTIONS" '
      BEGIN { skip = 1 }
      /^# / { skip = ($0 ~ boilerplate) ? 1 : 0; next }
      !skip
    ' "$brief"
  else
    cat "$brief"
  fi | sed 's/{TASK}//g'
}

count_keywords() {
  local content=$1 keyword count=0
  for keyword in "${TELEMETRY_KEYWORDS[@]}"; do
    if printf '%s\n' "$content" \
      | grep -Eiq "(^|[^[:alnum:]])$keyword(s|es|d|ed|ing)?([^[:alnum:]]|$)" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

estimate_difficulty() {
  local brief=$1 content words lines keyword_count score
  [ -f "$brief" ] || { printf 'unknown\n'; return 0; }
  content=$(scored_content "$brief")
  words=$(printf '%s\n' "$content" | wc -w | tr -d '[:space:]')
  lines=$(printf '%s\n' "$content" | grep -c '[^[:space:]]' || true)
  score=0
  if [ "${words:-0}" -gt 400 ]; then
    score=$((score + 2))
  elif [ "${words:-0}" -gt 120 ]; then
    score=$((score + 1))
  fi
  [ "${lines:-0}" -gt 30 ] && score=$((score + 1))
  keyword_count=$(count_keywords "$content")
  if [ "${keyword_count:-0}" -ge 5 ]; then
    score=$((score + 3))
  elif [ "${keyword_count:-0}" -ge 3 ]; then
    score=$((score + 2))
  elif [ "${keyword_count:-0}" -ge 2 ]; then
    score=$((score + 1))
  fi
  if printf '%s\n' "$content" \
    | grep -Eiq '(^|[^[:alnum:]])(trivial|typo|copy edit|small doc|one-line|one line)([^[:alnum:]]|$)' 2>/dev/null; then
    score=$((score - 1))
  fi
  if [ "$score" -le 1 ]; then
    printf 'simple\n'
  elif [ "$score" -le 2 ]; then
    printf 'intermediate\n'
  else
    printf 'complex\n'
  fi
}

json_usage_generic() {
  local file=$1
  command -v jq >/dev/null 2>&1 || return 1
  jq -rs '
    def n($v): if ($v | type) == "number" then $v else 0 end;
    def shaped:
      (type == "object") and (
        has("input_tokens") or has("prompt_tokens") or
        has("cache_creation_input_tokens") or has("cache_read_input_tokens") or
        has("output_tokens") or has("completion_tokens") or has("total_tokens")
      );
    # One usage object per record: a record often carries a cumulative total
    # beside a per-turn delta (codex info.total_token_usage vs last_token_usage),
    # and summing both double-counts. Take the shallowest usage object, breaking
    # ties toward the cumulative-looking key.
    def pick:
      . as $rec
      | if ($rec | shaped) then $rec
        else
          [ paths(objects) as $p | select($rec | getpath($p) | shaped) | $p ] as $found
          | if ($found | length) == 0 then empty
            else
              ($found | map(length) | min) as $depth
              | [ $found[] | select(length == $depth) ] as $top
              | ([ $top[] | select(.[-1] | tostring | test("total|cumulative"; "i")) ] | first) as $preferred
              | $rec | getpath($preferred // $top[0])
            end
        end;
    # Cached prompt re-reads are excluded exactly as the harness parsers do:
    # codex folds them into input_tokens/total_tokens, claude reports them
    # separately as cache_read_input_tokens.
    reduce (.[] | pick) as $u ({prompt:0, completion:0, total:0};
      n($u.cached_input_tokens?) as $cached
      | .prompt += ([n($u.input_tokens?) + n($u.prompt_tokens?) + n($u.cache_creation_input_tokens?) - $cached, 0] | max)
      | .completion += (n($u.output_tokens?) + n($u.completion_tokens?))
      | .total += ([n($u.total_tokens?) - $cached, 0] | max)
    )
    | .total = (if .total > 0 then .total else (.prompt + .completion) end)
    | select(.total > 0)
    | "\(.prompt)\t\(.completion)\t\(.total)"
  ' "$file" 2>/dev/null
}

json_usage_codex() {
  local file=$1
  command -v jq >/dev/null 2>&1 || return 1
  jq -rs '
    def n($v): if ($v | type) == "number" then $v else 0 end;
    (
      [
        .[]
        | select(.type == "event_msg" and .payload.type == "token_count")
        | .payload.info.total_token_usage?
        | select(type == "object")
      ] | last?
    ) as $u
    | select($u != null)
    # Codex counts the cached prompt prefix inside input_tokens (and so inside
    # total_tokens) every turn; Claude reports it separately and it is excluded
    # there, so drop it here too and keep the two harnesses on one scale.
    | n($u.cached_input_tokens) as $cached
    | ([n($u.input_tokens) - $cached, 0] | max) as $prompt
    | n($u.output_tokens) as $completion
    | ([n($u.total_tokens) - $cached, 0] | max) as $total
    | [$prompt, $completion, (if $total > 0 then $total else ($prompt + $completion) end)]
    | select(.[2] > 0)
    | @tsv
  ' "$file" 2>/dev/null
}

json_usage_claude() {
  local file=$1
  command -v jq >/dev/null 2>&1 || return 1
  jq -rs '
    def n($v): if ($v | type) == "number" then $v else 0 end;
    reduce .[] as $e ({seen:{}, prompt:0, completion:0};
      if (($e.message.usage? | type) == "object") then
        ($e.message.id // $e.requestId // $e.uuid // "") as $key
        | if ($key != "" and (.seen[$key] // false)) then .
          else
            .seen[$key] = true
            | ($e.message.usage) as $u
            | .prompt += (n($u.input_tokens?) + n($u.cache_creation_input_tokens?))
            | .completion += n($u.output_tokens?)
          end
      else .
      end
    )
    | (.prompt + .completion) as $total
    | select($total > 0)
    | "\(.prompt)\t\(.completion)\t\($total)"
  ' "$file" 2>/dev/null
}

claude_project_dir() {
  local worktree=$1 encoded
  [ -n "$worktree" ] || return 1
  encoded=$(printf '%s' "$worktree" | sed 's#[^a-zA-Z0-9-]#-#g')
  printf '%s/.claude/projects/%s\n' "$HOME" "$encoded"
}

candidate_files() {
  local id=$1 meta=$2 harness=$3 worktree=$4 file dir ref
  # Prefer the spawn-time marker, whose mtime is never bumped by later meta
  # rewrites (e.g. fm-pr-check on a green PR); fall back to meta for tasks
  # spawned before the marker existed.
  ref="$STATE/$id.spawn-ref"
  [ -f "$ref" ] || ref="$meta"
  for file in "$STATE/$id.usage.json" "$STATE/$id.usage.jsonl" "$STATE/$id.usage"; do
    [ -f "$file" ] && printf 'generic\t%s\n' "$file"
  done
  if [ -n "$worktree" ] && [ -d "$worktree" ]; then
    for file in "$worktree/.fm-token-usage.json" "$worktree/.fm-token-usage.jsonl" "$worktree/.fm-token-usage"; do
      [ -f "$file" ] && printf 'generic\t%s\n' "$file"
    done
  fi
  case "$harness" in
    codex)
      dir="$HOME/.codex/sessions"
      [ -d "$dir" ] || return 0
      find "$dir" -type f -name '*.jsonl' -newer "$ref" 2>/dev/null \
        | while IFS= read -r file; do
            grep -F "\"cwd\":\"$worktree\"" "$file" >/dev/null 2>&1 && printf 'codex\t%s\n' "$file"
          done
      ;;
    claude)
      dir=$(claude_project_dir "$worktree") || return 0
      [ -d "$dir" ] || return 0
      find "$dir" -maxdepth 1 -type f -name '*.jsonl' -newer "$ref" 2>/dev/null \
        | while IFS= read -r file; do
            printf 'claude\t%s\n' "$file"
          done
      ;;
  esac
}

usage_from_file() {
  local source=$1 file=$2 result=''
  local effective=$source
  # A harness-specific filter that matches nothing still exits 0 with empty
  # output, so the generic fallback keys off emptiness rather than exit status.
  case "$source" in
    codex) result=$(json_usage_codex "$file" || true) ;;
    claude) result=$(json_usage_claude "$file" || true) ;;
  esac
  if [ -z "$result" ]; then
    result=$(json_usage_generic "$file" || true)
    # The generic reading is lower fidelity than a harness parser (it cannot tell
    # cumulative totals from per-turn deltas), so it never wears the plain
    # harness label in the ledger.
    [ "$source" = generic ] || effective="$source-generic"
  fi
  [ -n "$result" ] || return 1
  printf '%s\t%s\n' "$result" "$effective"
}

collect_usage() {
  local id=$1 meta=$2 harness=$3 worktree=$4 source file usage prompt completion total read_as
  local prompt_sum=0 completion_sum=0 total_sum=0 sources='' found=0 accepted=''
  # candidate_files emits candidates in precedence order. The first kind that
  # yields a reading wins outright; mixing kinds would double-count a task that
  # has both an explicit sidecar and a harness session log. Several files of the
  # accepted kind (e.g. a resumed harness session) are still summed.
  while IFS="$(printf '\t')" read -r source file; do
    [ -n "$source" ] && [ -n "$file" ] || continue
    [ -z "$accepted" ] || [ "$source" = "$accepted" ] || continue
    usage=$(usage_from_file "$source" "$file" | tail -1 || true)
    [ -n "$usage" ] || continue
    IFS="$(printf '\t')" read -r prompt completion total read_as <<EOF
$usage
EOF
    case "$prompt$completion$total" in *[!0-9]*|'') continue ;; esac
    prompt_sum=$((prompt_sum + prompt))
    completion_sum=$((completion_sum + completion))
    total_sum=$((total_sum + total))
    found=1
    accepted=$source
    case "+$sources+" in
      *"+$read_as+"*) ;;
      *) sources="${sources:+$sources+}$read_as" ;;
    esac
  done <<EOF
$(candidate_files "$id" "$meta" "$harness" "$worktree" | awk -F "$(printf '\t')" '!seen[$1 FS $2]++')
EOF
  [ "$found" -eq 1 ] || return 1
  printf '%s\t%s\t%s\t%s\n' "$prompt_sum" "$completion_sum" "$total_sum" "$sources"
}

ledger_upsert() {
  local row=$1 tmp
  mkdir -p "$DATA" || return 1
  tmp=$(mktemp "$DATA/.task-telemetry.XXXXXX") || return 1
  if [ -f "$LEDGER" ]; then
    awk -F '\t' -v id="${row%%$'\t'*}" 'NR == 1 || $1 != id { print }' "$LEDGER" > "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  else
    printf '%s\n' 'id	recorded_at	kind	difficulty	harness	model	effort	prompt_tokens	completion_tokens	total_tokens	difficulty_points	tokens_per_difficulty_point	source' > "$tmp"
  fi
  printf '%s\n' "$row" >> "$tmp"
  mv "$tmp" "$LEDGER"
}

collect_task() {
  local id=$1 meta worktree kind difficulty harness model effort recorded_at
  local usage prompt completion total source points ratio row
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "error: no meta for task $id at $meta" >&2; return 1; }
  worktree=$(meta_get "$meta" worktree)
  kind=$(meta_get "$meta" kind); [ -n "$kind" ] || kind=ship
  difficulty=$(meta_get "$meta" difficulty); [ -n "$difficulty" ] || difficulty=unknown
  harness=$(meta_get "$meta" harness); [ -n "$harness" ] || harness=unknown
  model=$(meta_get "$meta" model); [ -n "$model" ] || model=default
  effort=$(meta_get "$meta" effort); [ -n "$effort" ] || effort=default
  recorded_at=$(ts_now)
  points=$(difficulty_points "$difficulty")
  if usage=$(collect_usage "$id" "$meta" "$harness" "$worktree"); then
    IFS="$(printf '\t')" read -r prompt completion total source <<EOF
$usage
EOF
    if [ "$points" -gt 0 ]; then
      ratio=$((total / points))
    else
      ratio=unknown
    fi
  else
    prompt=unknown
    completion=unknown
    total=unknown
    source=unavailable
    ratio=unknown
  fi
  {
    printf 'usage_prompt_tokens=%s\n' "$prompt"
    printf 'usage_completion_tokens=%s\n' "$completion"
    printf 'usage_total_tokens=%s\n' "$total"
    printf 'usage_source=%s\n' "$source"
    printf 'usage_recorded_at=%s\n' "$recorded_at"
  } >> "$meta"
  row=$(
    {
      printf '%s\t' "$(printf '%s' "$id" | sanitize_tsv)"
      printf '%s\t' "$recorded_at"
      printf '%s\t' "$(printf '%s' "$kind" | sanitize_tsv)"
      printf '%s\t' "$(printf '%s' "$difficulty" | sanitize_tsv)"
      printf '%s\t' "$(printf '%s' "$harness" | sanitize_tsv)"
      printf '%s\t' "$(printf '%s' "$model" | sanitize_tsv)"
      printf '%s\t' "$(printf '%s' "$effort" | sanitize_tsv)"
      printf '%s\t%s\t%s\t%s\t%s\t' "$prompt" "$completion" "$total" "$points" "$ratio"
      printf '%s\n' "$(printf '%s' "$source" | sanitize_tsv)"
    }
  )
  ledger_upsert "$row"
}

summary() {
  [ -f "$LEDGER" ] || { echo "no telemetry ledger at $LEDGER"; return 0; }
  printf 'difficulty\tharness\tmodel\tsource\ttasks\tavg_total_tokens\tavg_tokens_per_difficulty_point\n'
  awk -F '\t' '
    NR == 1 { next }
    $10 ~ /^[0-9]+$/ {
      # source is part of the key: a lower-fidelity <harness>-generic reading
      # must never be averaged into a normalized harness reading.
      key = $4 "\t" $5 "\t" $6 "\t" $13
      count[key] += 1
      total[key] += $10
      point_total[key] += $11
    }
    END {
      for (key in count) {
        avg = int(total[key] / count[key])
        ratio = point_total[key] > 0 ? int(total[key] / point_total[key]) : 0
        print key "\t" count[key] "\t" avg "\t" ratio
      }
    }
  ' "$LEDGER" | sort
}

case "${1:-}" in
  estimate)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    estimate_difficulty "$2"
    ;;
  collect)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    collect_task "$2"
    ;;
  summary)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    summary
    ;;
  -h|--help|'')
    usage
    ;;
  *)
    echo "error: unknown command $1" >&2
    usage >&2
    exit 2
    ;;
esac
