#!/usr/bin/env bash
# Install the Firstmate deadman as stable copies outside the git checkout.
#
# The installer atomically replaces individual installed files, writes the
# LaunchAgent plist, and sends a mandatory canary notification. It bootstraps
# launchd only when --bootstrap is explicit and only after that canary succeeds.
# It never starts, stops, or repairs Firstmate fleet processes.
#
# Usage:
#   fm-deadman-install.sh [--fm-home PATH] [--channel DIRECTIVE]... [--bootstrap]
#   fm-deadman-install.sh --uninstall
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_PROBE="$SCRIPT_DIR/fm-deadman.sh"
SOURCE_NOTIFY="$SCRIPT_DIR/fm-notify-lib.sh"
TEMPLATE="$SCRIPT_DIR/launchd/com.firstmate.deadman.plist.template"
INSTALL_DIR=${FM_DEADMAN_INSTALL_DIR:-$HOME/Library/Application Support/Firstmate/deadman}
PLIST=${FM_DEADMAN_PLIST:-$HOME/Library/LaunchAgents/com.firstmate.deadman.plist}
FM_HOME_VALUE=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME_EXPLICIT=0
BOOTSTRAP=0
UNINSTALL=0
CHANNELS=()

usage() {
  sed -n '2,13{s/^# \{0,1\}//;p;}' "$0" >&2
}

atomic_install() {
  local source=$1 target=$2 mode=$3 tmp
  tmp="$target.tmp.$$"
  install -m "$mode" "$source" "$tmp"
  mv -f "$tmp" "$target"
}

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\\&apos;/g"
}

sed_replacement() {
  sed -e 's/[\\&|]/\\&/g'
}

write_plist() {
  local script stdout_log stderr_log path_value tmp
  script=$(printf '%s' "$INSTALL_DIR/fm-deadman.sh" | xml_escape | sed_replacement)
  stdout_log=$(printf '%s' "$INSTALL_DIR/deadman.stdout.log" | xml_escape | sed_replacement)
  stderr_log=$(printf '%s' "$INSTALL_DIR/deadman.stderr.log" | xml_escape | sed_replacement)
  path_value=$(printf '%s' "${PATH-}" | xml_escape | sed_replacement)
  tmp="$PLIST.tmp.$$"
  sed -e "s|__DEADMAN_SCRIPT__|$script|g" \
    -e "s|__STDOUT_LOG__|$stdout_log|g" \
    -e "s|__STDERR_LOG__|$stderr_log|g" \
    -e "s|__PATH__|$path_value|g" "$TEMPLATE" > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$PLIST"
}

write_config() {
  local line found=0 tmp="$INSTALL_DIR/deadman.env.tmp.$$"
  if [ -f "$INSTALL_DIR/deadman.env" ] && [ "$FM_HOME_EXPLICIT" -eq 0 ]; then
    return 0
  fi
  (umask 077
    if [ -f "$INSTALL_DIR/deadman.env" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          FM_HOME=*)
            if [ "$found" -eq 0 ]; then
              printf 'FM_HOME=%s\n' "$FM_HOME_VALUE"
              found=1
            fi
            ;;
          *) printf '%s\n' "$line" ;;
        esac
      done < "$INSTALL_DIR/deadman.env"
      [ "$found" -eq 1 ] || printf 'FM_HOME=%s\n' "$FM_HOME_VALUE"
    else
      printf 'FM_HOME=%s\n' "$FM_HOME_VALUE"
      printf 'STALE_AFTER_SECS=600\n'
      printf 'SAMPLE_GAP_SECS=60\n'
      printf 'SAMPLE_MAX_GAP_SECS=120\n'
      printf 'FIRST_ARM_GRACE_SECS=660\n'
      printf 'WAKE_GRACE_SECS=300\n'
      printf 'SLEEP_GAP_DETECT_SECS=180\n'
      printf 'COOLDOWN_SECS=1800\n'
    fi > "$tmp")
  mv -f "$tmp" "$INSTALL_DIR/deadman.env"
}

