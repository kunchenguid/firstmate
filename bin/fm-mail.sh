#!/usr/bin/env bash
# fm-mail.sh - general-purpose mail plane for reading and sending mail.
#
# Reads inbound mail over IMAP and sends mail over SMTP on demand. This is an
# ordinary mail client surface, not an escalation of authority: every surfaced
# message is a notification firstmate reads before deciding, and firstmate still
# applies its own judgment exactly as it would for a TUI message (including
# return/away and other rules).
#
# Subcommands:
#   read                 List unseen INBOX mail as a compact digest (From /
#                        Date / Subject / first line).
#   send <to> <subject> <body | ->
#                        Send one message. A "-" body reads plain text from
#                        stdin.
#   poll                 Surface NEW unseen mail as a `check` wake so firstmate
#                        answers it concisely. Only UNSEEN mail newer than the
#                        last poll is surfaced; already-read mail never wakes a
#                        poll, no message is ever marked read (BODY.PEEK), and
#                        every surfaced message is keyed by its immutable IMAP
#                        UID so expunge renumbering never re-wakes or loses
#                        mail. The cursor also records the mailbox generation
#                        (UIDVALIDITY) so a recreated mailbox cannot reuse a
#                        numeric uid and suppress a new wake, and overlapping
#                        polls are serialized so the same mail is never
#                        double-surfaced. poll itself has no scheduler: run it
#                        manually, from `at`/cron, or via the standing check
#                        armed by bin/fm-mail-check.sh (docs/configuration.md
#                        "Mail plane").
#   status               Print configuration and the last poll cursor. No
#                        network, no wake.
#
# Volume: poll surfaces at most FM_MAIL_POLL_MAX_WAKES messages per run
# (default 20, valid 1..200); a larger flood is left unseen so the next poll
# surfaces the next batch, keeping the durable wake queue bounded no matter how
# much inbound mail arrives.
#
# Deployment - credentials and endpoints live ONLY in the gitignored
# $FM_HOME/.env (same convention as the Relay/FMX token). Add these four
# required values, plus the optional ports:
#   FM_MAIL_USER=<imap/smtp account>
#   FM_MAIL_PASS=<password>
#   FM_IMAP_HOST=<imap host>
#   FM_IMAP_PORT=<imap port>     (default 993)
#   FM_SMTP_HOST=<smtp host>
#   FM_SMTP_PORT=<smtp port>     (default 465)
# FM_HOME falls back to the repo root when unset. This script carries no secret
# and no default endpoint that could resolve against a wrong home; the four
# FM_MAIL_* credential and endpoint values are always required, and
# FM_MAIL_PASS is never logged.
#
# IMAP/SMTP work is delegated to bin/fm-mail.py (imaplib/smtplib, in-process
# TLS). BODY.PEEK is used on read/poll so mail is never marked seen before
# firstmate actually answers it.

set -euo pipefail

# --- resolve home, env, and endpoints -------------------------------------
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
ENV_FILE="$FM_HOME/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

for r in FM_MAIL_USER FM_MAIL_PASS FM_IMAP_HOST FM_SMTP_HOST; do
  if [ -z "${!r:-}" ]; then
    echo "fm-mail: missing required \$FM_HOME/.env value: $r" >&2
    echo "fm-mail: add $r (and the other three FM_MAIL_* values) to $ENV_FILE" >&2
    exit 1
  fi
done
IMAP_HOST="$FM_IMAP_HOST"
IMAP_PORT="${FM_IMAP_PORT:-993}"
SMTP_HOST="$FM_SMTP_HOST"
SMTP_PORT="${FM_SMTP_PORT:-465}"
MAIL_MAX_WAKES="${FM_MAIL_POLL_MAX_WAKES:-20}"
case "$MAIL_MAX_WAKES" in
  ''|*[!0-9]*|0) MAIL_MAX_WAKES=20 ;;
esac
if [ "$MAIL_MAX_WAKES" -gt 200 ]; then
  MAIL_MAX_WAKES=200
fi

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-mail: python3 required" >&2
  exit 1
