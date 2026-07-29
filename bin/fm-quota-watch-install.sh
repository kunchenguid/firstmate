#!/usr/bin/env bash
# fm-quota-watch-install.sh - print (default) or install the OS-scheduler entry
# that runs bin/fm-quota-watch.sh periodically. See docs/quota-watch.md.
#
# This is entirely opt-in: merging or pulling firstmate never runs this script,
# and by default it only PRINTS what it would do. Nothing here starts a cron job
# or launchd agent on its own; the captain (or whoever has shell access to this
# machine) reviews the output and, on a separate deliberate step, either pastes
# it into their own crontab, passes --install-crontab, or saves the launchd
# plist and loads it with launchctl.
#
# Usage:
#   fm-quota-watch-install.sh                       print a crontab line (default)
#   fm-quota-watch-install.sh --launchd             print a launchd plist instead
#   fm-quota-watch-install.sh --install-crontab     append the crontab line for
#                                                    the current user (idempotent:
#                                                    refuses if already present)
#   fm-quota-watch-install.sh --interval-minutes N  cadence (default 5)
#   fm-quota-watch-install.sh --help
#
# The printed command resolves `quota-axi`, `jq`, and every session-backend CLI
# fm-send.sh might dispatch through (tmux, herdr, zellij, cmux - whichever are
# actually installed) to absolute paths at generation time and bakes their
# directories into an explicit PATH, because cron and launchd both run with a
# minimal PATH that will not see a Node version manager's install directory or
# a Homebrew-installed backend CLI. quota-axi and jq are required (the script
# cannot read quota or parse it without them); a backend CLI is optional and
# simply omitted if not found, since which backend(s) are actually in use can
# change over time and any installed one might be needed by a live crewmate.
# Every resolved binary is then re-checked against the generated PATH with a
# scrubbed environment before printing, so a stale or inconsistent PATH is
# caught here instead of failing silently on every cron firing (the exact
# production failure this script now guards against: quota-axi resolved fine
# so quota reading kept working, while herdr did not, so every interrupt/resume
# send failed silently until diagnosed live). If any of these move (a new Node
# version, a reinstall, a newly installed backend), regenerate the line rather
# than hand-editing the stale path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

fm_quota_install_usage() {
  sed -n '2,37{s/^# \{0,1\}//;p;}' "$SCRIPT_DIR/fm-quota-watch-install.sh"
}

MODE=crontab-print
INTERVAL=5
while [ "$#" -gt 0 ]; do
  case "$1" in
    --launchd) MODE=launchd-print; shift ;;
    --install-crontab) MODE=crontab-install; shift ;;
    --interval-minutes)
      [ "$#" -ge 2 ] || { echo "fm-quota-watch-install.sh: --interval-minutes requires a value" >&2; exit 2; }
      INTERVAL=$2
      shift 2
      ;;
    --help|-h) fm_quota_install_usage; exit 0 ;;
    *) echo "fm-quota-watch-install.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done
case "$INTERVAL" in
  ''|*[!0-9]*|0) echo "fm-quota-watch-install.sh: --interval-minutes must be a positive integer, got '$INTERVAL'" >&2; exit 2 ;;
esac

# Space-separated, order-preserving, de-duplicated directory list. Args are
# candidate directories (possibly empty/duplicate); each non-empty, not-yet-seen
# one is appended.
fm_quota_install_add_dir() {  # <dir>
  local d=$1 existing
  [ -n "$d" ] || return 0
  for existing in $RESOLVED_DIRS; do
    [ "$existing" != "$d" ] || return 0
  done
  RESOLVED_DIRS="${RESOLVED_DIRS:+$RESOLVED_DIRS }$d"
}

RESOLVED_DIRS=""
RESOLVED_BINS=""

if ! QUOTA_AXI_BIN=$(command -v quota-axi 2>/dev/null); then
  echo "fm-quota-watch-install.sh: quota-axi not found on PATH; install/authenticate it first (quota-axi --allow-keychain-prompt), then rerun" >&2
  exit 1
