#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule to a concrete profile.
# Usage:
#   fm-dispatch-select.sh [--select <strategy>] [--quota-json <file>]
#     [--config <file>] [--state-file <file>] [--now-epoch <seconds>]
#     [<rule-or-use-json>]
#
# Input may be a full rule object with `use` and optional `select`, a single
# profile object, or an ordered array of profile objects.
# Output is one compact JSON profile object on stdout.
#
# quota-balanced is deterministic, and this header is the single owner of its
# scoring contract:
#   - It consumes quota-axi schema version 2 through `quota-axi --json`
#     (or the --quota-json fixture).
#   - General windows have provider kind `session` or `weekly`; model-scoped and
#     code-review-scoped windows are excluded regardless of kind or duration. An
#     explicit positive windowSeconds is authoritative. Actual 5-hour and 7-day
#     durations define session and weekly capacity scope even when provider kind
#     is misleading. Claude's known five_hour and seven_day windows fall back to
#     those canonical durations because Claude omits the field. No Codex duration
#     is inferred from its misleading five_hour id.
#   - A window score is percentage-capacity headroom through its reset:
#       remaining + (100 * configured extra resets) - reserve
#         - (estimated burn per second * seconds until reset)
#     This is normalized provider-relative capacity, not a token or per-task
#     prediction. A provider's score is its lowest general-window score.
#   - On a first sample, burn is percent used divided by elapsed window time.
#     A compatible recent sample can raise that estimate from actual usage
#     delta; recentWeight controls burst sensitivity. Rollover, decreasing
#     usage, old history, or clock reversal discards the recent delta. Reset
#     time is clamped to the actual duration to contain source clock skew.
#   - The vendor with the higher score wins; an exact tie between equally
#     trusted candidates uses the first array element.
#   - Stale-but-cached general-window numbers are usable, but a fresh candidate
#     wins unless the stale candidate's score is at least the stale-clear margin
#     higher (default 20 percentage-capacity points).
#   - A vendor absent from quota output, or with no usable general windows, is
#     unavailable; selection happens among available candidates.
#   - Candidate/window scores and their inputs are logged without account data
#     so every decision is auditable.
#   - If quota-axi is missing, exits non-zero, returns unparseable JSON, has an
#     unsupported schema, or no candidate is usable, the reason is logged and
#     the first array element is printed. Quota trouble never blocks dispatch.
#
# quota-balanced uses quota-axi --json unless --quota-json supplies a
# fixture. Live calls keep private samples in state/.dispatch-quota-samples.json;
# fixture calls are stateless unless --state-file is explicit.
# The quotaBalanced object in config/crew-dispatch.json owns local tuning.
# FM_DISPATCH_QUOTA_AXI overrides the quota command.
# FM_DISPATCH_STALE_CLEAR_MARGIN overrides configured/default stale margin.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FM_DISPATCH_HOME=${FM_HOME:-$ROOT}
CONFIG_ROOT=${FM_CONFIG_OVERRIDE:-$FM_DISPATCH_HOME/config}
STATE_ROOT=${FM_STATE_OVERRIDE:-$FM_DISPATCH_HOME/state}
STALE_CLEAR_OVERRIDE=${FM_DISPATCH_STALE_CLEAR_MARGIN:-}
SELECT_OVERRIDE=
QUOTA_JSON_FILE=
CONFIG_FILE=
CONFIG_FILE_EXPLICIT=0
STATE_FILE=
STATE_FILE_EXPLICIT=0
NOW_EPOCH=
ARGS=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

