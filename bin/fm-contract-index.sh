#!/usr/bin/env bash
# fm-contract-index.sh - markdown index of deferred contract topics.
#
# render (default) prints the table.
# --check with no table argument also compares the AGENTS.md marker block
# to that table and enforces a 3200-word ceiling (wc -w).
# --check with a table argument validates that table only.
# --write replaces the marker block in AGENTS.md.
# FM_CONTRACT_AGENTS, when set, is the file those two modes read.
# Tests point it at a copy so a drifted index or a fat file can fail
# without editing the tracked contract.
#
# Usage: fm-contract-index.sh [render]
#        fm-contract-index.sh --check [tsv]
#        fm-contract-index.sh --write
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

_fm_ci_agents_path() {
  if [ -n "${FM_CONTRACT_AGENTS:-}" ]; then
    printf '%s\n' "$FM_CONTRACT_AGENTS"
  else
    printf '%s\n' "$FM_CONTRACT_ROOT/AGENTS.md"
  fi
}

_fm_ci_extract_index() {  # <agents-file>
  awk '
    $0 == "<!-- fm-contract-index:begin -->" { n++; cap = 1; next }
    $0 == "<!-- fm-contract-index:end -->" {
      if (cap != 1) bad = 1
      cap = 0
      ended++
      next
    }
    cap == 1 { print }
    END {
      if (n != 1 || ended != 1 || bad == 1 || cap == 1) exit 1
    }
  ' "$1"
}

_fm_ci_check_agents() {
  local agents rendered extracted words
  agents=$(_fm_ci_agents_path)
  [ -f "$agents" ] || { _fm_ci_die "missing AGENTS.md" || return 1; }
  rendered=$(fm_contract_index_render) || return 1
  if ! extracted=$(_fm_ci_extract_index "$agents"); then
    _fm_ci_die "AGENTS.md contract index markers missing or repeated" || return 1
  fi
  [ "$extracted" = "$rendered" ] || {
    _fm_ci_die "AGENTS.md contract index drifted" || return 1
  }
  words=$(wc -w <"$agents" | tr -d '[:space:]') || {
    _fm_ci_die "could not count AGENTS.md words" || return 1
  }
  case "$words" in
    ''|*[!0-9]*) _fm_ci_die "could not count AGENTS.md words" || return 1 ;;
  esac
  [ "$words" -le 3200 ] || {
    _fm_ci_die "AGENTS.md is $words words; ceiling is 3200" || return 1
  }
}

_fm_ci_write_agents() {
  local agents rendered tmp
  agents=$(_fm_ci_agents_path)
  [ -f "$agents" ] || { _fm_ci_die "missing AGENTS.md" || return 1; }
  _fm_ci_extract_index "$agents" >/dev/null || {
    _fm_ci_die "AGENTS.md contract index markers missing or repeated" || return 1
  }
  rendered=$(mktemp) || return 1
  tmp=$(mktemp) || { rm -f "$rendered"; return 1; }
  if ! fm_contract_index_render >"$rendered"; then
    rm -f "$rendered" "$tmp"
    return 1
  fi
  if ! awk -v repl="$rendered" '
    BEGIN {
      begin = "<!-- fm-contract-index:begin -->"
      end = "<!-- fm-contract-index:end -->"
    }
    $0 == begin {
      print
      while ((getline line < repl) > 0) print line
      close(repl)
      skip = 1
      next
    }
    $0 == end { skip = 0; print; next }
    skip { next }
    { print }
  ' "$agents" >"$tmp"; then
    rm -f "$rendered" "$tmp"
    return 1
  fi
  mv "$tmp" "$agents" || { rm -f "$rendered" "$tmp"; return 1; }
  rm -f "$rendered"
}

_fm_ci_usage() {
  printf '%s\n' 'usage: fm-contract-index.sh [render]' >&2
  printf '%s\n' '       fm-contract-index.sh --check [tsv]' >&2
  printf '%s\n' '       fm-contract-index.sh --write' >&2
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
      if [ "$#" -eq 2 ]; then
        _fm_ci_load "$2"
      else
        _fm_ci_load && _fm_ci_check_agents
      fi
      ;;
    --write)
      [ "$#" -eq 1 ] || { _fm_ci_usage; exit 2; }
      _fm_ci_write_agents
      ;;
    *)
      _fm_ci_usage
      exit 2
      ;;
  esac
fi
