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
#   retire    drops the registry record and the ledger. A URL this home never
#             registered is refused rather than reported as retired, so retiring
#             the wrong URL cannot look like success while the real artifact
#             stays live. `rearm`, `new` and `handled` refuse an unregistered
#             URL the same way; only `register` creates a record.
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
#   handled   records one thread as handled at <mark> (default "-"). Everything
#             after the thread id is the mark, so a mark written as several
#             words is kept whole rather than truncated at the first one.
#
# A mark's own interior spaces are folded to "_" on the way in, by the same one
# normalization on the recording and the comparing path, so a mark carrying one
# still matches itself later.
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
# A registry that exists but cannot be read - or a data/ directory this process
# cannot SEARCH, which hides the registry just as completely, whatever its read
# bit says - is refused by every subcommand, never answered as an empty
# registry. Reporting a home that has live artifacts as a home that has none is
# the same silent loss this record exists to prevent.
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

# The hash tool is resolved ONCE, before any subcommand composes a ledger path.
# Discovering it is missing later is not survivable: the discovery would happen
# inside a `$(...)`, where `die` kills only the subshell while the surrounding
# printf still succeeds, and a caller would receive the bare ledger ROOT as if
# it were one artifact's directory.
HASH_CMD=''
resolve_hash_cmd() {
  if printf '' | shasum -a 256 >/dev/null 2>&1; then
    HASH_CMD=shasum
  elif printf '' | sha256sum >/dev/null 2>&1; then
    HASH_CMD=sha256sum
  else
    die "no working sha256 tool found (need shasum or sha256sum)"
  fi
}

sha256_of() {  # <string>
  case "$HASH_CMD" in
    shasum) printf '%s' "$1" | shasum -a 256 | awk '{print $1}' ;;
    sha256sum) printf '%s' "$1" | sha256sum | awk '{print $1}' ;;
  esac
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
  # Interior whitespace is refused for the same reason a newline is scrubbed out
  # of a title: a URL carrying one would write a second registry line and forge
  # a record. A real artifact URL never contains it.
  case "$u" in
    *[[:space:]]*) die "an artifact URL may not contain whitespace: $u" ;;
  esac
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
  [ -n "$hash" ] || return 1
  printf '%s-%s' "${tail:-artifact}" "$hash"
}

