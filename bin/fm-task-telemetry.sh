#!/usr/bin/env bash
# Estimate task difficulty and collect token usage for completed direct reports.
# Usage:
#   fm-task-telemetry.sh estimate <brief-path>
#   fm-task-telemetry.sh collect <task-id>
#   fm-task-telemetry.sh summary
#
# Spawn records the estimate in state/<id>.meta as difficulty=<simple|intermediate|complex|unknown>.
# Teardown calls `collect` before volatile task state and worktree files are removed.
# `collect` appends usage_* fields to the live meta for immediate inspection, then
# upserts one durable TSV row in data/task-telemetry.tsv:
#   id recorded_at kind difficulty harness model effort prompt_tokens completion_tokens total_tokens difficulty_points tokens_per_difficulty_point source
#
# Usage collection is best-effort because harnesses expose token data differently.
# Supported sources, in order:
#   - explicit per-task usage sidecars at state/<id>.usage.json[l],
#     state/<id>.usage, worktree/.fm-token-usage.json[l], and
#     worktree/.fm-token-usage.
#   - Codex JSONL sessions under ~/.codex/sessions whose session cwd matches the
#     recorded worktree; token_count events are cumulative, so the last total per
#     session file is used.
#   - Claude JSONL transcripts under ~/.claude/projects/<cwd encoded with slash
#     as dash>; repeated content chunks for one assistant message are deduped by
#     message id or request id.
# Unknown or unsupported harness logs still get a durable row with source=unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LEDGER="$DATA/task-telemetry.tsv"

usage() {
  sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
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

estimate_difficulty() {
  local brief=$1 words lines keyword_count score
  [ -f "$brief" ] || { printf 'unknown\n'; return 0; }
  words=$(wc -w < "$brief" | tr -d '[:space:]')
  lines=$(wc -l < "$brief" | tr -d '[:space:]')
  score=0
  if [ "${words:-0}" -gt 1000 ]; then
    score=$((score + 2))
  elif [ "${words:-0}" -gt 300 ]; then
    score=$((score + 1))
  fi
  [ "${lines:-0}" -gt 80 ] && score=$((score + 1))
  keyword_count=$(grep -Eio \
    'migration|database|schema|security|auth|concurrency|race|deadlock|refactor|architecture|multi-project|secondmate|backend|watcher|teardown|spawn|dispatch|no-mistakes|ci|e2e|integration|browser|performance|telemetry|token|quota|recovery|diagnose|investigate|audit|design|report' \
    "$brief" 2>/dev/null | sort -u | wc -l | tr -d '[:space:]')
  if [ "${keyword_count:-0}" -ge 5 ]; then
    score=$((score + 3))
  elif [ "${keyword_count:-0}" -ge 2 ]; then
    score=$((score + 1))
  fi
  if grep -Eiq '(^|[^[:alnum:]])(trivial|typo|copy edit|small doc|one-line|one line)([^[:alnum:]]|$)' "$brief" 2>/dev/null; then
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
    def usageish:
      .. | objects
      | select(
          has("input_tokens") or has("prompt_tokens") or
          has("cache_creation_input_tokens") or has("cache_read_input_tokens") or
          has("output_tokens") or has("completion_tokens") or has("total_tokens")
        );
    reduce usageish as $u ({prompt:0, completion:0, total:0};
      .prompt += (n($u.input_tokens?) + n($u.prompt_tokens?) + n($u.cache_creation_input_tokens?) + n($u.cache_read_input_tokens?))
      | .completion += (n($u.output_tokens?) + n($u.completion_tokens?))
      | .total += n($u.total_tokens?)
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
    | [n($u.input_tokens), n($u.output_tokens), n($u.total_tokens)]
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
            | .prompt += (n($u.input_tokens?) + n($u.cache_creation_input_tokens?) + n($u.cache_read_input_tokens?))
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
  encoded=$(printf '%s' "$worktree" | sed 's#/#-#g')
  printf '%s/.claude/projects/%s\n' "$HOME" "$encoded"
}

candidate_files() {
  local id=$1 meta=$2 harness=$3 worktree=$4 file dir
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
      find "$dir" -type f -name '*.jsonl' -newer "$meta" 2>/dev/null \
        | while IFS= read -r file; do
            grep -F "\"cwd\":\"$worktree\"" "$file" >/dev/null 2>&1 && printf 'codex\t%s\n' "$file"
          done
      ;;
    claude)
      dir=$(claude_project_dir "$worktree") || return 0
      [ -d "$dir" ] || return 0
      find "$dir" -maxdepth 1 -type f -name '*.jsonl' -newer "$meta" 2>/dev/null \
        | while IFS= read -r file; do
            printf 'claude\t%s\n' "$file"
          done
      ;;
  esac
}

usage_from_file() {
  local source=$1 file=$2
  case "$source" in
    codex) json_usage_codex "$file" || json_usage_generic "$file" ;;
    claude) json_usage_claude "$file" || json_usage_generic "$file" ;;
    *) json_usage_generic "$file" ;;
  esac
}

collect_usage() {
  local id=$1 meta=$2 harness=$3 worktree=$4 source file usage prompt completion total
  local prompt_sum=0 completion_sum=0 total_sum=0 sources='' found=0
  while IFS="$(printf '\t')" read -r source file; do
    [ -n "$source" ] && [ -n "$file" ] || continue
    usage=$(usage_from_file "$source" "$file" | tail -1 || true)
    [ -n "$usage" ] || continue
    IFS="$(printf '\t')" read -r prompt completion total <<EOF
$usage
EOF
    case "$prompt$completion$total" in *[!0-9]*|'') continue ;; esac
    prompt_sum=$((prompt_sum + prompt))
    completion_sum=$((completion_sum + completion))
    total_sum=$((total_sum + total))
    found=1
    if [ -z "$sources" ]; then
      sources=$source
    else
      sources="$sources+$source"
    fi
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
  awk -F '\t' '
    NR == 1 { next }
    $10 ~ /^[0-9]+$/ {
      key = $4 "\t" $5 "\t" $6
      count[key] += 1
      total[key] += $10
      point_total[key] += $11
    }
    END {
      print "difficulty\tharness\tmodel\ttasks\tavg_total_tokens\tavg_tokens_per_difficulty_point"
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
