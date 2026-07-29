#!/usr/bin/env bash
# fm-admission-lib.sh - shared fleet-admission policy reader and schema validator.
#
# ONE owner of "is this home's `_scheduling.admission_control` policy present,
# inert, or valid?" so bin/fm-bootstrap.sh's startup diagnostic and
# bin/fm-admission.sh's evaluator cannot drift apart on the same config bytes.
# The per-field schema and its operator-facing semantics are owned by
# docs/configuration.md "Fleet admission control"; this file owns the executable
# check of that schema.
# Sourced by scripts and has no side effects on source.
#
# Policy lives in the optional local `config/crew-dispatch.json` under
# `_scheduling.admission_control`. Keys beginning with `_` are operator notes and
# are ignored, matching the surrounding scheduling config's existing convention.
#
# Configured states (fm_admission_state):
#   absent  - no config file, no `_scheduling`, or no `admission_control` object.
#   inert   - the object carries only notes, or `enabled` is false.
#   active  - a valid, enabled policy.
#   invalid - the object failed schema validation; the reason is on stdout of
#             fm_admission_validate_reason. An invalid policy never resolves to a
#             band: callers refuse rather than admitting on unreadable policy.

# Print the resolved crew-dispatch config path for a config dir.
fm_admission_config_file() {  # <config-dir>
  printf '%s\n' "$1/crew-dispatch.json"
}

# The single jq schema program. Prints one reason line when the policy is
# malformed and nothing when it is valid or absent.
# shellcheck disable=SC2016  # jq program, not shell expansion.
FM_ADMISSION_VALIDATE_JQ='
def real_keys($o): ($o | keys_unsorted | map(select(startswith("_") | not)));
def unknown($o; $allowed): (real_keys($o) - $allowed);
def isbool($v): ($v | type) == "boolean";
def isstr($v): (($v | type) == "string") and (($v | length) > 0);
def isobj($v): ($v | type) == "object";
def nullable_num($v): ($v == null) or ((($v | type) == "number") and ($v >= 0));
def band_value($v): ["soft","hard"] | index($v);

def signal_source: {
  census_integrity: "fresh-authority-census",
  backlog_consistency: "main-inventory",
  admission_queue_pressure: "tasks-axi-load-holds-plus-ledger",
  coordination_debt: "wake-outcome-ledger",
  active_workers: "fresh-authority-census",
  host_resources: "node-summaries",
  reservation_pressure: "admission-registry"
};
def signal_keys: {
  census_integrity: ["enabled","required","source","unknown_band","max_snapshot_age_seconds"],
  backlog_consistency: ["enabled","enforce","source","unknown_band"],
  admission_queue_pressure: ["enabled","enforce","source","queued_soft_count","queued_hard_count","oldest_wait_soft_seconds","oldest_wait_hard_seconds"],
  coordination_debt: ["enabled","enforce","source","pending_wakes_soft_count","pending_wakes_hard_count","oldest_unhandled_wake_soft_seconds","oldest_unhandled_wake_hard_seconds","handled_wake_latency_window_seconds","handled_wake_latency_soft_seconds","handled_wake_latency_hard_seconds"],
  active_workers: ["enabled","enforce","source","soft_count","hard_count"],
  host_resources: ["enabled","enforce","source","metrics"],
  reservation_pressure: ["enabled","enforce","source","soft_count","hard_count"]
};
# Sources with no collector on this machine today. Enabling one would record an
# invented value instead of an observation, so the schema refuses it outright.
def uncollectable_signals: ["coordination_debt","host_resources","reservation_pressure"];
def threshold_pairs: {
  admission_queue_pressure: [["queued_soft_count","queued_hard_count"],["oldest_wait_soft_seconds","oldest_wait_hard_seconds"]],
  coordination_debt: [["pending_wakes_soft_count","pending_wakes_hard_count"],["oldest_unhandled_wake_soft_seconds","oldest_unhandled_wake_hard_seconds"],["handled_wake_latency_soft_seconds","handled_wake_latency_hard_seconds"]],
  active_workers: [["soft_count","hard_count"]],
  reservation_pressure: [["soft_count","hard_count"]]
};

def top_keys: ["schema_version","enabled","enforcement_mode","fleet_id","combine","severity_order","unknown_band","bands","signals","authority","reservations","queue","notifications","telemetry","dormant_triggers"];

