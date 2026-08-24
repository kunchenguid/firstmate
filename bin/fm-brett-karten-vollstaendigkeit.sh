#!/usr/bin/env bash
# fm-brett-karten-vollstaendigkeit.sh - completeness guard for the captain
# board's card supply (standing order O-0022).
#
# Every open captain-held task of this home and of every secondmate home
# listed in data/secondmates.md must have exactly one card named <id>.md
# under this home's data/brett-karten/. The filename-is-task-id contract is
# load-bearing for the answer path, so the guard compares ids only.
#
# The check REPORTS ONLY. It never creates, moves, or deletes cards - card
# writing needs firstmate judgment with full context - and it never touches
# any home's backlog. One printed line reports every gap loudly; silence
# means the supply matched:
#   fehlt(N:id@heim,...)  a captain-held task whose hold-until date has come
#                         due (today or earlier) and whose card is missing
#   geparkt-ohne-frist(N:id@heim,...)
#                         an open captain-held task with no hold-until date
#                         and no card - a register finding for firstmate to
#                         resolve (date the hold or supply the card), not a
#                         board demand
#   waise(N:id,...)       a card whose id is not an open captain hold
#                         anywhere anymore (answered or stale)
#   karte-ohne-antwortweg(N:id,...)
#                         a card carrying no answer options in the format the
#                         board recognizes, so it offers the captain no way
#                         to answer and cannot be sent
#   FEHLER(...)           an unreadable source, never a silent skip
#
# Holds deliberately parked into the future are taken OUT of the card
# contract entirely: a row carrying "(hold-until: <date>)" with a date after
# today demands no card and its existing card is no orphan. An unparseable
# hold-until value is its own FEHLER. The clock comes from `date`; tests pin
# it through FM_BRETT_KARTEN_TODAY (YYYY-MM-DD), which fails loudly when it
# is not a date.
#
# Commands:
#   fm-brett-karten-vollstaendigkeit.sh check     compare and report (default)
#   fm-brett-karten-vollstaendigkeit.sh arm       write and register
#                                                 state/brett-karten-vollstaendigkeit.check.sh
#   fm-brett-karten-vollstaendigkeit.sh disarm    remove the check shim and its
#                                                 trust binding
#   fm-brett-karten-vollstaendigkeit.sh --selftest  verify the sources this check needs
#   fm-brett-karten-vollstaendigkeit.sh --help    print this command summary
#
# Sources, resolved fresh on every sweep:
#   - Main home: FM_HOME/data/backlog.md, labeled haupt.
#   - Secondmate homes: data/secondmates.md lines "- <name> ... (home:
#     <absolute-path>; ...)", parsed exactly like fm-brett-antworten.sh;
#     labeled with their registry name. A registry line without an absolute
#     usable home path is its own FEHLER.
#   - An open captain-held row starts "- [ ] <id> " and carries
#     "(hold-kind: captain)". Closed rows and other hold kinds need no card.
#     A "(hold-until: YYYY-MM-DD)" field on the row dates a deliberate park;
#     the selftest probes only the main home for fristlos gaps, the fleet
#     sweep owns all homes.
#   - A card is a regular top-level <id>.md file in data/brett-karten/.
#   - An answer way is at least one "## " section heading whose text matches
#     the board's OPTION pattern: one uppercase letter, optional blanks, the
#     middle dot, any title. The pattern's single owner is the board code
#     this home serves from projects/captain-brett,
#     src/brett/sammler/entscheide.py (ABSCHNITT/OPTION; a zero-option card
#     is that collector's "keine Optionen" format error); this guard reads
#     its bytes byte-wise so it fails exactly when the board finds nothing.
#
# FEHLER cases: a missing officer home, an unreadable or absent backlog,
# an unreadable secondmates.md, a malformed secondmate line, or a
# brett-karten path that exists but is no readable directory. With the card
# directory unusable the comparison itself stays quiet, because neither
# fehlt nor waise could be told apart from a broken enumeration.
#
# Paths follow the house overrides: FM_ROOT_OVERRIDE, FM_HOME, and
# FM_STATE_OVERRIDE resolve as in fm-brett-antworten.sh. The sweep reads
# local files only and finishes well inside FM_CHECK_TIMEOUT.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
KARTEN="$FM_HOME/data/brett-karten"
SECONDMATES="$FM_HOME/data/secondmates.md"
BACKLOG="$FM_HOME/data/backlog.md"
CHECK_ID=brett-karten-vollstaendigkeit
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LIST=5

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-brett-karten-vollstaendigkeit.sh check     compare open captain holds of
                                  all homes against data/brett-karten/ and
                                  report gaps loudly (default)
  fm-brett-karten-vollstaendigkeit.sh arm       write and register
                                  state/brett-karten-vollstaendigkeit.check.sh
  fm-brett-karten-vollstaendigkeit.sh disarm    remove the check shim and its
                                  trust binding
  fm-brett-karten-vollstaendigkeit.sh --selftest  verify the sources this check needs
  fm-brett-karten-vollstaendigkeit.sh --help    print this summary

