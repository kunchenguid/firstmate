#!/usr/bin/env bash
# fm-dashboard.sh - the ONLY way an agent touches the Admiral's Fleet Dashboard.
#
# The dashboard is a purpose-built task board, not a mirror of any backlog:
# it owns its own persistent records (bin/fleet-dashboard/server/store.py),
# and every card exists only because something explicitly put it there
# through this CLI (or the equivalent HTTP call). Agents must never edit
# bin/fleet-dashboard/web/ or the database directly - see
# .agents/skills/fleet-dashboard/SKILL.md and docs/dashboard.md.
#
# Every subcommand below is exactly one call, on purpose: a command that
# needs three round-trips to record one update gets skipped by an agent
# under time pressure, and the board rots.
#
# Usage:
#   fm-dashboard.sh add --title <t> --captain <firstmate|dj|river> \
#       (--prompt <text> | --prompt-file <path>) [--agent <name>] \
#       [--status <status>] [--ref <backlog-ref>] [--reason <text>]
#       --reason is REQUIRED when --status is needs-attention (same rule and
#       same server-side guard as the `status` subcommand below), and is
#       REFUSED for every other starting status. Only `waiting` and
#       `needs-attention` store a reason on the card at all; for `waiting`
#       the `status` subcommand owns it, and for the rest a reason is not
#       stored anywhere `show` will render it.
#   fm-dashboard.sh list [--status <status>] [--captain <c>] [--starred] \
#       [--sort updated|date|status|title] [--json]
#   fm-dashboard.sh show <id> [--json]
#   fm-dashboard.sh title <id> <new title>
#   fm-dashboard.sh agent <id> <agent name>
#   fm-dashboard.sh captain <id> <firstmate|dj|river>
#   fm-dashboard.sh ref <id> <backlog-ref>
#   fm-dashboard.sh status <id> <status> [--waiting-on <id>] [--reason <text>]
#       --reason is what the card is waiting on for `waiting`, or what is
#       being asked of him for `needs-attention`; ignored for other statuses.
#       needs-attention REQUIRES --reason: the server refuses the status
#       change with no reason, and refuses a reason it can mechanically
#       tell is only a progress report rather than an ask (see
#       bin/fleet-dashboard/server/validation.py's REPORT_SHAPED_PHRASES).
#   fm-dashboard.sh star <id>
#   fm-dashboard.sh unstar <id>
#   fm-dashboard.sh note <id> --tab <interpretation|communication|needs> \
#       [--text <text>] [--link <url>] [--link-label <text>] [--author <a>]
#   fm-dashboard.sh link <id> --url <url> [--label <text>] [--tab <tab>]
#   fm-dashboard.sh delete <id> --confirm
#   fm-dashboard.sh audit-log (<id> | --fleet) <text> [--kind discrepancy|error]
#   fm-dashboard.sh audit-run --duration-seconds <n> --checked <n> \
#       [--discrepancies <n>] [--forced] [--started-at <iso>]
#   fm-dashboard.sh audit-interval [get | <minutes>]
#   fm-dashboard.sh audit-status [--json]
#   fm-dashboard.sh audit-tick
#   fm-dashboard.sh audit-claim [--forced] [--json]
#   fm-dashboard.sh audit-release
#   fm-dashboard.sh start|stop|restart|server-status   (server process lifecycle)
#   fm-dashboard.sh --help
#
# The audit-tick/audit-claim/audit-release/audit-status quartet is the fleet
# auditor's own timer plumbing (bin/fm-fleet-audit-tick.sh and
# bin/fm-fleet-audit-sweep.sh are the actual timer and sweep executor); an
# agent doing ordinary dashboard work never needs them directly.
#
# statuses: needs-attention not-started working paused waiting testing complete
# tabs:     interpretation communication needs
# captain shorthands: dj -> captain_dj, river -> captain_river, firstmate -> firstmate
#
# Server URL resolution: $FM_DASHBOARD_URL env var, else the first line of
# $FM_HOME/config/dashboard-url, else http://127.0.0.1:8420. A secondmate on
# a different host points config/dashboard-url at the primary's tailnet
# address (see docs/dashboard.md "Reaching the board from a secondmate").
#
# Every call is bounded: --connect-timeout 5s and --max-time 20s, overridable
# with $FM_DASHBOARD_CONNECT_TIMEOUT / $FM_DASHBOARD_MAX_TIME (positive
# seconds; anything else is ignored loudly and the default used).
# Exit codes: 0 success, 4 the board answered and said the id does not exist,
# 1 anything else (unreachable board, refused write, bad usage).
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DASHBOARD_DIR="$FM_ROOT/bin/fleet-dashboard"