fi
PY_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-mail.py"
if [ ! -f "$PY_BIN" ]; then
  echo "fm-mail: $PY_BIN missing" >&2
  exit 1
fi

STATE_DIR="$FM_HOME/state"
mkdir -p "$STATE_DIR"
CURSOR="$STATE_DIR/.mail-seen"
# Durable emission journal: every successfully published poll wake records its
# uid here under the queue lock, immediately after the wake row is appended and
# before the cursor records it. A journal entry therefore always proves a wake
# was published, so a mail is never silently suppressed. The fleet wake drain
# acknowledges and removes consumed wake rows from its own queue, so the queue
# alone cannot prove that a wake was ever emitted after an ack; this journal is
# fm-mail's own record of emission and survives any drain ack, which makes
# recovery exactly-once instead of racing the drain.
WOKEN="$STATE_DIR/.mail-woken"

# Invoke the python engine with the resolved endpoints, cursor, and cap in the
# environment so credentials never reach argv.
run_py() {
  FM_MAIL_USER="$FM_MAIL_USER" FM_MAIL_PASS="$FM_MAIL_PASS" \
  FM_IMAP_HOST="$IMAP_HOST" FM_IMAP_PORT="$IMAP_PORT" \
  FM_SMTP_HOST="$SMTP_HOST" FM_SMTP_PORT="$SMTP_PORT" \
  FM_MAIL_CURSOR="$CURSOR" FM_MAIL_POLL_MAX_WAKES="$MAIL_MAX_WAKES" \
    "$PY" "$PY_BIN" "$@"
}

usage() {
  cat <<'EOF'
fm-mail.sh read
fm-mail.sh send <to> <subject> <body | ->
fm-mail.sh poll
fm-mail.sh status
EOF
}

mail_seen() {
  # $1 = uid; returns 0 when the cursor already records the uid as surfaced.
  grep -Fqx "$1" "$CURSOR"
}

mail_record_evidence() {
  # Write the journal and cursor records; return 0 when at least one landed.
  # At least one must survive with a queued wake row, or the drain could
  # acknowledge the wake with no durable record of its uid.
  local generation=$1 id=$2 journal_ok=0 cursor_ok=0
  printf '%s\t%s\n' "$generation" "$id" >> "$WOKEN" && journal_ok=1 || true
  printf '%s\n' "$id" >> "$CURSOR" && cursor_ok=1 || true
  if [ "$journal_ok" -eq 1 ] || [ "$cursor_ok" -eq 1 ]; then
    return 0
  fi
  return 1
}

fm_mail_rollback_wake_locked() {
  # Remove a just-appended wake row plus any partial journal/cursor evidence.
  # Runs under the held FM_WAKE_QUEUE_LOCK, so the rewrite cannot race an
  # acknowledgement; failure means the poll already fails closed so the next
  # poll's queue heal still reconciles any residual row.
  local wake_key=$1 generation=$2 id=$3 clean_key tmp queue_status=0
  clean_key=$(printf '%s' "$wake_key" | fm_wake_clean_field)
  tmp=$(mktemp "$FM_WAKE_QUEUE.rollback.XXXXXX") || return 1
  awk -F '\t' -v key="$clean_key" '
    NF >= 5 && $3 == "check" && $4 == key { next }
    { print }
  ' "$FM_WAKE_QUEUE" > "$tmp" || queue_status=$?
  if [ -n "$queue_status" ] && [ "$queue_status" -ne 0 ]; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$FM_WAKE_QUEUE" || {
    rm -f -- "$tmp"
    return 1
  }
  if awk -F '\t' -v g="$generation" -v i="$id" \
      '!($1 == g && $2 == i)' "$WOKEN" > "$WOKEN.tmp.$$" 2>/dev/null; then
    if mv -f -- "$WOKEN.tmp.$$" "$WOKEN" 2>/dev/null; then
      :
    fi
  fi
  rm -f -- "$WOKEN.tmp.$$"
  if grep -vx -e "$id" "$CURSOR" > "$CURSOR.tmp.$$" 2>/dev/null; then
    if mv -f -- "$CURSOR.tmp.$$" "$CURSOR" 2>/dev/null; then
      :
    fi
  fi
  rm -f -- "$CURSOR.tmp.$$"
  return 0
}

