#!/usr/bin/env bash
# fm-hplan-guard.sh - report world-readable copies of the HPlan inventory data.
#
# Why this exists: four times in two days (2026-08-23/24) copies of the real
# HPlan database turned up world-readable - 229 hall bookings with real names
# and phone numbers of the instructors - created by docker cp, by scripts, and
# by hand, under names nobody had predicted. On 2026-08-24 the running
# production database itself stood at 644. The rights grip inside HPlan covers
# only databases HPlan itself creates; every other copy vector stays open. A
# guardian hung on filenames would have caught none of the general case, so
# this one hangs its signature on content:
#
#   The signature is the inventory's own shape - table `belegung` carrying a
#   filled `uebungsleiter` column - never a name. It matches in three tiers:
#
#     sqlite-struktur  structured proof: SQLite opened read-only and immutable,
#                      belegung present, uebungsleiter column present, at least
#                      MIN_ROWS rows with a populated instructor field.
#     byte-signatur    when structure cannot be read: both schema tokens
#                      `uebungsleiter` and `belegung` co-present in the raw
#                      bytes of a NUL-bearing (non-text) file above
#                      BYTE_MIN_BYTES - live WAL images, orphaned -wal files,
#                      anything sqlite cannot open.
#     dump-signatur    plain SQL text carrying both tokens above BYTE_MIN_BYTES
#                      with an INSERT targeting belegung; prose that merely
#                      mentions the words is never reported.
#
#   Threshold trade-off, stated rather than silent: a sub-threshold extract is
#   accepted as out of scope so a guardian crying wolf at template and test
#   databases does not get switched off. Full copies - the entire observed
#   incident family - always clear the threshold. MIN_ROWS is an environment
#   knob, not a code change.
#
# Where it looks:
#   Every sweep scans /tmp, this home, this repo root, and the working-copy
#   pool under $HOME/.treehouse locally, plus - over ssh, bounded by SSH_SECS -
#   the running service's Docker volume on the server, WAL companions included.
#   The server always appears in scan's coverage view: COVER with candidate
#   counts when the sweep ran, leer when the configured roots are absent, a
#   named PARTIAL when unreachable or torn - never silence. check mode stays
#   deviation-driven: clean sweeps print nothing there, so the watcher is not
#   woken every cycle by an all-clear. The remote leg applies no size floor on
#   purpose: inside the service's own data location any world-readable
#   signature carrier is news, however small, and a floor would turn small
#   extracts into exactly the silence that hides a leak.
#   Backup folders are excluded: the backup script sets those rights itself and
#   they are the normal state, not a find - a guardian reporting its own
#   non-findings gets switched off. Dependency, bytecode, build, and cache
#   trees inside the pool are pruned (stated limit, owned by the analyzer);
#   with them gone the pool here is about 23k readable files and walks in
#   seconds. If the pool ever outgrows the budget, the walk names the scope
#   incomplete and the next sweep finishes the job - a named partial state,
#   never a crash.
#
# What it reports: path, mode, size, tier, row count. NEVER content. It reads
# files to recognize them, and what it sees stays with it; stdout, stderr, and
# the state record carry no names and no phone numbers. It repairs nothing and
# changes nothing it scans - databases are opened immutable read-only, which
# takes no locks and writes no journal. The remedy travels in the message; a
# human decides. It never issues pattern kills against foreign processes.
#
# Cost contract: one sweep is bounded by BUDGET_SECS (cut to fit inside the
# watcher's FM_CHECK_TIMEOUT the same way fm-tool-update-check.sh fits its
# budget), the server attempt gets SSH_SECS of its own, and unreachability is
# "not checked today", never a crash. An unreadable file, a vanished scope, or
# a malformed database is an ordinary counted event. Every failure lands as a
# named partial state on stdout while the run still exits 0 - this check rides
# the supervision cycle, and the cycle must survive it.
#
# Silence discipline: suppression is per finding and per named partial state,
# keyed on path and mode, so a leak that stays put does not nag every cycle,
# a changed mode or a new path reports immediately, and RE_NAG_SECS brings a
# standing finding back around once a day.
#
# Usage:
#   fm-hplan-guard.sh check     watcher mode: silent or ONE line, always exit 0
#   fm-hplan-guard.sh scan      human mode: FINDING/COVER/PARTIAL detail lines
#   fm-hplan-guard.sh arm       write and register state/hplan-guard.check.sh
#   fm-hplan-guard.sh disarm    remove the check shim, trust binding, and record
#   fm-hplan-guard.sh --help    print this help
#
# Environment knobs (defaults fit this home; validated, bad values become a
# named config state in check mode and a refusal in scan/arm):
#   HPLAN_GUARD_BUDGET_SECS    whole-sweep bound, default 20 (1..120)
#   HPLAN_GUARD_SSH_SECS       bound for one server attempt, default 8 (1..30)
#   HPLAN_GUARD_MIN_ROWS       structured-tier row floor, default 100 (1..10M)
#   HPLAN_GUARD_BYTE_MIN_BYTES byte/dump size floor, default 32768 (1024..1G)
#   HPLAN_GUARD_SCAN_MAX_BYTES raw bytes read per file, default 64 MiB
#                              (1 MiB..1 GiB)
#   HPLAN_GUARD_SCOPES         colon-separated local scopes, default
#                              /tmp:$HOME/.treehouse:$FM_HOME:<this repo root>
#   HPLAN_GUARD_SERVER         on|off, default on
#   HPLAN_GUARD_SSH_CMD        word-split command prefix, default
#                              "ssh -o ConnectTimeout=10 -o BatchMode=yes"
#   HPLAN_GUARD_REMOTE_HOST    default gex
#   HPLAN_GUARD_REMOTE_ROOTS   colon list, default the hplan Docker volume
#                              /var/lib/docker/volumes/hplan_hplan-daten/_data
#   HPLAN_GUARD_REMOTE_EXCLUDE colon list, default /root/backups/hplan
#   HPLAN_GUARD_RE_NAG_SECS    re-report an unchanged finding or partial after
#                              this many seconds, default 86400; 0 = every sweep
#
# State: state/.hplan-guard holds the per-item suppression ledger - keyed
# hashes and epochs, no paths, no content. Arm/disarm follow the trusted-
# check-shim pattern of fm-tool-update-check.sh, including rollback, so a
# failed arm never leaves an unauthenticated shim behind for the watcher to
# reject every cycle.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.hplan-guard"
CHECK_ID=hplan-guard
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
ANALYZE_BIN="$SCRIPT_DIR/fm-hplan-guard-analyze.py"
RECORD_SCHEMA=fm-hplan-guard-v1
MAX_LINE=1600

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-hplan-guard.sh check     watcher mode: silent or ONE line, always exit 0
  fm-hplan-guard.sh scan      human mode: FINDING/COVER/PARTIAL detail lines
  fm-hplan-guard.sh arm       write and register state/hplan-guard.check.sh
  fm-hplan-guard.sh disarm    remove the check shim, trust binding, and record
  fm-hplan-guard.sh --help    print this help