# Never hands back the ledger ROOT. An empty key would make the root look like
# one artifact's directory, and `retire` would then delete every artifact's
# ledger instead of one.
ledger_dir_for() {  # <normalized-url>
  local key
  key=$(key_for "$1") || key=''
  case "$key" in
    ''|*/*) printf 'fm-artifact: cannot derive a ledger key for %s\n' "$1" >&2; return 1 ;;
  esac
  printf '%s/%s' "$LEDGER_ROOT" "$key"
}

# Scrub the field separators out of anything that becomes part of a one-line
# record, so a title with a newline cannot forge a second registry entry.
one_line() {  # <text>
  printf '%s' "$1" | tr '\n\t' '  '
}

# The ONE normalization for a thread mark. The mark is caller-supplied - a
# comment count or a last-comment id - so a space in it is folded rather than
# refused. Both the path that RECORDS a mark and the path that COMPARES one go
# through here: if they folded it differently, a handled thread whose mark
# carried a space would never match again and the backstop would re-surface it
# on every poll for ever, which is the double-handling this ledger prevents.
normalize_mark() {  # <mark>
  local m
  m=$(one_line "${1:-}")
  m=${m#"${m%%[![:space:]]*}"}
  m=${m%"${m##*[![:space:]]}"}
  m=${m// /_}
  printf '%s' "${m:--}"
}

# --- record rewrites --------------------------------------------------------

# Every rewrite that drops one record goes through this single boundary. It
# exists because `awk -v` runs escape processing over the value it assigns, so a
# URL or a thread id carrying a literal backslash reaches the comparison as
# different bytes than the ones on disk and silently matches nothing: the record
# is never replaced or removed, and the caller is told it was. The environment
# does no such processing, so awk reads the value verbatim.
#
# The prelude is where the value is bound, and the trailing "" is what makes it
# an unambiguous STRING. awk compares two strnums numerically, so without it a
# numeric-looking thread id is matched by value rather than by bytes and two
# distinct ids that round to the same double collide. Binding it once here keeps
# every program below on a byte comparison.
# shellcheck disable=SC2016 # awk program text: ENVIRON is awk syntax, not shell.
DROP_PRELUDE='BEGIN { want = ENVIRON["FM_ARTIFACT_WANT"] "" }'

# shellcheck disable=SC2016 # awk program text: $2 is an awk field, not shell.
REGISTRY_DROP_AWK='
  BEGIN { skip = 0 }
  /^- http/ {
    u = $2
    sub(/\/+$/, "", u)
    skip = (u == want) ? 1 : 0
    if (skip) next
  }
  skip && /^[[:space:]]+[a-z]+:/ { next }
  { skip = 0; print }
'

# shellcheck disable=SC2016 # awk program text: $1 is an awk field, not shell.
LEDGER_DROP_AWK='
  $1 != want
'

drop_matching() {  # <want> <awk-program> <file>
  FM_ARTIFACT_WANT=$1 awk "$DROP_PRELUDE $2" "$3"
}

# --- registry reads ---------------------------------------------------------

# A registry that exists but cannot be read is NOT an empty registry. Reading it
# as one would report a home with live artifacts as a home with none, which is
# exactly the silent loss this whole record exists to prevent - so every
# subcommand refuses up front rather than returning a confident empty answer.
require_readable_registry() {
  # Concluding "this home has no artifacts" means having actually resolved the
  # registry path inside data/, and resolving a path inside a directory is what
  # its search bit governs. A data/ this process cannot search hides the
  # registry as completely as an unreadable registry file does, and answering as
  # an empty home is the same silent loss either way.
  if [ -d "$DATA" ] && [ ! -x "$DATA" ]; then
    die "the data directory exists but cannot be searched, so its registry cannot be resolved: $DATA"
  fi
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
  local url title='' note='' dir
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
  drop_matching "$url" "$REGISTRY_DROP_AWK" "$REG" > "$tmp"
  {
    printf -- '- %s - %s (registered %s)\n' "$url" "$title" "$(now_date)"
    [ -z "$note" ] || printf '  note: %s\n' "$note"
  } >> "$tmp"
  mv -f "$tmp" "$REG"

  dir=$(ledger_dir_for "$url")
  mkdir -p "$dir"
  printf '%s' "$url" > "$dir/url"
  printf 'registered %s\n' "$url"
  printf '  Arm its watch now, then record the result with:\n'
  printf '    %s/bin/fm-artifact.sh rearm %s ok\n' "$FM_ROOT" "$url"
}

cmd_retire() {
  local url tmp dir
  url=$(require_url "${1:-}")
  require_registered "$url"
  if [ -f "$REG" ]; then
    tmp=$(mktemp "$REG.XXXXXX")
    drop_matching "$url" "$REGISTRY_DROP_AWK" "$REG" > "$tmp"
    mv -f "$tmp" "$REG"
  fi
  dir=$(ledger_dir_for "$url") || die "cannot retire $url: its ledger directory could not be resolved"
  case "$dir" in
    "$LEDGER_ROOT"|"$LEDGER_ROOT"/) die "refusing to remove the whole ledger root: $dir" ;;
  esac
  rm -rf "$dir"
  printf 'retired %s\n' "$url"
}

cmd_list() {
  read_registry
}

cmd_digest() {
  local url title rearm state at reason
  while IFS=$'\t' read -r url title; do
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
    mark=$(normalize_mark "${line#"$id"}")
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
  shift 2
  mark=$(normalize_mark "$*")

  dir=$(ledger_dir_for "$url")
  mkdir -p "$dir"
  printf '%s' "$url" > "$dir/url"
  tmp=$(mktemp "$dir/handled.XXXXXX")
  if [ -f "$dir/handled" ]; then
    drop_matching "$id" "$LEDGER_DROP_AWK" "$dir/handled" > "$tmp"
  fi
  printf '%s %s\n' "$id" "$mark" >> "$tmp"
  mv -f "$tmp" "$dir/handled"
  printf 'handled %s %s\n' "$id" "$mark"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  register|retire|list|digest|rearm|due|new|handled) require_readable_registry ;;
esac

# Before any ledger path is composed, never after: see resolve_hash_cmd.
case "${1:-}" in
  register|retire|digest|rearm|due|new|handled) resolve_hash_cmd ;;
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
