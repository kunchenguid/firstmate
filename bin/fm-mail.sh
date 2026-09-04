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
#                        answers it concisely. Only mail newer than the last
#                        poll is surfaced; nothing is ever marked read
#                        (BODY.PEEK). poll is OPERATOR-INVOKED: it has no
#                        scheduler or daemon. A captain or an `at`/cron job
#                        decides when to run it; this home offers no email
#                        service wiring of its own.
#   status               Print configuration and the last poll cursor. No
#                        network, no wake.
#
# Deployment - credentials and endpoints live ONLY in the gitignored
# $FM_HOME/.env (same convention as the Relay/FMX token). Add these four
# required values, plus the optional ports and reply target:
#   FM_MAIL_USER=<imap/smtp account>
#   FM_MAIL_PASS=<password>
#   FM_IMAP_HOST=<imap host>
#   FM_IMAP_PORT=<imap port>     (default 993)
#   FM_SMTP_HOST=<smtp host>
#   FM_SMTP_PORT=<smtp port>     (default 465)
#   FM_MAIL_TO=<reply target>    (optional; the address you answer mail to)
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
MAIL_TO="${FM_MAIL_TO:-}"

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-mail: python3 required" >&2
  exit 1
fi

STATE_DIR="$FM_HOME/state"
mkdir -p "$STATE_DIR"
CURSOR="$STATE_DIR/.mail-seen"

# Delegate IMAP/SMTP to python3 (in-core TLS + mime, no shell byte-juggling).
run_py() {
  FM_MAIL_USER="$FM_MAIL_USER" FM_MAIL_PASS="$FM_MAIL_PASS" \
  FM_IMAP_HOST="$IMAP_HOST" FM_IMAP_PORT="$IMAP_PORT" \
  FM_SMTP_HOST="$SMTP_HOST" FM_SMTP_PORT="$SMTP_PORT" \
    "$PY" - "$@" <<'PYEOF'
import imaplib, ssl, sys, os, email
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
        typ, data = M.search(None, 'UNSEEN')
        ids = (data[0] or b'').split()
        if not ids:
            print('(no unseen mail)')
            M.logout()
            sys.exit(0)
        for i in ids[-20:]:
            typ, msg = M.fetch(i, '(BODY.PEEK[HEADER])')
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
        typ, data = M.search(None, 'ALL')
        ids = [x for x in (data[0] or b'').split()]
        out = []
        for i in ids[-50:]:
            typ, msg = M.fetch(i, '(BODY.PEEK[HEADER])')
            if typ != 'OK' or not msg or not msg[0]:
                continue
            mi = email.message_from_bytes(msg[0][1])
            uid = i.decode()
            idate = dec(mi.get('Date'))
            subj = dec(mi.get('Subject'))
            fr = dec(mi.get('From'))
            out.append((uid, idate, fr, subj))
        # Deliver each message's uid/date so the bash layer diffs against cursor.
        for uid, idate, fr, subj in out:
            print('%s\t%s\t%s\t%s' % (uid, idate, fr, subj))
        M.logout()
    except Exception as e:
        print('fm-mail poll error:', e)
        sys.exit(1)
    sys.exit(0)

raise SystemExit('unknown command')
PYEOF
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
  local id=$1 summary=$2 lib="$FM_HOME/bin/fm-wake-lib.sh"
  if [ -f "$lib" ]; then
    # shellcheck source=/dev/null
    . "$lib"
    fm_wake_append check "mail:$id" "check: mail $id - $summary"
  else
    echo "fm-mail: $lib missing; cannot wake" >&2
    return 1
  fi
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
    if [ -n "$MAIL_TO" ]; then
      echo "reply target: $MAIL_TO"
    fi
    run_py seen "$CURSOR" || true
    ;;
  poll)
    # List recent mail (uid,date,from,subj), then diff against already-surfaced
    # uids to find NEW messages and surface one wake each. Never marks anything
    # read. The cursor file holds one surfaced uid per line.
    LIST="$(run_py poll_list || true)"
    declare -A SEEN
    [ -f "$CURSOR" ] || : > "$CURSOR"
    while IFS= read -r u; do
      [ -n "$u" ] && SEEN["$u"]=1
    done < "$CURSOR"
    woke=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      uid="$(printf '%s' "$line" | cut -f1)"
      fr="$(printf '%s' "$line" | cut -f3)"
      subj="$(printf '%s' "$line" | cut -f4)"
      if [ -z "${SEEN[$uid]:-}" ]; then
        wake_for "$uid" "mail from $fr - ${subj:-no subject}"
        echo "fm-mail: woke for $uid"
        printf '%s\n' "$uid" >> "$CURSOR"
        woke=$((woke + 1))
      fi
    done <<< "$LIST"
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
