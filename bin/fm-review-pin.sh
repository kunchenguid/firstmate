#!/usr/bin/env bash
# fm-review-pin.sh - quota-aware pin of the shared no-mistakes review agent.
#
# Usage:
#   fm-review-pin.sh resolve [--snapshot <path>] [--repo <dir>]
#   fm-review-pin.sh pin --task <id> [--snapshot <path>] [--repo <dir>]
#   fm-review-pin.sh restore --task <id>
#   fm-review-pin.sh status
#
# resolve  Read ONE quota-axi JSON snapshot (from --snapshot, else one
#          `quota-axi --json` call), walk the accepted list in
#          $FM_HOME/config/review-dispatch.json in order, and print the first
#          candidate that is not in the low-tank band as
#          "<agent> <model> <effort>" (effort is "-" when the candidate has
#          none). One "skip ..." or "pick ..." reason line per candidate goes to
#          stderr. Writes nothing. Prints "none" and exits 1 when every candidate
#          is skipped; firstmate then decides instead of the helper guessing.
# pin      resolve, then write the shared no-mistakes agent pin. Refuses while
#          another pin is held or while any no-mistakes review is in flight.
#          Re-running pin for the task that already holds an unchanged pin is a
#          no-op success. Firstmate runs this before triggering a no-mistakes
#          validation; project workers never hand-edit the pin.
# restore  Put the config bytes saved by pin back and release the pin. Refuses
#          when the caller's --task is not the holder, when the config no longer
#          matches what pin wrote, or while any review is still in flight.
# status   Print "free" or the held record, then the reviews in flight.
#
# Configuration. docs/configuration.md "Review dispatch" owns the schema of
# config/review-dispatch.json; this header owns only how the helper reads it.
# `default` is the accepted list. A concrete entry is {harness, model, effort?,
# provider?}. A group entry is {harness, use: [{model, effort?}...], provider?}
# and expands in place to one concrete candidate per `use` item, so a group is
# reached only after every earlier candidate was skipped. Optional
# `codexReviewFloorPercent` (default 20) and `lowTankPercent` (default 20) are
# whole percentages.
#
# Selection. Each candidate is judged against the quota-axi rows of its
# provider: the provider-wide all_models/all_products scope plus the exact
# model:<m>/product:<m> scope for the candidate's model with any
# "<provider>/" prefix removed. The most constraining known row decides.
# A candidate is in the low-tank band, and skipped, when its quota is known and
#   - any applicable runway is exhausted_now or the remaining percent is 0;
#   - its provider is codex and the remaining percent is under
#     codexReviewFloorPercent, or any applicable runway is projected_exhaustion
#     (it will run out before reset);
#   - otherwise the remaining percent is under lowTankPercent.
# Unknown quota (no provider row, no applicable scope, or an unmeasured scope)
# is disclosed uncertainty: the candidate stays eligible and the reason line
# says so. The helper never ranks, never reorders, and never invents a route.
#
# Provider derivation, when the entry has no explicit `provider`:
#   claude -> claude, codex -> codex, cursor -> cursor, grok -> grok;
#   pi, pi-signed, opencode -> by model prefix: openai-codex/ -> codex,
#   anthropic/ or claude-bridge/ -> claude, xai/ -> grok; any other prefix has
#   no provider and reads as unknown quota.
# Agent derivation (the no-mistakes `agent:` value) from the harness:
#   pi and pi-signed -> pi; claude, codex, cursor, grok, opencode -> themselves.
#   Any other harness is a configuration error.
# With --repo <dir>, a candidate whose agent is not codex, claude, or pi is
# skipped when <dir>/.no-mistakes.yaml sets `disable_project_settings: true`,
# because no-mistakes refuses every other gate agent in such a repository.
#
# Pin mechanics. The pin is $NM_HOME/config.yaml (NM_HOME defaults to
# ~/.no-mistakes), shared by every home and lane on this machine. pin saves the
# current bytes, removes the top-level `agent`, `agent_config`, and
# `agent_args_override` keys (the last one because any flag there beats the
# same knob in agent_config), keeps every other line and every comment, and
# appends one managed block:
#   # >>> firstmate review pin ... >>>
#   agent: <agent>
#   agent_config:
#     <agent>:
#       model: <model>
#       effort: <effort>        (omitted when the candidate has no effort)
#   # <<< firstmate review pin <<<
# The file is replaced atomically with its previous mode. The record lives in
# $NM_HOME/firstmate-review-pin/: `held` (task, home, agent, model, effort,
# since), `previous.yaml` (the saved bytes), and `pinned.yaml` (the bytes
# written, which restore compares against the live file before touching it).
#
# Lock and in-flight rule. pin and restore serialize on the mkdir lock
# $NM_HOME/firstmate-review-pin/lock, reclaimed only when its recorded pid is
# dead. A review is in flight when $NM_HOME/state.sqlite has a run whose status
# is not completed, failed, aborted, or cancelled and which still has a step
# other than `ci` that is not completed, skipped, or failed; a run that only
# monitors CI is not in flight, so a later CI repair uses whatever agent is
# pinned at that time. A missing database means nothing ever ran; a query
# error, or a missing sqlite3, refuses because nothing can be proven. To release
# a pin whose run died, abort that run through no-mistakes first, then restore.
#
# Exit status: 0 success; 1 no eligible candidate; 2 usage, configuration,
# snapshot, or environment error; 3 refused (pin held by another task, review
# in flight, or the live config no longer matches the pin).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
NM_HOME="${NM_HOME:-$HOME/.no-mistakes}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