def signal_error($name; $sig):
  if (isobj($sig) | not) then "signals.\($name) must be an object"
  elif ((unknown($sig; signal_keys[$name])) | length) > 0 then
    "unknown signals.\($name) field: " + ((unknown($sig; signal_keys[$name])) | join(", "))
  elif (isbool($sig.enabled) | not) then "signals.\($name).enabled must be a boolean"
  elif ($sig.source != signal_source[$name]) then
    "signals.\($name).source must be \"\(signal_source[$name])\""
  elif ($sig | has("enforce")) and (isbool($sig.enforce) | not) then
    "signals.\($name).enforce must be a boolean"
  elif ($sig | has("required")) and (isbool($sig.required) | not) then
    "signals.\($name).required must be a boolean"
  elif ($sig | has("unknown_band")) and (band_value($sig.unknown_band) | not) then
    "signals.\($name).unknown_band must be soft or hard"
  elif ($sig | has("metrics")) and (isobj($sig.metrics) | not) then
    "signals.\($name).metrics must be an object"
  elif ([signal_keys[$name][] | select(endswith("_count") or endswith("_seconds"))
         | select(nullable_num($sig[.]) | not)] | length) > 0 then
    "signals.\($name) thresholds must be null or a non-negative number: "
      + ([signal_keys[$name][] | select(endswith("_count") or endswith("_seconds"))
          | select(nullable_num($sig[.]) | not)] | join(", "))
  elif ([threshold_pairs[$name] // [] | .[]
         | select(($sig[.[0]] != null) and ($sig[.[1]] != null) and ($sig[.[0]] > $sig[.[1]]))
         | .[0]] | length) > 0 then
    "signals.\($name) soft threshold must not be more restrictive than hard: "
      + ([threshold_pairs[$name] // [] | .[]
          | select(($sig[.[0]] != null) and ($sig[.[1]] != null) and ($sig[.[0]] > $sig[.[1]]))
          | .[0]] | join(", "))
  elif ($sig.enabled == true) and (uncollectable_signals | index($name)) then
    "signals.\($name) cannot be enabled: its \(signal_source[$name]) source is not collectable yet"
  elif ($sig.enforce == true) and ($sig.enabled != true) then
    "signals.\($name).enforce requires enabled"
  else empty
  end;

def band_error($name; $band; $action):
  if (isobj($band) | not) then "bands.\($name) must be an object"
  elif ($band.action != $action) then "bands.\($name).action must be \"\($action)\""
  elif ($name != "preferred") and ($band.hold_kind != "load") then
    "bands.\($name).hold_kind must be \"load\""
  elif ($band | has("auto_reconsider")) and (isbool($band.auto_reconsider) | not) then
    "bands.\($name).auto_reconsider must be a boolean"
  elif ((unknown($band; ["action","hold_kind","auto_reconsider"])) | length) > 0 then
    "unknown bands.\($name) field: " + ((unknown($band; ["action","hold_kind","auto_reconsider"])) | join(", "))
  else empty
  end;

def structure_error:
  . as $a
  | if ((unknown($a; top_keys)) | length) > 0 then
      "unknown field: " + ((unknown($a; top_keys)) | join(", "))
    elif ($a.schema_version != 1) then "schema_version must be 1"
    elif (isbool($a.enabled) | not) then "enabled must be a boolean"
    elif ($a.enforcement_mode != "safety-only") then
      "enforcement_mode must be \"safety-only\" until an evidence-gated mode is added"
    elif (isstr($a.fleet_id) | not) then "fleet_id must be a non-empty string"
    elif ($a.combine != "most_restrictive") then
      "combine must be \"most_restrictive\" so no averaging can hide a hard result"
    elif ($a.severity_order != ["preferred","soft","hard"]) then
      "severity_order must be [\"preferred\",\"soft\",\"hard\"]"
    elif (band_value($a.unknown_band) | not) then "unknown_band must be soft or hard"
    elif ($a.enabled == true) and ([("bands","signals","authority","queue","telemetry")
           | . as $k | select(($a | has($k)) | not)] | length) > 0 then
      "an enabled policy needs " + ([("bands","signals","authority","queue","telemetry")
        | . as $k | select(($a | has($k)) | not)] | join(", "))
    else empty
    end;

def bands_error:
  . as $a
  | if ($a | has("bands") | not) then empty
    elif (isobj($a.bands) | not) then "bands must be an object"
    elif ((unknown($a.bands; ["preferred","soft","hard"])) | length) > 0 then
      "unknown bands field: " + ((unknown($a.bands; ["preferred","soft","hard"])) | join(", "))
    elif ([("preferred","soft","hard") | . as $k | select(($a.bands | has($k)) | not)] | length) > 0 then
      "bands needs " + ([("preferred","soft","hard") | . as $k | select(($a.bands | has($k)) | not)] | join(", "))
    else
      first(band_error("preferred"; $a.bands.preferred; "admit"),
            band_error("soft"; $a.bands.soft; "queue"),
            band_error("hard"; $a.bands.hard; "refuse"))
        // empty
    end;