wake_for() {
  # Publish one `check` wake and its durable records under a single held
  # FM_WAKE_QUEUE_LOCK. The key is generation-aware when the mailbox reports a
  # UIDVALIDITY, so a restored mailbox's reused uid can never collide with a
  # stale wake key. The wake row is appended first, then the evidence records;
  # the drain acknowledges and deletes consumed rows only under the same lock,
  # so it can never remove our wake between the surface and the uid record.
  # A journal entry therefore always means the wake was published - a mail is
  # never silently suppressed. If no durable record can be written the row is
  # rolled back for a clean retry, and only when the journal, the cursor, and
  # the queue rewrite all fail does the poll fail closed, accepting a possible
  # duplicate over a lost mail.
  local generation=$1 id=$2 summary=$3 lib="$FM_HOME/bin/fm-wake-lib.sh" status=0
  local wake_key="mail:$id"
  if [ -n "$generation" ]; then
    wake_key="mail:$generation/$id"
  fi
  if [ ! -f "$lib" ]; then
    echo "fm-mail: $lib missing; cannot wake" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$lib"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if fm_wake_append_locked check "$wake_key" "check: mail $id - $summary"; then
    if mail_record_evidence "$generation" "$id"; then
      :
    elif fm_mail_rollback_wake_locked "$wake_key" "$generation" "$id"; then
      echo "fm-mail: wake for $id rolled back (journal and cursor writes failed); retried on next poll" >&2
      status=1
    elif mail_record_evidence "$generation" "$id"; then
      echo "fm-mail: wake for $id durably recorded after the queue rewrite failed" >&2
    else
      echo "fm-mail: wake for $id could not be rolled back or durably recorded; the wake stays queued and the next poll heals it - a possible duplicate, never a lost mail" >&2
      status=1
    fi
  else
    status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

mail_stored_generation() {
  # Print the mailbox generation the local cursor was last reset to, or "".
  local u gen=""
  [ -f "$CURSOR" ] || : > "$CURSOR"
  while IFS= read -r u; do
    case "$u" in
      "uidvalidity="*) gen="${u#uidvalidity=}" ;;
    esac
  done < "$CURSOR"
  printf '%s' "$gen"
}

mail_heal() {
  # Reconcile a poll interrupted between its operations. Emission is a
  # three-phase commit: the wake append publishes the surfacing, the journal
  # write then proves THIS home emitted it, and the cursor record finally
  # declares the uid surfaced. Each phase is healed from durable evidence:
  #
  # 1. Journal heal - a journal entry is proof a wake was published, written
  #    immediately after a successful wake append under the same lock. It
  #    survives the fleet drain's ack (which physically removes consumed wake
  #    rows from the queue), so a poll killed after appending its wake but
  #    before recording the uid is recovered even when the drain already
  #    acknowledged that wake: the uid is recorded without re-waking, never
  #    duplicate.
  # 2. Queue heal - a queued wake whose uid is absent from the cursor (kill in
  #    the tiny gap between wake append and journal write) is likewise recorded
  #    without re-waking.
  # Both are generation-scoped: only evidence matching the CURRENT mailbox
  # generation is healed, so a legacy key or a stale prior-generation wake can
  # never mark a reused numeric uid as surfaced in the new mailbox.
  local generation=$1 jgen juid keyrest keygen keyuid
  if [ -s "$WOKEN" ]; then
    while IFS=$'\t' read -r jgen juid; do
      [ -n "$juid" ] || continue
      [ "$jgen" != "$generation" ] && continue
      if ! mail_seen "$juid"; then
        printf '%s\n' "$juid" >> "$CURSOR"
      fi
    done < "$WOKEN"
    : > "$WOKEN"
  fi
  while IFS= read -r k; do
    keyrest="${k#mail:}"
    [ "$keyrest" = "$k" ] && continue
    keygen=""
    keyuid=""
    case "$keyrest" in
      */*) keygen="${keyrest%%/*}"; keyuid="${keyrest#*/}" ;;
      *) keyuid="$keyrest" ;;
    esac
    [ -z "$keyuid" ] && continue
    [ "$keygen" != "$generation" ] && continue
    if ! mail_seen "$keyuid"; then
      printf '%s\n' "$keyuid" >> "$CURSOR"
    fi
  done < <(fm_wake_queued_keys check 2>/dev/null || true)
}

