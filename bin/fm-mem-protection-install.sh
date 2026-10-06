#!/usr/bin/env bash
# fm-mem-protection-install.sh - install this host's memory-protection policy.
#
# The policy has three host-side parts, all reproducible from this tracked script:
#   1. earlyoom, configured to kill the largest process once available memory
#      falls below 5 percent, preferring node/pytest/acceptance/vitest work and
#      excluding omp, sshd, dockerd, herdr, or clickhouse-server.
#   2. a systemd user timer running bin/fm-mem-alert.sh once a minute from the
#      home's tracked bin/.
#   3. this home's heavy-suite posture: heavy suites are refused locally and the
#      campaign runner is named (bin/fm-heavy-guard.sh consumes it).
#
# Usage:
#   fm-mem-protection-install.sh status
#   fm-mem-protection-install.sh print
#   fm-mem-protection-install.sh install [--home <firstmate-home>] [--runner <path>]
#   fm-mem-protection-install.sh install-config [--home <firstmate-home>] [--runner <path>]
#
# `status`  reports the current state of every part without changing anything.
# `print`   prints every generated file and every command the installer would run.
# `install` applies all parts. It is idempotent and requires sudo for part 1.
# Install an earlyoom version supporting --ignore before running `install`.
#
# Environment:
#   FM_HOME   firstmate home whose config/ receives the heavy-suite posture and
#             whose bin/ runs the alert check (default: the repo root).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

FM_MP_RUNNER_DEFAULT=/sloth/gcp-runner
FM_MP_EARLYOOM_DEFAULTS=/etc/default/earlyoom
FM_MP_EARLYOOM_BACKUP=/etc/default/earlyoom.fm-backup
FM_MP_USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
FM_MP_SERVICE=fm-mem-alert.service
FM_MP_TIMER=fm-mem-alert.timer
# --prefer adds 300 to oom_score, --ignore excludes matching processes. The regex matches the
# basename in /proc/PID/comm, truncated to 15 bytes, so clickhouse-server and
# systemd-journald appear truncated and are matched by prefix. Node.js renames
# its main thread to "MainThread", so `node` alone would never match a node
# process; MainThread is in the prefer list to catch node, vitest, and
# acceptance.cjs runs.
FM_MP_EARLYOOM_PREFER='^(node|nodejs|MainThread|pytest|vitest|acceptance|playwright|cypress|npm|npx)'
FM_MP_EARLYOOM_IGNORE='^(omp|sshd|dockerd|containerd|herdr|clickhouse|systemd|dbus-daemon|Xorg|gnome-shell|tmux|earlyoom)'
FM_MP_EARLYOOM_ARGS="-m 5 -s 100 -r 60 --prefer '$FM_MP_EARLYOOM_PREFER' --ignore '$FM_MP_EARLYOOM_IGNORE'"

usage() {
  sed -n '2,/^set -u/{ /^set -u/d;s/^# \{0,1\}//;p;}' "$0"
}

die() {
  printf 'fm-mem-protection-install: %s\n' "$*" >&2
  exit 2
}

say() {
  printf '%s\n' "$*"
}

earlyoom_defaults_content() {
  cat <<EOF
# Written by firstmate bin/fm-mem-protection-install.sh.
#
# -m 5            act once available memory falls below 5 percent of total
# -s 100          effectively ignore swap usage
# -r 60           print a memory report every 60 seconds
# --prefer REGEX  add 300 to oom_score, so node/pytest/acceptance/vitest work dies first
# --ignore REGEX  exclude infrastructure from victim selection
EARLYOOM_ARGS="$FM_MP_EARLYOOM_ARGS"
EOF
}

service_content() {
  local home=$1
  cat <<EOF
[Unit]
Description=Firstmate memory alert (one minute)
Documentation=man:fm-mem-alert.sh(1)

[Service]
Type=oneshot
Environment=FM_HOME=$home
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/bin/sh -c 'exec "\$FM_HOME/bin/fm-mem-alert.sh" check'
EOF
}

timer_content() {
  cat <<EOF
[Unit]
Description=Firstmate memory alert every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=$FM_MP_SERVICE

[Install]
WantedBy=timers.target
EOF
}

