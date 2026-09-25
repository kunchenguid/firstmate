#!/usr/bin/env bash
# Capture and retrieve home-local memories and timed reminders.
#
# Usage:
#   fm-memory.sh remember <text>
#   fm-memory.sh remind --at <epoch|UTC-ISO> <text>
#   fm-memory.sh remind --in <N{s|m|h|d|w}> <text>
#   fm-memory.sh list [--all] [--kind memory|reminder]
#   fm-memory.sh search [--all] <query>
#   fm-memory.sh done <reminder-id>
#   fm-memory.sh arm | disarm | check
#
# Records live under data/memory/records in the selected FM_HOME. Each record is
# an ordinary private file in the fm-memory-v1 line format owned by this script.
# Memory text is one non-empty printable line, at most 500 bytes. `check` is the
# watcher-facing operation: it marks a bounded batch of due reminders notified,
# then prints one line when firstmate should wake. A malformed record is named
# on that same line and does not suppress due reminders. Repeated checks stay
# silent until another reminder becomes due. Marking a reminder done
# acknowledges it. The standing check is retired when no open reminder remains,
# and a retirement failure is reported so a later `done` retries it. The check
# is armed automatically when a reminder is created. It never uses a sleeping
# agent or a separate scheduler.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STORE="$DATA/memory"
RECORDS="$STORE/records"
LOCK="$STORE/.lock"
CHECK_ID=memory-reminders
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"
SCHEMA=fm-memory-v1
MAX_TEXT_BYTES=500
MAX_DUE_PER_CHECK=5
MAX_WAKE_TEXT_BYTES=140

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-memory.sh remember <text>
  fm-memory.sh remind --at <epoch|YYYY-MM-DDTHH:MM:SSZ> <text>
  fm-memory.sh remind --in <N{s|m|h|d|w}> <text>
  fm-memory.sh list [--all] [--kind memory|reminder]
  fm-memory.sh search [--all] <query>
  fm-memory.sh done <reminder-id>
  fm-memory.sh arm
  fm-memory.sh disarm
  fm-memory.sh check

`list` shows memories and open reminders by default. `--all` also shows completed
reminders. `search` is a case-insensitive literal search over the same records.
Reminder creation arms an authenticated watcher check automatically. `disarm`
refuses while an open reminder exists. `check` is for the watcher: it prints one
line when a reminder is due or a stored record is malformed, and nothing otherwise.
EOF
}

die_usage() {
  printf 'fm-memory: %s\n' "$1" >&2
  usage >&2
  exit 2
}

die() {
  printf 'fm-memory: %s\n' "$1" >&2
  exit 1
}

now_epoch() {
  case "${FM_MEMORY_NOW:-}" in
    '') date +%s ;;
    *[!0-9]*) return 1 ;;
    *) printf '%s\n' "$FM_MEMORY_NOW" ;;
  esac
}

iso_for_epoch() {
  local epoch=$1
  date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

parse_iso_epoch() {
  local value=$1 epoch roundtrip
  case "$value" in
    ????-??-??T??:??:??Z) ;;
    *) return 1 ;;
  esac
  epoch=$(date -u -d "$value" +%s 2>/dev/null \
    || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null) || return 1
  roundtrip=$(iso_for_epoch "$epoch") || return 1
  [ "$roundtrip" = "$value" ] || return 1
  printf '%s\n' "$epoch"
}

