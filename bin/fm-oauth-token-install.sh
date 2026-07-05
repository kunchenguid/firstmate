#!/usr/bin/env bash
# Install, uninstall, or inspect the com.firstmate.oauth-token LaunchAgent that
# makes CLAUDE_CODE_OAUTH_TOKEN survive reboots on macOS by re-exporting it into
# the user's launchd session domain at every login.
#
# It renders the committed template at bin/launchd/com.firstmate.oauth-token.plist
# (which holds NO token, only a reference to bin/fm-oauth-token-load.sh) into
# ~/Library/LaunchAgents/ with the absolute path to this repo's bin/ and a
# per-user log directory substituted, loads it with launchctl, then runs the
# helper once so the token is set immediately without requiring a re-login.
# Re-running --install is idempotent: it unloads any prior copy first, rewrites
# the plist, and reloads it.
#
# The token itself is NEVER read, printed, or committed here; the helper reads it
# from the operator's secure source at run time (see fm-oauth-token-load.sh).
#
# Override paths for testing:
#   FM_USER_LAUNCHAGENTS_DIR  default ~/Library/LaunchAgents
#   FM_OAUTH_TOKEN_LOG_DIR    default ~/Library/Logs/firstmate
#   FM_LAUNCHCTL              default `launchctl`; the binary name used for every
#                            launchctl call, so the no-launchctl refusal path can
#                            be exercised without removing /usr/bin from PATH
# Usage: fm-oauth-token-install.sh [--install|--uninstall|--status|--help]
set -u

LABEL='com.firstmate.oauth-token'
PLIST_NAME="$LABEL.plist"
LAUNCHCTL="${FM_LAUNCHCTL:-launchctl}"

usage() {
  sed -n '2,/^# Usage:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_BIN="$SCRIPT_DIR"
TEMPLATE="$FM_ROOT/bin/launchd/$PLIST_NAME"
USER_AGENTS_DIR="${FM_USER_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
LOG_DIR="${FM_OAUTH_TOKEN_LOG_DIR:-$HOME/Library/Logs/firstmate}"
TARGET="$USER_AGENTS_DIR/$PLIST_NAME"

require_launchctl() {
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl not found (looked for $LAUNCHCTL); this installer is macOS-only" >&2; return 1; }
}

# render_plist: substitute @@FM_BIN@@ and @@FM_LOG_DIR@@ in the template and
# print the result. bash global substitution is used so path characters such as
# '&' are treated literally (no regex replacement semantics).
render_plist() {
  [ -f "$TEMPLATE" ] || { echo "error: missing plist template $TEMPLATE" >&2; return 1; }
  local content
  content=$(cat -- "$TEMPLATE") || return 1
  content=${content//@@FM_BIN@@/$FM_BIN}
  content=${content//@@FM_LOG_DIR@@/$LOG_DIR}
  printf '%s\n' "$content"
}

do_install() {
  require_launchctl || return 1
  [ -f "$TEMPLATE" ] || { echo "error: missing plist template $TEMPLATE" >&2; return 1; }
  [ -x "$FM_BIN/fm-oauth-token-load.sh" ] || { echo "error: helper $FM_BIN/fm-oauth-token-load.sh missing or not executable" >&2; return 1; }
  mkdir -p "$USER_AGENTS_DIR" "$LOG_DIR" || { echo "error: could not create $USER_AGENTS_DIR or $LOG_DIR" >&2; return 1; }
  # unload any prior copy so a stale registration does not linger.
  "$LAUNCHCTL" unload "$TARGET" 2>/dev/null || true
  render_plist > "$TARGET" || { echo "error: could not render plist to $TARGET" >&2; return 1; }
  if "$LAUNCHCTL" load -w "$TARGET" 2>/dev/null; then
    echo "oauth-token: installed and loaded $TARGET"
  else
    echo "oauth-token: wrote $TARGET but launchctl load failed; run '$LAUNCHCTL load -w $TARGET' manually" >&2
    return 1
  fi
  # set the token now so it is present without a re-login; a failure here is a
  # source problem, not an install problem, so warn but do not undo the install.
  "$FM_BIN/fm-oauth-token-load.sh" --setenv \
    || echo "oauth-token: helper --setenv failed on first run; check $LOG_DIR/oauth-token.err.log and your secure source" >&2
  echo "oauth-token: next login will re-export CLAUDE_CODE_OAUTH_TOKEN automatically"
  echo "oauth-token: rotate by updating your secure source and re-running --install, or reboot"
}

do_uninstall() {
  require_launchctl || return 1
  local removed=0
  if [ -f "$TARGET" ]; then
    "$LAUNCHCTL" unload -w "$TARGET" 2>/dev/null || true
    rm -f "$TARGET" && removed=1
  fi
  # best-effort: clear any stale registration left behind by a manually deleted
  # plist. `launchctl remove` takes the job label, not a path.
  "$LAUNCHCTL" remove "$LABEL" 2>/dev/null || true
  "$LAUNCHCTL" unsetenv CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
  if [ "$removed" = 1 ]; then
    echo "oauth-token: removed $TARGET and unset CLAUDE_CODE_OAUTH_TOKEN from the launchd user domain"
  else
    echo "oauth-token: nothing to remove; $TARGET was not present"
  fi
}

do_status() {
  require_launchctl || return 1
  echo "template:   $TEMPLATE"
  echo "installed:  $([ -f "$TARGET" ] && echo "$TARGET" || echo '(not installed)')"
  if [ -f "$TARGET" ]; then
    if grep -q '@@FM_BIN@@\|@@FM_LOG_DIR@@' "$TARGET"; then
      echo "render:     WARN - $TARGET still contains unsubstituted placeholders"
    else
      echo "render:     ok"
    fi
  fi
  if "$LAUNCHCTL" getenv CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null | grep -q .; then
    echo "launchd:    CLAUDE_CODE_OAUTH_TOKEN present in user domain"
  else
    echo "launchd:    CLAUDE_CODE_OAUTH_TOKEN absent from user domain"
  fi
  if "$FM_BIN/fm-oauth-token-load.sh" --print >/dev/null 2>&1; then
    echo "source:     resolvable"
  else
    echo "source:     not resolvable (populate your secure source or set config/oauth-token-source)"
  fi
}

case "${1:---install}" in
  --install)   do_install ;;
  --uninstall) do_uninstall ;;
  --status)    do_status ;;
  -h|--help)   usage; exit 0 ;;
  *) echo "usage: fm-oauth-token-install.sh [--install|--uninstall|--status|--help]" >&2; exit 2 ;;
esac
