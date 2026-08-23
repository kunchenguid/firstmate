#!/usr/bin/env bash
# Unarmed lab for one external, idle-aware /stow attempt.
#
# This script is deliberately not a scheduler and is not called by bootstrap,
# the watcher, or the away-mode daemon.
# A genuinely separate primary or secondmate agent may run one scan against a
# directly related home; every actual text submission delegates to fm-send.sh,
# the existing external sender owner.
#
# Usage:
#   fm-stow-cadence-lab.sh activity <busy|idle> --harness <claude|codex|pi|pi-signed|cursor-agent>
#       [--backend <backend> --target <backend-target>]
#   fm-stow-cadence-lab.sh complete
#   fm-stow-cadence-lab.sh run --target-home <home> --target <backend-target>
#       --backend <backend> --harness <harness> [--wait-seconds <seconds>]
#
# activity is called only by the tracked primary lifecycle adapters.
# A busy edge increments the per-home semantic activity sequence; its matching
# idle edge closes that sequence.
# complete is called by the stow skill after its required curation pass and
# completion receipt are ready.
# It accepts only one outstanding due receipt and records success idempotently.
# run requires FM_HOME to name the sender home, proves a local parent/secondmate
# relationship in either direction, refuses same-home injection, creates the
# target home's due receipt before sending, and waits a bounded interval for
# complete to publish success.
#
# Durable private state under the TARGET home's state/stow-cadence/:
#   activity.receipt                 semantic target activity
#   due/s<seq>.receipt               one outstanding activity generation
#   success/s<seq>.receipt           completed /stow receipt
#   failure/s<seq>-<class>.receipt   idempotent deferral/failure receipt
#
# Failure classes are busy, unavailable, permission-refused, unsupported,
# dead, receipt-timeout, shared-memory-mutated, shared-memory-unsafe, and
# superseded.
# Busy, unavailable, permission-refused, unsupported, and dead are deliberate
# deferrals and exit 3.
# An authorization failure exits 4 and never sends.
#
# Supported skill invocations are adapter-specific and exact:
#   claude      /stow
#   codex       $stow
#   pi          /skill:stow
#   pi-signed   /skill:stow
# Cursor primary and secondmate scheduling remains unsupported.
# No path ever sends /compact.
#
# Test seams:
#   FM_STOW_SEND_BIN          sender executable (default bin/fm-send.sh)
#   FM_STOW_TARGET_PROBE_BIN  executable receiving <backend> <target>; zero=alive
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

