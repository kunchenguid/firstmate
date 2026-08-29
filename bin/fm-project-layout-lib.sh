#!/usr/bin/env bash
# Read-only helpers for fm-project-layout-preflight.sh.
#
# This library owns path canonicalization, portable ownership/mode inspection,
# local-filesystem classification, Git topology reads, credential redaction,
# JSON encoding, and the evidence fingerprint used by the preflight command.
# Sourcing it has no side effects.

fmp_json_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

fmp_has_control() {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;;
  esac
  return 1
}

fmp_absolute_path_is_lexically_safe() {
  local path=$1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  fmp_has_control "$path" && return 1
  case "/$path/" in
    *'/../'*|*'/./'*) return 1 ;;
  esac
  return 0
}

fmp_path_has_symlink_component() {
  local path=$1 rest component current=
  fmp_absolute_path_is_lexically_safe "$path" || return 0
  rest=${path#/}
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) component=${rest%%/*}; rest=${rest#*/} ;;
      *) component=$rest; rest= ;;
    esac
    [ -n "$component" ] || continue
    current="$current/$component"
    [ -L "$current" ] && return 0
  done
  return 1
}

fmp_existing_path_physical() {
  local path=$1 parent base resolved
  [ -e "$path" ] || [ -L "$path" ] || return 1
  if [ -d "$path" ]; then
    resolved=$(cd "$path" 2>/dev/null && pwd -P)
  else
    parent=$(dirname "$path")
    base=$(basename "$path")
    resolved=$(cd "$parent" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$base")
  fi
  [ -n "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

fmp_nearest_existing_ancestor() {
  local path=$1
  fmp_absolute_path_is_lexically_safe "$path" || return 1
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    [ "$path" != / ] || break
    path=$(dirname "$path")
  done
  [ -e "$path" ] || [ -L "$path" ] || return 1
  fmp_existing_path_physical "$path"
}

fmp_path_is_within() {
  local parent=$1 child=$2
  [ "$parent" != "$child" ] || return 1
  case "$child/" in
    "$parent/"*) return 0 ;;
  esac
  return 1
}

fmp_stat_uid() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

fmp_stat_mode() {
  if [ "$(uname -s)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fmp_mode_group_or_world_writable() {
  local mode=$1 group world
  case "$mode" in
    *[!0-7]*|'') return 0 ;;
  esac
  mode=${mode#"${mode%???}"}
  group=${mode%?}
  group=${group#?}
  world=${mode#??}
  case "$group$world" in
    *2*|*3*|*6*|*7*) return 0 ;;
  esac
  return 1
}

fmp_filesystem_source() {
  LC_ALL=C df -P "$1" 2>/dev/null | awk 'NF { line=$0 } END { split(line, f, /[[:space:]]+/); print f[1] }'
}

fmp_filesystem_locality() {
  local source=$1
  case "$source" in
    /dev/*|overlay|overlayfs|tmpfs|devtmpfs|ramfs) printf '%s\n' local ;;
    *:*|//*) printf '%s\n' network ;;
    *) printf '%s\n' unknown ;;
  esac
}

fmp_git_absolute_dir() {
  local repo=$1 kind=$2 value
  case "$kind" in
    git) value=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null) || return 1 ;;
    common) value=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  fmp_existing_path_physical "$value"
}

fmp_git_object_format() {
  local repo=$1 format
  format=$(git -C "$repo" rev-parse --show-object-format 2>/dev/null) || format=
  if [ -z "$format" ]; then
    format=$(git -C "$repo" config --get extensions.objectFormat 2>/dev/null) || format=
  fi
  printf '%s\n' "${format:-sha1}"
}

fmp_git_default_branch() {
  local repo=$1 ref
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=
  case "$ref" in
    origin/*) printf '%s\n' "${ref#origin/}"; return 0 ;;
  esac
  for ref in main master; do
    if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" >/dev/null; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

fmp_meta_value() {
  local file=$1 key=$2
  awk -v wanted="$key" '
    index($0, wanted "=") == 1 {
      print substr($0, length(wanted) + 2)
      exit
    }
  ' "$file" 2>/dev/null
}

fmp_redact_origin() {
  local origin=$1 scheme rest authority
  case "$origin" in
    *://*)
      scheme=${origin%%://*}
      rest=${origin#*://}
      rest=${rest%%\?*}
      rest=${rest%%\#*}
      authority=${rest%%/*}
      case "$authority" in
        *@*)
          rest=${rest#*@}
          printf '%s://<redacted>@%s\n' "$scheme" "$rest"
          return 0
          ;;
      esac
      printf '%s://%s\n' "$scheme" "$rest"
      return 0
      ;;
  esac
  printf '%s\n' "$origin"
}

fmp_origin_has_http_credentials() {
  local origin=$1 rest authority
  case "$origin" in
    http://*|https://*)
      rest=${origin#*://}
      authority=${rest%%/*}
      case "$authority" in *@*) return 0 ;; esac
      case "$origin" in *\?*|*\#*) return 0 ;; esac
      ;;
  esac
  return 1
}

fmp_fingerprint() {
  local output sum bytes
  output=$(LC_ALL=C cksum) || output="0 0"
  sum=${output%% *}
  output=${output#* }
  bytes=${output%% *}
  printf 'posix-cksum:%s:%s\n' "$sum" "$bytes"
}

fmp_csv_contains() {
  local rest=$1 wanted=$2 item
  while :; do
    case "$rest" in
      *,*) item=${rest%%,*}; rest=${rest#*,} ;;
      *) item=$rest; rest= ;;
    esac
    item=$(printf '%s' "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$item" = "$wanted" ] && return 0
    [ -n "$rest" ] || break
  done
  return 1
}
