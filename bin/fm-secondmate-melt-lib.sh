#!/usr/bin/env bash
# fm-secondmate-melt-lib.sh - the secondmate commander-model melt owner.
#
# This library owns the deterministic decision that a live secondmate's pinned
# commander cannot serve, the quota-checked replacement profile, and the small
# pane-evidence/cooldown records used to avoid relaunch thrash. The watcher owns
# endpoint capture, lifecycle execution, parent wake publication, and the local
# versus remote transport choice.
#
# A quota snapshot is data, not a recommendation. A profile is quota-ok only
# when every applicable measured bound has positive remaining capacity and no
# bound is exhausted_now. Unknown or unmeasured quota is not enough to license
# an automatic replacement. Parent config/secondmate-harness wins when it names
# a model and is quota-ok; otherwise the default profiles in
# config/crew-dispatch.json are tried in their declared order after the same
# eligibility check. The caller must pass the replacement model explicitly.
#
# The default pane evidence threshold is two distinct pane snapshots containing
# a 429, rate-limit, or out-of-quota marker for the same pinned model. Re-reading
# one stale error screen never increments the counter. A quota snapshot can
# trigger immediately against a live endpoint even when pane text is empty. The
# default relaunch cooldown is one hour and is bound to the still-recorded
# harness/model pair written into the marker. The watcher writes that marker
# only for unsuccessful attempts (no replacement, relaunch failure) or when a
# successful relaunch could not update the still-recorded parent pin; a
# successful replacement with an updated profile must not suppress later
# quota-dead detection. A bare or mismatched marker never suppresses evaluation,
# so an ordinary restart that restores a different (still-dead) pin is not
# suppressed by a prior melt. Both constants are environment-overridable for
# tests and are documented here so the watcher does not grow a second policy
# copy.
#
# Source only. No lifecycle action occurs when this file is sourced.

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-control-lib.sh"

FM_SECONDMATE_MELT_EVIDENCE_DEFAULT=2
FM_SECONDMATE_MELT_COOLDOWN_DEFAULT=3600
FM_SECONDMATE_MELT_FORBIDDEN_MODEL_RE='(^|[-_/])sol($|[-_/])'

fm_secondmate_melt_evidence_threshold() {
  local value=${FM_SECONDMATE_MELT_EVIDENCE_COUNT:-$FM_SECONDMATE_MELT_EVIDENCE_DEFAULT}
  case "$value" in
    ''|*[!0-9]*|0) value=$FM_SECONDMATE_MELT_EVIDENCE_DEFAULT ;;
  esac
  printf '%s\n' "$value"
}

fm_secondmate_melt_cooldown_secs() {
  local value=${FM_SECONDMATE_MELT_COOLDOWN_SECS:-$FM_SECONDMATE_MELT_COOLDOWN_DEFAULT}
  case "$value" in
    ''|*[!0-9]*) value=$FM_SECONDMATE_MELT_COOLDOWN_DEFAULT ;;
  esac
  printf '%s\n' "$value"
}

fm_secondmate_melt_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_secondmate_melt_cooldown_write() { # <state-dir> <id> <harness> <model>
  local marker="$1/.secondmate-melt-cooldown-$2" harness=$3 model=$4
  [ -n "$harness" ] && [ -n "$model" ] || return 1
  printf '%s\t%s\n' "$harness" "$model" > "$marker"
}