cmd_print() {
  local home=$1
  say "=== $FM_MP_EARLYOOM_DEFAULTS ==="
  earlyoom_defaults_content
  say ""
  say "=== $FM_MP_USER_UNIT_DIR/$FM_MP_SERVICE ==="
  service_content "$home"
  say ""
  say "=== $FM_MP_USER_UNIT_DIR/$FM_MP_TIMER ==="
  timer_content
  say ""
  say "=== $home/config/heavy-suites ==="
  say "remote-only"
  say ""
  say "=== $home/config/campaign-runner ==="
  say "$FM_MP_RUNNER_DEFAULT"
  say ""
  say "=== commands ==="
  say "# prerequisite: installed earlyoom supporting --ignore"
  say "sudo install -m 0644 <defaults> $FM_MP_EARLYOOM_DEFAULTS"
  say "sudo systemctl enable --now earlyoom && sudo systemctl restart earlyoom"
  say "systemctl --user daemon-reload"
  say "systemctl --user enable --now $FM_MP_TIMER"
}

state_earlyoom() {
  local ver
  if command -v earlyoom >/dev/null 2>&1; then
    ver=$(earlyoom -v 2>&1 | head -n1)
    say "earlyoom: installed ($ver)"
  else
    say "earlyoom: absent"
  fi
  if systemctl is-enabled earlyoom >/dev/null 2>&1; then
    say "earlyoom-enabled: $(systemctl is-enabled earlyoom 2>&1)"
  else
    say "earlyoom-enabled: no"
  fi
  if systemctl is-active earlyoom >/dev/null 2>&1; then
    say "earlyoom-active: $(systemctl is-active earlyoom 2>&1)"
  else
    say "earlyoom-active: no"
  fi
  if [ -f "$FM_MP_EARLYOOM_DEFAULTS" ]; then
    say "earlyoom-args: $(sed -n 's/^EARLYOOM_ARGS=//p' "$FM_MP_EARLYOOM_DEFAULTS" | tail -n1)"
  else
    say "earlyoom-args: (no $FM_MP_EARLYOOM_DEFAULTS)"
  fi
}

state_timer() {
  local runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  if [ -f "$FM_MP_USER_UNIT_DIR/$FM_MP_TIMER" ]; then
    say "timer-unit: $FM_MP_USER_UNIT_DIR/$FM_MP_TIMER"
  else
    say "timer-unit: absent"
  fi
  if XDG_RUNTIME_DIR=$runtime systemctl --user is-enabled "$FM_MP_TIMER" >/dev/null 2>&1; then
    say "timer-enabled: yes"
  else
    say "timer-enabled: no"
  fi
  if XDG_RUNTIME_DIR=$runtime systemctl --user is-active "$FM_MP_TIMER" >/dev/null 2>&1; then
    say "timer-active: yes"
  else
    say "timer-active: no"
  fi
}

state_config() {
  local home=$1 key
  for key in heavy-suites campaign-runner; do
    if [ -f "$home/config/$key" ]; then
      say "config/$key: $(head -n1 "$home/config/$key")"
    else
      say "config/$key: absent"
    fi
  done
}

cmd_status() {
  local home=$1
  state_earlyoom
  state_timer
  state_config "$home"
}

# write_config_noclobber <path> <value>
# Overwrites only when the file is absent or already holds the same value, so a
# captain edit is never silently replaced.
write_config_noclobber() {
  local path=$1 value=$2 current=
  current=$(head -n1 "$path" 2>/dev/null) || current=
  if [ -f "$path" ] && [ "$current" != "$value" ]; then
    die "refusing to replace $path (holds '$current')"
  fi
  mkdir -p "$(dirname "$path")" || die "could not create configuration directory for $path"
  (umask 077; printf '%s\n' "$value" > "$path") || die "could not write $path"
}

