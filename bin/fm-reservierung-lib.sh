#!/usr/bin/env bash
# fm-reservierung-lib.sh - the ONE owner of the reservation file format for
# shared environments (Grundsatz "shared environments carry a reservation").
#
# Usage:
#   . bin/fm-reservierung-lib.sh
#   fm_reservierung_check <gate> [key=value]...   0 free / 1 blocked / 2 loud error
#   fm_reservierung_files                         the reservation files that count
#   fm_reservierung_field <file> <key>            one header value
#
# File contract (this header is the single owner):
#   $FM_HOME/state/reservierungen/<slug>.md - one reservation per file, flat
#   `key: value` lines, no header terminator (the whole file is the record):
#     holder:  WHO holds it (agent or home id, free text after the id)
#     purpose: WHAT it is held for, incl. the safety rails of that run
#     expiry:  until when it holds - UTC, YYYY-MM-DDTHH:MMZ or YYYY-MM-DDTHH:MM:SSZ
#              or a bare YYYY-MM-DD (end of that day)
#     set-by:  optional provenance line (who set it, on what grounds)
#     blocks:  OPTIONAL, repeatable, machine-readable half:
#                blocks: <gate> <key>=<value> [<key>=<value>...]
#              gates: spawn | plan-approval | merge | rollout | brief
#              keys:  account | project | task | klasse | path-prefix | holder
#              A blocks line shuts that gate for a FULL MATCH: every key=value
#              must be present in the call context with that value. `path-prefix`
#              matches on a leading substring, every other key exactly. A line
#              with no pairs shuts the gate entirely.
#   $FM_HOME/state/reservierungen/archiv/ - expired reservations moved aside by
#   hand; NEVER read here (only the flat top level counts).
#
# Holder exception: the holder of a reservation is not blocked by his own
# reservation. A context carrying `holder=<x>` passes a reservation whose holder
# field is `<x>` or begins with the token `<x>` (the field may carry a trailing
# note, e.g. "sm-lensclash (Bahn p1-fotett-app)").
#
# Expired means free: a reservation whose expiry has passed blocks nothing, and
# the file stays on disk. An UNPARSABLE or missing expiry is a loud warning on
# stderr AND counts as still holding - a reservation exists to protect someone
# else's running work, so the doubtful case fails toward the stronger lock
# (L33: unknown value is never a silent pass).
#
# Blocked output (stdout, one line per blocking reservation, exit 1):
#   reservierung:<path relative to the home><TAB><holder>: <purpose>
#
# Arming: this file is a LIBRARY and blocks nothing by itself; the gate script
# calling it owns its state/.tor-<name>-scharf arming flag and its named exit.
# Every call writes one Tor-Log line via bin/fm-tor-log-lib.sh (gate name
# `reservierung`): rot with the reservation file as the rule, gruen with `-`.
#
# A blocked check is a RETURN VALUE, not a failure: a caller under `set -e` must
# take the verdict in an `if`/`case` (`if fm_reservierung_check ...; then`), or
# its own shell dies on the very refusal it asked for.

# shellcheck source=bin/fm-tor-log-lib.sh
if [ -r "$(dirname "${BASH_SOURCE[0]}")/fm-tor-log-lib.sh" ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/fm-tor-log-lib.sh"
else
  # TODO TOR-LOG-LIB: bin/fm-tor-log-lib.sh is missing - decisions still stand,
  # but they are not recorded. Remove this fallback once the lib is in place.
  fm_tor_log() { :; }
fi

FM_RESERVIERUNG_GATES="spawn plan-approval merge rollout brief"
FM_RESERVIERUNG_KEYS="account project task klasse path-prefix holder"

fm_reservierung_home() {
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

fm_reservierung_files() { # -> every reservation file that counts, sorted
  local dir
  dir="$(fm_reservierung_home)/state/reservierungen"
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | sort
}

fm_reservierung_field() { # <file> <key> -> the first value of that key
  awk -v k="$2" 'index($0, k": ")==1 {print substr($0, length(k)+3); exit}' "$1"
}

fm_reservierung_blocks_lines() { # <file> -> its blocks entries, one per line
  awk 'index($0, "blocks: ")==1 {print substr($0, 9)}' "$1"
}

fm_reservierung_epoch() { # <expiry value> -> epoch seconds, or empty when unreadable
  local v="$1" norm
  case "$v" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) norm="${v}T23:59:59Z" ;;
    *T*:*:*Z) norm="$v" ;;
    *T*:*Z) norm="${v%Z}:00Z" ;;
    *) return 0 ;;
  esac
  date -u -d "$norm" +%s 2>/dev/null || true
}

