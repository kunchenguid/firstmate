#!/usr/bin/env bash
# fm-wiki-ask.sh - config-gated firstmate path to the local wiki engine.
#
# Usage:
#   fm-wiki-ask.sh <query>
#
# Puts one knowledge question to the configured wiki-tool engine and prints
# that engine's JSON envelope unchanged. This script is not a second wiki
# engine and does not vendor wiki-tool.
#
# docs/configuration.md "Wiki engine ask" owns the operator contract; this
# header owns flags, the unconfigured messages, and the miss-classifier call.
#
# Unconfigured: if the engine or private catalog setting is absent, print
# `wiki-ask: no engine configured` or `wiki-ask: no private catalog configured`
# on stderr, print nothing on stdout, and exit 0. No network, no Jev, no
# vault write.
#
# On an engine status of no-match or missing-source, invoke
# bin/fm-jev-retrieval-miss.sh with the query plus the envelope. That
# helper's header owns its content guard and classification contract.
# Hits, contradictions, refusals, and errors are
# printed and not classified.
#
# Exit 0 for unconfigured, a completed ask, and a classifier skip so a
# knowledge question is never blocked. Exit 2 for usage or a configured
# engine/catalog that cannot be used (unreadable catalog, non-executable
# engine).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  printf 'Usage: fm-wiki-ask.sh <query>\n' >&2
}

die() {
  printf 'wiki-ask: %s\n' "$1" >&2
  exit 2
}

first_config_line() {
  local file=$1 line
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      *) printf '%s' "$line"; return 0 ;;
    esac
  done < "$file"
  return 1
}

resolve_engine() {
  local raw path
  raw=${FM_WIKI_ENGINE:-}
  if [ -z "$raw" ]; then
    raw=$(first_config_line "$CONFIG/wiki-engine") || raw=
  fi
  [ -n "$raw" ] || return 1
  case "$raw" in
    /*)
      path=$raw
      ;;
    *)
      path=$(command -v "$raw" 2>/dev/null) || path=$raw
      ;;
  esac
  printf '%s' "$path"
}

resolve_catalog() {
  local raw
  raw=${FM_WIKI_CATALOG:-}
  if [ -z "$raw" ]; then
    raw=$(first_config_line "$CONFIG/wiki-catalog") || raw=
  fi
  [ -n "$raw" ] || return 1
  printf '%s' "$raw"
}

query=
case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  '')
    usage
    die "query is required"
    ;;
  -*)
    die "unknown option: $1"
    ;;
  *)
    [ $# -eq 1 ] || die "pass the query as one argument"
    query=$1
    ;;
esac

engine=$(resolve_engine) || {
  printf 'wiki-ask: no engine configured\n' >&2
  exit 0
}
catalog=$(resolve_catalog) || {
  printf 'wiki-ask: no private catalog configured\n' >&2
  exit 0
}

[ -x "$engine" ] && [ ! -d "$engine" ] || die "engine is not executable: $engine"
[ -f "$catalog" ] && [ -r "$catalog" ] && [ ! -L "$catalog" ] \
  || die "private catalog is unreadable"

command -v jq >/dev/null 2>&1 || die "jq is required"

embeddings_enabled=0
openviking_enabled=0
if [ "$(jq -r '.embeddings.enabled // false' "$catalog" 2>/dev/null || true)" = true ]; then
  embeddings_enabled=1
fi
if [ "$(jq -r '.openviking.enabled // false' "$catalog" 2>/dev/null || true)" = true ]; then
  openviking_enabled=1
fi

tmp=$(mktemp) || die "mktemp failed"
err=$(mktemp) || { rm -f "$tmp"; die "mktemp failed"; }
# shellcheck disable=SC2317,SC2329 # Invoked by the EXIT trap below.
cleanup() { rm -f -- "$tmp" "$err"; }
trap cleanup EXIT

engine_code=0
"$engine" ask --config "$catalog" -- "$query" > "$tmp" 2>"$err" || engine_code=$?

if [ ! -s "$tmp" ]; then
  if [ -s "$err" ]; then
    cat "$err" >&2
  fi
  die "engine produced no envelope (exit $engine_code)"
fi
cat "$tmp"

if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
  exit 0
fi

status=$(jq -r '.status // empty' "$tmp")
case "$status" in
  no-match|missing-source)
    "$SCRIPT_DIR/fm-jev-retrieval-miss.sh" \
      --query "$query" \
      --envelope-file "$tmp" \
      --embeddings-enabled "$embeddings_enabled" \
      --openviking-enabled "$openviking_enabled" \
      >/dev/null || true
    ;;
esac
exit 0
