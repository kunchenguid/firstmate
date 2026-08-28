#!/usr/bin/env bash
# Validate and persist the task-scoped ROUTING_DECISION consumed by fm-spawn.
#
# Every fresh crewmate or scout dispatch and every relaunch carrying a routing
# override requires these private inputs under data/<task-id>/:
#   routing-intent.json             exact ROUTING_INTENT authority object
#   routing-decision.pending.json   proposed ROUTING_DECISION schema v1 receipt
#   quota-snapshot.json             required only for a multi-candidate profile
#
# The requirement is an unconditional fm-spawn invariant.
# The canonical config/crew-dispatch.json presence or absence is attested as an
# input and FM_CONFIG_OVERRIDE never selects the authority for this gate.
#
# fm_routing_decision_validate_and_persist validates the pending receipt against
# the invocation task id, exact brief and intent bytes, canonical dispatch-config
# state, selected tuple, emitted model and effort fragments, current home and host
# identities, and the fixed five-minute receipt/quota freshness policy.
# On success it publishes generation-addressed receipt and brief artifacts
# before fm-spawn creates a worker endpoint or leases a worktree.
# The canonical schemas and field semantics live in docs/configuration.md under
# "ROUTING_DECISION receipts".

# shellcheck disable=SC2034 # consumed by the sourcing fm-spawn.sh process
FM_ROUTING_DECISION_FINAL=
FM_ROUTING_BRIEF_FINAL=
FM_ROUTING_BRIEF_HASH=
FM_ROUTING_PREPARED_DIR=
FM_ROUTING_PREPARED_DATA=
FM_ROUTING_PREPARED_ID=
FM_ROUTING_PREPARED_HOME=
FM_ROUTING_PREPARED_SOURCE_PENDING=
FM_ROUTING_PREPARED_DIR_DEV=
FM_ROUTING_PREPARED_DIR_INO=
FM_ROUTING_PREPARED_PENDING_DEV=
FM_ROUTING_PREPARED_PENDING_INO=
FM_ROUTING_PREPARED_GENERATION=
FM_ROUTING_PREPARED_PUBLISHED=0
FM_ROUTING_DECISION_MAX_AGE_SECONDS=300
FM_ROUTING_DECISION_MAX_FUTURE_SECONDS=30

fm_routing_decision_required() { # <kind> <relaunch:0|1> <harness-set:0|1> <model-set:0|1> <effort-set:0|1>
  local kind=$1 relaunch=$2 harness_set=$3 model_set=$4 effort_set=$5
  if [ "$relaunch" -eq 1 ]; then
    [ "$harness_set" -eq 1 ] || [ "$model_set" -eq 1 ] || [ "$effort_set" -eq 1 ]
    return
  fi
  [ "$kind" != secondmate ]
}

fm_routing_sha256_file() {
  local file=$1 output
  if command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256 "$file" 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum "$file" 2>/dev/null) || return 1
  else
    return 1
  fi
  awk '{print $1}' <<<"$output"
}

fm_routing_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_routing_refuse() {
  local predicate=$1 detail=$2
  printf 'error: ROUTING_DECISION %s: %s\n' "$predicate" "$detail" >&2
  return 1
}

fm_routing_private_input() {
  local path=$1 label=$2 unreadable_label=${3:-$2}
  [ -f "$path" ] && [ ! -L "$path" ] || {
    fm_routing_refuse "$label" "required regular task-scoped file is absent: $path"
    return 1
  }
  [ -r "$path" ] || {
    fm_routing_refuse "$unreadable_label" "required regular task-scoped file is unreadable"
    return 1
  }
}

fm_routing_fs_boundary() {
  perl "$(dirname "${BASH_SOURCE[0]}")/fm-routing-fs-boundary.pl" "$@"
}

fm_routing_decision_resolve_inherited() {
  local receipt=$1 task_dir=$2 generation_dir generation expected brief intent
  local expected_intent actual_intent expected_brief actual_brief source_brief
  [ "$(dirname "$(dirname "$receipt")")" = "$task_dir" ] || return 1
  [ "$(basename "$receipt")" = receipt.json ] || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  generation_dir=$(basename "$(dirname "$receipt")")
  generation=${generation_dir#routing-generation.}
  [ "$generation_dir" = "routing-generation.$generation" ] || return 1
  [[ "$generation" =~ ^[0-9a-f]{64}$ ]] || return 1
  expected=$(fm_routing_fs_boundary hash "$(dirname "$receipt")" receipt.json 2>/dev/null) || return 1
  [ "$expected" = "$generation" ] || return 1
  brief="$(dirname "$receipt")/brief.md"
  [ -f "$brief" ] && [ ! -L "$brief" ] || return 1
  intent="$task_dir/routing-intent.json"
  [ -f "$intent" ] && [ ! -L "$intent" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  expected_intent=$(jq -er '.intent_sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$receipt" 2>/dev/null) || return 1
  actual_intent=$(fm_routing_fs_boundary hash "$task_dir" routing-intent.json 2>/dev/null) || return 1
  [ "$actual_intent" = "$expected_intent" ] || return 1
  expected_brief=$(jq -er '.brief_sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$intent" 2>/dev/null) || return 1
  actual_brief=$(fm_routing_fs_boundary hash "$(dirname "$receipt")" brief.md 2>/dev/null) || return 1
  [ "$actual_brief" = "$expected_brief" ] || return 1
  source_brief=$(fm_routing_fs_boundary hash "$task_dir" brief.md 2>/dev/null) || return 1
  [ "$source_brief" = "$expected_brief" ] || return 1
  FM_ROUTING_DECISION_FINAL=$receipt
  FM_ROUTING_BRIEF_FINAL=$brief
}

FM_ROUTING_WORDS=()

fm_routing_raw_environment_assignment() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

fm_routing_raw_ascii_text() { # <command>
  local LC_ALL=C input=$1 ch i
  for ((i = 0; i < ${#input}; i++)); do
    ch=${input:i:1}
    case "$ch" in
      [[:print:]]) ;;
      *) return 1 ;;
    esac
  done
}

fm_routing_literal_words() { # <command> <raw:0|1>
  local input=$1 raw=${2:-0} state=plain token='' ch i token_started=0
  FM_ROUTING_WORDS=()
  if [ "$raw" -eq 1 ]; then
    fm_routing_raw_ascii_text "$input" || return 1
  fi
  for ((i = 0; i < ${#input}; i++)); do
    ch=${input:i:1}
    case "$state" in
      plain)
        case "$ch" in
          ' '|$'\t')
            if [ "$token_started" -eq 1 ]; then
              FM_ROUTING_WORDS+=("$token")
              token=
              token_started=0
            fi
            ;;
          "'") state=single; token_started=1 ;;
          '"') state=double; token_started=1 ;;
          '=')
            [ -n "$token" ] || return 1
            token+="$ch"
            token_started=1
            ;;
          [[:alnum:]]|'-'|'_'|'.'|'/'|':'|','|'+'|'@'|'%')
            token+="$ch"
            token_started=1
            ;;
          *) return 1 ;;
        esac
        ;;
      single)
        # POSIX shells treat every character inside single quotes literally;
        # only the closing quote changes parser state.
        if [ "$ch" = "'" ]; then
          state=plain
        else
          token+="$ch"
        fi
        ;;
      double)
        case "$ch" in
          '"') state=plain ;;
          [[:alnum:]]|' '|'#'|'%'|'&'|"'"|'('|')'|'*'|'+'|','|'-'|'.'|'/'|':'|';'|'<'|'='|'>'|'?'|'@'|'['|']'|'^'|'_'|'{'|'|'|'}'|'~')
            token+="$ch"
            ;;
          *) return 1 ;;
        esac
        ;;
    esac
  done
  [ "$state" = plain ] || return 1
  if [ "$token_started" -eq 1 ]; then
    FM_ROUTING_WORDS+=("$token")
  fi
  [ "${#FM_ROUTING_WORDS[@]}" -gt 0 ]
}