The full mechanics contract is owned by the header comment of this script.
EOF
}

die_usage() {
  printf 'fm-brett-karten-vollstaendigkeit: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# --- findings ----------------------------------------------------------------
# Counters plus capped id lists keep the printed line bounded.

N_FEHLT=0 L_FEHLT=
N_GEFR=0 L_GEFR=
N_WAISE=0 L_WAISE=
N_WEG=0 L_WEG=
F_FEHLER=

today_epoch() {
  local t=${FM_BRETT_KARTEN_TODAY:-$(date +%F)}
  case $t in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *)
      printf 'fm-brett-karten-vollstaendigkeit: FM_BRETT_KARTEN_TODAY ist kein Datum (JJJJ-MM-TT): %s\n' "$t" >&2
      return 1
      ;;
  esac
  date -d "$t" +%s 2>/dev/null || {
    printf 'fm-brett-karten-vollstaendigkeit: FM_BRETT_KARTEN_TODAY ist unlesbar: %s\n' "$t" >&2
    return 1
  }
}
TODAY_EPOCH=$(today_epoch) || exit 2

list_add() {  # <L-var> <N-var> <token>
  local lv=$1 nv=$2 token=$3 cur n
  cur=${!lv:-}
  case " $cur " in
    *" $token "*) return 0 ;;
  esac
  n=$(printf '%s' "${!nv:-0}")
  case $cur in
    '') ;;
    *) [ "$(printf '%s' "$cur" | wc -w)" -ge "$MAX_LIST" ] && return 0 ;;
  esac
  printf -v "$lv" '%s%s%s' "$cur" "${cur:+ }" "$token"
  printf -v "$nv" '%s' "$((n + 1))"
}

fehler_add() {
  local text=$1
  case " $F_FEHLER " in
    *" $text "*) return 0 ;;
  esac
  printf -v F_FEHLER '%s%s%s' "$F_FEHLER" "${F_FEHLER:+ }" "$text"
}

summary_line() {
  local out=brett-karten
  [ "$N_FEHLT" -gt 0 ] && out+=" $N_FEHLT fehlt(${L_FEHLT// /,});"
  [ "$N_GEFR" -gt 0 ] && out+=" $N_GEFR geparkt-ohne-frist(${L_GEFR// /,});"
  [ "$N_WAISE" -gt 0 ] && out+=" $N_WAISE waise(${L_WAISE// /,});"
  [ "$N_WEG" -gt 0 ] && out+=" $N_WEG karte-ohne-antwortweg(${L_WEG// /,});"
  [ -n "$F_FEHLER" ] && out+=" FEHLER($F_FEHLER);"
  [ "$out" != brett-karten ] && printf '%s\n' "$out"
  return 0
}

# --- source readers -----------------------------------------------------------

captain_rows() {  # <backlog> -> "id<TAB>until" per open captain row; until is
  #               "" when undated and "?" when a hold-until value is unparseable
  awk '
    index($0, "- [ ] ") == 1 && index($0, "(hold-kind: captain)") > 0 {
      id = $0
      sub(/^- \[ \] /, "", id)
      sub(/[ \t].*$/, "", id)
      if (id == "") next
      until = ""
      i = index($0, "(hold-until: ")
      if (i > 0) {
        d = substr($0, i + 13, 10)
        if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) until = d
        else until = "?"
      }
      print id "\t" until
    }
  ' "$1"
}

