#!/usr/bin/env bash
# fm-effort.sh - append-only effort ledger, reducer, and derived board.
#
# This is the first small slice of the delivery-control-surface work.
# The source of truth is data/efforts/ledger.jsonl in the current firstmate
# checkout.
# Source adapters read an external firstmate home when passed with --home, but
# never write to that home.
# All views are derived by folding the ledger from the start on every command.
#
# Usage:
#   fm-effort.sh emit --effort-id <id> --to-stage <stage> [flags]
#   fm-effort.sh list [--json]
#   fm-effort.sh board [--output <path>]
#   fm-effort.sh ingest state --home <firstmate-home>
#   fm-effort.sh ingest tasks --home <firstmate-home>
#   fm-effort.sh ingest inventory [--repo-allowlist <patterns>] <inventory.json>
#   fm-effort.sh ingest all --home <firstmate-home> [--inventory <inventory.json>] [--repo-allowlist <patterns>]
#   fm-effort.sh reconcile --home <firstmate-home> [--json]
#
# Valid stages:
#   intake in_progress in_review merge_ready merged deployed fallout_observed
#   done blocked needs_captain abandoned
#
# needs_captain events must carry a decision card:
#   {kind: scope|merge_word|waiver|priority|cancellation, question,
#    recommendation, options}
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
EFFORTS_DIR="${FM_EFFORTS_DIR_OVERRIDE:-$FM_ROOT/data/efforts}"
LEDGER="${FM_EFFORT_LEDGER_OVERRIDE:-$EFFORTS_DIR/ledger.jsonl}"
BOARD="${FM_EFFORT_BOARD_OVERRIDE:-$EFFORTS_DIR/BOARD.md}"
NOW="${FM_EFFORT_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
TASKS_LIMIT="${FM_EFFORT_TASKS_LIMIT:-1000}"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  fm-effort.sh emit --effort-id <id> --to-stage <stage> [flags]
  fm-effort.sh list [--json]
  fm-effort.sh board [--output <path>]
  fm-effort.sh ingest state --home <firstmate-home>
  fm-effort.sh ingest tasks --home <firstmate-home>
  fm-effort.sh ingest inventory [--repo-allowlist <patterns>] <inventory.json>
  fm-effort.sh ingest all --home <firstmate-home> [--inventory <inventory.json>] [--repo-allowlist <patterns>]
  fm-effort.sh reconcile --home <firstmate-home> [--json]

emit flags:
  --kind <event-kind>              default: stage
  --actor <actor>                  default: manual
  --from-stage <stage>             defaults to current folded stage
  --evidence <url-or-path>
  --note <text>
  --decision-json <json-object>
  --decision-kind <kind>
  --question <text>
  --recommendation <text>
  --option <text>                  repeatable
EOF
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

ensure_ledger_dir() {
  mkdir -p "$(dirname "$LEDGER")"
  [ -f "$LEDGER" ] || : > "$LEDGER"
}

stage_valid() {
  case "$1" in
    intake|in_progress|in_review|merge_ready|merged|deployed|fallout_observed|done|blocked|needs_captain|abandoned)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

