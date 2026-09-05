#!/usr/bin/env bash
# Periodic-check adapter for the generic process-to-event runner: register a
# standing check once, let the runner's blocking child re-run it on a fixed
# cadence, and wake firstmate ONLY when a run reports something worth reading.
#
# Usage:
#   fm-procevent-periodic.sh arm <name> [options] -- <argv>...
#   fm-procevent-periodic.sh classify <result-file>
#   fm-procevent-periodic.sh silent <result-file>
#   fm-procevent-periodic.sh source-id <name>
#   fm-procevent-periodic.sh due <name>
#   fm-procevent-periodic.sh retire <name>
#   fm-procevent-periodic.sh run <source-id>
#
# arm        Bind a standing check as process-event source "periodic-<name>".
#            The spec is written privately under state/periodic/ and hash-bound
#            by a trust record the same way fm-check-register.sh binds a custom
#            check, and the spec separately binds the resolved check
#            executable's bytes. A mutated spec or a changed executable is
#            refused before anything runs. The argv is executed directly with no
#            shell, so nothing is re-split or interpreted.
#            Options, before --:
#              --interval <secs>   seconds between the START of consecutive runs
#                                  (default 86400, one day)
#              --timeout <secs>    bound on one run of the check (default 900)
#              --first <now|wait>  run immediately on arming (default) or wait a
#                                  full interval before the first run
#            POLICY, not enforceable here: the check must be READ-ONLY and safe
#            to run unattended on every cadence, because nothing gates it and
#            its result is captured without judgment. Anything that changes
#            state belongs on the condition->action path (fm-procevent-when.sh)
#            or the ordinary wake-and-decide flow.
#            The registered runner starts on the watcher's next cycle via
#            `fm-procevent.sh reconcile`; arm never runs the check itself.
# classify   Print the captured outcome class a handler should act on:
#            report, clean, timeout, rejected, or unknown. A `clean` result is
#            never announced, so a handler sees it only by reading the inbox
#            directly.
# silent     Exit 0 only for a proved-clean run, which the generic runner then
#            records as handled and never announces. Every other outcome, and
#            any result this cannot read, announces.
# source-id  Print the canonical source id for <name>.
# due        Print the epoch second the next run is scheduled for, or "now".
# retire     Stop the periodic check: retire the registration and remove the
#            spec, trust record, and schedule marker. Idempotent. Captured
#            results and their handled acknowledgements are never touched.
# run        The blocking child the generic runner executes; never run it in a
#            conversational turn. It sleeps until the durable next-due time,
#            runs the check once bounded by its timeout, records the following
#            due time BEFORE emitting, and writes exactly one outcome document
#            on stdout for durable capture. It then exits so the runner's own
#            ordinary reconcile restarts it for the next cycle: the cadence
#            therefore survives a watcher restart, a reboot, and a crash without
#            this adapter owning any timer of its own.
#
# REPORT-WORTHY CONVENTION, and why exit status rather than output.
# A run is report-worthy when the check exits NONZERO. A zero exit is clean and
# never wakes anyone, whatever it printed.
# Output is deliberately not the signal: the runner already captures stdout as
# the EVIDENCE a handler reads, and a useful check prints progress, headers, and
# per-item results on its clean path too - the interim MealTalk sweep this
# adapter replaces printed a banner and two section headers on every run,
# including a completely clean one. Making emptiness the signal would wake
# firstmate on every cadence for those checks and would push authors toward
# silencing exactly the context that makes a real report readable. Exit status
# is instead a single unambiguous bit the check states on purpose, it is the
# convention every shell check already follows, and it leaves stdout free to
# carry the evidence on both paths.
# A check that has no meaningful exit status can still say "report this" by
# exiting 1 deliberately; a check that cannot decide should exit nonzero, since
# an uncertain run must reach a human rather than be silently dropped.
# Exit 124 is reserved for "the timeout bound was hit", matching GNU timeout's
# convention; a check must not use 124 itself to mean "report this", the same
# constraint any script run under `timeout` already has.
#
# Outcome document (the captured result named by the wake):
#   periodic: <source-id>
#   status: report|clean|timeout|rejected
#   detail: <one line>
#   check_exit: <code>         (report and clean only)
#   ran_at: <epoch second>
#   next_due: <epoch second>
#   output:
#   <bounded tail of the check's combined output>
#
# Ownership, durable capture, publication, restart recovery, and the handled
# acknowledgement all belong to bin/fm-procevent.sh; this adapter owns only the
# cadence and report-worthiness semantics above.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