The signature hangs on content - table belegung with a filled uebungsleiter
column - never on a filename. /tmp, home, repo root, the ~/.treehouse pool,
and the server volume are all covered every sweep. See this script's header
comment for tiers, exclusions, cost bounds, silence discipline, and knobs.
EOF
}

die_usage() {
  printf 'fm-hplan-guard: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# --- configuration ----------------------------------------------------------

CONFIG_ERROR=

int_in_range() { # <value> <min> <max>
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

require_int() { # <var-name> <default> <min> <max>
  local name=$1 def=$2 min=$3 max=$4 val
  eval "val=\${$name:-}"
  [ -n "$val" ] || val=$def
  if ! int_in_range "$val" "$min" "$max"; then
    CONFIG_ERROR="$name muss eine ganze Zahl von $min bis $max sein"
    return 1
  fi
  eval "$name=\$val"
}

resolve_config() {
  # Defaults first, so even a failed validation leaves every variable the
  # reporting path touches defined.
  require_int BUDGET_SECS "${HPLAN_GUARD_BUDGET_SECS:-20}" 1 120 || return 1
  require_int SSH_SECS "${HPLAN_GUARD_SSH_SECS:-8}" 1 30 || return 1
  require_int MIN_ROWS "${HPLAN_GUARD_MIN_ROWS:-100}" 1 10000000 || return 1
  require_int BYTE_MIN_BYTES "${HPLAN_GUARD_BYTE_MIN_BYTES:-32768}" \
    1024 1073741824 || return 1
  require_int SCAN_MAX_BYTES "${HPLAN_GUARD_SCAN_MAX_BYTES:-67108864}" \
    1048576 1073741824 || return 1
  require_int RE_NAG_SECS "${HPLAN_GUARD_RE_NAG_SECS:-86400}" 0 2592000 \
    || return 1

  SERVER_MODE=${HPLAN_GUARD_SERVER:-on}
  case "$SERVER_MODE" in
    on|off) ;;
    *)
      CONFIG_ERROR='HPLAN_GUARD_SERVER muss on oder off sein'
      return 1
      ;;
  esac
  SSH_CMD=${HPLAN_GUARD_SSH_CMD:-'ssh -o ConnectTimeout=10 -o BatchMode=yes'}
  REMOTE_HOST=${HPLAN_GUARD_REMOTE_HOST:-gex}
  REMOTE_ROOTS=${HPLAN_GUARD_REMOTE_ROOTS:-/var/lib/docker/volumes/hplan_hplan-daten/_data}
  REMOTE_EXCLUDE=${HPLAN_GUARD_REMOTE_EXCLUDE:-/root/backups/hplan}

  # Explicit scopes replace the default plan: the contract for tests and
  # one-off audits.
  SCOPES=${HPLAN_GUARD_SCOPES:-"/tmp:$HOME/.treehouse:$FM_HOME:$SCRIPT_DIR/.."}
  return 0
}

