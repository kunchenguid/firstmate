#!/usr/bin/env bash
# fm-artifact.sh - the durable record of the artifacts the captain still
# comments on, and of which of those comments firstmate has already handled.
#
# WHY THIS EXISTS. An artifact watch is SESSION-LOCAL. It is armed by a tool
# call inside one firstmate session and dies with that session, so after a
# restart nothing is subscribed: the captain leaves a comment, no notification
# is delivered, and the review loop stops without anyone noticing. Conversation
# memory cannot fix that, because the restart is exactly what destroys it. So
# the set of live artifacts lives on disk, in data/, next to the other durable
# fleet records, and this script is its only writer.
#
# TWO DIFFERENT DURABILITY PROBLEMS, TWO MECHANISMS:
#
#   re-arm     Session start reprints every live artifact so firstmate
#              re-subscribes to each one in its new session. `digest` is the
#              listing bin/fm-session-start.sh prints; `rearm` records what
#              actually happened, so a watch that could NOT be restored is a
#              line in the next digest rather than a swallowed error.
#   backstop   A watch can also drop mid-session, silently. `due` names the
#              artifacts whose comment threads are worth re-reading now, and
#              `new` reports only the threads that have moved since firstmate
#              last handled them. Both stay silent when there is nothing to do.
#
# COST. The backstop runs on a heartbeat, so it must not cost a model tool call
# per artifact per beat. `due` is one cheap local read that prints nothing until
# an artifact's poll interval has elapsed, so an ordinary heartbeat spends a
# single shell call and stops there.
#
# NO DOUBLE HANDLING. Reading comments is a firstmate tool call; this script
# never reaches the network. Firstmate reports what it saw and what it handled,
# and the ledger below is what makes the two paths agree: a thread answered
# through the live subscription is recorded with `handled`, so the backstop's
# `new` no longer reports it. A thread MARK (the caller's own stable identity
# for "how far this thread has been read" - a comment count, or the last comment
# id) is compared, not just the thread id, so a follow-up comment on an
# already-answered thread is still reported as new.
#
# Usage:
#   fm-artifact.sh register <url> [--title <title>] [--note <note>]
#   fm-artifact.sh retire <url>
#   fm-artifact.sh list
#   fm-artifact.sh digest
#   fm-artifact.sh rearm <url> ok|failed [<reason>]
#   fm-artifact.sh due [--all]
#   fm-artifact.sh new <url>                  (thread lines on stdin)
#   fm-artifact.sh handled <url> <thread-id> [<mark>]
#
#   list      one "<url>\t<title>" per live artifact.
#   digest    the session-start listing: one indented block per artifact,
#             carrying any recorded re-arm failure. Prints NOTHING when this
#             home has no live artifacts, so a home that publishes none never
#             grows a digest section.
#   due       one "<url>\t<title>" per artifact whose backstop read is due.
#             Silent when nothing is due. --all ignores the interval and lists
#             every live artifact, for a deliberate manual sweep.
#   new       reads "<thread-id> [<mark>]" lines on stdin and prints the ones
#             whose mark differs from the handled ledger, one per line. Records
#             the poll either way, so an empty read still resets the interval.
#   handled   records one thread as handled at <mark> (default "-").
#
# Environment:
#   FM_HOME                          operational home whose data/ and state/ are used.
#   FM_ARTIFACT_BACKSTOP_INTERVAL    seconds between backstop reads of one
#                                    artifact. Default 1800. A non-numeric or
#                                    zero value falls back to the default rather
#                                    than removing the interval.
#
# Records written:
#   data/artifacts.md          the live registry, one "- <url> - <title>
#                              (registered <date>)" line per artifact, with an
#                              optional indented "note:" line. Human-readable on
#                              purpose: it is the captain's own list of open
#                              review surfaces, and it changes rarely.
#   state/artifacts/<key>/     the runtime ledger for one artifact: url, handled
#                              (one "<thread-id> <mark>" line per thread),
#                              rearm, polled. High-churn machine state, so it
#                              lives in state/ rather than in the registry the
#                              captain reads.
#
# The <key> is a sanitized tail of the URL plus a short hash of the whole URL,
# so the directory is recognizable while two artifacts that share a tail still
# get separate ledgers.
#
# A registry that exists but cannot be read is refused by every subcommand,
# never answered as an empty registry. Reporting a home that has live artifacts
# as a home that has none is the same silent loss this record exists to prevent.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SELF_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REG="$DATA/artifacts.md"
LEDGER_ROOT="$STATE/artifacts"

