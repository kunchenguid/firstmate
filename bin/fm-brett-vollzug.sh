#!/usr/bin/env bash
# fm-brett-vollzug.sh - the Bemerkungstor's enforcement side: turns an open
# captain-remark marker (state/brett-bemerkungen/, schema fm-brett-bemerkung.v1,
# owned by bin/fm-brett-antworten.sh) into an actual block on downstream work,
# instead of a marker that only ever shows up in a wake line.
#
# Usage:
#   fm-brett-vollzug.sh status <antwort-id>
#                                    print the answer's option (from
#                                    data/brett-antworten/) and its remark
#                                    marker (from state/brett-bemerkungen/ or
#                                    its erledigt/ archive) side by side
#   fm-brett-vollzug.sh vollzugsfrei <kontext k=v...>
#                                    exit 0 when nothing open blocks this
#                                    context; exit 1 with the blocking remark
#                                    printed loud when an open marker's task:
#                                    or subject: field matches (see below)
#   fm-brett-vollzug.sh erledigt <antwort-id> --vermerk '<wohin/wie>'
#                                    retire the marker: delegates to
#                                    `fm-brett-antworten.sh bemerkung-erledigt`
#                                    when that subcommand exists there
#                                    (checked at runtime), otherwise retires
#                                    it standalone with an appended
#                                    "## erledigt" block
#   fm-brett-vollzug.sh anreichern <antwort-id> --task <id> --subject '<text>'
#                                    write task:/subject: header fields onto
#                                    an existing OPEN marker, so vollzugsfrei
#                                    can match it (migration bridge: markers
#                                    written before this tool existed carry
#                                    neither field)
#   fm-brett-vollzug.sh --help
#
# Ownership: this script does NOT own the fm-brett-bemerkung.v1 marker schema
# or its lifecycle (create/list/erledigt-by-id) - that contract is
# bin/fm-brett-antworten.sh's header, and this file never writes to it apart
# from the two fields below and (only as a fallback) the retiring move. What
# THIS file owns:
#   * the task:/subject: header fields on a marker (plain "name: value"
#     lines, collapsed to one line like every other field in the schema;
#     absent on a marker nothing has enriched yet - "Altbestand"),
#   * the vollzugsfrei match rule and its block/pass decision,
#   * the fm_brett_vollzug_check() library entry point other tools
#     (fm-spawn, fm-send) source this file to call.
#
# Match rule for vollzugsfrei <k=v...>: for every OPEN marker (never one
# already retired to erledigt/), a `task=<id>` context argument matches an
# exact equal marker task: field; a `subject=<text>` context argument matches
# when either string contains the other as a substring of the marker's
# subject: field. A marker carrying NEITHER field is Altbestand: it cannot be
# matched, so it never blocks, but its presence is still worth a human's
# attention - one WARN line to stderr per such marker, exit 0 regardless.
#
# Gate: state/.tor-bemerkung-scharf gates ONLY the vollzugsfrei blockade
# (transition rule: the Tor is built, but stands down silently - no output,
# no tor-log line - until the flag is set after full verification). `status`,
# `erledigt`, and `anreichern` are always active; they are housekeeping, not
# the block itself.
#
# Tor log: every vollzugsfrei decision (rot/warn/gruen) is written via
# fm_tor_log from bin/fm-tor-log-lib.sh when that library is present; until it
# lands this file falls back to a local no-op (see the TOR-LOG-LIB marker
# below), so vollzugsfrei's behavior never depends on the lib's presence.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ANTWORTEN="$FM_HOME/data/brett-antworten"
BEMERKUNG_DIR="$STATE/brett-bemerkungen"
BEMERKUNG_DONE_DIR="$BEMERKUNG_DIR/erledigt"
TOR_NAME=bemerkung
TOR_FLAG="$STATE/.tor-bemerkung-scharf"
BRETT_ANTWORTEN_BIN="$SCRIPT_DIR/fm-brett-antworten.sh"

TOR_LOG_LIB="$SCRIPT_DIR/fm-tor-log-lib.sh"
if [ -f "$TOR_LOG_LIB" ]; then
  # shellcheck source=/dev/null
  . "$TOR_LOG_LIB"
else
  # TODO-Marker: TOR-LOG-LIB - bin/fm-tor-log-lib.sh does not exist yet.
  # This local no-op stands in until it lands; it makes every fm_tor_log call
  # below inert (nothing is appended to state/tor-log/<tor>.jsonl) without
  # changing any block/pass decision.
  fm_tor_log() { :; }
fi