mail_poll() {
  # List unseen mail (uid,date,from,subj) plus the mailbox generation guard,
  # then diff against already-surfaced uids to find NEW messages and surface
  # one wake each. Never marks anything read. Overlapping polls are serialized
  # on the mail-seen lock; each poll first heals a run interrupted between its
  # phases (mail_heal), so an overlapping poll or an interrupted run can never
  # lose a mail or double-surface it.
  local list generation line uid fr subj woke=0
  if [ ! -f "$FM_HOME/bin/fm-wake-lib.sh" ]; then
    echo "fm-mail: $FM_HOME/bin/fm-wake-lib.sh missing; cannot poll" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "$FM_HOME/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$STATE_DIR/.mail-seen.lock"
  list="$(run_py poll_list)"
  generation="$(printf '%s\n' "$list" | head -n1 | cut -f2)"
  list="$(printf '%s\n' "$list" | tail -n +2)"

  # A recreated/restored mailbox has a new UIDVALIDITY; a numeric uid can be
  # reused, so a stale cursor must not suppress its wake. Journal entries from
  # the old mailbox are equally stale: they describe wakes from before the
  # mailbox identity changed, so clear them rather than risk healing a reused
  # uid into the new generation.
  if [ -n "$generation" ] && [ "$(mail_stored_generation)" != "$generation" ]; then
    printf 'uidvalidity=%s\n' "$generation" > "$CURSOR"
    : > "$WOKEN"
  fi

  mail_heal "$generation"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    uid="$(printf '%s' "$line" | cut -f1)"
    fr="$(printf '%s' "$line" | cut -f3)"
    subj="$(printf '%s' "$line" | cut -f4)"
    if ! mail_seen "$uid"; then
      # Wake first, then record: the wake append, journal, and cursor commit
      # together under the wake-queue lock inside wake_for (so no drain ack can
      # split them), and a failure stops the poll so the next run retries. A
      # kill before the append leaves nothing and the next poll retries; a kill
      # after the append is healed above without re-waking.
      # Reaching the per-poll wake cap stops the loop: the remaining unseen
      # mail stays out of the cursor and surfaces on the next poll, so a flood
      # bounds the durable wake queue instead of flooding firstmate.
      if [ "$woke" -ge "$MAIL_MAX_WAKES" ]; then
        echo "fm-mail: per-poll wake cap ($MAIL_MAX_WAKES) reached; remaining mail surfaces on the next poll" >&2
        break
      fi
      if wake_for "$generation" "$uid" "mail from $fr - ${subj:-no subject}"; then
        echo "fm-mail: woke for $uid"
        woke=$((woke + 1))
      else
        echo "fm-mail: wake failed for $uid; retried on next poll" >&2
        fm_lock_release "$STATE_DIR/.mail-seen.lock"
        return 1
      fi
    fi
  done <<< "$list"
  fm_lock_release "$STATE_DIR/.mail-seen.lock"
  if [ "$woke" -eq 0 ]; then
    echo "fm-mail: no new mail"
  fi
  return 0
}

case "${1:-}" in
  read)
    run_py read
    ;;
  send)
    to="${2:-}"
    subj="${3:-}"
    body="${4:--}"
    if [ -z "$to" ] || [ -z "$subj" ]; then
      usage
      exit 1
    fi
    if [ "$body" = "-" ]; then
      body="$(cat)"
    fi
    printf '%s' "$body" | run_py send "$to" "$subj" "-"
    ;;
  status)
    echo "mail account: $FM_MAIL_USER"
    echo "imap: $IMAP_HOST:$IMAP_PORT smtp: $SMTP_HOST:$SMTP_PORT"
    run_py seen "$CURSOR" || true
    ;;
  poll)
    mail_poll
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac