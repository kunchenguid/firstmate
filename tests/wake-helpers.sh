#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites.
# The fake Herdr surfaces here encode
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
# Create the recorder dir with mktemp directly (not fm_test_tmproot, whose
# first call installs an EXIT trap that, invoked inside a command-substitution
# subshell, would delete the dir on subshell exit). Register it for the same
# cleanup and install the trap in THIS shell if it is the first registration.
_fm_wedge_rec_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-wedge-rec.XXXXXX")
if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then trap fm_test_cleanup EXIT; fi
FM_TEST_CLEANUP_DIRS+=("$_fm_wedge_rec_dir")
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

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.7.3","protocol":14},"server":{"running":true}}\n' ;;
  'pane get') [ "${FM_FAKE_HERDR_PANE_ALIVE:-1}" = 1 ] ;;
  'pane read') [ -n "${FM_FAKE_HERDR_CAPTURE:-}" ] && cat "$FM_FAKE_HERDR_CAPTURE" ;;
  'agent get')
    status=${FM_FAKE_HERDR_AGENT_STATUS:-idle}
    if [ -n "${FM_FAKE_HERDR_CAPTURE:-}" ] && [ -e "$FM_FAKE_HERDR_CAPTURE.submitted" ]; then
      status=working
    fi
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
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

make_supercase() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.7.3","protocol":14},"server":{"running":true}}\n' ;;
  'pane get') [ "${FM_FAKE_HERDR_PANE_ALIVE:-1}" = 1 ] ;;
  'pane read') [ -n "${FM_FAKE_HERDR_CAPTURE:-}" ] && cat "$FM_FAKE_HERDR_CAPTURE" ;;
  'agent get')
    status=${FM_FAKE_HERDR_AGENT_STATUS:-idle}
    if [ -n "${FM_FAKE_HERDR_CAPTURE:-}" ] && [ -e "$FM_FAKE_HERDR_CAPTURE.submitted" ]; then
      status=working
    fi
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    ;;
  'pane send-text')
    text=${4:-}
    printf '%s\n' "$text" >> "${FM_FAKE_HERDR_SENT:-/dev/null}"
    [ -z "${FM_FAKE_HERDR_CAPTURE:-}" ] || rm -f "$FM_FAKE_HERDR_CAPTURE.submitted"
    [ -n "${FM_FAKE_HERDR_CAPTURE:-}" ] && printf '❯ %s\n' "$text" > "$FM_FAKE_HERDR_CAPTURE"
    ;;
  'pane send-keys')
    if [ "${4:-}" = enter ]; then
      if [ -n "${FM_FAKE_HERDR_SWALLOW_FILE:-}" ] && [ -f "$FM_FAKE_HERDR_SWALLOW_FILE" ]; then
        [ "${FM_FAKE_HERDR_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_HERDR_SWALLOW_FILE"
      else
        printf '[ENTER]\n' >> "${FM_FAKE_HERDR_SENT:-/dev/null}"
        if [ -n "${FM_FAKE_HERDR_CAPTURE:-}" ]; then
          printf '❯ \n' > "$FM_FAKE_HERDR_CAPTURE"
          : > "$FM_FAKE_HERDR_CAPTURE.submitted"
        fi
      fi
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$dir"
}

make_bordered_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"; fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  printf '│ > │\n' > "$dir/composer"
  printf 'idle\n' > "$dir/composer.status"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?FM_FAKE_COMPOSER unset}"
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.7.3","protocol":14},"server":{"running":true}}\n' ;;
  'pane get') return_code=${FM_FAKE_PANE_GONE:-0}; [ "$return_code" = 0 ] ;;
  'pane read') cat "$COMPOSER" 2>/dev/null ;;
  'agent get')
    status=$(cat "$COMPOSER.status" 2>/dev/null || printf '%s' "${FM_FAKE_HERDR_AGENT_STATUS:-idle}")
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status"
    ;;
  'pane send-text')
    [ "${FM_FAKE_SEND_FAIL:-0}" = 1 ] && exit 1
    text=${4:-}
    [ -n "${FM_FAKE_SENT:-}" ] && printf '%s\n' "$text" >> "$FM_FAKE_SENT"
    printf '│ > %s │\n' "$text" > "$COMPOSER"
    ;;
  'pane send-keys')
    if [ "${4:-}" = enter ]; then
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        [ -n "${FM_FAKE_SENT:-}" ] && printf '[ENTER]\n' >> "$FM_FAKE_SENT"
        printf '│ > │\n' > "$COMPOSER"
        printf 'working\n' > "$COMPOSER.status"
      fi
    fi
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$dir"
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
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
