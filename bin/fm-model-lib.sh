# shellcheck shell=bash
# fm-model-lib.sh - requested vs effective model metadata for crew tasks.
#
# requested_model is spawn configuration (model= / requested_model= in meta).
# effective_model is runtime-verified only; never inferred from aliases.
# Model history lives in state/<id>.model-history (one line per change).

FM_MODEL_SOURCE_SPAWN=spawn-config
FM_MODEL_SOURCE_PENDING=pending
FM_MODEL_SOURCE_UNKNOWN=unknown
FM_MODEL_DISPLAY_SOURCE=fm-model-display

fm_model_harness_label() {  # <harness>
  case "$1" in
    claude) printf 'Claude' ;;
    cursor) printf 'Cursor' ;;
    grok) printf 'Grok' ;;
    codex) printf 'Codex' ;;
    opencode) printf 'OpenCode' ;;
    pi|pi-signed) printf 'Pi' ;;
    kimi) printf 'Kimi' ;;
    muse) printf 'Muse' ;;
    fable) printf 'Fable' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_model_source_label() {  # <harness> <effective-model-id>
  local harness=$1 effective=$2 effective_lc
  effective_lc=$(printf '%s' "$effective" | tr '[:upper:]' '[:lower:]')
  case "$effective_lc" in
    cursor-grok-*) printf 'Cursor · Grok' ;;
    xai/grok-*|grok-*) printf 'xAI · Grok' ;;
    claude-*)
      if [ "$harness" = cursor ]; then
        printf 'Cursor · Claude'
      else
        printf 'Anthropic · Claude'
      fi
      ;;
    *) printf '%s' "$(fm_model_harness_label "$harness")" ;;
  esac
}

fm_model_alias_token() {  # <token>
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    ''|default|auto|sonnet|opus|haiku|low|medium|high|xhigh|max) return 0 ;;
    *) return 1 ;;
  esac
}