PERIODIC_DIR="$STATE/periodic"
OUTPUT_TAIL_BYTES=${FM_PERIODIC_OUTPUT_TAIL_BYTES:-8192}
# Bound on one sleep, so a long cadence wakes to re-read its schedule instead of
# holding one uninterruptible sleep for a whole day.
SLEEP_SLICE=${FM_PERIODIC_SLEEP_SLICE:-60}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,85p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

spec_file()  { printf '%s/%s.spec\n' "$PERIODIC_DIR" "$1"; }
trust_file() { printf '%s/%s.trust\n' "$PERIODIC_DIR" "$1"; }
due_file()   { printf '%s/%s.due\n' "$PERIODIC_DIR" "$1"; }

periodic_name_valid() {
  local name=${1-}
  fm_task_id_path_safe "$name" || return 1
  fm_procevent_source_id_valid "periodic-$name"
}

cmd_source_id() {
  local name=${1-}
  periodic_name_valid "$name" || die "name must be path-safe and at most 55 characters: ${name-}"
  printf 'periodic-%s\n' "$name"
}

positive_int() { case "${1-}" in ''|*[!0-9]*) return 1 ;; 0) return 1 ;; *) return 0 ;; esac }

check_executable() {  # <argv-zero>: print the executable's absolute path
  local command=$1 found dir base
  case "$command" in
    */*) found=$command ;;
    *) found=$(type -P -- "$command") || return 1 ;;
  esac
  dir=${found%/*}
  base=${found##*/}
  [ "$dir" != "$found" ] || dir=.
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  found="$dir/$base"
  [ -f "$found" ] && [ -x "$found" ] || return 1
  printf '%s\n' "$found"
}

# --- durable schedule --------------------------------------------------------

# The next-due epoch second is durable state, not a runtime variable, so a
# restart resumes the existing cadence instead of restarting it. Written with a
# temp-and-rename so a crash mid-write cannot leave a half-parsed schedule.
write_due() {  # <source-id> <epoch>
  local sid=$1 when=$2 tmp
  tmp=$(umask 077; mktemp "$PERIODIC_DIR/.due.XXXXXX") || return 1
  printf 'fm-periodic-due-v1\n%s\n' "$when" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$(due_file "$sid")" || { rm -f -- "$tmp"; return 1; }
}

# write_due_retrying <source-id> <epoch>: retry a transient write_due failure a
# few times with a short backoff before giving up. `run` is a long-blocking
# child, not a conversational turn, so it can afford to wait here. Without
# this, a single transient write failure (e.g. momentary disk pressure) would
# leave the due marker stuck in the past: the runner's own reconcile restarts
# this non-terminal source on its very next cycle (as often as every
# FM_POLL, ~15s by default), which re-hits the same write and re-announces a
# refusal every cycle instead of once. Retrying here lets a transient failure
# clear within one run instead of turning into a repeat-wake storm; a
# genuinely persistent failure (e.g. disk full or PERIODIC_DIR gone) still
# exhausts the retries and is announced exactly as before.
WRITE_DUE_RETRIES=${FM_PERIODIC_WRITE_DUE_RETRIES:-5}
WRITE_DUE_RETRY_DELAY=${FM_PERIODIC_WRITE_DUE_RETRY_DELAY:-1}
write_due_retrying() {  # <source-id> <epoch>
  local sid=$1 when=$2 tries=0
  while :; do
    write_due "$sid" "$when" && return 0
    tries=$((tries + 1))
    [ "$tries" -lt "$WRITE_DUE_RETRIES" ] || return 1
    sleep "$WRITE_DUE_RETRY_DELAY"
  done
}

