#!/usr/bin/env bash
# Periodic watchdog that resumes this firstmate home's supervision session on
# its own once real pending work exists and no session already holds it -
# the auto-fire counterpart to bin/fm-relaunch.sh's on-demand-only tool.
# Usage: fm-orchestrator.sh install|status|uninstall|check [--help]
#
# Mechanism, the gating conditions that must all hold before a fire, and why
# THIS tool is allowed a real recurring launchd trigger while fm-relaunch.sh
# deliberately is not, are owned by docs/orchestrator-tool.md - this header
# stays a pointer, not a restatement. fm-relaunch.sh's own resume mechanics
# (terminal/trust-dialog/kickoff handshake) are that script's own; see its
# --help and docs/relaunch-tool.md.
#
# macOS-only (launchd). Fails closed with a clear message on any other platform.
set -eu

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

RELAUNCH_BIN="${FM_ORCHESTRATOR_RELAUNCH_BIN:-$SCRIPT_DIR/fm-relaunch.sh}"
LOCK_BIN="${FM_ORCHESTRATOR_LOCK_BIN:-$SCRIPT_DIR/fm-lock.sh}"
BACKEND_SH="${FM_ORCHESTRATOR_BACKEND_SH:-$SCRIPT_DIR/fm-backend.sh}"

# Cooldown: minimum seconds between fires, so a relaunched session that
# immediately hits the same limit and exits fast can never cause a tight
# fire-loop off a recurring timer. Overridable only for tests.
COOLDOWN_SECS="${FM_ORCHESTRATOR_COOLDOWN_SECS:-1800}"
INTERVAL_SECS="${FM_ORCHESTRATOR_INTERVAL_SECS:-1800}"
COOLDOWN_FILE="$STATE/.orchestrator-cooldown"

usage() {
  sed -n '2,12p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
}

fm_orch_require_macos() {
  [ "$(uname -s)" = Darwin ] || {
    echo "error: fm-orchestrator.sh is macOS-only (needs launchd); this platform is $(uname -s)" >&2
    exit 1
  }
}

# Label derivation mirrors fm-relaunch.sh's, with a distinct base label so the
# two tools never collide on one launchd job.
fm_orch_label() {
  if [ "$FM_HOME" = "$FM_ROOT" ]; then
    printf 'dev.firstmate.orchestrator'
    return
  fi
  local slug
  if command -v shasum >/dev/null 2>&1; then
    slug=$(printf '%s' "$FM_HOME" | shasum -a 256 | cut -c1-8)
  elif command -v sha256sum >/dev/null 2>&1; then
    slug=$(printf '%s' "$FM_HOME" | sha256sum | cut -c1-8)
  else
    echo "error: need shasum or sha256sum to derive a per-home label" >&2
    exit 1
  fi
  printf 'dev.firstmate.orchestrator.%s' "$slug"
}

LABEL="$(fm_orch_label)"
DOMAIN="gui/$(id -u)"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"

fm_orch_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

fm_orch_write_plist() {  # <out-path>
  local out=$1
  mkdir -p "$(dirname "$out")"
  cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$SCRIPT_PATH</string>
		<string>check</string>
	</array>
	<key>StartInterval</key>
	<integer>$INTERVAL_SECS</integer>
	<key>EnvironmentVariables</key>
	<dict>
		<key>FM_HOME</key>
		<string>$FM_HOME</string>
	</dict>
	<key>StandardOutPath</key>
	<string>$FM_HOME/state/fm-orchestrator.log</string>
	<key>StandardErrorPath</key>
	<string>$FM_HOME/state/fm-orchestrator.log</string>
</dict>
</plist>
PLIST
}

cmd_install() {
  fm_orch_require_macos
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-orchestrator-plist.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  fm_orch_write_plist "$tmp"
  if [ -f "$PLIST_PATH" ] && cmp -s "$tmp" "$PLIST_PATH" && fm_orch_loaded; then
    rm -f -- "$tmp"
    trap - EXIT
    echo "installed: $LABEL already up to date and loaded (every ${INTERVAL_SECS}s)"
    return 0
  fi
  if fm_orch_loaded; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  mv -f -- "$tmp" "$PLIST_PATH"
  trap - EXIT
  chmod 0644 "$PLIST_PATH"
  launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
  echo "installed: $LABEL ($PLIST_PATH), fires 'check' every ${INTERVAL_SECS}s"
}

