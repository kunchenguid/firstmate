#!/usr/bin/env bash
# One intake poll cycle for firstmate's watcher check mechanism.
#
# Inert by default: a HARD no-op unless config/intake.env exists. Bootstrap owns
# generating/removing state/intake.check.sh; this body keeps the same safety
# contract when run directly.
#
# Check contract: print exactly one compact line only when firstmate should wake,
# otherwise print nothing. Side effects (snapshots + backlog derivation) are
# intentionally silent.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-backlog-generated-lib.sh
. "$SCRIPT_DIR/fm-backlog-generated-lib.sh"

INTAKE_ENV="${FM_INTAKE_ENV:-$CONFIG/intake.env}"
[ -f "$INTAKE_ENV" ] || exit 0
# shellcheck disable=SC1090
. "$INTAKE_ENV"
INTAKE_SLA_ENV="${FM_INTAKE_SLA_ENV:-$CONFIG/intake-sla.env}"
if [ -f "$INTAKE_SLA_ENV" ]; then
  # shellcheck disable=SC1090
  . "$INTAKE_SLA_ENV"
fi

INTAKE_STATE="$STATE/intake"
ERROR_FILE="$INTAKE_STATE/error"
BACKLOG_OUT="${FM_INTAKE_BACKLOG_OUT:-$DATA/backlog.md}"

GH_REPO="${FM_GH_REPO:-lindy-ai/lindy}"
GH_OWNER="${FM_GH_OWNER:-lindy-ai}"
GH_USER="${FM_GH_USER:-twaldin}"
GH_LIMIT="${FM_GH_LIMIT:-1000}"
GH_CMD="${FM_INTAKE_GH_CMD:-gh-axi}"

BROKER_CMD="${FM_INTAKE_BROKER_CMD:-$FM_ROOT/bin/fm-mcp-broker}"
BROKER_HOME_PATH="${FM_INTAKE_BROKER_HOME:-$FM_HOME/data/mcp-broker/home}"
LINEAR_ASSIGNEE="${FM_INTAKE_LINEAR_ASSIGNEE:-tim@lindy.ai}"
LINEAR_QUERY="${FM_INTAKE_LINEAR_QUERY:-assignee:$LINEAR_ASSIGNEE state:!Done state:!Canceled state:!Duplicate}"
LINEAR_ONCALL_EXAMPLE="${FM_INTAKE_LINEAR_ONCALL_EXAMPLE:-EM-11195}"
# Confirmed against EM-11195 on 2026-07-07. Keep the emoji: Linear stores it.
INTAKE_LINEAR_ONCALL_LABEL="${FM_INTAKE_LINEAR_ONCALL_LABEL:-🚨 On Call}"

ONCALL_WARN_VALUE="${FM_INTAKE_ONCALL_WARN_SECS:-${FM_INTAKE_ONCALL_WARN:-18h}}"
ONCALL_BREACH_VALUE="${FM_INTAKE_ONCALL_BREACH_SECS:-${FM_INTAKE_ONCALL_BREACH:-24h}}"
REVIEW_WARN_VALUE="${FM_INTAKE_REVIEW_WARN_SECS:-${FM_INTAKE_REVIEW_WARN:-24h}}"
REVIEW_BREACH_VALUE="${FM_INTAKE_REVIEW_BREACH_SECS:-${FM_INTAKE_REVIEW_BREACH:-}}"
NORMAL_WARN_VALUE="${FM_INTAKE_NORMAL_WARN_SECS:-${FM_INTAKE_NORMAL_WARN:-}}"
NORMAL_BREACH_VALUE="${FM_INTAKE_NORMAL_BREACH_SECS:-${FM_INTAKE_NORMAL_BREACH:-}}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-intake-poll.XXXXXX") || exit 0
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