# True only while a fresh marker names the same still-recorded harness/model.
# A bare or mismatched marker never suppresses evaluation, so a restart onto a
# restored dead pin can melt again inside the prior window. Callers should write
# the marker only for the still-recorded pin after an unsuccessful attempt.
fm_secondmate_melt_cooldown_active() { # <state-dir> <id> <harness> <model>
  local marker="$1/.secondmate-melt-cooldown-$2" harness=$3 model=$4
  local content recorded_harness recorded_model m now age
  [ -n "$harness" ] && [ -n "$model" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  content=$(cat "$marker" 2>/dev/null || true)
  case "$content" in
    *$'\t'*) ;;
    *) return 1 ;;
  esac
  recorded_harness=${content%%$'\t'*}
  recorded_model=${content#*$'\t'}
  recorded_model=${recorded_model%%$'\n'*}
  [ "$recorded_harness" = "$harness" ] && [ "$recorded_model" = "$model" ] || return 1
  m=$(fm_secondmate_melt_stat_mtime "$marker") || return 1
  now=$(date +%s)
  case "$m" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$((now - m))
  [ "$age" -ge 0 ] || age=0
  [ "$age" -lt "$(fm_secondmate_melt_cooldown_secs)" ]
}

fm_secondmate_melt_capture_has_quota_error() { # <capture>
  printf '%s\n' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | grep -Eiq \
    '(^|[^0-9])429([^0-9]|$)|out[[:space:]-]*of[[:space:]-]*quota|quota[^[:alnum:]]*(exhaust|deplet|limit)|rate[[:space:]-]*limit'
}