parse_due() {
  local mode=$1 value=$2 now amount unit multiplier due
  now=$(now_epoch) || return 1
  case "$mode" in
    --at)
      case "$value" in
        ''|*[!0-9]*) due=$(parse_iso_epoch "$value") || return 1 ;;
        *) due=$value ;;
      esac
      ;;
    --in)
      case "$value" in
        [1-9]*[smhdw]) ;;
        *) return 1 ;;
      esac
      amount=${value%?}
      case "$amount" in ''|*[!0-9]*) return 1 ;; esac
      unit=${value#"$amount"}
      case "$unit" in
        s) multiplier=1 ;;
        m) multiplier=60 ;;
        h) multiplier=3600 ;;
        d) multiplier=86400 ;;
        w) multiplier=604800 ;;
        *) return 1 ;;
      esac
      [ "$amount" -le 315360000 ] 2>/dev/null || return 1
      due=$((now + amount * multiplier))
      [ "$due" -ge "$now" ] || return 1
      ;;
    *) return 1 ;;
  esac
  case "$due" in ''|*[!0-9]*) return 1 ;; esac
  [ "$due" -le 9999999999 ] 2>/dev/null || return 1
  printf '%s\n' "$due"
}

validate_text() {
  local text=$1 bytes
  [ -n "$text" ] || return 1
  case "$text" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  # Refuse every remaining C0 control byte and DEL. The record format is
  # deliberately line-oriented, so accepting one would make display ambiguous.
  if printf '%s' "$text" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
    return 1
  fi
  bytes=$(printf '%s' "$text" | wc -c | tr -d '[:space:]')
  [ "$bytes" -le "$MAX_TEXT_BYTES" ]
}

ensure_store() {
  mkdir -p "$DATA" || return 1
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 1
  if [ -e "$STORE" ] || [ -L "$STORE" ]; then
    [ -d "$STORE" ] && [ ! -L "$STORE" ] || return 1
  else
    (umask 077; mkdir "$STORE") || return 1
  fi
  chmod 0700 "$STORE" || return 1
  if [ -e "$RECORDS" ] || [ -L "$RECORDS" ]; then
    [ -d "$RECORDS" ] && [ ! -L "$RECORDS" ] || return 1
  else
    (umask 077; mkdir "$RECORDS") || return 1
  fi
  chmod 0700 "$RECORDS" || return 1
}

LOCK_HELD=0
lock_release() {
  [ "$LOCK_HELD" -eq 0 ] || rm -rf -- "$LOCK"
  LOCK_HELD=0
}

lock_acquire() {
  local tries=0
  ensure_store || return 1
  while ! (umask 077; mkdir "$LOCK") 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 1
    sleep 0.1
  done
  LOCK_HELD=1
  trap 'lock_release' EXIT HUP INT TERM
}

record_id_valid() {
  [ "${#1}" -le 80 ] && [[ "$1" =~ ^m-[0-9]+-[0-9]+-[0-9]+$ ]]
}

# Populates R_ID, R_KIND, R_CREATED, R_DUE, R_STATE, R_NOTIFIED, and R_TEXT.
record_read() {
  local path=$1 line
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r line < "$path" || return 1
  [ "$line" = "$SCHEMA" ] || return 1
  {
    IFS= read -r line && R_ID=${line#id=} && [ "$line" = "id=$R_ID" ]
    IFS= read -r line && R_KIND=${line#kind=} && [ "$line" = "kind=$R_KIND" ]
    IFS= read -r line && R_CREATED=${line#created=} && [ "$line" = "created=$R_CREATED" ]
    IFS= read -r line && R_DUE=${line#due=} && [ "$line" = "due=$R_DUE" ]
    IFS= read -r line && R_STATE=${line#state=} && [ "$line" = "state=$R_STATE" ]
    IFS= read -r line && R_NOTIFIED=${line#notified=} && [ "$line" = "notified=$R_NOTIFIED" ]
    IFS= read -r line && R_TEXT=${line#text=} && [ "$line" = "text=$R_TEXT" ]
    ! IFS= read -r _
  } < <(tail -n +2 "$path") || return 1
  record_id_valid "$R_ID" || return 1
  [ "$(basename "$path")" = "$R_ID" ] || return 1
  case "$R_KIND" in memory|reminder) ;; *) return 1 ;; esac
  case "$R_CREATED" in ''|*[!0-9]*) return 1 ;; esac
  case "$R_STATE" in open|"done") ;; *) return 1 ;; esac
  case "$R_NOTIFIED" in 0|[1-9][0-9]*) ;; *) return 1 ;; esac
  if [ "$R_KIND" = memory ]; then
    [ "$R_DUE" = - ] && [ "$R_STATE" = open ] && [ "$R_NOTIFIED" = 0 ] || return 1
  else
    case "$R_DUE" in ''|*[!0-9]*) return 1 ;; esac
  fi
  validate_text "$R_TEXT"
}