write_channels() {
  local channel tmp="$INSTALL_DIR/deadman.conf.tmp.$$"
  if [ "${#CHANNELS[@]}" -eq 0 ] && [ -f "$INSTALL_DIR/deadman.conf" ]; then
    return 0
  fi
  (umask 077
    if [ "${#CHANNELS[@]}" -eq 0 ]; then
      printf 'auto\n'
    else
      for channel in "${CHANNELS[@]}"; do
        printf '%s\n' "$channel"
      done
    fi > "$tmp")
  mv -f "$tmp" "$INSTALL_DIR/deadman.conf"
}

uninstall_deadman() {
  launchctl bootout "gui/$UID/com.firstmate.deadman" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  rm -f "$INSTALL_DIR/fm-deadman.sh" "$INSTALL_DIR/fm-notify-lib.sh"
  rm -f "$INSTALL_DIR/deadman.env" "$INSTALL_DIR/deadman.conf"
  rm -f "$INSTALL_DIR/installed-at" "$INSTALL_DIR/armed" "$INSTALL_DIR/first-stale"
  rm -f "$INSTALL_DIR/last-run-at" "$INSTALL_DIR/wake-grace-until" "$INSTALL_DIR/last-success-at"
  rm -f "$INSTALL_DIR/deadman.journal" "$INSTALL_DIR/deadman.stdout.log" "$INSTALL_DIR/deadman.stderr.log"
  rmdir "$INSTALL_DIR/.probe.lock" 2>/dev/null || true
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  printf 'Uninstalled com.firstmate.deadman.\n'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fm-home)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      FM_HOME_VALUE=$2
      FM_HOME_EXPLICIT=1
      shift 2
      ;;
    --channel)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      CHANNELS+=("$2")
      shift 2
      ;;
    --bootstrap) BOOTSTRAP=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [ "$UNINSTALL" -eq 1 ]; then
  [ "$BOOTSTRAP" -eq 0 ] && [ "${#CHANNELS[@]}" -eq 0 ] || { usage; exit 2; }
  uninstall_deadman
  exit 0
fi

case "$FM_HOME_VALUE" in /*) ;; *) printf 'fm-deadman-install: FM_HOME must be absolute.\n' >&2; exit 2 ;; esac
case "$FM_HOME_VALUE" in *$'\n'*|*$'\r'*) printf 'fm-deadman-install: FM_HOME must be one line.\n' >&2; exit 2 ;; esac
if [ "${#CHANNELS[@]}" -gt 0 ]; then
  for channel in "${CHANNELS[@]}"; do
    case "$channel" in
      *$'\n'*|*$'\r'*|'') printf 'fm-deadman-install: each channel must be one non-empty line.\n' >&2; exit 2 ;;
      off|auto|default|osascript|herdr|command:*) ;;
      *) printf 'fm-deadman-install: unrecognized channel directive.\n' >&2; exit 2 ;;
    esac
  done
fi
[ -r "$SOURCE_PROBE" ] && [ -r "$SOURCE_NOTIFY" ] && [ -r "$TEMPLATE" ] || {
  printf 'fm-deadman-install: source files are incomplete.\n' >&2
  exit 2
}

mkdir -p "$INSTALL_DIR" "$(dirname "$PLIST")"
atomic_install "$SOURCE_PROBE" "$INSTALL_DIR/fm-deadman.sh" 755
atomic_install "$SOURCE_NOTIFY" "$INSTALL_DIR/fm-notify-lib.sh" 644
write_config
write_channels
[ -f "$INSTALL_DIR/installed-at" ] || (umask 077 && date +%s > "$INSTALL_DIR/installed-at")
write_plist
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST" >/dev/null
fi

printf 'Sending required deadman canary before launchd bootstrap...\n'
if ! "$INSTALL_DIR/fm-deadman.sh" --canary; then
  printf 'fm-deadman-install: canary delivery failed; LaunchAgent was not bootstrapped.\n' >&2
  exit 1
fi
printf 'Canary delivery succeeded.\n'

if [ "$BOOTSTRAP" -eq 1 ]; then
  launchctl bootout "gui/$UID/com.firstmate.deadman" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  printf 'Bootstrapped com.firstmate.deadman.\n'
else
  printf 'Installed but not bootstrapped. Re-run with --bootstrap after reviewing the canary.\n'
fi
