#!/usr/bin/env bash
# fm-primary-resource.sh - automatic resource protection for the MAIN Firstmate
# session only. Owns observe/arm/check/commit/helper and the
# private state schema under state/primary-resource/.
#
# Usage:
#   fm-primary-resource.sh observe [--payload-file <path> | --payload <json>]
#   fm-primary-resource.sh arm
#   fm-primary-resource.sh check
#   fm-primary-resource.sh commit <incident-id> --stow-receipt <path>
#   fm-primary-resource.sh helper <incident-id>
#   fm-primary-resource.sh --help
#
# Thresholds (inclusive, fixed policy):
#   context: 175000 input-context tokens (Claude usage sum or Codex input_tokens)
#   quota:   97 percent used (100 - percentRemaining) on a session or weekly
#            window of the primary's provider
# When both triggers apply, quota wins. Only Claude and Codex have verified
# reliable context adapters; every other adapter is alert-only and never closes
# the session. One automatic action per incident:
# a receipt created no-clobber before any terminal action; check never
# re-proposes an incident that already has a receipt; commit refuses one; failed
# receipts are never deleted.
#
# Private state schema (version: 1) under state/primary-resource/:
#   binding.json
#     {version, harness, pid, sessionId, transcriptPath, boundAt}
#   alerts/<generation>--<condition>
#     presence file; one alert per (session generation, condition)
#   proposals/<incidentId>.json
#     decision JSON retained so a check killed between report and queue delivery
#     cannot lose the action
#   receipts/<incidentId>.json  (immutable once created; no-clobber hard link)
#     {version, incidentId, action, sourceHarness, sourceProvider,
#      destinationHarness, destinationProvider, stowReceiptPath, reservedAt,
#      helperEndpoint}
#   outcomes/<incidentId>.json
#     {version, incidentId, stage: waiting-idle|exiting|launching|started|failed,
#      reason, updatedAt}
#   launch/<incidentId>.argv  private NUL-delimited argv; deleted after attempt
#   helper-ready/<incidentId> helper acknowledgement marker
#   .lock                     directory lock via fm_lock_*
#
# Data shapes named before logic (canonical JSON values):
#   binding        {harness, pid, sessionId, transcriptPath, boundAt}
#   context        {tokens|null, reliability: reliable|unknown, reason}
#   quota verdict  {provider, exhausted:[{id,kind,resetsAt,percentUsed}],
#                   reliability}
#   decision       {action: none|alert|context|quota, incidentId, reason,
#                   replacement}
#   receipt        fields above; outcome stage is a separate file
#
# Main home only: observe/arm/check are no-ops in a secondmate home and in task
# worktrees. Terminal handover is tmux-only. Herdr is alert-only until a guarded
# live lab proves the full exit->shell->successor transaction. Other backends
# alert. Requires python3 (preflighted at arm). The helper never uses shell `&`;
# it runs in a backend-owned terminal the way bin/fm-afk-launch.sh does, waits
# bounded for the primary pane to go idle, proves the pane occupant still matches
# the bound source pid/harness before sending exit once via
# fm_control_exit_command + fm_backend_send_text_submit, and launches only after
# the old pid is gone and the pane process predicate is shell-only.
#
# Residual limit: a successor that reaches a login/auth prompt still classifies
# as a live agent; only the check-side reconciliation alert (started with no new
# binding within the bound) surfaces that stalled handover. Never auto-retry.
#
# Stow attestation (exactly one shape; commit rejects all others):
#   FM_PRIMARY_RESOURCE_STOW_V1
#   verdict=reset-safe
#   incidentId=<this-incident>
#   generation=<binding.sessionId>
# Rejects symlinks, negative/contradictory/malformed content, and any file not
# bound to this incident and current generation.
#
# Quota episodes: each exhausted window is claimed independently under
# claims/<windowIncidentId>; an active episodes/<provider> file retains coverage
# until a reliable below-threshold reading clears it, so a later window crossing
# 97% does not mint a second terminal attempt. Missing/ambiguous resetsAt is
# alert-only and never reliable.
#
# Test seams:
#   FM_PRIMARY_RESOURCE_QUOTA_JSON / _FILE  inject quota-axi JSON
#   FM_PRIMARY_RESOURCE_NOW                fixed epoch seconds
#   FM_PRIMARY_RESOURCE_HELPER_WAIT_SECS   bound helper idle waits (default 30)
#   FM_PRIMARY_RESOURCE_RECONCILE_SECS     stranded-helper alert bound (default 120)
#   FM_PRIMARY_RESOURCE_BUSY_STATE_FILE    override busy|idle|unknown for helper
#   FM_PRIMARY_RESOURCE_ROUTE_ENV_FILE     inject NUL-delimited environ for route checks
#   FM_PRIMARY_RESOURCE_ARGV_FILE         inject NUL-delimited argv for commit capture (tests)

set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PR_DIR="$STATE/primary-resource"
CHECK_ID="primary-resource"
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
CONTEXT_THRESHOLD=175000
QUOTA_THRESHOLD=97
SCHEMA_VERSION=1
MAX_LINE=240
QUOTA_BUDGET_SECS=${FM_PRIMARY_RESOURCE_QUOTA_BUDGET_SECS:-20}
case "$QUOTA_BUDGET_SECS" in
  ''|*[!0-9]*) QUOTA_BUDGET_SECS=20 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-primary-resource.sh observe [--payload-file PATH | --payload JSON]
  fm-primary-resource.sh arm
  fm-primary-resource.sh check
  fm-primary-resource.sh commit INCIDENT --stow-receipt PATH
  fm-primary-resource.sh helper INCIDENT
  fm-primary-resource.sh --help

Main Firstmate session only. See the script header for the private state schema
under state/primary-resource/, thresholds, and helper lifecycle.
EOF
}

die_usage() {
  printf 'fm-primary-resource: %s\n' "$1" >&2
  usage >&2
  exit 2
}

pr_now() {
  case "${FM_PRIMARY_RESOURCE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PRIMARY_RESOURCE_NOW" ;;
  esac
}

pr_lock_pid() {
  # state/.lock holds a bare harness pid (fm-lock.sh), not pid=KEY=value.
  local raw
  raw=$(cat "$STATE/.lock" 2>/dev/null || true)
  raw=${raw%%$'\n'*}
  case "$raw" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$raw"
}

pr_primary_busy_state() {  # <backend> <target> <harness> -> busy|idle|unknown
  local backend=$1 target=$2 harness=$3 b
  if [ -n "${FM_PRIMARY_RESOURCE_BUSY_STATE_FILE:-}" ] && [ -f "$FM_PRIMARY_RESOURCE_BUSY_STATE_FILE" ]; then
    tr -d '\n' < "$FM_PRIMARY_RESOURCE_BUSY_STATE_FILE"
    printf '\n'
    return 0
  fi
  b=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || printf 'unknown')
  case "$b" in
    busy|idle) printf '%s\n' "$b"; return 0 ;;
  esac
  case "$backend" in
    tmux)
      fm_pane_busy_state "$target" "$harness"
      ;;
    *) printf 'unknown\n' ;;
  esac
}


pr_ensure_dir() {
  mkdir -p "$PR_DIR" "$PR_DIR/alerts" "$PR_DIR/proposals" "$PR_DIR/receipts" \
    "$PR_DIR/outcomes" "$PR_DIR/launch" "$PR_DIR/helper-ready" \
    "$PR_DIR/claims" "$PR_DIR/episodes" 2>/dev/null || return 1
  chmod 0700 "$PR_DIR" 2>/dev/null || true
}

RECONCILE_SECS=${FM_PRIMARY_RESOURCE_RECONCILE_SECS:-120}
case "$RECONCILE_SECS" in
  ''|*[!0-9]*) RECONCILE_SECS=120 ;;
esac

pr_require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'fm-primary-resource: python3 required for argv admission (install python3)\n' >&2
    return 1
  fi
  if ! python3 -c 'import sys' >/dev/null 2>&1; then
    printf 'fm-primary-resource: python3 required for argv admission (install python3)\n' >&2
    return 1
  fi
  return 0
}

pr_lock_acquire() {
  pr_ensure_dir || return 1
  fm_lock_acquire_wait_bounded "$PR_DIR/.lock" "${FM_PRIMARY_RESOURCE_LOCK_SECS:-10}"
}

pr_lock_release() {
  fm_lock_release "$PR_DIR/.lock" 2>/dev/null || true
}

pr_is_main_home() {
  if fm_root_is_secondmate_home "$FM_HOME"; then
    return 1
  fi
  local git_dir git_common_dir
  git_dir=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || return 1
  git_common_dir=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$git_common_dir" ] || return 1
  [ -f "$FM_ROOT/AGENTS.md" ] || return 1
  [ -d "$FM_ROOT/bin" ] || return 1
  [ -d "$STATE" ] || return 1
}

pr_hash() {
  # Portable sha256 of stdin -> hex
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}

pr_incident_context() {  # <sessionId>
  printf 'context\0%s\0%s' "$FM_HOME" "$1" | pr_hash
}

# One incident id per exhausted window (provider + window id + exact resetsAt).
pr_incident_quota_window() {  # <provider> <window-id> <resetsAt>
  local provider=$1 wid=$2 resets=$3
  printf 'quota\0%s\0%s\0%s\0%s' "$FM_HOME" "$provider" "$wid" "$resets" | pr_hash
}

