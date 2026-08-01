# shellcheck shell=bash
# Shared context-usage inspection primitives.
# Usage: source bin/fm-context-lib.sh after bin/fm-backend.sh.
#
# data/captain-shared.md owns the routing rule.
# This library owns only its mechanical inputs and verdicts: config/context-ceiling,
# harness-specific footer extraction, short-lived session-bound self-reports, and
# the fail-closed under|over result consumed by routing and supervision surfaces.

FM_CONTEXT_CEILING_FILE=context-ceiling
FM_CONTEXT_CEILING_DEFAULT=45
FM_CONTEXT_CEILING_ERROR=""
FM_CONTEXT_CEILING_VALUE=""
FM_CONTEXT_STATUS=""
FM_CONTEXT_SOURCE=""
FM_CONTEXT_META_IDENTITY=""
FM_CONTEXT_RESULT=""
FM_CONTEXT_SELF_REPORT_MAX_AGE=${FM_CONTEXT_SELF_REPORT_MAX_AGE:-300}

fm_context_fail() {
  FM_CONTEXT_CEILING_ERROR=$1
  return 1
}

fm_context_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_context_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# fm_context_ceiling_file_valid <path>
# Accept exactly one base-10 integer from 0 through 100 and one newline.
fm_context_ceiling_file_valid() {
  local path=$1 links value
  FM_CONTEXT_CEILING_VALUE=""
  if [ -L "$path" ]; then
    fm_context_fail "file is symlinked"
    return 1
  fi
  if [ ! -f "$path" ]; then
    fm_context_fail "file is not a regular file"
    return 1
  fi
  links=$(fm_context_link_count "$path") || {
    fm_context_fail "could not inspect file link count"
    return 1
  }
  if [ "$links" != 1 ]; then
    fm_context_fail "file is hardlinked"
    return 1
  fi
  value=$(<"$path") || {
    fm_context_fail "could not read file"
    return 1
  }
  case "$value" in
    0|[1-9]|[1-9][0-9]|100) ;;
    *)
      fm_context_fail "value must be one decimal integer from 0 through 100"
      return 1
      ;;
  esac
  if ! printf '%s\n' "$value" | cmp -s "$path" -; then
    fm_context_fail "file must contain exactly one value followed by one newline"
    return 1
  fi
  FM_CONTEXT_CEILING_VALUE=$value
  return 0
}

# fm_context_ceiling_read <config-dir>
# Absence selects the documented default; malformed or unsafe presence fails.
fm_context_ceiling_read() {
  local config_dir=$1 path
  # Public diagnostic consumed by executable and inheritance callers.
  # shellcheck disable=SC2034
  FM_CONTEXT_CEILING_ERROR=""
  FM_CONTEXT_CEILING_VALUE=""
  if [ -L "$config_dir" ]; then
    fm_context_fail "config directory is symlinked"
    return 1
  fi
  if [ ! -e "$config_dir" ]; then
    FM_CONTEXT_CEILING_VALUE=$FM_CONTEXT_CEILING_DEFAULT
    printf '%s\n' "$FM_CONTEXT_CEILING_VALUE"
    return 0
  fi
  if [ ! -d "$config_dir" ]; then
    fm_context_fail "config directory is not a directory"
    return 1
  fi
  path="$config_dir/$FM_CONTEXT_CEILING_FILE"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    FM_CONTEXT_CEILING_VALUE=$FM_CONTEXT_CEILING_DEFAULT
    printf '%s\n' "$FM_CONTEXT_CEILING_VALUE"
    return 0
  fi
  fm_context_ceiling_file_valid "$path" || return 1
  printf '%s\n' "$FM_CONTEXT_CEILING_VALUE"
}

fm_context_extract_percent() {  # <harness> <capture>
  local harness=$1 capture=$2 percent=""
  case "$harness" in
    claude*)
      percent=$(printf '%s\n' "$capture" \
        | sed -nE 's/.*\[[^]]*\][[:space:]]+([0-9]{1,3})%[[:space:]]*\|.*/\1/p; s/.*\([^)]*[Cc]ontext[^)]*\).*[[:space:]]([0-9]{1,3})%[[:space:]]*$/\1/p' \
        | tail -1)
      ;;
    pi|pi-signed)
      percent=$(printf '%s\n' "$capture" \
        | sed -nE 's/.*\([^)]*[Cc]ontext[^)]*\).*[[:space:]]([0-9]{1,3})%[[:space:]]*$/\1/p' \
        | tail -1)
      ;;
    kimi*)
      percent=$(printf '%s\n' "$capture" \
        | sed -nE 's/^[[:space:]]*[Cc]ontext:[[:space:]]*([0-9]{1,3})%([[:space:]].*)?$/\1/p' \
        | tail -1)
      ;;
    *) return 1 ;;
  esac
  [ -n "$percent" ] || return 1
  [ "$percent" -le 100 ] || return 1
  printf '%s\n' "$percent"
}

fm_context_self_report_path() {  # <state-dir> <task-id>
  printf '%s/%s.context-self-report\n' "$1" "$2"
}