# Update the per-model evidence counter and print the counter. The return value
# is 0 when the repeated-evidence threshold is reached.
fm_secondmate_melt_record_evidence() { # <state-dir> <id> <model> <capture>
  local state=$1 id=$2 model=$3 capture=$4 marker previous
  local previous_model previous_count previous_hash capture_hash count
  marker="$state/.secondmate-melt-evidence-$id"
  previous=$(cat "$marker" 2>/dev/null || true)
  previous_model=${previous%%$'\t'*}
  previous=${previous#*$'\t'}
  previous_count=${previous%%$'\t'*}
  previous_hash=${previous#*$'\t'}
  case "$previous_count" in ''|*[!0-9]*) previous_count=0 ;; esac
  capture_hash=$(printf '%s' "$capture" | cksum | awk '{ print $1 ":" $2 }') || return 1
  if fm_secondmate_melt_capture_has_quota_error "$capture"; then
    if [ "$previous_model" = "$model" ] && [ "$previous_hash" = "$capture_hash" ]; then
      count=$previous_count
    elif [ "$previous_model" = "$model" ]; then
      count=$((previous_count + 1))
    else
      count=1
    fi
  else
    count=0
  fi
  printf '%s\t%s\t%s\n' "$model" "$count" "$capture_hash" > "$marker" || return 1
  printf '%s\n' "$count"
  [ "$count" -ge "$(fm_secondmate_melt_evidence_threshold)" ]
}

fm_secondmate_melt_model_forbidden() { # <model>
  local model
  model=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  [ -n "$model" ] || return 0
  printf '%s\n' "$model" | grep -Eq "$FM_SECONDMATE_MELT_FORBIDDEN_MODEL_RE"
}

# Print one of: ok, dead, unknown. The snapshot must already be captured by the
# caller so all candidate decisions use one quota-axi observation.
fm_secondmate_melt_quota_status() { # <snapshot> <harness> <model> [provider]
  local snapshot=$1 harness=$2 model=$3 provider=${4:-} lane
  if [ -z "$provider" ]; then
    provider=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null || true)
  fi
  [ -n "$provider" ] || { printf 'unknown\n'; return 0; }
  lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)' 2>/dev/null || true)
  printf '%s\n' "$snapshot" | jq -r --arg provider "$provider" --arg model "$model" --arg lane "$lane" "$FM_QUOTA_ROW_JQ"'
    quota_row(.; $provider; $lane) as $row |
    if $row == null then "unknown"
    else
      ($model | split("/") | last) as $bare |
      [($row.quotaSemantics.effectiveAvailability // [])[] | select(
        .scope == "all_models" or .scope == "all_products" or
        ($bare != "" and
          ((.scope == ("model:" + $bare)) or (.scope == ("product:" + $bare))))
      )] as $bounds |
      if ($bounds | length) == 0 then "unknown"
      elif any($bounds[]; (.runway.status // "") == "exhausted_now") then "dead"
      elif any($bounds[]; .status == "known" and
        ((.effectivePercentRemaining | type) != "number" or .effectivePercentRemaining <= 0)) then "dead"
      elif any($bounds[]; .status != "known") then "unknown"
      else "ok"
      end
    end
  ' 2>/dev/null || printf 'unknown\n'
}

fm_secondmate_melt_profile_provider() { # <harness> <model> [provider]
  if [ -n "${3:-}" ]; then
    printf '%s\n' "$3"
  else
    fm_quota_provider_for_harness "$1" "$2" 2>/dev/null
  fi
}

fm_secondmate_melt_candidate_usable() { # <snapshot> <old-harness> <old-model> <harness> <model> [provider]
  local snapshot=$1 old_harness=$2 old_model=$3 harness=$4 model=$5 provider=${6:-} status
  [ -n "$harness" ] && [ -n "$model" ] && [ "$model" != default ] || return 1
  [ "$model" != "$old_model" ] || return 1
  fm_secondmate_melt_model_forbidden "$model" && return 1
  fm_control_harness_supported "$harness" || return 1
  fm_control_harness_supports_kind "$harness" secondmate || return 1
  provider=$(fm_secondmate_melt_profile_provider "$harness" "$model" "$provider" 2>/dev/null || true)
  [ -n "$provider" ] || return 1
  status=$(fm_secondmate_melt_quota_status "$snapshot" "$harness" "$model" "$provider")
  [ "$status" = ok ]
}

# Print harness<TAB>model<TAB>effort<TAB>source for the first usable profile.
# The parent pin is checked before crew-dispatch.json's default profiles.
fm_secondmate_melt_choose_profile() { # <snapshot> <config-dir> <script-dir> <old-harness> <old-model>
  local snapshot=$1 config=$2 script_dir=$3 old_harness=$4 old_model=$5
  local harness model effort provider line
  if [ -f "$config/secondmate-harness" ]; then
    harness=$(FM_CONFIG_OVERRIDE="$config" "$script_dir/fm-harness.sh" secondmate 2>/dev/null || true)
    model=$(FM_CONFIG_OVERRIDE="$config" "$script_dir/fm-harness.sh" secondmate-model 2>/dev/null || true)
    effort=$(FM_CONFIG_OVERRIDE="$config" "$script_dir/fm-harness.sh" secondmate-effort 2>/dev/null || true)
    [ -n "$effort" ] || effort=default
    provider=$(fm_secondmate_melt_profile_provider "$harness" "$model" 2>/dev/null || true)
    if fm_secondmate_melt_candidate_usable "$snapshot" "$old_harness" "$old_model" \
      "$harness" "$model" "$provider"; then
      printf '%s\t%s\t%s\tparent-pin\n' "$harness" "$model" "$effort"
      return 0
    fi
  fi
  [ -f "$config/crew-dispatch.json" ] || return 1
  # Use a non-whitespace separator so an omitted model remains an empty field.
  # Bash collapses adjacent tab IFS characters and would otherwise shift effort
  # into model, accidentally turning a model-less profile into an explicit one.
  while IFS=$'\034' read -r harness model effort provider; do
    [ -n "$harness" ] || continue
    [ -n "$effort" ] || effort=default
    if fm_secondmate_melt_candidate_usable "$snapshot" "$old_harness" "$old_model" \
      "$harness" "$model" "$provider"; then
      printf '%s\t%s\t%s\tcrew-dispatch-default\n' "$harness" "$model" "$effort"
      return 0
    fi
  done < <(jq -r '
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    profiles(.default // null)[] |
      [(.harness // ""), (.model // ""), (.effort // "default"), (.provider // "")] |
      join("\u001c")
  ' "$config/crew-dispatch.json" 2>/dev/null || true)
  return 1
}
