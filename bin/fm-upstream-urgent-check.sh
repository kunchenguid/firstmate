#!/usr/bin/env bash
# Fetch upstream/main once and report new commits whose subject or body carries
# an urgent-upstream keyword.
#
# Usage:
#   fm-upstream-urgent-check.sh check
#   fm-upstream-urgent-check.sh arm
#   fm-upstream-urgent-check.sh disarm
#   fm-upstream-urgent-check.sh --help
#
# `check` is silent when no matching commit exists, so it is safe to run as a
# registered watcher check.
# `arm` writes and registers state/upstream-urgent.check.sh.
# `disarm` removes that shim, its trust binding, and the report record.
#
# The report record state/.upstream-urgent carries the reports the last lines
# were made from, uncut, so one urgent commit is reported once rather than on
# every watcher poll while the recorded sync base still trails it.
#
# A condition that stops the inspection is split by whether retrying can clear
# it, because the watcher turns any stdout line into a firstmate wake and only
# a matching commit is allowed to wake anyone about.
#
#   Retryable   a failed fetch, an upstream/main missing right after one, a log
#               that could not be read. Network, sleep/wake, a concurrent gc.
#               These go to stderr and a non-zero exit ONLY, so a flapping link
#               cannot wake firstmate once per poll about a condition that the
#               next poll may well clear on its own.
#   Unusable    no readable sync base, no upstream remote, a recorded base that
#               is not a commit here or not an ancestor of upstream/main. No
#               amount of retrying fixes these; the tripwire is armed and dead
#               until a human edits the catch-up log or the remote. These report
#               on stderr, once, for a hand run without waking firstmate.
#
# Every failure still exits non-zero, so a hand run and the test suite can tell
# a failed inspection from a silent one either way.
#
# A hit and an unusable-tripwire report keep SEPARATE keys, because they
# interleave on their own schedules: a pending urgent commit stays pending for
# days, until a sync advances the base. One shared slot would let a report of
# the other kind evict the hit's suppression state and re-announce the same
# commit set on the next poll that succeeds.
set -u
# The upstream probe must never stop to ask for credentials; an unauthenticated
# fetch has to fail inside its bound instead of waiting for an answer.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SYNC_LOG="$FM_ROOT/docs/upstream-sync.md"
CHECK_ID=upstream-urgent
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.$CHECK_ID"
RECORD_SCHEMA=fm-upstream-urgent-v2
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
# Wider than the digest default because one finding names a 12-character hash
# and a full commit subject, and a window can carry several of them.
MAX_LINE=1000

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

WATCHER_CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
if [[ "$WATCHER_CHECK_TIMEOUT" =~ ^0*([0-9]+)$ ]]; then
  WATCHER_CHECK_TIMEOUT=${BASH_REMATCH[1]}
else
  WATCHER_CHECK_TIMEOUT=30
fi
[ "$WATCHER_CHECK_TIMEOUT" != 0 ] || WATCHER_CHECK_TIMEOUT=30
if [ "${#WATCHER_CHECK_TIMEOUT}" -gt 9 ]; then
  WATCHER_CHECK_TIMEOUT=10