# Primary quota incident for a set of reliable exhausted windows: first sorted
# window id, used as the proposal/receipt key; all windows are claimed as aliases.
pr_incident_quota_primary() {  # <provider> <exhausted-json-array>
  local provider=$1 exhausted=$2 first
  first=$(printf '%s' "$exhausted" | jq -r '
    map(select((.resetsAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")))
    | sort_by(.id) | .[0] // empty
    | if . == null or . == "" then empty else "\(.id)\t\(.resetsAt)" end
  ' 2>/dev/null) || first=
  [ -n "$first" ] || return 1
  pr_incident_quota_window "$provider" "${first%%$'\t'*}" "${first#*$'\t'}"
}

pr_episode_path() {  # <provider>
  printf '%s/episodes/%s' "$PR_DIR" "${1//\//_}"
}

pr_episode_active() {  # <provider>
  [ -f "$(pr_episode_path "$1")" ]
}

pr_episode_open() {  # <provider> <primaryIncidentId>
  local provider=$1 id=$2 path
  path=$(pr_episode_path "$provider")
  pr_ensure_dir || return 1
  printf 'incidentId=%s\nopenedAt=%s\n' "$id" "$(pr_now)" > "$path" || return 1
  chmod 0600 "$path" 2>/dev/null || true
}

pr_episode_clear_if_below() {  # <provider> <verdict-json>
  local provider=$1 verdict=$2 path
  path=$(pr_episode_path "$provider")
  [ -f "$path" ] || return 0
  if [ "$(printf '%s' "$verdict" | jq -r '
    if .reliability != "reliable" then "keep"
    elif ((.exhausted // []) | length) == 0 then "clear"
    else "keep" end
  ')" = clear ]; then
    rm -f -- "$path"
  fi
}

pr_claim_exists() {  # <windowIncidentId>
  [ -e "$PR_DIR/claims/$1" ] || [ -f "$PR_DIR/receipts/$1.json" ]
}

pr_claim_create() {  # <windowIncidentId> <primaryIncidentId>
  local wid=$1 primary=$2 dest tmp
  pr_ensure_dir || return 1
  dest="$PR_DIR/claims/$wid"
  tmp=$(mktemp "$PR_DIR/claims/.claim.XXXXXX") || return 1
  printf 'primary=%s\n' "$primary" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  if ln "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Structured stow attestation: exact positive shape bound to incident+generation.
pr_stow_attestation_ok() {  # <path> <incidentId> <generation>
  local path=$1 incident=$2 generation=$3
  [ -n "$path" ] || return 1
  [ -L "$path" ] && return 1
  [ -f "$path" ] || return 1
  [ ! -L "$path" ] || return 1
  python3 - "$path" "$incident" "$generation" <<'PY' 2>/dev/null || return 1
import sys
path, incident, generation = sys.argv[1:4]
try:
    text = open(path, "r", encoding="utf-8").read()
except OSError:
    sys.exit(1)
lines = [ln.rstrip("\n") for ln in text.splitlines()]
# Drop trailing empty lines for tolerance of a final newline.
while lines and lines[-1] == "":
    lines.pop()
if len(lines) < 4:
    sys.exit(1)
# Anchored header must be the first non-empty line.
body = [ln for ln in lines if ln.strip() != ""]
if not body or body[0] != "FM_PRIMARY_RESOURCE_STOW_V1":
    sys.exit(1)
fields = {}
for ln in body[1:]:
    if "=" not in ln or ln.startswith("#"):
        sys.exit(1)
    k, _, v = ln.partition("=")
    if k in fields:
        sys.exit(1)  # contradictory duplicate
    fields[k] = v
required = ("verdict", "incidentId", "generation")
if any(k not in fields for k in required):
    sys.exit(1)
if fields["verdict"] != "reset-safe":
    sys.exit(1)
if fields["incidentId"] != incident:
    sys.exit(1)
if fields["generation"] != generation:
    sys.exit(1)
# Stow attestation: reject negative prose anywhere in the file.
low = text.lower()
if "not reset-safe" in low or "reset-safe: no" in low or "reset-safe:no" in low:
    sys.exit(1)
sys.exit(0)
PY
}

# Route evidence: custom base URL/gateway for source or destination => not independent.
pr_route_custom_gateway() {  # <provider> <pid|->
  local provider=$1 pid=${2:--} envfile environ
  environ=
  if [ -n "${FM_PRIMARY_RESOURCE_ROUTE_ENV_FILE:-}" ] && [ -f "$FM_PRIMARY_RESOURCE_ROUTE_ENV_FILE" ]; then
    environ=$(tr '\0' '\n' < "$FM_PRIMARY_RESOURCE_ROUTE_ENV_FILE" 2>/dev/null || true)
  elif [ "$pid" != "-" ] && [ -r "/proc/$pid/environ" ]; then
    environ=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true)
  fi
  case "$provider" in
    claude)
      printf '%s\n' "$environ" | grep -qiE '^(ANTHROPIC_BASE_URL|ANTHROPIC_API_BASE|CLAUDE_BASE_URL)=' && return 0
      envfile="${HOME:-}/.claude/settings.json"
      if [ -f "$envfile" ] && grep -qiE '"?(baseURL|base_url|apiBase|api_base)"?\s*:' "$envfile" 2>/dev/null; then
        return 0
      fi
      ;;
    codex)
      printf '%s\n' "$environ" | grep -qiE '^(OPENAI_BASE_URL|OPENAI_API_BASE|CODEX_BASE_URL|OPENAI_API_BASE_URL)=' && return 0
      envfile="${HOME:-}/.codex/config.toml"
      if [ -f "$envfile" ] && grep -qiE 'base_url\s*=' "$envfile" 2>/dev/null; then
        return 0
      fi
      ;;
  esac
  return 1
}

pr_providers_route_ok() {  # <srcProvider> <destProvider> <pid>
  local src=$1 dest=$2 pid=$3
  if pr_route_custom_gateway "$src" "$pid"; then
    return 1
  fi
  if [ -n "$dest" ] && [ "$dest" != "$src" ] && pr_route_custom_gateway "$dest" "$pid"; then
    return 1
  fi
  return 0
}

pr_write_json_atomic() {  # <dest> <json>
  local dest=$1 json=$2 tmp
  tmp=$(mktemp "$dest.XXXXXX") || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$json" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# Create dest only if absent: write temp in same dir, hard-link no-clobber.
pr_receipt_create_noclobber() {  # <dest> <json>
  local dest=$1 json=$2 tmp dir
  dir=$(dirname -- "$dest")
  tmp=$(mktemp "$dir/.receipt.XXXXXX") || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$json" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ln "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

pr_alert_key_path() {  # <generation> <condition>
  local gen=$1 cond=$2
  gen=${gen//\//_}
  cond=${cond//\//_}
  printf '%s/alerts/%s--%s' "$PR_DIR" "$gen" "$cond"
}

pr_alert_once() {  # <generation> <condition> <line>
  local gen=$1 cond=$2 line=$3 path
  path=$(pr_alert_key_path "$gen" "$cond")
  pr_ensure_dir || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    return 1
  fi
  : > "$path" || return 1
  chmod 0600 "$path" 2>/dev/null || true
  fm_cap_line "$line" "$MAX_LINE"
  return 0
}

# --- decision -----------------------------------------------------------------

pr_decide_jq() {
  # Thresholds come from shell CONTEXT_THRESHOLD / QUOTA_THRESHOLD via --argjson.
  cat <<'JQ'
(. // {}) as $e
| ($e.context // {}) as $c
| ($e.quota // {}) as $q
| ($e.replacement // null) as $r
| ($e.receipts // []) as $receipts
| ($e.alerts // []) as $alerts
| ($e.generation // ($c.generation // "unknown")) as $gen
| (if ($e | has("backendSupported")) then $e.backendSupported else true end) as $be_ok
| (if ($e | has("argvParseable")) then $e.argvParseable else true end) as $argv_ok
| (if ($q.reliability == "reliable") and (($q.exhausted // []) | length) > 0
   then true else false end) as $quota_hit
| (if ($c.reliability == "reliable") and ($c.tokens != null)
      and (($c.tokens | tonumber) >= $threshold_ctx)
   then true else false end) as $ctx_hit
| (if ($c.reliability != "reliable") then true else false end) as $ctx_unknown
| if ($be_ok == false) then
    {action:"alert", incidentId:("alert-backend-" + $gen), reason:"unsupported-backend",
     replacement:null, alertKey:($gen + "--unsupported-backend")}
  elif ($argv_ok == false) and ($quota_hit or $ctx_hit) then
    {action:"alert", incidentId:("alert-argv-" + $gen), reason:"unparseable-launch-argv",
     replacement:null, alertKey:($gen + "--unparseable-launch-argv")}
  elif $quota_hit then
    (if ($r != null) and ($r.eligible == true)
     then
       ($e.incidentIdQuota // ("quota-" + ($q.provider // "unknown"))) as $qid
       | if (($receipts | index($qid)) != null) then
           {action:"none", incidentId:$qid, reason:"receipt-exists", replacement:null}
         else
           {action:"quota", incidentId:$qid, reason:"quota-threshold",
            replacement:$r}
         end
     else
       ($gen + "--quota-no-replacement") as $ak
       | if (($alerts | index($ak)) != null) then
           {action:"none", incidentId:"", reason:"alert-already-emitted", replacement:null}
         else
           {action:"alert", incidentId:("alert-quota-" + $gen), reason:"quota-no-eligible-replacement",
            replacement:null, alertKey:$ak}
         end
     end)
  elif $ctx_hit then
    ($e.incidentIdContext // ("context-" + $gen)) as $cid
    | if (($receipts | index($cid)) != null) then
        {action:"none", incidentId:$cid, reason:"receipt-exists", replacement:null}
      else
        {action:"context", incidentId:$cid, reason:"context-threshold",
         replacement:($r // {eligible:true, harness:($e.sourceHarness // "same"), provider:($q.provider // "same")})}
      end
  elif $ctx_unknown then
    ($gen + "--context-unavailable") as $ak
    | if (($alerts | index($ak)) != null) then
        {action:"none", incidentId:"", reason:"alert-already-emitted", replacement:null}
      else
        {action:"alert", incidentId:("alert-context-" + $gen), reason:($c.reason // "context-unavailable"),
         replacement:null, alertKey:$ak}
      end
  else
    {action:"none", incidentId:"", reason:"below-threshold", replacement:null}
  end
JQ
}

pr_decide() {
  command -v jq >/dev/null 2>&1 || { printf 'fm-primary-resource: jq required\n' >&2; exit 1; }
  jq -c \
    --argjson threshold_ctx "$CONTEXT_THRESHOLD" \
    "$(pr_decide_jq)"
}

# --- context reading ----------------------------------------------------------

pr_read_context_claude() {  # <transcript>
  local path=$1
  [ -f "$path" ] || { printf '{"tokens":null,"reliability":"unknown","reason":"missing-binding"}'; return 0; }
  jq -c '
    reduce inputs as $line ({tokens:null, reliability:"unknown", reason:"no-usage"};
      if ($line | type) != "object" then .
      elif ($line.isSidechain == true) then .
      elif ($line.type != "assistant") then .
      elif (($line.message.usage | type) != "object") then
        {tokens:null, reliability:"unknown", reason:"malformed-usage"}
      else
        ($line.message.usage) as $u
        | if (($u.input_tokens | type) != "number") then
            {tokens:null, reliability:"unknown", reason:"malformed-usage"}
          else
            {tokens: (
               ($u.input_tokens // 0)
               + ($u.cache_creation_input_tokens // 0)
               + ($u.cache_read_input_tokens // 0)
             ),
             reliability:"reliable", reason:""}
          end
      end
    )
  ' -n "$path" 2>/dev/null || printf '{"tokens":null,"reliability":"unknown","reason":"malformed-usage"}'
}

pr_read_context_codex() {  # <transcript>
  local path=$1
  [ -f "$path" ] || { printf '{"tokens":null,"reliability":"unknown","reason":"missing-binding"}'; return 0; }
  jq -c '
    reduce inputs as $line ({tokens:null, reliability:"unknown", reason:"no-usage"};
      if ($line | type) != "object" then .
      elif ($line.type != "event_msg" and $line.type != "token_count"
            and (($line.payload.type // "") != "token_count")
            and ($line.type != "token_count")) then .
      elif (($line.payload.info.last_token_usage // $line.payload.last_token_usage // null) | type) == "object" then
        (($line.payload.info.last_token_usage // $line.payload.last_token_usage) as $ltu
         | if ($ltu | type) != "object" then
             {tokens:null, reliability:"unknown", reason:"malformed-usage"}
           elif (($ltu.input_tokens | type) != "number") then
             {tokens:null, reliability:"unknown", reason:"malformed-usage"}
           else
             {tokens:$ltu.input_tokens, reliability:"reliable", reason:""}
           end)
      elif ($line.type == "token_count")
            and (($line.payload.info.last_token_usage // null) | type) == "object" then
        ($line.payload.info.last_token_usage) as $ltu
        | if (($ltu.input_tokens | type) != "number") then
            {tokens:null, reliability:"unknown", reason:"malformed-usage"}
          else
            {tokens:$ltu.input_tokens, reliability:"reliable", reason:""}
          end
      else .
      end
    )
  ' -n "$path" 2>/dev/null || printf '{"tokens":null,"reliability":"unknown","reason":"malformed-usage"}'
}

pr_read_context() {  # <harness> <transcript>
  local harness=$1 path=$2
  case "$harness" in
    claude) pr_read_context_claude "$path" ;;
    codex) pr_read_context_codex "$path" ;;
    *) printf '{"tokens":null,"reliability":"unknown","reason":"unsupported-adapter"}' ;;
  esac
}

# --- quota --------------------------------------------------------------------

pr_provider_for_harness() {
  case "$1" in
    claude) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    *) return 1 ;;
  esac
}

pr_quota_budget_secs() {
  local check_timeout=${FM_CHECK_TIMEOUT:-30} max
  case "$check_timeout" in
    ''|*[!0-9]*) check_timeout=30 ;;
  esac
  # Leave headroom for jq and watcher kill grace (fm-tool-update-check pattern).
  max=$((check_timeout - 5))
  [ "$max" -ge 1 ] || max=1
  if [ "$QUOTA_BUDGET_SECS" -gt "$max" ]; then
    printf '%s\n' "$max"
  else
    printf '%s\n' "$QUOTA_BUDGET_SECS"
  fi
}

pr_load_quota_json() {
  local out budget
  if [ -n "${FM_PRIMARY_RESOURCE_QUOTA_JSON:-}" ]; then
    printf '%s\n' "$FM_PRIMARY_RESOURCE_QUOTA_JSON"
    return 0
  fi
  if [ -n "${FM_PRIMARY_RESOURCE_QUOTA_FILE:-}" ] && [ -f "$FM_PRIMARY_RESOURCE_QUOTA_FILE" ]; then
    cat -- "$FM_PRIMARY_RESOURCE_QUOTA_FILE"
    return 0
  fi
  if ! command -v quota-axi >/dev/null 2>&1; then
    return 1
  fi
  budget=$(pr_quota_budget_secs)
  out=$(fm_run_timed "$budget" quota-axi --json 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
  return 0
}

pr_quota_verdict() {  # <provider> <quota-json>
  local provider=$1 qjson=$2
  printf '%s\n' "$qjson" | jq -c --arg provider "$provider" --argjson thr "$QUOTA_THRESHOLD" '
    ([.providers[]? | select(.provider == $provider)] | first) as $p
    | if ($p // null) == null then
        {provider:$provider, exhausted:[], reliability:"unknown", ambiguousReset:false}
      elif (($p.state.stale // false) == true) then
        {provider:$provider, exhausted:[], reliability:"unknown", ambiguousReset:false}
      elif (($p.quotaSemantics.status // "unknown") == "unknown") then
        {provider:$provider, exhausted:[], reliability:"unknown", ambiguousReset:false}
      else
        ($p.windows // [])
        | map(select((.kind == "session" or .kind == "five_hour" or .id == "five_hour"
                      or .kind == "weekly" or .id == "seven_day")
              and ((.percentRemaining | type) == "number")
              and (.percentRemaining >= 0) and (.percentRemaining <= 100)))
        | map(. + {percentUsed: (100 - .percentRemaining)})
        | map(select(.percentUsed >= $thr)) as $hit
        | ($hit | map(select((.resetsAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")))) as $reliable
        | ($hit | length) as $n
        | ($reliable | length) as $r
        | if $n > 0 and $r == 0 then
            {provider:$provider, exhausted:[], reliability:"unknown", ambiguousReset:true}
          elif $n > $r then
            {provider:$provider,
             exhausted: ($reliable | map({id, kind, resetsAt, percentUsed})),
             reliability:(if $r > 0 then "reliable" else "unknown" end),
             ambiguousReset:true}
          else
            {provider:$provider,
             exhausted: ($reliable | map({id, kind, resetsAt, percentUsed})),
             reliability:(if $r > 0 then "reliable" else "reliable" end),
             ambiguousReset:false}
          end
      end
  ' 2>/dev/null || printf '{"provider":"%s","exhausted":[],"reliability":"unknown","ambiguousReset":false}' "$provider"
}

pr_find_replacement() {  # <sourceHarness> <sourceProvider> <quota-json> [pid]
  local src_h=$1 src_p=$2 qjson=$3 pid=${4:--} dest_h dest_p row
  case "$src_h" in
    claude) dest_h=codex; dest_p=codex ;;
    codex) dest_h=claude; dest_p=claude ;;
    *) printf '{"eligible":false,"harness":null,"provider":null,"reason":"no-verified-template"}'; return 0 ;;
  esac
  [ "$dest_p" != "$src_p" ] || {
    printf '{"eligible":false,"harness":"%s","provider":"%s","reason":"same-provider"}' "$dest_h" "$dest_p"
    return 0
  }
  if ! pr_providers_route_ok "$src_p" "$dest_p" "$pid"; then
    printf '{"eligible":false,"harness":"%s","provider":"%s","reason":"custom-route-gateway"}' "$dest_h" "$dest_p"
    return 0
  fi
  row=$(printf '%s\n' "$qjson" | jq -c --arg provider "$dest_p" --argjson thr "$QUOTA_THRESHOLD" '
    ([.providers[]? | select(.provider == $provider)] | first) as $p
    | if ($p // null) == null then {ok:false, reason:"missing-row"}
      elif (($p.state.stale // false) == true) then {ok:false, reason:"stale-row"}
      elif (($p.quotaSemantics.status // "unknown") == "unknown") then {ok:false, reason:"unknown-row"}
      else
        ($p.windows // [])
        | map(select(.kind == "session" or .kind == "five_hour" or .id == "five_hour"
                     or .kind == "weekly" or .id == "seven_day")) as $w
        | if ($w | length) == 0 then {ok:false, reason:"no-applicable-windows"}
          elif ($w | map(select((.percentRemaining | type) != "number")) | length) > 0 then
            {ok:false, reason:"malformed-window"}
          elif ($w | map(select((100 - .percentRemaining) >= $thr)) | length) > 0 then
            {ok:false, reason:"destination-above-threshold"}
          else {ok:true, reason:""}
          end
      end
  ' 2>/dev/null) || row='{"ok":false,"reason":"parse-error"}'
  if [ "$(printf '%s' "$row" | jq -r '.ok')" = true ]; then
    printf '{"eligible":true,"harness":"%s","provider":"%s","reason":""}' "$dest_h" "$dest_p"
  else
    printf '{"eligible":false,"harness":"%s","provider":"%s","reason":%s}' \
      "$dest_h" "$dest_p" "$(printf '%s' "$row" | jq -c '.reason')"
  fi
}

# --- observe ------------------------------------------------------------------

action_observe() {
  local payload='' payload_file=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --payload-file)
        payload_file=${2:-}; shift 2 || die_usage "observe: --payload-file needs a path"
        ;;
      --payload)
        payload=${2:-}; shift 2 || die_usage "observe: --payload needs JSON"
        ;;
      -)
        payload=$(cat); shift ;;
      *)
        die_usage "observe: unknown argument $1"
        ;;
    esac
  done
  # turnend-guard pipes PAYLOAD into `observe` with zero arguments; read stdin.
  if [ -z "$payload" ] && [ -z "$payload_file" ]; then
    payload=$(cat 2>/dev/null || true)
  fi
  if [ -n "$payload_file" ]; then
    [ -f "$payload_file" ] || return 0
    payload=$(cat -- "$payload_file" 2>/dev/null || true)
  fi
  [ -n "$payload" ] || return 0

  pr_is_main_home || return 0
  if [ "${FM_PRIMARY_RESOURCE_FORCE_OWNER:-0}" != 1 ]; then
    fm_session_lock_owned_by_self "$STATE" || return 0
  fi
  command -v jq >/dev/null 2>&1 || return 0

  local session_id transcript harness pid bound
  session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || return 0
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null) || return 0
  [ -n "$session_id" ] || return 0
  [ -n "$transcript" ] || return 0
  [ -f "$transcript" ] || return 0

  harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
  case "$harness" in
    claude|codex) ;;
    *) harness=$(printf '%s' "$payload" | jq -r '.harness // empty' 2>/dev/null) ;;
  esac
  case "$harness" in
    claude|codex) ;;
    *) harness=unsupported ;;
  esac

  pid=
  if pid=$(pr_lock_pid); then
    :
  else
    pid=$$
  fi
  if [ -f "$PR_DIR/binding.json" ]; then
    local old_session old_pid
    old_session=$(jq -r '.sessionId // empty' "$PR_DIR/binding.json" 2>/dev/null || true)
    old_pid=$(jq -r '.pid // empty' "$PR_DIR/binding.json" 2>/dev/null || true)
    if [ -n "$old_session" ] && [ "$old_session" != "$session_id" ]; then
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        return 0
      fi
    fi
  fi

  bound=$(pr_now)
  pr_ensure_dir || return 0
  pr_lock_acquire || return 0
  pr_write_json_atomic "$PR_DIR/binding.json" "$(jq -nc \
    --argjson v "$SCHEMA_VERSION" \
    --arg h "$harness" \
    --argjson p "$pid" \
    --arg s "$session_id" \
    --arg t "$transcript" \
    --argjson b "$bound" \
    '{version:$v, harness:$h, pid:$p, sessionId:$s, transcriptPath:$t, boundAt:$b}')" || true
  pr_lock_release
  return 0
}

# --- arm ---------------------------------------------------------------------

shim_write() {
  local tmp
  tmp=$(mktemp "$CHECK_SHIM.XXXXXX") || return 1
  cat > "$tmp" <<EOF
#!/usr/bin/env bash
# Generated by fm-primary-resource.sh arm. Do not edit.
set -u
export FM_HOME=${FM_HOME@Q}
exec ${SCRIPT_DIR@Q}/fm-primary-resource.sh check
EOF
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CHECK_SHIM" || { rm -f -- "$tmp"; return 1; }
}

action_arm() {
  pr_is_main_home || return 0
  pr_require_python3 || return 1
  pr_ensure_dir || return 1
  mkdir -p "$STATE" || return 1
  shim_write || return 1
  if ! FM_HOME="$FM_HOME" "$REGISTER_BIN" "$CHECK_ID"; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    return 1
  fi
  return 0
}

# --- check --------------------------------------------------------------------

pr_reconcile_stranded() {
  # Receipt-preserving: emit one alert for stale nonterminal or stalled started.
  local f stage updated now age incident gen reason
  now=$(pr_now)
  [ -d "$PR_DIR/outcomes" ] || return 0
  for f in "$PR_DIR/outcomes"/*.json; do
    [ -f "$f" ] || continue
    incident=$(jq -r '.incidentId // empty' "$f" 2>/dev/null || true)
    [ -n "$incident" ] || continue
    [ -f "$PR_DIR/receipts/$incident.json" ] || continue
    stage=$(jq -r '.stage // empty' "$f" 2>/dev/null || true)
    updated=$(jq -r '.updatedAt // 0' "$f" 2>/dev/null || printf 0)
    case "$updated" in ''|*[!0-9]*) continue ;; esac
    age=$((now - updated))
    [ "$age" -ge "$RECONCILE_SECS" ] || continue
    gen=$(jq -r '.generation // "unknown"' "$PR_DIR/receipts/$incident.json" 2>/dev/null || printf 'unknown')
    case "$stage" in
      waiting-idle|exiting|launching)
        reason="handover-stranded-$stage"
        pr_alert_once "$gen" "stranded-$incident" \
          "primary-resource alert: handover stranded ($stage) for $incident; session kept; no auto-retry" || true
        ;;
      started)
        # Success requires a new binding generation after reservation; absent that,
        # a login-prompt or non-working successor is only caught here.
        local bind_gen
        bind_gen=$(jq -r '.sessionId // "unknown"' "$PR_DIR/binding.json" 2>/dev/null || printf unknown)
        if [ "$bind_gen" = "$gen" ]; then
          pr_alert_once "$gen" "stalled-successor-$incident" \
            "primary-resource alert: successor never became a working session for $incident; session kept; no auto-retry" || true
        fi
        ;;
    esac
  done
}

action_check() {
  local binding harness pid session transcript ctx qjson provider verdict replacement
  local generation evidence decision action line incident alert_key

  pr_is_main_home || return 0
  command -v jq >/dev/null 2>&1 || return 0
  pr_ensure_dir || return 0

  # Always reconcile stranded receipts before suppressing on receipt presence.
  pr_reconcile_stranded

  if [ ! -f "$PR_DIR/binding.json" ]; then
    generation="unbound"
    harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
    case "$harness" in
      claude|codex) line="context unavailable (no binding yet)" ;;
      *) line="adapter $harness is alert-only (only Claude and Codex have reliable context readings)" ;;
    esac
    if pr_alert_once "$generation" "context-unavailable" \
      "primary-resource alert: $line; session kept"; then
      :
    fi
    return 0
  fi

  binding=$(cat -- "$PR_DIR/binding.json")
  harness=$(printf '%s' "$binding" | jq -r '.harness')
  pid=$(printf '%s' "$binding" | jq -r '.pid')
  session=$(printf '%s' "$binding" | jq -r '.sessionId')
  transcript=$(printf '%s' "$binding" | jq -r '.transcriptPath')
  generation=$session

  # Lock owner must still match bound pid when a lock exists.
  if [ -f "$STATE/.lock" ]; then
    local lock_pid
    if lock_pid=$(pr_lock_pid); then
      if [ "$lock_pid" != "$pid" ]; then
        if pr_alert_once "$generation" "wrong-session" \
          "primary-resource alert: binding pid does not own the session lock; session kept"; then
          :
        fi
        return 0
      fi
    fi
  fi

  ctx=$(pr_read_context "$harness" "$transcript")
  provider=
  if pr_provider_for_harness "$harness" >/dev/null 2>&1; then
    provider=$(pr_provider_for_harness "$harness")
  fi

  qjson=
  if [ -n "${FM_PRIMARY_RESOURCE_QUOTA_JSON:-}" ] || [ -n "${FM_PRIMARY_RESOURCE_QUOTA_FILE:-}" ]; then
    qjson=$(pr_load_quota_json) || qjson='{"schemaVersion":5,"providers":[]}'
  elif qjson=$(pr_load_quota_json); then
    if ! printf '%s\n' "$qjson" | fm_quota_json_valid 2>/dev/null; then
      qjson='{"schemaVersion":5,"providers":[]}'
    fi
  else
    qjson='{"schemaVersion":5,"providers":[]}'
  fi

  if [ -n "$provider" ]; then
    verdict=$(pr_quota_verdict "$provider" "$qjson")
    pr_episode_clear_if_below "$provider" "$verdict"
    replacement=$(pr_find_replacement "$harness" "$provider" "$qjson" "$pid")
  else
    verdict=$(printf '{"provider":"","exhausted":[],"reliability":"unknown","ambiguousReset":false}')
    replacement='{"eligible":false,"harness":null,"provider":null,"reason":"unsupported-provider"}'
  fi

  # Ambiguous/missing resetsAt: alert-only, never treat as reliable exhaustion alone.
  if [ "$(printf '%s' "$verdict" | jq -r '.ambiguousReset // false')" = true ] \
    && [ "$(printf '%s' "$verdict" | jq -r '(.exhausted // []) | length')" = 0 ]; then
    if pr_alert_once "$generation" "quota-ambiguous-reset" \
      "primary-resource alert: quota reset identity ambiguous; session kept"; then
      :
    fi
  fi

  local backend be_ok=true argv_ok=true herdr_alert_only=false
  backend=$(discover_supervisor_backend 2>/dev/null) || backend=
  [ -n "$backend" ] || backend=unknown
  case "$backend" in
    tmux) be_ok=true ;;
    herdr)
      # Decide may still compute thresholds; terminal commit/helper stay disabled.
      be_ok=true
      herdr_alert_only=true
      ;;
    *) be_ok=false ;;
  esac

  local id_ctx id_quota receipts_json alerts_json episode_blocks=false
  id_ctx=$(pr_incident_context "$session")
  id_quota=
  if [ -n "$provider" ]; then
    if id_quota=$(pr_incident_quota_primary "$provider" "$(printf '%s' "$verdict" | jq -c '.exhausted')"); then
      :
    else
      id_quota=
    fi
    if pr_episode_active "$provider"; then
      episode_blocks=true
    fi
  fi
  [ -n "$id_quota" ] || id_quota="quota-none"

  receipts_json='[]'
  if [ -d "$PR_DIR/receipts" ] && [ -n "$(ls -A "$PR_DIR/receipts" 2>/dev/null || true)" ]; then
    receipts_json=$(jq -nc '[inputs.incidentId] | unique' "$PR_DIR"/receipts/*.json 2>/dev/null || printf '[]')
  fi
  # Treat per-window claims and active episodes as receipt coverage.
  if [ "$episode_blocks" = true ] && [ -n "$id_quota" ] && [ "$id_quota" != "quota-none" ]; then
    receipts_json=$(printf '%s' "$receipts_json" | jq -c --arg id "$id_quota" '. + [$id] | unique')
  fi
  if [ -d "$PR_DIR/claims" ]; then
    local claim_ids
    claim_ids=$(find "$PR_DIR/claims" -type f -printf '%f\n' 2>/dev/null \
      | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null || printf '[]')
    receipts_json=$(jq -nc --argjson a "$receipts_json" --argjson b "$claim_ids" '$a + $b | unique')
  fi

  alerts_json='[]'
  if [ -d "$PR_DIR/alerts" ]; then
    alerts_json=$(find "$PR_DIR/alerts" -type f -printf '%f\n' 2>/dev/null \
      | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null || printf '[]')
  fi

  evidence=$(jq -nc \
    --argjson ctx "$ctx" \
    --argjson quota "$verdict" \
    --argjson repl "$replacement" \
    --argjson receipts "$receipts_json" \
    --argjson alerts "$alerts_json" \
    --arg gen "$generation" \
    --arg src "$harness" \
    --argjson be_ok "$be_ok" \
    --argjson argv_ok "$argv_ok" \
    --arg idc "$id_ctx" \
    --arg idq "$id_quota" \
    --argjson pid "$pid" \
    --arg sess "$session" \
    '{
      context: ($ctx + {generation:$gen}),
      quota:$quota,
      replacement:$repl,
      receipts:$receipts,
      alerts:$alerts,
      generation:$gen,
      sourceHarness:$src,
      backendSupported:$be_ok,
      argvParseable:$argv_ok,
      incidentIdContext:$idc,
      incidentIdQuota:$idq,
      sourceBinding:{pid:$pid, sessionId:$sess, harness:$src}
    }')

  decision=$(printf '%s\n' "$evidence" | pr_decide) || return 0
  action=$(printf '%s' "$decision" | jq -r '.action')
  incident=$(printf '%s' "$decision" | jq -r '.incidentId // empty')
  alert_key=$(printf '%s' "$decision" | jq -r '.alertKey // empty')

  case "$action" in
    none) return 0 ;;
    alert)
      local reason
      reason=$(printf '%s' "$decision" | jq -r '.reason')
      if [ -n "$alert_key" ]; then
        local gen_part cond_part
        gen_part=${alert_key%%--*}
        cond_part=${alert_key#*--}
        pr_alert_once "$gen_part" "$cond_part" \
          "primary-resource alert: $reason; session kept" || return 0
      else
        fm_cap_line "primary-resource alert: $reason; session kept" "$MAX_LINE"
      fi
      return 0
      ;;
    context|quota)
      [ -n "$incident" ] || return 0
      if [ -f "$PR_DIR/receipts/$incident.json" ] || pr_claim_exists "$incident"; then
        return 0
      fi
      if [ "$action" = quota ] && [ "$episode_blocks" = true ]; then
        return 0
      fi
      if [ "$herdr_alert_only" = true ]; then
        pr_alert_once "$generation" "herdr-alert-only" \
          "primary-resource alert: Herdr terminal handover unverified (live proof missing); session kept" || return 0
        return 0
      fi
      # Persist normalized evidence + generation for commit-time revalidation.
      decision=$(printf '%s' "$decision" | jq -c \
        --argjson ev "$evidence" \
        --arg gen "$generation" \
        --argjson pid "$pid" \
        --arg sess "$session" \
        --arg src "$harness" \
        '. + {generation:$gen, evidence:$ev, sourceBinding:{pid:$pid, sessionId:$sess, harness:$src}}')
      pr_write_json_atomic "$PR_DIR/proposals/$incident.json" "$decision" || true
      line="primary-resource $action $incident"
      fm_cap_line "$line" "$MAX_LINE"
      return 0
      ;;

  esac
  return 0
}

# --- commit -------------------------------------------------------------------

pr_outcome_write() {  # <incident> <stage> <reason>
  local id=$1 stage=$2 reason=$3
  pr_ensure_dir || return 1
  pr_write_json_atomic "$PR_DIR/outcomes/$id.json" "$(jq -nc \
    --argjson v "$SCHEMA_VERSION" \
    --arg id "$id" \
    --arg stage "$stage" \
    --arg reason "$reason" \
    --argjson t "$(pr_now)" \
    '{version:$v, incidentId:$id, stage:$stage, reason:$reason, updatedAt:$t}')"
}

pr_capture_argv() {  # <pid> <dest>
  local pid=$1 dest=$2
  if [ -n "${FM_PRIMARY_RESOURCE_ARGV_FILE:-}" ] && [ -f "$FM_PRIMARY_RESOURCE_ARGV_FILE" ]; then
    cat -- "$FM_PRIMARY_RESOURCE_ARGV_FILE" > "$dest" || return 1
    return 0
  fi
  if [ ! -r "/proc/$pid/cmdline" ]; then
    return 1
  fi
  cat "/proc/$pid/cmdline" > "$dest" || return 1
  return 0
}

pr_strip_resume_argv() {  # <nul-argv-file> <harness> -> shell-quoted command line
  # Per-harness tables: strip only resume/continue (and values when they take
  # them) plus the old positional prompt. Keep captain posture flags such as
  # --dangerously-skip-permissions. Unknown option arity fails closed.
  # argv[0] MUST be the expected harness executable (basename match); wrappers
  # (env) and interpreters (node/python) are refused before parsing.
  local file=$1 harness=$2
  pr_require_python3 || return 1
  python3 - "$file" "$harness" <<'PY' 2>/dev/null || return 1
import sys, shlex, os
raw = open(sys.argv[1], "rb").read().split(b"\0")
harness = sys.argv[2]
args = [a.decode("utf-8", "surrogateescape") for a in raw if a]
if not args:
    sys.exit(1)

def basename(p):
    return os.path.basename(p.rstrip("/")) or p

# Prove argv[0] is the harness itself — not env/node/python wrappers.
exe = basename(args[0])
# Strip a leading dash from login-shell style names (not expected for harnesses).
if exe.startswith("-"):
    exe = exe[1:]
expected = {
    "claude": {"claude"},
    "codex": {"codex"},
}.get(harness)
if expected is None or exe not in expected:
    sys.exit(1)

def drop_optional_value(i, args):
    if i + 1 < len(args) and not args[i + 1].startswith("-"):
        return i + 2
    return i + 1

if harness == "claude":
    # -c/--continue are booleans. -p/--print is boolean. --resume/-r take an
    # optional session id. Keep --dangerously-skip-permissions.
    DROP_BOOL = {"-c", "--continue"}
    DROP_OPT_VALUE = {"--resume", "-r"}
    VALUE_OPTS = {
        "-m", "--model", "--effort", "--settings",
        "--add-dir", "--plugin-dir", "--mcp-config", "--allowedTools",
        "--allowed-tools", "--disallowedTools", "--disallowed-tools",
        "--append-system-prompt", "--system-prompt",
        "--permission-mode", "--output-format", "--input-format",
        "--agent", "--agents", "--betas", "--debug-file",
    }
    BOOL_KEEP = {
        "-p", "--print", "--dangerously-skip-permissions",
        "--allow-dangerously-skip-permissions", "--bare", "--chrome",
        "--no-chrome", "--brief", "--verbose",
    }
elif harness == "codex":
    # -c/--config takes key=value. -p/--profile takes a value. Keep both.
    DROP_BOOL = set()
    DROP_OPT_VALUE = {"--continue"}
    VALUE_OPTS = {
        "-c", "--config", "-p", "--profile", "-m", "--model",
        "-i", "--image", "--enable", "--disable", "--remote",
        "--remote-auth-token-env", "--local-provider",
        "--effort", "--sandbox",
    }
    BOOL_KEEP = {"--oss", "--strict-config"}
else:
    sys.exit(1)

out = [args[0]]
i = 1
while i < len(args):
    a = args[i]
    base = a.split("=", 1)[0]
    if a in DROP_BOOL or base in DROP_BOOL:
        i += 1
        continue
    if a in DROP_OPT_VALUE or base in DROP_OPT_VALUE:
        if "=" in a:
            i += 1
            continue
        i = drop_optional_value(i, args)
        continue
    if harness == "codex" and a == "resume":
        break
    if a.startswith("-") and base in VALUE_OPTS:
        if "=" in a:
            out.append(a)
            i += 1
            continue
        out.append(a)
        if i + 1 >= len(args):
            sys.exit(1)
        out.append(args[i + 1])
        i += 2
        continue
    if a.startswith("-"):
        if a in BOOL_KEEP or base in BOOL_KEEP:
            out.append(a)
            i += 1
            continue
        if a.startswith("--"):
            sys.exit(1)
        sys.exit(1)
    # positional prompt: drop for a fresh conversation
    i += 1
print(" ".join(shlex.quote(x) for x in out))
PY
}

pr_launch_helper() {  # <incident> <primary-target> <primary-backend>
  local incident=$1 target=$2 backend=$3 cmd session hash nonce entry helper_endpoint
  entry="$SCRIPT_DIR/fm-primary-resource.sh"
  case "$backend" in
    tmux) ;;
    herdr)
      # Terminal helper launch disabled until guarded live Herdr proof exists.
      return 1
      ;;
    *) return 1 ;;
  esac
  cmd=$(printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %q helper %q' \
    "$FM_HOME" "$target" "$backend" "$entry" "$incident")
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(pr_now)"
  session="fm-pr-helper-$hash-$nonce"
  if ! tmux new-session -d -s "$session" "$cmd" 2>/dev/null; then
    return 1
  fi
  helper_endpoint="tmux:$session"
  printf '%s\n' "$helper_endpoint"
}

# Recompute whether the same handover action is still warranted (commit gate).
pr_commit_revalidate() {  # <incident> <expected-action> -> 0 if still warranted
  local incident=$1 expected=$2
  local binding harness pid session transcript ctx qjson provider verdict replacement
  local generation evidence decision action fresh_id be_ok=true

  [ -f "$PR_DIR/binding.json" ] || return 1
  binding=$(cat -- "$PR_DIR/binding.json")
  harness=$(printf '%s' "$binding" | jq -r '.harness')
  pid=$(printf '%s' "$binding" | jq -r '.pid')
  session=$(printf '%s' "$binding" | jq -r '.sessionId')
  transcript=$(printf '%s' "$binding" | jq -r '.transcriptPath')
  generation=$session

  local lock_pid
  if ! lock_pid=$(pr_lock_pid); then
    return 1
  fi
  [ "$lock_pid" = "$pid" ] || return 1
  [ "$session" = "$(jq -r '.sourceBinding.sessionId // .generation // empty' "$PR_DIR/proposals/$incident.json" 2>/dev/null)" ] \
    || [ "$session" = "$(jq -r '.generation // empty' "$PR_DIR/proposals/$incident.json" 2>/dev/null)" ] \
    || return 1

  ctx=$(pr_read_context "$harness" "$transcript")
  provider=$(pr_provider_for_harness "$harness" 2>/dev/null || printf '')
  qjson=$(pr_load_quota_json 2>/dev/null || printf '{"schemaVersion":5,"providers":[]}')
  if [ -n "$provider" ]; then
    verdict=$(pr_quota_verdict "$provider" "$qjson")
    replacement=$(pr_find_replacement "$harness" "$provider" "$qjson" "$pid")
  else
    verdict='{"provider":"","exhausted":[],"reliability":"unknown","ambiguousReset":false}'
    replacement='{"eligible":false,"harness":null,"provider":null,"reason":"unsupported-provider"}'
  fi

  local backend
  backend=$(discover_supervisor_backend 2>/dev/null) || backend=
  case "$backend" in
    tmux) be_ok=true ;;
    *) be_ok=false ;;
  esac

  local id_ctx id_quota
  id_ctx=$(pr_incident_context "$session")
  id_quota=
  if [ -n "$provider" ]; then
    id_quota=$(pr_incident_quota_primary "$provider" "$(printf '%s' "$verdict" | jq -c '.exhausted')" 2>/dev/null || true)
  fi
  [ -n "$id_quota" ] || id_quota="quota-none"

  evidence=$(jq -nc \
    --argjson ctx "$ctx" \
    --argjson quota "$verdict" \
    --argjson repl "$replacement" \
    --arg gen "$generation" \
    --arg src "$harness" \
    --argjson be_ok "$be_ok" \
    --arg idc "$id_ctx" \
    --arg idq "$id_quota" \
    '{
      context: ($ctx + {generation:$gen}),
      quota:$quota,
      replacement:$repl,
      receipts:[],
      alerts:[],
      generation:$gen,
      sourceHarness:$src,
      backendSupported:$be_ok,
      argvParseable:true,
      incidentIdContext:$idc,
      incidentIdQuota:$idq
    }')
  decision=$(printf '%s\n' "$evidence" | pr_decide) || return 1
  action=$(printf '%s' "$decision" | jq -r '.action')
  fresh_id=$(printf '%s' "$decision" | jq -r '.incidentId // empty')
  [ "$action" = "$expected" ] || return 1
  [ "$fresh_id" = "$incident" ] || return 1
  return 0
}

action_commit() {
  local incident='' stow=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --stow-receipt) stow=${2:-}; shift 2 || die_usage "commit: --stow-receipt needs a path" ;;
      --help|-h) usage; return 0 ;;
      -*) die_usage "commit: unknown flag $1" ;;
      *)
        [ -z "$incident" ] || die_usage "commit: unexpected arg $1"
        incident=$1; shift
        ;;
    esac
  done
  [ -n "$incident" ] || die_usage "commit: incident id required"
  fm_pr_task_id_valid "$incident" || die_usage "commit: invalid incident id"
  [ -n "$stow" ] || die_usage "commit: --stow-receipt required"
  [ -e "$stow" ] || { printf 'fm-primary-resource: stow receipt missing\n' >&2; return 1; }
  [ -L "$stow" ] && { printf 'fm-primary-resource: stow receipt must not be a symlink\n' >&2; return 1; }
  [ -f "$stow" ] || { printf 'fm-primary-resource: stow receipt missing\n' >&2; return 1; }

  pr_is_main_home || { printf 'fm-primary-resource: not main home\n' >&2; return 1; }
  pr_require_python3 || return 1
  if [ "${FM_PRIMARY_RESOURCE_FORCE_OWNER:-0}" != 1 ]; then
    fm_session_lock_owned_by_self "$STATE" || {
      printf 'fm-primary-resource: session lock not owned\n' >&2; return 1; }
  fi

  local proposal action dest_h dest_p src_h src_p generation
  proposal="$PR_DIR/proposals/$incident.json"
  [ -f "$proposal" ] || { printf 'fm-primary-resource: no proposal for %s\n' "$incident" >&2; return 1; }
  action=$(jq -r '.action' "$proposal")
  case "$action" in
    context|quota) ;;
    *) printf 'fm-primary-resource: proposal action is not a handover\n' >&2; return 1 ;;
  esac
  # Proposal must carry evidence + generation from check.
  if ! jq -e '.evidence and .generation and .sourceBinding' "$proposal" >/dev/null 2>&1; then
    printf 'fm-primary-resource: proposal missing evidence/generation for revalidation\n' >&2
    return 1
  fi
  generation=$(jq -r '.generation' "$proposal")

  if ! pr_stow_attestation_ok "$stow" "$incident" "$generation"; then
    printf 'fm-primary-resource: stow attestation rejected (need FM_PRIMARY_RESOURCE_STOW_V1 bound to this incident)\n' >&2
    return 1
  fi

  if [ -f "$PR_DIR/receipts/$incident.json" ]; then
    printf 'fm-primary-resource: receipt already exists for %s\n' "$incident" >&2
    return 1
  fi

  pr_lock_acquire || return 1

  # Under the resource lock: binding must still be the lock owner; re-read
  # evidence and refuse unless the same action remains warranted.
  if [ "${FM_PRIMARY_RESOURCE_FORCE_OWNER:-0}" != 1 ]; then
    if ! pr_commit_revalidate "$incident" "$action"; then
      pr_lock_release
      printf 'fm-primary-resource: commit revalidation refused (action no longer warranted)\n' >&2
      return 1
    fi
  else
    # Test seam: still require binding pid == lock pid when a lock file exists.
    if [ -f "$STATE/.lock" ] && [ -f "$PR_DIR/binding.json" ]; then
      local lock_pid bind_pid
      lock_pid=$(pr_lock_pid 2>/dev/null || true)
      bind_pid=$(jq -r '.pid' "$PR_DIR/binding.json")
      if [ -n "$lock_pid" ] && [ "$lock_pid" != "$bind_pid" ]; then
        pr_lock_release
        printf 'fm-primary-resource: binding pid does not own the session lock\n' >&2
        return 1
      fi
    fi
    if ! pr_commit_revalidate "$incident" "$action"; then
      pr_lock_release
      printf 'fm-primary-resource: commit revalidation refused (action no longer warranted)\n' >&2
      return 1
    fi
  fi

  src_h=$(jq -r '.harness' "$PR_DIR/binding.json")
  src_p=$(pr_provider_for_harness "$src_h" 2>/dev/null || printf '')
  dest_h=$(jq -r '.replacement.harness // empty' "$proposal")
  dest_p=$(jq -r '.replacement.provider // empty' "$proposal")
  if [ "$action" = context ]; then
    dest_h=$src_h
    dest_p=$src_p
  fi

  if [ "$action" = quota ]; then
    local bind_pid
    bind_pid=$(jq -r '.pid' "$PR_DIR/binding.json")
    if ! pr_providers_route_ok "$src_p" "$dest_p" "$bind_pid"; then
      pr_lock_release
      printf 'fm-primary-resource: custom route/gateway; refusing provider-independence claim\n' >&2
      return 1
    fi
  fi

  local backend target
  target=$(discover_supervisor_target) || {
    pr_lock_release
    printf 'fm-primary-resource: cannot discover supervisor target\n' >&2; return 1; }
  backend=$(discover_supervisor_backend) || {
    pr_lock_release
    printf 'fm-primary-resource: cannot discover supervisor backend\n' >&2; return 1; }
  case "$backend" in
    tmux) ;;
    herdr)
      pr_lock_release
      printf 'fm-primary-resource: Herdr terminal handover unverified (live proof missing)\n' >&2
      return 1
      ;;
    *)
      pr_lock_release
      printf 'fm-primary-resource: unsupported backend %s\n' "$backend" >&2
      return 1
      ;;
  esac

  local pid argv_file launch_cmd
  pid=$(jq -r '.pid' "$PR_DIR/binding.json")
  argv_file="$PR_DIR/launch/$incident.argv"
  pr_ensure_dir || { pr_lock_release; return 1; }

  if [ "$action" = context ]; then
    if ! pr_capture_argv "$pid" "$argv_file"; then
      pr_lock_release
      printf 'fm-primary-resource: cannot capture launch argv (non-/proc or unreadable)\n' >&2
      return 1
    fi
    if ! launch_cmd=$(pr_strip_resume_argv "$argv_file" "$src_h"); then
      pr_lock_release
      printf 'fm-primary-resource: unparseable launch argv (wrapper/interpreter refused or unknown options)\n' >&2
      rm -f -- "$argv_file"
      return 1
    fi
    local prompt
    prompt="This is a fresh main Firstmate session replacing the session recorded in receipt $incident. Read AGENTS.md. Run bin/fm-session-start.sh exactly once unless its complete digest was already supplied. Verify lock ownership, read the stow receipt and outstanding work through their existing owners, then resume the emitted supervision protocol. Do not retry this incident; its immutable receipt consumes the automatic action. Do not resume the previous vendor conversation."
    launch_cmd="$launch_cmd $(printf '%q' "$prompt")"
    printf '%s\n' "$launch_cmd" > "$PR_DIR/launch/$incident.cmd"
  else
    local prompt bin
    case "$dest_h" in
      claude) bin=$(command -v claude) || { pr_lock_release; printf 'fm-primary-resource: claude binary missing\n' >&2; return 1; } ;;
      codex) bin=$(command -v codex) || { pr_lock_release; printf 'fm-primary-resource: codex binary missing\n' >&2; return 1; } ;;
      *) pr_lock_release; printf 'fm-primary-resource: destination harness not a verified template\n' >&2; return 1 ;;
    esac
    prompt="This is a fresh main Firstmate session replacing the session recorded in receipt $incident. Read AGENTS.md. Run bin/fm-session-start.sh exactly once unless its complete digest was already supplied. Verify lock ownership, read the stow receipt and outstanding work through their existing owners, then resume the emitted supervision protocol. Do not retry this incident; its immutable receipt consumes the automatic action. Do not resume the previous vendor conversation."
    launch_cmd=$(printf '%q %q' "$bin" "$prompt")
    printf '%s\n' "$launch_cmd" > "$PR_DIR/launch/$incident.cmd"
  fi

  local receipt helper_endpoint reserved window_claims='[]'
  reserved=$(pr_now)
  helper_endpoint=""
  if [ "$action" = quota ] && [ -n "$src_p" ]; then
    local exhausted_json wids wid resets claim_id
    exhausted_json=$(jq -c '.evidence.quota.exhausted // []' "$proposal" 2>/dev/null || printf '[]')
    wids=$(printf '%s' "$exhausted_json" | jq -r '.[] | select((.resetsAt // "") | test("^[0-9]{4}-")) | "\(.id)\t\(.resetsAt)"')
    window_claims='[]'
    while IFS=$'\t' read -r wid resets; do
      [ -n "$wid" ] || continue
      claim_id=$(pr_incident_quota_window "$src_p" "$wid" "$resets")
      window_claims=$(printf '%s' "$window_claims" | jq -c --arg id "$claim_id" '. + [$id]')
    done <<EOF
$wids
EOF
  fi

  receipt=$(jq -nc \
    --argjson v "$SCHEMA_VERSION" \
    --arg id "$incident" \
    --arg action "$action" \
    --arg sh "$src_h" \
    --arg sp "${src_p:-}" \
    --arg dh "$dest_h" \
    --arg dp "${dest_p:-}" \
    --arg gen "$generation" \
    --arg stow "$stow" \
    --argjson ra "$reserved" \
    --argjson claims "$window_claims" \
    '{version:$v, incidentId:$id, action:$action, sourceHarness:$sh, sourceProvider:$sp,
      destinationHarness:$dh, destinationProvider:$dp, generation:$gen, stowReceiptPath:$stow,
      reservedAt:$ra, windowClaims:$claims}')

  if ! pr_receipt_create_noclobber "$PR_DIR/receipts/$incident.json" "$receipt"; then
    pr_lock_release
    printf 'fm-primary-resource: receipt already exists for %s\n' "$incident" >&2
    return 1
  fi

  # Claim each exhausted window independently (aliases); open the provider episode.
  if [ "$action" = quota ] && [ -n "$src_p" ]; then
    local claim_id
    for claim_id in $(printf '%s' "$window_claims" | jq -r '.[]'); do
      pr_claim_create "$claim_id" "$incident" || true
    done
    pr_episode_open "$src_p" "$incident" || true
  fi

  pr_outcome_write "$incident" "waiting-idle" "reserved" || true

  if ! helper_endpoint=$(pr_launch_helper "$incident" "$target" "$backend"); then
    pr_outcome_write "$incident" "failed" "helper-launch-failed" || true
    pr_lock_release
    printf 'fm-primary-resource: helper launch failed\n' >&2
    return 1
  fi
  pr_outcome_write "$incident" "waiting-idle" "helper-launched" "$helper_endpoint" || true
  pr_lock_release

  local wait_secs=${FM_PRIMARY_RESOURCE_HELPER_WAIT_SECS:-15} i=0
  while [ "$i" -lt "$wait_secs" ]; do
    [ -f "$PR_DIR/helper-ready/$incident" ] && break
    sleep 1
    i=$((i + 1))
  done
  if [ ! -f "$PR_DIR/helper-ready/$incident" ]; then
    pr_outcome_write "$incident" "failed" "helper-ready-timeout" || true
    printf 'fm-primary-resource: helper did not acknowledge ready\n' >&2
    return 1
  fi
  printf '%s\n' "$incident"
  return 0
}

# --- helper -------------------------------------------------------------------

# Explicit shell-only process predicate (not recovery-grade agent_state=dead).
pr_pane_process_state() {  # <backend> <target> -> agent|shell|other|unknown
  local backend=$1 target=$2 state_target=$2
  case "$backend" in
    herdr)
      local session pane
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$session" != "$target" ] || {
        printf 'unknown\n'; return 0; }
      fm_backend_source herdr 2>/dev/null || { printf 'unknown\n'; return 0; }
      fm_backend_herdr_pane_process_state "$session" "$pane" 2>/dev/null || printf 'unknown\n'
      ;;
    tmux)
      case "$target" in
        %*)
          state_target=$(tmux display-message -p -t "$target" '#{session_name}:#{window_name}' 2>/dev/null || printf '%s' "$target")
          ;;
      esac
      local pids seen=0 agent=0 other=0 shell=0 pid name argv0 args
      pids=$(fm_backend_tmux_foreground_pids "$state_target" 2>/dev/null || true)
      while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        seen=1
        name=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        argv0=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | head -n1 || true)
        args=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
        case "$(fm_agent_process_classify "${name:-}" "${argv0:-}" "${args:-}" "$pid")" in
          agent) agent=1 ;;
          shell) shell=1 ;;
          *) other=1 ;;
        esac
      done <<EOF
$pids
EOF
      if [ "$seen" -eq 0 ]; then
        printf 'unknown\n'
      elif [ "$agent" -eq 1 ]; then
        printf 'agent\n'
      elif [ "$other" -eq 1 ]; then
        printf 'other\n'
      elif [ "$shell" -eq 1 ]; then
        printf 'shell\n'
      else
        printf 'unknown\n'
      fi
      ;;
    *) printf 'unknown\n' ;;
  esac
}

pr_pane_is_shell() {  # <backend> <target>
  [ "$(pr_pane_process_state "$1" "$2")" = shell ]
}

# Prove the pane's current occupant is the recorded source pid (and harness).
pr_pane_occupant_matches() {  # <backend> <target> <expected-pid> <expected-harness>
  local backend=$1 target=$2 expected_pid=$3 expected_harness=$4
  local state_target=$2 pids found=0 pid name argv0 args class
  case "$expected_pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$expected_pid" 2>/dev/null || return 1

  case "$backend" in
    tmux)
      case "$target" in
        %*)
          state_target=$(tmux display-message -p -t "$target" '#{session_name}:#{window_name}' 2>/dev/null || printf '%s' "$target")
          ;;
      esac
      pids=$(fm_backend_tmux_foreground_pids "$state_target" 2>/dev/null || true)
      # Also accept the expected pid as a child of the pane shell (foreground
      # group may be the shell while the harness is a descendant).
      printf '%s\n' "$pids" | grep -qx "$expected_pid" && found=1
      if [ "$found" -eq 0 ]; then
        local shell_pid
        shell_pid=$(tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null || true)
        if [ -n "$shell_pid" ]; then
          # Exact pid must still be a descendant of the pane shell (or the shell itself).
          local cur=$expected_pid pp walk=0
          while [ "$walk" -lt 16 ]; do
            case "$cur" in ''|*[!0-9]*) break ;; esac
            if [ "$cur" = "$shell_pid" ]; then
              found=1
              break
            fi
            pp=$(awk '/^PPid:/{print $2; exit}' "/proc/$cur/status" 2>/dev/null || true)
            [ -n "$pp" ] && [ "$pp" != "$cur" ] || break
            cur=$pp
            walk=$((walk + 1))
          done
        fi
      fi
      [ "$found" -eq 1 ] || return 1
      ;;

    herdr)
      local session pane info
      session=${target%%:*}
      pane=${target#*:}
      fm_backend_source herdr 2>/dev/null || return 1
      if [ "$(fm_backend_herdr_pane_process_state "$session" "$pane" 2>/dev/null || true)" != agent ]; then
        return 1
      fi
      # Exact pid match via process-info when available.
      info=$(fm_backend_herdr_cli "$session" pane process-info "$pane" 2>/dev/null || true)
      if [ -n "$info" ]; then
        printf '%s' "$info" | jq -e --argjson p "$expected_pid" \
          '[.. | objects | .pid? // empty] | index($p) != null' >/dev/null 2>&1 || return 1
      fi
      ;;
    *) return 1 ;;
  esac

  name=$(ps -p "$expected_pid" -o comm= 2>/dev/null || true)
  argv0=$(tr '\0' '\n' < "/proc/$expected_pid/cmdline" 2>/dev/null | head -n1 || true)
  args=$(tr '\0' ' ' < "/proc/$expected_pid/cmdline" 2>/dev/null || true)
  class=$(fm_agent_process_classify "${name:-}" "${argv0:-}" "${args:-}" "$expected_pid")
  [ "$class" = agent ] || return 1
  # Harness name must appear in argv0/comm for the recorded source harness.
  case "$expected_harness" in
    claude|codex)
      printf '%s\n%s\n' "$name" "$argv0" | grep -qi "$expected_harness" || return 1
      ;;
  esac
  return 0
}

action_helper() {
  local incident=${1:-}
  [ -n "$incident" ] || die_usage "helper: incident id required"
  fm_pr_task_id_valid "$incident" || die_usage "helper: invalid incident id"

  local receipt binding pid harness backend target launch_cmd exit_cmd dest_h
  receipt="$PR_DIR/receipts/$incident.json"
  [ -f "$receipt" ] || { printf 'fm-primary-resource: missing receipt\n' >&2; exit 1; }
  jq -e --arg id "$incident" '.incidentId == $id' "$receipt" >/dev/null 2>&1 \
    || { printf 'fm-primary-resource: invalid receipt\n' >&2; exit 1; }
  pr_ensure_dir || exit 1

  : > "$PR_DIR/helper-ready/$incident"
  chmod 0600 "$PR_DIR/helper-ready/$incident" 2>/dev/null || true
  binding="$PR_DIR/binding.json"
  [ -f "$binding" ] || { pr_outcome_write "$incident" "failed" "missing-binding"; exit 1; }
  pid=$(jq -r '.pid' "$binding")
  harness=$(jq -r '.sourceHarness // empty' "$receipt")
  [ -n "$harness" ] || harness=$(jq -r '.harness' "$binding")
  dest_h=$(jq -r '.destinationHarness // empty' "$receipt")
  target=${FM_SUPERVISOR_TARGET:-}
  backend=${FM_SUPERVISOR_BACKEND:-}
  [ -n "$target" ] && [ -n "$backend" ] || {
    pr_outcome_write "$incident" "failed" "missing-supervisor-target"
    return 1
  }
  case "$backend" in
    herdr)
      pr_outcome_write "$incident" "failed" "herdr-alert-only"
      return 1
      ;;
  esac
  launch_cmd=$(cat -- "$PR_DIR/launch/$incident.cmd" 2>/dev/null || true)
  [ -n "$launch_cmd" ] || { pr_outcome_write "$incident" "failed" "missing-launch-cmd"; exit 1; }

  local wait_secs=${FM_PRIMARY_RESOURCE_HELPER_WAIT_SECS:-30} i=0 state_target busy
  state_target=$target
  if [ "$backend" = tmux ]; then
    case "$target" in
      %*)
        state_target=$(tmux display-message -p -t "$target" '#{session_name}:#{window_name}' 2>/dev/null || printf '%s' "$target")
        ;;
    esac
  fi
  pr_outcome_write "$incident" "waiting-idle" "awaiting-turn-end" || true
  while [ "$i" -lt "$wait_secs" ]; do
    busy=$(pr_primary_busy_state "$backend" "$state_target" "$harness")
    case "$busy" in
      idle) break ;;
      busy)
        sleep 1
        i=$((i + 1))
        continue
        ;;
      *)
        pr_outcome_write "$incident" "failed" "no-busy-signal"
        return 1
        ;;
    esac
  done
  if [ "$i" -ge "$wait_secs" ]; then
    busy=$(pr_primary_busy_state "$backend" "$state_target" "$harness")
    if [ "$busy" != idle ]; then
      pr_outcome_write "$incident" "failed" "busy-wait-timeout"
      return 1
    fi
  fi

  if ! exit_cmd=$(fm_control_exit_command "$harness"); then
    pr_outcome_write "$incident" "failed" "no-exit-command"
    return 1
  fi

  # Immediately before exit: occupant must still be the recorded source pid/harness.
  if ! pr_pane_occupant_matches "$backend" "$target" "$pid" "$harness"; then
    pr_outcome_write "$incident" "failed" "occupant-changed"
    return 1
  fi

  pr_outcome_write "$incident" "exiting" "sending-exit" || true
  if ! fm_backend_send_text_submit "$backend" "$target" "$exit_cmd" 1 0.2 0.5 >/dev/null 2>&1; then
    case "$backend" in
      tmux) tmux send-keys -t "$target" -l "$exit_cmd" \; send-keys -t "$target" Enter 2>/dev/null || true ;;
    esac
  fi

  i=0
  while [ "$i" -lt "$wait_secs" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      if pr_pane_is_shell "$backend" "$target"; then
        break
      fi
    fi
    sleep 1
    i=$((i + 1))
  done

  if kill -0 "$pid" 2>/dev/null; then
    pr_outcome_write "$incident" "failed" "old-pid-still-alive"
    return 1
  fi
  i=0
  while [ "$i" -lt 10 ]; do
    if pr_pane_is_shell "$backend" "$target"; then
      break
    fi
    sleep 0.5
    i=$((i + 1))
  done
  if ! pr_pane_is_shell "$backend" "$target"; then
    pr_outcome_write "$incident" "failed" "pane-not-shell"
    return 1
  fi

  pr_outcome_write "$incident" "launching" "sending-launch" || true
  fm_backend_source "$backend" || true
  case "$backend" in
    tmux) fm_backend_tmux_send_text_line "$target" "$launch_cmd" >/dev/null 2>&1 || true ;;
    *)
      fm_backend_send_text_submit "$backend" "$target" "$launch_cmd" 1 0.2 0.5 >/dev/null 2>&1 || true
      ;;
  esac

  i=0
  while [ "$i" -lt "$wait_secs" ]; do
    # Pane-scoped agent classifier only — never host-wide pgrep of the harness name.
    if [ "$(fm_backend_agent_alive "$backend" "$state_target")" = alive ]; then
      pr_outcome_write "$incident" "started" "successor-alive" || true
      rm -f -- "$PR_DIR/launch/$incident.argv" "$PR_DIR/launch/$incident.cmd" 2>/dev/null || true
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  pr_outcome_write "$incident" "failed" "successor-not-alive"
  return 1
}

# --- main ---------------------------------------------------------------------

cmd=${1:-}
[ -n "$cmd" ] || die_usage "command required"
shift || true

case "$cmd" in
  --help|-h) usage; exit 0 ;;
  observe) action_observe "$@"; exit $? ;;
  arm) action_arm "$@"; exit $? ;;
  check) action_check "$@"; exit $? ;;
  commit) action_commit "$@"; exit $? ;;
  helper) action_helper "$@"; exit $? ;;
  *) die_usage "unknown command: $cmd" ;;
esac