fm_reservierung_holder_matches() { # <reservation holder field> <context holder>
  local field="$1" want="$2"
  [ -n "$want" ] || return 1
  [ "$field" = "$want" ] && return 0
  [ "${field%% *}" = "$want" ] && return 0
  return 1
}

fm_reservierung_entry_matches() { # <ctx-array-name> "<blocks entry>" -> 0 match
  local -n _fm_rctx="$1"
  local entry="$2"
  local -a toks=()
  read -r -a toks <<< "$entry"
  [ "${#toks[@]}" -gt 0 ] || return 1
  local i=1 pair k v have
  while [ "$i" -lt "${#toks[@]}" ]; do
    pair="${toks[$i]}"
    case "$pair" in
      *=*) ;;
      *) return 1 ;;
    esac
    k="${pair%%=*}"
    v="${pair#*=}"
    [ -n "${_fm_rctx[$k]+set}" ] || return 1
    have="${_fm_rctx[$k]}"
    if [ "$k" = "path-prefix" ]; then
      case "$have" in "$v"*) ;; *) return 1 ;; esac
    else
      [ "$have" = "$v" ] || return 1
    fi
    i=$((i + 1))
  done
  return 0
}

fm_reservierung_check() { # <gate> [key=value]... -> 0 free, 1 blocked, 2 loud
  local gate="${1:-}"
  if [ "$#" -lt 1 ]; then
    echo "error: fm_reservierung_check needs a gate: $FM_RESERVIERUNG_GATES" >&2
    return 2
  fi
  shift
  case " $FM_RESERVIERUNG_GATES " in
    *" $gate "*) ;;
    *) echo "error: unknown gate '$gate'; known gates: $FM_RESERVIERUNG_GATES" >&2; return 2 ;;
  esac
  local -A ctx=()
  local pair k
  for pair in "$@"; do
    case "$pair" in
      *=*) ;;
      *) echo "error: context '$pair' is not key=value (keys: $FM_RESERVIERUNG_KEYS)" >&2; return 2 ;;
    esac
    k="${pair%%=*}"
    case " $FM_RESERVIERUNG_KEYS " in
      *" $k "*) ;;
      *) echo "error: unknown context key '$k'; known keys: $FM_RESERVIERUNG_KEYS" >&2; return 2 ;;
    esac
    ctx["$k"]="${pair#*=}"
  done
  local ctx_text="gate=$gate ${*:-(no context)}"

  local home f rel holder purpose expiry epoch now entry blocked="" hit
  home="$(fm_reservierung_home)"
  now="$(date -u +%s)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    holder="$(fm_reservierung_field "$f" holder)"
    purpose="$(fm_reservierung_field "$f" purpose)"
    expiry="$(fm_reservierung_field "$f" expiry)"
    rel="${f#"$home"/}"
    if [ -z "$expiry" ]; then
      echo "warn: reservation $rel has no expiry line; it counts as HOLDING until it gets one" >&2
    else
      epoch="$(fm_reservierung_epoch "$expiry")"
      if [ -z "$epoch" ]; then
        echo "warn: reservation $rel has an unreadable expiry '$expiry'; it counts as HOLDING" >&2
      elif [ "$epoch" -lt "$now" ]; then
        continue
      fi
    fi
    if fm_reservierung_holder_matches "$holder" "${ctx[holder]-}"; then continue; fi
    hit="no"
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case " $FM_RESERVIERUNG_GATES " in
        *" ${entry%% *} "*) ;;
        *) echo "error: reservation $rel names an unknown gate in 'blocks: $entry'" >&2
           echo "       fix the reservation - a gate never guesses what is reserved" >&2
           return 2 ;;
      esac
      [ "${entry%% *}" = "$gate" ] || continue
      if fm_reservierung_entry_matches ctx "$entry"; then hit="yes"; fi
    done < <(fm_reservierung_blocks_lines "$f")
    if [ "$hit" = "yes" ]; then
      blocked+="reservierung:$rel"$'\t'"$holder: $purpose"$'\n'
    fi
  done < <(fm_reservierung_files)

  if [ -n "$blocked" ]; then
    printf '%s' "$blocked"
    while IFS=$'\t' read -r ref _; do
      [ -n "$ref" ] || continue
      fm_tor_log reservierung "${ref#reservierung:}" rot - "$ctx_text"
    done <<< "${blocked%$'\n'}"
    return 1
  fi
  fm_tor_log reservierung - gruen - "$ctx_text"
  return 0
}