record_write() {
  local path=$1 id=$2 kind=$3 created=$4 due=$5 state=$6 notified=$7 text=$8 tmp
  tmp=$(umask 077; mktemp "$RECORDS/.fm-memory.XXXXXX") || return 1
  if ! printf '%s\nid=%s\nkind=%s\ncreated=%s\ndue=%s\nstate=%s\nnotified=%s\ntext=%s\n' \
      "$SCHEMA" "$id" "$kind" "$created" "$due" "$state" "$notified" "$text" > "$tmp" \
    || ! chmod 0600 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$path"
}

new_id() {
  local now=$1 attempt=0 id
  while [ "$attempt" -lt 100 ]; do
    id="m-$now-$$-$((RANDOM + attempt))"
    [ -e "$RECORDS/$id" ] || { printf '%s\n' "$id"; return 0; }
    attempt=$((attempt + 1))
  done
  return 1
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-memory.sh - due-reminder watcher check.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-memory.sh") check"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle.
# A failed or interrupted arm therefore never leaves a shim without a matching
# trust binding. A previously registered shim is restored; otherwise the shim
# is removed.
SHIM_WRITE_TMP=
ARM_BACKUP=

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-memory-check.XXXXXX" 2>/dev/null) || return 1
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

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-memory: arming was interrupted and rolled back\n' >&2
  exit 1
}

