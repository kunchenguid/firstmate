#!/usr/bin/env python3
# fm-mail.py - the IMAP/SMTP engine behind bin/fm-mail.sh.
#
# A small, side-effect-free mail client used by fm-mail.sh:
#   read                   List unseen INBOX mail as a compact digest.
#   send <to> <subj> <body | ->   Send one SMTP message; "-" reads stdin.
#   poll_list              Emit unseen mail as tab-separated rows for the bash
#                          poll, bounded to uids this home has not surfaced,
#                          plus a retry-set of previously unfetchable uids.
#   seen <cursor>          Print a cursor file (used by `status`).
#
# All configuration arrives through the environment (FM_MAIL_*), never through
# arguments, so credentials never appear in argv or logs. read/poll use
# BODY.PEEK so mail is never marked seen before firstmate answers it.
import imaplib
import os
import re
import socket
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


def mail_timeout():
    """Seconds for IMAP/SMTP sockets. Invalid or non-positive values become 20."""
    raw = os.environ.get('FM_MAIL_TIMEOUT', '20')
    try:
        value = float(raw)
    except (TypeError, ValueError):
        value = 20.0
    if value <= 0:
        value = 20.0
    return value


MAIL_TIMEOUT = mail_timeout()
socket.setdefaulttimeout(MAIL_TIMEOUT)

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
    a fake uid line for the bash layer; strip surrounding whitespace too."""
    return re.sub(r'[\t\r\n]+', ' ', s or '').strip()


def connect_mailbox():
    m = imaplib.IMAP4_SSL(IMH, IMP, ssl_context=CTX, timeout=MAIL_TIMEOUT)
    m.login(USER, PW)
    return m


def body_preview(msg):
    """First non-empty text/plain line, else first non-empty text/html line,
    else empty. An empty plain-text alternative falls through to html so a
    valid message never loses its promised preview."""
    for part in msg.walk():
        if part.get_content_type() == 'text/plain':
            text = (part.get_payload(decode=True) or b'').decode('utf-8', 'replace').strip()
            if text:
                return text
    for part in msg.walk():
        if part.get_content_type() == 'text/html':
            raw = (part.get_payload(decode=True) or b'').decode('utf-8', 'replace')
            raw = re.sub(r'(?is)<(style|script)[^>]*>.*?</\1>', ' ', raw)
            preview = re.sub(r'<[^>]+>', ' ', raw)
            preview = ' '.join(preview.split())
            if preview:
                return preview
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
            uid = i.decode() if isinstance(i, bytes) else str(i)
            typ, msg = m.uid('fetch', i, '(BODY.PEEK[])')
            if typ != 'OK' or not msg or not msg[0]:
                print('---')
                print('Uid:', uid)
                print('From:', '(unfetchable)')
                print('Date:', '')
                print('Subj:', 'unfetchable body - see fm-mail read')
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
        with smtplib.SMTP_SSL(STH, STP, context=CTX, timeout=MAIL_TIMEOUT) as s:
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


def load_retry(retry_path):
    """Return (retry_set, retry_order) from the local retry file."""
    retry = set()
    ordered = []
    if not retry_path or not os.path.exists(retry_path):
        return retry, ordered
    with open(retry_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            uid = line.strip()
            if not uid or uid in retry:
                continue
            retry.add(uid)
            ordered.append(uid)
    return retry, ordered


def rotate_retry_failed(retry_path, uid):
    """Move a still-failing retry uid to the end of the retry file so the next
    poll's scan advances past it and a fixed prefix of persistent failures can
    never starve recovered uids behind it. Runs under the poll's mail-seen
    lock; the bash layer owns the same file, never concurrently."""
    if not retry_path or not os.path.exists(retry_path):
        return
    with open(retry_path, encoding='utf-8', errors='replace') as f:
        lines = [ln.rstrip('\n') for ln in f]
    filtered = [ln for ln in lines if ln and ln != uid]
    if len(filtered) == len(lines):
        return
    filtered.append(uid)
    with open(retry_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(filtered) + '\n')


def cmd_poll_list():
    # Bound the expensive header fetches: only uids not already recorded in the
    # cursor are considered as new, then previously unfetchable retry-set uids
    # (already in the cursor) are fetched again so a transient IMAP failure
    # cannot permanently replace real metadata with degraded placeholders. A
    # bounded window of candidates is scanned to fill the per-poll cap, new
    # uids first so a large retry backlog can never starve new mail.
    cap = int(os.environ.get('FM_MAIL_POLL_MAX_WAKES') or '20')
    if cap < 1:
        cap = 20
    stored_gen, seen = load_cursor(os.environ.get('FM_MAIL_CURSOR', ''))
    retry, retry_order = load_retry(os.environ.get('FM_MAIL_RETRY', ''))
    try:
        m = connect_mailbox()
        m.select('INBOX')
        ur = m.untagged_responses.get('UIDVALIDITY')
        uidv = clean(ur[-1].decode()) if ur else ''
        typ, data = m.uid('search', None, 'UNSEEN')
        unseen = []
        for x in (data[0] or b'').split():
            uid = x.decode() if isinstance(x, bytes) else str(x)
            unseen.append(uid)
        if uidv and uidv == stored_gen:
            # Same mailbox generation: skip uids this home already surfaced so
            # the fetch budget goes to genuinely new mail. Retry-set uids are
            # only meaningful for this generation.
            new_uids = [u for u in unseen if u not in seen]
        else:
            # On a generation change the cursor and retry set are stale, so
            # list everything as new and ignore retry membership; bash clears
            # both files before the wake loop.
            new_uids = list(unseen)
            retry = set()
            retry_order = []
        candidates = []
        seen_cand = set()
        for u in new_uids:
            if u in seen_cand:
                continue
            candidates.append(u)
            seen_cand.add(u)
        for u in retry_order:
            if u in seen_cand:
                continue
            candidates.append(u)
            seen_cand.add(u)
        # Scan a bounded window of candidates rather than exactly the cap, so a
        # repeatedly unfetchable uid (a corrupt message) cannot starve later
        # mail. A new unfetchable uid is still surfaced with a degraded row and
        # recorded in the cursor, so it is never missed; a retry-set uid that
        # fails again emits nothing and stays in the retry set.
        window = max(cap * 4, cap + 10)
        out = []
        for u in candidates[:window]:
            if len(out) >= cap:
                break
            typ, msg = m.uid('fetch', u.encode(), '(BODY.PEEK[HEADER])')
            if typ != 'OK' or not msg or not msg[0]:
                if u in retry:
                    rotate_retry_failed(os.environ.get('FM_MAIL_RETRY', ''), u)
                    continue
                uid = clean(u)
                out.append((uid, '', '(no header)',
                            'unfetchable header - see fm-mail read', 'degraded'))
                continue
            mi = email.message_from_bytes(msg[0][1])
            uid = clean(u)
            idate = clean(dec(mi.get('Date')))
            subj = clean(dec(mi.get('Subject')))
            fr = clean(dec(mi.get('From')))
            status = 'retry' if u in retry else 'ok'
            out.append((uid, idate, fr, subj, status))
        # Emit the mailbox generation guard first, then each message row
        # (uid, date, from, subject, status) so the bash layer diffs against
        # the cursor and the retry set.
        print('uidvalidity\t%s' % uidv)
        for uid, idate, fr, subj, status in out:
            print('%s\t%s\t%s\t%s\t%s' % (uid, idate, fr, subj, status))
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