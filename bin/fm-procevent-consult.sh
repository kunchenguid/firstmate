#!/usr/bin/env bash
# Consultation adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-consult.sh arm <consult-id>
#   fm-procevent-consult.sh wait <consult-id>
#   fm-procevent-consult.sh handle <consult-id> <sequence> <captured-result-file>
#   fm-procevent-consult.sh source-id <consult-id>
#   fm-procevent-consult.sh classify <captured-result-file>
#   fm-procevent-consult.sh terminal <captured-result-file>
#
# `arm` registers the wait for one already-submitted known job.
# `wait` is executed only by bin/fm-procevent.sh's background runner and may
# block. It captures raw pro-cli wait output privately, then emits a bounded
# completion envelope containing no advisory text. `handle` fetches the stored
# result through fm-consult.sh, validates its job id, records the advisory, and
# acknowledges exactly that source generation only after the receipt is durable.
# No command here submits a prompt, retries a job, reads ~/.pro-cli credentials,
# or runs a blocking wait in a conversational turn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

consult_id_valid() {
  case "${1-}" in ????????-????-????-????-????????????) ;; *) return 1 ;; esac
  case "${1//-/}" in *[!0-9a-f]*) return 1 ;; esac
}

source_id() { "$SCRIPT_DIR/fm-consult.sh" source-id "$1"; }

private_mode() {
  local actual
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  actual=$(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null) || return 1
  [ "$actual" = 600 ]
}

json_error_code() {
  perl -MJSON::PP -e '
    my $v = eval { decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }) };
    if (ref($v) eq "HASH" && ref($v->{error}) eq "HASH" && defined($v->{error}{code}) && $v->{error}{code} =~ /^[A-Z0-9_]+$/) {
      print "$v->{error}{code}\n";
    }
  ' "$1"
}

json_wait_timed_out() {
  perl -MJSON::PP -e '
    my $v = eval { decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }) };
    exit 1 unless ref($v) eq "HASH" && ref($v->{ok}) eq "JSON::PP::Boolean" && $v->{ok};
    exit 1 unless ref($v->{data}) eq "HASH" && ref($v->{data}{wait}) eq "HASH";
    exit 1 unless ref($v->{data}{wait}{timedOut}) eq "JSON::PP::Boolean" && $v->{data}{wait}{timedOut};
  ' "$1"
}

json_wait_job_status() {  # <file>; prints one known job status
  perl -MJSON::PP -e '
    my $v = eval { decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }) };
    exit 1 unless ref($v) eq "HASH" && ref($v->{ok}) eq "JSON::PP::Boolean" && $v->{ok};
    exit 1 unless ref($v->{data}) eq "HASH" && ref($v->{data}{job}) eq "HASH";
    my $status = $v->{data}{job}{status};
    exit 1 unless defined($status) && !ref($status) && $status =~ /^(?:queued|running|succeeded|failed|cancelled)$/;
    print "$status\n";
  ' "$1"
}

json_string() { perl -MJSON::PP -e 'print JSON::PP->new->encode($ARGV[0])' "$1"; }

wait_timeout_ms() {
  local value=${FM_CONSULT_WAIT_TIMEOUT_MS:-1800000}
  case "$value" in ''|*[!0-9]*) die "FM_CONSULT_WAIT_TIMEOUT_MS must be a positive whole number" ;; esac
  [ "$value" -gt 0 ] || die "FM_CONSULT_WAIT_TIMEOUT_MS must be a positive whole number"
  printf '%s\n' "$value"
}

cmd_arm() {
  local id=${1-} source job registration
  [ "$#" -eq 1 ] || usage
  consult_id_valid "$id" || die "invalid consult id"
  job=$("$SCRIPT_DIR/fm-consult.sh" job-id "$id") || exit 1
  if ! "$SCRIPT_DIR/fm-consult.sh" wait-needed "$id"; then
    printf 'not-armed: %s (already captured or finished)\n' "$id"
    return 0
  fi
  case "$job" in job_[A-Za-z0-9_-]*) ;; *) die "consult has an invalid known job id" ;; esac
  source=$(source_id "$id") || exit 1
  registration="$FM_HOME/state/procevent/$source.source"
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    if ! [ -f "$registration" ] || [ -L "$registration" ] || ! private_mode "$registration"; then
      die "existing consultation wait registration is unsafe"
    fi
    printf 'already-armed: %s\n' "$id"
    return 0
  fi
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" register-if-absent consult "$source" \
    -- "$SCRIPT_DIR/fm-procevent-consult.sh" wait "$id" || exit 1
  printf 'armed: %s\n' "$id"
}