CONFIG="$FM_HOME/config/review-dispatch.json"
NM_CONFIG="$NM_HOME/config.yaml"
NM_DB="$NM_HOME/state.sqlite"
PIN_DIR="$NM_HOME/firstmate-review-pin"
LOCK_DIR="$PIN_DIR/lock"
HELD="$PIN_DIR/held"
PREVIOUS="$PIN_DIR/previous.yaml"
PINNED="$PIN_DIR/pinned.yaml"
MARK_OPEN='# >>> firstmate review pin - written by bin/fm-review-pin.sh; project workers must not hand-edit >>>'
MARK_CLOSE='# <<< firstmate review pin <<<'
QUOTA_TIMEOUT=60
DEFAULT_CODEX_FLOOR=20
DEFAULT_LOW_TANK=20

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'fm-review-pin: %s\n' "$1" >&2; exit 2; }
refuse() { printf 'fm-review-pin: refused: %s\n' "$1" >&2; exit 3; }

COMMAND=${1-}
[ -n "$COMMAND" ] || usage
shift

TASK=
SNAPSHOT_SOURCE=
REPO=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)
      [ -n "${2-}" ] || die "--task needs a value"
      TASK=$2; shift 2 ;;
    --snapshot)
      [ -n "${2-}" ] || die "--snapshot needs a path"
      SNAPSHOT_SOURCE=$2; shift 2 ;;
    --repo)
      [ -n "${2-}" ] || die "--repo needs a directory"
      REPO=$2; shift 2 ;;
    -h|--help|help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$COMMAND" in
  resolve|pin|restore|status) ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $COMMAND" ;;
esac

case "$COMMAND" in
  pin|restore)
    [ -n "$TASK" ] || die "$COMMAND needs --task <id>"
    case "$TASK" in
      *[!A-Za-z0-9._-]*) die "invalid task id: $TASK" ;;
    esac ;;
esac
[ -z "$REPO" ] || [ -d "$REPO" ] || die "--repo is not a directory: $REPO"
command -v jq >/dev/null 2>&1 || die "jq is required"

# ---------------------------------------------------------------------------
# Configuration and quota reading
# ---------------------------------------------------------------------------