# Precedence: FM_DASHBOARD_URL (full override) > FM_DASHBOARD_HOST/_PORT (the
# same pair `start` launches the server with) > config/dashboard-url > default.
dash_url() {
  if [ -n "${FM_DASHBOARD_URL:-}" ]; then
    printf '%s\n' "$FM_DASHBOARD_URL"
    return 0
  fi
  if [ -n "${FM_DASHBOARD_HOST:-}${FM_DASHBOARD_PORT:-}" ]; then
    printf 'http://%s:%s\n' "${FM_DASHBOARD_HOST:-127.0.0.1}" "${FM_DASHBOARD_PORT:-8420}"
    return 0
  fi
  if [ -f "$CONFIG/dashboard-url" ]; then
    head -n1 "$CONFIG/dashboard-url"
    return 0
  fi
  printf '%s\n' "http://127.0.0.1:8420"
}

die() { printf 'fm-dashboard.sh: %s\n' "$1" >&2; exit 1; }

need_tool() { command -v "$1" >/dev/null 2>&1 || die "requires '$1' on PATH"; }

# Exit code reserved for "the board answered, and says this id does not
# exist". Callers that must tell a definitive board rejection from a board
# they simply could not reach - bin/fm-backlog-handoff.sh's pending card
# record, which retries the second forever and must never retry the first -
# key off this instead of parsing the stderr message.
DASH_EXIT_NOT_FOUND=4

# Bound every call. The board is typically a tailnet host that can simply be
# powered off, dropping packets rather than refusing them, and these calls run
# inside held handoff locks (bin/fm-backlog-handoff.sh) and on
# bin/fm-bootstrap.sh's synchronous path, where an unbounded wait stalls the
# whole fleet rather than one card. A non-numeric override is ignored loudly
# rather than passed to curl, which would reject it and turn a bad env var
# into "the board is unreachable". A non-positive one is ignored just as
# loudly for the opposite reason: curl accepts --max-time 0 and
# --connect-timeout 0 and reads them as no timeout at all, so honouring a zero
# would silently restore exactly the unbounded wait these bounds exist to
# remove. Zero is spelled as "no [1-9] anywhere in an otherwise valid decimal",
# which catches 0, 0.0 and .0 alike; a negative value carries a '-' and is
# already non-numeric here.
dash_timeout_seconds() { # <env-name> <raw-value> <default>
  local name=$1 raw=$2 default=$3
  case "$raw" in
    '') printf '%s' "$default"; return 0 ;;
    .|*.*.*|*[!0-9.]*) : ;;
    *[1-9]*) printf '%s' "$raw"; return 0 ;;
  esac
  printf 'fm-dashboard.sh: ignoring invalid %s=%s (want positive seconds); using %s\n' "$name" "$raw" "$default" >&2
  printf '%s' "$default"
}