FM_ROUTING_COMMAND_HARNESS=
FM_ROUTING_COMMAND_MODEL=
FM_ROUTING_COMMAND_EFFORT=
FM_ROUTING_COMMAND_MODEL_SEEN=0
FM_ROUTING_COMMAND_EFFORT_SEEN=0

fm_routing_raw_harness_for_executable() { # <executable-word>
  local executable=$1 command_name harness expected
  command_name=$(basename "$executable")
  case "$command_name" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|muse)
      harness=$command_name
      ;;
    cursor-agent)
      harness=cursor
      ;;
    *)
      fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch command head is not a supported harness executable"
      return 1
      ;;
  esac
  case "$executable" in
    */*)
      case "$executable" in
        /*) ;;
        *)
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch command head uses a relative path"
          return 1
          ;;
      esac
      ;;
  esac
  expected=$(type -P "$command_name" 2>/dev/null) || {
    fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "supported raw harness executable cannot be resolved through PATH"
    return 1
  }
  if [[ "$executable" == /* ]] \
    && { [ ! -x "$executable" ] || [[ ! "$executable" -ef "$expected" ]]; }; then
    fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "absolute raw harness path is not the supported executable resolved through PATH"
    return 1
  fi
  printf '%s\n' "$harness"
}

fm_routing_set_codex_effort() { # <encoded-effort>
  local encoded=$1
  case "$encoded" in
    \"*)
      case "$encoded" in
        *\") encoded=${encoded#\"}; encoded=${encoded%\"} ;;
        *)
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort config quote pair is unmatched"
          return 1
          ;;
      esac
      ;;
    \'*)
      case "$encoded" in
        *\') encoded=${encoded#\'}; encoded=${encoded%\'} ;;
        *)
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort config quote pair is unmatched"
          return 1
          ;;
      esac
      ;;
    *\"|*\')
      fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort config quote pair is unmatched"
      return 1
      ;;
  esac
  [ -n "$encoded" ] || {
    fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort config has no fixed literal value"
    return 1
  }
  fm_routing_set_raw_effort config "$encoded"
}

fm_routing_set_raw_effort() { # <spelling> <effort>
  local spelling=$1 effort=$2
  case "$FM_ROUTING_COMMAND_HARNESS:$spelling" in
    claude:--effort|codex:config|grok:--reasoning-effort|pi:--thinking|pi-signed:--thinking|muse:--reasoning-effort) ;;
    *)
      fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort spelling is not supported by the selected raw harness"
      return 1
      ;;
  esac
  case "$FM_ROUTING_COMMAND_HARNESS:$effort" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max|codex:low|codex:medium|codex:high|codex:xhigh|grok:low|grok:medium|grok:high|pi:low|pi:medium|pi:high|pi:xhigh|pi:max|pi-signed:low|pi-signed:medium|pi-signed:high|pi-signed:xhigh|pi-signed:max|muse:low|muse:medium|muse:high|muse:xhigh|muse:ultra) ;;
    *)
      fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort value is not supported by the selected raw harness"
      return 1
      ;;
  esac
  FM_ROUTING_COMMAND_EFFORT=$effort
  FM_ROUTING_COMMAND_EFFORT_SEEN=1
}

fm_routing_parse_command_axes() { # <command> <raw:0|1>
  local input=$1 raw=$2 word value i executable_seen=0 harness_word
  FM_ROUTING_COMMAND_HARNESS=
  FM_ROUTING_COMMAND_MODEL=
  FM_ROUTING_COMMAND_EFFORT=
  FM_ROUTING_COMMAND_MODEL_SEEN=0
  FM_ROUTING_COMMAND_EFFORT_SEEN=0
  if [ "$raw" -eq 1 ]; then
    case "$input" in
      *'__MODELFLAG__'*|*'__EFFORTFLAG__'*|*'__BRIEF__'*|*'__TURNEND__'*|*'__PIEXT__'*|*'__PITURNEND__'*|*'__PIWATCH__'*|*'__OPINPUT__'*|*'__WORKTREE__'*|*'__LAUNCHINPUT__'*|*'__PIBIN__'*|*'__PITUIMODE__'*|*'__CURSORBIN__'*|*'__KIMIBIN__'*|*'__MUSEBIN__'*|*'__MUSECONFIG__'*|*'__MUSEDATA__'*)
        fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch contains a reserved template placeholder expanded after receipt validation"
        return 1
        ;;
    esac
  fi
  fm_routing_literal_words "$input" "$raw" || {
    fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "launch syntax contains expansion, substitution, control operators, or unbalanced quoting"
    return 1
  }
  for ((i = 0; i < ${#FM_ROUTING_WORDS[@]}; i++)); do
    word=${FM_ROUTING_WORDS[$i]}
    if [ "$executable_seen" -eq 0 ]; then
      if fm_routing_raw_environment_assignment "$word"; then
        [ "$raw" -eq 0 ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch environment assignments can select an unobserved runtime"
          return 1
        }
        continue
      fi
      case "$word" in -*) break ;; esac
      if [ "$raw" -eq 1 ]; then
        harness_word=$(fm_routing_raw_harness_for_executable "$word") || return 1
      else
        harness_word=$(basename "$word")
      fi
      FM_ROUTING_COMMAND_HARNESS=$harness_word
      executable_seen=1
      continue
    fi
    if [ "$raw" -eq 1 ] && fm_routing_raw_environment_assignment "$word"; then
      fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch environment assignments can select an unobserved runtime"
      return 1
    fi
    case "$word" in
      --) break ;;
      --model)
        [ "$FM_ROUTING_COMMAND_MODEL_SEEN" -eq 0 ] \
          && [ $((i + 1)) -lt "${#FM_ROUTING_WORDS[@]}" ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "model flag is missing a value or duplicated"
          return 1
        }
        i=$((i + 1))
        FM_ROUTING_COMMAND_MODEL=${FM_ROUTING_WORDS[$i]}
        case "$FM_ROUTING_COMMAND_MODEL" in -*|'')
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "model flag has no fixed literal value"
          return 1
        esac
        FM_ROUTING_COMMAND_MODEL_SEEN=1
        ;;
      --model=*)
        [ "$FM_ROUTING_COMMAND_MODEL_SEEN" -eq 0 ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "model flag is duplicated"
          return 1
        }
        FM_ROUTING_COMMAND_MODEL=${word#--model=}
        [ -n "$FM_ROUTING_COMMAND_MODEL" ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "model flag has no fixed literal value"
          return 1
        }
        FM_ROUTING_COMMAND_MODEL_SEEN=1
        ;;
      -m|-m=*|--model-name|--model-name=*|--model-id|--model-id=*)
        fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses a non-standard model flag spelling"
        return 1
        ;;
      --*model*|--*fallback*)
        fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses an unattested model or fallback selector"
        return 1
        ;;
      --settings|--settings=*|--agent|--agent=*|--agents|--agents=*)
        if [ "$FM_ROUTING_COMMAND_HARNESS" = claude ]; then
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses an unattested model-bearing Claude configuration"
          return 1
        fi
        ;;
      -p|--profile|--profile=*|--oss|--local-provider|--local-provider=*)
        if [ "$FM_ROUTING_COMMAND_HARNESS" = codex ]; then
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses an unattested Codex model or provider configuration"
          return 1
        fi
        ;;
      --*provider*|--*account*|--*router*|--*backend*)
        fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses an unattested provider, account, router, or backend selector"
        return 1
        ;;
      --effort|--reasoning-effort|--thinking)
        [ "$FM_ROUTING_COMMAND_EFFORT_SEEN" -eq 0 ] \
          && [ $((i + 1)) -lt "${#FM_ROUTING_WORDS[@]}" ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort flag is missing a value or duplicated"
          return 1
        }
        i=$((i + 1))
        value=${FM_ROUTING_WORDS[$i]}
        case "$value" in -*|'')
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort flag has no fixed literal value"
          return 1
        esac
        fm_routing_set_raw_effort "$word" "$value" || return 1
        ;;
      --effort=*|--reasoning-effort=*|--thinking=*)
        [ "$FM_ROUTING_COMMAND_EFFORT_SEEN" -eq 0 ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort flag is duplicated"
          return 1
        }
        value=${word#*=}
        [ -n "$value" ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort flag has no fixed literal value"
          return 1
        }
        fm_routing_set_raw_effort "${word%%=*}" "$value" || return 1
        ;;
      -c)
        [ "$FM_ROUTING_COMMAND_HARNESS" = codex ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses an unattested configuration or session selector"
          return 1
        }
        [ $((i + 1)) -lt "${#FM_ROUTING_WORDS[@]}" ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "config flag has no fixed literal value"
          return 1
        }
        i=$((i + 1))
        value=${FM_ROUTING_WORDS[$i]}
        case "$value" in
          model_reasoning_effort=*)
            [ "$FM_ROUTING_COMMAND_HARNESS" = codex ] || {
              fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "model_reasoning_effort config is only verifiable for the codex harness"
              return 1
            }
            [ "$FM_ROUTING_COMMAND_EFFORT_SEEN" -eq 0 ] || {
              fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort flag is duplicated"
              return 1
            }
            fm_routing_set_codex_effort "${value#model_reasoning_effort=}" || return 1
            ;;
          *)
            fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses an unattested Codex configuration override"
            return 1
            ;;
        esac
        ;;
      -c=model_reasoning_effort=*)
        [ "$FM_ROUTING_COMMAND_HARNESS" = codex ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "model_reasoning_effort config is only verifiable for the codex harness"
          return 1
        }
        [ "$FM_ROUTING_COMMAND_EFFORT_SEEN" -eq 0 ] || {
          fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "effort flag is duplicated"
          return 1
        }
        fm_routing_set_codex_effort "${word#-c=model_reasoning_effort=}" || return 1
        ;;
      -c=*)
        fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "raw launch uses an unattested Codex configuration override"
        return 1
        ;;
    esac
  done
  [ "$executable_seen" -eq 1 ] || {
    fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "launch has no executable harness word"
    return 1
  }
}

fm_routing_expected_launch_binding() { # <raw:0|1> <launch> <harness> <model> <effort> <model-fragment> <effort-fragment>
  local raw=$1 launch=$2 harness=$3 selected_model=$4 selected_effort=$5
  local model_fragment=${6:-} effort_fragment=${7:-} parse_input kind model_json effort_json expected_effort
  if [ "$raw" -eq 1 ]; then
    parse_input=$launch
    kind=raw_launch
  else
    parse_input="$harness $model_fragment$effort_fragment"
    kind=verified_template
  fi
  fm_routing_parse_command_axes "$parse_input" "$raw" || return 1
  if [ "$raw" -eq 1 ]; then
    case "$FM_ROUTING_COMMAND_HARNESS" in
      opencode|kimi|cursor)
        fm_routing_refuse "RAW_LAUNCH_NOT_VERIFIABLE" "selected raw harness cannot express the required effort axis"
        return 1
        ;;
    esac
  fi
  [ "$FM_ROUTING_COMMAND_HARNESS" = "$harness" ] || {
    fm_routing_refuse "RAW_LAUNCH_MISMATCH" "emitted harness contradicts the selected tuple"
    return 1
  }
  if [ "$raw" -eq 1 ]; then
    [ "$FM_ROUTING_COMMAND_MODEL_SEEN" -eq 1 ] \
      && [ "$FM_ROUTING_COMMAND_EFFORT_SEEN" -eq 1 ] || {
      fm_routing_refuse "RAW_LAUNCH_UNRESOLVED" "raw launches must expose fixed literal model and effort selections"
      return 1
    }
  fi
  if [ "$FM_ROUTING_COMMAND_MODEL_SEEN" -eq 1 ]; then
    [ "$FM_ROUTING_COMMAND_MODEL" = "$selected_model" ] || {
      fm_routing_refuse "RAW_LAUNCH_MISMATCH" "emitted model contradicts the selected tuple"
      return 1
    }
    model_json=$(jq -cn --arg value "$FM_ROUTING_COMMAND_MODEL" '$value')
  else
    model_json=null
  fi
  if [ "$FM_ROUTING_COMMAND_EFFORT_SEEN" -eq 1 ]; then
    expected_effort=$selected_effort
    if [ "$harness" = muse ] && [ "$selected_effort" = max ]; then
      expected_effort=ultra
    fi
    [ "$FM_ROUTING_COMMAND_EFFORT" = "$expected_effort" ] || {
      fm_routing_refuse "RAW_LAUNCH_MISMATCH" "emitted effort contradicts the selected tuple"
      return 1
    }
    effort_json=$(jq -cn --arg value "$FM_ROUTING_COMMAND_EFFORT" '$value')
  else
    effort_json=null
  fi
  jq -cn \
    --arg kind "$kind" \
    --arg harness "$FM_ROUTING_COMMAND_HARNESS" \
    --argjson model "$model_json" \
    --argjson effort "$effort_json" \
    '{kind: $kind, harness: $harness, model: $model, effort: $effort}'
}

fm_routing_iso_epoch() {
  jq -nr --arg value "$1" \
    '$value | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null
}

fm_routing_timestamp_fresh() {
  local value=$1 predicate=$2 now epoch age
  epoch=$(fm_routing_iso_epoch "$value") || {
    fm_routing_refuse "$predicate" "timestamp is not RFC3339 UTC"
    return 1
  }
  now=$(date -u +%s)
  age=$((now - epoch))
  if [ "$age" -gt "$FM_ROUTING_DECISION_MAX_AGE_SECONDS" ]; then
    fm_routing_refuse "$predicate" "timestamp exceeds the ${FM_ROUTING_DECISION_MAX_AGE_SECONDS}s freshness policy"
    return 1
  fi
  if [ "$age" -lt "-$FM_ROUTING_DECISION_MAX_FUTURE_SECONDS" ]; then
    fm_routing_refuse "$predicate" "timestamp is more than ${FM_ROUTING_DECISION_MAX_FUTURE_SECONDS}s in the future"
    return 1
  fi
}

fm_routing_normalized_candidates() {
  local config=$1 source=$2 index=$3
  case "$source" in
    rule)
      jq -ce --argjson index "$index" '
        .rules[$index].use
        | if type == "array" then . else [.] end
        | map({harness: .harness, model: (.model // "default"), effort: (.effort // "default")})
      ' "$config" 2>/dev/null
      ;;
    default)
      jq -ce '
        .default
        | if type == "array" then . else [.] end
        | map({harness: .harness, model: (.model // "default"), effort: (.effort // "default")})
      ' "$config" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

fm_routing_decision_validate_snapshot() { # <data> <canonical-config> <task-id> <harness> <model> <effort> <home> <raw:0|1> <launch> <model-fragment> <effort-fragment> <source-pending> <snapshot-dir> [fresh|committed]
  local data=$1 config_dir=$2 id=$3 harness=$4 model=$5 effort=$6 home=$7
  local raw_launch=$8 launch=$9 model_fragment=${10:-} effort_fragment=${11:-}
  local source_pending=${12} snapshot_dir=${13} freshness_mode=${14:-fresh} consumed_pending brief_final
  local task_dir brief intent pending quota_snapshot final config_file brief_hash intent_hash
  local receipt_task generated_at required_gate intent_gate source index candidates chosen candidate_count
  local quota_basis quota_source quota_observed quota_hash actual_quota_hash snapshot_observed
  local home_hash host_hash receipt_home_hash receipt_host_hash launch_binding config_binding config_hash

  FM_ROUTING_DECISION_FINAL=
  task_dir="$data/$id"
  brief="$task_dir/brief.md"
  intent="$task_dir/routing-intent.json"
  pending="$task_dir/routing-decision.pending.json"
  quota_snapshot="$task_dir/quota-snapshot.json"
  final="${source_pending%.pending.json}.json"
  config_file="$config_dir/crew-dispatch.json"

  fm_routing_private_input "$pending" "missing" "UNREADABLE_RECEIPT" || return 1
  fm_routing_private_input "$intent" "missing" "UNREADABLE_INTENT" || return 1
  fm_routing_private_input "$brief" "missing" "NOT_VERIFIABLE(BRIEF)" || return 1
  command -v jq >/dev/null 2>&1 || {
    fm_routing_refuse "NOT_VERIFIABLE(SCHEMA)" "jq is unavailable"
    return 1
  }

  jq -e '
    type == "object"
    and (keys == ["ambiguity", "authority", "brief_sha256", "forbidden_effects", "gate", "hard_capability", "risk", "schema_version", "task_id"])
    and (.schema_version | type == "number" and . == 1 and floor == .)
    and (.task_id | type == "string" and length > 0)
    and (.hard_capability | type == "string" and length > 0)
    and (.ambiguity | type == "string" and length > 0)
    and (.risk | type == "string" and length > 0)
    and (.authority | type == "string" and length > 0)
    and (.brief_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.gate | type == "string" and length > 0)
    and (.forbidden_effects | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  ' "$intent" >/dev/null 2>&1 || {
    fm_routing_refuse "MALFORMED_INTENT" "routing-intent.json does not satisfy schema version 1"
    return 1
  }
  jq -e '
    type == "object"
    and (keys == (["candidates_considered", "dispatch_config", "effort", "fallback", "generated_at", "harness", "host", "intent_sha256", "launch_binding", "matched_profile", "model", "quota", "quota_basis", "rationale", "required_gate", "schema_version", "selection_order", "supervisor", "task_id"] | sort))
    and (.schema_version | type == "number" and . == 1 and floor == .)
    and (.task_id | type == "string" and length > 0)
    and (.intent_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.dispatch_config | type == "object" and (keys == ["kind", "sha256"]))
    and ((.dispatch_config.kind == "present" and (.dispatch_config.sha256 | type == "string" and test("^[0-9a-f]{64}$"))) or (.dispatch_config.kind == "absent" and .dispatch_config.sha256 == null))
    and (.matched_profile | type == "object" and (keys == ["index", "source"]))
    and (.supervisor | type == "object" and (keys == ["home_sha256", "kind"]))
    and (.host | type == "object" and (keys == ["identity_sha256", "kind"]))
    and (.launch_binding | type == "object" and (keys == ["effort", "harness", "kind", "model"]))
    and (.launch_binding.kind == "verified_template" or .launch_binding.kind == "raw_launch")
    and (.launch_binding.harness | type == "string" and length > 0)
    and ((.launch_binding.model == null) or (.launch_binding.model | type == "string" and length > 0))
    and ((.launch_binding.effort == null) or (.launch_binding.effort | type == "string" and length > 0))
    and (.harness | type == "string" and length > 0)
    and (.model | type == "string" and length > 0)
    and (.effort | type == "string" and length > 0)
    and (.candidates_considered | type == "array" and length > 0 and all(.[];
      type == "object" and (keys == ["effort", "harness", "model"])
      and (.harness | type == "string" and length > 0)
      and (.model | type == "string" and length > 0)
      and (.effort | type == "string" and length > 0)))
    and (.quota | type == "object" and (keys == ["observed_at", "snapshot_sha256", "source"]))
    and (.quota_basis | type == "string" and length > 0)
    and (.fallback | type == "string" and length > 0)
    and (.rationale | type == "string" and length > 0)
    and (.required_gate | type == "string" and length > 0)
    and (.selection_order == ["hard_capability", "ambiguity_complexity", "fresh_quota_among_capable"])
    and (.generated_at | type == "string" and length > 0)
  ' "$pending" >/dev/null 2>&1 || {
    fm_routing_refuse "MALFORMED_SCHEMA" "routing-decision.pending.json does not satisfy schema version 1"
    return 1
  }

  receipt_task=$(jq -r '.task_id' "$pending")
  [ "$receipt_task" = "$id" ] && [ "$(jq -r '.task_id' "$intent")" = "$id" ] || {
    fm_routing_refuse "TASK_MISMATCH" "receipt and intent task_id must match the invocation task"
    return 1
  }
  brief_hash=$(fm_routing_sha256_file "$brief") || {
    fm_routing_refuse "NOT_VERIFIABLE(BRIEF)" "brief SHA-256 could not be computed"
    return 1
  }
  [ "$(jq -r '.brief_sha256' "$intent")" = "$brief_hash" ] || {
    fm_routing_refuse "BRIEF_HASH_MISMATCH" "intent is not bound to the exact brief bytes"
    return 1
  }
  intent_hash=$(fm_routing_sha256_file "$intent") || {
    fm_routing_refuse "NOT_VERIFIABLE(INTENT)" "intent SHA-256 could not be computed"
    return 1
  }
  [ "$(jq -r '.intent_sha256' "$pending")" = "$intent_hash" ] || {
    fm_routing_refuse "INTENT_HASH_MISMATCH" "receipt is not bound to the exact intent bytes"
    return 1
  }

  if [ -e "$config_file" ] || [ -L "$config_file" ]; then
    [ -f "$config_file" ] && [ ! -L "$config_file" ] && [ -r "$config_file" ] || {
      fm_routing_refuse "NOT_VERIFIABLE(CONFIG)" "canonical dispatch configuration is not a readable regular file"
      return 1
    }
    config_hash=$(fm_routing_sha256_file "$config_file") || {
      fm_routing_refuse "NOT_VERIFIABLE(CONFIG)" "canonical dispatch configuration SHA-256 could not be computed"
      return 1
    }
    config_binding=$(jq -cn --arg sha256 "$config_hash" '{kind: "present", sha256: $sha256}')
  else
    config_binding='{"kind":"absent","sha256":null}'
  fi
  jq -e --argjson binding "$config_binding" '.dispatch_config == $binding' "$pending" >/dev/null 2>&1 || {
    fm_routing_refuse "DISPATCH_CONFIG_MISMATCH" "receipt is not bound to canonical dispatch configuration presence and bytes"
    return 1
  }

  generated_at=$(jq -r '.generated_at' "$pending")
  case "$freshness_mode" in
    fresh) fm_routing_timestamp_fresh "$generated_at" "STALE" || return 1 ;;
    committed)
      fm_routing_iso_epoch "$generated_at" >/dev/null || {
        fm_routing_refuse "STALE" "timestamp is not RFC3339 UTC"
        return 1
      }
      ;;
    *)
      fm_routing_refuse "NOT_VERIFIABLE(SCHEMA)" "routing freshness mode is unsupported"
      return 1
      ;;
  esac
  required_gate=$(jq -r '.required_gate' "$pending")
  intent_gate=$(jq -r '.gate' "$intent")
  [ "$required_gate" = "$intent_gate" ] || {
    fm_routing_refuse "GATE_MISMATCH" "receipt required_gate differs from the exact intent"
    return 1
  }
  [ "$(jq -r '.fallback' "$pending")" = NONE ] || {
    fm_routing_refuse "FORBIDDEN_FALLBACK" "schema version 1 permits no fallback route"
    return 1
  }

  home_hash=$(printf '%s' "$home" | fm_routing_sha256_text) || {
    fm_routing_refuse "NOT_VERIFIABLE(SUPERVISOR)" "current home identity could not be hashed"
    return 1
  }
  host_hash=$(uname -n | fm_routing_sha256_text) || {
    fm_routing_refuse "NOT_VERIFIABLE(HOST)" "local host identity could not be hashed"
    return 1
  }
  receipt_home_hash=$(jq -r '.supervisor.home_sha256' "$pending")
  receipt_host_hash=$(jq -r '.host.identity_sha256' "$pending")
  [ "$(jq -r '.supervisor.kind' "$pending")" = current-firstmate-home ] \
    && [ "$receipt_home_hash" = "$home_hash" ] || {
    fm_routing_refuse "SUPERVISOR_MISMATCH" "receipt supervisor is not this Firstmate home"
    return 1
  }
  [ "$(jq -r '.host.kind' "$pending")" = local ] \
    && [ "$receipt_host_hash" = "$host_hash" ] || {
    fm_routing_refuse "HOST_MISMATCH" "receipt host is not the current local host"
    return 1
  }

  source=$(jq -r '.matched_profile.source' "$pending")
  index=$(jq -r '.matched_profile.index' "$pending")
  case "$source" in
    rule)
      [ "$(jq -r '.dispatch_config.kind' "$pending")" = present ] || {
        fm_routing_refuse "DISPATCH_CONFIG_MISMATCH" "rule source requires canonical dispatch configuration"
        return 1
      }
      jq -e '.matched_profile.index | type == "number" and . >= 0 and floor == .' "$pending" >/dev/null 2>&1 || {
        fm_routing_refuse "MALFORMED_SCHEMA" "rule match requires a non-negative integer index"
        return 1
      }
      candidates=$(fm_routing_normalized_candidates "$config_file" rule "$index") || {
        fm_routing_refuse "DISPATCH_CONFIG_MISMATCH" "matched rule is absent or malformed in canonical configuration"
        return 1
      }
      ;;
    default)
      [ "$(jq -r '.dispatch_config.kind' "$pending")" = present ] && [ "$index" = null ] || {
        fm_routing_refuse "DISPATCH_CONFIG_MISMATCH" "default source requires canonical configuration and a null index"
        return 1
      }
      candidates=$(fm_routing_normalized_candidates "$config_file" default null) || {
        fm_routing_refuse "DISPATCH_CONFIG_MISMATCH" "default profile is absent or malformed in canonical configuration"
        return 1
      }
      ;;
    static_harness)
      [ "$(jq -r '.dispatch_config.kind' "$pending")" = absent ] \
        && [ "$index" = null ] \
        && [ "$(jq -r '.authority' "$intent")" = STATIC_HARNESS ] || {
        fm_routing_refuse "AUTHORITY_MISMATCH" "static harness source requires canonical configuration absence and matching intent authority"
        return 1
      }
      candidates=$(jq -c '.candidates_considered' "$pending")
      [ "$(jq 'length' <<<"$candidates")" = 1 ] || {
        fm_routing_refuse "MALFORMED_SCHEMA" "static harness source must be a singleton candidate set"
        return 1
      }
      ;;
    explicit_override)
      [ "$index" = null ] \
        && [ "$(jq -r '.authority' "$intent")" = EXPLICIT_RUNTIME_OVERRIDE ] || {
        fm_routing_refuse "AUTHORITY_MISMATCH" "explicit runtime override is not present in the exact intent"
        return 1
      }
      candidates=$(jq -c '.candidates_considered' "$pending")
      [ "$(jq 'length' <<<"$candidates")" = 1 ] || {
        fm_routing_refuse "MALFORMED_SCHEMA" "explicit runtime override must be a singleton candidate set"
        return 1
      }
      ;;
    *)
      fm_routing_refuse "MALFORMED_SCHEMA" "matched_profile.source is unsupported"
      return 1
      ;;
  esac

  jq -e --argjson candidates "$candidates" '.candidates_considered == $candidates' "$pending" >/dev/null 2>&1 || {
    fm_routing_refuse "DISPATCH_CONFIG_MISMATCH" "candidate set is not the exact authoritative set"
    return 1
  }
  chosen=$(jq -cn --arg harness "$harness" --arg model "$model" --arg effort "$effort" \
    '{harness: $harness, model: $model, effort: $effort}')
  jq -e --argjson chosen "$chosen" '
    .harness == $chosen.harness
    and .model == $chosen.model
    and .effort == $chosen.effort
    and any(.candidates_considered[]; . == $chosen)
  ' "$pending" >/dev/null 2>&1 || {
    fm_routing_refuse "INCAPABLE_CANDIDATE" "selected spawn tuple is not the attested capable candidate"
    return 1
  }
  launch_binding=$(fm_routing_expected_launch_binding \
    "$raw_launch" "$launch" "$harness" "$model" "$effort" "$model_fragment" "$effort_fragment") || return 1
  jq -e --argjson launch_binding "$launch_binding" '.launch_binding == $launch_binding' "$pending" >/dev/null 2>&1 || {
    fm_routing_refuse "LAUNCH_BINDING_MISMATCH" "receipt launch binding does not match emitted command fragments"
    return 1
  }

  candidate_count=$(jq '.candidates_considered | length' "$pending")
  quota_basis=$(jq -r '.quota_basis' "$pending")
  quota_source=$(jq -r '.quota.source' "$pending")
  if [ "$candidate_count" -eq 1 ]; then
    if ! { [ "$quota_basis" = NOT_APPLICABLE_SINGLETON ] \
      && [ "$quota_source" = NOT_APPLICABLE_SINGLETON ] \
      && jq -e '.quota.observed_at == null and .quota.snapshot_sha256 == null' "$pending" >/dev/null 2>&1; }; then
      fm_routing_refuse "MALFORMED_QUOTA_BASIS" "singleton route must record NOT_APPLICABLE_SINGLETON without quota evidence"
      return 1
    fi
  else
    [ "$quota_basis" = FRESH_QUOTA_COMPARISON ] \
      && [ "$quota_source" = 'quota-axi --json' ] || {
      fm_routing_refuse "NOT_VERIFIABLE(QUOTA)" "multi-candidate route lacks the required quota basis"
      return 1
    }
    fm_routing_private_input "$quota_snapshot" "NOT_VERIFIABLE(QUOTA)" "NOT_VERIFIABLE(QUOTA)" || return 1
    jq -e '
      type == "object"
      and (.schemaVersion == 5)
      and (.generatedAt | type == "string" and length > 0)
      and (.providers | type == "array" and length > 0 and all(.[];
        type == "object"
        and (.provider | type == "string" and length > 0)
        and (.state | type == "object")
        and (.quotaSemantics | type == "object")))
    ' "$quota_snapshot" >/dev/null 2>&1 || {
      fm_routing_refuse "NOT_VERIFIABLE(QUOTA)" "quota snapshot is not schema 5 provider evidence"
      return 1
    }
    actual_quota_hash=$(fm_routing_sha256_file "$quota_snapshot") || {
      fm_routing_refuse "NOT_VERIFIABLE(QUOTA)" "quota snapshot SHA-256 could not be computed"
      return 1
    }
    quota_hash=$(jq -r '.quota.snapshot_sha256' "$pending")
    quota_observed=$(jq -r '.quota.observed_at' "$pending")
    snapshot_observed=$(jq -r '.generatedAt' "$quota_snapshot")
    [ "$quota_hash" = "$actual_quota_hash" ] && [ "$quota_observed" = "$snapshot_observed" ] || {
      fm_routing_refuse "NOT_VERIFIABLE(QUOTA)" "receipt is not bound to the exact quota snapshot"
      return 1
    }
    case "$freshness_mode" in
      fresh) fm_routing_timestamp_fresh "$quota_observed" "NOT_VERIFIABLE(QUOTA)" || return 1 ;;
      committed)
        fm_routing_iso_epoch "$quota_observed" >/dev/null || {
          fm_routing_refuse "NOT_VERIFIABLE(QUOTA)" "timestamp is not RFC3339 UTC"
          return 1
        }
        ;;
    esac
  fi

  FM_ROUTING_BRIEF_FINAL=$brief
  FM_ROUTING_BRIEF_HASH=$brief_hash
}

fm_routing_decision_persist_prepared() {
  local snapshot_dir=$FM_ROUTING_PREPARED_DIR data=$FM_ROUTING_PREPARED_DATA
  local id=$FM_ROUTING_PREPARED_ID source_pending=$FM_ROUTING_PREPARED_SOURCE_PENDING
  local home=$FM_ROUTING_PREPARED_HOME task_dir prepared_pending final brief_final generation generated_at meta prior result
  [ -n "$snapshot_dir" ] && [ -d "$snapshot_dir" ] && [ "$FM_ROUTING_PREPARED_PUBLISHED" -eq 0 ] || {
    fm_routing_refuse "PERSISTENCE_REFUSED" "no validated routing decision is prepared"
    return 1
  }
  task_dir="$data/$id"
  prepared_pending="$task_dir/routing-decision.pending.json"
  generation=$FM_ROUTING_PREPARED_GENERATION
  final="$(dirname "$source_pending")/routing-generation.$generation/receipt.json"
  brief_final="$(dirname "$source_pending")/routing-generation.$generation/brief.md"
  generated_at=$(jq -r '.generated_at' "$prepared_pending")
  fm_routing_timestamp_fresh "$generated_at" "STALE" || return 1
  meta="$home/state/$id.meta"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    prior=$(awk -F= '$1 == "routing_decision" { print substr($0, index($0, "=") + 1); count++ } END { if (count > 1) exit 1 }' "$meta") || {
      fm_routing_refuse "PERSISTENCE_REFUSED" "current routing receipt pointer is ambiguous"
      return 1
    }
    [ "$prior" != "$final" ] || {
      fm_routing_refuse "PERSISTENCE_REFUSED" "receipt generation already authorizes the current agent"
      return 1
    }
  fi
  result=$(fm_routing_fs_boundary consume-generation "$(dirname "$source_pending")" "$generation" 2>&1) || {
    fm_routing_refuse "PERSISTENCE_REFUSED" "$result"
    return 1
  }
  [ "$result" = "$generation" ] || {
    fm_routing_refuse "PERSISTENCE_REFUSED" "consumed-generation ledger returned an unexpected identity"
    return 1
  }
  result=$(fm_routing_fs_boundary publish \
    "$(dirname "$source_pending")" "$snapshot_dir" \
    "$FM_ROUTING_PREPARED_DIR_DEV" "$FM_ROUTING_PREPARED_DIR_INO" \
    "$FM_ROUTING_PREPARED_PENDING_DEV" "$FM_ROUTING_PREPARED_PENDING_INO" \
    "$id" "$generation" 2>&1) || {
    fm_routing_refuse "PERSISTENCE_REFUSED" "$result"
    return 1
  }
  generation=$result
  FM_ROUTING_PREPARED_GENERATION=$generation
  FM_ROUTING_PREPARED_PUBLISHED=1
  FM_ROUTING_DECISION_FINAL=$final
  FM_ROUTING_BRIEF_FINAL=$brief_final
}

fm_routing_decision_consume_prepared() {
  [ "$FM_ROUTING_PREPARED_PUBLISHED" -eq 1 ] || return 1
}

fm_routing_decision_discard_prepared() {
  FM_ROUTING_PREPARED_DIR=
  FM_ROUTING_PREPARED_DATA=
  FM_ROUTING_PREPARED_ID=
  FM_ROUTING_PREPARED_HOME=
  FM_ROUTING_PREPARED_SOURCE_PENDING=
  FM_ROUTING_PREPARED_DIR_DEV=
  FM_ROUTING_PREPARED_DIR_INO=
  FM_ROUTING_PREPARED_PENDING_DEV=
  FM_ROUTING_PREPARED_PENDING_INO=
  FM_ROUTING_PREPARED_GENERATION=
  FM_ROUTING_PREPARED_PUBLISHED=0
  FM_ROUTING_DECISION_FINAL=
  FM_ROUTING_BRIEF_FINAL=
  FM_ROUTING_BRIEF_HASH=
}

fm_routing_decision_seal_prepared() {
  [ "$FM_ROUTING_PREPARED_PUBLISHED" -eq 1 ] || return 1
  FM_ROUTING_PREPARED_DIR=
  FM_ROUTING_PREPARED_DATA=
  FM_ROUTING_PREPARED_ID=
  FM_ROUTING_PREPARED_HOME=
  FM_ROUTING_PREPARED_SOURCE_PENDING=
  FM_ROUTING_PREPARED_DIR_DEV=
  FM_ROUTING_PREPARED_DIR_INO=
  FM_ROUTING_PREPARED_PENDING_DEV=
  FM_ROUTING_PREPARED_PENDING_INO=
  FM_ROUTING_PREPARED_GENERATION=
  FM_ROUTING_PREPARED_PUBLISHED=0
}

fm_routing_decision_validate_and_prepare() { # <data> <canonical-config> <task-id> <harness> <model> <effort> <home> <raw:0|1> <launch> <model-fragment> <effort-fragment> [fresh|committed]
  local data=$1 config_dir=$2 id=$3 task_dir source_pending
  local snapshot_name snapshot_dir snapshot_data snapshot_config status snapshot_result snapshot_error

  FM_ROUTING_DECISION_FINAL=
  FM_ROUTING_BRIEF_FINAL=
  FM_ROUTING_BRIEF_HASH=
  FM_ROUTING_PREPARED_DIR=
  FM_ROUTING_PREPARED_DATA=
  FM_ROUTING_PREPARED_ID=
  FM_ROUTING_PREPARED_HOME=
  FM_ROUTING_PREPARED_SOURCE_PENDING=
  FM_ROUTING_PREPARED_DIR_DEV=
  FM_ROUTING_PREPARED_DIR_INO=
  FM_ROUTING_PREPARED_PENDING_DEV=
  FM_ROUTING_PREPARED_PENDING_INO=
  FM_ROUTING_PREPARED_GENERATION=
  FM_ROUTING_PREPARED_PUBLISHED=0
  task_dir="$data/$id"
  source_pending="$task_dir/routing-decision.pending.json"
  command -v jq >/dev/null 2>&1 || {
    fm_routing_refuse "NOT_VERIFIABLE(SCHEMA)" "jq is unavailable"
    return 1
  }

  snapshot_result=$(fm_routing_fs_boundary snapshot "$task_dir" "$config_dir" "$id" 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    snapshot_error=$snapshot_result
    fm_routing_decision_discard_prepared
    case "$snapshot_error" in
      *routing-decision.pending.json*) fm_routing_refuse "missing" "$snapshot_error" ;;
      *routing-intent.json*) fm_routing_refuse "missing" "$snapshot_error" ;;
      *brief.md*) fm_routing_refuse "NOT_VERIFIABLE(BRIEF)" "$snapshot_error" ;;
      *crew-dispatch.json*) fm_routing_refuse "NOT_VERIFIABLE(CONFIG)" "$snapshot_error" ;;
      *quota-snapshot.json*) fm_routing_refuse "NOT_VERIFIABLE(QUOTA)" "$snapshot_error" ;;
      *) fm_routing_refuse "NOT_VERIFIABLE(SNAPSHOT)" "$snapshot_error" ;;
    esac
    return 1
  fi
  IFS=$'\t' read -r snapshot_name FM_ROUTING_PREPARED_DIR_DEV FM_ROUTING_PREPARED_DIR_INO FM_ROUTING_PREPARED_PENDING_DEV FM_ROUTING_PREPARED_PENDING_INO _ FM_ROUTING_PREPARED_GENERATION <<<"$snapshot_result"
  snapshot_dir="$task_dir/$snapshot_name"
  FM_ROUTING_PREPARED_DIR=$snapshot_dir
  snapshot_data="$snapshot_dir/data"
  snapshot_config="$snapshot_dir/config"

  fm_routing_decision_validate_snapshot \
    "$snapshot_data" "$snapshot_config" "$id" "$4" "$5" "$6" "$7" "$8" "$9" \
    "${10:-}" "${11:-}" "$source_pending" "$snapshot_dir" "${12:-fresh}"
  status=$?
  if [ "$status" -ne 0 ]; then
    fm_routing_decision_discard_prepared
    return "$status"
  fi
  FM_ROUTING_PREPARED_DATA=$snapshot_data
  FM_ROUTING_PREPARED_ID=$id
  FM_ROUTING_PREPARED_HOME=$7
  FM_ROUTING_PREPARED_SOURCE_PENDING=$source_pending
}

fm_routing_decision_validate_committed_handoff() { # <data> <canonical-config> <task-id> <harness> <model> <effort> <home> <raw:0|1> <launch> <model-fragment> <effort-fragment> <prior-receipt>
  local data=$1 id=$3 prior_receipt=${12:-} task_dir generation final brief_final result
  fm_routing_decision_validate_and_prepare \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
    "${10:-}" "${11:-}" committed || return 1
  task_dir="$data/$id"
  generation=$FM_ROUTING_PREPARED_GENERATION
  final="$task_dir/routing-generation.$generation/receipt.json"
  brief_final="$task_dir/routing-generation.$generation/brief.md"
  [ "$prior_receipt" != "$final" ] || {
    fm_routing_refuse "PERSISTENCE_REFUSED" "receipt generation already authorizes the current agent"
    return 1
  }
  result=$(fm_routing_fs_boundary verify-committed-generation \
    "$task_dir" "$FM_ROUTING_PREPARED_DIR" \
    "$FM_ROUTING_PREPARED_DIR_DEV" "$FM_ROUTING_PREPARED_DIR_INO" \
    "$id" "$generation" 2>&1) || {
    fm_routing_refuse "PERSISTENCE_REFUSED" "$result"
    return 1
  }
  [ "$result" = "$generation" ] || {
    fm_routing_refuse "PERSISTENCE_REFUSED" "committed generation verification returned an unexpected identity"
    return 1
  }
  FM_ROUTING_DECISION_FINAL=$final
  FM_ROUTING_BRIEF_FINAL=$brief_final
}

fm_routing_decision_seal_committed_handoff() {
  [ -n "$FM_ROUTING_PREPARED_DIR" ] \
    && [ -n "$FM_ROUTING_PREPARED_GENERATION" ] \
    && [ "$FM_ROUTING_PREPARED_PUBLISHED" -eq 0 ] \
    && [ -n "$FM_ROUTING_DECISION_FINAL" ] \
    && [ -n "$FM_ROUTING_BRIEF_FINAL" ] || return 1
  FM_ROUTING_PREPARED_DIR=
  FM_ROUTING_PREPARED_DATA=
  FM_ROUTING_PREPARED_ID=
  FM_ROUTING_PREPARED_HOME=
  FM_ROUTING_PREPARED_SOURCE_PENDING=
  FM_ROUTING_PREPARED_DIR_DEV=
  FM_ROUTING_PREPARED_DIR_INO=
  FM_ROUTING_PREPARED_PENDING_DEV=
  FM_ROUTING_PREPARED_PENDING_INO=
  FM_ROUTING_PREPARED_GENERATION=
}

fm_routing_decision_validate_and_persist() { # <data> <canonical-config> <task-id> <harness> <model> <effort> <home> <raw:0|1> <launch> <model-fragment> <effort-fragment>
  local status
  fm_routing_decision_validate_and_prepare "$@" || return 1
  fm_routing_decision_persist_prepared
  status=$?
  if [ "$status" -eq 0 ]; then
    fm_routing_decision_consume_prepared || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_routing_decision_seal_prepared || status=1
  else
    fm_routing_decision_discard_prepared
  fi
  return "$status"
}