# Print the recorded next-due epoch second, or fail when there is none to read.
# A malformed or unreadable marker is not treated as "due now": it fails, and
# the caller re-establishes a schedule, so corrupt state cannot become a hot
# loop that runs the check continuously.
read_due() {  # <source-id>
  local sid=$1 version when extra
  local file; file=$(due_file "$sid")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  {
    IFS= read -r version && IFS= read -r when && ! IFS= read -r extra
  } < "$file" || return 1
  [ "$version" = fm-periodic-due-v1 ] || return 1
  case "$when" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$when"
}

cmd_due() {
  local name=${1-} sid when now
  periodic_name_valid "$name" || die "name must be path-safe and at most 55 characters: ${name-}"
  sid="periodic-$name"
  when=$(read_due "$sid") || die "no schedule is recorded for: $sid"
  now=$(date +%s)
  if [ "$when" -le "$now" ]; then
    printf 'now\n'
  else
    printf '%s\n' "$when"
  fi
}

# --- arm ---------------------------------------------------------------------

cmd_arm() {
  local name=${1-} sid interval=86400 timeout=900 first=now
  local -a argv=()
  [ -n "$name" ] || usage
  shift
  periodic_name_valid "$name" || die "name must be path-safe and at most 55 characters: $name"
  sid="periodic-$name"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) positive_int "${2-}" || die "--interval needs a positive integer of seconds"; interval=$2; shift 2 ;;
      --timeout)  positive_int "${2-}" || die "--timeout needs a positive integer of seconds"; timeout=$2; shift 2 ;;
      --first)
        case "${2-}" in
          now|wait) first=$2 ;;
          *) die "--first needs now or wait" ;;
        esac
        shift 2 ;;
      --) shift; while [ "$#" -gt 0 ]; do argv+=("$1"); shift; done ;;
      *) die "unknown arm argument: $1" ;;
    esac
  done
  [ "${#argv[@]}" -ge 1 ] || die "arm needs at least one argv element after --"
  [ "$timeout" -lt "$interval" ] \
    || die "--timeout ($timeout) must be shorter than --interval ($interval) so one run cannot outlast its own cadence"
  local arg
  for arg in "${argv[@]}"; do
    case "$arg" in *$'\n'*) die "argv elements cannot contain newlines" ;; esac
  done

  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  fm_procevent_source_lock_acquire "$sid" || die "cannot lock the periodic source"
  trap 'fm_procevent_source_lock_release "$sid"' EXIT
  local leftover
  for leftover in "$(spec_file "$sid")" "$(trust_file "$sid")" "$(due_file "$sid")" \
    "$(fm_procevent_registry_dir "$STATE")/$sid.source"; do
    if [ -e "$leftover" ] || [ -L "$leftover" ]; then
      die "periodic check already exists or left state behind: $leftover (retire it first)"
    fi
  done
  local pending
  pending=$(fm_procevent_pending "$STATE" | grep -c "/$sid\." || true)
  [ "$pending" -eq 0 ] || die "an unhandled captured result exists for $sid; handle it before re-arming"

  (umask 077; mkdir -p "$PERIODIC_DIR") || die "cannot create the periodic directory"
  [ -d "$PERIODIC_DIR" ] && [ ! -L "$PERIODIC_DIR" ] || die "periodic directory is unavailable"
  local tmp trust_tmp hash device check_path check_hash now due
  check_path=$(check_executable "${argv[0]}") || die "check executable is unavailable: ${argv[0]}"
  check_hash=$(fm_pr_sha256 "$check_path") || die "cannot hash the check executable"
  argv[0]=$check_path
  device=$(fm_pr_file_device "$PERIODIC_DIR") || die "cannot inspect the periodic directory"
  now=$(date +%s)
  tmp=$(umask 077; mktemp "$PERIODIC_DIR/.spec.XXXXXX") || die "cannot stage the spec"
  {
    printf 'fm-periodic-spec-v1\n'
    printf 'armed=%s\n' "$now"
    printf 'interval=%s\n' "$interval"
    printf 'timeout=%s\n' "$timeout"
    printf 'check_sha256=%s\n' "$check_hash"
    printf 'argc=%s\n' "${#argv[@]}"
    printf 'argv:\n'
    printf '%s\n' "${argv[@]}"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write the spec"; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the spec"; }
  hash=$(fm_pr_sha256 "$tmp") || { rm -f -- "$tmp"; die "cannot hash the spec"; }
  trust_tmp=$(umask 077; mktemp "$PERIODIC_DIR/.trust.XXXXXX") || { rm -f -- "$tmp"; die "cannot stage the trust record"; }
  printf 'fm-periodic-trust-v1\n%s\n' "$hash" > "$trust_tmp" || { rm -f -- "$tmp" "$trust_tmp"; die "cannot write the trust record"; }
  chmod 0600 "$trust_tmp" || { rm -f -- "$tmp" "$trust_tmp"; die "cannot secure the trust record"; }
  mv -f -- "$tmp" "$(spec_file "$sid")" || { rm -f -- "$tmp" "$trust_tmp"; die "cannot publish the spec"; }
  mv -f -- "$trust_tmp" "$(trust_file "$sid")" || { rm -f -- "$(spec_file "$sid")" "$trust_tmp"; die "cannot publish the trust record"; }
  if ! fm_pr_private_file_valid "$(spec_file "$sid")" 600 "$device" \
    || ! fm_pr_private_file_valid "$(trust_file "$sid")" 600 "$device"; then
    rm -f -- "$(spec_file "$sid")" "$(trust_file "$sid")"
    die "published spec failed validation"
  fi

  due=$now
  [ "$first" = wait ] && due=$(( now + interval ))
  if ! write_due "$sid" "$due"; then
    rm -f -- "$(spec_file "$sid")" "$(trust_file "$sid")"
    die "cannot record the first due time"
  fi

  if ! fm_procevent_registration_publish_locked "$STATE" periodic "$sid" \
    "$SCRIPT_DIR/fm-procevent-periodic.sh" run "$sid"; then
    rm -f -- "$(spec_file "$sid")" "$(trust_file "$sid")" "$(due_file "$sid")"
    die "cannot register the periodic source"
  fi
  fm_procevent_source_lock_release "$sid"
  trap - EXIT
  printf 'armed: %s (every %ss)\n' "$sid" "$interval"
  printf 'starts on the watcher'"'"'s next cycle; or run: bin/fm-procevent.sh reconcile\n'
  printf 'reminder: read-only unattended checks only; a nonzero exit is what wakes firstmate\n'
}

