#!/usr/bin/env bash
# fm-handoff-doc.sh — publish and discover session HANDOFF DOCUMENTS, optionally
# with a git bundle carrying the work they describe.
#
# This is a THIRD, distinct object from the two existing handoff verbs:
#   fm-fleet.sh handoff <id> <op>   reassigns a queued TASK to another operator
#   fm-backlog-handoff.sh           moves BACKLOG ITEMS into a secondmate's backlog
#   fm-handoff-doc.sh               hands off the narrative + refs of a finished session
#
# Solo by default: with no fleet, no group, and no root this stores under
# $FM_HOME/state/handoffs and every verb works. Sharing across operators on one
# host is additive and opt-in (config/admiral) — it never becomes a prerequisite
# for using handoff documents at all.
#
# Usage:
#   fm-handoff-doc.sh check                      (exit 0 iff a document is waiting; one line)
#   fm-handoff-doc.sh list                       (all documents, newest first)
#   fm-handoff-doc.sh show <id>                  (print it; marks it seen for this operator)
#   fm-handoff-doc.sh publish <file> [options]
#   fm-handoff-doc.sh fetch <id> [--into <repo>] (bundle refs -> refs/remotes/handoff/*)
#   fm-handoff-doc.sh where                      (resolved dir and how it was chosen)
#
# publish options:
#   --title <text>        human title (default: the document's first heading)
#   --bundle <ref>        git ref to bundle alongside the document (repeatable)
#   --repo <path>         repo the refs come from (default: $PWD)
#   --share-anyway        publish a 0600 source into a group-readable store
#
# Store resolves from: FM_HANDOFF_DIR -> <fleet-dir>/handoffs (only when this home
# opted into the cross-operator tier) -> $FM_HOME/state/handoffs
set -euo pipefail