log() {
  printf 'fm-dispatch-select: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --select)
      [ "$#" -gt 1 ] || { echo "error: --select requires a value" >&2; exit 2; }
      SELECT_OVERRIDE=$2
      shift 2
      ;;
    --select=*)
      SELECT_OVERRIDE=${1#--select=}
      shift
      ;;
    --quota-json)
      [ "$#" -gt 1 ] || { echo "error: --quota-json requires a file" >&2; exit 2; }
      QUOTA_JSON_FILE=$2
      shift 2
      ;;
    --quota-json=*)
      QUOTA_JSON_FILE=${1#--quota-json=}
      shift
      ;;
    --config)
      [ "$#" -gt 1 ] || { echo "error: --config requires a file" >&2; exit 2; }
      CONFIG_FILE=$2
      CONFIG_FILE_EXPLICIT=1
      shift 2
      ;;
    --config=*)
      CONFIG_FILE=${1#--config=}
      CONFIG_FILE_EXPLICIT=1
      shift
      ;;
    --state-file)
      [ "$#" -gt 1 ] || { echo "error: --state-file requires a file" >&2; exit 2; }
      STATE_FILE=$2
      STATE_FILE_EXPLICIT=1
      shift 2
      ;;
    --state-file=*)
      STATE_FILE=${1#--state-file=}
      STATE_FILE_EXPLICIT=1
      shift
      ;;
    --now-epoch)
      [ "$#" -gt 1 ] || { echo "error: --now-epoch requires seconds" >&2; exit 2; }
      NOW_EPOCH=$2
      shift 2
      ;;
    --now-epoch=*)
      NOW_EPOCH=${1#--now-epoch=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

[ "${#ARGS[@]}" -le 1 ] || { echo "error: expected at most one JSON argument" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

if [ -z "$NOW_EPOCH" ]; then
  NOW_EPOCH=$(date -u +%s)
fi
case "$NOW_EPOCH" in
  ''|*[!0-9]*) echo "error: --now-epoch must be a non-negative integer" >&2; exit 2 ;;
esac

if [ "${#ARGS[@]}" -eq 1 ]; then
  SPEC_JSON=${ARGS[0]}
else
  SPEC_JSON=$(cat)
fi

profiles_json=$(printf '%s\n' "$SPEC_JSON" | jq -ec '
  (if type == "object" and has("use") then .use else . end)
  | if type == "array" then .
    elif type == "object" then [.]
    else empty
    end
' 2>/dev/null) || { echo "error: dispatch input must be a rule, profile, or profile array" >&2; exit 2; }

profile_count=$(printf '%s\n' "$profiles_json" | jq 'length')
[ "$profile_count" -gt 0 ] || { echo "error: dispatch profile array must not be empty" >&2; exit 2; }

first_profile() {
  printf '%s\n' "$profiles_json" | jq -c '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[0])
  '
}

select_strategy=$SELECT_OVERRIDE
if [ -z "$select_strategy" ]; then
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | jq -r '
    if type == "object" and has("use") and (.select? | type) == "string" then .select else "" end
  ' 2>/dev/null || true)
fi

if [ "$select_strategy" != quota-balanced ]; then
  if [ -n "$select_strategy" ]; then
    log "unknown select strategy '$select_strategy'; using first profile"
  fi
  first_profile
  exit 0
fi

if [ "$CONFIG_FILE_EXPLICIT" -eq 0 ]; then
  CONFIG_FILE="$CONFIG_ROOT/crew-dispatch.json"
fi
if [ -f "$CONFIG_FILE" ]; then
  if ! dispatch_config=$(cat "$CONFIG_FILE" 2>/dev/null); then
    log "cannot read dispatch config; using first profile"
    first_profile
    exit 0
  fi
  if ! printf '%s\n' "$dispatch_config" | jq -e 'type == "object"' >/dev/null 2>&1; then
    log "dispatch config is invalid; using first profile"
    first_profile
    exit 0
  fi
elif [ "$CONFIG_FILE_EXPLICIT" -eq 1 ]; then
  log "cannot read dispatch config; using first profile"
  first_profile
  exit 0
else
  dispatch_config='{}'
fi

if [ -n "$QUOTA_JSON_FILE" ]; then
  if ! quota_json=$(cat "$QUOTA_JSON_FILE" 2>/dev/null); then
    log "cannot read quota JSON; using first profile"
    first_profile
    exit 0
  fi
else
  quota_cmd=${FM_DISPATCH_QUOTA_AXI:-quota-axi}
  if ! command -v "$quota_cmd" >/dev/null 2>&1; then
    log "quota-axi missing; using first profile"
    first_profile
    exit 0
  fi
  quota_json=$("$quota_cmd" --json 2>/dev/null)
  quota_status=$?
  if [ "$quota_status" -ne 0 ]; then
    log "quota-axi exited $quota_status; using first profile"
    first_profile
    exit 0
  fi
fi

if ! printf '%s\n' "$quota_json" | jq -e '
  type == "object" and .schemaVersion == 2 and (.providers | type) == "array"
' >/dev/null 2>&1; then
  log "quota-axi returned invalid or unsupported schema JSON; using first profile"
  first_profile
  exit 0
fi

if [ "$STATE_FILE_EXPLICIT" -eq 0 ] && [ -z "$QUOTA_JSON_FILE" ]; then
  STATE_FILE="$STATE_ROOT/.dispatch-quota-samples.json"
fi
history_json='{"schemaVersion":1,"samples":[]}'
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
  if candidate_history=$(cat "$STATE_FILE" 2>/dev/null) \
    && printf '%s\n' "$candidate_history" | jq -e '
      type == "object" and .schemaVersion == 1 and (.samples | type) == "array"
    ' >/dev/null 2>&1; then
    history_json=$candidate_history
  else
    log "quota sample history is invalid; ignoring it"
  fi
fi

selection=$(printf '%s\n' "$quota_json" | jq -ec \
  --argjson profiles "$profiles_json" \
  --argjson config "$dispatch_config" \
  --argjson history "$history_json" \
  --argjson now "$NOW_EPOCH" \
  --arg staleOverride "$STALE_CLEAR_OVERRIDE" '
  . as $quota
  | def clean($p):
    {harness: $p.harness}
    + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
    + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
  def clamp($n; $low; $high): if $n < $low then $low elif $n > $high then $high else $n end;
  def positive_number($v): ($v | type) == "number" and $v > 0;
  def iso_epoch($value):
    if ($value | type) != "string" then null
    else ($value
      | sub("\\+00:00$"; "Z")
      | sub("\\.[0-9]+Z$"; "Z")
      | try fromdateiso8601 catch null)
    end;
  def duration_for($provider; $window):
    if positive_number($window.windowSeconds?) then ($window.windowSeconds | floor)
    elif $provider == "claude" and $window.id == "five_hour" and $window.kind == "session" then 18000
    elif $provider == "claude" and $window.id == "seven_day" and $window.kind == "weekly" then 604800
    else null
    end;
  def scope_for($window; $duration):
    if $duration == 18000 then "session"
    elif $duration == 604800 then "weekly"
    else $window.kind
    end;
  def general_window($window):
    (($window.kind == "session" or $window.kind == "weekly")
      and (((($window.id? // "") | startswith("model:")) or
        (($window.id? // "") | startswith("code_review_"))) | not));
  def settings: ($config.quotaBalanced? // {});
  def run_settings: (settings.runRate? // {});
  def reserve_for($provider):
    (settings.providers?[$provider].reservePercent? // settings.reservePercent? // 0);
  def extra_resets($provider; $scope; $duration):
    ([settings.providers?[$provider].windows[]?
      | select(.durationSeconds == $duration and .scope == $scope)
      | (.extraResets // 0)] | add // 0);
  def history_for($provider; $id; $kind; $duration):
    [$history.samples[]?
      | select(.provider == $provider and .id == $id and .kind == $kind
        and .durationSeconds == $duration)][0];
  def window_metric($provider; $window):
    (duration_for($provider; $window)) as $duration
    | (iso_epoch($window.resetsAt?)) as $reset
    | (if ($window.percentRemaining? | type) == "number" then $window.percentRemaining
       elif ($window.percentUsed? | type) == "number" then (100 - $window.percentUsed)
       else null end) as $raw_remaining
    | if $duration == null or $reset == null or $raw_remaining == null then empty
      else
        (clamp($raw_remaining; 0; 100)) as $remaining
        | (scope_for($window; $duration)) as $scope
        | (if ($window.percentUsed? | type) == "number" then clamp($window.percentUsed; 0; 100)
           else (100 - $remaining) end) as $used
        | (clamp(($reset - $now); 0; $duration)) as $until_reset
        | ($duration - $until_reset) as $elapsed
        | (run_settings.minimumObservationSeconds? // 300) as $minimum_observation
        | (run_settings.historyMaxAgeSeconds? // 86400) as $history_max_age
        | (run_settings.recentWeight? // 1) as $recent_weight
        | (history_for($provider; ($window.id // ""); $window.kind; $duration)) as $prior
        | (($prior != null)
          and (($now - ($prior.sampledAtEpoch // ($now + 1))) > 0)
          and (($now - $prior.sampledAtEpoch) <= $history_max_age)
          and (((($prior.resetsAtEpoch // 0) - $reset) | fabs) <= 60)
          and ($used >= ($prior.percentUsed // 101))) as $recent_valid
        | ($used / ([$elapsed, $minimum_observation] | max)) as $cycle_rate
        | (if $recent_valid then
            (($used - $prior.percentUsed) / ($now - $prior.sampledAtEpoch))
          else 0 end) as $recent_rate
        | ([$cycle_rate, ($recent_rate * $recent_weight)] | max) as $burn_rate
        | (extra_resets($provider; $scope; $duration)) as $extra
        | (reserve_for($provider)) as $reserve
        | ($burn_rate * $until_reset) as $projected
        | ($remaining + (100 * $extra)) as $capacity
        | {
            id: ($window.id // ""),
            kind: $window.kind,
            scope: $scope,
            durationSeconds: $duration,
            remaining: $remaining,
            extraResets: $extra,
            reserve: $reserve,
            secondsUntilReset: $until_reset,
            burnPerHour: ($burn_rate * 3600),
            projectedBurn: $projected,
            score: ($capacity - $reserve - $projected),
            rateSource: (if $recent_valid and (($recent_rate * $recent_weight) > $cycle_rate)
              then "recent" else "cycle" end),
            clockClamped: (($reset - $now) < 0 or ($reset - $now) > $duration),
            sample: {
              provider: $provider,
              id: ($window.id // ""),
              kind: $window.kind,
              durationSeconds: $duration,
              resetsAtEpoch: $reset,
              sampledAtEpoch: $now,
              percentUsed: $used
            }
          }
      end;
  def provider_for($name): [$quota.providers[]? | select(.provider == $name)][0];
  def candidate_metric($profile; $index):
    ($profile.harness // "") as $provider_name
    | (provider_for($provider_name)) as $provider
    | if $provider == null then empty
      else
        ([$provider.windows[]?
          | select(general_window(.))
          | window_metric($provider_name; .)]) as $windows
        | if ($windows | length) == 0 then empty
          else ($windows | min_by(.score)) as $bottleneck
          | {
              index: $index,
              profile: clean($profile),
              harness: $provider_name,
              fresh: (($provider.state.status? // "") == "fresh"),
              score: $bottleneck.score,
              bottleneck: $bottleneck,
              windows: $windows
            }
          end
      end;
  def better($a; $b):
    if $a == null then $b
    elif $b == null then $a
    elif $b.score > $a.score then $b
    elif $b.score == $a.score and $b.index < $a.index then $b
    else $a
    end;
  def best($items): reduce $items[] as $item (null; better(.; $item));
  ([range(0; $profiles | length) as $index
    | candidate_metric($profiles[$index]; $index)]) as $candidates
  | (if $staleOverride == "" then (settings.staleClearMargin? // 20)
     else ($staleOverride | tonumber) end) as $stale_margin
  | if ($candidates | length) == 0 then {
      fallback: true,
      reason: "no usable quota windows for candidate vendors",
      profile: clean($profiles[0]),
      candidates: [],
      samples: []
    }
    else
      (best($candidates | map(select(.fresh)))) as $fresh_best
      | (best($candidates | map(select(.fresh | not)))) as $stale_best
      | (if $fresh_best != null and $stale_best != null then
          if $stale_best.score >= ($fresh_best.score + $stale_margin)
          then $stale_best else $fresh_best end
        elif $fresh_best != null then $fresh_best
        else $stale_best
        end) as $chosen
      | {
          fallback: false,
          profile: $chosen.profile,
          chosen: $chosen.harness,
          candidates: $candidates,
          samples: ([$candidates[] | select(.fresh) | .windows[].sample]
            | unique_by([.provider, .id, .kind, .durationSeconds]))
        }
    end
' 2>/dev/null) || {
  log "quota-axi data or quota-balanced configuration could not be evaluated; using first profile"
  first_profile
  exit 0
}

while IFS= read -r diagnostic; do
  [ -n "$diagnostic" ] && log "$diagnostic"
done < <(printf '%s\n' "$selection" | jq -r '
  .candidates[]?
  | . as $candidate
  | $candidate.windows[]
  | "quota-balanced candidate \($candidate.harness) trust=\(if $candidate.fresh then "fresh" else "stale" end)"
    + " window=\(.scope)/\(.durationSeconds)s source-kind=\(.kind) score=\(.score * 100 | round / 100)"
    + " remaining=\(.remaining) extra-resets=\(.extraResets) reserve=\(.reserve)"
    + " burn-per-hour=\(.burnPerHour * 100 | round / 100) projected=\(.projectedBurn * 100 | round / 100)"
    + " rate-source=\(.rateSource) clock-clamped=\(.clockClamped)"
')

if [ "$(printf '%s\n' "$selection" | jq -r '.fallback')" = true ]; then
  log "$(printf '%s\n' "$selection" | jq -r '.reason'); using first profile"
else
  log "quota-balanced selected $(printf '%s\n' "$selection" | jq -r '.chosen') by bottleneck sustainable-headroom score"
fi

if [ -n "$STATE_FILE" ] && [ "$(printf '%s\n' "$selection" | jq '.samples | length')" -gt 0 ]; then
  state_parent=$(dirname "$STATE_FILE")
  if mkdir -p "$state_parent" 2>/dev/null; then
    history_lock="$STATE_FILE.lock"
    # shellcheck source=bin/fm-wake-lib.sh
    FM_STATE_OVERRIDE="$state_parent" . "$ROOT/bin/fm-wake-lib.sh"
    history_lock_attempt=0
    history_lock_acquired=0
    while [ "$history_lock_attempt" -lt 10 ]; do
      if fm_lock_try_acquire "$history_lock"; then
        history_lock_acquired=1
        break
      fi
      history_lock_attempt=$((history_lock_attempt + 1))
      [ "$history_lock_attempt" -ge 10 ] || sleep 0.1
    done
    if [ "$history_lock_acquired" -eq 1 ]; then
      trap 'fm_lock_release "$history_lock"' EXIT
      current_history='{"schemaVersion":1,"samples":[]}'
      if [ -f "$STATE_FILE" ]; then
        if locked_history=$(cat "$STATE_FILE" 2>/dev/null) \
          && printf '%s\n' "$locked_history" | jq -e '
            type == "object" and .schemaVersion == 1 and (.samples | type) == "array"
          ' >/dev/null 2>&1; then
          current_history=$locked_history
        fi
      fi
      state_tmp=$(umask 077; mktemp "$state_parent/.dispatch-quota-samples.XXXXXX" 2>/dev/null) || state_tmp=
      if [ -n "$state_tmp" ]; then
        if jq -nec --argjson old "$current_history" --argjson current "$selection" '
          def key: [.provider, .id, .kind, .durationSeconds];
          {schemaVersion: 1,
           samples: ([($old.samples[]? // empty), $current.samples[]]
             | sort_by(key)
             | group_by(key)
             | map(max_by([.sampledAtEpoch, .resetsAtEpoch, .percentUsed])))}
        ' > "$state_tmp" && chmod 600 "$state_tmp" && mv "$state_tmp" "$STATE_FILE"; then
          :
        else
          rm -f "$state_tmp"
          log "could not update quota sample history; selection remains valid"
        fi
      else
        log "could not prepare quota sample history; selection remains valid"
      fi
      fm_lock_release "$history_lock"
      trap - EXIT
    else
      log "could not acquire quota sample history lock; selection remains valid"
    fi
  else
    log "could not create quota sample state directory; selection remains valid"
  fi
fi

printf '%s\n' "$selection" | jq -c '.profile'
