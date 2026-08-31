#!/usr/bin/env bash
# shellcheck disable=SC2034 # Parsed fields are output globals for sourcing callers.
# Shared validation for deterministic Codex worker routing records.

FM_TASK_ROUTE_ID=
FM_TASK_ROUTE_MODEL=
FM_TASK_ROUTE_EFFORT=
FM_TASK_ROUTE_MINIMUM_TIER=
FM_TASK_ROUTE_QUOTA_PROFILES=
FM_TASK_ROUTE_RESOLVED_PROFILE=
FM_TASK_ROUTE_RESOLVED_MODEL=
FM_TASK_ROUTE_RESOLVED_EFFORT=

fm_task_route_tier_rank() {
  case "$1" in luna) echo 1 ;; terra) echo 2 ;; sol) echo 3 ;; *) echo 0 ;; esac
}

fm_task_route_model_tier() {
  case "$1" in
    gpt-5.6-luna) echo luna ;;
    gpt-5.6-terra) echo terra ;;
    gpt-5.6-sol) echo sol ;;
    *) return 1 ;;
  esac
}

fm_task_route_default_effort() {
  case "$1" in luna) echo medium ;; terra|sol) echo high ;; *) return 1 ;; esac
}

fm_task_route_effort_supported() {
  case "$1:$2" in
    luna:low|luna:medium|luna:high|luna:xhigh|luna:max) return 0 ;;
    terra:low|terra:medium|terra:high|terra:xhigh|terra:max|terra:ultra) return 0 ;;
    sol:low|sol:medium|sol:high|sol:xhigh|sol:max|sol:ultra) return 0 ;;
  esac
  return 1
}

fm_task_route_quota_candidate_selectable() {  # <model> <effort> <minimum-tier> <override-model> <override-effort>
  local model=$1 effort=$2 minimum_tier=$3 override_model=$4 override_effort=$5 tier
  tier=$(fm_task_route_model_tier "$model") || return 1
  if [ "$override_model" = none ]; then
    [ "$(fm_task_route_tier_rank "$tier")" -ge \
      "$(fm_task_route_tier_rank "$minimum_tier")" ]
  else
    [ "$model" = "$override_model" ] && [ "$effort" = "$override_effort" ]
  fi
}

fm_task_route_quota_candidate_valid() {  # <profile> <model> <effort> <eligibility> <reason> <evidence> <minimum-tier> <override-model> <override-effort>
  local profile=$1 model=$2 effort=$3 eligibility=$4 reason=$5 evidence=$6
  local tier
  case "$profile" in ''|none|*[!A-Za-z0-9._@%:+-]*) return 1 ;; esac
  case "$model" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$effort" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$eligibility" in eligible|ineligible) ;; *) return 1 ;; esac
  case "$reason" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$evidence" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$eligibility" in
    eligible)
      [ "$reason" = none ] || return 1
      tier=$(fm_task_route_model_tier "$model") || return 1
      fm_task_route_effort_supported "$tier" "$effort" || return 1
      ;;
    ineligible)
      [ "$reason" != none ]
      ;;
  esac
}

fm_task_route_sha256() {
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(env -u LC_CTYPE LC_ALL=C LANG=C shasum -a 256 "$1" 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(env -u LC_CTYPE LC_ALL=C LANG=C sha256sum "$1" 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

fm_task_route_score_tier() {
  if [ "$1" -le 2 ]; then echo luna
  elif [ "$1" -le 6 ]; then echo terra
  else echo sol
  fi
}

fm_task_route_floor_tier() {
  case "$1" in
    none) echo luna ;;
    user-behavior|multi-module) echo terra ;;
    architecture|security|data-migration|unknown-production-incident) echo sol ;;
    *) return 1 ;;
  esac
}

fm_task_route_read_pair() {
  local expected=$1 line value
  IFS= read -r line <&8 || return 1
  case "$line" in "$expected"$'\t'*) ;; *) return 1 ;; esac
  value=${line#*$'\t'}
  case "$value" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  FM_TASK_ROUTE_VALUE=$value
}