fm_context_self_report_read() {  # <state-dir> <task-id> <meta-identity>
  local state=$1 id=$2 identity=$3 path version task reported_identity percent reported_at now age max_age
  path=$(fm_context_self_report_path "$state" "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_context_link_count "$path")" = 1 ] || return 1
  version=$(fm_meta_get "$path" version)
  task=$(fm_meta_get "$path" task)
  reported_identity=$(fm_meta_get "$path" meta_sha256)
  percent=$(fm_meta_get "$path" percent)
  reported_at=$(fm_meta_get "$path" reported_at)
  [ "$version" = 1 ] && [ "$task" = "$id" ] && [ "$reported_identity" = "$identity" ] || return 1
  case "$percent" in ''|*[!0-9]*) return 1 ;; esac
  [ "$percent" -le 100 ] || return 1
  case "$reported_at" in ''|*[!0-9]*) return 1 ;; esac
  max_age=$FM_CONTEXT_SELF_REPORT_MAX_AGE
  case "$max_age" in ''|*[!0-9]*|0) max_age=300 ;; esac
  now=$(date +%s) || return 1
  [ "$now" -ge "$reported_at" ] || return 1
  age=$((now - reported_at))
  [ "$age" -le "$max_age" ] || return 1
  printf '%s\n' "$percent"
}

fm_context_self_report_write() {  # <state-dir> <task-id> <percent>
  local state=$1 id=$2 percent=$3 meta identity path tmp now
  case "$id" in ''|*[!A-Za-z0-9._-]*) fm_context_fail "invalid task id"; return 1 ;; esac
  case "$percent" in ''|*[!0-9]*) fm_context_fail "percent must be an integer from 0 through 100"; return 1 ;; esac
  if [ "$percent" -gt 100 ]; then
    fm_context_fail "percent must be an integer from 0 through 100"
    return 1
  fi
  [ -d "$state" ] && [ ! -L "$state" ] || { fm_context_fail "state directory is unavailable"; return 1; }
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { fm_context_fail "task metadata is unavailable"; return 1; }
  identity=$(fm_context_sha256_file "$meta") || { fm_context_fail "could not identify task metadata"; return 1; }
  path=$(fm_context_self_report_path "$state" "$id")
  tmp=$(umask 077; mktemp "$state/.$id.context-self-report.XXXXXX" 2>/dev/null) \
    || { fm_context_fail "could not create self-report"; return 1; }
  now=$(date +%s) || { rm -f "$tmp"; fm_context_fail "could not timestamp self-report"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'task=%s\n' "$id"
    printf 'meta_sha256=%s\n' "$identity"
    printf 'percent=%s\n' "$percent"
    printf 'reported_at=%s\n' "$now"
  } > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    fm_context_fail "could not publish self-report"
    return 1
  fi
  printf 'CONTEXT_CEILING id=%s self_reported=%s\n' "$id" "$percent"
}

fm_context_set_result() {
  local id=$1 status=$2 percent=$3 threshold=$4 source=$5 reason=$6
  # Public verdict consumed by routing and supervision callers.
  # shellcheck disable=SC2034
  FM_CONTEXT_STATUS=$status
  FM_CONTEXT_SOURCE=$source
  FM_CONTEXT_RESULT="CONTEXT_CEILING id=$id status=$status percent=${percent:-unreadable} threshold=$threshold source=$source"
  [ -z "$reason" ] || FM_CONTEXT_RESULT="$FM_CONTEXT_RESULT reason=$reason"
}

# fm_context_inspect_meta <meta-file> <state-dir> <config-dir>
# Sets FM_CONTEXT_* and returns success for a complete verdict, including over.
fm_context_inspect_meta() {
  local meta=$1 state=$2 config=$3 id harness backend target threshold capture percent
  id=${meta##*/}
  id=${id%.meta}
  FM_CONTEXT_META_IDENTITY=""
  FM_CONTEXT_SOURCE=""
  if ! threshold=$(fm_context_ceiling_read "$config" 2>/dev/null); then
    fm_context_set_result "$id" over "" invalid config-error "invalid-config"
    return 0
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    fm_context_set_result "$id" over "" "$threshold" metadata-unreadable "unreadable"
    return 0
  fi
  FM_CONTEXT_META_IDENTITY=$(fm_context_sha256_file "$meta" 2>/dev/null || true)
  harness=$(fm_meta_get "$meta" harness)
  case "$harness" in
    claude*|pi|pi-signed|kimi*)
      backend=$(fm_backend_of_meta "$meta")
      target=$(fm_backend_target_of_meta "$meta")
      if [ -n "$target" ]; then
        capture=$(fm_backend_capture "$backend" "$target" 12 "fm-$id" 2>/dev/null || true)
        percent=$(fm_context_extract_percent "$harness" "$capture" 2>/dev/null || true)
      fi
      ;;
  esac
  if [ -z "${percent:-}" ] && [ -n "$FM_CONTEXT_META_IDENTITY" ]; then
    percent=$(fm_context_self_report_read "$state" "$id" "$FM_CONTEXT_META_IDENTITY" 2>/dev/null || true)
    [ -z "$percent" ] || FM_CONTEXT_SOURCE=self-report
  fi
  if [ -z "${percent:-}" ]; then
    fm_context_set_result "$id" over "" "$threshold" external-unreadable "unreadable"
  elif [ "$percent" -ge "$threshold" ]; then
    fm_context_set_result "$id" over "$percent" "$threshold" "${FM_CONTEXT_SOURCE:-footer}" ""
  else
    fm_context_set_result "$id" under "$percent" "$threshold" "${FM_CONTEXT_SOURCE:-footer}" ""
  fi
}