action_arm() {
  local home want device
  mkdir -p "$STATE" || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  want=$(shim_content "$home")
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_TRUST" "$device" || return 1
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || return 1
  fi
  SHIM_WRITE_TMP=$(umask 077; mktemp "$STATE/.fm-memory-check.XXXXXX") || {
    arm_rollback
    return 1
  }
  trap arm_interrupted HUP INT TERM
  if ! printf '%s\n' "$want" > "$SHIM_WRITE_TMP" || ! chmod 0700 "$SHIM_WRITE_TMP" \
    || ! fm_pr_private_file_valid "$SHIM_WRITE_TMP" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$SHIM_WRITE_TMP" "$CHECK_SHIM"; then
    trap - HUP INT TERM
    arm_rollback
    return 1
  fi
  SHIM_WRITE_TMP=
  if ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

has_open_reminder() {
  local path
  for path in "$RECORDS"/*; do
    [ -e "$path" ] || continue
    record_read "$path" || return 2
    [ "$R_KIND" != reminder ] || [ "$R_STATE" != open ] || return 0
  done
  return 1
}

action_disarm() {
  local check_open=0
  lock_acquire || die 'the memory store is busy or unavailable'
  has_open_reminder || check_open=$?
  case "$check_open" in
    0) die 'cannot disarm while an open reminder exists' ;;
    1) ;;
    *) die 'cannot disarm because a stored record is malformed' ;;
  esac
  if [ -e "$CHECK_SHIM" ] || [ -L "$CHECK_SHIM" ] || [ -e "$CHECK_TRUST" ] || [ -L "$CHECK_TRUST" ]; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null \
      || die 'could not retire the reminder check'
  fi
  lock_release
  trap - EXIT HUP INT TERM
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

# Retire the standing check when no open reminder remains.
# A malformed record makes absence unprovable, so the check stays and can
# still surface the corruption. Returns 1 only when retirement was required
# and failed.
retire_check_if_idle() {
  local open_rc=0
  has_open_reminder || open_rc=$?
  case "$open_rc" in
    0|2) return 0 ;;
    1) ;;
    *) return 1 ;;
  esac
  if [ ! -e "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && [ ! -e "$CHECK_TRUST" ] && [ ! -L "$CHECK_TRUST" ]; then
    return 0
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null
}

action_add() {
  local kind=$1 due=$2 text=$3 now id path
  validate_text "$text" || die_usage "text must be one printable line of at most $MAX_TEXT_BYTES bytes"
  now=$(now_epoch) || die 'the current time is unavailable'
  lock_acquire || die 'the memory store is busy or unavailable'
  if [ "$kind" = reminder ]; then
    action_arm >/dev/null || die 'could not arm the due-reminder check; no reminder was recorded'
    trap 'lock_release' EXIT HUP INT TERM
  fi
  if ! id=$(new_id "$now"); then
    [ "$kind" != reminder ] || retire_check_if_idle || true
    die 'could not allocate a record id'
  fi
  path="$RECORDS/$id"
  if ! record_write "$path" "$id" "$kind" "$now" "$due" open 0 "$text"; then
    [ "$kind" != reminder ] || retire_check_if_idle || true
    die 'could not write the record'
  fi
  lock_release
  trap - EXIT HUP INT TERM
  if [ "$kind" = memory ]; then
    printf 'recorded memory %s\n' "$id"
  else
    printf 'recorded reminder %s due %s\n' "$id" "$(iso_for_epoch "$due" || printf '%s' "$due")"
  fi
}

print_record() {
  local due_display=-
  [ "$R_DUE" = - ] || due_display=$(iso_for_epoch "$R_DUE" || printf '%s' "$R_DUE")
  printf '%s\t%s\t%s\t%s\t%s\n' "$R_ID" "$R_KIND" "$R_STATE" "$due_display" "$R_TEXT"
}

action_list() {
  local show_all=0 kind="" path
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) show_all=1 ;;
      --kind)
        shift
        [ "$#" -gt 0 ] || die_usage '--kind requires memory or reminder'
        case "$1" in memory|reminder) kind=$1 ;; *) die_usage '--kind requires memory or reminder' ;; esac
        ;;
      *) die_usage "unknown list argument: $1" ;;
    esac
    shift
  done
  ensure_store || die 'the memory store is unavailable'
  for path in "$RECORDS"/*; do
    [ -e "$path" ] || continue
    record_read "$path" || die "malformed record: $(basename "$path")"
    [ "$show_all" -eq 1 ] || [ "$R_STATE" = open ] || continue
    [ -z "$kind" ] || [ "$R_KIND" = "$kind" ] || continue
    print_record
  done
}

action_search() {
  local show_all=0 query path lowered_text lowered_query
  if [ "${1:-}" = --all ]; then
    show_all=1
    shift
  fi
  [ "$#" -gt 0 ] || die_usage 'search requires a query'
  query=$*
  validate_text "$query" || die_usage "query must be one printable line of at most $MAX_TEXT_BYTES bytes"
  lowered_query=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')
  ensure_store || die 'the memory store is unavailable'
  for path in "$RECORDS"/*; do
    [ -e "$path" ] || continue
    record_read "$path" || die "malformed record: $(basename "$path")"
    [ "$show_all" -eq 1 ] || [ "$R_STATE" = open ] || continue
    lowered_text=$(printf '%s' "$R_TEXT" | tr '[:upper:]' '[:lower:]')
    if printf '%s\n' "$lowered_text" | grep -F -e "$lowered_query" >/dev/null; then
      print_record
    fi
  done
}

action_done() {
  local id=${1:-} path now="" already=0
  [ "$#" -eq 1 ] || die_usage 'done requires exactly one reminder id'
  record_id_valid "$id" || die_usage 'invalid reminder id'
  lock_acquire || die 'the memory store is busy or unavailable'
  path="$RECORDS/$id"
  [ -e "$path" ] || die "no such reminder: $id"
  record_read "$path" || die "malformed record: $id"
  [ "$R_KIND" = reminder ] || die "$id is a memory, not a reminder"
  if [ "$R_STATE" = "done" ]; then
    already=1
  else
    now=$(now_epoch) || die 'the current time is unavailable'
    record_write "$path" "$R_ID" "$R_KIND" "$R_CREATED" "$R_DUE" "done" "$R_NOTIFIED" "$R_TEXT" \
      || die 'could not update the reminder'
  fi
  # Retirement stays inside the store lock so a concurrent reminder cannot arm
  # and then lose its check to this retirement.
  if ! retire_check_if_idle; then
    lock_release
    trap - EXIT HUP INT TERM
    if [ "$already" -eq 1 ]; then
      die "reminder $id is already done, but the standing check could not be retired"
    fi
    die "marked $id done, but the standing check could not be retired"
  fi
  lock_release
  trap - EXIT HUP INT TERM
  if [ "$already" -eq 1 ]; then
    printf 'already done: %s\n' "$id"
  else
    printf 'done: %s at %s\n' "$id" "$now"
  fi
}

truncate_wake_text() {
  local text=$1
  if [ "$(printf '%s' "$text" | wc -c | tr -d '[:space:]')" -le "$MAX_WAKE_TEXT_BYTES" ]; then
    printf '%s' "$text"
  else
    printf '%s...' "$(printf '%s' "$text" | LC_ALL=C cut -b "1-$MAX_WAKE_TEXT_BYTES")"
  fi
}

action_check() {
  local now path count=0 report="" text malformed=""
  now=$(now_epoch) || { printf 'memory reminders: current time unavailable\n'; return 0; }
  lock_acquire || { printf 'memory reminders: store busy or unavailable\n'; return 0; }
  for path in "$RECORDS"/*; do
    [ -e "$path" ] || continue
    if ! record_read "$path"; then
      [ -n "$malformed" ] || malformed=$(basename "$path")
      continue
    fi
    [ "$count" -lt "$MAX_DUE_PER_CHECK" ] || continue
    [ "$R_KIND" = reminder ] && [ "$R_STATE" = open ] && [ "$R_NOTIFIED" = 0 ] \
      && [ "$R_DUE" -le "$now" ] 2>/dev/null || continue
    if ! record_write "$path" "$R_ID" "$R_KIND" "$R_CREATED" "$R_DUE" "$R_STATE" "$now" "$R_TEXT"; then
      report="${report:+$report; }could not mark $R_ID notified"
      break
    fi
    text=$(truncate_wake_text "$R_TEXT")
    if [ -z "$report" ]; then
      report="memory reminder due: $R_ID $text"
    else
      report="$report; $R_ID $text"
    fi
    count=$((count + 1))
  done
  lock_release
  trap - EXIT HUP INT TERM
  if [ -n "$malformed" ]; then
    if [ -z "$report" ]; then
      report="memory reminders: malformed record $malformed"
    else
      report="$report; malformed record $malformed"
    fi
  fi
  [ -z "$report" ] || printf '%s\n' "$report"
}

command=${1:-}
[ -n "$command" ] || { usage; exit 2; }
shift
case "$command" in
  remember)
    [ "$#" -gt 0 ] || die_usage 'remember requires text'
    action_add memory - "$*"
    ;;
  remind)
    [ "$#" -ge 3 ] || die_usage 'remind requires --at/--in, a time, and text'
    mode=$1
    value=$2
    shift 2
    due=$(parse_due "$mode" "$value") || die_usage 'invalid reminder time'
    action_add reminder "$due" "$*"
    ;;
  list) action_list "$@" ;;
  search) action_search "$@" ;;
  "done") action_done "$@" ;;
  arm)
    [ "$#" -eq 0 ] || die_usage 'arm takes no arguments'
    action_arm || die 'could not arm the due-reminder check'
    ;;
  disarm)
    [ "$#" -eq 0 ] || die_usage 'disarm takes no arguments'
    action_disarm
    ;;
  check)
    [ "$#" -eq 0 ] || die_usage 'check takes no arguments'
    action_check
    ;;
  -h|--help|help) usage ;;
  *) die_usage "unknown command: $command" ;;
esac
