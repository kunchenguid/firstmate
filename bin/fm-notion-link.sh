#!/usr/bin/env bash
# Link a spawned task to the Notion board card it came from, so the
# notion-board skill can sync that card's Status as the task moves and can
# post the result back into the card body when it lands.
#
# Usage: fm-notion-link.sh <task-id> <page-url>
#        fm-notion-link.sh --archive <task-id>
#
# Records link lines in state/<task-id>.meta (replacing any prior link,
# preserving every other meta line):
#   notion_page=<url>          the card this task is currently bound to
#   notion_linked_ts=<epoch>   link time
#
# --archive is the RECYCLING GUARD and is mandatory before a card is returned
# to the free pool. Cards are reused rather than deleted (the Notion MCP
# surface has no delete or trash tool at all), so a card URL outlives the task
# that used it and will later hold a DIFFERENT task. Archiving rewrites
# notion_page= to notion_page_archived=, which no sync step reads, so a late
# wake on an old task can never push a status into a card that has since been
# handed to someone else. Never hand a card back to the pool while a live
# notion_page= still points at it.
#
# This is a separate step the notion-board skill runs AFTER fm-spawn.sh, so it
# never changes fm-spawn's interface - the same split fm-x-link.sh uses. This
# script is deliberately network-free: it owns only the meta format, while
# every Notion read and write goes through the MCP connector from inside the
# agent's own turn.
#
# The task id composes a path (state/<id>.meta) and is guarded against path
# traversal even though it comes from a trusted caller.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-notion-link.sh <task-id> <page-url>" >&2
  echo "       fm-notion-link.sh --archive <task-id>" >&2
}

# Atomic replace of the notion_* lines, preserving every other meta line.
notion_meta_write() {  # <meta> <mode:link|archive> [url] [ts]
  local meta=$1 mode=$2 url=${3:-} ts=${4:-} dir base tmp
  [ -f "$meta" ] || return 1
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  [ -d "$dir" ] || return 1
  tmp=$(mktemp "$dir/.${base}.fm-notion.XXXXXX") || return 1
  if [ "$mode" = archive ]; then
    # Keep the value, retire the key: history stays readable, no sync step
    # will ever act on it again.
    if ! sed -e 's/^notion_page=/notion_page_archived=/' \
             -e 's/^notion_linked_ts=/notion_archived_ts=/' "$meta" > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
  else
    if ! { grep -vE '^notion_page=|^notion_linked_ts=' "$meta" || true; } > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
    printf 'notion_page=%s\n' "$url" >> "$tmp" || { rm -f "$tmp"; return 1; }
    printf 'notion_linked_ts=%s\n' "$ts" >> "$tmp" || { rm -f "$tmp"; return 1; }
  fi
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

MODE=link
if [ "${1:-}" = "--archive" ]; then
  MODE=archive
  shift
fi

ID=${1:-}
URL=${2:-}
if [ -z "$ID" ]; then
  usage
  exit 2
fi
if [ "$MODE" = link ] && [ -z "$URL" ]; then
  usage
  exit 2
fi
if [ "$MODE" = archive ] && [ -n "$URL" ]; then
  usage
  exit 2
fi

fm_pr_task_id_valid "$ID" || { echo "fm-notion-link: unsafe task id: $ID" >&2; exit 2; }

META="$STATE/$ID.meta"
if [ ! -f "$META" ]; then
  echo "fm-notion-link: no such task: state/$ID.meta" >&2
  exit 1
fi

if [ "$MODE" = archive ]; then
  if ! grep -q '^notion_page=' "$META"; then
    # Idempotent: re-archiving an already-archived task is a no-op success, so
    # a retried cleanup pass never fails the recycle.
    printf 'no live Notion link on %s\n' "$ID"
    exit 0
  fi
  if ! notion_meta_write "$META" archive; then
    echo "fm-notion-link: failed to archive the link in state/$ID.meta" >&2
    exit 1
  fi
  printf 'archived the Notion link on %s; its card may now be recycled\n' "$ID"
  exit 0
fi

# The URL lands in a line-oriented meta file and is echoed into later prompts,
# so reject anything with whitespace, a newline, or a shell/control character
# before it is ever written.
case "$URL" in
  https://*) ;;
  *) echo "fm-notion-link: page url must start with https:// - got: $URL" >&2; exit 2 ;;
esac
case "$URL" in
  *notion.so/*|*notion.com/*) ;;
  *) echo "fm-notion-link: page url must be a notion.so or notion.com link" >&2; exit 2 ;;
esac
case "$URL" in
  *[[:space:]]*|*'$'*|*'`'*|*'"'*|*"'"*|*'\'*|*'<'*|*'>'*)
    echo "fm-notion-link: page url contains an unsafe character" >&2; exit 2 ;;
esac

# FM_NOW_OVERRIDE keeps tests deterministic; production uses the wall clock.
LINK_TS=${FM_NOW_OVERRIDE:-$(date +%s)}
case "$LINK_TS" in
  ''|*[!0-9]*) echo "fm-notion-link: could not read the current time" >&2; exit 1 ;;
esac

if ! notion_meta_write "$META" link "$URL" "$LINK_TS"; then
  echo "fm-notion-link: failed to record the link in state/$ID.meta" >&2
  exit 1
fi

printf 'linked %s to Notion card %s\n' "$ID" "$URL"