load_config() {
  [ -f "$CONFIG" ] || die "no accepted list: $CONFIG is absent"
  CONFIG_JSON=$(cat -- "$CONFIG") || die "cannot read $CONFIG"
  printf '%s\n' "$CONFIG_JSON" | jq -e '
    def token_ok: type == "string" and test("^[A-Za-z0-9._/:-]+$");
    def effort_ok: (has("effort") | not) or
      (.effort | type == "string" and IN("minimal", "low", "medium", "high", "xhigh", "max"));
    def profile_ok: type == "object" and (.model | token_ok) and effort_ok;
    def percent_ok($k): (has($k) | not) or ((.[$k] | type) == "number" and .[$k] >= 0 and .[$k] <= 100);
    type == "object" and
    percent_ok("codexReviewFloorPercent") and percent_ok("lowTankPercent") and
    (.default | type) == "array" and (.default | length) > 0 and
    all(.default[];
      type == "object" and
      (.harness | type == "string" and test("^[a-z][a-z0-9-]*$")) and
      ((has("provider") | not) or (.provider | type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$"))) and
      (if has("use") then
         (has("model") | not) and (has("effort") | not) and
         (.use | type) == "array" and (.use | length) > 0 and all(.use[]; profile_ok)
       else profile_ok end))
  ' >/dev/null 2>&1 || die "invalid accepted list in $CONFIG (schema: docs/configuration.md \"Review dispatch\")"
}

load_snapshot() {
  if [ -n "$SNAPSHOT_SOURCE" ]; then
    [ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] || die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
    QUOTA_JSON=$(cat -- "$SNAPSHOT_SOURCE") || die "cannot read snapshot: $SNAPSHOT_SOURCE"
  else
    command -v quota-axi >/dev/null 2>&1 || die "quota-axi is required when --snapshot is omitted"
    QUOTA_JSON=$(fm_run_timed "$QUOTA_TIMEOUT" quota-axi --json 2>/dev/null </dev/null) ||
      die "quota-axi --json failed or exceeded ${QUOTA_TIMEOUT}s"
  fi
  [ -n "$QUOTA_JSON" ] || die "empty quota snapshot"
  printf '%s\n' "$QUOTA_JSON" | fm_quota_json_valid || die "invalid quota-axi JSON snapshot"
}

repo_locks_agents() {
  [ -n "$REPO" ] || return 1
  [ -f "$REPO/.no-mistakes.yaml" ] || return 1
  grep -Eq '^disable_project_settings:[[:space:]]*true[[:space:]]*(#.*)?$' "$REPO/.no-mistakes.yaml"
}

# Emit one JSON decision per candidate, in accepted order:
#   {kind: "skip"|"pick", harness, agent, model, effort, reason}
# The walk stops at the first pick.
resolve_decisions() {
  local locked=false
  repo_locks_agents && locked=true
  jq -c -n \
    --argjson cfg "$CONFIG_JSON" \
    --argjson quota "$QUOTA_JSON" \
    --argjson locked "$locked" \
    --argjson codex_floor_default "$DEFAULT_CODEX_FLOOR" \
    --argjson low_tank_default "$DEFAULT_LOW_TANK" '
    ($cfg.codexReviewFloorPercent // $codex_floor_default) as $codex_floor |
    ($cfg.lowTankPercent // $low_tank_default) as $low_tank |
    def agent_for($h):
      {"pi": "pi", "pi-signed": "pi", "claude": "claude", "codex": "codex",
       "cursor": "cursor", "grok": "grok", "opencode": "opencode"}[$h];
    def provider_for($h; $m):
      if $h == "claude" then "claude"
      elif $h == "codex" then "codex"
      elif $h == "cursor" then "cursor"
      elif $h == "grok" then "grok"
      elif ($h == "pi" or $h == "pi-signed" or $h == "opencode") then
        if ($m | startswith("openai-codex/")) then "codex"
        elif ($m | startswith("anthropic/") or startswith("claude-bridge/")) then "claude"
        elif ($m | startswith("xai/")) then "grok"
        else null end
      else null end;
    def model_token($m): $m | sub("^[a-z0-9-]+/"; "");
    def evidence($provider; $m):
      if $provider == null then {status: "unknown", detail: "no quota provider is derivable for this model"}
      else
        ([$quota.providers[]? | select(.provider == $provider)] | first) as $p |
        if $p == null then {status: "unknown", detail: "quota-axi has no row for provider \($provider)"}
        else
          (model_token($m)) as $tok |
          [($p.quotaSemantics.effectiveAvailability // [])[] |
            select(.scope == "all_models" or .scope == "all_products" or
                   .scope == "model:\($tok)" or .scope == "product:\($tok)")] as $app |
          (if ($p.state.status // "fresh") != "fresh" then
             " (quota-axi state \($p.state.status)\(if $p.state.error then ": \($p.state.error)" else "" end))"
           else "" end) as $state_note |
          if ($app | length) == 0 then {status: "unknown", detail: "no applicable quota scope for \($provider)\($state_note)"}
          else
            [$app[] | select((.runway.status // "") == "exhausted_now")] as $exh |
            [$app[] | select(.status == "known")] as $known |
            if ($exh | length) > 0 then
              {status: "known", exhausted: true, pct: 0, runway: "exhausted_now", scope: $exh[0].scope, projected: false}
            elif ($known | length) == 0 then {status: "unknown", detail: "quota scope unmeasured for \($provider)"}
            else
              ($known | min_by(.effectivePercentRemaining)) as $lim |
              {status: "known",
               exhausted: ($lim.effectivePercentRemaining == 0),
               pct: $lim.effectivePercentRemaining,
               runway: ($lim.runway.status // "unknown"),
               scope: $lim.scope,
               projected: any($known[]; (.runway.status // "") == "projected_exhaustion")}
            end
          end
        end
      end;
    def judge($provider; $ev):
      if $ev.status != "known" then {low: false, why: "quota unknown (\($ev.detail)); eligible with disclosed uncertainty"}
      elif $ev.exhausted then {low: true, why: "\($provider) \($ev.scope) exhausted"}
      elif $provider == "codex" and $ev.pct < $codex_floor then
        {low: true, why: "codex \($ev.scope) \($ev.pct)% is under the review floor \($codex_floor)%"}
      elif $provider == "codex" and $ev.projected then
        {low: true, why: "codex \($ev.scope) \($ev.pct)% will run out before reset (projected_exhaustion)"}
      elif $ev.pct < $low_tank then
        {low: true, why: "\($provider) \($ev.scope) \($ev.pct)% is in the low-tank band (under \($low_tank)%)"}
      else {low: false, why: "\($provider) \($ev.scope) \($ev.pct)% \($ev.runway)"} end;
    [ $cfg.default[] |
      if has("use") then . as $g | $g.use[] | {harness: $g.harness, provider: $g.provider, model, effort}
      else {harness, provider, model, effort} end ] as $candidates |
    reduce $candidates[] as $c ({picked: false, out: []};
      if .picked then .
      else
        (agent_for($c.harness)) as $agent |
        if $agent == null then error("harness \($c.harness) has no no-mistakes agent")
        else
          ($c.provider // provider_for($c.harness; $c.model)) as $provider |
          (evidence($provider; $c.model)) as $ev |
          (judge($provider; $ev)) as $j |
          {harness: $c.harness, agent: $agent, model: $c.model, effort: ($c.effort // "-")} as $base |
          if $locked and ($agent | IN("codex", "claude", "pi") | not) then
            .out += [$base + {kind: "skip", reason: "repo sets disable_project_settings: true and no-mistakes accepts only codex, claude, or pi as gate agent there"}]
          elif $j.low then .out += [$base + {kind: "skip", reason: $j.why}]
          else .picked = true | .out += [$base + {kind: "pick", reason: $j.why}]
          end
        end
      end) | .out[]
  '
}

# Sets PICK_AGENT, PICK_MODEL, PICK_EFFORT from the decisions, printing reasons
# to stderr. Returns 1 when nothing was picked.
resolve_pick() {
  local decisions line kind harness agent model effort reason
  decisions=$(resolve_decisions 2>&1) || die "${decisions#jq: error (at <unknown>): }"
  PICK_AGENT=''
  PICK_MODEL=''
  PICK_EFFORT=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=$(printf '%s\n' "$line" | jq -r '.kind')
    harness=$(printf '%s\n' "$line" | jq -r '.harness')
    agent=$(printf '%s\n' "$line" | jq -r '.agent')
    model=$(printf '%s\n' "$line" | jq -r '.model')
    effort=$(printf '%s\n' "$line" | jq -r '.effort')
    reason=$(printf '%s\n' "$line" | jq -r '.reason')
    printf '%s %s %s %s: %s\n' "$kind" "$harness" "$model" "$effort" "$reason" >&2
    if [ "$kind" = pick ]; then
      PICK_AGENT=$agent PICK_MODEL=$model PICK_EFFORT=$effort
    fi
  done <<EOF
$decisions
EOF
  [ -n "$PICK_AGENT" ]
}

# ---------------------------------------------------------------------------
# Pin record, lock, and in-flight detection
# ---------------------------------------------------------------------------

LOCK_OWNED=0
release_lock() {
  [ "$LOCK_OWNED" -eq 1 ] || return 0
  rm -rf -- "$LOCK_DIR"
  LOCK_OWNED=0
}
trap release_lock EXIT

acquire_lock() {
  local pid attempt
  [ -d "$PIN_DIR" ] || mkdir -m 0700 -- "$PIN_DIR" || die "cannot create $PIN_DIR"
  for attempt in 1 2; do
    if mkdir -- "$LOCK_DIR" 2>/dev/null; then
      LOCK_OWNED=1
      printf '%s\n' "$$" > "$LOCK_DIR/pid"
      return 0
    fi
    pid=$(cat -- "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) if kill -0 "$pid" 2>/dev/null; then
           refuse "another pin operation is in progress (pid $pid)"
         fi ;;
    esac
    [ "$attempt" -eq 2 ] || rm -rf -- "$LOCK_DIR"
  done
  refuse "cannot acquire $LOCK_DIR"
}

held_field() {  # <key>
  sed -n "s/^$1=//p" "$HELD" 2>/dev/null | head -1
}

# Print one "<run id> <branch> <step>:<status>" line per review in flight.
# Returns 0 when at least one is printed, 1 when none, 2 when unprovable.
reviews_in_flight() {
  local out
  [ -e "$NM_DB" ] || return 1
  command -v sqlite3 >/dev/null 2>&1 || { printf 'sqlite3 is not installed\n' >&2; return 2; }
  out=$(sqlite3 -readonly -separator ' ' "$NM_DB" '.timeout 3000' "
    SELECT r.id, r.branch, s.step_name || ':' || s.status
    FROM runs r JOIN step_results s ON s.run_id = r.id
    WHERE r.status NOT IN ('completed', 'failed', 'aborted', 'cancelled')
      AND s.step_name <> 'ci'
      AND s.status NOT IN ('completed', 'skipped', 'failed')
    ORDER BY r.id, s.step_order;" 2>&1) || { printf '%s\n' "$out" >&2; return 2; }
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

require_no_review_in_flight() {  # <verb>
  local listing status
  listing=$(reviews_in_flight)
  status=$?
  case "$status" in
    0) printf '%s\n' "$listing" >&2
       refuse "a review is in flight; $1 would change its agent mid-run" ;;
    1) return 0 ;;
    *) refuse "cannot prove no review is in flight ($NM_DB)" ;;
  esac
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# Replace $NM_CONFIG atomically with the contents of file $1, keeping the mode
# the live file had (0644 when it cannot be read).
install_config() {  # <source-file>
  local mode tmp
  mode=$(path_mode "$NM_CONFIG")
  case "$mode" in
    ''|*[!0-7]*) mode=644 ;;
  esac
  tmp=$(mktemp "$NM_HOME/.config.yaml.fm-review-pin.XXXXXX") || die "cannot create a temporary file in $NM_HOME"
  if ! { cat -- "$1" > "$tmp" && chmod "$mode" "$tmp" && mv -f -- "$tmp" "$NM_CONFIG"; }; then
    rm -f -- "$tmp"
    die "cannot write $NM_CONFIG"
  fi
}

# Print $1 without the top-level agent, agent_config, and agent_args_override
# keys, their values, and any earlier managed-block markers. Column-0 comments
# are always kept; blank lines inside a removed block go with it.
strip_pin_keys() {  # <yaml-file>
  awk -v mark_open="$MARK_OPEN" -v mark_close="$MARK_CLOSE" '
    { line[NR] = $0 }
    END {
      cur = ""; npend = 0
      for (i = 1; i <= NR; i++) {
        l = line[i]
        if (l == mark_open || l == mark_close) { drop[i] = 1; continue }
        if (l ~ /^#/) { continue }
        if (l ~ /^[A-Za-z_][A-Za-z0-9_-]*:/) {
          npend = 0
          split(l, parts, ":"); cur = parts[1]
          owner[i] = cur
        } else if (l ~ /^[ \t]/ || l ~ /^- / || l == "-") {
          for (p = 1; p <= npend; p++) owner[pend[p]] = cur
          npend = 0
          owner[i] = cur
        } else if (l ~ /^[ \t]*$/) {
          pend[++npend] = i
        } else {
          npend = 0; cur = ""
        }
      }
      for (i = 1; i <= NR; i++) {
        if (drop[i]) continue
        o = (i in owner) ? owner[i] : ""
        if (o == "agent" || o == "agent_config" || o == "agent_args_override") continue
        print line[i]
      }
    }
  ' "$1"
}

write_pinned_file() {  # <previous-file> <out-file>
  {
    strip_pin_keys "$1"
    printf '%s\n' "$MARK_OPEN"
    printf 'agent: %s\n' "$PICK_AGENT"
    printf 'agent_config:\n'
    printf '  %s:\n' "$PICK_AGENT"
    printf '    model: %s\n' "$PICK_MODEL"
    [ "$PICK_EFFORT" = "-" ] || printf '    effort: %s\n' "$PICK_EFFORT"
    printf '%s\n' "$MARK_CLOSE"
  } > "$2"
}

print_pick() {
  printf '%s %s %s\n' "$PICK_AGENT" "$PICK_MODEL" "$PICK_EFFORT"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_resolve() {
  load_config
  load_snapshot
  if resolve_pick; then
    print_pick
    return 0
  fi
  printf 'none\n'
  return 1
}

cmd_pin() {
  load_config
  load_snapshot
  [ -f "$NM_CONFIG" ] || die "no shared no-mistakes config to pin: $NM_CONFIG is absent"
  if ! resolve_pick; then
    printf 'none\n'
    return 1
  fi
  acquire_lock
  if [ -f "$HELD" ]; then
    if [ "$(held_field task)" = "$TASK" ] && cmp -s -- "$NM_CONFIG" "$PINNED"; then
      printf 'fm-review-pin: already pinned by task %s\n' "$TASK" >&2
      PICK_AGENT=$(held_field agent) PICK_MODEL=$(held_field model) PICK_EFFORT=$(held_field effort)
      print_pick
      return 0
    fi
    refuse "pin held by task $(held_field task) from $(held_field home) since $(held_field since); restore it first"
  fi
  require_no_review_in_flight "pinning"
  local tmp_prev tmp_pinned
  tmp_prev=$(mktemp "$PIN_DIR/.previous.XXXXXX") || die "cannot write under $PIN_DIR"
  tmp_pinned=$(mktemp "$PIN_DIR/.pinned.XXXXXX") || die "cannot write under $PIN_DIR"
  cat -- "$NM_CONFIG" > "$tmp_prev" || die "cannot read $NM_CONFIG"
  write_pinned_file "$tmp_prev" "$tmp_pinned"
  chmod 0600 "$tmp_prev" "$tmp_pinned"
  mv -f -- "$tmp_prev" "$PREVIOUS"
  mv -f -- "$tmp_pinned" "$PINNED"
  install_config "$PINNED"
  {
    printf 'task=%s\n' "$TASK"
    printf 'home=%s\n' "$FM_HOME"
    printf 'agent=%s\n' "$PICK_AGENT"
    printf 'model=%s\n' "$PICK_MODEL"
    printf 'effort=%s\n' "$PICK_EFFORT"
    printf 'since=%s\n' "$(date +%s)"
  } > "$HELD.tmp" && chmod 0600 "$HELD.tmp" && mv -f -- "$HELD.tmp" "$HELD"
  printf 'fm-review-pin: pinned %s for task %s; previous config saved at %s\n' "$NM_CONFIG" "$TASK" "$PREVIOUS" >&2
  print_pick
}

cmd_restore() {
  acquire_lock
  [ -f "$HELD" ] || refuse "no pin is held"
  [ "$(held_field task)" = "$TASK" ] ||
    refuse "pin held by task $(held_field task), not $TASK"
  [ -f "$PREVIOUS" ] && [ -f "$PINNED" ] || die "pin record is incomplete under $PIN_DIR"
  cmp -s -- "$NM_CONFIG" "$PINNED" ||
    refuse "$NM_CONFIG changed since the pin was written; reconcile it by hand against $PREVIOUS, then remove $HELD"
  require_no_review_in_flight "restoring"
  install_config "$PREVIOUS"
  rm -f -- "$HELD" "$PREVIOUS" "$PINNED"
  printf 'fm-review-pin: restored %s and released the pin held by task %s\n' "$NM_CONFIG" "$TASK" >&2
  printf 'restored\n'
}

cmd_status() {
  local listing status
  if [ -f "$HELD" ]; then
    printf 'held task=%s home=%s agent=%s model=%s effort=%s since=%s\n' \
      "$(held_field task)" "$(held_field home)" "$(held_field agent)" \
      "$(held_field model)" "$(held_field effort)" "$(held_field since)"
  else
    printf 'free\n'
  fi
  listing=$(reviews_in_flight)
  status=$?
  case "$status" in
    0) printf 'in-flight:\n'; printf '%s\n' "$listing" | sed 's/^/  /' ;;
    1) printf 'in-flight: none\n' ;;
    *) printf 'in-flight: unknown\n' ;;
  esac
}

case "$COMMAND" in
  resolve) cmd_resolve ;;
  pin) cmd_pin ;;
  restore) cmd_restore ;;
  status) cmd_status ;;
esac