# --- spec load ---------------------------------------------------------------

# spec_load <source-id>: validate the trust binding, then parse the spec into
# SPEC_* variables plus CHECK_ARGV. Any structural or trust failure returns 1
# with a reason in SPEC_ERROR; nothing from the spec is executed.
spec_load() {
  local sid=$1 spec trust device hash want version line key value extra
  SPEC_ERROR=
  CHECK_ARGV=()
  spec=$(spec_file "$sid")
  trust=$(trust_file "$sid")
  [ -d "$PERIODIC_DIR" ] && [ ! -L "$PERIODIC_DIR" ] || { SPEC_ERROR="periodic directory is unavailable"; return 1; }
  device=$(fm_pr_file_device "$PERIODIC_DIR") || { SPEC_ERROR="cannot inspect the periodic directory"; return 1; }
  fm_pr_private_file_valid "$spec" 600 "$device" || { SPEC_ERROR="spec is missing or not private"; return 1; }
  fm_pr_private_file_valid "$trust" 600 "$device" || { SPEC_ERROR="trust record is missing or not private"; return 1; }
  {
    IFS= read -r version && IFS= read -r want && ! IFS= read -r extra
  } < "$trust" || { SPEC_ERROR="trust record is malformed"; return 1; }
  [ "$version" = fm-periodic-trust-v1 ] || { SPEC_ERROR="trust record has an unknown version"; return 1; }
  local LC_ALL=C
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { SPEC_ERROR="trust record hash is malformed"; return 1; }
  hash=$(fm_pr_sha256 "$spec") || { SPEC_ERROR="cannot hash the spec"; return 1; }
  [ "$hash" = "$want" ] || { SPEC_ERROR="spec does not match its registered trust binding"; return 1; }

  SPEC_ARMED='' SPEC_INTERVAL='' SPEC_TIMEOUT='' SPEC_CHECK_SHA256=''
  local argc='' in_argv=0 read_argv=0
  {
    IFS= read -r version || { SPEC_ERROR="spec is empty"; return 1; }
    [ "$version" = fm-periodic-spec-v1 ] || { SPEC_ERROR="spec has an unknown version"; return 1; }
    while IFS= read -r line; do
      if [ "$in_argv" -eq 0 ]; then
        if [ "$line" = "argv:" ]; then in_argv=1; continue; fi
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
          armed)        SPEC_ARMED=$value ;;
          interval)     SPEC_INTERVAL=$value ;;
          timeout)      SPEC_TIMEOUT=$value ;;
          check_sha256) SPEC_CHECK_SHA256=$value ;;
          argc)         argc=$value ;;
          *) SPEC_ERROR="spec carries an unknown field: $key"; return 1 ;;
        esac
      elif [ "$read_argv" -lt "${argc:-0}" ]; then
        CHECK_ARGV+=("$line")
        read_argv=$((read_argv + 1))
      else
        SPEC_ERROR="spec carries trailing content"
        return 1
      fi
    done
  } < "$spec"
  [ -z "$SPEC_ERROR" ] || return 1
  case "$SPEC_ARMED" in ''|*[!0-9]*) SPEC_ERROR="spec armed epoch is malformed"; return 1 ;; esac
  positive_int "$SPEC_INTERVAL" || { SPEC_ERROR="spec interval is malformed"; return 1; }
  positive_int "$SPEC_TIMEOUT" || { SPEC_ERROR="spec timeout is malformed"; return 1; }
  [[ "$SPEC_CHECK_SHA256" =~ ^[0-9a-f]{64}$ ]] \
    || { SPEC_ERROR="spec check hash is malformed"; return 1; }
  positive_int "${argc:-}" || { SPEC_ERROR="spec argc is malformed"; return 1; }
  [ "$read_argv" -eq "$argc" ] || { SPEC_ERROR="spec argv is incomplete"; return 1; }
}

