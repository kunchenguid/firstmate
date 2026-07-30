#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving session-lock identity inside a
# real command environment and the bounded foreground-checkpoint supervision
# path.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
PROBE="$PROJECT/codex-lock-probe.sh"
LOCK_FRESH_HOME="$LAB/lock-fresh"
LOCK_STALE_HOME="$LAB/lock-stale"
CODEX_VERSION=$(codex --version)
OUTER_THREAD_ID=${CODEX_THREAD_ID:-}

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/bin/fm-lock.sh" "$ROOT/bin/fm-session-lock-lib.sh" "$PROJECT/bin/"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
cat > "$PROBE" <<'SH'
#!/usr/bin/env bash
set -u

ROOT=${CODEX_PROBE_ROOT:?}
FRESH=${CODEX_PROBE_FRESH_HOME:?}
STALE=${CODEX_PROBE_STALE_HOME:?}

yes_no() {
  if "$@"; then printf '%s' yes; else printf '%s' no; fi
}

shell_pid=$$
shell_pgid=$(ps -o pgid= -p "$shell_pid" | tr -d ' ')
shell_sid=$(ps -o sid= -p "$shell_pid" | tr -d ' ')
parent_comm=$(ps -o comm= -p "$PPID" | tr -d '[:space:]')
thread_set=$(yes_no test -n "${CODEX_THREAD_ID:-}")
thread_differs_from_outer=not-applicable
if [ -n "${CODEX_PROBE_OUTER_THREAD_ID:-}" ]; then
  thread_differs_from_outer=$(yes_no test "${CODEX_THREAD_ID:-}" != "$CODEX_PROBE_OUTER_THREAD_ID")
fi
pgid_leader=$(yes_no test "$shell_pid" = "$shell_pgid")
sid_leader=$(yes_no test "$shell_pid" = "$shell_sid")
parent_codex=$(yes_no test "$parent_comm" = codex)
namespace_match=$(yes_no test "$(readlink "/proc/$shell_pid/ns/pid")" = "$(readlink "/proc/$PPID/ns/pid")")

mkdir -p "$FRESH/state" "$STALE/state"
FM_HOME="$FRESH" "$ROOT/bin/fm-lock.sh" >/dev/null
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"
fresh_owned=no
fm_session_lock_owned_by_self "$FRESH/state" && fresh_owned=yes
fresh_lock=$(cat "$FRESH/state/.lock")
fresh_identity=$(cat "$FRESH/state/.lock.codex-thread")
fresh_pid_match=$(yes_no test "${fresh_identity%%:*}" = "$fresh_lock")
fresh_thread_match=$(yes_no test "${fresh_identity#*:}" = "${CODEX_THREAD_ID:-}")

printf '%s\n' 99999999 > "$STALE/state/.lock"
printf '%s\n' '99999999:01900000-0000-7000-8000-000000000000' > "$STALE/state/.lock.codex-thread"
stale_status=$(FM_HOME="$STALE" "$ROOT/bin/fm-lock.sh" status)
FM_HOME="$STALE" "$ROOT/bin/fm-lock.sh" >/dev/null
stale_owned=no
fm_session_lock_owned_by_self "$STALE/state" && stale_owned=yes
printf 'CODEX_THREAD_ID is set: %s\n' "$thread_set"
printf 'CODEX_THREAD_ID differs from outer session: %s\n' "$thread_differs_from_outer"
printf 'probe is its own PGID leader: %s\n' "$pgid_leader"
printf 'probe is its own SID leader: %s\n' "$sid_leader"
printf 'probe parent is codex: %s\n' "$parent_codex"
printf 'probe PID namespace matches parent: %s\n' "$namespace_match"
printf 'fresh ownership verified: %s\n' "$fresh_owned"
printf 'fresh sidecar pid matches lock: %s\n' "$fresh_pid_match"
printf 'fresh sidecar thread matches command: %s\n' "$fresh_thread_match"
printf '%s\n' "$stale_status"
printf 'stale ownership verified after reacquisition: %s\n' "$stale_owned"
SH
chmod +x "$PROBE"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `exec ./codex-lock-probe.sh` as one foreground shell call. Then run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After both commands return, reply briefly.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" \
    CODEX_PROBE_ROOT="$PROJECT" \
    CODEX_PROBE_FRESH_HOME="$LOCK_FRESH_HOME" \
    CODEX_PROBE_STALE_HOME="$LOCK_STALE_HOME" \
    CODEX_PROBE_OUTER_THREAD_ID="$OUTER_THREAD_ID" \
    codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

for expected in \
  'CODEX_THREAD_ID is set: yes' \
  'probe is its own PGID leader: yes' \
  'probe is its own SID leader: yes' \
  'probe parent is codex: yes' \
  'probe PID namespace matches parent: yes' \
  'fresh ownership verified: yes' \
  'fresh sidecar pid matches lock: yes' \
  'fresh sidecar thread matches command: yes' \
  'lock: stale (pid 99999999 dead or not a harness)' \
  'stale ownership verified after reacquisition: yes'; do
  grep -F "$expected" "$TRANSCRIPT" >/dev/null \
    || fail "Codex transcript omitted '$expected': $(tail -20 "$TRANSCRIPT")"
done
if [ -n "$OUTER_THREAD_ID" ]; then
  grep -F 'CODEX_THREAD_ID differs from outer session: yes' "$TRANSCRIPT" >/dev/null \
    || fail "nested Codex command reused the outer thread identity: $(tail -20 "$TRANSCRIPT")"
else
  grep -F 'CODEX_THREAD_ID differs from outer session: not-applicable' "$TRANSCRIPT" >/dev/null \
    || fail "top-level Codex probe did not report the absent outer session: $(tail -20 "$TRANSCRIPT")"
fi
grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi

printf 'ok - %s live E2E verified isolated-command lock ownership, stale recovery, and the one-second foreground checkpoint path\n' "$CODEX_VERSION"
