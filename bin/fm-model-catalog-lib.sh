# shellcheck shell=bash
# Model catalog file primitives.
# Usage: . bin/fm-model-catalog-lib.sh
#
# The local, primary-authoritative config/model-catalog.json setting is one JSON
# document describing paid model pools the fleet may spawn. This library owns
# safe parsing and schema validation for inheritance publication.

FM_MODEL_CATALOG_FILE="model-catalog.json"
FM_MODEL_CATALOG_INVALID_MARKER=".model-catalog.invalid-primary"
FM_MODEL_CATALOG_ERROR=""
FM_MODEL_CATALOG_QUARANTINE=""

fm_model_catalog_fail() {
  FM_MODEL_CATALOG_ERROR=$1
  [ -n "$FM_MODEL_CATALOG_ERROR" ]
  return 1
}

fm_model_catalog_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_model_catalog_config_dir_safe() {
  local dir=$1
  if [ -L "$dir" ]; then
    fm_model_catalog_fail "config directory is symlinked"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    fm_model_catalog_fail "config directory is not a directory"
    return 1
  fi
  return 0
}

# fm_model_catalog_schema_error <path>
# Prints a single-line schema reason or nothing when valid.
fm_model_catalog_schema_error() {
  local path=$1
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' "jq is required to validate model catalog JSON"
    return 0
  fi
  jq -r '
    def nonempty_string: (type == "string") and (length > 0);
    def valid_pool:
      type == "object"
      and (.pool | nonempty_string)
      and (.provider | nonempty_string)
      and (.plan | nonempty_string)
      and (.harness | nonempty_string)
      and (.account | nonempty_string)
      and (.models | type) == "array"
      and ((.models | length) > 0)
      and all(.models[]?; nonempty_string)
      and (.quota_readable | type) == "boolean"
      and ((has("gap") | not) or (.gap | type) == "string")
      and ((has("note") | not) or (.note | type) == "string")
      and all(keys_unsorted[] as $k |
        ($k | startswith("_")) or
        ($k | IN("pool","provider","plan","harness","account","models","quota_readable","gap","note"))
      );
    if type != "object" then "top-level value must be an object"
    elif (.pools | type) != "array" then "pools must be an array"
    elif (.pools | length) == 0 then "pools must be non-empty"
    elif [(.pools[]? | select(type != "object"))] | length > 0 then "each pool must be an object"
    elif [(.pools[]? | select(valid_pool | not))] | length > 0 then "each pool needs valid pool, provider, plan, harness, account, models, quota_readable, gap, and note fields"
    elif has("excluded") and ((.excluded | type) != "array") then "excluded must be an array"
    elif [(.excluded // [])[]? | select(type != "object")] | length > 0 then "each excluded entry must be an object"
    elif [(.excluded // [])[]? | select((.what? | nonempty_string | not) or (.why? | nonempty_string | not))] | length > 0 then "each excluded entry needs what and why"
    else empty
    end
  ' "$path" 2>/dev/null
}

# fm_model_catalog_file_valid <path>
# True only for a regular, single-linked file containing valid catalog JSON.
fm_model_catalog_file_valid() {
  local path=$1 links schema_err
  if [ -L "$path" ]; then
    fm_model_catalog_fail "file is symlinked"
    return 1
  fi
  if [ ! -e "$path" ]; then
    fm_model_catalog_fail "file is absent"
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_model_catalog_fail "file is not a regular file"
    return 1
  fi
  links=$(fm_model_catalog_link_count "$path") || {
    fm_model_catalog_fail "could not inspect file link count"
    return 1
  }
  if [ "$links" != 1 ]; then
    fm_model_catalog_fail "file is hardlinked"
    return 1
  fi
  if ! jq -e . "$path" >/dev/null 2>&1; then
    fm_model_catalog_fail "malformed JSON"
    return 1
  fi
  schema_err=$(fm_model_catalog_schema_error "$path")
  if [ -n "$schema_err" ]; then
    fm_model_catalog_fail "$schema_err"
    return 1
  fi
  return 0
}

fm_model_catalog_file_safe_existing() {
  local path=$1 links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  links=$(fm_model_catalog_link_count "$path") || return 1
  [ "$links" = 1 ]
}

fm_model_catalog_quarantine_invalid() {
  local path=$1 parent base quarantine links n=0 stamp
  FM_MODEL_CATALOG_QUARANTINE=""
  parent=${path%/*}
  [ "$parent" != "$path" ] || parent=.
  fm_model_catalog_config_dir_safe "$parent" || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || {
    fm_model_catalog_fail "invalid catalog cannot be safely quarantined"
    return 1
  }
  links=$(fm_model_catalog_link_count "$path") || {
    fm_model_catalog_fail "could not inspect invalid catalog link count"
    return 1
  }
  [ "$links" = 1 ] || {
    fm_model_catalog_fail "invalid catalog is hardlinked"
    return 1
  }
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$parent/$FM_MODEL_CATALOG_FILE.invalid-$stamp-$$"
  quarantine=$base
  while [ -e "$quarantine" ] || [ -L "$quarantine" ]; do
    n=$((n + 1))
    quarantine="$base.$n"
  done
  mv -- "$path" "$quarantine" || {
    fm_model_catalog_fail "could not quarantine invalid catalog"
    return 1
  }
  chmod 600 "$quarantine" || {
    fm_model_catalog_fail "could not secure quarantined catalog"
    return 1
  }
  FM_MODEL_CATALOG_QUARANTINE=$quarantine
  return 0
}

fm_model_catalog_validate_primary() {
  local path=$1 validation_error quarantine_error parent marker marker_tmp
  parent=${path%/*}
  [ "$parent" != "$path" ] || parent=.
  marker="$parent/$FM_MODEL_CATALOG_INVALID_MARKER"
  if fm_model_catalog_file_valid "$path"; then
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      fm_model_catalog_file_safe_existing "$marker" || {
        fm_model_catalog_fail "invalid-source marker is unsafe"
        return 1
      }
      rm -f -- "$marker" || {
        fm_model_catalog_fail "could not clear corrected invalid-source marker"
        return 1
      }
    fi
    return 0
  fi
  validation_error=$FM_MODEL_CATALOG_ERROR
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_model_catalog_file_safe_existing "$marker" || {
      fm_model_catalog_fail "$validation_error; invalid-source marker is unsafe"
      return 1
    }
  fi
  if fm_model_catalog_quarantine_invalid "$path"; then
    marker_tmp=$(mktemp "$parent/.model-catalog-invalid.XXXXXX") || {
      mv -- "$FM_MODEL_CATALOG_QUARANTINE" "$path" 2>/dev/null || true
      fm_model_catalog_fail "$validation_error; could not stage invalid-source marker"
      return 1
    }
    printf '%s\n' "$FM_MODEL_CATALOG_QUARANTINE" > "$marker_tmp"
    chmod 600 "$marker_tmp" || {
      rm -f -- "$marker_tmp"
      mv -- "$FM_MODEL_CATALOG_QUARANTINE" "$path" 2>/dev/null || true
      fm_model_catalog_fail "$validation_error; could not secure invalid-source marker"
      return 1
    }
    if ! mv -f -- "$marker_tmp" "$marker"; then
      rm -f -- "$marker_tmp"
      mv -- "$FM_MODEL_CATALOG_QUARANTINE" "$path" 2>/dev/null || true
      fm_model_catalog_fail "$validation_error; could not publish invalid-source marker"
      return 1
    fi
    fm_model_catalog_fail "$validation_error; quarantined as $FM_MODEL_CATALOG_QUARANTINE"
  else
    quarantine_error=$FM_MODEL_CATALOG_ERROR
    fm_model_catalog_fail "$validation_error; quarantine failed: $quarantine_error"
  fi
  return 1
}

fm_model_catalog_absence_allowed() {
  local config_dir=$1 marker
  marker="$config_dir/$FM_MODEL_CATALOG_INVALID_MARKER"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_model_catalog_file_safe_existing "$marker" || {
      fm_model_catalog_fail "invalid-source marker is unsafe"
      return 1
    }
    fm_model_catalog_fail "invalid primary catalog remains quarantined; remove $marker to confirm intentional absence"
    return 1
  fi
  return 0
}

# fm_model_catalog_read <config-dir>
# Confirms the catalog file under config-dir is present and schema-valid.
fm_model_catalog_read() {
  local config_dir=$1 path
  fm_model_catalog_config_dir_safe "$config_dir" || return 1
  path="$config_dir/$FM_MODEL_CATALOG_FILE"
  if ! fm_model_catalog_file_valid "$path"; then
    [ -n "$FM_MODEL_CATALOG_ERROR" ] || fm_model_catalog_fail "invalid model catalog"
    return 1
  fi
  return 0
}
