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
    try:
        if msg is None:
            return ''
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
    except Exception:
        return ''
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
            if typ != 'OK' or not msg or not msg[0] or not msg[0][1]:
                print('---')
                print('Uid:', uid)
                print('From:', '(unfetchable)')
                print('Date:', '')
                print('Subj:', 'unfetchable body - see fm-mail read')
                print('Body:', '(body unavailable)')
                continue
            mi = email.message_from_bytes(msg[0][1])
            print('---')
            print('From:', dec(mi.get('From')))
            print('Date:', dec(mi.get('Date')))
            print('Subj:', dec(mi.get('Subject')))
            preview = body_preview(mi)
            if preview:
                first = preview.splitlines()[0]
                print('Body:', (first[:MAX_PREVIEW] if first else ''))
            else:
                print('Body:', '(body unavailable)')
        try:
            m.logout()
        except Exception:
            pass
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


def load_retry_pos(pos_path, n):
    """Return the durable retry-scan start position, clamped into range."""
    if not pos_path:
        return 0
    try:
        pos = int(open(pos_path).read().strip() or '0')
    except (OSError, ValueError):
        return 0
    if n <= 0:
        return 0
    return pos % n


def retry_scan_window(order, pos, window):
    """Take the bounded retry scan starting at the durable position, wrapping
    around the end of the retry file so every retry uid is examined within
    ceil(len/window) polls. The caller advances the position by the window,
    making the scan a cursor over the whole retry set: a recovered uid can
    never be stranded behind a persistent-failure prefix."""
    if not order:
        return []
    if len(order) <= window:
        return list(order)
    start = pos % len(order)
    cands = order[start:start + window]
    if len(cands) < window:
        cands += order[:window - len(cands)]
    return cands


def save_retry_pos(pos_path, order_len, window, pos):
    """Persist the next retry-scan start position after this poll's window.
    A failed write propagates so the poll fails closed rather than silently
    restarting the retry scan at the same head every poll."""
    if not pos_path:
        return
    if order_len <= 0:
        next_pos = 0
    else:
        next_pos = (pos + window) % order_len
    with open(pos_path, 'w', encoding='utf-8') as f:
        f.write(str(next_pos) + '\n')


def load_turn(path):
    """Return the durable alternating-turn flag (0=new,1=retry) for a single
    contended slot."""
    if not path:
        return 0
    try:
        return int(open(path).read().strip() or '0') % 2
    except (OSError, ValueError):
        return 0


def save_turn(path, turn):
    """Persist the alternating-turn flag. A failed write propagates so the
    poll fails closed rather than silently selecting the same class forever."""
    if not path:
        return
    with open(path, 'w', encoding='utf-8') as f:
        f.write(str(turn % 2) + '\n')


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
    retry_pos_path = os.environ.get('FM_MAIL_RETRY_POS', '')
    retry_pos = load_retry_pos(retry_pos_path, len(retry_order))
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
        # Bound the expensive fetch work with a window, applied to each class
        # separately so a large new-mail backlog cannot slice retry candidates
        # out of the scan. The retry scan starts at a durable position and the
        # position advances by the window each poll, so it is a cursor over the
        # whole retry set: every retry uid is examined within ceil(N/window)
        # polls and a recovered uid can never be stranded behind a persistent-
        # failure prefix.
        window = max(cap * 4, cap + 10)
        new_candidates = new_uids[:window]
        # Only a retry uid that is already surfaced (in the cursor) is a pure
        # retry re-fetch. A retry-set uid that is not yet in the cursor is a
        # degraded wake that failed to record - it stays a new candidate so
        # the next poll surfaces it again as degraded instead of silently
        # dropping it.
        retry_candidates = [u for u in retry_scan_window(retry_order, retry_pos, window)
                            if u in seen]
        if cap == 1 and new_candidates and retry_candidates:
            # A single contended slot alternates between new surfacing and
            # retry recovery, so a sustained new-mail flood can never starve
            # recovered metadata indefinitely, and a retry backlog can never
            # delay new mail for more than one poll.
            if load_turn(os.environ.get('FM_MAIL_TURN', '')) == 0:
                new_budget, retry_budget = 1, 0
                save_turn(os.environ.get('FM_MAIL_TURN', ''), 1)
            else:
                new_budget, retry_budget = 0, 1
                save_turn(os.environ.get('FM_MAIL_TURN', ''), 0)
        else:
            # Reserve a quarter of the cap (at least one) for retry successes
            # so a sustained new-mail flood cannot starve recovered metadata,
            # but never let the reservation fully suppress new mail: when both
            # classes have candidates, new mail always keeps at least one slot.
            retry_budget = max(1, cap // 4) if retry_candidates else 0
            new_budget = cap - retry_budget
            if new_candidates and new_budget < 1:
                new_budget = 1
                retry_budget = cap - 1
        out = []
        new_emitted = 0
        retry_emitted = 0
        for u in new_candidates + retry_candidates:
            is_retry = u in retry and u in seen
            if is_retry:
                if retry_emitted >= retry_budget:
                    continue
            elif new_emitted >= new_budget:
                continue
            # A raised or empty FETCH is treated as a failure for THIS uid only,
            # so one bad message can never abort the bounded scan: a new uid is
            # surfaced degraded, a retry uid is rotated, and the scan advances.
            try:
                typ, msg = m.uid('fetch', u.encode(), '(BODY.PEEK[HEADER])')
                if typ != 'OK' or not msg or not msg[0]:
                    raise ValueError('no header data')
                mi = email.message_from_bytes(msg[0][1])
                uid = clean(u)
                idate = clean(dec(mi.get('Date')))
                subj = clean(dec(mi.get('Subject')))
                fr = clean(dec(mi.get('From')))
            except Exception:
                if is_retry:
                    continue
                out.append((clean(u), '', '(no header)',
                            'unfetchable header - see fm-mail read', 'degraded'))
                new_emitted += 1
                continue
            status = 'retry' if is_retry else 'ok'
            out.append((uid, idate, fr, subj, status))
            if is_retry:
                retry_emitted += 1
            else:
                new_emitted += 1
        # Finish every IMAP round-trip before emit or persist so a hung
        # logout cannot run after the retry-scan position advances. Then emit
        # the mailbox generation guard and each message row (uid, date, from,
        # subject, status) so the bash layer diffs against the cursor and the
        # retry set. Flush stdout before persisting: under a pipe CPython
        # block-buffers, and a timeout kill would otherwise discard unflushed
        # rows after the position had already advanced. An interruption
        # between emission and the position write must never advance the
        # cursor over rows that never reached the bash wake layer. A failed
        # position write still fails the poll loudly, so the same bounded
        # window is re-scanned on the next poll rather than silently
        # restarting from the old head.
        try:
            m.logout()
        except Exception:
            pass
        print('uidvalidity\t%s' % uidv)
        for uid, idate, fr, subj, status in out:
            print('%s\t%s\t%s\t%s\t%s' % (uid, idate, fr, subj, status))
        sys.stdout.flush()
        save_retry_pos(retry_pos_path, len(retry_order), window, retry_pos)
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