def signals_error:
  . as $a
  | if ($a | has("signals") | not) then empty
    elif (isobj($a.signals) | not) then "signals must be an object"
    elif ((unknown($a.signals; (signal_keys | keys))) | length) > 0 then
      "unknown signal: " + ((unknown($a.signals; (signal_keys | keys))) | join(", "))
    elif ($a.enabled == true) and (($a.signals | has("census_integrity")) | not) then
      "an enabled policy needs signals.census_integrity"
    else
      (first(real_keys($a.signals)[] as $n | signal_error($n; $a.signals[$n])) // empty)
    end;

def enforcement_error:
  . as $a
  | [real_keys($a.signals // {})[] | select(($a.signals[.].enforce // false) == true)] as $enforcing
  | if ($a.enforcement_mode == "safety-only") and (($enforcing | length) > 0) then
      "enforcement_mode safety-only forbids enforce on " + ($enforcing | join(", "))
        + "; numeric enforcement is evidence-gated and not implemented yet"
    else empty
    end;

def authority_error:
  . as $a
  | if ($a | has("authority") | not) then empty
    elif (isobj($a.authority) | not) then "authority must be an object"
    elif ((unknown($a.authority; ["mode","authority_id","config_mismatch_band","unreachable_band"])) | length) > 0 then
      "unknown authority field: " + ((unknown($a.authority; ["mode","authority_id","config_mismatch_band","unreachable_band"])) | join(", "))
    elif ($a.authority.mode != "single-primary") then
      "authority.mode must be \"single-primary\" until a second intake authority is registered"
    elif ($a.authority | has("authority_id")) and (isstr($a.authority.authority_id) | not) then
      "authority.authority_id must be a non-empty string"
    elif (band_value($a.authority.config_mismatch_band) | not) then
      "authority.config_mismatch_band must be soft or hard"
    elif (band_value($a.authority.unreachable_band) | not) then
      "authority.unreachable_band must be soft or hard"
    else empty
    end;

def reservations_error:
  . as $a
  | if ($a | has("reservations") | not) then empty
    elif (isobj($a.reservations) | not) then "reservations must be an object"
    elif ((unknown($a.reservations; ["enabled","ttl_seconds","heartbeat_seconds","clock_skew_tolerance_seconds","release_on","reconcile_on"])) | length) > 0 then
      "unknown reservations field: "
        + ((unknown($a.reservations; ["enabled","ttl_seconds","heartbeat_seconds","clock_skew_tolerance_seconds","release_on","reconcile_on"])) | join(", "))
    elif (isbool($a.reservations.enabled) | not) then "reservations.enabled must be a boolean"
    elif ([("ttl_seconds","heartbeat_seconds","clock_skew_tolerance_seconds")
           | select(nullable_num($a.reservations[.]) | not)] | length) > 0 then
      "reservations durations must be null or a non-negative number"
    elif ($a.reservations.enabled == true) then
      "reservations are dormant until a second intake authority or remote node is registered"
    else empty
    end;

def queue_error:
  . as $a
  | if ($a | has("queue") | not) then empty
    elif (isobj($a.queue) | not) then "queue must be an object"
    elif ((unknown($a.queue; ["substrate","release_triggers","already_empty_fleet_recheck"])) | length) > 0 then
      "unknown queue field: " + ((unknown($a.queue; ["substrate","release_triggers","already_empty_fleet_recheck"])) | join(", "))
    elif ($a.queue.substrate != "tasks-axi hold --kind load") then
      "queue.substrate must be \"tasks-axi hold --kind load\" - admission adds no second queue"
    elif (($a.queue.release_triggers | type) != "array")
      or (($a.queue.release_triggers | length) == 0)
      or ((($a.queue.release_triggers) - ["teardown","session-start"]) | length) > 0 then
      "queue.release_triggers must be a non-empty subset of [\"teardown\",\"session-start\"]"
    elif ($a.queue.already_empty_fleet_recheck != "session-start-only") then
      "queue.already_empty_fleet_recheck must be \"session-start-only\""
    else empty
    end;

def notifications_error:
  . as $a
  | if ($a | has("notifications") | not) then empty
    elif (isobj($a.notifications) | not) then "notifications must be an object"
    elif ((unknown($a.notifications; ["policy_ref","episode_dedupe_seconds"])) | length) > 0 then
      "unknown notifications field: " + ((unknown($a.notifications; ["policy_ref","episode_dedupe_seconds"])) | join(", "))
    elif (isstr($a.notifications.policy_ref) | not) then
      "notifications.policy_ref must be a non-empty string"
    elif (nullable_num($a.notifications.episode_dedupe_seconds) | not) then
      "notifications.episode_dedupe_seconds must be null or a non-negative number"
    else empty
    end;

def telemetry_error:
  . as $a
  | ["sink","record_every_decision","record_signal_values","record_config_paths","record_config_digest","credentials_forbidden"] as $keys
  | if ($a | has("telemetry") | not) then empty
    elif (isobj($a.telemetry) | not) then "telemetry must be an object"
    elif ((unknown($a.telemetry; $keys)) | length) > 0 then
      "unknown telemetry field: " + ((unknown($a.telemetry; $keys)) | join(", "))
    elif (isstr($a.telemetry.sink) | not) then "telemetry.sink must be a non-empty string"
    elif ([$keys[] | select(. != "sink") | select(isbool($a.telemetry[.]) | not)] | length) > 0 then
      "telemetry flags must be booleans"
    elif ($a.enabled == true) and ($a.telemetry.record_every_decision != true) then
      "telemetry.record_every_decision must be true while admission is enabled"
    elif ($a.enabled == true) and ($a.telemetry.credentials_forbidden != true) then
      "telemetry.credentials_forbidden must be true while admission is enabled"
    else empty
    end;

def dormant_error:
  . as $a
  | if ($a | has("dormant_triggers") | not) then empty
    elif (isobj($a.dormant_triggers) | not) then "dormant_triggers must be an object"
    elif ([real_keys($a.dormant_triggers)[]
           | select((isobj($a.dormant_triggers[.]) | not)
                    or (isstr($a.dormant_triggers[.].checkpoint) | not))] | length) > 0 then
      "each dormant trigger needs a named checkpoint: "
        + ([real_keys($a.dormant_triggers)[]
            | select((isobj($a.dormant_triggers[.]) | not)
                     or (isstr($a.dormant_triggers[.].checkpoint) | not))] | join(", "))
    else empty
    end;

(._scheduling // {}) as $s
| if (($s | type) != "object") then "_scheduling must be an object"
  elif (($s | has("admission_control")) | not) then empty
  elif (($s.admission_control | type) != "object") then "admission_control must be an object"
  else
    $s.admission_control as $a
    | if ((real_keys($a)) | length) == 0 then empty
      else
        first($a | structure_error, bands_error, signals_error, enforcement_error,
                   authority_error, reservations_error, queue_error,
                   notifications_error, telemetry_error, dormant_error)
          // empty
      end
  end
'

# Print the schema failure reason for <config-file>, or nothing when the policy
# is valid, absent, or note-only. Returns 1 when the file cannot be inspected at
# all (missing jq or malformed JSON) so callers can distinguish "unreadable" from
# "well-formed but wrong"; the reason is still printed.
fm_admission_validate_reason() {  # <config-file>
  local file=$1 reason
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to validate admission policy\n'
    return 1
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf 'malformed JSON\n'
    return 1
  fi
  reason=$(jq -r "$FM_ADMISSION_VALIDATE_JQ" "$file" 2>/dev/null) || {
    printf 'admission_control could not be validated\n'
    return 1
  }
  [ -n "$reason" ] && printf '%s\n' "$reason"
  return 0
}

# Print absent | inert | active | invalid for <config-file>.
fm_admission_state() {  # <config-file>
  local file=$1 reason enabled real
  if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    printf 'absent\n'
    return 0
  fi
  reason=$(fm_admission_validate_reason "$file") || { printf 'invalid\n'; return 0; }
  if [ -n "$reason" ]; then
    printf 'invalid\n'
    return 0
  fi
  real=$(jq -r '
    (._scheduling.admission_control // null)
    | if . == null then "absent"
      else ([keys_unsorted[] | select(startswith("_") | not)] | length | tostring)
      end' "$file" 2>/dev/null) || { printf 'absent\n'; return 0; }
  case "$real" in
    absent) printf 'absent\n'; return 0 ;;
    0) printf 'inert\n'; return 0 ;;
  esac
  enabled=$(jq -r '._scheduling.admission_control.enabled // false' "$file" 2>/dev/null)
  if [ "$enabled" = true ]; then printf 'active\n'; else printf 'inert\n'; fi
}

# Print the canonical admission policy object for <config-file>, or "null".
fm_admission_object() {  # <config-file>
  local file=$1
  if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    printf 'null\n'
    return 0
  fi
  jq -S -c '._scheduling.admission_control // null' "$file" 2>/dev/null || printf 'null\n'
}

# Print a stable short digest of an exact byte string, so every decision can name
# the configuration and fleet-view identities it acted on.
fm_admission_digest() {  # <canonical-bytes>
  local json=$1 sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$json" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$json" | shasum -a 256 | awk '{print $1}')
  else
    printf 'unavailable\n'
    return 0
  fi
  printf 'sha256:%s\n' "${sum:0:16}"
}
