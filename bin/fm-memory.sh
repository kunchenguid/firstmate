#!/usr/bin/env bash
# fm-memory.sh - plain-markdown memory store with a light BM25 search index.
#
# Usage:
#   fm-memory.sh remember [--category <cat>] <topic> [body...]
#   fm-memory.sh recall [--json] [--limit <n>] <query>
#   fm-memory.sh list
#   fm-memory.sh reindex
#   fm-memory.sh stats
#   fm-memory.sh dir
#
# docs/memory.md owns the operator contract, the migration from OpenViking,
# and the retirement of the old server. This header owns flags, the store-dir
# resolution, the on-disk record format, and exit codes.
#
# Store directory resolution, first match wins:
#   1. FM_MEMORY_DIR environment override
#   2. first non-comment non-blank line of gitignored config/memory-dir
#      (under FM_CONFIG_OVERRIDE when set, else $FM_HOME/config)
#   3. $FM_HOME/data/memories
#
# A memory is one markdown file. `remember` writes
# <category>/<slug>.md with a small frontmatter block (category, created,
# updated) and a `# <topic>` title; re-writing the same category+topic updates
# the file in place and preserves its original `created:` date. `body` comes
# from the remaining arguments joined by spaces, or from stdin when no body
# argument is given. Categories normalize the OpenViking names
# (preference->preferences, entity->entities, event->events); any other value
# must match ^[a-z0-9][a-z0-9-]*$ (or `.` for the store root). The topic is
# slugified to a filename (lowercase, non-alphanumeric runs collapse to `-`).
#
# `recall` runs BM25 over the store through bin/fm-memory-bm25.mjs and
# prints ranked `score  relpath  title` lines with a snippet; --json prints one
# JSON envelope for programmatic consumers. The index is the disposable cache
# <store>/.index.json owned by the engine; it self-rebuilds whenever the tree
# drifts from the recorded manifest, so recall never answers from stale bytes.
#
# `reindex` forces a rebuild, `list` prints store-relative paths, `stats`
# prints the resolved dir, document count, and index freshness, and `dir`
# prints the resolved store path.
#
# Exit codes: 0 success (including zero recall hits); 2 usage error, a node
# runtime problem, or a missing/unusable store component; 3 an invalid
# category or topic slug.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENGINE="$SCRIPT_DIR/fm-memory-bm25.mjs"

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-memory.sh remember [--category <cat>] <topic> [body...]
  fm-memory.sh recall [--json] [--limit <n>] <query>
  fm-memory.sh list
  fm-memory.sh reindex
  fm-memory.sh stats
  fm-memory.sh dir
EOF
}

die() {
  printf 'memory: %s\n' "$1" >&2
  exit "${2:-2}"
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

resolve_store_dir() {
  local raw
  raw=${FM_MEMORY_DIR:-}
  if [ -z "$raw" ]; then
    raw=$(first_config_line "$CONFIG/memory-dir") || raw=
  fi
  if [ -n "$raw" ]; then
    printf '%s' "$raw"
  else
    printf '%s' "$FM_HOME/data/memories"
  fi
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

normalize_category() {
  local raw=$1
  case "$raw" in
    preference) raw=preferences ;;
    entity) raw=entities ;;
    event) raw=events ;;
  esac
  printf '%s' "$raw"
}

require_node() {
  command -v node >/dev/null 2>&1 || die "node is required for the BM25 engine"
  [ -f "$ENGINE" ] || die "BM25 engine not found: $ENGINE"
}

cmd_dir() {
  resolve_store_dir
}