cmd_status() {
  fm_orch_require_macos
  if [ ! -f "$PLIST_PATH" ]; then
    echo "status: $LABEL not installed"
    return 1
  fi
  local interval
  interval=$(grep -A1 '<key>StartInterval</key>' "$PLIST_PATH" | tail -1 | sed -E 's/.*<integer>([0-9]+)<\/integer>.*/\1/')
  echo "status: $LABEL installed at $PLIST_PATH, interval ${interval:-unknown}s"
  if fm_orch_loaded; then
    echo "status: loaded in $DOMAIN"
  else
    echo "status: NOT loaded in $DOMAIN (run install)"
  fi
  if [ -f "$COOLDOWN_FILE" ]; then
    local last now remaining
    last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    remaining=$((last + COOLDOWN_SECS - now))
    if [ "$remaining" -gt 0 ]; then
      echo "status: last fired at epoch $last, cooldown active for ${remaining}s more"
    else
      echo "status: last fired at epoch $last, cooldown elapsed"
    fi
  else
    echo "status: never fired (no cooldown record)"
  fi
}

cmd_uninstall() {
  fm_orch_require_macos
  if fm_orch_loaded; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  rm -f -- "$PLIST_PATH"
  echo "uninstalled: $LABEL"
}

# fm_orch_session_alive: true if a live firstmate session already holds this
# home's session lock. Reuses fm-lock.sh's own liveness mechanism verbatim
# rather than inventing a second one (AGENTS.md section 3's session lock).
fm_orch_session_alive() {
  local out
  out=$(FM_HOME="$FM_HOME" "$LOCK_BIN" status 2>/dev/null) || return 1
  case "$out" in
    *"held by live"*) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_orch_wake_queue_pending: true if the durable wake queue is non-empty.
fm_orch_wake_queue_pending() {
  [ -s "$STATE/.wake-queue" ]
}

# fm_orch_stalled_task_pending: true if any recorded ship/scout task's backend
# endpoint is not alive and its last known status is not terminal. Secondmates
# are excluded: an idle secondmate is healthy persistent state, not a stall
# (AGENTS.md section 6).
fm_orch_stalled_task_pending() {
  local meta id kind backend target status_file last
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
    [ "$kind" = secondmate ] && continue
    backend=$(sed -n 's/^backend=//p' "$meta" | tail -1)
    target=$(sed -n 's/^window=//p' "$meta" | tail -1)
    [ -n "$backend" ] && [ -n "$target" ] || continue
    status_file="$STATE/$id.status"
    if [ -f "$status_file" ]; then
      last=$(tail -1 "$status_file" 2>/dev/null || true)
      case "$last" in
        done:*|failed:*) continue ;;
      esac
    fi
    if ! command -v fm_backend_agent_alive >/dev/null 2>&1 && [ -f "$BACKEND_SH" ]; then
      # shellcheck disable=SC1090
      . "$BACKEND_SH"
    fi
    if command -v fm_backend_agent_alive >/dev/null 2>&1; then
      [ "$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null)" = alive ] && continue
      return 0
    fi
  done
  return 1
}

# fm_orch_backlog_pending: true if data/backlog.md has a Queued item with no
# recorded blocker. Deliberately text-only (grep, no tasks-axi dependency) so
# this stays a cheap, dependency-free gate; a false negative here just means a
# clearable item waits one more cycle for the next heartbeat to catch it.
fm_orch_backlog_pending() {
  local backlog="$DATA/backlog.md"
  [ -f "$backlog" ] || return 1
  awk '
    /^## Queued/ { inq=1; next }
    /^## / { inq=0 }
    inq && /^- / { print }
  ' "$backlog" | grep -qv 'blocked-by:'
}

fm_orch_pending_work() {
  fm_orch_wake_queue_pending && return 0
  fm_orch_stalled_task_pending && return 0
  fm_orch_backlog_pending && return 0
  return 1
}

fm_orch_cooldown_active() {
  [ -f "$COOLDOWN_FILE" ] || return 1
  local last now
  last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $((now - last)) -lt "$COOLDOWN_SECS" ]
}

cmd_check() {
  fm_orch_require_macos
  if fm_orch_session_alive; then
    echo "check: session already alive, nothing to do"
    return 0
  fi
  if ! fm_orch_pending_work; then
    echo "check: no pending work, nothing to do"
    return 0
  fi
  if fm_orch_cooldown_active; then
    echo "check: pending work found but cooldown active, skipping fire"
    return 0
  fi
  [ -x "$RELAUNCH_BIN" ] || {
    echo "error: $RELAUNCH_BIN not found or not executable; cannot fire" >&2
    exit 1
  }
  local rc=0
  set +e
  "$RELAUNCH_BIN" run
  rc=$?
  set -e
  mkdir -p "$STATE"
  date +%s > "$COOLDOWN_FILE"
  if [ "$rc" -ne 0 ]; then
    echo "error: $RELAUNCH_BIN run failed (exit $rc)" >&2
    exit "$rc"
  fi
  echo "check: fired session resume"
}

case "${1:-}" in
  install) cmd_install ;;
  status) cmd_status ;;
  uninstall) cmd_uninstall ;;
  check) cmd_check ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