# The watcher runs every check under its own hard timeout and discards whatever
# a killed run printed, so the budget has to fit inside that bound or a torn
# sweep would repeat its silence on every poll. Same margins as
# fm-tool-update-check.sh: rounding plus kill grace.
fit_budget_to_watcher() {
  CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
  case "$CHECK_TIMEOUT" in
    ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
  esac
  local budget_max=$((CHECK_TIMEOUT - 3))
  [ "$budget_max" -ge 1 ] || budget_max=1
  if [ "$BUDGET_SECS" -gt "$budget_max" ]; then
    BUDGET_SECS=$budget_max
  fi
}

real_epoch() { date +%s; }

have_jq() { command -v jq >/dev/null 2>&1; }

human_size() {
  if [ "$1" -ge 1048576 ]; then
    printf '%s MB' "$((($1 + 524287) / 1048576))"
  elif [ "$1" -ge 1024 ]; then
    printf '%s KB' "$((($1 + 512) / 1024))"
  else
    printf '%s B' "$1"
  fi
}

# --- sweep results ----------------------------------------------------------
# Every finding is one row: path TAB mode TAB size TAB tier TAB detail.
# Companions (world-readable -wal/-shm siblings of a flagged database) become
# rows of their own with tier "begleiter", so nothing about a leak hides behind
# its database entry.

FINDING_ROWS=()
PARTIALS=()
LOCAL_JSON=

add_finding_row() { # <path> <mode> <size> <tier> <detail>
  FINDING_ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5")
}