cmd_remember() {
  local category=preferences topic='' body='' arg
  while [ $# -gt 0 ]; do
    case "$1" in
      --category)
        [ $# -ge 2 ] || die "--category needs a value"
        category=$2
        shift 2
        ;;
      --category=*)
        category=${1#--category=}
        shift
        ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) topic=$1; shift; break ;;
    esac
  done
  if [ -z "$topic" ] && [ $# -gt 0 ]; then
    topic=$1
    shift
  fi
  [ -n "$topic" ] || { usage; die "remember needs a topic"; }
  for arg in "$@"; do
    case "$arg" in
      --category|--category=*|--from-file|--from-file=*)
        die "unexpected option after the body: $arg; supported form: 'remember [--category <cat>] <topic> [body...]' with --category before the topic and the body from arguments or stdin (no --from-file)"
        ;;
    esac
  done
  body=$*
  if [ $# -eq 0 ] && [ ! -t 0 ]; then
    body=$(cat)
  fi
  [ -n "$body" ] || die "remember needs a body (arguments or stdin)"

  category=$(normalize_category "$category")
  if [ "$category" != "." ]; then
    case "$category" in
      *[!a-z0-9-]*|''|-*) die "invalid category: $category" 3 ;;
    esac
  fi

  local slug
  slug=$(slugify "$topic")
  [ -n "$slug" ] || die "topic has no usable characters: $topic" 3

  local store dir file today created=''
  store=$(resolve_store_dir)
  if [ "$category" = "." ]; then
    dir=$store
  else
    dir=$store/$category
  fi
  mkdir -p "$dir" || die "cannot create $dir"
  file=$dir/$slug.md
  today=$(date +%F)
  if [ -f "$file" ]; then
    created=$(awk '
      NR == 1 { if ($0 != "---") exit; next }
      /^---[[:space:]]*$/ { exit }
      /^created:/ { sub(/^created:[[:space:]]*/, ""); print; exit }
    ' "$file")
  fi
  [ -n "$created" ] || created=$today

  local tmp
  tmp=$(mktemp "$dir/.mem.XXXXXX") || die "mktemp failed"
  {
    printf -- '---\n'
    [ "$category" = "." ] || printf 'category: %s\n' "$category"
    printf 'created: %s\n' "$created"
    printf 'updated: %s\n' "$today"
    printf -- '---\n'
    printf '# %s\n\n' "$topic"
    printf '%s\n' "$body"
  } > "$tmp" || { rm -f "$tmp"; die "write failed for $file"; }
  mv "$tmp" "$file" || { rm -f "$tmp"; die "write failed for $file"; }
  printf '%s\n' "${file#"$store"/}"

  require_node
  node "$ENGINE" build --dir "$store" >/dev/null || die "reindex failed"
}

cmd_recall() {
  local json_flag='' limit='' query=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json_flag=--json; shift ;;
      --limit)
        [ $# -ge 2 ] || die "--limit needs a value"
        limit=$2
        shift 2
        ;;
      --limit=*) limit=${1#--limit=}; shift ;;
      --) shift; break ;;
      -*) die "unknown option: $1" ;;
      *) query=$1; shift; break ;;
    esac
  done
  if [ -z "$query" ] && [ $# -gt 0 ]; then
    query=$1
    shift
  fi
  [ -n "$query" ] || { usage; die "recall needs a query"; }
  [ $# -eq 0 ] || die "pass the query as one argument"

  require_node
  local store
  store=$(resolve_store_dir)
  [ -d "$store" ] || die "memory store not found: $store"
  local args=(query --dir "$store" --query "$query")
  [ -n "$json_flag" ] && args+=(--json)
  [ -n "$limit" ] && args+=(--limit "$limit")
  node "$ENGINE" "${args[@]}"
}

cmd_list() {
  [ $# -eq 0 ] || die "list takes no arguments"
  local store
  store=$(resolve_store_dir)
  [ -d "$store" ] || die "memory store not found: $store"
  (cd "$store" && find . -type f -name '*.md' ! -path '*/.*' \
    | sed 's|^\./||' | sort) || true
}

cmd_reindex() {
  require_node
  local store
  store=$(resolve_store_dir)
  mkdir -p "$store" || die "cannot create $store"
  node "$ENGINE" build --dir "$store"
}

cmd_stats() {
  local store
  store=$(resolve_store_dir)
  printf 'dir: %s\n' "$store"
  if [ ! -d "$store" ]; then
    printf 'documents: 0\nindex: absent (store missing)\n'
    return 0
  fi
  local count
  count=$(cmd_list | grep -c . || true)
  printf 'documents: %s\n' "${count:-0}"
  if command -v node >/dev/null 2>&1 && [ -f "$store/.index.json" ]; then
    if node "$ENGINE" stale --dir "$store"; then
      printf 'index: stale\n'
    else
      printf 'index: fresh\n'
    fi
  else
    printf 'index: absent\n'
  fi
}

cmd=${1:-}
case "$cmd" in
  ''|-h|--help)
    usage
    [ -n "$cmd" ] || exit 2
    exit 0
    ;;
esac
shift

case "$cmd" in
  dir) cmd_dir "$@" ;;
  remember) cmd_remember "$@" ;;
  recall) cmd_recall "$@" ;;
  list) cmd_list "$@" ;;
  reindex) cmd_reindex "$@" ;;
  stats) cmd_stats "$@" ;;
  *) usage; die "unknown command: $cmd" ;;
esac