canonical_dir() {  # <dir>
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

now_epoch() {
  date +%s
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null
  else stat -c %a "$1" 2>/dev/null; fi
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

record_value() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

token_valid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

uint_valid() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

ensure_private_tree() {  # <state>
  local root="$1/stow-cadence"
  mkdir -p "$root/due" "$root/success" "$root/failure"
  chmod 0700 "$root" "$root/due" "$root/success" "$root/failure"
}

publish_record() {  # <path> <content>
  local path=$1 content=$2 tmp
  tmp="$path.tmp.$$"
  umask 077
  printf '%s' "$content" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

publish_record_once() {  # <path> <content>
  local path=$1 content=$2 tmp
  [ ! -e "$path" ] || return 0
  tmp="$path.tmp.$$"
  umask 077
  printf '%s' "$content" > "$tmp"
  chmod 0600 "$tmp"
  if mv -n -- "$tmp" "$path" 2>/dev/null; then return 0; fi
  rm -f -- "$tmp"
  [ -e "$path" ]
}

lock_acquire() {  # <state>
  local lock="$1/stow-cadence/.lock" tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.02
  done
  chmod 0700 "$lock"
  STOW_LOCK=$lock
}

lock_release() {
  [ -n "${STOW_LOCK:-}" ] || return 0
  rmdir "$STOW_LOCK" 2>/dev/null || true
  STOW_LOCK=
}

trap lock_release EXIT INT TERM

primary_home_required() {  # <home>
  local home=$1 state="$1/state"
  [ -d "$state" ] || return 1
  if fm_root_is_secondmate_home "$home"; then
    [ -f "$home/.fm-secondmate-parent" ] && [ ! -L "$home/.fm-secondmate-parent" ] \
      && [ -f "$home/AGENTS.md" ] && [ -d "$home/bin" ]
    return
  fi
  fm_primary_scope_matches "$home" "$state"
}

authorized_home_required() {  # <home> <counterpart-home>
  local home=$1 counterpart=$2 id saved_home validated meta meta_home
  if ! fm_root_is_secondmate_home "$home"; then
    fm_primary_scope_matches "$home" "$home/state"
    return
  fi
  id=$(sed -n '1p' "$home/.fm-secondmate-home" 2>/dev/null)
  token_valid "$id" || return 1
  saved_home=${FM_HOME:-}
  FM_HOME=$counterpart
  if validate_secondmate_home "$id" "$home" >/dev/null 2>&1; then
    validated=$VALIDATED_HOME
  else
    validated=
  fi
  FM_HOME=$saved_home
  [ "$validated" = "$home" ] || return 1
  meta="$counterpart/state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 1
  meta_home=$(fm_meta_get "$meta" home)
  meta_home=$(canonical_dir "$meta_home" 2>/dev/null || true)
  [ "$meta_home" = "$home" ]
}

activity_record_valid() {  # <record>
  local record=$1 schema seq state harness backend target source ts
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  schema=$(record_value "$record" schema)
  seq=$(record_value "$record" seq)
  state=$(record_value "$record" state)
  harness=$(record_value "$record" harness)
  backend=$(record_value "$record" backend)
  target=$(record_value "$record" target)
  source=$(record_value "$record" source)
  ts=$(record_value "$record" ts)
  [ "$schema" = fm-stow-activity.v1 ] || return 1
  uint_valid "$seq" && [ "$seq" -gt 0 ] || return 1
  case "$state" in busy|idle) : ;; *) return 1 ;; esac
  token_valid "$harness" && token_valid "$backend" && [ -n "$target" ] \
    && token_valid "$source" && uint_valid "$ts"
}

discover_activity_endpoint() {
  local backend target
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  backend=$(discover_supervisor_backend) || return 1
  target=$(discover_supervisor_target) || return 1
  if [ "$backend" = tmux ]; then
    target=$(tmux display-message -p -t "$target" '#{session_name}:#{window_name}' 2>/dev/null) || return 1
  fi
  token_valid "$backend" && [ -n "$target" ] || return 1
  printf '%s|%s' "$backend" "$target"
}

activity_cmd() {
  local state_value=${1:-} harness='' backend='' target='' endpoint home state_dir record
  local seq=0 current_state current_harness content due due_status due_seq
  local observed_invocation=''
  shift || true
  [ "$state_value" = busy ] || [ "$state_value" = idle ] || usage
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness) [ "$#" -ge 2 ] || usage; harness=$2; shift 2 ;;
      --backend) [ "$#" -ge 2 ] || usage; backend=$2; shift 2 ;;
      --target) [ "$#" -ge 2 ] || usage; target=$2; shift 2 ;;
      --invocation-stdin) IFS= read -r observed_invocation || true; shift ;;
      *) usage ;;
    esac
  done
  token_valid "$harness" || die "invalid harness for activity"
  if [ -z "$backend" ] && [ -z "$target" ]; then
    endpoint=$(discover_activity_endpoint) || die "could not resolve the target home's own endpoint"
    backend=${endpoint%%|*}
    target=${endpoint#*|}
  fi
  token_valid "$backend" && [ -n "$target" ] || die "invalid endpoint for activity"
  case "$target" in *$'\n'*|*$'\r'*) die "invalid endpoint for activity" ;; esac
  home=$(canonical_dir "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") \
    || die "FM_HOME must name the target home"
  primary_home_required "$home" || exit 0
  state_dir="$home/state"
  ensure_private_tree "$state_dir"
  lock_acquire "$state_dir" || die "could not lock stow cadence state"
  record="$state_dir/stow-cadence/activity.receipt"
  if activity_record_valid "$record"; then
    seq=$(record_value "$record" seq)
    current_state=$(record_value "$record" state)
    current_harness=$(record_value "$record" harness)
  else
    current_state=unknown
    current_harness=
  fi
  if [ "$state_value" = busy ]; then
    seq=$((seq + 1))
    for due in "$state_dir/stow-cadence/due"/*.receipt; do
      [ -f "$due" ] || continue
      due_status=$(record_value "$due" status)
      [ "$due_status" = sending ] || [ "$due_status" = observed ] || continue
      [ "$observed_invocation" = "$(invocation_for_harness "$(record_value "$due" harness)" 2>/dev/null || true)" ] \
        || continue
      due_seq=$(record_value "$due" seq)
      publish_record "$due" "$(due_content "$due_seq" observed \
        "$(record_value "$due" harness)" "$(record_value "$due" backend)" \
        "$(record_value "$due" target)" "$(record_value "$due" shared_sha256)" \
        "$(record_value "$due" shared_mode)" "$seq")"
      break
    done
  else
    [ "$current_state" = busy ] || { lock_release; return 0; }
    [ "$current_harness" = "$harness" ] || { lock_release; return 0; }
    for due in "$state_dir/stow-cadence/due"/*.receipt; do
      [ -f "$due" ] || continue
      [ "$(record_value "$due" status)" = failed-observed ] || continue
      [ "$(record_value "$due" active_seq)" = "$seq" ] || continue
      failure_record "$state_dir" "$(record_value "$due" seq)" unconfirmed \
        "observed invocation settled without external transport acknowledgment"
      rm -f -- "$due"
    done
  fi
  content=$(printf 'schema=fm-stow-activity.v1\nseq=%s\nstate=%s\nharness=%s\nbackend=%s\ntarget=%s\nsource=%s-primary\nts=%s\n' \
    "$seq" "$state_value" "$harness" "$backend" "$target" "$harness" "$(now_epoch)")
  publish_record "$record" "$content"
  lock_release
}

related_homes_authorized() {  # <sender> <target>
  local sender=$1 target=$2 parent
  [ "$sender" != "$target" ] || return 1
  if fm_root_is_secondmate_home "$target" \
    && fm_secondmate_parent_record_parse "$target/.fm-secondmate-parent" \
    && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    parent=$(canonical_dir "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null || true)
    [ "$parent" = "$sender" ] && return 0
  fi
  if fm_root_is_secondmate_home "$sender" \
    && fm_secondmate_parent_record_parse "$sender/.fm-secondmate-parent" \
    && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    parent=$(canonical_dir "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null || true)
    [ "$parent" = "$target" ] && return 0
  fi
  return 1
}

endpoint_authorized_for_home() {  # <activity-record> <backend> <target> <harness>
  [ "$(record_value "$1" backend)" = "$2" ] \
    && [ "$(record_value "$1" target)" = "$3" ] \
    && [ "$(record_value "$1" harness)" = "$4" ]
}

invocation_for_harness() {  # <harness>
  case "$1" in
    claude|claude-*) printf '/stow' ;;
    codex|codex-*) printf '%s' "\$stow" ;;
    pi|pi-signed) printf '/skill:stow' ;;
    *) return 1 ;;
  esac
}

failure_record() {  # <state> <seq> <class> <detail>
  local state=$1 seq=$2 class=$3 detail=$4 path content
  token_valid "$class" || return 1
  case "$seq" in ''|*[!0-9]*) seq=unknown ;; esac
  ensure_private_tree "$state"
  path="$state/stow-cadence/failure/s${seq}-${class}.receipt"
  detail=${detail//$'\n'/ }
  detail=${detail//$'\r'/ }
  content=$(printf 'schema=fm-stow-failure.v1\nseq=%s\nclass=%s\nts=%s\ndetail=%s\n' \
    "$seq" "$class" "$(now_epoch)" "$detail")
  publish_record_once "$path" "$content"
}

latest_success_seq() {  # <state>
  local file seq max=0
  for file in "$1/stow-cadence/success"/*.receipt; do
    [ -f "$file" ] || continue
    seq=$(record_value "$file" activity_seq)
    uint_valid "$seq" || continue
    [ "$seq" -le "$max" ] || max=$seq
  done
  printf '%s' "$max"
}

retire_older_due() {  # <state> <current-seq>
  local state=$1 current=$2 file old
  for file in "$state/stow-cadence/due"/*.receipt; do
    [ -f "$file" ] || continue
    old=$(record_value "$file" seq)
    uint_valid "$old" || continue
    [ "$old" -lt "$current" ] || continue
    failure_record "$state" "$old" superseded "new semantic activity advanced to seq=$current"
    rm -f -- "$file"
  done
}

shared_snapshot() {  # <target-home>
  local home=$1 file="$1/data/captain-shared.md" mode sha
  if ! fm_root_is_secondmate_home "$home"; then
    printf 'not-applicable|not-applicable'
    return 0
  fi
  if [ ! -e "$file" ]; then
    printf 'absent|absent'
    return 0
  fi
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  mode=$(file_mode "$file") || return 1
  case "$mode" in
    *[2367]*) return 1 ;;
  esac
  sha=$(file_sha256 "$file") || return 1
  printf '%s|%s' "$sha" "$mode"
}

due_content() {  # <seq> <status> <harness> <backend> <target> <shared-sha> <shared-mode> [<active-seq>]
  local target=$5
  target=${target//$'\n'/ }
  printf 'schema=fm-stow-due.v1\nseq=%s\nstatus=%s\nharness=%s\nbackend=%s\ntarget=%s\nshared_sha256=%s\nshared_mode=%s\nactive_seq=%s\nts=%s\n' \
    "$1" "$2" "$3" "$4" "$target" "$6" "$7" "${8:--}" "$(now_epoch)"
}

default_probe() {  # <backend> <target>
  fm_backend_target_exists "$1" "$2"
}

run_cmd() {
  local target_home='' target='' backend='' harness='' wait_seconds=5 sender_home target_state activity
  local seq activity_state activity_harness success_seq due active_due active_status active_seq
  local shared shared_sha shared_mode invocation
  local probe send_bin send_out rc=0 end success failure_class failure_message timeout_recheck
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target-home) [ "$#" -ge 2 ] || usage; target_home=$2; shift 2 ;;
      --target) [ "$#" -ge 2 ] || usage; target=$2; shift 2 ;;
      --backend) [ "$#" -ge 2 ] || usage; backend=$2; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || usage; harness=$2; shift 2 ;;
      --wait-seconds) [ "$#" -ge 2 ] || usage; wait_seconds=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$target_home" ] && [ -n "$target" ] && [ -n "$backend" ] && [ -n "$harness" ] || usage
  uint_valid "$wait_seconds" || usage
  if ! token_valid "$backend" || ! token_valid "$harness"; then usage; fi
  case "$target" in
    *:*) : ;;
    *) die "target must be an explicit backend endpoint containing ':'" ;;
  esac
  sender_home=$(canonical_dir "${FM_HOME:-}") || die "FM_HOME must name the external sender home"
  target_home=$(canonical_dir "$target_home") || die "target home is unavailable"
  if ! related_homes_authorized "$sender_home" "$target_home"; then
    printf 'blocked: a genuinely separate sender cannot be authorized for sender=%s target=%s\n' \
      "$sender_home" "$target_home" >&2
    return 4
  fi
  if ! authorized_home_required "$sender_home" "$target_home"; then
    printf 'blocked: external sender home is not a validated primary or secondmate home\n' >&2
    return 4
  fi
  if ! authorized_home_required "$target_home" "$sender_home"; then
    printf 'blocked: target home is not a validated primary or secondmate home\n' >&2
    return 4
  fi
  target_state="$target_home/state"
  ensure_private_tree "$target_state"
  activity="$target_state/stow-cadence/activity.receipt"
  if ! activity_record_valid "$activity"; then
    failure_record "$target_state" unknown unavailable "semantic activity missing or malformed"
    printf 'deferred: unavailable semantic activity is not proven\n'
    return 3
  fi
  if ! endpoint_authorized_for_home "$activity" "$backend" "$target" "$harness"; then
    printf 'blocked: target endpoint is not bound to the authorized target home\n' >&2
    return 4
  fi
  seq=$(record_value "$activity" seq)
  activity_state=$(record_value "$activity" state)
  activity_harness=$(record_value "$activity" harness)
  if [ "$activity_harness" != "$harness" ]; then
    failure_record "$target_state" "$seq" unavailable "activity harness mismatch"
    printf 'deferred: unavailable semantic activity belongs to harness %s, not %s\n' "$activity_harness" "$harness"
    return 3
  fi
  success_seq=$(latest_success_seq "$target_state")
  if [ "$success_seq" -ge "$seq" ]; then
    printf 'unchanged: no new activity since successful receipt seq=%s\n' "$success_seq"
    return 0
  fi
  invocation=$(invocation_for_harness "$harness" 2>/dev/null || true)
  if [ -z "$invocation" ]; then
    failure_record "$target_state" "$seq" unsupported "no adapter-verified stow invocation for $harness"
    printf 'deferred: unsupported harness %s has no adapter-verified stow invocation\n' "$harness"
    return 3
  fi
  if [ "$activity_state" != idle ]; then
    failure_record "$target_state" "$seq" busy "semantic state=$activity_state"
    printf 'deferred: busy semantic state=%s seq=%s\n' "$activity_state" "$seq"
    return 3
  fi
  probe=${FM_STOW_TARGET_PROBE_BIN:-}
  if [ -n "$probe" ]; then
    if ! "$probe" "$backend" "$target"; then
      failure_record "$target_state" "$seq" dead "target endpoint is not live"
      printf 'deferred: dead target endpoint\n'
      return 3
    fi
  elif ! default_probe "$backend" "$target"; then
    failure_record "$target_state" "$seq" dead "target endpoint is not live"
    printf 'deferred: dead target endpoint\n'
    return 3
  fi
  send_bin=${FM_STOW_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
  if ! FM_HOME="$sender_home" "$send_bin" --stow-submission-identity-capability >/dev/null 2>&1; then
    failure_record "$target_state" "$seq" unsupported "external sender lacks identity-bound stow submission lifecycle proof"
    printf 'deferred: unsupported external sender cannot bind stow submission identity\n'
    return 3
  fi
  lock_acquire "$target_state" || die "could not lock stow cadence state"
  if ! activity_record_valid "$activity"; then
    lock_release
    failure_record "$target_state" unknown unavailable "semantic activity changed before claim"
    printf 'deferred: unavailable semantic activity changed before claim\n'
    return 3
  fi
  seq=$(record_value "$activity" seq)
  activity_state=$(record_value "$activity" state)
  activity_harness=$(record_value "$activity" harness)
  if [ "$activity_state" != idle ] || [ "$activity_harness" != "$harness" ]; then
    lock_release
    failure_record "$target_state" "$seq" busy "semantic activity changed before claim"
    printf 'deferred: busy semantic activity changed before claim\n'
    return 3
  fi
  if ! endpoint_authorized_for_home "$activity" "$backend" "$target" "$harness"; then
    lock_release
    printf 'blocked: target endpoint changed before the activity generation was claimed\n' >&2
    return 4
  fi
  success_seq=$(latest_success_seq "$target_state")
  if [ "$success_seq" -ge "$seq" ]; then
    lock_release
    printf 'unchanged: no new activity since successful receipt seq=%s\n' "$success_seq"
    return 0
  fi
  for active_due in "$target_state/stow-cadence/due"/*.receipt; do
    [ -f "$active_due" ] || continue
    active_status=$(record_value "$active_due" status)
    case "$active_status" in sent|sending|observed|failed-observed|started) ;; *) continue ;; esac
    active_seq=$(record_value "$active_due" seq)
    lock_release
    printf 'deferred: unavailable receipt still pending for seq=%s\n' "$active_seq"
    return 3
  done
  retire_older_due "$target_state" "$seq"
  due="$target_state/stow-cadence/due/s${seq}.receipt"
  if [ ! -e "$due" ]; then
    shared=$(shared_snapshot "$target_home") || {
      lock_release
      failure_record "$target_state" "$seq" shared-memory-unsafe "captain-shared is not a safe read-only file"
      printf 'deferred: unavailable primary-owned captain-shared input is unsafe\n'
      return 3
    }
    shared_sha=${shared%%|*}
    shared_mode=${shared#*|}
    publish_record_once "$due" "$(due_content "$seq" pending "$harness" "$backend" "$target" "$shared_sha" "$shared_mode")"
  fi
  case "$(record_value "$due" status)" in
    sent|sending|observed|failed-observed|started)
      lock_release
      printf 'deferred: unavailable receipt still pending for seq=%s\n' "$seq"
      return 3
      ;;
  esac
  publish_record "$due" "$(due_content "$seq" sending "$harness" "$backend" "$target" \
    "$(record_value "$due" shared_sha256)" "$(record_value "$due" shared_mode)" \
    "$(record_value "$due" active_seq)")"
  lock_release
  send_out=$(FM_HOME="$sender_home" "$send_bin" "$target" "$invocation" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$send_out" | grep -Eiq 'permission|denied|refus'; then
      failure_class=permission-refused
      failure_message='deferred: permission-refused by external sender'
    else
      failure_class=unavailable
      failure_message='deferred: unavailable external sender failed'
    fi
    lock_acquire "$target_state" || die "could not lock stow cadence state"
    failure_record "$target_state" "$seq" "$failure_class" "$send_out"
    if [ -f "$due" ]; then
      case "$(record_value "$due" status)" in
        observed)
          publish_record "$due" "$(due_content "$seq" failed-observed "$harness" "$backend" "$target" \
            "$(record_value "$due" shared_sha256)" "$(record_value "$due" shared_mode)" \
            "$(record_value "$due" active_seq)")"
          ;;
        sending) rm -f -- "$due" ;;
      esac
    fi
    lock_release
    printf '%s\n' "$failure_message"
    return 3
  fi
  success="$target_state/stow-cadence/success/s${seq}.receipt"
  lock_acquire "$target_state" || die "could not lock stow cadence state"
  if [ ! -f "$success" ] && [ -f "$due" ]; then
    case "$(record_value "$due" status)" in
      observed)
        publish_record "$due" "$(due_content "$seq" started "$harness" "$backend" "$target" \
          "$(record_value "$due" shared_sha256)" "$(record_value "$due" shared_mode)" \
          "$(record_value "$due" active_seq)")"
        ;;
      sending)
        publish_record "$due" "$(due_content "$seq" sent "$harness" "$backend" "$target" \
          "$(record_value "$due" shared_sha256)" "$(record_value "$due" shared_mode)" \
          "$(record_value "$due" active_seq)")"
        ;;
    esac
  fi
  lock_release
  end=$((SECONDS + wait_seconds))
  while [ ! -f "$success" ] && [ "$SECONDS" -lt "$end" ]; do sleep 0.1; done
  if [ -f "$success" ]; then
    printf 'success: receipt=%s activity_seq=%s\n' "${success##*/}" "$(record_value "$success" activity_seq)"
    return 0
  fi
  timeout_recheck=${FM_STOW_TIMEOUT_RECHECK_BIN:-}
  [ -z "$timeout_recheck" ] || "$timeout_recheck"
  lock_acquire "$target_state" || die "could not lock stow cadence state"
  if [ -f "$success" ]; then
    lock_release
    printf 'success: receipt=%s activity_seq=%s\n' "${success##*/}" "$(record_value "$success" activity_seq)"
    return 0
  fi
  failure_record "$target_state" "$seq" receipt-timeout "no completion receipt within ${wait_seconds}s"
  lock_release
  printf 'deferred: unavailable /stow receipt timed out for seq=%s\n' "$seq"
  return 3
}