cmd_wait() {
  local id=${1-} job raw rc timed_out=false code='' state_dir job_status='' job_status_json=null
  [ "$#" -eq 1 ] || usage
  consult_id_valid "$id" || die "invalid consult id"
  job=$("$SCRIPT_DIR/fm-consult.sh" job-id "$id") || exit 1
  state_dir="$FM_HOME/state"
  (umask 077; mkdir -p "$state_dir") || die "cannot prepare private wait staging"
  raw=$(umask 077; mktemp "$state_dir/.consult-wait.XXXXXX") || die "cannot stage pro-cli wait output"
  chmod 0600 "$raw" || { rm -f -- "$raw"; die "cannot secure pro-cli wait staging"; }
  pro-cli job wait "$job" --soft-timeout "$(wait_timeout_ms)" --json > "$raw" 2>&1
  rc=$?
  chmod 0600 "$raw" || { rm -f -- "$raw"; die "cannot secure pro-cli wait capture"; }
  if [ "$rc" -eq 0 ] && json_wait_timed_out "$raw"; then
    timed_out=true
  fi
  job_status=$(json_wait_job_status "$raw" 2>/dev/null || true)
  [ -z "$job_status" ] || job_status_json=$(json_string "$job_status")
  code=$(json_error_code "$raw" 2>/dev/null || true)
  rm -f -- "$raw"
  printf '{"schema":"fm-consult-wait/1","consult_id":%s,"job_id":%s,"wait_exit":%s,"wait_timed_out":%s,"job_status":%s,"error_code":%s}\n' \
    "$(json_string "$id")" "$(json_string "$job")" "$rc" "$timed_out" "$job_status_json" "$( [ -n "$code" ] && json_string "$code" || printf null )"
  # The runner's captured envelope is the completion notification. It is never
  # the raw pro-cli answer, and a nonzero known-job wait is still a result for
  # the handler to reconcile through local status/result commands.
  return 0
}

event_valid() {
  perl -MJSON::PP -e '
    my $v = eval { decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }) };
    exit 1 unless ref($v) eq "HASH" && ($v->{schema} // "") eq "fm-consult-wait/1";
    exit 1 unless ($v->{consult_id} // "") =~ /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
    exit 1 unless ($v->{job_id} // "") =~ /^job_[A-Za-z0-9_-]{1,128}$/;
    exit 1 unless defined($v->{wait_exit}) && !ref($v->{wait_exit}) && $v->{wait_exit} =~ /^-?[0-9]+$/;
    exit 1 unless ref($v->{wait_timed_out}) eq "JSON::PP::Boolean";
    exit 1 unless !defined($v->{job_status}) || (!ref($v->{job_status}) && $v->{job_status} =~ /^(?:queued|running|succeeded|failed|cancelled)$/);
    exit 1 unless !defined($v->{error_code}) || (!ref($v->{error_code}) && $v->{error_code} =~ /^[A-Z0-9_]+$/);
  ' "$1"
}

event_is_terminal() {  # <file>
  perl -MJSON::PP -e '
    my $v = eval { decode_json(do { local $/; open my $fh, "<", $ARGV[0] or die; <$fh> }) };
    exit 1 unless ref($v) eq "HASH" && ($v->{schema} // "") eq "fm-consult-wait/1";
    exit 1 unless ref($v->{wait_timed_out}) eq "JSON::PP::Boolean";
    exit 1 unless defined($v->{wait_exit}) && !ref($v->{wait_exit}) && $v->{wait_exit} =~ /^0$/;
    exit 0 if $v->{wait_timed_out};
    exit 0 if defined($v->{job_status}) && !ref($v->{job_status}) && $v->{job_status} =~ /^(?:succeeded|failed|cancelled)$/;
    exit 1;
  ' "$1"
}

cmd_classify() {
  local file=${1-}
  if [ "$#" -ne 1 ] || ! private_mode "$file" || ! event_valid "$file"; then
    die "invalid consultation completion envelope"
  fi
  printf 'completed\n'
}

cmd_terminal() {
  local file=${1-}
  [ "$#" -eq 1 ] && private_mode "$file" && event_valid "$file" || return 1
  event_is_terminal "$file"
}

cmd_handle() {
  local id=${1-} seq=${2-} file=${3-} source
  [ "$#" -eq 3 ] || usage
  consult_id_valid "$id" || die "invalid consult id"
  case "$seq" in ''|*[!0-9]*) die "invalid process-event sequence" ;; esac
  source=$(source_id "$id") || exit 1
  "$SCRIPT_DIR/fm-consult.sh" collect "$id" "$file" || exit 1
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" handled "$source" "$seq"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  wait) shift; cmd_wait "$@" ;;
  handle) shift; cmd_handle "$@" ;;
  source-id) shift; source_id "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  silent|answers|autohandle|self-announcing) exit 2 ;;
  *) usage ;;
esac