# dash_call METHOD PATH [JSON_BODY] - prints response body on stdout,
# prints an error message on stderr and returns non-zero on failure
# ($DASH_EXIT_NOT_FOUND for a 404, 1 otherwise). Never exits the process
# directly: a caller (cmd_server_status in particular) needs to catch
# "server unreachable" instead of the whole script dying.
dash_call() {
  local method=$1 path=$2 body=${3:-} base resp code out
  local -a bounds
  need_tool curl
  need_tool jq
  base=$(dash_url)
  bounds=(
    --connect-timeout "$(dash_timeout_seconds FM_DASHBOARD_CONNECT_TIMEOUT "${FM_DASHBOARD_CONNECT_TIMEOUT:-}" 5)"
    --max-time "$(dash_timeout_seconds FM_DASHBOARD_MAX_TIME "${FM_DASHBOARD_MAX_TIME:-}" 20)"
  )
  if [ -n "$body" ]; then
    resp=$(curl -sS "${bounds[@]}" -w '\n%{http_code}' -X "$method" "$base$path" \
      -H 'Content-Type: application/json' -d "$body" 2>&1) || {
      printf 'fm-dashboard.sh: could not reach dashboard at %s (is it running? see: fm-dashboard.sh start / server-status): %s\n' "$base" "$resp" >&2
      return 1
    }
  else
    resp=$(curl -sS "${bounds[@]}" -w '\n%{http_code}' -X "$method" "$base$path" 2>&1) || {
      printf 'fm-dashboard.sh: could not reach dashboard at %s (is it running? see: fm-dashboard.sh start / server-status): %s\n' "$base" "$resp" >&2
      return 1
    }
  fi
  code=$(printf '%s' "$resp" | tail -n1)
  out=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" -ge 400 ] 2>/dev/null; then
    printf 'fm-dashboard.sh: server refused (%s): %s\n' "$code" "$(printf '%s' "$out" | jq -r '.error // .' 2>/dev/null || printf '%s' "$out")" >&2
    [ "$code" != 404 ] || return "$DASH_EXIT_NOT_FOUND"
    return 1
  fi
  printf '%s' "$out"
}

json_escape() { need_tool jq; jq -Rs . <<<"$1"; }

canon_status() {
  case "$1" in
    not-started|not_started) printf 'not_started' ;;
    needs-attention|needs_attention) printf 'needs_attention' ;;
    working|paused|waiting|testing|complete) printf '%s' "$1" ;;
    *) die "unknown status '$1' - valid: needs-attention not-started working paused waiting testing complete" ;;
  esac
}

canon_captain() {
  case "$1" in
    dj|captain_dj) printf 'captain_dj' ;;
    river|captain_river) printf 'captain_river' ;;
    firstmate) printf 'firstmate' ;;
    *) die "unknown captain '$1' - valid: firstmate dj river" ;;
  esac
}

row_line() {
  # one-line confirmation row from a task JSON object on stdin
  jq -r '[.id, .status, .captain, (if .starred==1 then "*" else "-" end), .title] | @tsv'
}

cmd_add() {
  local title="" captain="" prompt="" prompt_file="" agent="" status="not_started" ref="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=$2; shift 2 ;;
      --captain) captain=$(canon_captain "$2") || return 1; shift 2 ;;
      --prompt) prompt=$2; shift 2 ;;
      --prompt-file) prompt_file=$2; shift 2 ;;
      --agent) agent=$2; shift 2 ;;
      --status) status=$(canon_status "$2") || return 1; shift 2 ;;
      --ref) ref=$2; shift 2 ;;
      --reason) reason=$2; shift 2 ;;
      *) die "add: unknown argument '$1'" ;;
    esac
  done
  [ -n "$title" ] || die "add: --title is required"
  [ -n "$captain" ] || die "add: --captain is required (firstmate|dj|river)"
  if [ -n "$prompt_file" ]; then
    [ -f "$prompt_file" ] || die "add: --prompt-file '$prompt_file' not found"
    prompt=$(cat "$prompt_file")
  fi
  [ -n "$prompt" ] || die "add: --prompt or --prompt-file is required - his own words, verbatim"
  # See cmd_status's matching check: the server enforces this too, but fail
  # here rather than spend a round-trip on the obvious case.
  if [ "$status" = needs_attention ] && [ -z "$reason" ]; then
    die "add: --status needs-attention requires --reason - say what he needs to decide, approve, or supply"
  fi
  # needs_attention is the only status whose reason `add` can write. Refuse
  # rather than send a value the server will drop on the floor - and only
  # point at the `status` subcommand for a status that actually persists a
  # reason there, since for the rest that command drops it just as quietly.
  if [ "$status" != needs_attention ] && [ -n "$reason" ]; then
    local why
    case "$status" in
      needs_attention|waiting)
        why="use 'fm-dashboard.sh status <id> $status --reason ...' instead" ;;
      *)
        why="a reason is not stored for '$status' - drop --reason or use --status needs-attention" ;;
    esac
    die "add: --reason is only accepted with --status needs-attention (got status '$status'); $why"
  fi
  local body
  body=$(jq -n --arg t "$title" --arg c "$captain" --arg p "$prompt" --arg a "$agent" \
              --arg s "$status" --arg r "$ref" --arg rs "$reason" \
    '{title:$t, captain:$c, initial_prompt:$p, agent:$a, status:$s}
     + (if $r=="" then {} else {backlog_ref:$r} end)
     + (if $rs=="" then {} else {reason:$rs} end)')
  dash_call POST /api/tasks "$body" | row_line
}