card_has_antwortweg() {  # <card.md> -> exit 0 when a board-recognized option exists
  # Byte-wise under LC_ALL=C: the middle dot arrives as the two bytes
  # 0302 0267, and the board's ABSCHNITT demands blanks right after "##".
  awk '
    {
      if ($0 !~ /^##/) next
      rest = substr($0, 3)
      if (rest == "") next
      if (substr(rest, 1, 1) != " " && substr(rest, 1, 1) != "\t") next
      gsub(/^[ \t\r]+|[ \t\r]+$/, "", rest)
      if (rest == "") next
      c = substr(rest, 1, 1)
      if (c < "A" || c > "Z") next
      j = 2
      while (substr(rest, j, 1) == " " || substr(rest, j, 1) == "\t") j++
      if (substr(rest, j, 2) == "\302\267") { found = 1; exit }
    }
    END { exit !found }
  ' "$1"
}

scan_home() {  # <label> <backlog> : classify one home's open captain holds
  local label=$1 backlog=$2 line id until tep
  while IFS= read -r line; do
    id=${line%%$'\t'*}
    until=${line#*$'\t'}
    OPEN_ALL[$id]=1
    if [ "$until" = "?" ]; then
      fehler_add "hold-until-unlesbar-$id"
      continue
    fi
    if [ -n "$until" ]; then
      tep=$(date -d "$until" +%s 2>/dev/null) || {
        fehler_add "hold-until-unlesbar-$id"
        continue
      }
      [ "$tep" -gt "$TODAY_EPOCH" ] && continue
    fi
    if [ "$KARTEN_OK" = 1 ] && [ ! -f "$KARTEN/$id.md" ]; then
      if [ -n "$until" ]; then
        list_add L_FEHLT N_FEHLT "$id@$label"
      else
        list_add L_GEFR N_GEFR "$id@$label"
      fi
    fi
  done < <(captain_rows "$backlog")
}

officers_scan() {  # walk data/secondmates.md like fm-brett-antworten.sh
  local line name home backlog
  [ -f "$SECONDMATES" ] || return 0
  if [ ! -r "$SECONDMATES" ]; then
    fehler_add secondmates-unlesbar
    return 0
  fi
  while IFS= read -r line; do
    case $line in
      -*" (home: "*) ;;
      *) continue ;;
    esac
    case $line in
      *" - "*) ;;
      *) fehler_add secondmates-ungueltig; continue ;;
    esac
    name=${line%% - *}
    name=${name#- }
    case $name in
      '' | *[!A-Za-z0-9_-]*) fehler_add secondmates-ungueltig; continue ;;
    esac
    home=${line#*"(home: "}
    home=${home%%;*}
    case $home in
      /*) ;;
      *) fehler_add "secondmates-ungueltig-$name"; continue ;;
    esac
    if [ ! -d "$home" ]; then
      fehler_add "heim-fehlt-$name"
      continue
    fi
    backlog=$home/data/backlog.md
    if [ ! -r "$backlog" ]; then
      fehler_add "backlog-unlesbar-$name"
      continue
    fi
    scan_home "$name" "$backlog"
  done < "$SECONDMATES"
  return 0
}

# --- the check ----------------------------------------------------------------

declare -A OPEN_ALL=()
KARTEN_OK=1

action_check() {
  local f stem

  if [ -e "$KARTEN" ] && [ ! -d "$KARTEN" ]; then
    fehler_add karten-kein-ordner
    KARTEN_OK=0
  elif [ -d "$KARTEN" ] && [ ! -r "$KARTEN" ]; then
    fehler_add karten-unlesbar
    KARTEN_OK=0
  fi

  if [ ! -r "$BACKLOG" ]; then
    fehler_add backlog-unlesbar-haupt
  else
    scan_home haupt "$BACKLOG"
  fi
  officers_scan

  if [ "$KARTEN_OK" = 1 ] && [ -d "$KARTEN" ]; then
    for f in "$KARTEN"/*.md; do
      [ -f "$f" ] || continue
      stem=$(basename "$f")
      stem=${stem%.md}
      [ -n "${OPEN_ALL[$stem]:-}" ] || list_add L_WAISE N_WAISE "$stem"
      if ! card_has_antwortweg "$f"; then
        list_add L_WEG N_WEG "$stem"
      fi
    done
  fi

  summary_line
  return 0
}

# --- arm / disarm -------------------------------------------------------------
# Mirrors fm-brett-antworten.sh: guards run before anything is written, bytes
# arrive by rename, and a failed or interrupted arm never leaves a shim without
# its trust binding, because an unregistered shim is rejected loudly on every
# watcher cycle instead of being inert.

SHIM_WRITE_TMP=
ARM_BACKUP=

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-brett-karten-vollstaendigkeit.sh - board card completeness poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-brett-karten-vollstaendigkeit.sh") check"
}

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-brett-karten-vollst.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-brett-karten-vollst.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

arm_interrupted() {
  arm_rollback
  printf 'fm-brett-karten-vollstaendigkeit: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  case $FM_HOME in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-brett-karten-vollstaendigkeit: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-brett-karten-vollstaendigkeit: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-brett-karten-vollstaendigkeit: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-brett-karten-vollstaendigkeit: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_selftest() {
  local ok=1 home line id until tep
  if [ -r "$BACKLOG" ]; then
    echo "SELFTEST OK: Haupt-Backlog lesbar ($BACKLOG)"
  else
    echo "SELFTEST FAIL: Haupt-Backlog unlesbar ($BACKLOG)"
    ok=0
  fi
  if [ -e "$KARTEN" ] && [ ! -d "$KARTEN" ]; then
    echo "SELFTEST FAIL: $KARTEN ist kein Ordner"
    ok=0
  elif [ -d "$KARTEN" ] && [ ! -r "$KARTEN" ]; then
    echo "SELFTEST FAIL: Kartenordner $KARTEN unlesbar"
    ok=0
  else
    echo "SELFTEST OK: Kartenordner $KARTEN lesbar (oder noch nicht angelegt)"
    if [ -d "$KARTEN" ]; then
      for f in "$KARTEN"/*.md; do
        [ -f "$f" ] || continue
        if ! card_has_antwortweg "$f"; then
          echo "SELFTEST FAIL: Karte $(basename "${f%.md}") traegt keinen Antwortweg (## A · ...-Abschnitt fehlt)"
          ok=0
        fi
      done
    fi
  fi
  if [ -f "$SECONDMATES" ]; then
    if [ ! -r "$SECONDMATES" ]; then
      echo "SELFTEST FAIL: $SECONDMATES unlesbar"
      ok=0
    else
      echo "SELFTEST OK: secondmates.md lesbar"
      while IFS= read -r home; do
        [ -d "$home" ] || { echo "SELFTEST FAIL: Offiziers-Heim $home fehlt"; ok=0; }
      done < <(sed -n 's/^.*(home: \([^;)]*\);.*/\1/p' "$SECONDMATES")
    fi
  else
    echo "SELFTEST OK: keine Offiziere registriert (secondmates.md abwesend)"
  fi
  if [ -r "$BACKLOG" ] && [ -d "$KARTEN" ] && [ -r "$KARTEN" ]; then
    while IFS= read -r line; do
      id=${line%%$'\t'*}
      until=${line#*$'\t'}
      [ "$until" = "?" ] && continue
      if [ -n "$until" ]; then
        tep=$(date -d "$until" +%s 2>/dev/null) || continue
        [ "$tep" -gt "$TODAY_EPOCH" ] && continue
      fi
      if [ ! -f "$KARTEN/$id.md" ]; then
        echo "SELFTEST FAIL: Haupt-Aufgabe $id ist offen und fristlos, aber ohne Karte (geparkt-ohne-frist)"
        ok=0
      fi
    done < <(captain_rows "$BACKLOG")
  fi
  [ "$ok" = 1 ] && echo "SELFTEST OK"
  [ "$ok" = 1 ]
}

case ${1:-check} in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  --selftest) action_selftest ;;
  -h | --help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