BACKSTOP_INTERVAL=${FM_ARTIFACT_BACKSTOP_INTERVAL:-1800}
case "$BACKSTOP_INTERVAL" in ''|*[!0-9]*|0) BACKSTOP_INTERVAL=1800 ;; esac

die() { printf 'fm-artifact: %s\n' "$*" >&2; exit 1; }

now_epoch() { date +%s; }
now_date() { date -u +%Y-%m-%d; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

sha256_of() {  # <string>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  fi
}

# One URL, one identity. Trailing slashes and surrounding whitespace are the
# difference between the captain pasting a link and firstmate echoing it back,
# never between two different artifacts.
normalize_url() {  # <url>
  local u=$1
  u=${u#"${u%%[![:space:]]*}"}
  u=${u%"${u##*[![:space:]]}"}
  while [ "${u%/}" != "$u" ]; do u=${u%/}; done
  printf '%s' "$u"
}

require_url() {  # <url>
  local u
  u=$(normalize_url "${1:-}")
  [ -n "$u" ] || die "an artifact URL is required"
  case "$u" in
    http://*|https://*) ;;
    *) die "not an artifact URL: $u" ;;
  esac
  printf '%s' "$u"
}

key_for() {  # <normalized-url>
  local url=$1 tail hash
  tail=${url##*/}
  tail=$(printf '%s' "$tail" | tr -c 'A-Za-z0-9._-' '-')
  tail=${tail:0:24}
  hash=$(sha256_of "$url")
  hash=${hash:0:8}
  [ -n "$hash" ] || die "no sha256 tool found (need shasum or sha256sum)"
  printf '%s-%s' "${tail:-artifact}" "$hash"
}

ledger_dir_for() {  # <normalized-url>
  printf '%s/%s' "$LEDGER_ROOT" "$(key_for "$1")"
}

# Scrub the field separators out of anything that becomes part of a one-line
# record, so a title with a newline cannot forge a second registry entry.
one_line() {  # <text>
  printf '%s' "$1" | tr '\n\t' '  '
}

# --- registry reads ---------------------------------------------------------

# A registry that exists but cannot be read is NOT an empty registry. Reading it
# as one would report a home with live artifacts as a home with none, which is
# exactly the silent loss this whole record exists to prevent - so every
# subcommand refuses up front rather than returning a confident empty answer.
require_readable_registry() {
  [ -e "$REG" ] || return 0
  [ -f "$REG" ] || die "the artifact registry is not a regular file: $REG"
  [ -r "$REG" ] || die "the artifact registry exists but cannot be read: $REG"
}

# Print "<url>\t<title>" for every registered artifact, in registry order.
read_registry() {
  local line rest url title
  [ -f "$REG" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '- http'*) ;;
      *) continue ;;
    esac
    rest=${line#- }
    url=${rest%% *}
    [ "$url" != "$rest" ] || url=$rest
    rest=${rest#"$url"}
    rest=${rest# - }
    title=${rest% (registered *}
    [ "$title" != "$rest" ] || title=$rest
    printf '%s\t%s\n' "$(normalize_url "$url")" "$title"
  done < "$REG"
}

registry_has() {  # <normalized-url>
  local url
  while IFS=$'\t' read -r url _; do
    [ "$url" = "$1" ] && return 0
  done < <(read_registry)
  return 1
}

require_registered() {  # <normalized-url>
  registry_has "$1" || die "not a registered artifact: $1 (register it first)"
}

# --- ledger reads and writes ------------------------------------------------

ledger_field() {  # <normalized-url> <file>
  local dir
  dir=$(ledger_dir_for "$1")
  [ -f "$dir/$2" ] || return 0
  cat "$dir/$2"
}

ledger_write() {  # <normalized-url> <file> <content>
  local dir
  dir=$(ledger_dir_for "$1")
  mkdir -p "$dir"
  printf '%s' "$1" > "$dir/url"
  printf '%s\n' "$3" > "$dir/$2"
}

# The recorded mark for one thread, or nothing when the thread is unhandled.
handled_mark() {  # <normalized-url> <thread-id>
  local dir line id mark
  dir=$(ledger_dir_for "$1")
  [ -f "$dir/handled" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    id=${line%% *}
    mark=${line#* }
    [ "$mark" != "$line" ] || mark=-
    if [ "$id" = "$2" ]; then
      printf '%s' "$mark"
      return 0
    fi
  done < "$dir/handled"
}

# --- subcommands ------------------------------------------------------------

cmd_register() {
  local url title='' note=''
  url=$(require_url "${1:-}")
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) title=${2:-}; shift 2 || die "--title needs a value" ;;
      --title=*) title=${1#--title=}; shift ;;
      --note) note=${2:-}; shift 2 || die "--note needs a value" ;;
      --note=*) note=${1#--note=}; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  title=$(one_line "$title")
  note=$(one_line "$note")

  mkdir -p "$DATA"
  if [ ! -f "$REG" ]; then
    cat > "$REG" <<'HEADER'
# Live artifacts

Published pages the captain still comments on.
Firstmate re-arms a watch on each of these at session start and re-reads their
comment threads as a heartbeat backstop, so a comment left while firstmate was
restarting is still picked up.
Retire an artifact with bin/fm-artifact.sh retire <url> once its review is over;
a retired artifact is neither watched nor polled.

HEADER
  fi

  # Rewrite in place so a re-register updates the title and note rather than
  # queueing a second record for the same URL.
  local tmp
  tmp=$(mktemp "$REG.XXXXXX")
  awk -v want="$url" '
    BEGIN { skip = 0 }
    /^- http/ {
      u = $2
      sub(/\/+$/, "", u)
      skip = (u == want) ? 1 : 0
      if (skip) next
    }
    skip && /^[[:space:]]+[a-z]+:/ { next }
    { skip = 0; print }
  ' "$REG" > "$tmp"
  {
    printf -- '- %s - %s (registered %s)\n' "$url" "$title" "$(now_date)"
    [ -z "$note" ] || printf '  note: %s\n' "$note"
  } >> "$tmp"
  mv -f "$tmp" "$REG"

  mkdir -p "$(ledger_dir_for "$url")"
  printf '%s' "$url" > "$(ledger_dir_for "$url")/url"
  printf 'registered %s\n' "$url"
  printf '  Arm its watch now, then record the result with:\n'
  printf '    %s/bin/fm-artifact.sh rearm %s ok\n' "$FM_ROOT" "$url"
}

cmd_retire() {
  local url tmp dir
  url=$(require_url "${1:-}")
  if [ -f "$REG" ]; then
    tmp=$(mktemp "$REG.XXXXXX")
    awk -v want="$url" '
      BEGIN { skip = 0 }
      /^- http/ {
        u = $2
        sub(/\/+$/, "", u)
        skip = (u == want) ? 1 : 0
        if (skip) next
      }
      skip && /^[[:space:]]+[a-z]+:/ { next }
      { skip = 0; print }
    ' "$REG" > "$tmp"
    mv -f "$tmp" "$REG"
  fi
  dir=$(ledger_dir_for "$url")
  rm -rf "$dir"
  printf 'retired %s\n' "$url"
}

cmd_list() {
  read_registry
}

cmd_digest() {
  local url title rearm state at reason any=0
  while IFS=$'\t' read -r url title; do
    any=1
    printf -- '- %s\n' "$url"
    [ -z "$title" ] || printf '    %s\n' "$title"
    rearm=$(ledger_field "$url" rearm)
    if [ -n "$rearm" ]; then
      at=${rearm%% *}
      state=${rearm#* }
      reason=${state#* }
      state=${state%% *}
      if [ "$state" = failed ]; then
        [ "$reason" != "$state" ] || reason='(no reason recorded)'
        printf '    ! the last attempt to restore this watch FAILED at %s: %s\n' "$at" "$reason"
      fi
    fi
  done < <(read_registry)
  [ "$any" -eq 1 ] || return 0
}

cmd_rearm() {
  local url outcome reason
  url=$(require_url "${1:-}")
  require_registered "$url"
  outcome=${2:-}
  case "$outcome" in
    ok|failed) ;;
    *) die "usage: fm-artifact.sh rearm <url> ok|failed [<reason>]" ;;
  esac
  shift 2
  reason=$(one_line "$*")
  if [ "$outcome" = ok ]; then
    ledger_write "$url" rearm "$(now_iso) ok"
  else
    [ -n "$reason" ] || reason='(no reason recorded)'
    ledger_write "$url" rearm "$(now_iso) failed $reason"
  fi
  printf 'rearm %s: %s\n' "$outcome" "$url"
}

cmd_due() {
  local all=0 url title polled now
  [ "${1:-}" != "--all" ] || all=1
  now=$(now_epoch)
  while IFS=$'\t' read -r url title; do
    if [ "$all" -eq 0 ]; then
      polled=$(ledger_field "$url" polled)
      case "$polled" in ''|*[!0-9]*) polled=0 ;; esac
      [ "$((now - polled))" -ge "$BACKSTOP_INTERVAL" ] || continue
    fi
    printf '%s\t%s\n' "$url" "$title"
  done < <(read_registry)
}

cmd_new() {
  local url line id mark known
  url=$(require_url "${1:-}")
  require_registered "$url"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    id=${line%%[[:space:]]*}
    mark=${line#"$id"}
    mark=${mark#"${mark%%[![:space:]]*}"}
    [ -n "$mark" ] || mark=-
    known=$(handled_mark "$url" "$id")
    [ "$known" = "$mark" ] && continue
    printf '%s\t%s\n' "$id" "$mark"
  done
  # The poll happened whether or not it found anything, so the interval resets
  # here. Recording it only on a hit would re-read a quiet artifact every beat.
  ledger_write "$url" polled "$(now_epoch)"
}

cmd_handled() {
  local url id mark dir tmp
  url=$(require_url "${1:-}")
  require_registered "$url"
  id=$(one_line "${2:-}")
  [ -n "$id" ] || die "usage: fm-artifact.sh handled <url> <thread-id> [<mark>]"
  case "$id" in *[[:space:]]*) die "a thread id may not contain whitespace: $id" ;; esac
  mark=$(one_line "${3:--}")
  mark=${mark// /_}
  [ -n "$mark" ] || mark=-

  dir=$(ledger_dir_for "$url")
  mkdir -p "$dir"
  printf '%s' "$url" > "$dir/url"
  tmp=$(mktemp "$dir/handled.XXXXXX")
  if [ -f "$dir/handled" ]; then
    awk -v want="$id" '$1 != want' "$dir/handled" > "$tmp"
  fi
  printf '%s %s\n' "$id" "$mark" >> "$tmp"
  mv -f "$tmp" "$dir/handled"
  printf 'handled %s %s\n' "$id" "$mark"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  register|retire|list|digest|rearm|due|new|handled) require_readable_registry ;;
esac

case "${1:-}" in
  register) shift; cmd_register "$@" ;;
  retire)   shift; cmd_retire "$@" ;;
  list)     shift; cmd_list ;;
  digest)   shift; cmd_digest ;;
  rearm)    shift; cmd_rearm "$@" ;;
  due)      shift; cmd_due "$@" ;;
  new)      shift; cmd_new "$@" ;;
  handled)  shift; cmd_handled "$@" ;;
  ''|-h|--help|help)
    # The whole header block, found rather than counted, so the help never
    # truncates the next time the header grows.
    awk 'NR == 1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}" ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
