#!/usr/bin/env bash
# fm-contract-index.sh — markdown index of deferred contract topics.
#
# render (default) prints the table. --check validates the topic table.
# AGENTS.md marker comparison and the 3200-word ceiling are Unit 3.
# This script does not read AGENTS.md.
#
# Usage: fm-contract-index.sh [render]
#        fm-contract-index.sh --check [tsv]
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_CONTRACT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

_FM_CI_ID=()
_FM_CI_TRIGGER=()
_FM_CI_PATH=()
_FM_CI_SEEN=

_fm_ci_die() {
  printf 'fm-contract-index: %s\n' "$*" >&2
  return 1
}

_fm_ci_inside_root() {  # <file> <root>
  local path=$1 root=$2 guard=0 target dir base phys rootphys
  while [ -L "$path" ]; do
    guard=$((guard + 1))
    [ "$guard" -le 8 ] || return 1
    target=$(readlink "$path") || return 1
    case "$target" in
      /*) path=$target ;;
      *)
        dir=$(dirname "$path")
        path=$dir/$target
        ;;
    esac
  done
  [ -f "$path" ] || return 1
  dir=$(dirname "$path")
  base=$(basename "$path")
  phys=$(cd "$dir" && pwd -P) || return 1
  rootphys=$(cd "$root" && pwd -P) || return 1
  case "$phys/$base" in
    "$rootphys"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_fm_ci_path_ok() {  # <path> <root>
  local path=$1 root=$2 full
  case "$path" in
    ''|~*|/*|*'$'*|*'..'*) return 1 ;;
    state|state/*|data|data/*) return 1 ;;
    .agents/*) ;;
    *) return 1 ;;
  esac
  if [ -n "${HOME:-}" ]; then
    case "$path" in
      "$HOME"|"$HOME"/*) return 1 ;;
    esac
  fi
  if [ -n "${FM_HOME:-}" ]; then
    case "$path" in
      "$FM_HOME"|"$FM_HOME"/*) return 1 ;;
    esac
  fi
  full=$root/$path
  [ -f "$full" ] || return 1
  _fm_ci_inside_root "$full" "$root"
}

_fm_ci_load() {  # [tsv]
  local tsv=${1:-$SCRIPT_DIR/fm-contract-topics.tsv}
  local line header_seen=0 id trigger path extra n
  _FM_CI_ID=()
  _FM_CI_TRIGGER=()
  _FM_CI_PATH=()
  _FM_CI_SEEN=
  [ -f "$tsv" ] || { _fm_ci_die "missing topics table" || return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ''|\#*) continue ;;
    esac
    if [ "$header_seen" -eq 0 ]; then
      [ "$line" = $'id\ttrigger\tpath' ] \
        || { _fm_ci_die "topics table header is wrong" || return 1; }
      header_seen=1
      continue
    fi
    extra=
    IFS=$'\t' read -r id trigger path extra <<<"$line"
    [ -z "$extra" ] || { _fm_ci_die "topics row has too many fields" || return 1; }
    case "$id" in
      ''|*[!a-z0-9-]*) _fm_ci_die "bad topic id" || return 1 ;;
    esac
    case "$trigger" in
      *[![:space:]]*) ;;
      *) _fm_ci_die "empty trigger" || return 1 ;;
    esac
    case " $_FM_CI_SEEN " in
      *" $id "*) _fm_ci_die "duplicate topic id: $id" || return 1 ;;
    esac
    if ! _fm_ci_path_ok "$path" "$FM_CONTRACT_ROOT"; then
      _fm_ci_die "refuse path: $path" || return 1
    fi
    n=${#_FM_CI_ID[@]}
    _FM_CI_ID[n]=$id
    _FM_CI_TRIGGER[n]=$trigger
    _FM_CI_PATH[n]=$path
    _FM_CI_SEEN="$_FM_CI_SEEN $id"
  done <"$tsv"
  [ "$header_seen" -eq 1 ] || { _fm_ci_die "topics table header is wrong" || return 1; }
}

fm_contract_index_render() {
  local i n
  _fm_ci_load || return 1
  printf '%s\n' '| id | trigger | path |'
  printf '%s\n' '| --- | --- | --- |'
  n=${#_FM_CI_ID[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '| %s | %s | %s |\n' "${_FM_CI_ID[$i]}" "${_FM_CI_TRIGGER[$i]}" "${_FM_CI_PATH[$i]}"
    i=$((i + 1))
  done
}

_fm_ci_usage() {
  printf '%s\n' 'usage: fm-contract-index.sh [render]' >&2
  printf '%s\n' '       fm-contract-index.sh --check [tsv]' >&2
  return 2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-render}" in
    render)
      [ "$#" -le 1 ] || { _fm_ci_usage; exit 2; }
      fm_contract_index_render
      ;;
    --check)
      [ "$#" -le 2 ] || { _fm_ci_usage; exit 2; }
      _fm_ci_load "${2:-}"
      ;;
    *)
      _fm_ci_usage
      exit 2
      ;;
  esac
fi