cmd_list() {
  local status="" captain="" starred="" sort="updated" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status=$(canon_status "$2") || return 1; shift 2 ;;
      --captain) captain=$(canon_captain "$2") || return 1; shift 2 ;;
      --starred) starred=1; shift ;;
      --sort) sort=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      *) die "list: unknown argument '$1'" ;;
    esac
  done
  local qs="?sort=$sort"
  [ -n "$status" ] && qs="$qs&status=$status"
  [ -n "$captain" ] && qs="$qs&captain=$captain"
  [ -n "$starred" ] && qs="$qs&starred=true"
  local out
  out=$(dash_call GET "/api/tasks$qs") || return 1
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r '.tasks[] | [.id, .status, .captain, (if .starred==1 then "*" else "-" end), .title] | @tsv'
  fi
}

cmd_show() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "show: task id required"
  local as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) as_json=1; shift ;; *) die "show: unknown argument '$1'" ;; esac
  done
  local out
  out=$(dash_call GET "/api/tasks/$id") || return $?
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out" | jq -r '
    "id:       \(.id)",
    "title:    \(.title)",
    "status:   \(.status)",
    "captain:  \(.captain)",
    "agent:    \(.agent)",
    "starred:  \(.starred == 1)",
    (if .status == "waiting" then "waiting on: \(.waiting_on_id // "(no card)") - \(.waiting_reason // "")" else empty end),
    (if .status == "needs_attention" then "needs attention: \(.needs_attention_reason // "(no reason recorded)")" else empty end),
    (if .backlog_ref then "ref:      \(.backlog_ref)" else empty end),
    "",
    "--- prompt ---",
    .initial_prompt,
    "",
    (if ([.notes[] | select(.tab=="interpretation")] | length) > 0
      then "--- interpretation ---", (.notes[] | select(.tab=="interpretation") | "[\(.author) \(.created_at)] \(.text)\(if .link_url then " -> " + .link_url else "" end)")
      else empty end),
    (if ([.notes[] | select(.tab=="communication")] | length) > 0
      then "--- communication ---", (.notes[] | select(.tab=="communication") | "[\(.author) \(.created_at)] \(.text)\(if .link_url then " -> " + .link_url else "" end)")
      else empty end),
    (if ([.notes[] | select(.tab=="needs")] | length) > 0
      then "--- needs ---", (.notes[] | select(.tab=="needs") | "[\(.author) \(.created_at)] \(.text)\(if .link_url then " -> " + .link_url else "" end)")
      else empty end)
  '
}

cmd_title() {
  local id=${1:-} title=${2:-}
  [ -n "$id" ] && [ -n "$title" ] || die "title: usage: title <id> <new title>"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg t "$title" '{title:$t}')" | row_line
}

cmd_agent() {
  local id=${1:-} agent=${2:-}
  [ -n "$id" ] || die "agent: usage: agent <id> <agent name>"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg a "${agent:-}" '{agent:$a}')" | row_line
}

cmd_captain() {
  local id=${1:-} captain=${2:-}
  [ -n "$id" ] && [ -n "$captain" ] || die "captain: usage: captain <id> <firstmate|dj|river>"
  captain=$(canon_captain "$captain") || return 1
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg c "$captain" '{captain:$c}')" | row_line
}