# --- run ---------------------------------------------------------------------

# emit_doc <source-id> <status> <detail> <check-exit-or-empty> <ran-at> <next-due> <output-file-or-empty>
# The single stdout writer of `run`: everything the generic runner captures.
emit_doc() {
  local sid=$1 status=$2 detail=$3 check_exit=$4 ran_at=$5 next_due=$6 outfile=$7
  printf 'periodic: %s\n' "$sid"
  printf 'status: %s\n' "$status"
  printf 'detail: %s\n' "$detail"
  [ -z "$check_exit" ] || printf 'check_exit: %s\n' "$check_exit"
  printf 'ran_at: %s\n' "$ran_at"
  printf 'next_due: %s\n' "$next_due"
  printf 'output:\n'
  if [ -n "$outfile" ] && [ -f "$outfile" ]; then
    tail -c "$OUTPUT_TAIL_BYTES" "$outfile" 2>/dev/null || true
  fi
}

# Sleep until the recorded due time, in bounded slices so a stop signal reaches
# this child promptly and a schedule rewritten by an operator is picked up
# within one slice rather than a whole cadence.
sleep_until_due() {  # <source-id>
  local sid=$1 due now remaining
  while :; do
    due=$(read_due "$sid") || return 1
    now=$(date +%s)
    remaining=$(( due - now ))
    [ "$remaining" -le 0 ] && return 0
    [ "$remaining" -gt "$SLEEP_SLICE" ] && remaining=$SLEEP_SLICE
    sleep "$remaining"
  done
}

