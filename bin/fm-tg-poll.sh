#!/usr/bin/env bash
# One sweep of the local phone-inbox pending directory for Telegram notes that
# have not yet been offered to firstmate.
#
# Inert by default: a HARD no-op (exit 0, no output) unless Telegram mode is
# opted in via the flag file config/telegram-mode in this home. The watcher
# invokes this trusted repository script directly only after
# state/tg-watch.check.sh matches the expected byte-static identity shim.
# Its contract is "output => wake firstmate, silence => keep sleeping", so the
# no-op keeps the watcher behaving exactly as today until a user opts in.
#
# Behavior when Telegram mode is on:
#   no pending notes                  -> print nothing, exit 0 (no wake)
#   missing phone inbox root          -> print one rate-limited diagnostic
#                                        ("tg-mode-error ...")
#   a pending note not yet offered    -> atomically claim a durable offered
#       marker at state/tg-offered/<id> and include the id in one compact line
#       "tg-message <id> [<id>...]" (which becomes the watcher wake payload)
#   an already offered pending note   -> print nothing, unless its marker is
#       older than FMTG_REOFFER_SECS (default 1800): a firstmate that died
#       between wake and claim then gets the note re-offered, so an unclaimed
#       note self-heals instead of waiting forever
#   a marker whose note left pending  -> marker pruned; a claimed or archived
#       note is owned by the fmtg-respond flow from that point on
#
# The wake payload carries note IDS ONLY. Note bodies are untrusted phone text,
# and pending FILENAMES embed the body as a slug, so neither may ever appear in
# output; fmtg-respond reads the body through the phone-inbox `inbox claim`
# command at act time.
#
# No network, no token, no subprocesses into the phone-inbox project: this
# reads only the local pending directory. PHONE_INBOX_ROOT overrides the
# default ~/.claude/inbox (e.g. for tests); FMTG_NOW_OVERRIDE keeps tests
# deterministic.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-tg-lib.sh
. "$SCRIPT_DIR/fm-tg-lib.sh"

# Hard no-op when Telegram mode is off: this is what keeps the check shim inert.
fmtg_enabled "$FM_HOME" || exit 0

# Dedupe records live in their own directory rather than directly under $STATE:
# the private-artifact helpers demand a 0700 directory identity, and a home's
# state/ is created under the ambient umask, so publishing into it would fail
# and re-emit the same diagnostic on every 30s poll forever.
ERROR_DIR="$STATE/tg-poll"

emit_error_once() {
  local base=$1 msg=$2
  if fmx_private_artifact_file_valid "$ERROR_DIR" "$base" 600 \
    && [ "$(cat "$ERROR_DIR/$base" 2>/dev/null)" = "$msg" ]; then
    return 0
  fi
  printf '%s\n' "$msg" \
    | fmx_private_artifact_publish_stdin "$ERROR_DIR" "$base" 600 2>/dev/null || true
  printf 'tg-mode-error %s\n' "$msg"
}

clear_error() {
  local base=$1
  fmx_private_artifact_dir_device "$ERROR_DIR" >/dev/null 2>&1 || return 0
  rm -f "$ERROR_DIR/$base" 2>/dev/null || true
}

INBOX_ROOT=$(fmtg_inbox_root)
if [ ! -d "$INBOX_ROOT" ] || [ -L "$INBOX_ROOT" ]; then
  emit_error_once error "missing phone inbox at $INBOX_ROOT"
  exit 0
fi
clear_error error

PENDING="$INBOX_ROOT/pending"
OFFERED="$STATE/tg-offered"
NOW=${FMTG_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) exit 0 ;;
esac
REOFFER=${FMTG_REOFFER_SECS:-1800}
case "$REOFFER" in
  ''|*[!0-9]*) REOFFER=1800 ;;
esac

PENDING_IDS=$(fmtg_pending_ids "$PENDING")

pending_has() {
  printf '%s\n' "$PENDING_IDS" | grep -qx "$1"
}

# Prune markers for notes that left pending (claimed by fmtg-respond or
# archived). This bounds marker retention naturally: a marker lives exactly as
# long as its note is pending.
if [ -d "$OFFERED" ] && [ ! -L "$OFFERED" ]; then
  for marker in "$OFFERED"/*; do
    [ -e "$marker" ] || continue
    mid=${marker##*/}
    case "$mid" in
      ''|*[!0-9]*) continue ;;
    esac
    pending_has "$mid" || rm -f -- "$marker" 2>/dev/null || true
  done
fi

WAKE_IDS=
claim_failed=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if fmx_private_artifact_file_valid "$OFFERED" "$id" 600; then
    # Already offered: silent while fresh; re-offer when the marker has aged
    # past the re-offer window without the note being claimed.
    mtime=$(fmtg_stat_mtime "$OFFERED/$id") || continue
    [ -n "$mtime" ] || continue
    age=$((NOW - mtime))
    [ "$age" -ge "$REOFFER" ] || continue
    if printf '%s\n' "$NOW" \
      | fmx_private_artifact_publish_stdin "$OFFERED" "$id" 600 2>/dev/null; then
      WAKE_IDS="$WAKE_IDS $id"
    else
      claim_failed=1
    fi
    continue
  fi
  if [ -e "$OFFERED/$id" ] || [ -L "$OFFERED/$id" ]; then
    # A marker path that is not a valid private artifact is tampering, not a
    # normal state; surface it once and never emit around it.
    claim_failed=1
    continue
  fi
  printf '%s\n' "$NOW" \
    | fmx_private_artifact_publish_stdin_once "$OFFERED" "$id" 600 2>/dev/null
  rc=$?
  case "$rc" in
    0) WAKE_IDS="$WAKE_IDS $id" ;;
    1) : ;;
    *) claim_failed=1 ;;
  esac
done <<EOF
$PENDING_IDS
EOF

if [ "$claim_failed" -eq 1 ]; then
  emit_error_once claim-error "cannot record note offer"
else
  clear_error claim-error
fi

[ -n "$WAKE_IDS" ] || exit 0
printf 'tg-message%s\n' "$WAKE_IDS"