emit_error_once() {
  local msg=$1
  mkdir -p "$INTAKE_STATE" 2>/dev/null || true
  if [ -f "$ERROR_FILE" ] && [ "$(cat "$ERROR_FILE" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" > "$ERROR_FILE" 2>/dev/null || true
  printf 'intake-error %s\n' "$msg"
}

clear_error() {
  rm -f "$ERROR_FILE" 2>/dev/null || true
}

safe_reason() {
  sed -n '1s/[[:space:]]\{1,\}/ /g;1p' "$1" 2>/dev/null \
    | sed -E 's/([Aa]uthorization: )[^\ ]+/\1[REDACTED]/g; s/([Tt]oken|[Ss]ecret|[Aa]pi[_-]?[Kk]ey)=?[^ ]+/\1=[REDACTED]/g'
}

duration_to_secs() {
  local value=$1 fallback=$2
  case "$value" in
    '') printf '%s\n' "$fallback" ;;
    *[!0-9hmsHMS]*) printf '%s\n' "$fallback" ;;
    *[hH])
      value=${value%[hH]}
      case "$value" in ''|*[!0-9]*) printf '%s\n' "$fallback" ;; *) printf '%s\n' $((value * 3600)) ;; esac
      ;;
    *[mM])
      value=${value%[mM]}
      case "$value" in ''|*[!0-9]*) printf '%s\n' "$fallback" ;; *) printf '%s\n' $((value * 60)) ;; esac
      ;;
    *[sS])
      value=${value%[sS]}
      case "$value" in ''|*[!0-9]*) printf '%s\n' "$fallback" ;; *) printf '%s\n' "$value" ;; esac
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

optional_duration_to_secs() {
  local value=$1
  case "$value" in
    '') printf '\n' ;;
    *[!0-9hmsHMS]*) printf '\n' ;;
    *[hH])
      value=${value%[hH]}
      case "$value" in ''|*[!0-9]*) printf '\n' ;; *) printf '%s\n' $((value * 3600)) ;; esac
      ;;
    *[mM])
      value=${value%[mM]}
      case "$value" in ''|*[!0-9]*) printf '\n' ;; *) printf '%s\n' $((value * 60)) ;; esac
      ;;
    *[sS])
      value=${value%[sS]}
      case "$value" in ''|*[!0-9]*) printf '\n' ;; *) printf '%s\n' "$value" ;; esac
      ;;
    *) printf '%s\n' "$value" ;;
  esac
}

ONCALL_WARN_SECS=$(duration_to_secs "$ONCALL_WARN_VALUE" 64800)
ONCALL_BREACH_SECS=$(duration_to_secs "$ONCALL_BREACH_VALUE" 86400)
REVIEW_WARN_SECS=$(duration_to_secs "$REVIEW_WARN_VALUE" 86400)
REVIEW_BREACH_SECS=$(optional_duration_to_secs "$REVIEW_BREACH_VALUE")
NORMAL_WARN_SECS=$(optional_duration_to_secs "$NORMAL_WARN_VALUE")
NORMAL_BREACH_SECS=$(optional_duration_to_secs "$NORMAL_BREACH_VALUE")

if [ -n "${FM_INTAKE_NOW_EPOCH:-}" ]; then
  case "$FM_INTAKE_NOW_EPOCH" in
    *[!0-9]*|'') NOW_EPOCH=$(date -u +%s) ;;
    *) NOW_EPOCH=$FM_INTAKE_NOW_EPOCH ;;
  esac
else
  NOW_EPOCH=$(date -u +%s)
fi

command -v jq >/dev/null 2>&1 || { emit_error_once "missing jq"; exit 0; }

