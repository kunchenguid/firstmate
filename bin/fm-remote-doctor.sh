#!/usr/bin/env bash
# Check, and optionally repair, one remote account's second-mate readiness.
#
# Usage:
#   bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh [--fix]
#
# Run it through fm-on.sh so the fixed remote entrypoint composes and exports
# the child PATH: this command reports the PATH it inherits instead of
# recomposing it, so the entrypoint stays the single owner of that ordering and
# the two can never drift.
#
# A remote second mate always runs on the Herdr backend in the dedicated
# fm-remote session, so readiness is more than tool resolution. herdr must
# resolve, that server must be reachable, and on macOS the Firstmate-owned
# launch agent dev.firstmate.herdr.fm-remote at
# ~/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist must exist, carry
# LimitLoadToSessionType=Aqua, and be loaded into the console user's gui/<uid>
# domain, so the server belongs to the GUI login session and survives logout and
# SSH disconnection. SSH cannot create an Aqua session, so a host with no GUI
# login is reported as a human gap rather than repaired.
#
# Line protocol, one fact per line, stable for script consumers:
#   mode=check|fix
#   path=<the child PATH this command inherited>
#   entrypoint=yes|no
#   platform=darwin|linux|<uname -s>|unknown
#   required <tool>=<path>|MISSING
#   optional <tool>=<path>|absent
#   fix <check>=applied: <what changed>       (--fix only)
#   fix <check>=failed: <why the repair did not land>   (--fix only)
#   check <check>=ok: <evidence>
#   check <check>=skip: <why this host is exempt>
#   check <check>=fixable: <gap --fix can close>
#   check <check>=human: <gap only a person at that machine can close>
#   action: <check>: <the exact step to take>
# Every check line is authoritative for the moment it printed: under --fix it is
# the state after the repair attempt, so a human gap is never presented as
# fixed. Any remaining fixable or human gap, and any missing required tool,
# exits non-zero.
#
# --fix is idempotent and closes only automatable gaps: it writes the Aqua
# launch agent, bootstraps and kickstarts it into gui/<uid> when a login session
# exists, starts the herdr server where no launch agent applies, and recreates
# the entrypoint symlink. It never creates a login session, never writes an
# auto-login password (kcpassword), never changes FileVault, and never stores an
# account password; those remain reported human gaps.
set -eu

# Resolve this script's directory with builtins only: a host missing a required
# tool must still reach the report that names it, not die on a bare PATH.
SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
REQUIRED_TOOLS=(git jq)
OPTIONAL_TOOLS=(tmux treehouse no-mistakes tasks-axi claude codex opencode pi grok kimi)
LAUNCH_AGENT_LABEL=dev.firstmate.herdr.fm-remote
# The dedicated remote-secondmate session. The user's interactive Herdr work
# remains in the separate default session, which this readiness check never
# requires or changes.
HERDR_SESSION_NAME=fm-remote
LAUNCH_AGENT_DIR="${HOME:-}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"
LAUNCH_AGENT_LOG_DIR="${HOME:-}/Library/Logs"
LAUNCH_AGENT_LOG="$LAUNCH_AGENT_LOG_DIR/$LAUNCH_AGENT_LABEL.log"
ENTRYPOINT_LINK="${HOME:-}/.local/bin/fm-remote-entrypoint.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE=check
case "${1:-}" in
  '') ;;
  --fix) MODE=fix; shift ;;
  *) usage ;;
esac
[ "$#" -eq 0 ] || usage

PLATFORM_RAW=$(uname -s 2>/dev/null) || PLATFORM_RAW=
case "$PLATFORM_RAW" in
  Darwin) PLATFORM=darwin ;;
  Linux) PLATFORM=linux ;;
  '') PLATFORM=unknown ;;
  *) PLATFORM=$PLATFORM_RAW ;;
esac
UID_NUM=$(id -u 2>/dev/null) || UID_NUM=

CHECK_NAMES=()
CHECK_VALUES=()
CHECK_ACTIONS=()

record() { # <name> <value> [operator-action]
  CHECK_NAMES+=("$1")
  CHECK_VALUES+=("$2")
  CHECK_ACTIONS+=("${3:-}")
}