usage() {
  cat <<'EOF'
Usage:
  fm-brett-vollzug.sh status <antwort-id>
                                   print the answer's option and its remark
                                   marker side by side
  fm-brett-vollzug.sh vollzugsfrei <kontext k=v...>
                                   exit 0 free, exit 1 blocked by an open
                                   remark marker (task=/subject= matching)
  fm-brett-vollzug.sh erledigt <antwort-id> --vermerk '<wohin/wie>'
                                   retire the marker, recording where the
                                   remark went
  fm-brett-vollzug.sh anreichern <antwort-id> --task <id> --subject '<text>'
                                   tag an existing open marker so
                                   vollzugsfrei can match it
  fm-brett-vollzug.sh --help

The full contract is owned by the header comment of this script.
EOF
}

die_usage() {
  printf 'fm-brett-vollzug: %s\n' "$1" >&2
  usage >&2
  exit 2
}

bemerkung_marker_path() { printf '%s/%s.md\n' "$BEMERKUNG_DIR" "$1"; }
bemerkung_done_path() { printf '%s/%s.md\n' "$BEMERKUNG_DONE_DIR" "$1"; }

id_ok() {  # <id> -> exit 0 when it is the antwort-id alphabet this house uses
  case $1 in
    '' | *[!A-Za-z0-9-]*) return 1 ;;
  esac
  return 0
}

# --- read-only display of the answer card (data/brett-antworten/<id>.md) ----
# Mirrors, but does not own, the header/"## " section shape
# bin/fm-brett-antworten.sh's parse_card enforces; this is a best-effort
# display reader, never a validator, so a malformed card still shows what it
# can instead of refusing status outright.

card_field_ro() {  # <file> <field-name> -> value on stdout ("" if absent)
  awk -v f="$2" '
    /^## / { exit }
    index($0, f ": ") == 1 { sub("^" f ": ", ""); print; exit }
  ' "$1"
}

card_wort_ro() {  # <file> -> body of "## Wort des Captains" until the next heading
  awk '
    /^## / {
      if (inw) { exit }
      if ($0 ~ /^## Wort des Captains/) { inw = 1 }
      next
    }
    inw { sub(/\r$/, ""); gsub(/\t/, " "); gsub(/^[ \t]+|[ \t]+$/, ""); if ($0 != "" && buf != "") buf = buf " "; buf = buf $0 }
    END { gsub(/ +/, " ", buf); print buf }
  ' "$1"
}

# --- status -------------------------------------------------------------------

action_status() {
  local id=${1:-}
  [ -n "$id" ] || die_usage "status braucht eine antwort-id"
  id_ok "$id" || die_usage "antwort-id unlesbar: $id"

  local card="$ANTWORTEN/$id.md" mark_open mark_done marker_file='' marker_state=keiner
  mark_open=$(bemerkung_marker_path "$id")
  mark_done=$(bemerkung_done_path "$id")
  if [ -f "$mark_open" ]; then
    marker_file=$mark_open; marker_state=offen
  elif [ -f "$mark_done" ]; then
    marker_file=$mark_done; marker_state=erledigt
  fi

  if [ ! -f "$card" ] && [ -z "$marker_file" ]; then
    printf 'fm-brett-vollzug: weder Antwort noch Bemerkungsmarker fuer %s\n' "$id" >&2
    return 1
  fi

  printf 'antwort-id: %s\n' "$id"
  printf -- '--- option (data/brett-antworten) ---\n'
  if [ -f "$card" ]; then
    printf 'entscheid: %s\n' "$(card_field_ro "$card" entscheid)"
    printf 'art: %s\n' "$(card_field_ro "$card" art)"
    printf 'wort: %s\n' "$(card_wort_ro "$card")"
  else
    printf 'entscheid: (keine Antwortkarte: %s)\n' "$card"
  fi
  printf -- '--- bemerkung (state/brett-bemerkungen) ---\n'
  printf 'status: %s\n' "$marker_state"
  if [ -n "$marker_file" ]; then
    printf 'verbleib: %s\n' "$(sed -n 's/^verbleib: //p' "$marker_file" | head -1)"
    printf 'bemerkung: %s\n' "$(sed -n 's/^bemerkung: //p' "$marker_file" | head -1)"
    local task subject
    task=$(sed -n 's/^task: //p' "$marker_file" | head -1)
    subject=$(sed -n 's/^subject: //p' "$marker_file" | head -1)
    [ -z "$task" ] || printf 'task: %s\n' "$task"
    [ -z "$subject" ] || printf 'subject: %s\n' "$subject"
  else
    printf 'bemerkung: (kein Marker)\n'
  fi
  return 0
}