install_earlyoom() {
  local prior_enabled=no prior_active=no
  command -v earlyoom >/dev/null 2>&1 \
    || die "install a compatible earlyoom version supporting --ignore before installation"
  earlyoom --ignore "$FM_MP_EARLYOOM_IGNORE" --dryrun --help >/dev/null 2>&1 \
    || die "installed earlyoom does not support required --ignore exclusions; install a compatible version before installation"
  systemctl is-enabled earlyoom >/dev/null 2>&1 && prior_enabled=yes
  systemctl is-active earlyoom >/dev/null 2>&1 && prior_active=yes
  say "host-change record: earlyoom prior enabled=$prior_enabled active=$prior_active"
  say "manual revert: [ ! -f $FM_MP_EARLYOOM_BACKUP ] || sudo cp -p $FM_MP_EARLYOOM_BACKUP $FM_MP_EARLYOOM_DEFAULTS"
  if [ "$prior_enabled" = yes ]; then
    say "manual revert: sudo systemctl enable earlyoom"
  else
    say "manual revert: sudo systemctl disable earlyoom"
  fi
  if [ "$prior_active" = yes ]; then
    say "manual revert: sudo systemctl restart earlyoom"
  else
    say "manual revert: sudo systemctl stop earlyoom"
  fi
  say "manual revert: systemctl --user disable --now $FM_MP_TIMER"
  if [ -f "$FM_MP_EARLYOOM_DEFAULTS" ] \
    && [ ! -f "$FM_MP_EARLYOOM_BACKUP" ] \
    && ! cmp -s <(earlyoom_defaults_content) "$FM_MP_EARLYOOM_DEFAULTS"; then
    sudo cp -p "$FM_MP_EARLYOOM_DEFAULTS" "$FM_MP_EARLYOOM_BACKUP" \
      || die "could not back up $FM_MP_EARLYOOM_DEFAULTS"
    say "install: saved $FM_MP_EARLYOOM_BACKUP"
  fi
  local tmp
  tmp=$(mktemp) || die "could not create a temporary file"
  earlyoom_defaults_content > "$tmp" || { rm -f "$tmp"; die "could not write temporary earlyoom defaults"; }
  sudo install -m 0644 "$tmp" "$FM_MP_EARLYOOM_DEFAULTS" || { rm -f "$tmp"; die "could not write $FM_MP_EARLYOOM_DEFAULTS"; }
  rm -f "$tmp"
  sudo systemctl enable earlyoom >/dev/null || die "could not enable earlyoom"
  sudo systemctl restart earlyoom || die "could not start earlyoom"
  say "install: earlyoom enabled and running with -m 5 -s 100"
}

install_timer() {
  local home=$1 runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [ -x "$home/bin/fm-mem-alert.sh" ] || die "alert executable missing: $home/bin/fm-mem-alert.sh"
  mkdir -p "$FM_MP_USER_UNIT_DIR" || die "could not create $FM_MP_USER_UNIT_DIR"
  (umask 022
    service_content "$home" > "$FM_MP_USER_UNIT_DIR/$FM_MP_SERVICE" &&
    timer_content > "$FM_MP_USER_UNIT_DIR/$FM_MP_TIMER") \
    || die "could not write user units"
  XDG_RUNTIME_DIR=$runtime systemctl --user daemon-reload || die "could not reload user units"
  XDG_RUNTIME_DIR=$runtime systemctl --user enable --now "$FM_MP_TIMER" \
    || die "could not enable $FM_MP_TIMER"
  say "install: $FM_MP_TIMER enabled (1 minute)"
}

install_config() {
  local home=$1 runner=$2
  write_config_noclobber "$home/config/heavy-suites" remote-only
  write_config_noclobber "$home/config/campaign-runner" "$runner"
  say "install: heavy suites refused locally; campaign runner $runner"
}

main() {
  local home=$FM_HOME runner=$FM_MP_RUNNER_DEFAULT
  local args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -gt 1 ] || die "--home requires a path"; home=$2; shift 2 ;;
      --home=*) home=${1#--home=}; shift ;;
      --runner) [ "$#" -gt 1 ] || die "--runner requires a path"; runner=$2; shift 2 ;;
      --runner=*) runner=${1#--runner=}; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ "${#args[@]}" -ge 1 ] || { usage >&2; exit 2; }
  case "${args[0]}" in
    status) cmd_status "$home" ;;
    print) cmd_print "$home" ;;
    install)
      [ -x "$home/bin/fm-mem-alert.sh" ] || die "alert executable missing: $home/bin/fm-mem-alert.sh"
      install_earlyoom
      install_timer "$home"
      install_config "$home" "$runner"
      ;;
    install-config) install_config "$home" "$runner" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