check_value() { # <name>; prints the recorded value, empty when unrecorded
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      printf '%s' "${CHECK_VALUES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

check_is_ok() { # <name>
  case "$(check_value "$1" 2>/dev/null || true)" in ok:*) return 0 ;; esac
  return 1
}

herdr_cli_available() {
  command -v herdr >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

# The herdr adapter is the single owner of session-scoped herdr invocation and
# of starting a server, so read and start through it rather than restating
# either here. Sourced only when both tools resolve, so a bare host still
# reports its gaps instead of failing to load.
herdr_adapter_load() {
  [ -z "${FM_REMOTE_DOCTOR_HERDR_LOADED:-}" ] || return 0
  herdr_cli_available || return 1
  [ -f "$SCRIPT_DIR/fm-backend.sh" ] && [ -f "$SCRIPT_DIR/backends/herdr.sh" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  fm_backend_source herdr || return 1
  FM_REMOTE_DOCTOR_HERDR_LOADED=1
}

herdr_server_running() {
  local running
  herdr_adapter_load || return 1
  running=$(fm_backend_herdr_cli "$HERDR_SESSION_NAME" status --json 2>/dev/null \
    | jq -r '.server.running // false' 2>/dev/null) || return 1
  [ "$running" = true ]
}

launch_agent_is_aqua() {
  local stripped
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  stripped=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  case "$stripped" in
    *'<key>LimitLoadToSessionType</key><string>Aqua</string>'*) return 0 ;;
  esac
  return 1
}

render_launch_agent() { # <resolved-herdr-path>
  local herdr_bin=$1
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCH_AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$herdr_bin</string>
		<string>server</string>
		<string>--session</string>
		<string>$HERDR_SESSION_NAME</string>
	</array>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
</dict>
</plist>
XML
}

launch_agent_contract_matches() {
  local herdr_bin actual expected
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  actual=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  expected=$(render_launch_agent "$herdr_bin" | tr -d ' \t\r\n') || return 1
  [ "$actual" = "$expected" ]
}

launch_agent_loaded_contract_matches() {
  local loaded herdr_bin herdr_compact plist_compact log_compact args
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  loaded=$(launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>/dev/null) || return 1
  loaded=$(printf '%s' "$loaded" | tr -d ' \t\r\n') || return 1
  herdr_compact=$(printf '%s' "$herdr_bin" | tr -d ' \t\r\n') || return 1
  plist_compact=$(printf '%s' "$LAUNCH_AGENT_PLIST" | tr -d ' \t\r\n') || return 1
  log_compact=$(printf '%s' "$LAUNCH_AGENT_LOG" | tr -d ' \t\r\n') || return 1
  args="arguments={$herdr_compact"'server--session'"$HERDR_SESSION_NAME}"
  [[ "$loaded" == *"path=$plist_compact"* ]] || return 1
  [[ "$loaded" == *"program=$herdr_compact"* ]] || return 1
  [[ "$loaded" == *"$args"* ]] || return 1
  [[ "$loaded" == *"stdoutpath=$log_compact"* ]] || return 1
  [[ "$loaded" == *"stderrpath=$log_compact"* ]] || return 1
  [[ "$loaded" == *'properties=keepalive|runatload'* ]] || return 1
}

# --- checks -----------------------------------------------------------------

check_herdr() {
  local resolved
  if resolved=$(command -v herdr 2>/dev/null); then
    record herdr "ok: $resolved"
    return 0
  fi
  record herdr "human: the herdr CLI does not resolve on the remote runtime PATH" \
    "install herdr from https://herdr.dev on that account, or add a ~/.local/bin wrapper for it; a remote second mate always runs on the Herdr backend"
}

check_gui_session() {
  if [ "$PLATFORM" != darwin ]; then
    record gui-session "skip: no Aqua login session applies on $PLATFORM"
    return 0
  fi
  if [ -z "$UID_NUM" ]; then
    record gui-session "human: the account uid could not be read, so its login session cannot be inspected" \
      "run 'id -u' on that account and report the failure; Firstmate cannot address gui/<uid> without it"
    return 0
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    record gui-session "human: launchctl does not resolve, so the login session cannot be inspected" \
      "restore /bin/launchctl on that macOS account; without it no launch agent can be inspected or loaded"
    return 0
  fi
  if launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
    record gui-session "ok: gui/$UID_NUM"
    return 0
  fi
  record gui-session "human: no Aqua login session exists for uid $UID_NUM" \
    "log that account in once at the console, and enable automatic login in System Settings > Users & Groups if the machine runs headless; SSH cannot create a GUI session, and Firstmate never writes an auto-login password or changes FileVault"
}

check_launch_agent() {
  if [ "$PLATFORM" != darwin ]; then
    record launchagent "skip: launch agents apply only on darwin"
    record launchagent-scope "skip: launch agents apply only on darwin"
    record launchagent-loaded "skip: launch agents apply only on darwin"
    return 0
  fi
  if [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ]; then
    if launch_agent_contract_matches; then
      record launchagent "ok: $LAUNCH_AGENT_PLIST matches the Firstmate-owned contract"
    else
      record launchagent "fixable: $LAUNCH_AGENT_PLIST does not match the current Firstmate-owned contract" \
        "rerun this command with --fix to rewrite its label, program arguments, session scope, restart policy, and log paths"
    fi
    if launch_agent_is_aqua; then
      record launchagent-scope "ok: LimitLoadToSessionType=Aqua"
    else
      record launchagent-scope "fixable: $LAUNCH_AGENT_PLIST is not scoped to the Aqua login session" \
        "rerun this command with --fix to rewrite it with LimitLoadToSessionType=Aqua"
    fi
  else
    record launchagent "fixable: no Firstmate herdr launch agent at $LAUNCH_AGENT_PLIST" \
      "rerun this command with --fix to install it"
    record launchagent-scope "skip: no launch agent is installed yet"
  fi
  check_launch_agent_loaded
}

check_launch_agent_loaded() {
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    record launchagent-loaded "human: the launch agent domain gui/<uid> cannot be inspected on this account" \
      "restore launchctl and a readable account uid, then rerun this command"
    return 0
  fi
  if launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
    if launch_agent_loaded_contract_matches; then
      record launchagent-loaded "ok: gui/$UID_NUM/$LAUNCH_AGENT_LABEL matches the effective contract"
    else
      record launchagent-loaded "fixable: gui/$UID_NUM/$LAUNCH_AGENT_LABEL does not match the effective Firstmate-owned contract" \
        "rerun this command with --fix to replace the loaded job with the current launch-agent contract"
    fi
    return 0
  fi
  if check_is_ok gui-session; then
    record launchagent-loaded "fixable: $LAUNCH_AGENT_LABEL is not loaded into gui/$UID_NUM" \
      "rerun this command with --fix to bootstrap and start it"
    return 0
  fi
  record launchagent-loaded "human: $LAUNCH_AGENT_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
    "close the login-session gap first; a launch agent can only be bootstrapped into an existing GUI session"
}

check_herdr_server() {
  if ! herdr_cli_available; then
    record herdr-server "human: herdr server status cannot be read without both herdr and jq on the runtime PATH" \
      "install the missing tool reported above, then rerun this command"
    return 0
  fi
  if herdr_server_running; then
    record herdr-server "ok: session $HERDR_SESSION_NAME is running"
    return 0
  fi
  if [ "$PLATFORM" = darwin ] && ! check_is_ok gui-session; then
    record herdr-server "human: the herdr server for session $HERDR_SESSION_NAME is not running and there is no GUI login session to start it in" \
      "close the login-session gap first; a server started over SSH would not belong to an Aqua session"
    return 0
  fi
  record herdr-server "fixable: the herdr server for session $HERDR_SESSION_NAME is not running" \
    "rerun this command with --fix to start it"
}

check_entrypoint_link() {
  local want
  if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
    record entrypoint-link "skip: this run did not come through the fixed remote entrypoint"
    return 0
  fi
  want="$FM_ROOT_OVERRIDE/bin/fm-remote-entrypoint.sh"
  if [ -L "$ENTRYPOINT_LINK" ] && [ "$(readlink "$ENTRYPOINT_LINK")" = "$want" ]; then
    record entrypoint-link "ok: $ENTRYPOINT_LINK"
    return 0
  fi
  if [ -e "$ENTRYPOINT_LINK" ] || [ -L "$ENTRYPOINT_LINK" ]; then
    record entrypoint-link "human: $ENTRYPOINT_LINK exists but is not the symlink to $want" \
      "inspect that path yourself and replace it with 'ln -sfn $want $ENTRYPOINT_LINK' if it is stale; Firstmate never overwrites a file it did not create there"
    return 0
  fi
  record entrypoint-link "fixable: no entrypoint symlink at $ENTRYPOINT_LINK" \
    "rerun this command with --fix to create it"
}

run_checks() {
  CHECK_NAMES=()
  CHECK_VALUES=()
  CHECK_ACTIONS=()
  check_herdr
  check_gui_session
  check_launch_agent
  check_herdr_server
  check_entrypoint_link
}

# --- repairs ----------------------------------------------------------------

fix_report() { # <check> applied|failed <text>
  printf 'fix %s=%s: %s\n' "$1" "$2" "$3"
}

write_launch_agent() {
  local herdr_bin tmp
  if ! herdr_bin=$(command -v herdr 2>/dev/null); then
    fix_report launchagent failed "herdr does not resolve, so no launch agent was written"
    return 1
  fi
  case "$herdr_bin" in
    *'&'*|*'<'*|*'>'*|*'"'*|*"'"*)
      fix_report launchagent failed "the resolved herdr path contains characters that cannot be embedded in a property list: $herdr_bin"
      return 1
      ;;
  esac
  if ! mkdir -p "$LAUNCH_AGENT_DIR" 2>/dev/null; then
    fix_report launchagent failed "cannot create $LAUNCH_AGENT_DIR"
    return 1
  fi
  mkdir -p "$LAUNCH_AGENT_LOG_DIR" 2>/dev/null || true
  tmp="$LAUNCH_AGENT_DIR/.$LAUNCH_AGENT_LABEL.plist.tmp.$$"
  render_launch_agent "$herdr_bin" > "$tmp"
  chmod 0644 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
    rm -f -- "$tmp"
    fix_report launchagent failed "cannot publish $LAUNCH_AGENT_PLIST"
    return 1
  fi
  fix_report launchagent applied "wrote the Aqua-scoped $LAUNCH_AGENT_LABEL launch agent running $herdr_bin server"
}