# Portable file mode: BSD stat (macOS) has no -c. macOS is a declared supported
# platform (README badge), and the repo already branches this way in
# bin/backends/herdr.sh.
fm_portable_mode() { # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# The cross-operator opt-in, following the config/berths idiom exactly: a gitignored
# flag file whose ABSENCE leaves the home behaving exactly as a solo home always has.
fm_handoff_admiral_enabled() {
  [ -f "$FM_HOME/config/admiral" ]
}

# The fleet library is loaded ONLY on the opted-in path. Solo mode is the default,
# so it must not depend on the fleet lib chain (fm-fleet-lib.sh pulls in
# fm-fleet-quota-lib.sh) merely to decide it is solo. Returns non-zero when the
# fleet surface is unavailable, which the caller treats as "stay solo".
fm_handoff_load_fleet() {
  [ -r "$SCRIPT_DIR/fm-fleet-lib.sh" ] || return 1
  # shellcheck source=bin/fm-fleet-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-fleet-lib.sh" 2>/dev/null || return 1
  command -v fm_fleet_dir >/dev/null 2>&1
}

# True only when this home opted in AND the resolved fleet is one it may read.
fm_handoff_shared_ready() {
  fm_handoff_admiral_enabled || return 1
  fm_handoff_load_fleet || return 1
  fm_fleet_assert_usable "$(fm_fleet_dir)" 2>/dev/null
}

# Where handoff documents live, and why. Shared storage is used ONLY when this home
# explicitly opted into the cross-operator tier: a single-operator home must never
# be silently attached to a directory other operators can read.
fm_handoff_dir() {
  if [ -n "${FM_HANDOFF_DIR:-}" ]; then printf '%s\n' "$FM_HANDOFF_DIR"; return 0; fi
  if fm_handoff_shared_ready; then
    printf '%s/handoffs\n' "$(fm_fleet_dir)"; return 0
  fi
  printf '%s/state/handoffs\n' "$FM_HOME"
}

fm_handoff_dir_source() {
  if [ -n "${FM_HANDOFF_DIR:-}" ]; then
    printf 'env (FM_HANDOFF_DIR)\n'
  elif fm_handoff_shared_ready; then
    printf 'shared fleet store (config/admiral present)\n'
  else
    printf 'solo store (this home only)\n'
  fi
}

fm_handoff_me() { id -un 2>/dev/null || printf 'unknown\n'; }

# "Seen" is per-reader state, so it lives in the READER's own home — never inside the
# publisher's entry. Writing it into the shared store would need group-write on
# another operator's directory (it does not have it, so `check` could never go
# quiet), and would let any reader mutate the publisher's artifact. Keeping it
# local also means the shared store can stay strictly read-only for consumers.
fm_handoff_seen_marker() { # <id>
  printf '%s/state/handoff-seen/%s\n' "$FM_HOME" "$1"
}

fm_handoff_seen() { # <id>
  [ -e "$(fm_handoff_seen_marker "$1")" ]
}

fm_handoff_mark_seen() { # <id>
  local marker; marker=$(fm_handoff_seen_marker "$1")
  mkdir -p "$(dirname "$marker")" 2>/dev/null || return 0
  : > "$marker" 2>/dev/null || return 0
}

# A slug that is safe as a directory name on any filesystem and stable to sort.
fm_handoff_slug() { # <text>
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-*//' -e 's/-*$//' \
    | cut -c1-60
}

fm_handoff_meta_get() { # <entry-dir> <key>
  [ -f "$1/meta" ] || return 1
  sed -n "s/^$2=//p" "$1/meta" | head -1
}

# Entries the caller has neither authored nor already read. This is what makes
# `check` quiet enough to run from a session-start hook.
fm_handoff_waiting() { # <dir>
  local dir=$1 entry me
  me=$(fm_handoff_me)
  [ -d "$dir" ] || return 0
  for entry in "$dir"/*/; do
    [ -d "$entry" ] || continue
    [ -f "$entry/meta" ] || continue
    [ "$(fm_handoff_meta_get "${entry%/}" author)" != "$me" ] || continue
    fm_handoff_seen "$(basename "${entry%/}")" && continue
    printf '%s\n' "${entry%/}"
  done
}

# An id names one directory INSIDE the store and nothing else. Without this a
# caller-supplied "../x" or an absolute path would resolve outside the store
# entirely, so every lookup validates before it touches the filesystem.
fm_handoff_valid_id() { # <id>
  case "$1" in
    ''|*/*|.|..|*..*) return 1 ;;
  esac
  case "$1" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# A document name is a bare filename within its own entry. The store is
# group-writable on a multi-operator host, so `meta` is UNTRUSTED INPUT: a planted
# entry carrying doc=../../../etc/something would otherwise make a reader open an
# arbitrary path with the reader's own credentials.
fm_handoff_valid_doc() { # <entry-dir> <name>
  case "$2" in
    ''|*/*|.|..|*..*) return 1 ;;
  esac
  # A bare name is still not enough: a symlink planted inside the entry would
  # point anywhere. Only a real file that is genuinely inside the entry is read.
  [ ! -L "$1/$2" ] && [ -f "$1/$2" ]
}

fm_handoff_require_entry() { # <dir> <id>
  local entry
  if ! fm_handoff_valid_id "$2"; then
    printf 'fm-handoff-doc: invalid handoff id "%s"\n' "$2" >&2
    printf '  ids are a single name: letters, digits, dot, dash, underscore\n' >&2
    return 1
  fi
  entry="$1/$2"
  if [ ! -d "$entry" ] || [ ! -f "$entry/meta" ]; then
    printf 'fm-handoff-doc: no handoff document "%s" in %s\n' "$2" "$1" >&2
    printf '  bin/fm-handoff-doc.sh list\n' >&2
    return 1
  fi
  printf '%s\n' "$entry"
}

cmd=${1:-}; shift || true
DIR=$(fm_handoff_dir)

case "$cmd" in
  where)
    printf '%s\n' "$DIR"
    printf '  chosen by: %s\n' "$(fm_handoff_dir_source)"
    if [ -d "$DIR" ]; then
      printf '  state: present, mode %s\n' "$(fm_portable_mode "$DIR" 2>/dev/null || printf '?')"
    else
      printf '  state: not created yet (publish creates it)\n'
    fi
    ;;

  check)
    # Deliberately quiet and cheap: prints at most two lines and exits non-zero when
    # there is nothing waiting, so a session hook can call it unconditionally.
    waiting=()
    while IFS= read -r line; do [ -n "$line" ] && waiting+=("$line"); done < <(fm_handoff_waiting "$DIR")
    if [ "${#waiting[@]}" -eq 0 ]; then
      printf 'handoff: nothing waiting\n'
      exit 1
    fi
    newest=${waiting[${#waiting[@]}-1]}
    printf 'handoff: %d document(s) waiting (latest %s, from %s)\n' \
      "${#waiting[@]}" "$(basename "$newest")" \
      "$(fm_handoff_meta_get "$newest" author)"
    printf '  bin/fm-handoff-doc.sh show %s\n' "$(basename "$newest")"
    ;;

  list)
    if [ ! -d "$DIR" ]; then printf 'no handoff documents in %s\n' "$DIR"; exit 0; fi
    printf '%-34s %-10s %-6s %s\n' ID AUTHOR STATE TITLE
    found=0
    for entry in "$DIR"/*/; do
      [ -d "$entry" ] && [ -f "$entry/meta" ] || continue
      found=1
      state=new
      ! fm_handoff_seen "$(basename "${entry%/}")" || state=seen
      printf '%-34s %-10s %-6s %s\n' \
        "$(basename "${entry%/}")" \
        "$(fm_handoff_meta_get "${entry%/}" author)" \
        "$state" \
        "$(fm_handoff_meta_get "${entry%/}" title)"
    done
    [ "$found" = 1 ] || printf 'no handoff documents in %s\n' "$DIR"
    ;;

  show)
    id=${1:?usage: fm-handoff-doc.sh show <id>}
    entry=$(fm_handoff_require_entry "$DIR" "$id") || exit 1
    doc=$(fm_handoff_meta_get "$entry" doc)
    if ! fm_handoff_valid_doc "$entry" "$doc"; then
      printf 'fm-handoff-doc: %s does not name a plain document inside its own entry; refusing to read it\n' "$id" >&2
      exit 1
    fi
    cat "$entry/$doc"
    # Best-effort and reader-local: a read-only shared store must still print.
    fm_handoff_mark_seen "$id"
    ;;

  publish)
    src=${1:?usage: fm-handoff-doc.sh publish <file> [--title T] [--bundle REF]... [--repo PATH]}
    shift
    title=""; repo=$PWD; share_anyway=0; refs=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)  title=${2:?--title needs a value}; shift 2 ;;
        --bundle) refs+=("${2:?--bundle needs a ref}"); shift 2 ;;
        --repo)   repo=${2:?--repo needs a path}; shift 2 ;;
        --share-anyway) share_anyway=1; shift ;;
        *) printf 'fm-handoff-doc: unknown option %s\n' "$1" >&2; exit 1 ;;
      esac
    done
    [ -f "$src" ] || { printf 'fm-handoff-doc: no such file: %s\n' "$src" >&2; exit 1; }

    # An entry owns two names. Copying a source over either one destroys the entry:
    # a document called "meta" is overwritten by the metadata written moments later,
    # and the document is silently lost.
    case "$(basename "$src")" in
      meta|handoff.bundle)
        printf 'fm-handoff-doc: "%s" is a reserved name inside a handoff entry\n' "$(basename "$src")" >&2
        printf '  rename the file, or pass a copy under a different name\n' >&2
        exit 1 ;;
    esac

    # The shared store is group-readable by design. Publishing a file the operator
    # kept private is therefore a disclosure, not a copy — make them say so.
    case "$(basename "$src")" in
      .env|.env.*)
        printf 'fm-handoff-doc: refusing to publish %s (secrets)\n' "$src" >&2; exit 1 ;;
    esac
    src_mode=$(fm_portable_mode "$src" 2>/dev/null || printf '644')
    if [ "$src_mode" = 600 ] && [ "$share_anyway" != 1 ] \
       && [ "$(fm_handoff_dir_source)" != "solo store (this home only)" ]; then
      printf 'fm-handoff-doc: %s is mode 0600 and the store is shared with other operators.\n' "$src" >&2
      printf '  Publishing makes it group-readable. Re-run with --share-anyway if that is intended.\n' >&2
      exit 1
    fi

    [ -n "$title" ] || title=$(sed -n 's/^##*[[:space:]]*//p' "$src" | head -1)
    [ -n "$title" ] || title=$(basename "$src")
    base_id="$(date -u +%Y-%m-%d)-$(fm_handoff_slug "$title")"
    id="$base_id"
    n=1
    mkdir -p "$DIR"
    while ! mkdir "$DIR/$id" 2>/dev/null; do
      [ -e "$DIR/$id" ] || { printf 'fm-handoff-doc: could not create entry %s/%s\n' "$DIR" "$id" >&2; exit 1; }
      n=$((n + 1))
      id="$base_id-$n"
    done
    entry="$DIR/$id"
    install -m 0644 "$src" "$entry/$(basename "$src")"

    bundle_note=none
    bundle_meta=
    if [ "${#refs[@]}" -gt 0 ]; then
      # A bundle with complete history applies to any clone regardless of what that
      # clone already has, which is what makes a handoff readable by an operator who
      # cannot see the author's repo at all.
      if ! git -C "$repo" bundle create "$entry/handoff.bundle" "${refs[@]}" >/dev/null 2>&1; then
        printf 'fm-handoff-doc: could not bundle %s from %s\n' "${refs[*]}" "$repo" >&2
        exit 1
      fi
      chmod 0644 "$entry/handoff.bundle"
      bundle_note="handoff.bundle (${#refs[@]} ref(s))"
      bundle_meta=handoff.bundle
    fi

    {
      printf 'id=%s\n' "$id"
      printf 'title=%s\n' "$title"
      printf 'author=%s\n' "$(fm_handoff_me)"
      printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'doc=%s\n' "$(basename "$src")"
      printf 'bundle=%s\n' "$bundle_meta"
    } > "$entry/meta"
    chmod 0644 "$entry/meta"

    printf 'handoff: published %s to %s\n' "$id" "$DIR"
    printf '  document  %s\n' "$(basename "$src")"
    printf '  bundle    %s\n' "$bundle_note"
    printf '  store     %s\n' "$(fm_handoff_dir_source)"
    ;;

  fetch)
    id=${1:?usage: fm-handoff-doc.sh fetch <id> [--into <repo>]}; shift || true
    into=$PWD
    while [ $# -gt 0 ]; do
      case "$1" in
        --into) into=${2:?--into needs a path}; shift 2 ;;
        *) printf 'fm-handoff-doc: unknown option %s\n' "$1" >&2; exit 1 ;;
      esac
    done
    entry=$(fm_handoff_require_entry "$DIR" "$id") || exit 1
    bundle="$entry/handoff.bundle"
    [ -f "$bundle" ] || { printf 'fm-handoff-doc: %s carries no bundle\n' "$id" >&2; exit 1; }
    if ! git -C "$into" bundle verify "$bundle" >/dev/null 2>&1; then
      printf 'fm-handoff-doc: bundle failed verification; refusing to fetch\n' >&2
      exit 1
    fi
    # Remote-tracking refs only. Never checkout, never merge, never move a branch:
    # the receiving operator decides what to do with the work.
    git -C "$into" fetch "$bundle" 'refs/heads/*:refs/remotes/handoff/*' 2>&1 | sed 's/^/  /'
    printf 'handoff: refs are under refs/remotes/handoff/* in %s\n' "$into"
    ;;

  ''|-h|--help|help)
    sed -n '2,30p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    ;;

  *)
    printf 'usage: fm-handoff-doc.sh check|list|show|publish|fetch|where\n' >&2
    exit 1
    ;;
esac