# --- vollzugsfrei / the library entry point ------------------------------------
# Contract: header block above. Never calls die_usage/exit - this is called
# both as a CLI action and as a sourced function, and a library function must
# only ever return.

action_vollzugsfrei() {
  [ -f "$TOR_FLAG" ] || return 0  # transition rule: gebaut, aber nicht scharf - stille Passage

  local arg key val ctx_task='' ctx_subject='' ctx_raw='' f id task subject bem hit
  for arg in "$@"; do
    ctx_raw="${ctx_raw:+$ctx_raw }$arg"
    key=${arg%%=*}
    val=${arg#*=}
    case $key in
      task) ctx_task=$val ;;
      subject) ctx_subject=$val ;;
    esac
  done
  [ -n "$ctx_raw" ] || ctx_raw='-'

  [ -d "$BEMERKUNG_DIR" ] || {
    fm_tor_log "$TOR_NAME" bemerkung-frei gruen - "$ctx_raw"
    return 0
  }

  for f in "$BEMERKUNG_DIR"/*.md; do
    [ -f "$f" ] || continue
    id=$(basename "${f%.md}")
    task=$(sed -n 's/^task: //p' "$f" | head -1)
    subject=$(sed -n 's/^subject: //p' "$f" | head -1)

    if [ -z "$task" ] && [ -z "$subject" ]; then
      printf 'fm-brett-vollzug: WARN Altbestand-Marker ohne task/subject-Feld, nicht pruefbar: %s\n' "$id" >&2
      fm_tor_log "$TOR_NAME" bemerkung-altbestand warn - "id=$id $ctx_raw"
      continue
    fi

    hit=''
    if [ -n "$task" ] && [ -n "$ctx_task" ] && [ "$task" = "$ctx_task" ]; then
      hit=1
    fi
    if [ -z "$hit" ] && [ -n "$subject" ] && [ -n "$ctx_subject" ]; then
      case $ctx_subject in *"$subject"*) hit=1 ;; esac
      if [ -z "$hit" ]; then
        case $subject in *"$ctx_subject"*) hit=1 ;; esac
      fi
    fi

    if [ -n "$hit" ]; then
      bem=$(sed -n 's/^bemerkung: //p' "$f" | head -1)
      printf 'fm-brett-vollzug: BLOCKIERT - offene Bemerkung %s haelt diesen Kontext (%s)\n' "$id" "$ctx_raw" >&2
      printf 'Bemerkung: "%s"\n' "${bem:--}" >&2
      printf 'Ausweg: fm-brett-vollzug.sh erledigt %s --vermerk "<wohin die Bemerkung floss>"\n' "$id" >&2
      fm_tor_log "$TOR_NAME" bemerkung-offen rot - "id=$id $ctx_raw"
      return 1
    fi
  done

  fm_tor_log "$TOR_NAME" bemerkung-frei gruen - "$ctx_raw"
  return 0
}

# Sourced by fm-spawn.sh/fm-send.sh (and anything else that needs to ask
# before acting): `fm_brett_vollzug_check task=<id>` or
# `fm_brett_vollzug_check subject=<text>`. Same contract as `vollzugsfrei`.
fm_brett_vollzug_check() {
  action_vollzugsfrei "$@"
}

# --- erledigt -------------------------------------------------------------------

brett_antworten_has_bemerkung_erledigt() {
  [ -x "$BRETT_ANTWORTEN_BIN" ] || return 1
  "$BRETT_ANTWORTEN_BIN" --help 2>/dev/null | grep -q 'bemerkung-erledigt'
}

action_erledigt() {
  local id=${1:-} vermerk=''
  [ -n "$id" ] || die_usage "erledigt braucht eine antwort-id"
  shift
  while [ "$#" -gt 0 ]; do
    case $1 in
      --vermerk) shift; vermerk=${1:-} ;;
      *) die_usage "unknown erledigt argument: $1" ;;
    esac
    shift
  done
  id_ok "$id" || die_usage "antwort-id unlesbar: $id"
  [ -n "$vermerk" ] || die_usage "--vermerk '<wohin die Bemerkung floss>' ist Pflicht"

  if brett_antworten_has_bemerkung_erledigt; then
    local rc
    "$BRETT_ANTWORTEN_BIN" bemerkung-erledigt "$id" --vermerk "$vermerk"
    rc=$?
    [ "$rc" -ne 0 ] || fm_tor_log "$TOR_NAME" bemerkung-erledigt gruen ja "id=$id"
    return "$rc"
  fi

  # Fallback: bemerkung-erledigt is not (or no longer) offered by
  # fm-brett-antworten.sh. Retire the marker standalone, appending a
  # "## erledigt" block instead of the flat lines the real subcommand writes
  # - a deliberately different shape, so a marker retired this way is visibly
  # not the delegate's own doing.
  local src dest tmp
  src=$(bemerkung_marker_path "$id")
  dest=$(bemerkung_done_path "$id")
  if [ ! -f "$src" ]; then
    if [ -f "$dest" ]; then
      printf 'schon erledigt: %s\n' "$id"
      return 0
    fi
    printf 'fm-brett-vollzug: keine offene Bemerkung %s\n' "$id" >&2
    return 1
  fi
  (umask 077; mkdir -p "$BEMERKUNG_DONE_DIR") || {
    printf 'fm-brett-vollzug: kann %s nicht anlegen\n' "$BEMERKUNG_DONE_DIR" >&2
    return 1
  }
  tmp=$(umask 077; mktemp "$BEMERKUNG_DIR/.marker.XXXXXX" 2>/dev/null) || {
    printf 'fm-brett-vollzug: kann den Vermerk nicht anlegen\n' >&2
    return 1
  }
  if ! {
    cat "$src"
    printf '## erledigt\n'
    printf 'erledigt: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'vermerk: %s\n' "$(printf '%s' "$vermerk" | tr '\n\r\t' '   ')"
  } > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    printf 'fm-brett-vollzug: kann den Vermerk nicht schreiben\n' >&2
    return 1
  fi
  rm -f -- "$src"
  fm_tor_log "$TOR_NAME" bemerkung-erledigt-fallback gruen ja "id=$id"
  printf 'erledigt: %s\n' "$id"
  return 0
}

# --- anreichern -----------------------------------------------------------------

action_anreichern() {
  local id='' task='' subject=''
  while [ "$#" -gt 0 ]; do
    case $1 in
      --task) shift; task=${1:-} ;;
      --subject) shift; subject=${1:-} ;;
      -*) die_usage "unknown anreichern argument: $1" ;;
      *)
        if [ -z "$id" ]; then
          id=$1
        else
          die_usage "unerwartetes Argument: $1"
        fi
        ;;
    esac
    shift
  done
  [ -n "$id" ] || die_usage "anreichern braucht eine antwort-id"
  id_ok "$id" || die_usage "antwort-id unlesbar: $id"
  { [ -n "$task" ] || [ -n "$subject" ]; } || die_usage "anreichern braucht --task und/oder --subject"

  local dest old_task old_subject tmp
  dest=$(bemerkung_marker_path "$id")
  if [ ! -f "$dest" ]; then
    printf 'fm-brett-vollzug: keine offene Bemerkung %s zum Anreichern\n' "$id" >&2
    return 1
  fi
  old_task=$(sed -n 's/^task: //p' "$dest" | head -1)
  old_subject=$(sed -n 's/^subject: //p' "$dest" | head -1)
  [ -n "$task" ] || task=$old_task
  [ -n "$subject" ] || subject=$old_subject

  tmp=$(umask 077; mktemp "$BEMERKUNG_DIR/.marker.XXXXXX" 2>/dev/null) || {
    printf 'fm-brett-vollzug: kann Marker nicht anreichern\n' >&2
    return 1
  }
  if ! {
    grep -v -e '^task: ' -e '^subject: ' "$dest"
    [ -z "$task" ] || printf 'task: %s\n' "$(printf '%s' "$task" | tr '\n\r\t' '   ')"
    [ -z "$subject" ] || printf 'subject: %s\n' "$(printf '%s' "$subject" | tr '\n\r\t' '   ')"
  } > "$tmp"; then
    rm -f -- "$tmp"
    printf 'fm-brett-vollzug: kann Marker nicht anreichern\n' >&2
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; printf 'fm-brett-vollzug: kann Marker nicht anreichern\n' >&2; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; printf 'fm-brett-vollzug: kann Marker nicht anreichern\n' >&2; return 1; }
  printf 'angereichert: %s (task=%s subject=%s)\n' "$id" "${task:--}" "${subject:--}"
  return 0
}

# --- dispatch (skipped when this file is sourced as a library) ----------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case ${1:-} in
    status) shift; action_status "$@" ;;
    vollzugsfrei) shift; action_vollzugsfrei "$@" ;;
    erledigt) shift; action_erledigt "$@" ;;
    anreichern) shift; action_anreichern "$@" ;;
    -h | --help) usage ;;
    '') die_usage "kein Kommando angegeben" ;;
    *) die_usage "unknown action: $1" ;;
  esac
fi
