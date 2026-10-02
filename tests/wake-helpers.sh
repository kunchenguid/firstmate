#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites. The fake Herdr surfaces here encode
# watcher/daemon/composer behavior, so they live here rather than in the generic
# tests/lib.sh. Generic reporters/assertions come from lib.sh, pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm-wake-drain.sh now calls fm-guard.sh to assert watcher liveness on every
# drain. fm-guard.sh's first check warns when the firstmate PRIMARY checkout
# (FM_ROOT) sits on a feature branch; with no override FM_ROOT resolves to the
# test runner's own checkout, which during validation is on a feature branch, so
# each drain would emit a spurious worktree-tangle banner. Point the tangle check
# at a fresh non-git dir to keep it inert across these suites - the same trick the
# direct fm-guard.sh tests use. A per-call FM_ROOT_OVERRIDE still wins where a
# suite sets its own (e.g. the watcher-lock guard-banner cases).
if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-wake-tangle-root)"
  export FM_ROOT_OVERRIDE
fi

# Wedge-alarm notifier recorder (safety seam). The away-mode wedge alarm fires a
# real OS-level desktop notification by default. Point its FM_WEDGE_ALARM_EXEC
# seam at a recorder for every
# daemon/wake suite, so no test - present or future - can post a real macOS,
# herdr, or command: notification: it is impossible to forget, because sourcing this harness
# installs it. The recorder is an on-disk script (a real daemon a test spawns
# inherits the path and records too). It logs "<channel>\t<summary>" to
# $FM_WEDGE_ALARM_LOG, which a test sets to its own file to assert on; unset means
# /dev/null. FM_WEDGE_ALARM_FAIL=<channel> makes the recorder exit non-zero for
# that channel, to exercise graceful degradation. Suites that do not source this
# harness still cannot fire a real notification: the daemon defaults the seam to
# "discard" whenever it is sourced (its library-mode guard).
_fm_wedge_rec_dir=$(fm_test_tmproot fm-wedge-rec)
cat > "$_fm_wedge_rec_dir/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
case " ${FM_WEDGE_ALARM_FAIL:-} " in *" ${1:-} "*) exit 1 ;; esac
exit 0
REC
chmod +x "$_fm_wedge_rec_dir/rec"
export FM_WEDGE_ALARM_EXEC="$_fm_wedge_rec_dir/rec"

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