complete_cmd() {
  local home state due_count=0 due='' seq shared_sha shared_mode shared_file current_sha current_mode
  local activity activity_seq active_seq success content
  [ "$#" -eq 0 ] || usage
  home=$(canonical_dir "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") \
    || die "FM_HOME must name the target home"
  primary_home_required "$home" || exit 0
  state="$home/state"
  ensure_private_tree "$state"
  lock_acquire "$state" || die "could not lock stow cadence state"
  for activity in "$state/stow-cadence/due"/*.receipt; do
    [ -f "$activity" ] || continue
    due=$activity
    due_count=$((due_count + 1))
  done
  if [ "$due_count" -eq 0 ]; then
    lock_release
    printf 'no-due: manual stow has no cadence receipt to record\n'
    return 0
  fi
  if [ "$due_count" -ne 1 ]; then
    lock_release
    die "multiple active stow due receipts require reconciliation"
  fi
  seq=$(record_value "$due" seq)
  uint_valid "$seq" || { lock_release; die "malformed stow due receipt"; }
  success="$state/stow-cadence/success/s${seq}.receipt"
  if [ -f "$success" ]; then
    rm -f -- "$due"
    lock_release
    printf 'success: receipt=%s already recorded\n' "${success##*/}"
    return 0
  fi
  shared_sha=$(record_value "$due" shared_sha256)
  shared_mode=$(record_value "$due" shared_mode)
  if [ "$shared_sha" != not-applicable ]; then
    shared_file="$home/data/captain-shared.md"
    if [ "$shared_sha" = absent ]; then
      if [ -e "$shared_file" ]; then
        failure_record "$state" "$seq" shared-memory-mutated "captain-shared appeared during stow"
        lock_release
        return 1
      fi
    elif [ ! -f "$shared_file" ] || [ -L "$shared_file" ]; then
      failure_record "$state" "$seq" shared-memory-mutated "captain-shared disappeared or became unsafe"
      lock_release
      return 1
    else
      current_sha=$(file_sha256 "$shared_file" 2>/dev/null || true)
      current_mode=$(file_mode "$shared_file" 2>/dev/null || true)
      if [ "$current_sha" != "$shared_sha" ] || [ "$current_mode" != "$shared_mode" ]; then
        failure_record "$state" "$seq" shared-memory-mutated "captain-shared bytes or mode changed during stow"
        lock_release
        return 1
      fi
    fi
  fi
  activity="$state/stow-cadence/activity.receipt"
  activity_record_valid "$activity" || { lock_release; die "semantic activity missing at stow completion"; }
  activity_seq=$(record_value "$activity" seq)
  active_seq=$(record_value "$due" active_seq)
  [ "$(record_value "$due" status)" = started ] || active_seq=invalid
  if ! uint_valid "$active_seq" \
    || [ "$active_seq" -ne $((seq + 1)) ]; then
    failure_record "$state" "$seq" unavailable "stow invocation lifecycle was not proven"
    lock_release
    return 1
  fi
  if [ "$activity_seq" -ne "$active_seq" ]; then
    failure_record "$state" "$seq" superseded "semantic activity advanced during stow"
    rm -f -- "$due"
    lock_release
    return 1
  fi
  content=$(printf 'schema=fm-stow-success.v1\ndue_seq=%s\nactivity_seq=%s\nharness=%s\nts=%s\n' \
    "$seq" "$active_seq" "$(record_value "$due" harness)" "$(now_epoch)")
  publish_record_once "$success" "$content"
  rm -f -- "$due"
  lock_release
  printf 'success: receipt=%s activity_seq=%s\n' "${success##*/}" "$activity_seq"
}

case "${1:-}" in
  activity) shift; activity_cmd "$@" ;;
  complete) shift; complete_cmd "$@" ;;
  run) shift; run_cmd "$@" ;;
  *) usage ;;
esac