emit_local_json_rows() {
  local line path mode size tier detail comp_path comp_mode comp_size
  while IFS=$'\t' read -r path mode size tier detail comps_json; do
    [ -n "$path" ] || continue
    add_finding_row "$path" "$mode" "$size" "$tier" "$detail"
    if [ -n "$comps_json" ] && [ "$comps_json" != "[]" ] && have_jq; then
      while IFS=$'\t' read -r comp_path comp_mode comp_size; do
        [ -n "$comp_path" ] || continue
        add_finding_row "$comp_path" "$comp_mode" "$comp_size" "begleiter" \
          "begleiter von $path"
      done < <(printf '%s' "$comps_json" \
        | jq -r '.[] | [.path, .mode, (.size|tostring)] | join("\t")')
    fi
  done < <(printf '%s\n' "$LOCAL_JSON" | jq -r '
    .findings[] | [.path, .mode, (.size|tostring), .tier, .detail,
                   ((.companions // []) | tostring)] | join("\t")' 2>/dev/null)
}

emit_cover_lines() {
  jq -r '.coverage[] |
    "COVER\t\(.scope)\t\(.status)\t\(.scanned)\t\(.unreadable)"' \
    <<< "$LOCAL_JSON" 2>/dev/null
}

# --- remote leg -------------------------------------------------------------

# Runs on the target over `bash -s`. Pure measurement: enumerate world-readable
# regular files under the roots (backup prefixes skipped), then one grep pair
# per candidate. No size floor here on purpose: these roots are the service's
# own data location, where any world-readable carrier of the signature is a
# find regardless of size - a floor would turn small extracts into silence,
# which is exactly the failure this leg exists to prevent.
#
# Output protocol, parsed below:
#   FINDING\tpath\tmode\tsize\ttier\tdetail
#   REMOTE-COVER\t<scanned>\t<unreadable>     always, when any root existed
#   REMOTE-NOSCOPES                            when every root was absent
remote_snippet() {
  cat <<'SNIP'
roots=$1
exclude=$2
scanned=0
unreadable=0
any_root=0
ROOTS=()
EXCL=()
OLDIFS=$IFS
IFS=:
set -- $roots
ROOTS=("$@")
set -- ${exclude:-}
EXCL=("$@")
IFS=$OLDIFS
for r in "${ROOTS[@]}"; do
  [ -n "$r" ] || continue
  [ -d "$r" ] || continue
  any_root=1
  while IFS= read -r -d '' f; do
    skip=0
    for e in "${EXCL[@]:-}"; do
      [ -n "$e" ] || continue
      case "$f" in
        "$e"|"$e"/*) skip=1; break ;;
      esac
    done
    [ "$skip" = 0 ] || continue
    m=$(stat -c '%a' -- "$f" 2>/dev/null)
    s=$(stat -c '%s' -- "$f" 2>/dev/null)
    if [ -z "$m" ] || [ -z "$s" ]; then
      unreadable=$((unreadable + 1))
      continue
    fi
    # The last octal digit carries the world-read bit; find already filtered,
    # this re-check keeps the snippet honest on its own.
    case ${m: -1} in
      [4567]) ;;
      *) continue ;;
    esac
    scanned=$((scanned + 1))
    if grep -qa uebungsleiter -- "$f" 2>/dev/null \
      && grep -qa belegung -- "$f" 2>/dev/null; then
      printf 'FINDING\t%s\t%s\t%s\tbyte-signatur\tmarker\n' "$f" "$m" "$s"
    fi
  done < <(find "$r" -type f -perm -0004 -print0 2>/dev/null)
done
if [ "$any_root" = 1 ]; then
  printf 'REMOTE-COVER\t%s\t%s\n' "$scanned" "$unreadable"
else
  printf 'REMOTE-NOSCOPES\n'
fi
exit 0
SNIP
}

run_remote_leg() { # <remaining-secs>: fills remote result globals, never fails
  local remaining=$1 bound out status line path mode size tier detail
  REMOTE_SCANNED=0
  REMOTE_UNREADABLE=0
  REMOTE_STATE=
  bound=$SSH_SECS
  [ "$bound" -gt "$remaining" ] && bound=$remaining
  [ "$bound" -ge 1 ] || bound=1
  status=0
  # The command prefix is a deliberate word split so operators can spell ssh
  # options into it; the host itself travels quoted.
  # shellcheck disable=SC2086
  out=$(printf '%s\n' "$(remote_snippet)" \
    | fm_run_timed "$bound" $SSH_CMD "$REMOTE_HOST" bash -s -- \
      "$REMOTE_ROOTS" "$REMOTE_EXCLUDE") || status=$?
  if [ "$status" -eq 124 ]; then
    PARTIALS+=("Server $REMOTE_HOST heute nicht geprueft: Zugriff ueberschritt die Frist")
    REMOTE_STATE=failed
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    PARTIALS+=("Server $REMOTE_HOST heute nicht geprueft: nicht erreichbar")
    REMOTE_STATE=failed
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      FINDING$'\t'*)
        line=${line#'FINDING'}
        line=${line#$'\t'}
        IFS=$'\t' read -r path mode size tier detail <<< "$line"
        add_finding_row "$path" "$mode" "$size" "$tier" "$detail"
        ;;
      REMOTE-COVER$'\t'*)
        line=${line#'REMOTE-COVER'}
        line=${line#$'\t'}
        IFS=$'\t' read -r REMOTE_SCANNED REMOTE_UNREADABLE <<< "$line"
        REMOTE_STATE=ok
        ;;
      "REMOTE-NOSCOPES")
        REMOTE_STATE=leer
        ;;
    esac
  done <<< "$out"
  [ -n "$REMOTE_STATE" ] || REMOTE_STATE=failed
  return 0
}

# The server always appears in the coverage view: COVER with candidate counts
# when the sweep ran, leer when the configured roots were absent, and a named
# PARTIAL (already in PARTIALS) when unreachable or torn.
emit_server_cover_line() {
  [ "$SERVER_MODE" = on ] || return 0
  case "$REMOTE_STATE" in
    ok)
      printf 'COVER\tserver:%s:%s\tok\t%s\t%s\n' \
        "$REMOTE_HOST" "$REMOTE_ROOTS" "$REMOTE_SCANNED" "$REMOTE_UNREADABLE"
      ;;
    leer)
      printf 'COVER\tserver:%s:%s\tleer\t0\t0\n' "$REMOTE_HOST" "$REMOTE_ROOTS"
      ;;
  esac
}

# --- local leg --------------------------------------------------------------

run_local_leg() { # <remaining-secs>: fills LOCAL_JSON/PARTIALS, never fails
  local remaining=$1 bound out status
  local -a scope_split=()
  if ! command -v python3 >/dev/null 2>&1; then
    PARTIALS+=("python3 fehlt auf diesem Host: lokale Suche heute nicht moeglich")
    return 0
  fi
  if ! have_jq; then
    PARTIALS+=("jq fehlt auf diesem Host: lokale Suche heute nicht moeglich")
    return 0
  fi
  bound=$remaining
  [ "$bound" -ge 1 ] || bound=1
  IFS=: read -r -a scope_split <<< "$SCOPES"
  status=0
  out=$(fm_run_timed "$bound" python3 "$ANALYZE_BIN" \
    --budget-secs "$bound" \
    --min-rows "$MIN_ROWS" \
    --byte-min "$BYTE_MIN_BYTES" \
    --scan-max "$SCAN_MAX_BYTES" \
    ${scope_split[@]+"${scope_split[@]}"}) || status=$?
  if [ "$status" -ne 0 ] || [ -z "$out" ]; then
    PARTIALS+=("lokale Suche an der Zeitgrenze abgeschnitten")
    return 0
  fi
  LOCAL_JSON=$out
}

# --- report assembly --------------------------------------------------------

format_finding_text() { # <row>: one captain-facing clause, metadata only
  local row=$1 path mode size tier detail text
  IFS=$'\t' read -r path mode size tier detail <<< "$row"
  text="$path (Rechte $mode, $(human_size "$size"), $tier"
  [ -n "$detail" ] && text="$text, $detail"
  printf '%s' "$text)"
}

item_key() { # <row or partial text>: stable suppression key, no content
  local hash
  hash=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}')
  if [ -z "$hash" ]; then
    hash=$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}')
  fi
  printf '%s\n' "${hash:0:16}"
}

# --- suppression ledger -----------------------------------------------------
# state/.hplan-guard:
#   fm-hplan-guard-v1
#   seen=<key>:<epoch>;…  what has already been reported, and when
# Keys are truncated hashes of path+mode+tier (findings) or of the message
# (partials): the ledger holds no paths and no content. Everything here stays
# compatible with stock bash 3.2 - indexed arrays only, no associative ones.

REC_SEEN=

record_read() {
  REC_SEEN=
  [ -f "$RECORD" ] || return 0
  local line
  while IFS= read -r line; do
    case "$line" in
      "$RECORD_SCHEMA") : ;;
      seen=*) REC_SEEN=${line#seen=} ;;
    esac
  done < "$RECORD"
  return 0
}

seen_epoch() { # <key>: prints the recorded epoch or nothing
  local key=$1 entry
  local IFS=';'
  for entry in $REC_SEEN; do
    [ -n "$entry" ] || continue
    [ "${entry%%:*}" = "$key" ] && { printf '%s\n' "${entry##*:}"; return 0; }
  done
  return 0
}

seen_is_news() { # <key>: success means this should be reported now
  local key=$1 epoch age
  epoch=$(seen_epoch "$key")
  [ -n "$epoch" ] || return 0
  age=$(( $(real_epoch) - epoch ))
  [ "$age" -lt 0 ] && age=0
  [ "$age" -ge "$RE_NAG_SECS" ]
}

record_write() { # <keys-reported-space-list>: persist the ledger atomically
  local reported=$1 now cutoff keep='' tmp
  local entry ekey eepoch key found i
  mkdir -p "$STATE" 2>/dev/null || true
  now=$(real_epoch)
  cutoff=$((now - 604800))
  local -a ks=()
  local -a es=()
  local IFS=';'
  for entry in $REC_SEEN; do
    [ -n "$entry" ] || continue
    ekey=${entry%%:*}
    eepoch=${entry##*:}
    case "$eepoch" in ''|*[!0-9]*) continue ;; esac
    [ "$eepoch" -ge "$cutoff" ] || continue
    ks+=("$ekey")
    es+=("$eepoch")
  done
  unset IFS
  for key in $reported; do
    found=0
    for i in ${ks[@]+"${!ks[@]}"}; do
      [ "${ks[$i]}" = "$key" ] && { es[i]=$now; found=1; break; }
    done
    [ "$found" = 1 ] || { ks+=("$key"); es+=("$now"); }
  done
  # One field per entry; printf adds the newline per argument, because a
  # command-substitution accumulator would strip it and glue entries together.
  local -a lines=()
  for i in ${ks[@]+"${!ks[@]}"}; do
    lines+=("$(printf '%010d %s' "${es[$i]}" "${ks[$i]}")")
  done
  local sorted e k
  sorted=$(printf '%s\n' ${lines[@]+"${lines[@]}"} | sort -r | head -n 128)
  while read -r e k; do
    [ -n "$k" ] || continue
    keep="${keep:+$keep;}${k}:${e}"
  done <<< "$sorted"
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'seen=%s\n' "$keep"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- actions ----------------------------------------------------------------

action_check() {
  if ! resolve_config; then
    # A bad configuration is a named partial state like any other: reported
    # once through the same suppression ledger, never a crash.
    PARTIALS+=("falsch konfiguriert: $CONFIG_ERROR")
    emit_suppressed_or_line
    return 0
  fi
  fit_budget_to_watcher
  record_read
  PARTIALS=()
  FINDING_ROWS=()
  LOCAL_JSON=
  local deadline left
  deadline=$(( $(real_epoch) + BUDGET_SECS ))
  if [ "$SERVER_MODE" = on ]; then
    run_remote_leg "$BUDGET_SECS"
  fi
  left=$((deadline - $(real_epoch)))
  if [ "$left" -lt 1 ]; then
    PARTIALS+=("lokale Suche an der Zeitgrenze abgeschnitten")
  else
    run_local_leg "$left"
  fi
  build_report_line
  emit_suppressed_or_line
  return 0
}

build_report_line() {
  if ! have_jq; then
    PARTIALS+=("jq fehlt auf diesem Host: lokale Suche heute nicht moeglich")
  elif [ -n "$LOCAL_JSON" ]; then
    emit_local_json_rows
  fi
}

# Decides what is news, assembles the one line, updates the ledger, prints it.
emit_suppressed_or_line() {
  local row text key reported_keys="" line="hplan-waechter:"
  local findings_part="" partials_part="" p remedy=""
  for row in ${FINDING_ROWS[@]+"${FINDING_ROWS[@]}"}; do
    key=$(item_key "$row")
    seen_is_news "$key" || continue
    reported_keys="${reported_keys:+$reported_keys }$key"
    text=$(format_finding_text "$row")
    findings_part="${findings_part:+$findings_part; }$text"
  done
  for p in ${PARTIALS[@]+"${PARTIALS[@]}"}; do
    key=$(item_key "partial|$p")
    seen_is_news "$key" || continue
    reported_keys="${reported_keys:+$reported_keys }$key"
    partials_part="${partials_part:+$partials_part; }$p"
  done
  if [ -n "$findings_part" ] && [ -z "$partials_part" ]; then
    remedy=" - Rechte auf 600 ziehen oder Datei entfernen; den Fund nicht veraendern."
    line="$line weltlesbare Bestandskopie: $findings_part$remedy"
  elif [ -n "$findings_part" ]; then
    line="$line weltlesbare Bestandskopie: $findings_part · $partials_part"
  elif [ -n "$partials_part" ]; then
    line="$line Pruefung unvollstaendig: $partials_part"
  else
    line=
  fi
  REPORT_LINE=
  if [ -n "$line" ]; then
    fm_cap_line_var "$line" "$MAX_LINE"
    REPORT_LINE=$FM_LINE_CAP_LINE
  fi
  record_write "$reported_keys" || true
  if [ -n "$REPORT_LINE" ]; then
    printf '%s\n' "$REPORT_LINE"
  fi
  return 0
}

action_scan() {
  resolve_config || {
    printf 'fm-hplan-guard: %s\n' "$CONFIG_ERROR" >&2
    exit 2
  }
  fit_budget_to_watcher
  PARTIALS=()
  FINDING_ROWS=()
  LOCAL_JSON=
  local deadline left p row
  deadline=$(( $(real_epoch) + BUDGET_SECS ))
  if [ "$SERVER_MODE" = on ]; then
    run_remote_leg "$BUDGET_SECS"
  fi
  left=$((deadline - $(real_epoch)))
  if [ "$left" -lt 1 ]; then
    PARTIALS+=("lokale Suche an der Zeitgrenze abgeschnitten")
  else
    run_local_leg "$left"
  fi
  if [ -n "$LOCAL_JSON" ]; then
    emit_local_json_rows
    emit_cover_lines
  fi
  emit_server_cover_line
  for p in ${PARTIALS[@]+"${PARTIALS[@]}"}; do
    printf 'PARTIAL\t%s\n' "$p"
  done
  for row in ${FINDING_ROWS[@]+"${FINDING_ROWS[@]}"}; do
    printf 'FINDING\t%s\n' "$row"
  done
  return 0
}

# --- arm/disarm (trusted check shim pattern of fm-tool-update-check.sh) ------

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-hplan-guard.sh - inventory-copy leak poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-hplan-guard.sh") check"
}

SHIM_WRITE_TMP=

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
  tmp=$(umask 077; mktemp "$STATE/.fm-hplan-guard-check.XXXXXX" 2>/dev/null) || return 1
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
  tmp=$(umask 077; mktemp "$STATE/.fm-hplan-guard-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

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
  printf 'fm-hplan-guard: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ -d "$STATE" ]; then
    :
  else
    mkdir -p "$STATE" || {
      printf 'fm-hplan-guard: cannot create %s\n' "$STATE" >&2
      return 1
    }
  fi
  resolve_config || {
    printf 'fm-hplan-guard: %s\n' "$CONFIG_ERROR" >&2
    return 1
  }
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-hplan-guard: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-hplan-guard: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-hplan-guard: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-hplan-guard: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  scan) action_scan ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
