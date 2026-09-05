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
# IMAP/SMTP work is delegated to python3 (imaplib/smtplib, in-process TLS).
# BODY.PEEK is used on read/poll so mail is never marked seen before firstmate
# actually answers it.

set -euo pipefail

# --- resolve home and env -------------------------------------------------
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

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-mail: python3 required" >&2
  exit 1
fi

STATE_DIR="$FM_HOME/state"
mkdir -p "$STATE_DIR"
CURSOR="$STATE_DIR/.mail-seen"
# Durable emission journal: every poll wake records its uid here under the
# queue lock, BEFORE the wake row is published, so an ackable wake always has a
# durable record already written. The fleet wake drain acknowledges and removes
# consumed wake rows from its own queue, so the queue alone cannot prove that a
# wake was ever emitted after an ack; this journal is fm-mail's own record of
# emission and survives any drain ack, which makes recovery exactly-once
# instead of racing the drain.
WOKEN="$STATE_DIR/.mail-woken"

# Delegate IMAP/SMTP to python3 (in-core TLS + mime, no shell byte-juggling).
# Write the script to a temp file so stdin stays free for piping body data
# through the pipe from the caller (e.g. send body via printf | run_py).
run_py() {
  local py_script rc=0
  py_script="$(mktemp)"
  cat > "$py_script" <<'PYEOF'
import imaplib, ssl, sys, os, email, re
from email.header import decode_header, make_header

USER = os.environ['FM_MAIL_USER']; PW = os.environ['FM_MAIL_PASS']
IMH = os.environ['FM_IMAP_HOST']; IMP = int(os.environ['FM_IMAP_PORT'])
STH = os.environ['FM_SMTP_HOST']; STP = int(os.environ['FM_SMTP_PORT'])
ctx = ssl.create_default_context()


def dec(s):
    if not s:
        return ''
    try:
        return str(make_header(decode_header(s)))
    except Exception:
        return str(s)


def connect_mailbox():
    M = imaplib.IMAP4_SSL(IMH, IMP, ssl_context=ctx)
    M.login(USER, PW)
    return M


cmd = sys.argv[1]

if cmd == 'read':
    try:
        M = connect_mailbox()
        M.select('INBOX')
        typ, data = M.uid('search', None, 'UNSEEN')
        ids = (data[0] or b'').split()
        if not ids:
            print('(no unseen mail)')
            M.logout()
            sys.exit(0)
        for i in ids[-20:]:
            typ, msg = M.uid('fetch', i, '(BODY.PEEK[])')
            if typ != 'OK' or not msg or not msg[0]:
                continue
            mi = email.message_from_bytes(msg[0][1])
            print('---')
            print('From:', dec(mi.get('From')))
            print('Date:', dec(mi.get('Date')))
            print('Subj:', dec(mi.get('Subject')))
            preview = ''
            for part in mi.walk():
                if part.get_content_type() == 'text/plain':
                    preview = part.get_payload(decode=True).decode('utf-8', 'replace').strip()
                    break
            if not preview:
                for part in mi.walk():
                    if part.get_content_type() == 'text/html':
                        raw = part.get_payload(decode=True).decode('utf-8', 'replace')
                        raw = re.sub(r'(?is)<(style|script)[^>]*>.*?</\1>', ' ', raw)
                        preview = re.sub(r'<[^>]+>', ' ', raw)
                        preview = ' '.join(preview.split())
                        break
            if preview:
                first = preview.splitlines()[0] if preview else preview
                print('Body:', (first[:200] if first else ''))
        M.logout()
    except Exception as e:
        print('fm-mail read error:', e)
        sys.exit(1)
    sys.exit(0)

if cmd == 'send':
    try:
        import smtplib
        from email.message import EmailMessage
        from email.utils import formatdate
        to, subj = sys.argv[2], sys.argv[3]
        if sys.argv[4] == '-':
            body = sys.stdin.read().rstrip('\n')
        else:
            body = sys.argv[4]
        m = EmailMessage()
        m['From'] = USER
        m['To'] = to
        m['Subject'] = subj
        m['Date'] = formatdate(localtime=True)
        m.set_content(body)
        with smtplib.SMTP_SSL(STH, STP, context=ctx) as s:
            s.login(USER, PW)
            s.send_message(m)
        print('sent to', to)
    except Exception as e:
        print('fm-mail send error:', e)
        sys.exit(1)
    sys.exit(0)

if cmd == 'seen':
    line = open(sys.argv[2]).read().strip() if os.path.exists(sys.argv[2]) else '(none)'
    print('cursor:', line)
    sys.exit(0)

if cmd == 'poll_list':
    try:
        M = connect_mailbox()
        M.select('INBOX')
        ur = M.untagged_responses.get('UIDVALIDITY')
        uidv = ur[-1].decode() if ur else ''
        typ, data = M.uid('search', None, 'UNSEEN')
        ids = [x for x in (data[0] or b'').split()]
        out = []
        for i in ids:
            typ, msg = M.uid('fetch', i, '(BODY.PEEK[HEADER])')
            if typ != 'OK' or not msg or not msg[0]:
                continue
            mi = email.message_from_bytes(msg[0][1])
            uid = i.decode()
            idate = dec(mi.get('Date'))
            subj = dec(mi.get('Subject'))
            fr = dec(mi.get('From'))
            out.append((uid, idate, fr, subj))
        # Emit the mailbox generation guard first, then each message's
        # uid/date so the bash layer diffs against cursor.
        print('uidvalidity\t%s' % uidv)
        for uid, idate, fr, subj in out:
            print('%s\t%s\t%s\t%s' % (uid, idate, fr, subj))
        M.logout()
    except Exception as e:
        # stderr, not stdout: the bash poll's command substitution captures
        # stdout, so a poll error printed to stdout is swallowed with the
        # list and the poll dies rc=1 with nothing left to report.
        print('fm-mail poll error:', e, file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

raise SystemExit('unknown command')
PYEOF
  FM_MAIL_USER="$FM_MAIL_USER" FM_MAIL_PASS="$FM_MAIL_PASS" \
  FM_IMAP_HOST="$IMAP_HOST" FM_IMAP_PORT="$IMAP_PORT" \
  FM_SMTP_HOST="$SMTP_HOST" FM_SMTP_PORT="$SMTP_PORT" \
    "$PY" "$py_script" "$@" || rc=$?
  rm -f "$py_script"
  return $rc
}

usage() {
  cat <<'EOF'
fm-mail.sh read
fm-mail.sh send <to> <subject> <body | ->
fm-mail.sh poll
fm-mail.sh status
EOF
}

wake_for() {
  # Reuse the fleet's durable wake append so a poll surfaces as a `check` wake.
  # The key is generation-aware when the mailbox reports a UIDVALIDITY, so a
  # restored mailbox's reused uid can never collide with a stale wake key.
  # Emission commits under a single held FM_WAKE_QUEUE_LOCK in three phases:
  # the durable journal record is written FIRST, then the wake row is published,
  # then the cursor records the uid. The journal therefore exists before any row
  # can be acknowledged, so the drain can never consume the only recovery
  # evidence: a kill or write failure after the publish still leaves the
  # journal, and the next poll's heal records the uid without re-waking - never
  # a duplicate. The one deliberate tradeoff is the reverse direction: if the
  # publish fails and the journal rollback also fails, the orphan journal entry
  # heals to a skip (the uid is recorded without a wake) rather than a
  # duplicate.
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
  if printf '%s\t%s\n' "$generation" "$id" >> "$WOKEN"; then
    if fm_wake_append_locked check "$wake_key" "check: mail $id - $summary"; then
      printf '%s\n' "$id" >> "$CURSOR" || {
        echo "fm-mail: cursor record write failed for $id; the journal heals it on the next poll" >&2
      }
    else
      fm_mail_journal_remove_locked "$generation" "$id" || \
        echo "fm-mail: journal rollback failed for $id; the next poll records it without re-waking" >&2
      echo "fm-mail: wake append failed for $id; retried on next poll" >&2
      status=1
    fi
  else
    echo "fm-mail: emission journal write failed for $id; retried on next poll" >&2
    status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_mail_journal_remove_locked() {
  # Remove a just-written journal record whose wake row could not be published.
  # Runs under the held FM_WAKE_QUEUE_LOCK; failure means an orphan journal
  # entry survives, which the next poll's journal heal records without re-waking
  # (a possible skip, never a duplicate).
  local generation=$1 id=$2 tmp
  tmp=$(mktemp "$WOKEN.rm.XXXXXX") || return 1
  if awk -F '\t' -v g="$generation" -v i="$id" \
      '!($1 == g && $2 == i)' "$WOKEN" > "$tmp" 2>/dev/null; then
    if mv -f -- "$tmp" "$WOKEN" 2>/dev/null; then
      return 0
    fi
  fi
  rm -f -- "$tmp"
  return 1
}

mail_seen() {
  # $1 = uid; returns 0 when the cursor already records the uid as surfaced.
  grep -Fqx "$1" "$CURSOR"
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
    # List unseen mail (uid,date,from,subj) plus the mailbox generation guard,
    # then diff against already-surfaced uids to find NEW messages and surface
    # one wake each. Never marks anything read. Emission is a three-phase commit
    # under the portable lock - durable journal record, then wake append, then
    # cursor record - and each poll first heals a run interrupted between those
    # phases from the journal and the wake queue, so an overlapping poll or an
    # interrupted run can never lose a mail or double-surface it.
    if [ ! -f "$FM_HOME/bin/fm-wake-lib.sh" ]; then
      echo "fm-mail: $FM_HOME/bin/fm-wake-lib.sh missing; cannot poll" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE_DIR/.mail-seen.lock"
    LIST="$(run_py poll_list)"
    GENERATION="$(printf '%s\n' "$LIST" | head -n1 | cut -f2)"
    LIST="$(printf '%s\n' "$LIST" | tail -n +2)"

    STORED_GEN=""
    [ -f "$CURSOR" ] || : > "$CURSOR"
    while IFS= read -r u; do
      case "$u" in
        "uidvalidity="*) STORED_GEN="${u#uidvalidity=}" ;;
      esac
    done < "$CURSOR"

    # A recreated/restored mailbox has a new UIDVALIDITY; a numeric uid can be
    # reused, so a stale cursor must not suppress its wake. Journal entries from
    # the old mailbox are equally stale: they describe wakes from before the
    # mailbox identity changed, so clear them rather than risk healing a reused
    # uid into the new generation.
    if [ -n "$GENERATION" ] && [ "$STORED_GEN" != "$GENERATION" ]; then
      STORED_GEN="$GENERATION"
      printf 'uidvalidity=%s\n' "$STORED_GEN" > "$CURSOR"
      : > "$WOKEN"
    fi

    # Heal a poll interrupted between its operations. Emission is a three-phase
    # commit: the durable journal record is written first, the wake append then
    # publishes the surfacing, and the cursor record finally declares the uid
    # surfaced. Each phase is healed from durable evidence:
    #
    # 1. Journal heal - a journal entry is proof a wake was committed, written
    #    BEFORE the row is published and surviving the fleet drain's ack (which
    #    physically removes consumed wake rows from the queue). A poll killed
    #    after publishing its wake but before recording the uid is recovered
    #    even when the drain already acknowledged that wake: the uid is recorded
    #    without re-waking, never duplicate. An orphan entry whose wake could
    #    never be published likewise records without re-waking - a possible
    #    skip, never a duplicate.
    # 2. Queue heal - a queued wake whose uid is absent from the cursor (a row
    #    published by a poll killed before its cursor write) is likewise
    #    recorded without re-waking.
    # Both are generation-scoped: only evidence matching the CURRENT mailbox
    # generation is healed, so a legacy key or a stale prior-generation wake can
    # never mark a reused numeric uid as surfaced in the new mailbox.
    if [ -s "$WOKEN" ]; then
      while IFS=$'\t' read -r jgen juid; do
        [ -n "$juid" ] || continue
        [ "$jgen" != "$GENERATION" ] && continue
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
      [ "$keygen" != "$GENERATION" ] && continue
      if ! mail_seen "$keyuid"; then
        printf '%s\n' "$keyuid" >> "$CURSOR"
      fi
    done < <(fm_wake_queued_keys check 2>/dev/null || true)

    woke=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      uid="$(printf '%s' "$line" | cut -f1)"
      fr="$(printf '%s' "$line" | cut -f3)"
      subj="$(printf '%s' "$line" | cut -f4)"
      if ! mail_seen "$uid"; then
        # Wake first, then record: the journal record, wake append, and cursor
        # commit together under the wake-queue lock inside wake_for (so no drain
        # ack can split them), and a failure stops the poll so the next run
        # retries. A kill before the journal leaves nothing and the next poll
        # retries; a kill after the journal is healed above without re-waking.
        if wake_for "$GENERATION" "$uid" "mail from $fr - ${subj:-no subject}"; then
          echo "fm-mail: woke for $uid"
          woke=$((woke + 1))
        else
          echo "fm-mail: wake failed for $uid; retried on next poll" >&2
          fm_lock_release "$STATE_DIR/.mail-seen.lock"
          exit 1
        fi
      fi
    done <<< "$LIST"
    fm_lock_release "$STATE_DIR/.mail-seen.lock"
    if [ "$woke" -eq 0 ]; then
      echo "fm-mail: no new mail"
    fi
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
