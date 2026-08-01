# shellcheck shell=bash
# fm-relay-lib.sh - the control-side client for a Bifrost relay task host.
#
# What this is for: firstmate stays the single control plane on one machine and
# dispatches a task to a REMOTE host machine that runs its own firstmate. The
# cross-machine layer sits at the SCRIPT level, not at bin/fm-backend.sh's
# primitive level: one fleet operation is one verb call, and the verb runs the
# host's OWN bin/fm-spawn.sh, bin/fm-send.sh, bin/fm-crew-state.sh. Every backend
# primitive therefore stays local-to-local on the host and fm-backend.sh is
# untouched. docs/relay-host.md owns the measured latency that makes the
# per-primitive alternative untenable and records the verification evidence.
#
# Two paths cross the relay and only two:
#   1. `bifrost remote exec` of ONE allowlisted verb entry script, with arguments
#      restricted to a character set that contains no shell metacharacter and no
#      slash. fm_relay_arg_valid enforces that locally before the call so a
#      malformed argument fails with a readable message instead of an opaque
#      policy rejection.
#   2. `bifrost remote file` inside ONE exchange directory. Anything that is not
#      a fixed short token - a brief, a steer, a report - travels as a FILE and
#      the verb receives only its short reference. That is what keeps arbitrary
#      captain text out of the shell allowlist.
#
# Host records live in <home>/config/relay-hosts.json (LOCAL, gitignored);
# docs/configuration.md owns that schema.
#
# Streaming caveat, measured 2026-08-01 against bifrost 0.0.167 -> 0.0.165:
# `remote exec --stream` is ~4.7x faster than the buffered form (median 1.07 s vs
# 4.97 s cross-machine), but it REPLACES a policy rejection with exit 1 and
# "stream digest mismatch", losing the real reason. fm_relay_exec therefore
# streams first and, only on failure, repeats the call buffered once to recover
# the authentic error text. A remote command's own non-zero exit code passes
# through the streamed call unchanged, so the retry costs nothing on the paths
# that matter.

FM_RELAY_ARG_RE='^[A-Za-z0-9._@=+-]{1,96}$'
FM_RELAY_REF_RE='^[A-Za-z0-9._-]{1,64}$'
FM_RELAY_ID_RE='^[A-Za-z0-9._-]{1,64}$'

# This file's own directory, so the generated wake check - which carries per-task
# parameters and one library call, nothing else - can reach its sibling scripts
# without the caller putting bin/ on PATH.
FM_RELAY_LIB_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Which machine is the control plane. Sourced here rather than in each caller
# because fm_relay_exec is the ONE funnel every cross-machine call goes through,
# so it is the one place the fencing token can be attached without a caller
# being able to forget. The dependency is one-way: fm-helm-lib.sh knows nothing
# about this file.
#
# A missing sibling STOPS this library rather than being tolerated. Sourcing a
# file that is not there leaves fm_helm_epoch_for_home undefined, every fenced
# verb call then quietly ships no epoch, and on a fleet machine the fence is
# gone with nothing to show for it. Refusing is the only honest answer to
# "half of this layer is installed".
if [ ! -f "$FM_RELAY_LIB_DIR/fm-helm-lib.sh" ]; then
  echo "error: $FM_RELAY_LIB_DIR/fm-helm-lib.sh is missing beside fm-relay-lib.sh; refusing to run a relay call that could not be fenced" >&2
  # `return` when sourced, which is the only supported use; `exit` if someone
  # runs this file directly, where `return` is a syntax error at runtime.
  # shellcheck disable=SC2317  # the exit is the fallback for the direct-run case
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=bin/fm-helm-lib.sh
. "$FM_RELAY_LIB_DIR/fm-helm-lib.sh"

# Set by fm_relay_exec / fm_relay_file_* for the caller to read.
FM_RELAY_OUT=
FM_RELAY_ERR=
FM_RELAY_RC=0