cmd_run() {
  local sid=${1-} out rc ran_at next_due
  fm_procevent_source_id_valid "$sid" || die "source id must be path-safe: $sid"

  if ! positive_int "$OUTPUT_TAIL_BYTES"; then
    emit_doc "$sid" rejected "FM_PERIODIC_OUTPUT_TAIL_BYTES must be a positive integer; nothing was executed" '' "$(date +%s)" 0 ''
    exit 0
  fi
  if ! positive_int "$SLEEP_SLICE"; then
    emit_doc "$sid" rejected "FM_PERIODIC_SLEEP_SLICE must be a positive integer; nothing was executed" '' "$(date +%s)" 0 ''
    exit 0
  fi

  if ! spec_load "$sid"; then
    emit_doc "$sid" rejected "refused without executing anything: $SPEC_ERROR" '' "$(date +%s)" 0 ''
    exit 0
  fi

  # A missing or unreadable schedule is re-established rather than treated as
  # due, so corrupt state can never become a continuous re-run of the check.
  if ! read_due "$sid" >/dev/null; then
    if ! write_due_retrying "$sid" "$(( $(date +%s) + SPEC_INTERVAL ))"; then
      emit_doc "$sid" rejected \
        "the schedule is unreadable and cannot be re-established; nothing was executed" '' "$(date +%s)" 0 ''
      exit 0
    fi
  fi

  if ! sleep_until_due "$sid"; then
    emit_doc "$sid" rejected "the schedule became unreadable while waiting; nothing was executed" '' "$(date +%s)" 0 ''
    exit 0
  fi

  # Revalidate the registered check bytes immediately before running them. A
  # changed or unavailable executable must never run.
  local current_hash
  current_hash=$(fm_pr_sha256 "${CHECK_ARGV[0]}") || current_hash=
  if [ "$current_hash" != "$SPEC_CHECK_SHA256" ]; then
    ran_at=$(date +%s)
    next_due=$(( ran_at + SPEC_INTERVAL ))
    if ! write_due_retrying "$sid" "$next_due"; then
      if unregister_self "$sid"; then
        emit_doc "$sid" rejected \
          "refused without running the check: its bytes do not match the registered trust binding, and the next-due time could not be recorded; retired to stop a repeat-wake loop - re-arm to restore the cadence" \
          '' "$ran_at" "$next_due" ''
      else
        emit_doc "$sid" rejected \
          "refused without running the check: its bytes do not match the registered trust binding, and the next-due time could not be recorded; retirement to stop a repeat-wake loop also failed - remove state/periodic/$sid.* by hand" \
          '' "$ran_at" "$next_due" ''
      fi
      exit 0
    fi
    emit_doc "$sid" rejected \
      "refused without running the check: its bytes do not match the registered trust binding" '' "$ran_at" "$next_due" ''
    exit 0
  fi

  if ! out=$(umask 077; mktemp "$PERIODIC_DIR/.run-out.XXXXXX"); then
    emit_doc "$sid" rejected "cannot stage command output; nothing was executed" '' "$(date +%s)" 0 ''
    exit 0
  fi
  trap 'rm -f -- "$out"' EXIT

  ran_at=$(date +%s)
  fm_run_timed "$SPEC_TIMEOUT" "${CHECK_ARGV[@]}" 2>&1 | tail -c "$OUTPUT_TAIL_BYTES" > "$out"
  rc=${PIPESTATUS[0]}

  # The next due time is recorded BEFORE the outcome is emitted, so the cadence
  # advances even if this process dies between here and capture. Without that
  # order a crash in the emit path would leave the schedule in the past and the
  # runner's own restart would re-run the check immediately, turning one cadence
  # into a hot loop. A failure to record it must never be papered over: it is
  # announced as its own refusal instead of letting a normal outcome mask a
  # schedule that is about to go stale and hot-loop on the next reconcile.
  # write_due_retrying already absorbs a transient failure here; only a
  # persistent one reaches this refusal.
  next_due=$(( ran_at + SPEC_INTERVAL ))
  if ! write_due_retrying "$sid" "$next_due"; then
    if unregister_self "$sid"; then
      emit_doc "$sid" rejected \
        "the check ran but its next-due time could not be recorded; retired to stop a repeat-wake loop - re-arm to restore the cadence" \
        "$rc" "$ran_at" "$next_due" "$out"
    else
      emit_doc "$sid" rejected \
        "the check ran but its next-due time could not be recorded; retirement to stop a repeat-wake loop also failed - remove state/periodic/$sid.* by hand" \
        "$rc" "$ran_at" "$next_due" "$out"
    fi
    exit 0
  fi

  case "$rc" in
    # fm_run_timed reproduces GNU timeout's convention: 124 always means the
    # bound was hit, exactly as bin/fm-procevent-when.sh's own bounded_run
    # already treats it. Wall-clock elapsed time cannot reliably disambiguate
    # a real timeout-kill from a check that happens to exit 124 on its own
    # near the deadline (integer-second measurement loses the sub-second
    # margin), so a check must not use exit 124 to signal "report" - the same
    # constraint any script run under `timeout` already has.
    124)
      emit_doc "$sid" timeout \
        "the check did not finish within ${SPEC_TIMEOUT}s and was stopped" '' "$ran_at" "$next_due" "$out"
      ;;
    0)
      emit_doc "$sid" clean "the check exited 0" "$rc" "$ran_at" "$next_due" "$out"
      ;;
    *)
      emit_doc "$sid" report "the check exited $rc and reported something to read" "$rc" "$ran_at" "$next_due" "$out"
      ;;
  esac
  exit 0
}