fi
fm_quota_install_add_dir "$(dirname "$QUOTA_AXI_BIN")"
RESOLVED_BINS="quota-axi"

if ! JQ_BIN=$(command -v jq 2>/dev/null); then
  echo "fm-quota-watch-install.sh: jq not found on PATH; install it first, then rerun" >&2
  exit 1
fi
fm_quota_install_add_dir "$(dirname "$JQ_BIN")"
RESOLVED_BINS="$RESOLVED_BINS jq"

# Optional session-backend CLIs fm-send.sh may dispatch through. Each is
# included only if actually installed; a missing one is silently skipped here
# (its absence is only a real problem if that backend is genuinely in use, and
# fm-send.sh already reports that loudly at send time).
for backend_bin in tmux herdr zellij cmux; do
  if bin_path=$(command -v "$backend_bin" 2>/dev/null); then
    fm_quota_install_add_dir "$(dirname "$bin_path")"
    RESOLVED_BINS="$RESOLVED_BINS $backend_bin"
  fi
done

WATCH_BIN="$SCRIPT_DIR/fm-quota-watch.sh"
LOG_FILE="$FM_HOME/state/quota-watch.log"
CRON_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
for d in $RESOLVED_DIRS; do
  CRON_PATH="$CRON_PATH:$d"
done

# Prove the generated PATH actually resolves every binary just resolved above,
# in a scrubbed environment matching what cron/launchd hand the script - this
# is the exact class of bug a captain hit in production (quota-axi resolved so
# reading always worked, herdr did not so every send silently failed).
for b in $RESOLVED_BINS; do
  # shellcheck disable=SC2016 # intentional: $1 expands in the inner sh -c, not here.
  if ! env -i PATH="$CRON_PATH" sh -c 'command -v "$1"' _ "$b" >/dev/null 2>&1; then
    echo "fm-quota-watch-install.sh: internal error: '$b' resolved during generation but not through the generated PATH ('$CRON_PATH'); refusing to print a broken entry" >&2
    exit 1
  fi
done
echo "fm-quota-watch-install.sh: PATH will include: $RESOLVED_BINS" >&2

CRON_LINE="*/$INTERVAL * * * * PATH=\"$CRON_PATH\" FM_HOME=\"$FM_HOME\" \"$WATCH_BIN\" >> \"$LOG_FILE\" 2>&1"

case "$MODE" in
  crontab-print)
    cat <<EOF
# Add this line with 'crontab -e' (see docs/quota-watch.md for the full story):
$CRON_LINE
EOF
    ;;
  crontab-install)
    if crontab -l 2>/dev/null | grep -qF "$WATCH_BIN"; then
      echo "fm-quota-watch-install.sh: a crontab entry already references $WATCH_BIN; leaving it unchanged" >&2
      exit 0
    fi
    { crontab -l 2>/dev/null || true; printf '%s\n' "$CRON_LINE"; } | crontab -
    echo "fm-quota-watch-install.sh: installed crontab entry (every $INTERVAL minute(s))"
    echo "$CRON_LINE"
    ;;
  launchd-print)
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.firstmate.quota-watch</string>
  <key>ProgramArguments</key>
  <array>
    <string>$WATCH_BIN</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$CRON_PATH</string>
    <key>FM_HOME</key>
    <string>$FM_HOME</string>
  </dict>
  <key>StartInterval</key>
  <integer>$((INTERVAL * 60))</integer>
  <key>StandardOutPath</key>
  <string>$LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$LOG_FILE</string>
</dict>
</plist>
EOF
    echo "# Save as ~/Library/LaunchAgents/io.firstmate.quota-watch.plist, then:" >&2
    echo "#   launchctl load ~/Library/LaunchAgents/io.firstmate.quota-watch.plist" >&2
    ;;
esac