cmd_ref() {
  local id=${1:-} ref=${2:-}
  [ -n "$id" ] && [ -n "$ref" ] || die "ref: usage: ref <id> <backlog-ref>"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --arg r "$ref" '{backlog_ref:$r}')" | row_line
}

cmd_status() {
  local id=${1:-}; shift || true
  local status=${1:-}; shift || true
  [ -n "$id" ] && [ -n "$status" ] || die "status: usage: status <id> <status> [--waiting-on <id>] [--reason <text>]"
  status=$(canon_status "$status") || return 1
  local waiting_on="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --waiting-on) waiting_on=$2; shift 2 ;;
      --reason) reason=$2; shift 2 ;;
      *) die "status: unknown argument '$1'" ;;
    esac
  done
  # needs_attention is the loudest status on the board and claims him; the
  # server also enforces this (and further refuses a report-shaped reason),
  # but fail here too rather than spend a round-trip on the obvious case.
  if [ "$status" = needs_attention ] && [ -z "$reason" ]; then
    die "status: needs-attention requires --reason - say what he needs to decide, approve, or supply"
  fi
  local body
  body=$(jq -n --arg s "$status" --arg w "$waiting_on" --arg r "$reason" \
    '{status:$s} + (if $w=="" then {} else {waiting_on_id:$w} end) + (if $r=="" then {} else {reason:$r} end)')
  dash_call POST "/api/tasks/$id/status" "$body" | row_line
}

cmd_star_toggle() {
  local on=$1 id=${2:-}
  [ -n "$id" ] || die "star: task id required"
  dash_call PATCH "/api/tasks/$id" "$(jq -n --argjson s "$on" '{starred:$s}')" | row_line
}

cmd_note() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "note: usage: note <id> --tab <tab> [--text <text>] [--link <url>] [--link-label <text>] [--author <a>]"
  local tab="" text="" link="" link_label="" author="agent"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tab) tab=$2; shift 2 ;;
      --text) text=$2; shift 2 ;;
      --link) link=$2; shift 2 ;;
      --link-label) link_label=$2; shift 2 ;;
      --author) author=$2; shift 2 ;;
      *) die "note: unknown argument '$1'" ;;
    esac
  done
  [ -n "$tab" ] || die "note: --tab is required (interpretation|communication|needs)"
  local body
  body=$(jq -n --arg tab "$tab" --arg author "$author" --arg text "$text" \
              --arg link "$link" --arg label "$link_label" \
    '{tab:$tab, author:$author, text:$text} + (if $link=="" then {} else {link_url:$link, link_label:$label} end)')
  dash_call POST "/api/tasks/$id/notes" "$body" >/dev/null && printf '%s: note added to %s\n' "$id" "$tab"
}

cmd_link() {
  local id=${1:-}; shift || true
  [ -n "$id" ] || die "link: usage: link <id> --url <url> [--label <text>] [--tab <tab>]"
  local url="" label="" tab="needs"
  while [ $# -gt 0 ]; do
    case "$1" in
      --url) url=$2; shift 2 ;;
      --label) label=$2; shift 2 ;;
      --tab) tab=$2; shift 2 ;;
      *) die "link: unknown argument '$1'" ;;
    esac
  done
  [ -n "$url" ] || die "link: --url is required"
  cmd_note "$id" --tab "$tab" --text "" --link "$url" --link-label "$label"
}

cmd_delete() {
  local id=${1:-} confirm=${2:-}
  [ -n "$id" ] || die "delete: task id required"
  [ "$confirm" = "--confirm" ] || die "delete: pass --confirm to actually delete '$id'"
  dash_call DELETE "/api/tasks/$id" >/dev/null && printf 'deleted: %s\n' "$id"
}