fm_model_id_is_exact() {  # <model-id>
  local id=$1
  [ -n "$id" ] || return 1
  fm_model_alias_token "$id" && return 1
  case "$id" in
    UNKNOWN|unknown|pending|PENDING) return 1 ;;
  esac
  case "$id" in
    *-*|*/*) return 0 ;;
  esac
  return 1
}

fm_model_meta_get() {  # <meta> <key>
  fm_meta_get "$1" "$2"
}

fm_model_requested() {  # <meta>
  local meta=$1 v
  v=$(fm_model_meta_get "$meta" requested_model)
  [ -n "$v" ] || v=$(fm_model_meta_get "$meta" model)
  printf '%s' "${v:-default}"
}

fm_model_effective() {  # <meta>
  local meta=$1 v
  v=$(fm_model_meta_get "$meta" effective_model)
  [ -n "$v" ] || { printf 'pending'; return 0; }
  printf '%s' "$v"
}

fm_model_effective_source() {  # <meta>
  local meta=$1 v
  v=$(fm_model_meta_get "$meta" effective_model_source)
  printf '%s' "${v:-}"
}

fm_model_history_file() {  # <state> <id>
  printf '%s/%s.model-history' "$1" "$2"
}

fm_model_history_append() {  # <state> <id> <stamp> <model> [tag]
  local state=$1 id=$2 stamp=$3 model=$4 tag=${5:-}
  local file line
  file=$(fm_model_history_file "$state" "$id")
  line="$stamp $model"
  [ -z "$tag" ] || line="$line [$tag]"
  printf '%s\n' "$line" >> "$file"
}

fm_model_meta_upsert() {  # <meta> <key> <value>
  local meta=$1 key=$2 value=$3 tmp
  tmp="${meta}.model-upsert.$$"
  awk -F= -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $1 == key { if (!done) { print key "=" value; done = 1 }; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$meta" > "$tmp" && mv -f "$tmp" "$meta"
}

fm_model_init_spawn_meta() {  # <meta> <requested-model>
  local meta=$1 requested=$2
  [ -n "$requested" ] || requested=default
  fm_model_meta_upsert "$meta" requested_model "$requested"
  fm_model_meta_upsert "$meta" model "$requested"
  fm_model_meta_upsert "$meta" effective_model pending
  fm_model_meta_upsert "$meta" effective_model_source "$FM_MODEL_SOURCE_SPAWN"
}

# On relaunch/recovery, keep a verified effective model instead of resetting to
# pending. Aliases and pending stay probeable; UNKNOWN stays explicit.
fm_model_relaunch_effective() {  # <prior-meta>
  local prior=$1 eff src
  eff=$(fm_model_effective "$prior")
  src=$(fm_model_effective_source "$prior")
  if fm_model_id_is_exact "$eff"; then
    printf '%s\t%s\n' "$eff" "${src:-$FM_MODEL_SOURCE_UNKNOWN}"
    return 0
  fi
  if [ "$eff" = UNKNOWN ] || [ "$eff" = unknown ]; then
    printf '%s\t%s\n' UNKNOWN "${src:-$FM_MODEL_SOURCE_UNKNOWN}"
    return 0
  fi
  printf '%s\t%s\n' pending "$FM_MODEL_SOURCE_SPAWN"
}

fm_model_record_effective() {  # <state> <id> <meta> <model> <source> [fallback-tag]
  local state=$1 id=$2 meta=$3 model=$4 source=$5 tag=${6:-}
  local prior stamp recorded
  [ -f "$meta" ] || return 1
  [ -n "$model" ] || return 1
  [ -n "$source" ] || return 1
  if ! fm_model_id_is_exact "$model"; then
    model=UNKNOWN
    source=$FM_MODEL_SOURCE_UNKNOWN
  fi
  prior=$(fm_model_effective "$meta")
  [ "$prior" = "$model" ] && [ "$(fm_model_effective_source "$meta")" = "$source" ] && return 0
  stamp=$(date '+%H:%M')
  fm_model_meta_upsert "$meta" effective_model "$model"
  fm_model_meta_upsert "$meta" effective_model_source "$source"
  if [ "$prior" != pending ] && [ "$prior" != "$model" ] && [ -n "$prior" ]; then
  fm_model_history_append "$state" "$id" "$stamp" "$model" "$tag"
  elif [ "$prior" = pending ] && [ "$model" != pending ] && [ "$model" != UNKNOWN ]; then
    fm_model_history_append "$state" "$id" "$stamp" "$model" "$tag"
  fi
  recorded=1
  return 0
}

fm_model_display_compact() {  # <meta>
  local meta=$1 harness requested effort effective display requested_lc effective_lc source_label
  harness=$(fm_model_meta_get "$meta" harness)
  requested=$(fm_model_requested "$meta")
  effort=$(fm_model_meta_get "$meta" effort)
  effective=$(fm_model_effective "$meta")
  [ "$effort" = default ] && effort=
  if fm_model_id_is_exact "$effective"; then
    source_label=$(fm_model_source_label "$harness" "$effective")
  else
    source_label=$(fm_model_harness_label "$harness")
  fi
  case "$effective" in
    pending|PENDING) effective='pending verification' ;;
    UNKNOWN|unknown) effective=UNKNOWN ;;
  esac
  display="$source_label · $effective"
  [ -z "$effort" ] || display="$display · $effort"
  requested_lc=$(printf '%s' "$requested" | tr '[:upper:]' '[:lower:]')
  effective_lc=$(printf '%s' "$effective" | tr '[:upper:]' '[:lower:]')
  if [ "$effective" != pending ] && [ "$effective" != 'pending verification' ] \
     && [ "$effective" != UNKNOWN ] \
     && [ "$requested_lc" != "$effective_lc" ]; then
    if fm_model_alias_token "$requested"; then
      display="$display ⚠ requested: $requested"
    elif fm_model_id_is_exact "$requested"; then
      display="$display ⚠ requested: $requested"
    fi
  fi
  printf '%s' "$display"
}

fm_model_report_lines() {  # <meta>
  local meta=$1 harness requested effort effective source
  harness=$(fm_model_meta_get "$meta" harness)
  requested=$(fm_model_requested "$meta")
  effort=$(fm_model_meta_get "$meta" effort)
  effective=$(fm_model_effective "$meta")
  source=$(fm_model_effective_source "$meta")
  case "$effective" in
    pending|PENDING) effective='pending verification' ;;
  esac
  printf 'Harness: %s\n' "$(fm_model_harness_label "$harness")"
  printf 'Requested Model: %s\n' "$requested"
  printf 'Effective Model: %s\n' "$effective"
  [ -z "$effort" ] || [ "$effort" = default ] || printf 'Effort: %s\n' "$effort"
  [ -z "$source" ] || printf 'Model Source: %s\n' "$source"
}