# Existing wake fixture: native Herdr reads and deterministic composer writes.
# No server or endpoint is contacted; each mutation affects only supplied files.
make_wake_herdr() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
capture=${FM_FAKE_COMPOSER:-${FM_FAKE_HERDR_CAPTURE:-}}
sent=${FM_FAKE_SENT:-${FM_FAKE_HERDR_SENT:-/dev/null}}
write_composer() {
  local text=$1 border= i=0 width=$((${#1} + 4))
  while [ "$i" -lt "$width" ]; do border="${border}─"; i=$((i + 1)); done
  printf '╭%s╮\n│ > %s │\n╰%s╯\n' "$border" "$text" "$border" > "$capture"
}
case "$1 ${2:-}" in
  'status --json') echo '{"server":{"running":true}}' ;;
  'agent --help') printf 'Commands:\n  prompt  Submit a prompt to an agent\n' ;;
  'pane get')
    [ "${FM_FAKE_HERDR_PANE_ALIVE:-1}" = 1 ] || { echo '{"error":{"code":"pane_not_found"}}'; exit 1; }
    jq -n --arg p "$3" '{result:{pane:{pane_id:$p}}}' ;;
  'agent get')
    case "${FM_FAKE_HERDR_CURRENT_COMMAND:-}" in
      bash|zsh|sh) echo '{"error":{"code":"agent_not_found"}}' ;;
      *) echo '{"result":{"agent":{"agent":"pi","agent_status":"unknown"}}}' ;;
    esac ;;
  'agent prompt')
    [ "${FM_FAKE_PROMPT_TIMEOUT:-0}" != 1 ] || {
      printf 'timeout waiting for response\n' >&2
      exit 1
    }
    [ "${FM_FAKE_SEND_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' "${4:-}" >> "$sent"
    printf '{"result":{"type":"agent_prompted"}}\n' ;;
  'pane process-info')
    jq -n --arg p "$4" --arg command "${FM_FAKE_HERDR_CURRENT_COMMAND:-pi}" '{result:{type:"pane_process_info",process_info:{pane_id:$p,shell_pid:101,foreground_processes:[{pid:102,name:$command,argv0:$command}]}}}' ;;
  'pane read')
    if [ -n "${FM_FAKE_HERDR_CAPTURE_COUNT_FILE:-}" ]; then
      count=$(cat "$FM_FAKE_HERDR_CAPTURE_COUNT_FILE" 2>/dev/null || echo 0)
      printf '%s\n' "$((count + 1))" > "$FM_FAKE_HERDR_CAPTURE_COUNT_FILE"
      [ -z "${FM_FAKE_HERDR_CAPTURE_FAIL_AFTER:-}" ] || [ "$count" -lt "$FM_FAKE_HERDR_CAPTURE_FAIL_AFTER" ] || exit 1
    fi
    [ -z "${FM_FAKE_HERDR_FORBIDDEN_TARGET:-}" ] || [ "$3" != "${FM_FAKE_HERDR_FORBIDDEN_TARGET#*:}" ] || exit 1
    [ -z "$capture" ] || cat "$capture" ;;
  'pane send-text')
    [ "${FM_FAKE_SEND_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' "${4:-}" >> "$sent"
    if [ -n "$capture" ]; then
      if [ -n "${FM_FAKE_COMPOSER:-}" ]; then write_composer "${4:-}"
      else printf '❯ %s\n' "${4:-}" > "$capture"; fi
    fi ;;
  'pane send-keys')
    case "${4:-}" in Enter|enter)
      swallow=${FM_FAKE_SWALLOW:-${FM_FAKE_HERDR_SWALLOW_FILE:-}}
      if [ -n "$swallow" ] && [ -f "$swallow" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$swallow"
      else
        printf '[ENTER]\n' >> "$sent"
        if [ -n "$capture" ]; then
          if [ -n "${FM_FAKE_COMPOSER:-}" ]; then write_composer ''; else printf '❯\n' > "$capture"; fi
        fi
      fi ;;
    esac ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  make_wake_herdr "$fakebin"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# Install a hermetic fake fm-crew-state.sh into <fakebin> and echo its path. The
# watcher's absorb-only-when-provably-working triage calls this (via
# FM_CREW_STATE_BIN) to read a crew's current state on no-verb signal and stale
# paths; the fake returns a canned "state: <s> · source: <src> · <detail>"
# verdict line so a test can fix the provably-working decision without a real
# worktree or no-mistakes.
# A per-id override FM_FAKE_CREW_STATE_<sanitized-id> wins; otherwise the shared
# FM_FAKE_CREW_STATE; otherwise an unknown verdict (NOT provably working), the
# safe default so a test that forgets to set one surfaces rather than absorbs.
make_fake_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin/fm-crew-state.sh"
}

# Prime <file>'s .seen-* marker to its CURRENT signature through the production
# signature owner (bin/fm-wake-lib.sh), so a test can declare "everything in
# this file was already surfaced or deliberately absorbed" before exercising
# the next wake, self-announced append, or annotation decision.
prime_status_seen() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

# Print the generation from a recovery marker token of any status/kind.
recovery_marker_generation() {  # <marker-file>
  sed -n 's/^[^:]*:[^:]*:\(.*\)$/\1/p' "$1"
}

# Acknowledge a drain from its captured stderr (the WAKE_ACK_REQUIRED line).
ack_drain_err() {  # <state> <stderr-file>
  local state=$1 err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation"
}

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  make_wake_herdr "$fakebin"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$dir/composer"
  make_wake_herdr "$fakebin"
  printf '%s\n' "$dir"
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