# Reload rather than plain bootstrap so a rewritten plist replaces a stale
# in-memory copy, and kickstart so the server is running now rather than at the
# next login. Both are safe to repeat.
reload_launch_agent() { # <check-to-report-under>
  local report=$1 out
  [ -f "$LAUNCH_AGENT_PLIST" ] || {
    fix_report "$report" failed "there is no launch agent to load at $LAUNCH_AGENT_PLIST"
    return 1
  }
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    fix_report "$report" failed "launchctl or the account uid is unavailable"
    return 1
  fi
  launchctl bootout "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  if ! out=$(launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENT_PLIST" 2>&1); then
    fix_report "$report" failed "launchctl bootstrap gui/$UID_NUM refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! out=$(launchctl kickstart -k "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>&1); then
    fix_report "$report" failed "launchctl kickstart gui/$UID_NUM/$LAUNCH_AGENT_LABEL refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! wait_for_herdr_server; then
    fix_report "$report" failed "the herdr server for session $HERDR_SESSION_NAME did not report running within 10s"
    return 1
  fi
  fix_report "$report" applied "bootstrapped and started $LAUNCH_AGENT_LABEL in gui/$UID_NUM"
}

wait_for_herdr_server() {
  local i=0
  while [ "$i" -lt 20 ]; do
    herdr_server_running && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

start_herdr_server() {
  if ! herdr_adapter_load; then
    fix_report herdr-server failed "herdr and jq must both resolve before the server can be started"
    return 1
  fi
  if fm_backend_herdr_server_ensure "$HERDR_SESSION_NAME" >/dev/null 2>&1; then
    fix_report herdr-server applied "started the herdr server for session $HERDR_SESSION_NAME"
    return 0
  fi
  fix_report herdr-server failed "the herdr server for session $HERDR_SESSION_NAME did not come up"
  return 1
}

link_entrypoint() {
  local want="${FM_ROOT_OVERRIDE:-}/bin/fm-remote-entrypoint.sh"
  if ! mkdir -p "$(dirname "$ENTRYPOINT_LINK")" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create $(dirname "$ENTRYPOINT_LINK")"
    return 1
  fi
  if ! ln -s "$want" "$ENTRYPOINT_LINK" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create the symlink at $ENTRYPOINT_LINK"
    return 1
  fi
  fix_report entrypoint-link applied "linked $ENTRYPOINT_LINK to $want"
}

apply_fixes() {
  local i name value launch_agent_written=0 launch_agent_reloaded=0
  i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    name=${CHECK_NAMES[$i]}
    value=${CHECK_VALUES[$i]}
    i=$((i + 1))
    case "$value" in fixable:*) ;; *) continue ;; esac
    case "$name" in
      launchagent|launchagent-scope)
        [ "$launch_agent_written" -eq 0 ] || continue
        launch_agent_written=1
        write_launch_agent || continue
        # A freshly written plist runs nothing until it is (re)loaded, and only
        # an existing GUI session can hold it.
        check_is_ok gui-session || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      launchagent-loaded)
        [ "$launch_agent_reloaded" -eq 0 ] || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      herdr-server)
        # On darwin the launch agent owns the server, so restart it through
        # launchd rather than starting a stray one outside the Aqua session. A
        # reload earlier in this same pass has already done that.
        if [ "$PLATFORM" = darwin ] && [ -f "$LAUNCH_AGENT_PLIST" ] && check_is_ok gui-session; then
          [ "$launch_agent_reloaded" -eq 0 ] || continue
          launch_agent_reloaded=1
          reload_launch_agent herdr-server || true
          continue
        fi
        start_herdr_server || true
        ;;
      entrypoint-link) link_entrypoint || true ;;
    esac
  done
}

