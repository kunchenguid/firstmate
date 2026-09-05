#!/usr/bin/env python3
# fm-mail.py - the IMAP/SMTP engine behind bin/fm-mail.sh.
#
# A small, side-effect-free mail client used by fm-mail.sh:
#   read                   List unseen INBOX mail as a compact digest.
#   send <to> <subj> <body | ->   Send one SMTP message; "-" reads stdin.
#   poll_list              Emit unseen mail as tab-separated rows for the bash
#                          poll, bounded to uids this home has not surfaced.
#   seen <cursor>          Print a cursor file (used by `status`).
#
# All configuration arrives through the environment (FM_MAIL_*), never through
# arguments, so credentials never appear in argv or logs. read/poll use
# BODY.PEEK so mail is never marked seen before firstmate answers it.
import imaplib
import os
import re
import ssl
import sys
import email
import smtplib
from email.header import decode_header, make_header
from email.message import EmailMessage
from email.utils import formatdate

USER = os.environ['FM_MAIL_USER']
PW = os.environ['FM_MAIL_PASS']
IMH = os.environ['FM_IMAP_HOST']
IMP = int(os.environ['FM_IMAP_PORT'])
STH = os.environ['FM_SMTP_HOST']
STP = int(os.environ['FM_SMTP_PORT'])
CTX = ssl.create_default_context()

MAX_PREVIEW = 200
READ_LIMIT = 20


def dec(s):
    """Decode an RFC-2047 header to display text, tolerating malformed input."""
    if not s:
        return ''
    try:
        return str(make_header(decode_header(s)))
    except Exception:
        return str(s)


def clean(s):
    """Collapse tabs/newlines/CR in a header value to single spaces so a
    crafted Subject/From can never split the tab-separated poll row or inject
    a fake uid line for the bash layer."""
    return re.sub(r'[\t\r\n]+', ' ', s or '')


def connect_mailbox():
    m = imaplib.IMAP4_SSL(IMH, IMP, ssl_context=CTX)
    m.login(USER, PW)
    return m


def body_preview(msg):
    """First text/plain line, else first text/html line, else empty."""
    for part in msg.walk():
        if part.get_content_type() == 'text/plain':
            return part.get_payload(decode=True).decode('utf-8', 'replace').strip()
    for part in msg.walk():
        if part.get_content_type() == 'text/html':
            raw = part.get_payload(decode=True).decode('utf-8', 'replace')
            raw = re.sub(r'(?is)<(style|script)[^>]*>.*?</\1>', ' ', raw)
            preview = re.sub(r'<[^>]+>', ' ', raw)
            return ' '.join(preview.split())
    return ''


def cmd_read():
    try:
        m = connect_mailbox()
        m.select('INBOX')
        typ, data = m.uid('search', None, 'UNSEEN')
        ids = (data[0] or b'').split()
        if not ids:
            print('(no unseen mail)')
            m.logout()
            return 0
        for i in ids[-READ_LIMIT:]:
            typ, msg = m.uid('fetch', i, '(BODY.PEEK[])')
            if typ != 'OK' or not msg or not msg[0]:
                continue
            mi = email.message_from_bytes(msg[0][1])
            print('---')
            print('From:', dec(mi.get('From')))
            print('Date:', dec(mi.get('Date')))
            print('Subj:', dec(mi.get('Subject')))
            preview = body_preview(mi)
            if preview:
                first = preview.splitlines()[0] if preview else preview
                print('Body:', (first[:MAX_PREVIEW] if first else ''))
        m.logout()
        return 0
    except Exception as e:
        print('fm-mail read error:', e)
        return 1


def cmd_send(to, subj, body):
    try:
        if body == '-':
            body = sys.stdin.read().rstrip('\n')
        m = EmailMessage()
        m['From'] = USER
        m['To'] = to
        m['Subject'] = subj
        m['Date'] = formatdate(localtime=True)
        m.set_content(body)
        with smtplib.SMTP_SSL(STH, STP, context=CTX) as s:
            s.login(USER, PW)
            s.send_message(m)
        print('sent to', to)
        return 0
    except Exception as e:
        print('fm-mail send error:', e)
        return 1


def cmd_seen(cursor_path):
    line = open(cursor_path).read().strip() if os.path.exists(cursor_path) else '(none)'
    print('cursor:', line)
    return 0


def load_cursor(cursor_path):
    """Return (stored_generation, seen_uids) from the local cursor file."""
    stored_gen = ''
    seen = set()
    if not os.path.exists(cursor_path):
        return stored_gen, seen
    with open(cursor_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('uidvalidity='):
                stored_gen = line.split('=', 1)[1]
            else:
                seen.add(line)
    return stored_gen, seen


def cmd_poll_list():
    # Bound the expensive header fetches: only uids not already recorded in the
    # cursor are fetched, and at most FM_MAIL_POLL_MAX_WAKES of them, so a large
    # unseen backlog makes bounded progress every poll instead of re-fetching
    # every unseen header and timing out the standing check.
    cap = int(os.environ.get('FM_MAIL_POLL_MAX_WAKES') or '20')
    if cap < 1:
        cap = 20
    stored_gen, seen = load_cursor(os.environ.get('FM_MAIL_CURSOR', ''))
    try:
        m = connect_mailbox()
        m.select('INBOX')
        ur = m.untagged_responses.get('UIDVALIDITY')
        uidv = clean(ur[-1].decode()) if ur else ''
        typ, data = m.uid('search', None, 'UNSEEN')
        ids = [x for x in (data[0] or b'').split()]
        if uidv and uidv == stored_gen:
            # Same mailbox generation: skip uids this home already surfaced so
            # the fetch budget goes to genuinely new mail. On a generation
            # change the cursor is stale, so list everything and let the bash
            # generation reset re-surface.
            ids = [x for x in ids if x.decode() not in seen]
        ids = ids[:cap]
        out = []
        for i in ids:
            typ, msg = m.uid('fetch', i, '(BODY.PEEK[HEADER])')
            if typ != 'OK' or not msg or not msg[0]:
                continue
            mi = email.message_from_bytes(msg[0][1])
            uid = clean(i.decode())
            idate = clean(dec(mi.get('Date')))
            subj = clean(dec(mi.get('Subject')))
            fr = clean(dec(mi.get('From')))
            out.append((uid, idate, fr, subj))
        # Emit the mailbox generation guard first, then each message's
        # uid/date so the bash layer diffs against cursor.
        print('uidvalidity\t%s' % uidv)
        for uid, idate, fr, subj in out:
            print('%s\t%s\t%s\t%s' % (uid, idate, fr, subj))
        m.logout()
        return 0
    except Exception as e:
        # stderr, not stdout: the bash poll's command substitution captures
        # stdout, so a poll error printed to stdout is swallowed with the list
        # and the poll dies rc=1 with nothing left to report.
        print('fm-mail poll error:', e, file=sys.stderr)
        return 1


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'read':
        return cmd_read()
    if cmd == 'send':
        if len(sys.argv) < 5:
            return 1
        return cmd_send(sys.argv[2], sys.argv[3], sys.argv[4])
    if cmd == 'seen':
        return cmd_seen(sys.argv[2] if len(sys.argv) > 2 else '')
    if cmd == 'poll_list':
        return cmd_poll_list()
    raise SystemExit('unknown command')


if __name__ == '__main__':
    sys.exit(main())