cmd_audit_log() {
  local target=${1:-}; shift || true
  [ -n "$target" ] || die "audit-log: usage: audit-log (<id> | --fleet) <text> [--kind discrepancy|error]"
  local text=${1:-}; shift || true
  [ -n "$text" ] || die "audit-log: text is required"
  local kind="discrepancy"
  while [ $# -gt 0 ]; do
    case "$1" in --kind) kind=$2; shift 2 ;; *) die "audit-log: unknown argument '$1'" ;; esac
  done
  local body
  if [ "$target" = "--fleet" ]; then
    body=$(jq -n --arg k "$kind" --arg t "$text" '{kind:$k, text:$t}')
  else
    body=$(jq -n --arg k "$kind" --arg t "$text" --arg id "$target" '{kind:$k, text:$t, task_id:$id}')
  fi
  dash_call POST /api/audit/log "$body" >/dev/null && printf 'audit finding recorded (%s)\n' "$kind"
}

cmd_audit_run() {
  local duration="" checked="" discrepancies="0" forced="false" started_at=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --duration-seconds) duration=$2; shift 2 ;;
      --checked) checked=$2; shift 2 ;;
      --discrepancies) discrepancies=$2; shift 2 ;;
      --forced) forced="true"; shift ;;
      --started-at) started_at=$2; shift 2 ;;
      *) die "audit-run: unknown argument '$1'" ;;
    esac
  done
  [ -n "$duration" ] && [ -n "$checked" ] || die "audit-run: --duration-seconds and --checked are required"
  local body
  body=$(jq -n --argjson d "$duration" --argjson c "$checked" --argjson x "$discrepancies" \
              --argjson f "$forced" --arg s "$started_at" \
    '{duration_seconds:$d, tasks_checked:$c, discrepancies_found:$x, forced:$f} + (if $s=="" then {} else {started_at:$s} end)')
  dash_call POST /api/audit/run "$body" >/dev/null \
    && printf 'audit run recorded: %ss, %s task(s), %s discrepancy(ies)%s\n' \
         "$duration" "$checked" "$discrepancies" "$([ "$forced" = "true" ] && printf ' (forced)' || true)"
}

cmd_audit_interval() {
  local arg=${1:-get}
  if [ "$arg" = "get" ]; then
    dash_call GET /api/settings/audit-interval | jq -r '"every \(.minutes) minute(s)"'
  else
    case "$arg" in ''|*[!0-9]*) die "audit-interval: minutes must be a positive integer" ;; esac
    dash_call PUT /api/settings/audit-interval "$(jq -n --argjson m "$arg" '{minutes:$m}')" \
      | jq -r '"every \(.minutes) minute(s)"'
  fi
}

cmd_audit_status() {
  local as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in --json) as_json=1; shift ;; *) die "audit-status: unknown argument '$1'" ;; esac
  done
  local out
  out=$(dash_call GET /api/audit/status) || return 1
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  printf '%s\n' "$out" | jq -r '
    "interval_minutes: \(.interval_minutes)",
    "last_tick_at:     \(.last_tick_at // "never")",
    "sweep running:    \(.sweep_lock.running)\(if .sweep_lock.running then " (forced: \(.sweep_lock.forced), since \(.sweep_lock.started_at))" else "" end)",
    (if .last_run then
      "last_run:         \(.last_run.completed_at) - \(.last_run.duration_seconds)s, \(.last_run.tasks_checked) checked, \(.last_run.discrepancies_found) discrepancy(ies)\(if .last_run.forced==1 then " (forced)" else "" end)"
    else
      "last_run:         never"
    end)
  '
}

cmd_audit_tick() {
  dash_call POST /api/audit/tick >/dev/null && printf 'tick recorded\n'
}

cmd_audit_claim() {
  local forced="false" as_json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --forced) forced="true"; shift ;;
      --json) as_json=1; shift ;;
      *) die "audit-claim: unknown argument '$1'" ;;
    esac
  done
  local out
  out=$(dash_call POST /api/audit/claim "$(jq -n --argjson f "$forced" '{forced:$f}')") || return 1
  if [ "$as_json" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | jq -r 'if .claimed then "claimed: true started_at: \(.started_at)" else "claimed: false running_since: \(.running_since) forced: \(.forced)" end'
  fi
  printf '%s' "$out" | jq -e '.claimed' >/dev/null
}