fi
WATCHER_CHECK_TIMEOUT=$((10#$WATCHER_CHECK_TIMEOUT))
CHECK_TIMEOUT=$((WATCHER_CHECK_TIMEOUT - 2))
[ "$CHECK_TIMEOUT" -ge 1 ] || CHECK_TIMEOUT=1
[ "$CHECK_TIMEOUT" -le 8 ] || CHECK_TIMEOUT=8
FETCH_TIMEOUT=$((CHECK_TIMEOUT - 1))
[ "$FETCH_TIMEOUT" -ge 1 ] || FETCH_TIMEOUT=1

usage() {
  cat <<'EOF'
Usage:
  fm-upstream-urgent-check.sh check    fetch upstream/main and report urgent commits
  fm-upstream-urgent-check.sh arm      write and register the watcher check shim
  fm-upstream-urgent-check.sh disarm   remove the check shim, its trust binding, and the record
  fm-upstream-urgent-check.sh --help   print this help

The check reads the latest adopted upstream base from docs/upstream-sync.md.
It prints on stdout only when a commit since that base matches security, CVE,
breaking, revert, data loss, or credential. An unusable tripwire reports once
on stderr until someone repairs its base or remote; a retryable failure - a
fetch, a missing ref, or an unreadable log - also goes only to stderr.
EOF
}

die_usage() {
  printf 'fm-upstream-urgent-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

latest_sync_base() {
  local LC_ALL=C
  export LC_ALL
  local field tick=$'\140'
  [ -f "$SYNC_LOG" ] || return 1
  field=$(awk -F'|' '
    $0 ~ /^\| [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \|/ { value=$3 }
    END { print value }
  ' "$SYNC_LOG") || return 1
  # The column carries the adopted upstream base first and may name a later
  # origin/main landing hash after it, so take the FIRST backticked bare hex
  # token rather than letting a greedy match walk to the last one.
  printf '%s\n' "$field" \
    | grep -o "${tick}[0-9a-f]\{7,40\}${tick}" \
    | head -n 1 \
    | tr -d "$tick"
}

urgent_commits() {
  local LC_ALL=C
  export LC_ALL
  local commit subject body clean found=0
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    subject=$(git -C "$FM_ROOT" show -s --format='%s' "$commit") || return 1
    body=$(git -C "$FM_ROOT" show -s --format='%b' "$commit") || return 1
    if clean=$(printf '%s\n%s' "$subject" "$body" | awk '
      {
        if (NR == 1) subject = $0
        text = text "\n" $0
      }
      END {
        text=tolower(text)
        if (text !~ /(^|[^[:alnum:]])(security|cve|breaking|revert|data[[:space:]-]+loss|credential(s)?)([^[:alnum:]]|$)/) exit 1
        gsub(/[[:cntrl:]]+/, " ", subject)
        gsub(/[[:space:]]+/, " ", subject)
        if (subject == "") subject="(no subject)"
        printf "%s", subject
      }
    '); then
      if [ "$found" -gt 0 ]; then
        printf '; '
      fi
      printf '%s "%s"' "${commit:0:12}" "$clean"
      found=1
    fi
  done
  return 0
}

RECORD_REPORTED=
RECORD_FAILED=

state_path_components_are_safe() {
  local path=$STATE parent home
  case "$STATE" in
    */) return 1 ;;
  esac
  [ ! -L "$STATE" ] || return 1
  if [ -z "${FM_STATE_OVERRIDE:-}" ]; then
    home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
    path="$home/state"
  else
    case "$path" in
      /*) ;;
      *) path="$(pwd -P)/$path" || return 1 ;;
    esac
  fi
  while :; do
    [ ! -L "$path" ] || return 1
    if [ -e "$path" ]; then
      [ -d "$path" ] || return 1
    fi
    [ "$path" = / ] && return 0
    parent=$(dirname -- "$path") || return 1
    [ "$parent" != "$path" ] || return 0
    path=$parent
  done
}

state_directory_is_safe() {
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  state_path_components_are_safe
}

state_directory_prepare() {
  state_path_components_are_safe || return 1
  if [ ! -e "$STATE" ]; then
    mkdir -p "$STATE" || return 1
  fi
  state_directory_is_safe
}

record_read() {
  local line line_number=0 valid=1 device
  RECORD_REPORTED=
  RECORD_FAILED=
  [ -f "$RECORD" ] || return 0
  state_directory_is_safe || return 0
  device=$(fm_pr_file_device "$STATE") || return 0
  fm_pr_private_file_valid "$RECORD" 600 "$device" || return 0
  while IFS= read -r line; do
    line_number=$((line_number + 1))
    case "$line_number" in
      1)
        [ "$line" = "$RECORD_SCHEMA" ] || valid=0
        ;;
      2)
        case "$line" in
          reported=*) RECORD_REPORTED=${line#reported=} ;;
          *) valid=0 ;;
        esac
        ;;
      3)
        case "$line" in
          failed=*) RECORD_FAILED=${line#failed=} ;;
          *) valid=0 ;;
        esac
        ;;
      *) valid=0 ;;
    esac
  done < "$RECORD"
  if [ "$line_number" -ne 3 ] || [ "$valid" -ne 1 ]; then
    RECORD_REPORTED=
    RECORD_FAILED=
  fi
  return 0
}

record_write() {
  local reported=$1 failed=$2 tmp device
  state_directory_prepare || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || return 1
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'reported=%s\n' "$reported"
    printf 'failed=%s\n' "$failed"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# The cut line is what gets printed, but the whole payload decides whether this
# is news, because a commit that lands past the cut leaves the printed line
# unchanged and would otherwise be suppressed for good.
report_emit() {
  local payload=$1 previous=$2
  fm_cap_line_var "$payload" "$MAX_LINE"
  [ "$payload" = "$previous" ] || printf '%s\n' "$FM_LINE_CAP_LINE"
}

# Report before recording throughout, so a record that cannot be written costs a
# repeated report rather than a lost one.
report_hit() {
  local payload=$1
  record_read
  report_emit "$payload" "$RECORD_REPORTED"
  # An inspection that ran to its end retires any failure the record still held.
  record_write "$payload" '' || true
}

report_clear() {
  record_read
  if [ -n "$RECORD_REPORTED" ] || [ -n "$RECORD_FAILED" ]; then
    record_write '' '' || true
  fi
}

check_retryable() {
  printf 'upstream urgent check: %s\n' "$1" >&2
  return 1
}

check_unusable() {
  local payload="upstream urgent check failed: $1"
  record_read
  report_emit "$payload" "$RECORD_FAILED" >&2
  # The match set the record already holds is carried through untouched, so a
  # report of this kind cannot make an unchanged pending commit set news again.
  record_write "$RECORD_REPORTED" "$payload" || true
  return 1
}

upstream_remote_is_canonical() {
  case "$1" in
    git@github.com:kunchenguid/firstmate|git@github.com:kunchenguid/firstmate.git|\
    ssh://git@github.com/kunchenguid/firstmate|ssh://git@github.com/kunchenguid/firstmate.git|\
    https://github.com/kunchenguid/firstmate|https://github.com/kunchenguid/firstmate.git)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

action_check_inner() {
  local base base_commit upstream_tip remote_url matches log ancestor_status
  base=$(latest_sync_base) || {
    check_unusable 'latest sync base is unavailable'
    return 1
  }
  [ -n "$base" ] || {
    check_unusable 'latest sync base is unavailable'
    return 1
  }
  remote_url=$(git -C "$FM_ROOT" remote get-url upstream 2>/dev/null) || {
    check_unusable 'upstream remote is unavailable'
    return 1
  }
  [ -n "$remote_url" ] || {
    check_unusable 'upstream remote is unavailable'
    return 1
  }
  upstream_remote_is_canonical "$remote_url" || {
    check_unusable 'upstream remote does not point at kunchenguid/firstmate'
    return 1
  }
  # This is the only network operation in the tripwire.
  fm_run_timed "$FETCH_TIMEOUT" git -C "$FM_ROOT" fetch --quiet --no-tags upstream \
    +main:refs/remotes/upstream/main >/dev/null 2>&1 || {
    check_retryable 'fetch failed'
    return 1
  }
  upstream_tip=$(git -C "$FM_ROOT" rev-parse --verify --quiet \
    'refs/remotes/upstream/main^{commit}') || {
    check_retryable 'upstream/main is unavailable after fetch'
    return 1
  }
  base_commit=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$base^{commit}") || {
    check_unusable "recorded base $base is not a commit in this clone"
    return 1
  }
  ancestor_status=0
  git -C "$FM_ROOT" merge-base --is-ancestor "$base_commit" "$upstream_tip" || ancestor_status=$?
  case "$ancestor_status" in
    0) ;;
    1)
      check_unusable "recorded base $base is not an ancestor of upstream/main"
      return 1
      ;;
    *)
      check_retryable 'could not verify recorded base ancestry'
      return 1
      ;;
  esac
  # The log is captured before it is matched, because a pipeline would take its
  # status from awk alone and report a failed inspection as a clean check.
  log=$(git -C "$FM_ROOT" log --reverse --format='%H' \
    "$base_commit..$upstream_tip") || {
    check_retryable 'could not inspect upstream commits'
    return 1
  }
  matches=$(printf '%s\n' "$log" | urgent_commits) || {
    check_retryable 'could not inspect upstream commits'
    return 1
  }
  [ -n "$matches" ] || {
    # A clean window clears the record, so the same commit set or the same
    # unusable-tripwire condition is news again if either comes back. Only a
    # condition that needed a human to clear can be in that slot, so this cannot
    # turn a flapping link into a wake per poll.
    report_clear
    return 0
  }
  report_hit "urgent upstream commits: $matches"
  return 0
}

action_check() {
  local status=0
  fm_run_timed "$CHECK_TIMEOUT" "$SCRIPT_DIR/fm-upstream-urgent-check.sh" \
    __check_inner || status=$?
  if [ "$status" -eq 124 ]; then
    check_retryable 'check timed out'
    return 1
  fi
  return "$status"
}

shim_content() {
  local home=$1 root=$2
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# Generated by fm-upstream-urgent-check.sh.'
  printf 'export FM_ROOT_OVERRIDE=%q\n' "$root"
  printf 'export FM_HOME=%q\n' "$home"
  printf 'exec %q check\n' "$SCRIPT_DIR/fm-upstream-urgent-check.sh"
}

SHIM_WRITE_TMP=

write_shim() {
  local content=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-upstream-urgent-check.XXXXXX") || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! mv -f -- "$tmp" "$CHECK_SHIM"; then
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
  tmp=$(umask 077; mktemp "$STATE/.fm-upstream-urgent-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding. The shim a working home had is put back and kept only
# when it is still bound; otherwise the shim goes, so the home is plainly not
# armed and the failure is the only thing the operator has to act on.
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
  printf 'fm-upstream-urgent-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local home root content
  state_directory_prepare || return 1
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-upstream-urgent-check: FM_HOME cannot be resolved\n' >&2
    return 1
  }
  root=$(CDPATH='' cd -- "$FM_ROOT" 2>/dev/null && pwd -P) || {
    printf 'fm-upstream-urgent-check: FM_ROOT cannot be resolved\n' >&2
    return 1
  }
  content=$(shim_content "$home" "$root") || return 1
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-upstream-urgent-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! write_shim "$content"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-upstream-urgent-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-upstream-urgent-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  if ! state_directory_is_safe; then
    printf 'fm-upstream-urgent-check: state directory is unavailable or symlinked\n' >&2
    return 1
  fi
  if ! rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"; then
    printf 'fm-upstream-urgent-check: could not fully disarm state/%s.check.sh\n' "$CHECK_ID" >&2
    return 1
  fi
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) [ "$#" -eq 1 ] || die_usage 'check takes no additional arguments'; action_check ;;
  __check_inner) [ "$#" -eq 1 ] || die_usage 'internal check takes no additional arguments'; action_check_inner ;;
  arm) [ "$#" -eq 1 ] || die_usage 'arm takes no additional arguments'; action_arm ;;
  disarm) [ "$#" -eq 1 ] || die_usage 'disarm takes no additional arguments'; action_disarm ;;
  -h|--help) [ "$#" -eq 1 ] || die_usage '--help takes no additional arguments'; usage ;;
  *) die_usage "unknown action: $1" ;;
esac