write_atomic() { # <src> <dest>
  local src=$1 dest=$2 tmp
  mkdir -p "$(dirname "$dest")" 2>/dev/null || return 1
  tmp="$dest.tmp.$$"
  cp "$src" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

run_gh_source() { # <raw-out> -- <gh-axi args...>
  local raw=$1 err reason
  shift
  err="$TMP/gh.err"
  if "$GH_CMD" "$@" > "$raw" 2> "$err"; then
    return 0
  fi
  reason=$(safe_reason "$err")
  [ -n "$reason" ] || reason="command failed"
  emit_error_once "github failed: $reason"
  return 1
}

parse_gh_axi_tsv() { # <raw> <tsv>
  local raw=$1 out=$2
  awk -v repo="$GH_REPO" '
    function unquote(s) {
      if (s ~ /^".*"$/) {
        sub(/^"/, "", s)
        sub(/"$/, "", s)
        gsub(/""/, "\"", s)
      }
      return s
    }
    function emit(num, title, state, url) {
      if (url == "") url = "https://github.com/" repo "/pull/" num
      gsub(/\t/, " ", title)
      printf "%s\t%s\t%s\t%s\n", num, unquote(title), state, url
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line !~ /^[0-9]+,/) next
      num = line
      sub(/,.*/, "", num)
      rest = line
      sub(/^[0-9]+,/, "", rest)
      pos = 0
      state = ""
      split("open closed merged", states, " ")
      for (i = 1; i <= 3; i++) {
        marker = "," states[i] ","
        p = index(rest, marker)
        if (p > 0 && (pos == 0 || p < pos)) {
          pos = p
          state = states[i]
        }
      }
      if (pos == 0) next
      title = substr(rest, 1, pos - 1)
      tail = substr(rest, pos + length(state) + 2)
      url = ""
      n = split(tail, parts, ",")
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^https?:\/\//) {
          url = parts[i]
          break
        }
      }
      emit(num, title, state, url)
    }
  ' "$raw" > "$out"
}

gh_tsv_to_json() { # <tsv> <lane> <out>
  local tsv=$1 lane=$2 out=$3
  jq -Rn \
    --arg lane "$lane" \
    --arg user "$GH_USER" '
      [inputs
        | split("\t")
        | select(length >= 4)
        | {
            id: ("github:" + $lane + ":" + .[0]),
            source: "github",
            lane: $lane,
            short_id: ("PR#" + .[0]),
            title: (.[1] | gsub("[\r\n\t]+"; " ")),
            url: .[3],
            assignee: $user,
            priority: null,
            priority_rank: null,
            state: .[2],
            sla_class: (if $lane == "review" then "review" else "normal" end)
          }]
    ' "$tsv" > "$out"
}

fetch_github() { # <out>
  local out=$1 authored_raw review_raw authored_tsv review_tsv authored_json review_json
  authored_raw="$TMP/gh-authored.raw"
  review_raw="$TMP/gh-review.raw"
  authored_tsv="$TMP/gh-authored.tsv"
  review_tsv="$TMP/gh-review.tsv"
  authored_json="$TMP/gh-authored.json"
  review_json="$TMP/gh-review.json"

  run_gh_source "$authored_raw" pr list --repo "$GH_REPO" --author "$GH_USER" --state open --limit "$GH_LIMIT" || return 1
  run_gh_source "$review_raw" search prs "review-requested:$GH_USER" --state open --owner "$GH_OWNER" --limit "$GH_LIMIT" || return 1
  parse_gh_axi_tsv "$authored_raw" "$authored_tsv"
  parse_gh_axi_tsv "$review_raw" "$review_tsv"
  gh_tsv_to_json "$authored_tsv" pr "$authored_json"
  gh_tsv_to_json "$review_tsv" review "$review_json"
  jq -s 'add' "$authored_json" "$review_json" > "$out"
}

run_broker_linear() { # <tool> <args-json> <out>
  local tool=$1 args=$2 out=$3 err reason
  err="$TMP/broker-$tool.err"
  if BROKER_HOME="$BROKER_HOME_PATH" "$BROKER_CMD" call linear "$tool" --args "$args" > "$out" 2> "$err"; then
    return 0
  fi
  reason=$(safe_reason "$err")
  [ -n "$reason" ] || reason="command failed"
  emit_error_once "linear failed: $reason"
  return 1
}