fm_task_route_read_factor() {
  local expected=$1 line rest score evidence
  IFS= read -r line <&8 || return 1
  case "$line" in "$expected"$'\t'*$'\t'*) ;; *) return 1 ;; esac
  rest=${line#*$'\t'}
  score=${rest%%$'\t'*}
  evidence=${rest#*$'\t'}
  case "$score" in 0|1|2) ;; *) return 1 ;; esac
  case "$evidence" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  FM_TASK_ROUTE_SCORE=$score
}

fm_task_route_read_quota_candidate() {
  local line rest profile model effort eligibility reason evidence
  IFS= read -r line <&8 || return 1
  case "$line" in quota_candidate$'\t'*$'\t'*$'\t'*$'\t'*$'\t'*$'\t'*) ;; *) return 1 ;; esac
  rest=${line#*$'\t'}
  profile=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  model=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  effort=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  eligibility=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  reason=${rest%%$'\t'*}
  rest=${rest#*$'\t'}
  evidence=$rest
  case "$profile" in ''|none|*[!A-Za-z0-9._@%:+-]*) return 1 ;; esac
  case "$model" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$effort" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$eligibility" in eligible|ineligible) ;; *) return 1 ;; esac
  case "$reason" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "$evidence" in ''|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  FM_TASK_ROUTE_CANDIDATE_PROFILE=$profile
  FM_TASK_ROUTE_CANDIDATE_MODEL=$model
  FM_TASK_ROUTE_CANDIDATE_EFFORT=$effort
  FM_TASK_ROUTE_CANDIDATE_ELIGIBILITY=$eligibility
  FM_TASK_ROUTE_CANDIDATE_REASON=$reason
  FM_TASK_ROUTE_CANDIDATE_EVIDENCE=$evidence
}