# Set by fm_relay_host_load and read by bin/fm-relay-conn.sh and bin/fm-relay-host.sh.
# shellcheck disable=SC2034  # consumed by this library's callers, not by itself
FM_RELAY_HOST=
FM_RELAY_CLIENT_ID=
FM_RELAY_CONTROL_ROOT=
FM_RELAY_FLEET_ROOT=
FM_RELAY_HOST_HOME=
FM_RELAY_HOST_ROOT=
FM_RELAY_HOST_DIR=
FM_RELAY_HOST_PATH=
FM_RELAY_HOST_LANG=
FM_RELAY_KEY=
FM_RELAY_SSH=
FM_RELAY_VERB=
FM_RELAY_GUI=
FM_RELAY_TMUX_SOCKET=
FM_RELAY_HOST_SESSION=
FM_RELAY_FLEET=

fm_relay_bifrost() {
  printf '%s' "${FM_RELAY_BIFROST:-bifrost}"
}

fm_relay_hosts_file() {  # <home>
  printf '%s/config/relay-hosts.json' "$1"
}

fm_relay_arg_valid() {  # <arg>
  [[ "$1" =~ $FM_RELAY_ARG_RE ]]
}

fm_relay_ref_valid() {  # <ref>
  [[ "$1" =~ $FM_RELAY_REF_RE ]]
}

fm_relay_id_valid() {  # <id>
  [[ "$1" =~ $FM_RELAY_ID_RE ]]
}