cmd_audit_release() {
  dash_call POST /api/audit/release >/dev/null && printf 'sweep lock released\n'
}

pidfile() { printf '%s/state/dashboard.pid' "$FM_HOME"; }

cmd_server_start() {
  local pf; pf=$(pidfile)
  if [ -f "$pf" ] && kill -0 "$(cat "$pf")" 2>/dev/null; then
    die "already running (pid $(cat "$pf")) - see: fm-dashboard.sh server-status"
  fi
  local host="${FM_DASHBOARD_HOST:-127.0.0.1}" port="${FM_DASHBOARD_PORT:-8420}"
  local db="${FM_DASHBOARD_DB:-$FM_HOME/data/dashboard.db}"
  mkdir -p "$(dirname "$pf")"
  nohup python3 "$DASHBOARD_DIR/server/main.py" --host "$host" --port "$port" --db "$db" \
    > "$FM_HOME/state/dashboard.log" 2>&1 &
  echo $! > "$pf"
  sleep 1
  if kill -0 "$(cat "$pf")" 2>/dev/null; then
    printf 'fleet dashboard started (pid %s) - http://%s:%s/  log: %s/state/dashboard.log\n' \
      "$(cat "$pf")" "$host" "$port" "$FM_HOME"
  else
    rm -f "$pf"
    die "failed to start - see $FM_HOME/state/dashboard.log"
  fi
}

cmd_server_stop() {
  local pf; pf=$(pidfile)
  [ -f "$pf" ] || die "no pidfile - not started via this script (see: fm-dashboard.sh server-status)"
  local pid; pid=$(cat "$pf")
  kill -0 "$pid" 2>/dev/null || { rm -f "$pf"; die "recorded pid $pid is not running"; }
  kill "$pid"
  rm -f "$pf"
  printf 'stopped (pid %s)\n' "$pid"
}

cmd_server_status() {
  local pf; pf=$(pidfile)
  if [ -f "$pf" ] && kill -0 "$(cat "$pf")" 2>/dev/null; then
    printf 'process: running (pid %s)\n' "$(cat "$pf")"
  else
    printf 'process: not running (no active pid recorded by this script)\n'
  fi
  if dash_call GET /api/health >/dev/null 2>&1; then
    printf 'api:     reachable at %s\n' "$(dash_url)"
  else
    printf 'api:     UNREACHABLE at %s\n' "$(dash_url)"
  fi
}

main() {
  local cmd=${1:-}
  [ -n "$cmd" ] && shift || true
  case "$cmd" in
    add) cmd_add "$@" ;;
    list) cmd_list "$@" ;;
    show) cmd_show "$@" ;;
    title) cmd_title "$@" ;;
    agent) cmd_agent "$@" ;;
    captain) cmd_captain "$@" ;;
    ref) cmd_ref "$@" ;;
    status) cmd_status "$@" ;;
    star) cmd_star_toggle true "$@" ;;
    unstar) cmd_star_toggle false "$@" ;;
    note) cmd_note "$@" ;;
    link) cmd_link "$@" ;;
    delete) cmd_delete "$@" ;;
    audit-log) cmd_audit_log "$@" ;;
    audit-run) cmd_audit_run "$@" ;;
    audit-interval) cmd_audit_interval "$@" ;;
    audit-status) cmd_audit_status "$@" ;;
    audit-tick) cmd_audit_tick "$@" ;;
    audit-claim) cmd_audit_claim "$@" ;;
    audit-release) cmd_audit_release "$@" ;;
    start) cmd_server_start ;;
    stop) cmd_server_stop ;;
    restart) cmd_server_stop 2>/dev/null; cmd_server_start ;;
    server-status) cmd_server_status ;;
    # Help is the header comment block itself: everything from line 2 (past the
    # shebang) up to the first non-comment line. Derived, not a fixed range, so
    # editing the header can never silently truncate --help.
    ""|--help|-h|help)
      awk 'NR == 1 { next } !/^#/ { exit } { print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$cmd' - run: fm-dashboard.sh --help" ;;
  esac
}

main "$@"