fm_task_route_record_parse() {
  local record=$1 version task_id ambiguity boundary risk diagnosis verification
  local total recorded_total score_tier recorded_score_tier floor floor_tier
  local minimum_tier recorded_minimum_tier override_model override_effort
  local precedence selected_tier model effort quota_candidate_count
  local candidate_profile candidate_model candidate_effort candidate_eligibility
  local resolved_profile resolved_model resolved_effort resolution quota_policy
  local extra expected_precedence quota_profiles='' selected_matches=0 index
  local -a candidate_profiles=() candidate_models=() candidate_efforts=()
  local -a candidate_eligibilities=()
  FM_TASK_ROUTE_ID=
  FM_TASK_ROUTE_MODEL=
  FM_TASK_ROUTE_EFFORT=
  FM_TASK_ROUTE_MINIMUM_TIER=
  FM_TASK_ROUTE_QUOTA_PROFILES=
  FM_TASK_ROUTE_RESOLVED_PROFILE=
  FM_TASK_ROUTE_RESOLVED_MODEL=
  FM_TASK_ROUTE_RESOLVED_EFFORT=
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  exec 8< "$record" || return 1

  fm_task_route_read_pair version || { exec 8<&-; return 1; }
  version=$FM_TASK_ROUTE_VALUE
  [ "$version" = 4 ] || { exec 8<&-; return 1; }
  fm_task_route_read_pair task_id || { exec 8<&-; return 1; }
  task_id=$FM_TASK_ROUTE_VALUE
  case "$task_id" in ''|*[!A-Za-z0-9._-]*) exec 8<&-; return 1 ;; esac

  fm_task_route_read_factor ambiguity || { exec 8<&-; return 1; }
  ambiguity=$FM_TASK_ROUTE_SCORE
  fm_task_route_read_factor boundary_clarity || { exec 8<&-; return 1; }
  boundary=$FM_TASK_ROUTE_SCORE
  fm_task_route_read_factor risk || { exec 8<&-; return 1; }
  risk=$FM_TASK_ROUTE_SCORE
  fm_task_route_read_factor diagnosis_need || { exec 8<&-; return 1; }
  diagnosis=$FM_TASK_ROUTE_SCORE
  fm_task_route_read_factor verification_quality || { exec 8<&-; return 1; }
  verification=$FM_TASK_ROUTE_SCORE

  fm_task_route_read_pair total || { exec 8<&-; return 1; }
  recorded_total=$FM_TASK_ROUTE_VALUE
  case "$recorded_total" in *[!0-9]*) exec 8<&-; return 1 ;; esac
  total=$((ambiguity + boundary + risk + diagnosis + verification))
  [ "$recorded_total" -eq "$total" ] || { exec 8<&-; return 1; }
  fm_task_route_read_pair score_tier || { exec 8<&-; return 1; }
  recorded_score_tier=$FM_TASK_ROUTE_VALUE
  score_tier=$(fm_task_route_score_tier "$total") || { exec 8<&-; return 1; }
  [ "$recorded_score_tier" = "$score_tier" ] || { exec 8<&-; return 1; }

  fm_task_route_read_pair floor || { exec 8<&-; return 1; }
  floor=$FM_TASK_ROUTE_VALUE
  floor_tier=$(fm_task_route_floor_tier "$floor") || { exec 8<&-; return 1; }
  minimum_tier=$score_tier
  if [ "$(fm_task_route_tier_rank "$floor_tier")" -gt "$(fm_task_route_tier_rank "$minimum_tier")" ]; then
    minimum_tier=$floor_tier
  fi
  fm_task_route_read_pair minimum_tier || { exec 8<&-; return 1; }
  recorded_minimum_tier=$FM_TASK_ROUTE_VALUE
  [ "$recorded_minimum_tier" = "$minimum_tier" ] || { exec 8<&-; return 1; }

  fm_task_route_read_pair override_model || { exec 8<&-; return 1; }
  override_model=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair override_effort || { exec 8<&-; return 1; }
  override_effort=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair precedence || { exec 8<&-; return 1; }
  precedence=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair selected_tier || { exec 8<&-; return 1; }
  selected_tier=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair model || { exec 8<&-; return 1; }
  model=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair effort || { exec 8<&-; return 1; }
  effort=$FM_TASK_ROUTE_VALUE

  if [ "$override_model" = none ] && [ "$override_effort" = none ]; then
    [ "$selected_tier" = "$minimum_tier" ] || { exec 8<&-; return 1; }
    [ "$model" = "gpt-5.6-$selected_tier" ] || { exec 8<&-; return 1; }
    [ "$effort" = "$(fm_task_route_default_effort "$selected_tier")" ] || { exec 8<&-; return 1; }
    if [ "$minimum_tier" = "$score_tier" ]; then expected_precedence=five_factor_score
    else expected_precedence=hard_floor
    fi
  elif [ "$override_model" != none ] && [ "$override_effort" != none ]; then
    [ "$model" = "$override_model" ] && [ "$effort" = "$override_effort" ] \
      || { exec 8<&-; return 1; }
    [ "$selected_tier" = "$(fm_task_route_model_tier "$override_model")" ] \
      || { exec 8<&-; return 1; }
    fm_task_route_effort_supported "$selected_tier" "$override_effort" \
      || { exec 8<&-; return 1; }
    expected_precedence=user_override
  else
    exec 8<&-
    return 1
  fi
  [ "$precedence" = "$expected_precedence" ] || { exec 8<&-; return 1; }

  fm_task_route_read_pair quota_candidate_count || { exec 8<&-; return 1; }
  quota_candidate_count=$FM_TASK_ROUTE_VALUE
  case "$quota_candidate_count" in 0|[1-9]*) ;; *) exec 8<&-; return 1 ;; esac
  case "$quota_candidate_count" in *[!0-9]*) exec 8<&-; return 1 ;; esac
  [ "$quota_candidate_count" -le 100 ] || { exec 8<&-; return 1; }
  index=0
  while [ "$index" -lt "$quota_candidate_count" ]; do
    fm_task_route_read_quota_candidate || { exec 8<&-; return 1; }
    candidate_profile=$FM_TASK_ROUTE_CANDIDATE_PROFILE
    candidate_model=$FM_TASK_ROUTE_CANDIDATE_MODEL
    candidate_effort=$FM_TASK_ROUTE_CANDIDATE_EFFORT
    candidate_eligibility=$FM_TASK_ROUTE_CANDIDATE_ELIGIBILITY
    case ",$quota_profiles," in *,"$candidate_profile",*) exec 8<&-; return 1 ;; esac
    fm_task_route_quota_candidate_valid "$candidate_profile" "$candidate_model" \
      "$candidate_effort" "$candidate_eligibility" "$FM_TASK_ROUTE_CANDIDATE_REASON" \
      "$FM_TASK_ROUTE_CANDIDATE_EVIDENCE" "$minimum_tier" "$override_model" \
      "$override_effort" || { exec 8<&-; return 1; }
    candidate_profiles[index]=$candidate_profile
    candidate_models[index]=$candidate_model
    candidate_efforts[index]=$candidate_effort
    candidate_eligibilities[index]=$candidate_eligibility
    quota_profiles=${quota_profiles:+$quota_profiles,}$candidate_profile
    index=$((index + 1))
  done
  fm_task_route_read_pair resolved_profile || { exec 8<&-; return 1; }
  resolved_profile=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair resolved_model || { exec 8<&-; return 1; }
  resolved_model=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair resolved_effort || { exec 8<&-; return 1; }
  resolved_effort=$FM_TASK_ROUTE_VALUE
  fm_task_route_read_pair resolution || { exec 8<&-; return 1; }
  resolution=$FM_TASK_ROUTE_VALUE
  if [ "$quota_candidate_count" -eq 0 ]; then
    [ "$resolved_profile" = none ] || { exec 8<&-; return 1; }
    [ "$resolved_model" = "$model" ] && [ "$resolved_effort" = "$effort" ] \
      || { exec 8<&-; return 1; }
    [ "$resolution" = deterministic ] || { exec 8<&-; return 1; }
  else
    case "$resolved_profile" in ''|none|*[!A-Za-z0-9._@%:+-]*) exec 8<&-; return 1 ;; esac
    index=0
    while [ "$index" -lt "$quota_candidate_count" ]; do
      if [ "${candidate_profiles[$index]}" = "$resolved_profile" ] \
        && [ "${candidate_models[$index]}" = "$resolved_model" ] \
        && [ "${candidate_efforts[$index]}" = "$resolved_effort" ] \
        && [ "${candidate_eligibilities[$index]}" = eligible ] \
        && fm_task_route_quota_candidate_selectable "$resolved_model" \
          "$resolved_effort" "$minimum_tier" "$override_model" "$override_effort"; then
        selected_matches=$((selected_matches + 1))
      fi
      index=$((index + 1))
    done
    [ "$selected_matches" -eq 1 ] || { exec 8<&-; return 1; }
    [ "$resolution" = quota_profile ] || { exec 8<&-; return 1; }
  fi

  fm_task_route_read_pair quota_policy || { exec 8<&-; return 1; }
  quota_policy=$FM_TASK_ROUTE_VALUE
  [ "$quota_policy" = 'quota records every configured profile with eligibility, rejection reason, and candidate-specific evidence; selection preserves explicit override exactly or otherwise never lowers minimum_tier' ] \
    || { exec 8<&-; return 1; }
  if IFS= read -r extra <&8 || [ -n "$extra" ]; then
    exec 8<&-
    return 1
  fi
  exec 8<&-

  FM_TASK_ROUTE_ID=$task_id
  FM_TASK_ROUTE_MODEL=$model
  FM_TASK_ROUTE_EFFORT=$effort
  FM_TASK_ROUTE_MINIMUM_TIER=$minimum_tier
  FM_TASK_ROUTE_QUOTA_PROFILES=${quota_profiles:-none}
  FM_TASK_ROUTE_RESOLVED_PROFILE=$resolved_profile
  FM_TASK_ROUTE_RESOLVED_MODEL=$resolved_model
  FM_TASK_ROUTE_RESOLVED_EFFORT=$resolved_effort
}