# Read one host record into the FM_RELAY_* globals. Every field is required
# except key/ssh, which only the pairing and audit paths need.
fm_relay_host_load() {  # <home> <host-name>
  local home=$1 name=$2 file raw
  FM_RELAY_HOST=; FM_RELAY_CLIENT_ID=; FM_RELAY_CONTROL_ROOT=; FM_RELAY_FLEET_ROOT=
  FM_RELAY_HOST_HOME=; FM_RELAY_HOST_ROOT=; FM_RELAY_HOST_DIR=; FM_RELAY_HOST_PATH=
  FM_RELAY_HOST_LANG=; FM_RELAY_KEY=; FM_RELAY_SSH=; FM_RELAY_VERB=
  FM_RELAY_GUI=; FM_RELAY_TMUX_SOCKET=; FM_RELAY_HOST_SESSION=; FM_RELAY_FLEET=
  fm_relay_arg_valid "$name" || { echo "error: invalid relay host name '$name'" >&2; return 1; }
  file=$(fm_relay_hosts_file "$home")
  [ -f "$file" ] || { echo "error: no relay host registry at $file" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: jq is required to read $file" >&2; return 1; }
  # One field per LINE, not one TSV row. Bash treats tab as IFS whitespace, so a
  # run of tabs collapses into a single separator and one absent optional field
  # (lang, home_dir, path) would silently shift every later field left - which is
  # how the ssh route once became the key path. Line-per-field preserves empties.
  #
  # The trailing "." is a sentinel and is never read. Command substitution strips
  # TRAILING newlines, so a record whose last optional fields are all absent -
  # a laptop host with no ssh route and no key, which is the normal shape - loses
  # those lines entirely and the reads below run off the end of the input. Each
  # failed read returns non-zero, and in a `set -e` caller like
  # bin/fm-relay-conn.sh that killed the whole script with no message at all.
  # A sentinel guarantees the last real field is never the last line.
  raw=$(jq -r --arg n "$name" '
    if (.[$n] // empty) == null then empty
    else .[$n] as $h
      | [ ($h.client_id // ""), ($h.control_root // ""), ($h.fleet_root // ""),
          ($h.home // ""), ($h.root // ""), ($h.home_dir // ""), ($h.path // ""),
          ($h.lang // ""), ($h.key // ""), ($h.ssh // ""),
          (if ($h.gui // false) then "1" else "" end),
          ($h.tmux_socket // ""), ($h.host_session // ""),
          ($h.fleet // ""), "." ]
      | .[]
    end' "$file" 2>/dev/null) || {
    echo "error: $file is not valid JSON" >&2; return 1; }
  [ -n "$raw" ] || { echo "error: relay host '$name' is not registered in $file" >&2; return 1; }
  # shellcheck disable=SC2034  # KEY/SSH are read by bin/fm-relay-conn.sh, not here
  { read -r FM_RELAY_CLIENT_ID; read -r FM_RELAY_CONTROL_ROOT; read -r FM_RELAY_FLEET_ROOT
    read -r FM_RELAY_HOST_HOME; read -r FM_RELAY_HOST_ROOT; read -r FM_RELAY_HOST_DIR
    read -r FM_RELAY_HOST_PATH; read -r FM_RELAY_HOST_LANG; read -r FM_RELAY_KEY
    read -r FM_RELAY_SSH; read -r FM_RELAY_GUI; read -r FM_RELAY_TMUX_SOCKET
    read -r FM_RELAY_HOST_SESSION; read -r FM_RELAY_FLEET
  } <<< "$raw"
  FM_RELAY_HOST=$name
  [ -n "$FM_RELAY_HOST_PATH" ] || FM_RELAY_HOST_PATH=/usr/local/bin:/usr/bin:/bin
  # A UTF-8 locale is load-bearing on the host, not cosmetic; see fmr-verb.sh.
  [ -n "$FM_RELAY_HOST_LANG" ] || FM_RELAY_HOST_LANG=en_US.UTF-8
  [ -n "$FM_RELAY_HOST_DIR" ] || FM_RELAY_HOST_DIR=${FM_RELAY_HOST_HOME%/*}
  for f in FM_RELAY_CLIENT_ID FM_RELAY_CONTROL_ROOT FM_RELAY_FLEET_ROOT FM_RELAY_HOST_HOME FM_RELAY_HOST_ROOT; do
    [ -n "${!f}" ] || { echo "error: relay host '$name' is missing ${f#FM_RELAY_}" >&2; return 1; }
  done
  # Each path on its own: concatenating them only ever checks the first
  # character, so a relative fleet_root would sail through behind an absolute
  # control_root.
  for f in FM_RELAY_CONTROL_ROOT FM_RELAY_FLEET_ROOT FM_RELAY_HOST_HOME FM_RELAY_HOST_ROOT; do
    case "${!f}" in
      /*) ;;
      *) echo "error: relay host '$name' ${f#FM_RELAY_} must be an absolute path" >&2; return 1 ;;
    esac
  done
  [ -n "$FM_RELAY_HOST_SESSION" ] || FM_RELAY_HOST_SESSION="$FM_RELAY_CONTROL_ROOT/host-session"
  FM_RELAY_VERB="$FM_RELAY_CONTROL_ROOT/verbs/fmr-verb.sh"
}

fm_relay_host_is_gui() { [ "$FM_RELAY_GUI" = 1 ]; }

fm_relay_hosts_list() {  # <home>
  local file
  file=$(fm_relay_hosts_file "$1")
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r 'keys[]' "$file" 2>/dev/null || true
}

# The verbs that CHANGE something on the peer, and therefore the verbs that
# carry this machine's helm epoch so the peer can refuse a stale control plane.
# Read-only verbs are deliberately absent: a demoted machine must still be able
# to look at what is running, it just may not touch it.
fm_relay_verb_is_fenced() {  # <verb>
  case "$1" in
    spawn|send|key|ack|teardown) return 0 ;;
  esac
  return 1
}

# Run one verb on the loaded host. Output lands in FM_RELAY_OUT, the exit status
# in FM_RELAY_RC, and any transport/policy diagnosis in FM_RELAY_ERR.
#
# On a home that declared no fleet, fm_helm_epoch_for_home prints nothing and the
# argument list below is byte-identical to the one this function sent before the
# helm layer existed. That is the whole compatibility contract for Phase 1/2
# hosts, and it costs one stat().
fm_relay_exec() {  # <verb> [arg...]
  local timeout=${FM_RELAY_TIMEOUT_MS:-120000} shell_text a out rc epoch
  [ -n "$FM_RELAY_HOST" ] || { echo "error: no relay host loaded" >&2; return 1; }
  shell_text=$FM_RELAY_VERB
  # The epoch rides on the VERB TOKEN as `<verb>@<epoch>`, never as an extra
  # argument. The host's shell policy allowlists this path plus at most EIGHT
  # arguments and `spawn` already uses all eight, so a ninth token would be
  # refused by the policy layer before the verb ran - and widening the allowlist
  # invalidates the grant and forces a re-pair (docs/relay-host.md).
  # With no fleet declared, fm_helm_epoch_for_home prints nothing and the token
  # stays the bare verb, byte-identical to what Phase 1/2 sent.
  if [ "${FM_HELM_NO_FENCE:-0}" != 1 ] && fm_relay_verb_is_fenced "${1:-}"; then
    epoch=$(fm_helm_epoch_for_home "${FM_HOME:-}")
    if [ -n "$epoch" ]; then
      local fenced_verb="$1@$epoch"
      shift
      set -- "$fenced_verb" "$@"
    fi
  fi
  for a in "$@"; do
    fm_relay_arg_valid "$a" || {
      FM_RELAY_ERR="refusing to send an argument outside the verb allowlist charset: $a"
      FM_RELAY_RC=2
      return 2
    }
    shell_text="$shell_text $a"
  done
  FM_RELAY_ERR=
  out=$("$(fm_relay_bifrost)" remote --client-id "$FM_RELAY_CLIENT_ID" exec --stream \
    --timeout-ms "$timeout" --shell-text "$shell_text" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && [ "${out#*stream digest mismatch}" != "$out" ]; then
    # The streamed form hides the authentic reason; ask once more, buffered.
    out=$("$(fm_relay_bifrost)" remote --client-id "$FM_RELAY_CLIENT_ID" exec \
      --timeout-ms "$timeout" --shell-text "$shell_text" 2>&1)
    rc=$?
  fi
  FM_RELAY_OUT=$out
  FM_RELAY_RC=$rc
  [ "$rc" -eq 0 ] || FM_RELAY_ERR=$out
  return "$rc"
}

# Convenience: run a verb and require its first token to be OK, printing the
# remainder. Used by every caller that wants "the answer or a loud failure".
fm_relay_verb_ok() {  # <verb> [arg...]
  local first
  fm_relay_exec "$@" || return "$FM_RELAY_RC"
  first=${FM_RELAY_OUT%%$'\n'*}
  case "$first" in
    # A bare OK header carries no payload of its own, so drop the whole line
    # rather than leaving a blank one at the top of every answer.
    OK) printf '%s\n' "$FM_RELAY_OUT" | sed '1d'; return 0 ;;
    OK\ *) printf '%s\n' "${FM_RELAY_OUT#OK }"; return 0 ;;
  esac
  FM_RELAY_ERR=$FM_RELAY_OUT
  FM_RELAY_RC=1
  return 1
}

fm_relay_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Push a local file into the host's exchange area and verify the remote hash.
# A mismatch is a hard failure: the remote copy is removed and nothing downstream
# is allowed to consume a half-written brief or steer.
fm_relay_put() {  # <local-file> <remote-relative-path>
  local src=$1 rel=$2 dest local_hash remote_hash
  [ -f "$src" ] || { FM_RELAY_ERR="local file not found: $src"; return 1; }
  dest="$FM_RELAY_FLEET_ROOT/$rel"
  local_hash=$(fm_relay_sha256 "$src") || { FM_RELAY_ERR="cannot hash $src"; return 1; }
  FM_RELAY_OUT=$("$(fm_relay_bifrost)" remote --client-id "$FM_RELAY_CLIENT_ID" file write \
    "$dest" --from-local "$src" --create-parents 2>&1) || {
    FM_RELAY_ERR=$FM_RELAY_OUT; return 1; }
  remote_hash=$("$(fm_relay_bifrost)" remote --client-id "$FM_RELAY_CLIENT_ID" file hash \
    "$dest" --algo sha256 2>&1 | awk '/^sha256:/ {print $2}')
  if [ "$remote_hash" != "$local_hash" ]; then
    "$(fm_relay_bifrost)" remote --client-id "$FM_RELAY_CLIENT_ID" file delete "$dest" >/dev/null 2>&1 || true
    FM_RELAY_ERR="hash mismatch after write: local $local_hash remote ${remote_hash:-<none>}"
    return 1
  fi
  return 0
}

# Pull a file out of the host's exchange area and verify it byte for byte.
# Always `file download`, never `file read`: read is silently truncated at
# max_read_bytes while still reporting the FULL size and hash, so a consumer that
# skipped the comparison would keep a corrupt artifact (measured on both ends,
# docs/relay-host.md).
fm_relay_get() {  # <remote-relative-path> <local-file> [expected-sha256]
  local rel=$1 dest=$2 want=${3:-} src got
  src="$FM_RELAY_FLEET_ROOT/$rel"
  rm -f "$dest"
  FM_RELAY_OUT=$("$(fm_relay_bifrost)" remote --client-id "$FM_RELAY_CLIENT_ID" file download \
    "$src" "$dest" 2>&1) || { FM_RELAY_ERR=$FM_RELAY_OUT; return 1; }
  got=$(fm_relay_sha256 "$dest") || { FM_RELAY_ERR="cannot hash $dest"; rm -f "$dest"; return 1; }
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    rm -f "$dest"
    # shellcheck disable=SC2034  # read by the caller that reports the failure
    FM_RELAY_ERR="hash mismatch after download: want $want got $got"
    return 1
  fi
  FM_RELAY_OUT=$got
  return 0
}

# The universal grant assertion. The trap is not "our grant drifted": a second
# `bifrost remote conn up` ADDS a fresh full-access grant and leaves the tightened
# one in the list looking correct, so a per-grant audit passes on a wide-open
# machine. The only sound question is the universal one - does ANY grant bind
# ssh-key-full-access - and it can only be answered on the TARGET, because
# `conn down --all` on the caller revokes just the connection it saved.
fm_relay_audit_grants_text() {  # <grant-list-text>
  local text=$1
  case "$text" in
    *ssh-key-full-access*) return 1 ;;
  esac
  return 0
}

fm_relay_meta_host() {  # <meta-file>
  [ -f "$1" ] || return 1
  grep '^host=' "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- queued dispatch ----------------------------------------------------------
#
# A GUI task host refuses work while its screen is locked, while its desktop host
# session is down, and - by simply not answering - while the machine is asleep.
# Those are all TRANSIENT: the right answer is to hold the dispatch and try
# again, not to lose it and not to pretend it started.
#
# So a refused dispatch leaves a record here and the ordinary wake check retries
# it. Everything needed to dispatch is in the record, which is why the first
# attempt and every retry run the identical code path
# (bin/fm-relay-host.sh dispatch) instead of a second, thinner one that would
# drift.
#
# The queue lives on the CONTROL side deliberately. The host cannot hold it: a
# sleeping machine has no queue, and the whole point is to survive the host being
# unavailable.

fm_relay_pending_file() {  # <state-dir> <id>
  printf '%s/%s.relay-pending' "$1" "$2"
}

fm_relay_pending_field() {  # <pending-file> <key>
  [ -f "$1" ] || return 1
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Record WHY the host would not take this work, in the host's own words.
#
# It lives in the record rather than being re-derived from a dispatch attempt's
# printed output, because only bin/fm-relay-host.sh sees the raw verb protocol;
# anything downstream would be parsing a human sentence and would classify a
# refused-but-reachable host as an unreachable one. It also makes
# `fm-relay-host.sh queued` able to say what a stuck dispatch is stuck on.
fm_relay_pending_set_reason() {  # <pending-file> <reason>
  local file=$1 reason=$2 tmp
  [ -f "$file" ] || return 0
  tmp="$file.tmp$$"
  { grep -v '^reason=' "$file" 2>/dev/null || true; printf 'reason=%s\n' "$reason"; } > "$tmp" \
    && mv -f "$tmp" "$file"
  rm -f "$tmp"
}

# Classify what came back from a dispatch attempt so the caller knows whether to
# hold the work or give it up. Prints "ok", "retry <reason>", or "fail <reason>".
#
# The FIRST TOKEN decides, not the exit status, because the verb protocol makes
# the first token authoritative and one refusal deliberately exits 0:
# ALREADY_CLAIMED reports a live task on the host, which succeeded as a question
# and failed as a dispatch. Reading the exit status alone would file that as a
# successful spawn and then write metadata from a claim report.
#
# The host's own transient refusals are self-identifying: every GUI preflight
# code starts with `gui`, so a new one is retryable the day it is added without
# this side being taught about it. A transport failure carries no ERR line at
# all, and that is exactly the shape a sleeping or powered-off host produces, so
# it is retryable too - "could not ask" is never "was told no".
# Anything else - a rejected argument, a missing project, an existing claim - is
# a decision that will not change by waiting.
fm_relay_dispatch_class() {  # <output-text> <exit-code>
  local out=$1 rc=$2 first
  first=${out%%$'\n'*}
  case "$first" in
    OK|OK\ *)
      [ "$rc" -eq 0 ] && { printf 'ok'; return 0; }
      printf 'fail the host answered OK but the call itself failed (exit %s)' "$rc"
      return 0 ;;
    ERR\ gui*)
      printf 'retry %s' "${first#ERR }"
      return 0 ;;
    ERR\ *|ALREADY_CLAIMED*)
      printf 'fail %s' "$first"
      return 0 ;;
  esac
  [ "$rc" -eq 0 ] && { printf 'fail the host answered with no protocol line: %s' "$first"; return 0; }
  printf 'retry host unreachable - asleep, powered off, or the link is down'
}

# One retry attempt for a queued dispatch, run from inside the wake check.
#
# Prints a line ONLY when the supervisor needs to act: the work finally started,
# or it has been held long enough with a stable reason that silence would be
# misreporting, or it failed for a reason waiting cannot fix. A refusal that is
# simply still true prints nothing, because a locked screen every five minutes is
# not news.
#
# The alert marker records the REASON it fired on, not just that it fired, so a
# refusal that changes - screen unlocked but the host session is now down - wakes
# once more instead of hiding behind the first alert.
# The dispatcher's EXIT CODE is the contract here, not its printed text: 0 it
# started, 3 the host declined for a reason that passes, anything else it failed
# for good. bin/fm-relay-host.sh's header owns those codes, and it is the only
# side that sees the raw verb protocol, so nothing downstream re-derives a
# verdict from a human sentence.
fm_relay_pending_emit() {  # <home> <id>
  local home=$1 id=$2 state pending host out rc reason fails limit prev
  state="${FM_STATE_OVERRIDE:-$home/state}"
  pending=$(fm_relay_pending_file "$state" "$id")
  host=$(fm_relay_pending_field "$pending" host) || return 0
  # A machine that is no longer the control plane must not keep trying to start
  # this work: the peer would refuse it as stale every time, and each refusal is
  # a NEW reason, so the alert marker would change on every check and wake a
  # supervisor that cannot act anyway. Silence here is not dropping the work -
  # the queued record stays on disk, and bin/fm-helm.sh handover reports it as
  # something that does not travel.
  if fm_helm_in_fleet "$home"; then
    fm_helm_fleet_load "$home" >/dev/null 2>&1 || return 0
    fm_helm_lease_load
    [ "$FM_HELM_HOLDER" = "$FM_HELM_MACHINE" ] || return 0
  fi
  limit=${FM_RELAY_QUEUE_WAKE_AFTER:-3}
  rc=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-$home/data}" \
    "$FM_RELAY_LIB_DIR/fm-relay-host.sh" dispatch "$id" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$state/$id.relay-queue-fails" "$state/$id.relay-queue-alert"
    printf '%s dispatched to %s after waiting: %s\n' "$id" "$host" \
      "$(printf '%s' "$out" | tr '\n' '|' | cut -c1-200)"
    return 0
  fi
  if [ "$rc" -ne 3 ]; then
    # Never silently drop queued work: the record stays, so a supervisor can see
    # it and decide, and the alert marker stops this repeating every check.
    reason=$(printf '%s' "$out" | tr '\n' '|' | cut -c1-200)
    prev=$(cat "$state/$id.relay-queue-alert" 2>/dev/null || true)
    [ "$prev" = "$reason" ] && return 0
    printf '%s\n' "$reason" > "$state/$id.relay-queue-alert"
    printf '%s is still queued for %s and cannot start: %s\n' "$id" "$host" "$reason"
    return 0
  fi
  reason=$(fm_relay_pending_field "$pending" reason)
  [ -n "$reason" ] || reason="the host declined without saying why"
  fails=$(cat "$state/$id.relay-queue-fails" 2>/dev/null || true)
  case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
  fails=$((fails + 1))
  printf '%s\n' "$fails" > "$state/$id.relay-queue-fails"
  prev=$(cat "$state/$id.relay-queue-alert" 2>/dev/null || true)
  # Hold quietly, but not forever and not through a CHANGED reason: a screen that
  # was unlocked while the host session went down is new information, and hiding
  # it behind the first alert would misreport what the machine is waiting on.
  if [ "$fails" -ge "$limit" ] && [ "$prev" != "$reason" ]; then
    printf '%s\n' "$reason" > "$state/$id.relay-queue-alert"
    printf '%s is waiting for %s: %s\n' "$id" "$host" "$reason"
  fi
}

# The body of a task's generated wake check. It lives here, not inlined into the
# generated file, because bin/fm-relay-check-make.sh WRITES that file once and
# nothing ever rewrites it: anything inlined would keep asking the question of the
# day it was armed (the same reasoning bin/fm-poll-lib.sh records).
#
# Watcher contract: print one line to wake firstmate, print nothing to keep
# sleeping. Two cursors keep that honest. The check advances only <id>.relay-seen,
# so one batch of new events produces exactly one wake instead of one every check
# interval, and it never touches <id>.relay-ack, so `events` still replays
# everything the supervisor has not actually been shown.
#
# A relay that cannot answer is not the same as "nothing happened", so a failed
# read never advances anything and never prints. It is also never silently
# swallowed forever: after FM_RELAY_FAIL_WAKE_AFTER consecutive failures the check
# wakes once with a diagnostic and marks itself reported, exactly so a task cannot
# sit unobserved behind a dead link.
fm_relay_check_emit() {  # <home> <id>
  local home=$1 id=$2 state host seen first new offset fails limit
  state="${FM_STATE_OVERRIDE:-$home/state}"
  limit=${FM_RELAY_FAIL_WAKE_AFTER:-3}
  # A task can be armed before it is live: a dispatch the host refused while it
  # was locked, asleep, or without its desktop host session is held here and
  # retried on this same check, so the work starts on its own once the host can
  # take it. While that record exists there is no remote task to read events
  # from, and the retry owns the whole check.
  if [ -f "$(fm_relay_pending_file "$state" "$id")" ]; then
    fm_relay_pending_emit "$home" "$id"
    return 0
  fi
  host=$(fm_relay_meta_host "$state/$id.meta") || return 0
  [ -n "$host" ] || return 0
  fm_relay_host_load "$home" "$host" >/dev/null 2>&1 || return 0
  seen=$(cat "$state/$id.relay-seen" 2>/dev/null || true)
  case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
  if ! fm_relay_exec events "$id" "$seen" >/dev/null 2>&1; then
    fails=$(cat "$state/$id.relay-fails" 2>/dev/null || true)
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    fails=$((fails + 1))
    printf '%s\n' "$fails" > "$state/$id.relay-fails"
    if [ "$fails" -ge "$limit" ] && [ ! -f "$state/$id.relay-error" ]; then
      : > "$state/$id.relay-error"
      printf 'relay host %s unreachable for %s consecutive checks; %s is unobserved\n' \
        "$host" "$fails" "$id"
    fi
    return 0
  fi
  rm -f "$state/$id.relay-fails" "$state/$id.relay-error"
  first=${FM_RELAY_OUT%%$'\n'*}
  new=$(printf '%s' "$first" | sed -n 's/.*new=\([0-9]*\).*/\1/p')
  offset=$(printf '%s' "$first" | sed -n 's/.*offset=\([0-9]*\).*/\1/p')
  case "$new" in ''|0) return 0 ;; esac
  [ -n "$offset" ] || return 0
  printf '%s\n' "$offset" > "$state/$id.relay-seen"
  # One line only, because a wake reason is one line. The full batch stays
  # readable with `fm-relay-host.sh events <id>`.
  printf '%s on %s: %s\n' "$id" "$host" \
    "$(printf '%s' "$FM_RELAY_OUT" | sed -n '2,$p' | tr '\n' '|' | cut -c1-200)"
}

# One line of remote task state for the control side's supervision, produced by
# the host's own bin/fm-crew-state.sh so its reconciliation rules are reused
# rather than reimplemented across the relay.
fm_relay_crew_state() {  # <home> <id>
  local home=$1 id=$2 host
  host=$(fm_relay_meta_host "$home/state/$id.meta") || return 1
  [ -n "$host" ] || return 1
  fm_relay_host_load "$home" "$host" || return 1
  fm_relay_verb_ok crew-state "$id"
}