# --- report -----------------------------------------------------------------

printf 'mode=%s\n' "$MODE"
printf 'path=%s\n' "${PATH:-}"
if [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ "${PATH%%:*}" = "$FM_ROOT_OVERRIDE/bin" ]; then
  printf 'entrypoint=yes\n'
else
  printf 'entrypoint=no\n'
  printf 'note: not launched through the fixed remote entrypoint; the reported PATH is this caller environment.\n' >&2
fi
printf 'platform=%s\n' "$PLATFORM"

MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'required %s=%s\n' "$tool" "$resolved"
  else
    printf 'required %s=MISSING\n' "$tool"
    MISSING+=("$tool")
  fi
done
for tool in "${OPTIONAL_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'optional %s=%s\n' "$tool" "$resolved"
  else
    printf 'optional %s=absent\n' "$tool"
  fi
done

run_checks
if [ "$MODE" = fix ]; then
  apply_fixes
  # Re-derive every check from the host itself, so what prints below is the
  # state after repair rather than the intent of a repair.
  run_checks
fi

GAPS=()
i=0
while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${CHECK_NAMES[$i]}" "${CHECK_VALUES[$i]}"
  case "${CHECK_VALUES[$i]}" in
    fixable:*|human:*) GAPS+=("$i") ;;
  esac
  i=$((i + 1))
done
for i in ${GAPS[@]+"${GAPS[@]}"}; do
  [ -z "${CHECK_ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${CHECK_NAMES[$i]}" "${CHECK_ACTIONS[$i]}"
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'error: required tools do not resolve on the remote runtime PATH: %s\n' "${MISSING[*]}" >&2
  printf 'fix: install each one where it resolves on the path reported above, or put a wrapper script for it in %s/.local/bin, which is always on that PATH.\n' "${HOME:-~}" >&2
  printf 'fix: tools provided by nvm, asdf, or mise never resolve here because no login or interactive shell runs; see docs/remote-secondmates.md for the wrapper recipe.\n' >&2
fi
if [ "${#MISSING[@]}" -gt 0 ] || [ "${#GAPS[@]}" -gt 0 ]; then
  NAMES=
  for i in ${GAPS[@]+"${GAPS[@]}"}; do
    NAMES="${NAMES:+$NAMES }${CHECK_NAMES[$i]}"
  done
  printf 'error: this host is not ready for a remote second mate%s\n' "${NAMES:+; unresolved: $NAMES}" >&2
  exit 1
fi
printf 'ok: remote second-mate readiness confirmed on this host\n'