verify_oncall_label() {
  local args raw
  args=$(jq -nc --arg id "$LINEAR_ONCALL_EXAMPLE" '{id:$id}')
  raw="$TMP/linear-oncall-example.json"
  run_broker_linear linear_get_issue "$args" "$raw" || return 1
  if jq -e --arg wanted_label "$INTAKE_LINEAR_ONCALL_LABEL" '
    def label_names:
      [ if (.labels? | type) == "array" then .labels[]
        elif (.labels? | type) == "object" and (.labels.nodes? | type) == "array" then .labels.nodes[]
        else empty end
        | if type == "string" then .
          elif type == "object" then (.name? // .label?.name? // empty)
          else empty end
      ];
    ((.issue? // .data.issue? // .) | label_names | index($wanted_label)) != null
  ' "$raw" >/dev/null 2>&1; then
    return 0
  fi
  emit_error_once "linear oncall label mismatch for $LINEAR_ONCALL_EXAMPLE"
  return 1
}

fetch_linear() { # <out>
  local out=$1 raw args
  verify_oncall_label || return 1
  raw="$TMP/linear-search.raw"
  args=$(jq -nc --arg query "$LINEAR_QUERY" '{query:$query}')
  run_broker_linear linear_search_issues "$args" "$raw" || return 1
  jq \
    --arg oncall "$INTAKE_LINEAR_ONCALL_LABEL" \
    --arg assignee "$LINEAR_ASSIGNEE" '
      def issues:
        if (.issues? | type) == "array" then .issues[]
        elif (.data?.issues?.nodes? | type) == "array" then .data.issues.nodes[]
        elif (.nodes? | type) == "array" then .nodes[]
        elif type == "array" then .[]
        else empty end;
      def issue_id:
        (.identifier? // .key? // .number? // .id? // empty) | tostring;
      def state_name:
        (.state.name? // .state? // .status? // "") | tostring;
      def assignee_name:
        (.assignee.email? // .assignee.name? // .assignee.displayName? // .assignee? // $assignee) | tostring;
      def label_names:
        [ if (.labels? | type) == "array" then .labels[]
          elif (.labels? | type) == "object" and (.labels.nodes? | type) == "array" then .labels.nodes[]
          else empty end
          | if type == "string" then .
            elif type == "object" then (.name? // .label?.name? // empty)
            else empty end
        ];
      def priority_value:
        if (.priority? | type) == "object" then
          (.priority.name? // .priority.label? // .priority.value? // .priority)
        else
          (.priorityLabel? // .priorityName? // .priority? // null)
        end;
      def priority_display:
        if priority_value == null then null else (priority_value | tostring) end;
      def priority_rank:
        if (.priority? | type) == "number" then
          (if .priority == 0 then null else .priority end)
        elif (.priority.value? | type) == "number" then
          (if .priority.value == 0 then null else .priority.value end)
        else
          (priority_value // "" | tostring | ascii_downcase) as $p
          | if $p == "" or $p == "null" or $p == "no priority" then null
            elif ($p | test("urgent|blocker|critical|p0|p1")) then 1
            elif ($p | test("high|p2")) then 2
            elif ($p | test("medium|normal|p3")) then 3
            elif ($p | test("low|p4")) then 4
            else null end
        end;
      def linear_url($id):
        (.url? // .webUrl? // .appUrl? // ("https://linear.app/issue/" + $id)) | tostring;
      [ issues
        | . as $issue
        | ($issue | issue_id) as $id
        | select($id != "")
        | ($issue | state_name) as $state
        | select(($state | ascii_downcase) as $s | ["done","canceled","cancelled","duplicate"] | index($s) | not)
        | ($issue | label_names) as $labels
        | ($labels | index($oncall) != null) as $is_oncall
        | {
            id: $id,
            source: "linear",
            lane: (if $is_oncall then "oncall" else "normal" end),
            short_id: $id,
            title: (($issue.title? // $issue.name? // $id) | tostring | gsub("[\r\n\t]+"; " ")),
            url: ($issue | linear_url($id)),
            assignee: ($issue | assignee_name),
            priority: ($issue | priority_display),
            priority_rank: ($issue | priority_rank),
            state: $state,
            sla_class: (if $is_oncall then "oncall" else "normal" end)
          }]
    ' "$raw" > "$out"
}

enrich_source() { # <source> <current-array> <prior-source-json> <out>
  local source=$1 current=$2 prior=$3 out=$4
  [ -f "$prior" ] || printf '{"items":[]}\n' > "$prior"
  jq -n \
    --slurpfile current "$current" \
    --slurpfile prior "$prior" \
    --arg source "$source" \
    --argjson now "$NOW_EPOCH" \
    --arg oncall_warn "$ONCALL_WARN_SECS" \
    --arg oncall_breach "$ONCALL_BREACH_SECS" \
    --arg review_warn "$REVIEW_WARN_SECS" \
    --arg review_breach "$REVIEW_BREACH_SECS" \
    --arg normal_warn "$NORMAL_WARN_SECS" \
    --arg normal_breach "$NORMAL_BREACH_SECS" '
      def old($id): [($prior[0].items // [])[] | select(.id == $id)][0];
      def iso($epoch): ($epoch | strftime("%Y-%m-%dT%H:%M:%SZ"));
      def num_or_null($v): if $v == "" then null else ($v | tonumber) end;
      def warn_secs($class):
        if $class == "oncall" then num_or_null($oncall_warn)
        elif $class == "review" then num_or_null($review_warn)
        elif $class == "normal" then num_or_null($normal_warn)
        else null end;
      def breach_secs($class):
        if $class == "oncall" then num_or_null($oncall_breach)
        elif $class == "review" then num_or_null($review_breach)
        elif $class == "normal" then num_or_null($normal_breach)
        else null end;
      def max_level($a; $b): if ($a // 0) > ($b // 0) then ($a // 0) else ($b // 0) end;
      def with_marker:
        . as $item
        | (old($item.id) // {}) as $old
        | (($old.detected_at_epoch // $now) | tonumber) as $det
        | (warn_secs($item.sla_class)) as $warn
        | (breach_secs($item.sla_class)) as $breach
        | (if $breach != null and $now >= ($det + $breach) then 2
           elif $warn != null and $now >= ($det + $warn) then 1
           else 0 end) as $level
        | $item + {
            detected_at: iso($det),
            detected_at_epoch: $det,
            sla_warn_at: (if $warn == null then null else iso($det + $warn) end),
            sla_breach_at: (if $breach == null then null else iso($det + $breach) end),
            current_sla_level: $level,
            last_notified_sla_level: max_level($old.last_notified_sla_level; $level)
          };
      {
        source: $source,
        generated_at: iso($now),
        items: [($current[0] // [])[] | with_marker]
      }
    ' > "$out"
}

events_for_source() { # <prior-source-json> <new-source-json> <out>
  local prior=$1 new=$2 out=$3
  [ -f "$prior" ] || printf '{"items":[]}\n' > "$prior"
  jq -n \
    --slurpfile prior "$prior" \
    --slurpfile current "$new" '
      def old($id): [($prior[0].items // [])[] | select(.id == $id)][0];
      def rank($v): if ($v | type) == "number" then $v else null end;
      def event_label($item): if $item.source == "github" then ("PR#" + ($item.id | split(":") | last)) else ($item.short_id // $item.id) end;
      [ ($current[0].items // [])[]
        | . as $item
        | (old($item.id)) as $old
        | if $old == null and $item.lane != "pr" then
            {type:"new", id:$item.id, label:event_label($item)}
          else empty end,
          if $old != null
             and (rank($item.priority_rank) != null)
             and (rank($old.priority_rank) != null)
             and (($item.priority_rank | tonumber) < ($old.priority_rank | tonumber)) then
            {type:"priority-raise", id:$item.id, label:event_label($item)}
          else empty end,
          if (($item.current_sla_level // 0) > ($old.last_notified_sla_level // 0)) then
            {type:(if ($item.current_sla_level // 0) >= 2 then "sla-breach" else "sla-warn" end), id:$item.id, label:event_label($item)}
          else empty end
      ]
    ' > "$out"
}

write_snapshot() { # <github-source-json> <linear-source-json> <out>
  local github=$1 linear=$2 out=$3
  jq -s \
    --argjson now "$NOW_EPOCH" '
      def iso($epoch): ($epoch | strftime("%Y-%m-%dT%H:%M:%SZ"));
      {
        generated_at: iso($now),
        items: ([.[].items[]?]
          | sort_by(.lane, .source, .id)
          | map({
              id,
              source,
              lane,
              title,
              url,
              assignee,
              priority,
              state,
              detected_at,
              sla_class,
              sla_warn_at,
              sla_breach_at
            }))
      }
    ' "$github" "$linear" > "$out"
}

write_backlog_lane() { # <snapshot> <lane> <title>
  local snapshot=$1 lane=$2 title=$3
  printf '### %s\n\n' "$title"
  if jq -e --arg lane "$lane" '.items[]? | select(.lane == $lane)' "$snapshot" >/dev/null 2>&1; then
    jq -r --arg lane "$lane" '
      .items[]
      | select(.lane == $lane)
      | "- [" + .id + "](" + .url + ") | " + .title
        + " | " + (.state // "open")
        + (if .priority == null then "" else " | priority " + (.priority | tostring) end)
        + (if .sla_warn_at == null then "" else " | warn " + .sla_warn_at end)
        + (if .sla_breach_at == null then "" else " | breach " + .sla_breach_at end)
    ' "$snapshot"
  else
    printf '_No items._\n'
  fi
  printf '\n'
}

write_backlog() { # <snapshot>
  local snapshot=$1 generated merged
  generated="$TMP/backlog-generated.md"
  merged="$TMP/backlog-merged.md"
  {
    printf '%s\n' "$FM_BACKLOG_PULL_START_MARKER"
    printf '## Generated Open-Work Refresh\n\n'
    jq -r '"Generated: " + .generated_at' "$snapshot"
    printf '\n'
    printf 'Sources: GitHub PRs and Linear assigned tickets.\n\n'
    write_backlog_lane "$snapshot" oncall "On-call Linear tickets"
    write_backlog_lane "$snapshot" normal "Normal Linear tickets"
    write_backlog_lane "$snapshot" review "GitHub review requests"
    write_backlog_lane "$snapshot" pr "Captain-authored PRs"
    printf '%s\n' "$FM_BACKLOG_PULL_END_MARKER"
  } > "$generated"
  fm_backlog_replace_generated_section "$BACKLOG_OUT" "$generated" "$merged" "Firstmate Backlog"
}

format_wake_line() { # <events-json>
  local events=$1
  jq -r '
    if length == 0 then empty
    else
      "intake: " + (
        sort_by(.type)
        | group_by(.type)
        | map({type: .[0].type, labels: map(.label)})
        | map("\(.labels | length) \(.type) (" + ((.labels | unique) | join(", ")) + ")")
        | join(", ")
      )
    end
  ' "$events"
}

mkdir -p "$INTAKE_STATE" 2>/dev/null || { emit_error_once "cannot create intake state"; exit 0; }

empty_source="$TMP/empty-source.json"
printf '{"items":[]}\n' > "$empty_source"

github_current="$TMP/github-current.json"
linear_current="$TMP/linear-current.json"
github_new="$TMP/github-new.json"
linear_new="$TMP/linear-new.json"
github_events="$TMP/github-events.json"
linear_events="$TMP/linear-events.json"
events="$TMP/events.json"
snapshot="$TMP/snapshot.json"

fetch_github "$github_current" || exit 0
fetch_linear "$linear_current" || exit 0

enrich_source github "$github_current" "${INTAKE_STATE}/github.json" "$github_new" || { emit_error_once "cannot prepare github snapshot"; exit 0; }
enrich_source linear "$linear_current" "${INTAKE_STATE}/linear.json" "$linear_new" || { emit_error_once "cannot prepare linear snapshot"; exit 0; }
events_for_source "${INTAKE_STATE}/github.json" "$github_new" "$github_events" || { emit_error_once "cannot diff github snapshot"; exit 0; }
events_for_source "${INTAKE_STATE}/linear.json" "$linear_new" "$linear_events" || { emit_error_once "cannot diff linear snapshot"; exit 0; }
jq -s 'add' "$github_events" "$linear_events" > "$events" || { emit_error_once "cannot merge intake events"; exit 0; }
write_snapshot "$github_new" "$linear_new" "$snapshot" || { emit_error_once "cannot write merged snapshot"; exit 0; }
write_backlog "$snapshot" || { emit_error_once "cannot derive backlog"; exit 0; }

write_atomic "$github_new" "$INTAKE_STATE/github.json" || { emit_error_once "cannot write github snapshot"; exit 0; }
write_atomic "$linear_new" "$INTAKE_STATE/linear.json" || { emit_error_once "cannot write linear snapshot"; exit 0; }
write_atomic "$snapshot" "$INTAKE_STATE/snapshot.json" || { emit_error_once "cannot write intake snapshot"; exit 0; }

clear_error
format_wake_line "$events"