# --- result classification ---------------------------------------------------

# Read the status field from the document's leading block. The read stops at the
# output: marker, so captured check output can never forge the status.
result_status() {  # <result-file>
  awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$1"
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(result_status "$file")
  case "$status" in
    report|clean|timeout|rejected) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

# Exit 0 only for a run this positively proved clean. A timeout, a refusal, an
# unreadable result, and anything it cannot classify all announce, because an
# uncertain run must reach a handler rather than be silently dropped.
cmd_silent() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  [ "$(cmd_classify "$file")" = clean ]
}

# --- retire ------------------------------------------------------------------

# unregister_self <source-id>: drop the runner registration and the private
# spec, trust, and due state for the source this very process is currently
# running as. Used only by cmd_run's persistent-write-failure paths: a
# next-due write that exhausts its retries can never be advanced, so leaving
# the source registered would have reconcile restart it every cycle against a
# due marker stuck in the past - a repeat-wake storm instead of the single
# announcement the caller already promised. This must NOT shell out to
# `fm-procevent.sh retire`: that command calls stop_runner_pid on the still-
# live claim it finds, which is this process's own runner group - self-
# retiring that way sends SIGTERM to the very check that is still finishing
# up and emitting its own outcome. Dropping the registration directly is
# enough: this process is already on its way to a normal exit, and the
# runner that invoked it releases the claim itself once it does.
# Returns 1 if the registration file could not be confirmed gone, so a caller
# never claims "retired" while reconcile can still find and restart the
# source: that would leave the wake loop it was meant to stop still running.
unregister_self() {  # <source-id>
  local sid=$1 reg_file
  fm_procevent_source_lock_acquire "$sid" || return 1
  reg_file="$(fm_procevent_registry_dir "$STATE")/$sid.source"
  rm -f -- "$reg_file" "$(spec_file "$sid")" "$(trust_file "$sid")" "$(due_file "$sid")"
  fm_procevent_source_lock_release "$sid"
  [ ! -e "$reg_file" ]
}

cmd_retire() {
  local name=${1-} sid
  periodic_name_valid "$name" || die "name must be path-safe and at most 55 characters: ${name-}"
  sid="periodic-$name"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" || die "cannot retire the periodic source: $sid"
  rm -f -- "$(spec_file "$sid")" "$(trust_file "$sid")" "$(due_file "$sid")"
  printf 'retired: %s\n' "$sid"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  run)       shift; [ "$#" -eq 1 ] || usage; cmd_run "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  silent)    shift; cmd_silent "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  due)       shift; cmd_due "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