terminal_stage() {
  case "$1" in
    done|abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

sha256_string() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

current_stage() {  # <effort-id>
  local effort_id=$1
  [ -f "$LEDGER" ] || return 0
  jq -r --arg id "$effort_id" '
    select(.effort_id == $id) | .to_stage // empty
  ' "$LEDGER" 2>/dev/null | tail -1
}

content_hash_seen() {  # <hash>
  local hash=$1
  [ -f "$LEDGER" ] || return 1
  jq -e --arg hash "$hash" '
    select(.content_hash? == $hash) | true
  ' "$LEDGER" >/dev/null 2>&1
}

validate_decision_event() {  # <event-json>
  printf '%s\n' "$1" | jq -e '
    .decision as $d
    | ($d | type == "object")
    and (($d.kind // "") as $k | ["scope","merge_word","waiver","priority","cancellation"] | index($k) != null)
    and (($d.question // "") | type == "string" and length > 0)
    and (($d.recommendation // "") | type == "string" and length > 0)
    and (($d.options // null) | type == "array" and length > 0)
  ' >/dev/null
}

append_event_json() {  # <event-json>
  local event=$1 validated effort_id to_stage from_stage event_kind current
  ensure_ledger_dir
  validated=$(printf '%s\n' "$event" | jq -ce '
    . as $e
    | (($e.ts // "") | type == "string" and length > 0)
    and (($e.effort_id // "") | type == "string" and length > 0)
    and (($e.kind // "") | type == "string" and length > 0)
    and (($e.actor // "") | type == "string" and length > 0)
    and ($e | has("from_stage"))
    and (($e.to_stage // "") | type == "string" and length > 0)
    and ($e | has("note"))
    | if . then $e else error("missing required event field") end
  ') || die "invalid event JSON"

  effort_id=$(printf '%s\n' "$validated" | jq -r '.effort_id')
  to_stage=$(printf '%s\n' "$validated" | jq -r '.to_stage')
  from_stage=$(printf '%s\n' "$validated" | jq -r '.from_stage // ""')
  event_kind=$(printf '%s\n' "$validated" | jq -r '.kind')

  stage_valid "$to_stage" || die "invalid to_stage: $to_stage"
  if [ -n "$from_stage" ]; then
    stage_valid "$from_stage" || die "invalid from_stage: $from_stage"
  fi

  if [ "$to_stage" = needs_captain ] || [ "$event_kind" = needs_captain ]; then
    validate_decision_event "$validated" || die "needs_captain event requires a valid decision card"
  fi

  current=$(current_stage "$effort_id" || true)
  if terminal_stage "$to_stage"; then
    if [ -n "$current" ] && terminal_stage "$current"; then
      die "terminal CAS rejected for $effort_id: already $current"
    fi
    if [ -n "$from_stage" ] && [ -n "$current" ] && [ "$from_stage" != "$current" ]; then
      die "terminal CAS rejected for $effort_id: expected $from_stage, current $current"
    fi
  fi

  printf '%s\n' "$validated" >> "$LEDGER"
}

decision_from_fields() {  # <kind> <question> <recommendation> <options-json>
  local kind=$1 question=$2 recommendation=$3 options_json=$4
  jq -cn \
    --arg kind "$kind" \
    --arg question "$question" \
    --arg recommendation "$recommendation" \
    --argjson options "$options_json" \
    '{kind:$kind, question:$question, recommendation:$recommendation, options:$options}'
}

default_decision_for_note() {  # <question>
  local question=$1
  decision_from_fields scope "$question" REVIEW '["APPROVE","CHANGES_REQUESTED","PARK"]'
}

make_event_json() {
  local ts=$1 effort_id=$2 kind=$3 actor=$4 evidence=$5 from_stage=$6 to_stage=$7 note=$8 decision_json=$9 extra_json=${10}
  jq -cn \
    --arg ts "$ts" \
    --arg effort_id "$effort_id" \
    --arg kind "$kind" \
    --arg actor "$actor" \
    --arg evidence "$evidence" \
    --arg from_stage "$from_stage" \
    --arg to_stage "$to_stage" \
    --arg note "$note" \
    --argjson decision "$decision_json" \
    --argjson extra "$extra_json" '
      {
        ts: $ts,
        effort_id: $effort_id,
        kind: $kind,
        actor: $actor,
        "evidence_url/path": $evidence,
        evidence: $evidence,
        from_stage: $from_stage,
        to_stage: $to_stage,
        note: $note
      }
      + (if ($evidence | test("^https?://")) then {evidence_url: $evidence} else {evidence_path: $evidence} end)
      + (if $decision == null then {} else {decision: $decision} end)
      + $extra
    '
}

cmd_emit() {
  need_jq
  local effort_id="" kind=stage actor=manual evidence="" from_stage="" to_stage="" note=""
  local decision_json="" decision_kind="" question="" recommendation="" options_json option
  local options=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --effort-id) [ $# -ge 2 ] || die "--effort-id needs a value"; effort_id=$2; shift 2 ;;
      --kind) [ $# -ge 2 ] || die "--kind needs a value"; kind=$2; shift 2 ;;
      --actor) [ $# -ge 2 ] || die "--actor needs a value"; actor=$2; shift 2 ;;
      --evidence) [ $# -ge 2 ] || die "--evidence needs a value"; evidence=$2; shift 2 ;;
      --from-stage) [ $# -ge 2 ] || die "--from-stage needs a value"; from_stage=$2; shift 2 ;;
      --to-stage) [ $# -ge 2 ] || die "--to-stage needs a value"; to_stage=$2; shift 2 ;;
      --note) [ $# -ge 2 ] || die "--note needs a value"; note=$2; shift 2 ;;
      --decision-json) [ $# -ge 2 ] || die "--decision-json needs a value"; decision_json=$2; shift 2 ;;
      --decision-kind) [ $# -ge 2 ] || die "--decision-kind needs a value"; decision_kind=$2; shift 2 ;;
      --question) [ $# -ge 2 ] || die "--question needs a value"; question=$2; shift 2 ;;
      --recommendation) [ $# -ge 2 ] || die "--recommendation needs a value"; recommendation=$2; shift 2 ;;
      --option) [ $# -ge 2 ] || die "--option needs a value"; option=$2; options+=("$option"); shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  [ -n "$effort_id" ] || die "--effort-id is required"
  [ -n "$to_stage" ] || die "--to-stage is required"
  stage_valid "$to_stage" || die "invalid to_stage: $to_stage"
  if [ -z "$from_stage" ]; then
    from_stage=$(current_stage "$effort_id" || true)
  fi
  if [ -n "$from_stage" ]; then
    stage_valid "$from_stage" || die "invalid from_stage: $from_stage"
  fi

  if [ -z "$decision_json" ]; then
    if [ "$to_stage" = needs_captain ] || [ "$kind" = needs_captain ] || [ -n "$decision_kind" ] || [ -n "$question" ]; then
      [ -n "$decision_kind" ] || decision_kind=scope
      [ -n "$question" ] || question=$note
      [ -n "$recommendation" ] || recommendation=REVIEW
      if [ "${#options[@]}" -eq 0 ]; then
        options=(APPROVE CHANGES_REQUESTED PARK)
      fi
      options_json=$(jq -cn '$ARGS.positional' --args "${options[@]}")
      decision_json=$(decision_from_fields "$decision_kind" "$question" "$recommendation" "$options_json")
    else
      decision_json=null
    fi
  else
    decision_json=$(printf '%s\n' "$decision_json" | jq -ce '.')
  fi

  append_event_json "$(make_event_json "$NOW" "$effort_id" "$kind" "$actor" "$evidence" "$from_stage" "$to_stage" "$note" "$decision_json" '{}')"
  printf 'emitted: %s %s -> %s\n' "$effort_id" "${from_stage:-<none>}" "$to_stage"
}

fold_rows_json() {
  need_jq
  if [ ! -f "$LEDGER" ]; then
    printf '[]\n'
    return 0
  fi
  jq -s '
    def event_evidence($e):
      $e.evidence // $e.evidence_url // $e.evidence_path // $e["evidence_url/path"] // "";
    def row($e; $prev):
      {
        effort_id: $e.effort_id,
        stage: $e.to_stage,
        updated_at: $e.ts,
        actor: $e.actor,
        kind: $e.kind,
        from_stage: ($e.from_stage // ""),
        note: ($e.note // ""),
        evidence: event_evidence($e),
        decision: ($e.decision // null),
        stage_ts: ($e.stage_ts // null),
        content_hash: ($e.content_hash // null),
        events_count: (($prev.events_count // 0) + 1)
      };
    reduce .[] as $e ({}; .[$e.effort_id] = row($e; (.[$e.effort_id] // {})))
    | [.[]]
    | sort_by(.effort_id)
  ' "$LEDGER"
}

cmd_list() {
  local json=0 rows
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  rows=$(fold_rows_json)
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$rows"
    return 0
  fi
  printf 'effort_id\tstage\tupdated_at\tactor\tkind\tnote\tevidence\n'
  printf '%s\n' "$rows" | jq -r '.[] | [.effort_id, .stage, .updated_at, .actor, .kind, .note, .evidence] | @tsv'
}

cmd_board() {
  local output=$BOARD rows tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --output) [ $# -ge 2 ] || die "--output needs a value"; output=$2; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  rows=$(fold_rows_json)
  mkdir -p "$(dirname "$output")"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-effort-board.XXXXXX")
  jq -nr \
    --arg generated "$NOW" \
    --argjson rows "$rows" '
      def epoch:
        try (
          if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end
          | sub("\\.[0-9]+Z$"; "Z")
          | fromdateiso8601
        ) catch 0;
      def evidence_text($r):
        if (($r.evidence // "") | length) > 0 then "\n  Evidence: \($r.evidence)" else "" end;
      def note_text($r):
        if (($r.note // "") | length) > 0 then $r.note else "no note" end;
      def decision_line($r):
        "- **\($r.effort_id)** - \($r.decision.question // note_text($r))\n" +
        "  Recommendation: \($r.decision.recommendation // "REVIEW")\n" +
        "  Options: \(($r.decision.options // []) | join(", "))" +
        evidence_text($r);
      def effort_line($r):
        "- **\($r.effort_id)** (`\($r.stage)`, \($r.updated_at)) - \(note_text($r))" + evidence_text($r);
      def section($title; $items; $decision):
        "## \($title)\n" +
        (if ($items | length) == 0 then "_None._"
         elif $decision then ($items | map(decision_line(.)) | join("\n"))
         else ($items | map(effort_line(.)) | join("\n"))
         end);
      ($generated | epoch) as $now
      | "# Effort Board\n\nGenerated: \($generated)\n\n" +
        section("1. NEEDS TIM NOW";
          ($rows | map(select(.stage == "needs_captain")));
          true
        ) + "\n\n" +
        section("2. In Flight";
          ($rows | map(select(.stage == "intake" or .stage == "in_progress" or .stage == "in_review" or .stage == "merge_ready")));
          false
        ) + "\n\n" +
        section("3. Blocked On Others";
          ($rows | map(select(.stage == "blocked")));
          false
        ) + "\n\n" +
        section("4. Landed 48h";
          ($rows | map(select((.stage == "merged" or .stage == "deployed" or .stage == "fallout_observed" or .stage == "done") and (((.stage_ts // .updated_at) | epoch) >= ($now - 172800)))));
          false
        ) + "\n"
    ' > "$tmp"
  mv "$tmp" "$output"
  printf 'board: %s\n' "$output"
}

normalize_task_stage() {  # <state> <blocked>
  local state=$1 blocked=$2
  if [ "$blocked" = yes ]; then
    printf 'blocked\n'
    return 0
  fi
  case "$state" in
    queued) printf 'intake\n' ;;
    in_flight) printf 'in_progress\n' ;;
    done) printf '%s\n' "done" ;;
    *) printf 'intake\n' ;;
  esac
}

tasks_rows_json() {  # <source-home> <out-jsonl>
  local source_home=$1 out=$2 raw rows parsed
  command -v tasks-axi >/dev/null 2>&1 || die "tasks-axi is required for tasks ingest"
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-effort-tasks.raw.XXXXXX")
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-effort-tasks.rows.XXXXXX")
  parsed=$(mktemp "${TMPDIR:-/tmp}/fm-effort-tasks.parsed.XXXXXX")
  (cd "$source_home" && tasks-axi list --limit "$TASKS_LIMIT" --fields blocked,blocked_by,created,closed,links,priority) > "$raw"
  sed -n '/^  /s/^  //p' "$raw" > "$rows"
  awk '
    function unquote(s) {
      if (s ~ /^".*"$/) {
        sub(/^"/, "", s)
        sub(/"$/, "", s)
        gsub(/""/, "\"", s)
      }
      return s
    }
    function pop_field(  p, value) {
      p = index(rest, ",")
      if (p == 0) {
        value = rest
        rest = ""
      } else {
        value = substr(rest, 1, p - 1)
        rest = substr(rest, p + 1)
      }
      return unquote(value)
    }
    function pop_title(  i, c, n, title, tail) {
      if (substr(rest, 1, 1) != "\"") {
        return pop_field()
      }
      title = "\""
      n = length(rest)
      for (i = 2; i <= n; i++) {
        c = substr(rest, i, 1)
        title = title c
        if (c == "\"") {
          if (substr(rest, i + 1, 1) == "\"") {
            i++
            title = title "\""
          } else {
            tail = substr(rest, i + 1)
            if (substr(tail, 1, 1) == ",") {
              rest = substr(tail, 2)
            } else {
              rest = tail
            }
            return unquote(title)
          }
        }
      }
      rest = ""
      return unquote(title)
    }
    /^[^,]+,/ {
      raw = $0
      rest = raw
      id = pop_field()
      if (id == "" || id == "-" || id ~ /^help\[/) next
      state = pop_field()
      task_kind = pop_field()
      repo = pop_field()
      title = pop_title()
      blocked = pop_field()
      blocked_by = pop_field()
      created = pop_field()
      closed = pop_field()
      links = pop_field()
      priority = pop_field()
      if (state !~ /^(queued|in_flight|done)$/) next
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", raw, id, state, task_kind, repo, title, blocked, blocked_by, created, closed, links, priority
    }
  ' "$rows" > "$parsed"
  jq -Rce '
    split("\t") as $row
    | select(($row | length) >= 12)
    | {
        raw: $row[0],
        id: $row[1],
        source_state: $row[2],
        task_kind: $row[3],
        repo: $row[4],
        title: $row[5],
        blocked: $row[6],
        blocked_by: $row[7],
        created: $row[8],
        closed: $row[9],
        links: $row[10],
        priority: $row[11]
      }
  ' "$parsed" > "$out"
  rm -f "$raw" "$rows" "$parsed"
}

emit_ingest_event() {
  local source=$1 effort_id=$2 to_stage=$3 evidence=$4 note=$5 content_hash=$6 actor=$7 decision_json=$8
  local stage_ts=${9:-} from_stage extra_json event
  if content_hash_seen "$content_hash"; then
    INGEST_SKIPPED=$((INGEST_SKIPPED + 1))
    return 0
  fi
  from_stage=$(current_stage "$effort_id" || true)
  if [ "$to_stage" = needs_captain ] && [ "$decision_json" = null ]; then
    decision_json=$(default_decision_for_note "$note")
  fi
  extra_json=$(jq -cn --arg source "$source" --arg content_hash "$content_hash" --arg stage_ts "$stage_ts" \
    '{source:$source, content_hash:$content_hash} + (if $stage_ts == "" then {} else {stage_ts:$stage_ts} end)')
  event=$(make_event_json "$NOW" "$effort_id" "${source}_observed" "$actor" "$evidence" "$from_stage" "$to_stage" "$note" "$decision_json" "$extra_json")
  append_event_json "$event"
  INGEST_EMITTED=$((INGEST_EMITTED + 1))
}

ingest_state() {  # <source-home>
  local source_home=$1 state_dir meta id status_file status_line verb to_stage raw hash harness meta_kind note evidence
  state_dir="$source_home/state"
  [ -d "$state_dir" ] || die "missing state dir: $state_dir"
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    status_file="$state_dir/$id.status"
    status_line=""
    if [ -f "$status_file" ]; then
      status_line=$(grep -v '^[[:space:]]*$' "$status_file" 2>/dev/null | tail -1 || true)
    fi
    verb=${status_line%%:*}
    meta_kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ "$meta_kind" = secondmate ]; then
      to_stage=in_progress
    else
      case "$verb" in
        done) to_stage="done" ;;
        needs-decision) to_stage=needs_captain ;;
        blocked|failed) to_stage=blocked ;;
        *) to_stage=in_progress ;;
      esac
    fi
    harness=$(grep '^harness=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$harness" ] || harness=unknown
    if [ -n "$status_line" ]; then
      note="$status_line"
    else
      note="live meta present at $meta"
    fi
    evidence="$meta"
    raw=$(sed -n '1,$p' "$meta"; printf '\nstatus=%s\n' "$status_line")
    hash=$(sha256_string "state:$id:$raw")
    emit_ingest_event state "$id" "$to_stage" "$evidence" "$note" "$hash" "fm-effort:state:$harness" null
  done
}

ingest_tasks() {  # <source-home>
  local source_home=$1 rows item id state blocked to_stage title repo task_kind closed evidence note hash raw stage_ts
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-effort-tasks.jsonl.XXXXXX")
  tasks_rows_json "$source_home" "$rows"
  while IFS= read -r item; do
    id=$(printf '%s\n' "$item" | jq -r '.id')
    state=$(printf '%s\n' "$item" | jq -r '.source_state')
    blocked=$(printf '%s\n' "$item" | jq -r '.blocked')
    to_stage=$(normalize_task_stage "$state" "$blocked")
    title=$(printf '%s\n' "$item" | jq -r '.title')
    repo=$(printf '%s\n' "$item" | jq -r '.repo')
    task_kind=$(printf '%s\n' "$item" | jq -r '.task_kind')
    closed=$(printf '%s\n' "$item" | jq -r '.closed')
    raw=$(printf '%s\n' "$item" | jq -r '.raw')
    evidence="tasks-axi:list:$id"
    note="$title (repo=$repo kind=$task_kind tasks_state=$state)"
    hash=$(sha256_string "tasks:$raw")
    stage_ts=""
    if [ "$to_stage" = "done" ] && [ "$closed" != "-" ]; then
      stage_ts="$closed"
    fi
    emit_ingest_event tasks "$id" "$to_stage" "$evidence" "$note" "$hash" "fm-effort:tasks-axi" null "$stage_ts"
  done < "$rows"
  rm -f "$rows"
}

inventory_rows_json() {  # <inventory-json> <out-jsonl> [repo-allowlist]
  local inventory=$1 out=$2 repo_allowlist=${3:-}
  [ -f "$inventory" ] || die "missing inventory JSON: $inventory"
  jq -c --arg path "$inventory" --arg generated "$NOW" --arg repo_allowlist "$repo_allowlist" '
    def rows:
      if type == "array" then .
      else (.items // .rows // .efforts // [])
      end;
    def text($v): if $v == null then "" else ($v | tostring) end;
    def first_nonempty:
      map(text(.))
      | map(select(length > 0))
      | .[0] // "";
    def epoch:
      try (
        if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end
        | sub("\\.[0-9]+Z$"; "Z")
        | fromdateiso8601
      ) catch 0;
    def allowlist:
      $repo_allowlist
      | split(",")
      | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
      | map(select(length > 0));
    def repo_from_url($url):
      try ($url | capture("github\\.com/(?<repo>[^/]+/[^/]+)/").repo) catch "";
    def row_repos:
      [.prs[]? | text(.repository // repo_from_url(.url // ""))]
      | map(select(length > 0))
      | unique;
    def glob_match($repo; $pattern):
      if $pattern == "*" then true
      elif ($pattern | contains("*")) then
        ($pattern | split("*")) as $parts
        | ($repo | startswith($parts[0]) and endswith($parts[-1]))
      else
        $repo == $pattern
      end;
    def repo_allowed:
      (allowlist) as $allow
      | if ($allow | length) == 0 then true
        elif (row_repos | length) == 0 then true
        else any(row_repos[]; . as $repo | any($allow[]; glob_match($repo; .)))
        end;
    def has_linear:
      ((.linear // []) | if type == "array" then length else 1 end) > 0;
    def first_linear:
      if (.linear // null) == null then {}
      elif (.linear | type) == "array" then (.linear[0] // {})
      elif (.linear | type) == "object" then .linear
      else {}
      end;
    def state_type_value($v):
      if $v == null then ""
      elif ($v | type) == "object" then text($v.type // $v.stateType // "")
      else ""
      end;
    def state_name_value($v):
      if $v == null then ""
      elif ($v | type) == "object" then text($v.name // $v.displayName // $v.title // "")
      else text($v)
      end;
    def linear_state_type:
      (first_linear) as $l
      | [.stateType?, .state_type?, state_type_value(.state?), $l.stateType?, $l.state_type?, state_type_value($l.state?)]
      | first_nonempty;
    def linear_state_name:
      (first_linear) as $l
      | [.stateName?, .state_name?, state_name_value(.state?), $l.stateName?, $l.state_name?, state_name_value($l.state?)]
      | first_nonempty;
    def linear_completed_or_canceled:
      has_linear and (linear_state_type | test("completed|canceled|cancelled"; "i"));
    def linear_duplicate_state:
      has_linear and ((linear_state_name | ascii_downcase) == "duplicate");
    def pr_lifecycle($pr):
      text($pr.lifecycle // $pr.state // $pr.status // "");
    def pr_landed($pr):
      (pr_lifecycle($pr) | test("^(merged|closed[- ]landed|closed landed)"; "i"));
    def pr_terminal($pr):
      pr_landed($pr) or (pr_lifecycle($pr) | test("^closed"; "i"));
    def pr_terminal_ts($pr):
      text($pr.mergedAt // $pr.closedAt // (try (pr_lifecycle($pr) | capture("(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+)").ts) catch null) // $pr.updatedAt // $pr.fetchedAt // "");
    def latest_pr_landed_ts:
      [.prs[]? | select(pr_landed(.)) | pr_terminal_ts(.) | select(length > 0)] | max // "";
    def pr_only_all_terminal:
      (has_linear | not) and (([.prs[]?] | length) > 0) and all(.prs[]?; pr_terminal(.));
    def pr_only_all_landed:
      (has_linear | not) and (([.prs[]?] | length) > 0) and all(.prs[]?; pr_landed(.));
    def within_48h($ts):
      (($ts | epoch) > 0) and (($ts | epoch) >= (($generated | epoch) - 172800));
    def keep_recent_pr_landed:
      pr_only_all_landed and within_48h(latest_pr_landed_ts);
    def skip_row:
      linear_completed_or_canceled
      or linear_duplicate_state
      or (repo_allowed | not)
      or (pr_only_all_terminal and (keep_recent_pr_landed | not));
    def urls:
      [
        .url?,
        .source_url?,
        .sourceUrl?,
        .urls[]?,
        .prs[]?.url?,
        .linear[]?.url?
      ] | map(select(. != null and (tostring | length > 0))) | map(tostring);
    def norm_stage($s):
      ($s | tostring | ascii_downcase | gsub("[^a-z0-9]+"; "_")) as $n
      | if ["intake","in_progress","in_review","merge_ready","merged","deployed","fallout_observed","done","blocked","needs_captain","abandoned"] | index($n) != null then $n
        elif ($n | test("needs.*captain|captain.*decision|human.*stamp")) then "needs_captain"
        elif ($n | test("merge.*ready|ready.*merge|ship.*stamp")) then "merge_ready"
        elif ($n | test("review|ready_for_review")) then "in_review"
        elif ($n | test("in.*progress|implement")) then "in_progress"
        elif ($n | test("fallout")) then "fallout_observed"
        elif ($n | test("deploy")) then "deployed"
        elif ($n | test("merged")) then "merged"
        elif ($n | test("done|complete|closed")) then "done"
        elif ($n | test("abandon|cancel|obsolete")) then "abandoned"
        elif ($n | test("block|red|failed")) then "blocked"
        else ""
        end;
    def blocker_list:
      (.blockers // .blocker // [])
      | if type == "array" then . elif . == null then [] elif tostring == "" then [] else [.] end
      | map(text(.))
      | map(select(length > 0));
    def blocker_text:
      blocker_list | join(" | ");
    def transition_ts:
      text(.last_transition_ts // .lastTransitionTs // .updatedAt // .generatedAt // .fetchedAt // latest_pr_landed_ts);
    def stale_since_transition:
      ((transition_ts | epoch) > 0) and ((transition_ts | epoch) <= (($generated | epoch) - 86400));
    def changes_requested_stale:
      (blocker_text | test("CHANGES_REQUESTED|changes requested"; "i")) and stale_since_transition;
    def named_dependency_blocker:
      blocker_text | test("blocked[- ]on|blocked[- ]by|dependency|depends|waiting on|merge state BLOCKED|DAT-[0-9]+|Temporal Cloud|admin|captain-deferred|deferred|key MINT|secret"; "i");
    def blocked_signal:
      changes_requested_stale or named_dependency_blocker;
    def action:
      text(.captain_action // .captainAction // .exactCaptainAction);
    def explicit_captain_now:
      (action | test("explicit merge|merge/stamp|decide ownership|decide priority|captain decision|needs captain"; "i"));
    def derived_stage:
      (norm_stage(.stage // .lifecycle_stage // .lifecycleStage // "")) as $explicit
      | if $explicit != "" then $explicit
        elif keep_recent_pr_landed then "done"
        elif explicit_captain_now then "needs_captain"
        elif blocked_signal then "blocked"
        elif ([.prs[]?.lifecycle? | tostring | ascii_downcase | contains("merged")] | any) then "merged"
        elif (([.prs[]?.review.decision? | tostring | ascii_downcase | test("approved")] | any)
          and ([.prs[]?.ci.state? | tostring | ascii_downcase | test("success|green|pass|green_or_skipped")] | any)) then "merge_ready"
        elif ([.prs[]?] | length) > 0 then "in_review"
        else "intake"
        end;
    rows[]
    | (text(.effort_id // .effortId // .logicalId // .id)) as $id
    | select($id | length > 0)
    | select(skip_row | not)
    | (urls) as $urls
    | {
        raw: .,
        id: $id,
        stage: derived_stage,
        evidence: (if ($urls | length) > 0 then $urls[0] else $path end),
        title: text(.title // .name // $id),
        next_machine_action: text(.next_machine_action // .nextMachineAction // .exactNextMachineAction),
        captain_action: action,
        blockers: blocker_list,
        last_transition_ts: (if keep_recent_pr_landed then latest_pr_landed_ts else transition_ts end),
        decision: (
          if derived_stage == "needs_captain" then
            {
              kind: (if (action | test("merge|stamp"; "i")) then "merge_word"
                elif (action | test("cancel|close|obsolete|resurrect"; "i")) then "cancellation"
                elif (action | test("priority|ownership"; "i")) then "priority"
                else "scope" end),
              question: (if (action | length) > 0 then action else ("Decide next action for " + $id) end),
              recommendation: "REVIEW",
              options: ["APPROVE","CHANGES_REQUESTED","PARK"]
            }
          else null
          end
        )
      }
  ' "$inventory" > "$out"
}

ingest_inventory() {  # <inventory-json> [repo-allowlist]
  local inventory=$1 repo_allowlist=${2:-} rows item id stage evidence title machine captain blockers last_ts note hash raw decision_json
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-effort-inventory.jsonl.XXXXXX")
  inventory_rows_json "$inventory" "$rows" "$repo_allowlist"
  while IFS= read -r item; do
    id=$(printf '%s\n' "$item" | jq -r '.id')
    stage=$(printf '%s\n' "$item" | jq -r '.stage')
    evidence=$(printf '%s\n' "$item" | jq -r '.evidence')
    title=$(printf '%s\n' "$item" | jq -r '.title')
    machine=$(printf '%s\n' "$item" | jq -r '.next_machine_action')
    captain=$(printf '%s\n' "$item" | jq -r '.captain_action')
    blockers=$(printf '%s\n' "$item" | jq -c '.blockers')
    last_ts=$(printf '%s\n' "$item" | jq -r '.last_transition_ts')
    raw=$(printf '%s\n' "$item" | jq -c '.raw')
    decision_json=$(printf '%s\n' "$item" | jq -c '.decision')
    note="$title"
    [ -z "$machine" ] || note="$note; next_machine=$machine"
    [ -z "$captain" ] || note="$note; captain_action=$captain"
    [ "$blockers" = "[]" ] || note="$note; blockers=$blockers"
    [ -z "$last_ts" ] || note="$note; last_transition_ts=$last_ts"
    hash=$(sha256_string "inventory:$inventory:$raw")
    emit_ingest_event inventory "$id" "$stage" "$evidence" "$note" "$hash" "fm-effort:inventory" "$decision_json" "$last_ts"
  done < "$rows"
  rm -f "$rows"
}

cmd_ingest() {
  need_jq
  local adapter=${1:-} source_home="${FM_EFFORT_SOURCE_HOME:-$FM_HOME}" inventory="" repo_allowlist=""
  [ -n "$adapter" ] || { usage; exit 1; }
  shift
  INGEST_EMITTED=0
  INGEST_SKIPPED=0
  case "$adapter" in
    state|tasks)
      while [ $# -gt 0 ]; do
        case "$1" in
          --home) [ $# -ge 2 ] || die "--home needs a value"; source_home=$2; shift 2 ;;
          --help|-h) usage; exit 0 ;;
          *) usage; exit 1 ;;
        esac
      done
      if [ "$adapter" = state ]; then ingest_state "$source_home"; else ingest_tasks "$source_home"; fi
      ;;
    inventory)
      while [ $# -gt 0 ]; do
        case "$1" in
          --repo-allowlist) [ $# -ge 2 ] || die "--repo-allowlist needs a value"; repo_allowlist=$2; shift 2 ;;
          --help|-h) usage; exit 0 ;;
          *)
            [ -z "$inventory" ] || { usage; exit 1; }
            inventory=$1
            shift
            ;;
        esac
      done
      [ -n "$inventory" ] || { usage; exit 1; }
      ingest_inventory "$inventory" "$repo_allowlist"
      ;;
    all)
      while [ $# -gt 0 ]; do
        case "$1" in
          --home) [ $# -ge 2 ] || die "--home needs a value"; source_home=$2; shift 2 ;;
          --inventory) [ $# -ge 2 ] || die "--inventory needs a value"; inventory=$2; shift 2 ;;
          --repo-allowlist) [ $# -ge 2 ] || die "--repo-allowlist needs a value"; repo_allowlist=$2; shift 2 ;;
          --help|-h) usage; exit 0 ;;
          *) usage; exit 1 ;;
        esac
      done
      ingest_state "$source_home"
      ingest_tasks "$source_home"
      if [ -n "$inventory" ]; then
        ingest_inventory "$inventory" "$repo_allowlist"
      fi
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  printf 'ingest: emitted=%s skipped=%s ledger=%s\n' "$INGEST_EMITTED" "$INGEST_SKIPPED" "$LEDGER"
}

cmd_reconcile() {
  need_jq
  local source_home="${FM_EFFORT_SOURCE_HOME:-$FM_HOME}" json=0 state_dir rows metas out item id state title evidence
  while [ $# -gt 0 ]; do
    case "$1" in
      --home) [ $# -ge 2 ] || die "--home needs a value"; source_home=$2; shift 2 ;;
      --json) json=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  state_dir="$source_home/state"
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-effort-reconcile-tasks.XXXXXX")
  metas=$(mktemp "${TMPDIR:-/tmp}/fm-effort-reconcile-metas.XXXXXX")
  out=$(mktemp "${TMPDIR:-/tmp}/fm-effort-reconcile-out.XXXXXX")
  : > "$metas"
  : > "$out"
  if [ -d "$state_dir" ]; then
    for meta in "$state_dir"/*.meta; do
      [ -e "$meta" ] || continue
      basename "$meta" .meta >> "$metas"
    done
  fi
  sort -o "$metas" "$metas"
  tasks_rows_json "$source_home" "$rows"
  while IFS= read -r item; do
    state=$(printf '%s\n' "$item" | jq -r '.source_state')
    [ "$state" = in_flight ] || continue
    id=$(printf '%s\n' "$item" | jq -r '.id')
    if grep -Fx -- "$id" "$metas" >/dev/null 2>&1; then
      continue
    fi
    title=$(printf '%s\n' "$item" | jq -r '.title')
    evidence="tasks-axi:list:$id plus missing $state_dir/$id.meta"
    jq -cn \
      --arg effort_id "$id" \
      --arg title "$title" \
      --arg evidence "$evidence" \
      '{effort_id:$effort_id, title:$title, reason:"backlog row claims in_flight but no live meta exists", evidence:$evidence}' >> "$out"
  done < "$rows"

  if [ "$json" -eq 1 ]; then
    jq -s '.' "$out"
  else
    printf 'stale_efforts[%s]{effort_id,reason,evidence}:\n' "$(jq -s 'length' "$out")"
    jq -r '. | "  \(.effort_id)\t\(.reason)\t\(.evidence)"' "$out"
  fi
  rm -f "$rows" "$metas" "$out"
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] || { usage; exit 1; }
  shift
  case "$cmd" in
    emit) cmd_emit "$@" ;;
    list) cmd_list "$@" ;;
    board) cmd_board "$@" ;;
    ingest) cmd_ingest "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    --help|-h|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
